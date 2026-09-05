# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "tempfile"
require "time"
require_relative "errors"
require_relative "submission_git_check"

module PulseProof
  # Binds a successful pre-stopcode release gate to one exact, published commit.
  # The later fast path may change only the organizer queue and generated output
  # artifacts; any source/config/test change invalidates the receipt.
  class StopcodePreflight
    VERSION = 1
    STATUS = "STOPCODE_PREFLIGHT_ARMED"
    DEFAULT_RECEIPT = File.join("outputs", "stopcode-preflight.json")
    MUTABLE_AFTER_PREFLIGHT = [
      "operations_queue_test.json",
      File.join("data", "operations_queue_test.json"),
      *SubmissionGitCheck::REQUIRED_ARTIFACTS
    ].freeze
    GIT_ENV = SubmissionGitCheck::GIT_ENV.merge("GIT_TERMINAL_PROMPT" => "0").freeze

    def initialize(root:, receipt_path: DEFAULT_RECEIPT)
      @root = File.expand_path(root)
      @receipt_path = File.expand_path(receipt_path, @root)
    end

    def write!
      state = candidate!
      receipt = {
        "version" => VERSION,
        "status" => STATUS,
        "commit" => state.fetch("commit"),
        "tree" => state.fetch("tree"),
        "branch" => state.fetch("branch"),
        "upstream_ref" => state.fetch("upstream_ref"),
        "upstream_commit" => state.fetch("upstream_commit"),
        "remote_commit_at_preflight" => state.fetch("remote_commit"),
        "remote_verified_at_preflight" => true,
        "ruby_engine" => RUBY_ENGINE,
        "ruby_version" => RUBY_VERSION,
        "release_gate" => "rake release",
        "created_at" => Time.now.utc.iso8601,
        "scope" => "The full local release gate passed and remote origin/main matched this exact clean main commit at preflight time. The receipt does not certify the later organizer queue, generated artifacts, future remote availability, or final score."
      }
      write_atomically(receipt)
      receipt
    rescue JSON::GeneratorError, SystemCallError, IOError => error
      fail_check("cannot write preflight receipt (#{error.class})")
    end

    def candidate!
      state = git_state!(mutable_paths: [])
      remote_commit = remote_main_commit!
      fail_check("origin/main on the remote server differs from local HEAD") unless remote_commit == state.fetch("commit")
      state.merge("remote_commit" => remote_commit)
    end

    def verify!
      receipt = load_receipt!
      fail_check("unsupported receipt version") unless receipt["version"] == VERSION
      fail_check("receipt status is invalid") unless receipt["status"] == STATUS

      state = git_state!(mutable_paths: MUTABLE_AFTER_PREFLIGHT)
      compare!(receipt, state, "commit")
      compare!(receipt, state, "tree")
      compare!(receipt, state, "branch")
      compare!(receipt, state, "upstream_ref")
      compare!(receipt, state, "upstream_commit")
      fail_check("Ruby engine changed since preflight") unless receipt["ruby_engine"] == RUBY_ENGINE
      fail_check("Ruby version changed since preflight") unless receipt["ruby_version"] == RUBY_VERSION

      receipt.merge(
        "verified" => true,
        "mutable_paths" => MUTABLE_AFTER_PREFLIGHT.dup,
        "verification_scope" => "Code, configuration and tests still match the preflight commit; only the organizer queue and two generated submission artifacts may differ."
      )
    end

    private

    def load_receipt!
      fail_check("receipt is missing; run rake arm_stopcode before the organizer queue arrives") unless File.file?(@receipt_path)
      document = JSON.parse(File.read(@receipt_path, encoding: "UTF-8"))
      fail_check("receipt root must be an object") unless document.is_a?(Hash)
      document
    rescue JSON::ParserError
      fail_check("receipt is not valid JSON")
    rescue SystemCallError, IOError => error
      fail_check("cannot read preflight receipt (#{error.class})")
    end

    def git_state!(mutable_paths:)
      repository_root = git!("rev-parse", "--show-toplevel", error: "not a readable Git working tree").strip
      unless File.realpath(repository_root).b == File.realpath(@root).b
        fail_check("the supplied directory is not the Git repository root")
      end

      commit = git!("rev-parse", "--verify", "HEAD^{commit}", error: "HEAD has no commit").strip
      tree = git!("rev-parse", "--verify", "HEAD^{tree}", error: "HEAD tree is unreadable").strip
      branch = git!("symbolic-ref", "--quiet", "--short", "HEAD", error: "HEAD is detached; expected branch main").strip
      fail_check("expected branch main, got #{branch}") unless branch == "main"

      upstream_ref = git!("rev-parse", "--symbolic-full-name", "@{upstream}", error: "main has no configured upstream").strip
      upstream_commit = git!("rev-parse", "--verify", "@{upstream}^{commit}", error: "main upstream commit is unreadable").strip
      fail_check("main does not track origin/main") unless upstream_ref == "refs/remotes/origin/main"
      fail_check("local main differs from the local origin/main tracking ref") unless upstream_commit == commit

      changed = nul_paths(git!("diff", "--name-only", "-z", "HEAD", "--", error: "cannot inspect tracked changes"))
      untracked = nul_paths(git!("ls-files", "--others", "--exclude-standard", "-z", error: "cannot inspect untracked files"))
      unexpected = (changed + untracked).uniq - mutable_paths
      fail_check("worktree changed outside allowed stopcode data: #{unexpected.join(', ')}") unless unexpected.empty?

      {
        "commit" => commit,
        "tree" => tree,
        "branch" => branch,
        "upstream_ref" => upstream_ref,
        "upstream_commit" => upstream_commit
      }
    rescue SystemCallError, IOError => error
      fail_check("cannot inspect local repository (#{error.class})")
    end

    def nul_paths(bytes)
      bytes.split("\0").reject(&:empty?)
    end

    def compare!(receipt, state, key)
      fail_check("#{key} differs from the preflight receipt") unless receipt[key] == state.fetch(key)
    end

    def write_atomically(document)
      directory = File.dirname(@receipt_path)
      FileUtils.mkdir_p(directory)
      temporary = Tempfile.new(["stopcode-preflight-", ".json"], directory)
      temporary.binmode
      temporary.write("#{JSON.pretty_generate(document)}\n")
      temporary.flush
      temporary.fsync
      temporary.close
      File.rename(temporary.path, @receipt_path)
    ensure
      temporary&.close unless temporary&.closed?
      temporary&.unlink
    end

    def remote_main_commit!
      output = git!("ls-remote", "--exit-code", "origin", "refs/heads/main", error: "cannot verify remote origin/main")
      commit, ref = output.lines.first.to_s.split
      fail_check("remote origin/main response is malformed") unless ref == "refs/heads/main" && commit&.match?(/\A[0-9a-f]{40,64}\z/)
      commit
    end

    def git!(*arguments, error:)
      stdout, _stderr, status = Open3.capture3(GIT_ENV, "git", "-C", @root, *arguments, binmode: true)
      fail_check(error) unless status.success?
      stdout
    end

    def fail_check(message)
      raise InputError, "stopcode preflight failed: #{message}"
    end
  end
end
