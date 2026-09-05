# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "tmpdir"
require_relative "test_helper"

class StopcodePreflightTest < Minitest::Test
  def setup
    @container = Dir.mktmpdir("pulseproof-stopcode-preflight-")
    @root = File.join(@container, "repo")
    @remote = File.join(@container, "remote.git")
    Dir.mkdir(@root)
    initialize_published_repo
  end

  def teardown
    FileUtils.remove_entry(@container) if @container && File.directory?(@container)
  end

  def test_receipt_verifies_and_allows_only_queue_and_generated_artifacts_to_change
    receipt = preflight.write!
    File.write(File.join(@root, "operations_queue_test.json"), "[]\n")
    File.write(File.join(@root, "routing_decisions_test.json"), "[{\"operation_id\":\"test\"}]\n")
    File.write(File.join(@root, "routing_report_test.json"), "{\"total_operations\":1}\n")

    verified = preflight.verify!

    assert_equal PulseProof::StopcodePreflight::STATUS, receipt.fetch("status")
    assert_equal true, receipt.fetch("remote_verified_at_preflight")
    assert_equal git("rev-parse", "HEAD").strip, verified.fetch("commit")
    assert_equal true, verified.fetch("verified")
    assert_includes verified.fetch("mutable_paths"), "operations_queue_test.json"
  end

  def test_changed_source_invalidates_receipt
    preflight.write!
    File.write(File.join(@root, "router.rb"), "changed\n")

    assert_failure("worktree changed outside allowed stopcode data: router.rb")
  end

  def test_untracked_source_invalidates_receipt
    preflight.write!
    File.write(File.join(@root, "new_policy.rb"), "new\n")

    assert_failure("worktree changed outside allowed stopcode data: new_policy.rb")
  end

  def test_new_published_commit_invalidates_old_receipt
    preflight.write!
    File.write(File.join(@root, "router.rb"), "changed\n")
    git("add", "--", "router.rb")
    git("commit", "-m", "change source")
    git("push", "--quiet", "origin", "main")

    assert_failure("commit differs from the preflight receipt")
  end

  def test_missing_receipt_is_rejected
    assert_failure("receipt is missing")
  end

  def test_local_commit_must_match_origin_main_before_receipt_is_written
    File.write(File.join(@root, "router.rb"), "changed\n")
    git("add", "--", "router.rb")
    git("commit", "-m", "local only")

    error = assert_raises(PulseProof::InputError) { preflight.write! }
    assert_includes error.message, "local main differs from the local origin/main tracking ref"
  end

  def test_tracking_ref_cannot_fake_remote_publication
    File.write(File.join(@root, "router.rb"), "changed\n")
    git("add", "--", "router.rb")
    git("commit", "-m", "local only")
    git("update-ref", "refs/remotes/origin/main", "HEAD")

    error = assert_raises(PulseProof::InputError) { preflight.write! }
    assert_includes error.message, "remote server differs from local HEAD"
  end

  private

  def preflight
    PulseProof::StopcodePreflight.new(root: @root)
  end

  def assert_failure(message)
    error = assert_raises(PulseProof::InputError) { preflight.verify! }
    assert_includes error.message, message
  end

  def initialize_published_repo
    git("init", "--quiet")
    git("symbolic-ref", "HEAD", "refs/heads/main")
    File.write(File.join(@root, ".gitignore"), "outputs/\noperations_queue_test.json\ndata/operations_queue_test.json\n")
    File.write(File.join(@root, "router.rb"), "original\n")
    File.write(File.join(@root, "routing_decisions_test.json"), "[]\n")
    File.write(File.join(@root, "routing_report_test.json"), "{}\n")
    git("add", "--", ".gitignore", "router.rb", "routing_decisions_test.json", "routing_report_test.json")
    git("commit", "-m", "published source")
    run_git(@container, "init", "--quiet", "--bare", @remote)
    git("remote", "add", "origin", @remote)
    git("push", "--quiet", "--set-upstream", "origin", "main")
  end

  def git(*arguments)
    run_git(@root, *arguments)
  end

  def run_git(directory, *arguments)
    stdout, stderr, status = Open3.capture3(PulseProof::SubmissionGitCheck::GIT_ENV,
      "git", "-C", directory, "-c", "user.name=PulseProof Test", "-c", "user.email=pulseproof-test@example.invalid",
      "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", *arguments, binmode: true)
    raise "temporary test Git command failed: #{stderr}" unless status.success?
    stdout
  end
end
