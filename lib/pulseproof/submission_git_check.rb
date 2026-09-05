# frozen_string_literal: true

require "open3"
require_relative "errors"

module PulseProof
  # Read-only, local Git check for exactly the two required output artifacts.
  # This does not certify the source tree, organizer input, validator score,
  # publication, or access to a repository by the organizers.
  class SubmissionGitCheck
    REQUIRED_ARTIFACTS = %w[routing_decisions_test.json routing_report_test.json].freeze
    REGULAR_MODES = %w[100644 100755].freeze
    GIT_ENV = {
      "GIT_OPTIONAL_LOCKS" => "0",
      "GIT_DIR" => nil,
      "GIT_WORK_TREE" => nil,
      "GIT_INDEX_FILE" => nil,
      "GIT_COMMON_DIR" => nil,
      "GIT_OBJECT_DIRECTORY" => nil,
      "GIT_ALTERNATE_OBJECT_DIRECTORIES" => nil
    }.freeze

    def initialize(root:)
      @root = File.expand_path(root)
    end

    def verify!
      repository_root = git!("rev-parse", "--show-toplevel", error: "not a readable Git working tree").strip
      # Git stdout is binary while the caller's path can be UTF-8 even under
      # a C locale. Filesystem identity is compared as canonical path bytes.
      unless File.realpath(repository_root).b == File.realpath(@root).b
        fail_check("the supplied directory is not the Git repository root")
      end

      commit = git!("rev-parse", "--verify", "HEAD^{commit}", error: "HEAD has no commit; local files are not committed").strip
      ref = git!("symbolic-ref", "--quiet", "HEAD", error: "HEAD is detached; expected branch main").strip
      fail_check("expected branch main") unless ref == "refs/heads/main"

      REQUIRED_ARTIFACTS.each { |path| verify_artifact!(path, commit) }

      {
        "status" => "LOCAL_ARTIFACTS_COMMITTED",
        "commit" => commit,
        "ref" => ref,
        "artifacts" => REQUIRED_ARTIFACTS.dup,
        "remote_verified" => false,
        "scope" => "Only the two required JSON files match HEAD, index and worktree; source delivery, organizer input authenticity, scoring and remote publication are not verified."
      }
    rescue SystemCallError, IOError => error
      fail_check("cannot inspect local repository or artifact (#{error.class})")
    end

    private

    def verify_artifact!(path, commit)
      metadata = git!("ls-tree", "-z", commit, "--", path, error: "cannot inspect committed artifact #{path}")
      entries = metadata.split("\0")
      fail_check("#{path} is not committed in the root of HEAD") unless entries.length == 1
      attributes, entry_path = entries.first.split("\t", 2)
      mode, type, object_id = attributes.split(" ")
      unless entry_path == path && type == "blob" && REGULAR_MODES.include?(mode)
        fail_check("#{path} must be a regular committed file, not a symlink or directory")
      end

      index = git!("ls-files", "--stage", "-z", "--", path, error: "cannot inspect staged artifact #{path}")
      expected_index = "#{mode} #{object_id} 0\t#{path}\0"
      fail_check("#{path} has staged changes, is untracked, or is conflicted") unless index == expected_index

      absolute_path = File.join(@root, path)
      unless File.exist?(absolute_path) && File.lstat(absolute_path).file?
        fail_check("#{path} must exist as a regular working-tree file, not a symlink")
      end
      committed_bytes = git!("cat-file", "blob", object_id, error: "cannot read committed artifact #{path}")
      fail_check("#{path} differs from its committed bytes") unless File.binread(absolute_path) == committed_bytes
    end

    def git!(*arguments, error:)
      stdout, _stderr, status = Open3.capture3(GIT_ENV, "git", "-C", @root, *arguments, binmode: true)
      fail_check(error) unless status.success?
      stdout
    end

    def fail_check(message)
      raise InputError, "submission Git check failed: #{message}"
    end
  end
end
