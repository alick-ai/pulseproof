# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"
require_relative "test_helper"
require_relative "../lib/pulseproof/submission_git_check"

class SubmissionGitCheckTest < Minitest::Test
  ARTIFACTS = PulseProof::SubmissionGitCheck::REQUIRED_ARTIFACTS

  def setup
    @root = Dir.mktmpdir("pulseproof-submission-git-")
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  def test_unborn_main_does_not_pass_with_local_artifacts
    initialize_repo
    write_artifacts
    assert_failure("HEAD has no commit")
  end

  def test_wrong_branch_does_not_pass
    commit_artifacts
    git("checkout", "-b", "other")
    assert_failure("expected branch main")
  end

  def test_detached_head_does_not_pass
    commit_artifacts
    git("checkout", "--detach", "HEAD")
    assert_failure("HEAD is detached")
  end

  def test_untracked_artifacts_do_not_pass_when_head_exists
    initialize_repo
    write_artifacts
    File.write(File.join(@root, "README.md"), "Synthetic test repository\n")
    git("add", "--", "README.md")
    git("commit", "-m", "synthetic seed")
    assert_failure("not committed")
  end

  def test_artifacts_only_in_index_do_not_pass
    initialize_repo
    write_artifacts
    File.write(File.join(@root, "README.md"), "Synthetic test repository\n")
    git("add", "--", "README.md")
    git("commit", "-m", "synthetic seed")
    git("add", "--", *ARTIFACTS)
    assert_failure("not committed")
  end

  def test_one_missing_committed_artifact_does_not_pass
    initialize_repo
    write_artifacts
    git("add", "--", ARTIFACTS.first)
    git("commit", "-m", "synthetic partial artifacts")
    assert_failure("#{ARTIFACTS.last} is not committed")
  end

  def test_modified_working_tree_bytes_do_not_pass
    commit_artifacts
    File.write(File.join(@root, ARTIFACTS.first), "[{}]\n")
    assert_failure("differs from its committed bytes")
  end

  def test_staged_changes_do_not_pass_even_if_worktree_matches_head
    commit_artifacts
    path = File.join(@root, ARTIFACTS.first)
    original = File.binread(path)
    File.write(path, "[{}]\n")
    git("add", "--", ARTIFACTS.first)
    File.binwrite(path, original)
    assert_failure("has staged changes")
  end

  def test_staged_deletion_does_not_pass_even_if_worktree_is_restored
    commit_artifacts
    git("rm", "--cached", "--", ARTIFACTS.first)
    assert_failure("has staged changes")
  end

  def test_missing_working_tree_file_does_not_pass
    commit_artifacts
    File.delete(File.join(@root, ARTIFACTS.first))
    assert_failure("must exist as a regular working-tree file")
  end

  def test_working_tree_symlink_does_not_pass_even_with_matching_bytes
    commit_artifacts
    path = File.join(@root, ARTIFACTS.first)
    File.rename(path, File.join(@root, "copy.json"))
    File.symlink("copy.json", path)
    assert_failure("must exist as a regular working-tree file")
  end

  def test_committed_symlink_does_not_pass
    initialize_repo
    write_artifacts
    path = File.join(@root, ARTIFACTS.first)
    File.rename(path, File.join(@root, "copy.json"))
    File.symlink("copy.json", path)
    git("add", "--", *ARTIFACTS, "copy.json")
    git("commit", "-m", "synthetic symlink artifact")
    assert_failure("must be a regular committed file")
  end

  def test_matching_artifacts_pass_without_claiming_remote_or_source_delivery
    commit_artifacts
    File.write(File.join(@root, "untracked-demo.txt"), "not within the artifact check\n")
    before_index = File.binread(File.join(@root, ".git", "index"))
    before_status = git("status", "--porcelain=v1")

    result = checker.verify!

    assert_equal "LOCAL_ARTIFACTS_COMMITTED", result.fetch("status")
    assert_equal git("rev-parse", "HEAD").strip, result.fetch("commit")
    assert_equal "refs/heads/main", result.fetch("ref")
    assert_equal ARTIFACTS, result.fetch("artifacts")
    assert_equal false, result.fetch("remote_verified")
    assert_includes result.fetch("scope"), "not verified"
    assert_equal before_index, File.binread(File.join(@root, ".git", "index"))
    assert_equal before_status, git("status", "--porcelain=v1")
    assert_equal "", git("remote")
  end

  def test_non_repository_does_not_pass
    assert_failure("not a readable Git working tree")
  end

  def test_nested_directory_cannot_claim_parent_repository_artifacts
    commit_artifacts
    nested = File.join(@root, "nested")
    Dir.mkdir(nested)
    error = assert_raises(PulseProof::InputError) do
      PulseProof::SubmissionGitCheck.new(root: nested).verify!
    end
    assert_includes error.message, "not the Git repository root"
  end

  def test_repository_with_russian_directory_name_passes
    temporary_root = @root
    @root = File.join(temporary_root, "репозиторий")
    Dir.mkdir(@root)
    commit_artifacts

    assert_equal "LOCAL_ARTIFACTS_COMMITTED", checker.verify!.fetch("status")
  ensure
    @root = temporary_root
  end

  private

  def checker
    PulseProof::SubmissionGitCheck.new(root: @root)
  end

  def assert_failure(message)
    error = assert_raises(PulseProof::InputError) { checker.verify! }
    assert_includes error.message, message
  end

  def initialize_repo
    git("init", "--quiet")
    git("symbolic-ref", "HEAD", "refs/heads/main")
  end

  def write_artifacts
    File.write(File.join(@root, ARTIFACTS.first), "[]\n")
    File.write(File.join(@root, ARTIFACTS.last), "{\"recommendation\":\"Проверка\"}\n", encoding: "UTF-8")
  end

  def commit_artifacts
    initialize_repo
    write_artifacts
    git("add", "--", *ARTIFACTS)
    git("commit", "-m", "synthetic artifacts")
  end

  # All mutations are confined to this test's fresh temporary repository.
  # Identity/signing settings apply to this invocation, never to global config.
  def git(*arguments)
    stdout, stderr, status = Open3.capture3(PulseProof::SubmissionGitCheck::GIT_ENV,
      "git", "-C", @root, "-c", "user.name=PulseProof Test", "-c", "user.email=pulseproof-test@example.invalid",
      "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", *arguments, binmode: true)
    raise "temporary test Git command failed: #{stderr}" unless status.success?
    stdout
  end
end
