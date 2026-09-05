#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"

ROOT = File.expand_path("..", __dir__)

def capture!(*command, chdir:, label:)
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  stdout, stderr, status = Open3.capture3(*command, chdir: chdir, binmode: true)
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  unless status.success?
    warn "#{label} failed (#{format('%.2f', elapsed)}s)"
    warn stdout unless stdout.empty?
    warn stderr unless stderr.empty?
    exit 1
  end
  puts "#{label}: PASS (#{format('%.2f', elapsed)}s)"
  { "seconds" => elapsed.round(2), "stdout" => stdout, "stderr" => stderr }
end

branch = capture!("git", "branch", "--show-current", chdir: ROOT, label: "Source branch").fetch("stdout").strip
abort "rehearsal requires source branch main" unless branch == "main"
dirty = capture!("git", "status", "--porcelain", chdir: ROOT, label: "Source worktree").fetch("stdout")
abort "rehearsal requires a clean source worktree" unless dirty.empty?
abort "rehearsal refuses to run while a root operations_queue_test.json exists" if File.exist?(File.join(ROOT, "operations_queue_test.json"))

Dir.mktmpdir("pulseproof-submission-rehearsal-") do |directory|
  worktree = File.join(directory, "worktree")
  remote = File.join(directory, "remote.git")
  capture!("git", "clone", "--quiet", "--no-hardlinks", ROOT, worktree, chdir: directory, label: "Isolated clone")
  capture!("git", "config", "user.name", "PulseProof rehearsal", chdir: worktree, label: "Rehearsal identity")
  capture!("git", "config", "user.email", "rehearsal@example.invalid", chdir: worktree, label: "Rehearsal email")

  FileUtils.cp(File.join(worktree, "data/operations_queue_10.json"), File.join(worktree, "operations_queue_test.json"))
  submit = capture!(RbConfig.ruby, "-S", "rake", "submit", chdir: worktree, label: "Stopcode generation gate")

  capture!("git", "add", "operations_queue_test.json", "routing_decisions_test.json", "routing_report_test.json", chdir: worktree, label: "Stage final artifacts")
  capture!("git", "commit", "-m", "Rehearse stopcode artifacts", chdir: worktree, label: "Commit final artifacts")
  capture!("git", "init", "--bare", remote, chdir: directory, label: "Isolated bare remote")
  capture!("git", "remote", "set-url", "origin", remote, chdir: worktree, label: "Isolated remote binding")
  push = capture!("git", "push", "--quiet", "--set-upstream", "origin", "main", chdir: worktree, label: "Push main")
  verify = capture!(RbConfig.ruby, "-S", "rake", "submission_git", chdir: worktree, label: "Committed-artifact gate")

  local_sha = capture!("git", "rev-parse", "HEAD", chdir: worktree, label: "Local commit hash").fetch("stdout").strip
  remote_line = capture!("git", "ls-remote", "--heads", "origin", "main", chdir: worktree, label: "Remote commit hash").fetch("stdout").strip
  remote_sha = remote_line.split.first
  abort "rehearsal hash mismatch: local=#{local_sha} remote=#{remote_sha}" unless local_sha == remote_sha

  summary = {
    "status" => "ISOLATED_SUBMISSION_REHEARSAL_PASS",
    "source_commit" => capture!("git", "rev-parse", "HEAD^", chdir: worktree, label: "Source commit hash").fetch("stdout").strip,
    "rehearsal_commit" => local_sha,
    "submit_seconds" => submit.fetch("seconds"),
    "push_seconds" => push.fetch("seconds"),
    "submission_git_seconds" => verify.fetch("seconds"),
    "remote_hash_matches" => true,
    "temporary_directory_removed_on_exit" => true,
    "scope" => "Public sample copied only inside an isolated temporary clone; no organizer queue or external remote used."
  }
  puts JSON.pretty_generate(summary)
end
