# frozen_string_literal: true

require "tmpdir"
require "open3"
require "rbconfig"
require_relative "test_helper"

class SubmissionWorkflowTest < Minitest::Test
  include PulseProofTestData

  def test_root_stopcode_queue_wins_over_public_sample
    Dir.mktmpdir do |root|
      data_dir = File.join(root, "data")
      Dir.mkdir(data_dir)
      File.write(File.join(data_dir, "operations_queue_10.json"), "[]")
      stopcode = File.join(root, "operations_queue_test.json")
      File.write(stopcode, "[]")

      assert_equal stopcode, PulseProof::InputLocator.queue(root: root)
      assert PulseProof::InputLocator.test_queue?(stopcode)
    end
  end

  def test_explanation_is_readable_without_opening_the_dashboard
    result = runner.run
    decision = result.decisions.find { |row| row["operation_id"] == "op_102" }
    proof = result.report.fetch("proof_capsules").fetch("op_102")
    output = PulseProof::ExplanationPresenter.new(decision: decision, proof: proof).call

    assert_includes output, "OPERATION op_102"
    assert_match(/FINAL\s+payflow/, output)
    assert_includes output, "bank_not_in_list"
    assert_match(/event head/i, output)
  end

  def test_fast_submit_does_not_claim_git_delivery
    Dir.mktmpdir("pulseproof-local-submit-") do |directory|
      queue_path = File.join(directory, "operations_queue_test.json")
      decisions_path = File.join(directory, "decisions.json")
      report_path = File.join(directory, "report.json")
      # Explicitly synthetic test input, never an organizer-provided queue.
      operation = queue.first.merge("operation_id" => "synthetic_submission")
      File.binwrite(queue_path, JSON.generate([operation]))
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, File.join(ROOT, "bin/pulseproof"),
        "submit", "--queue", queue_path, "--decisions", decisions_path, "--report", report_path,
        chdir: directory, binmode: true)
      assert status.success?, stderr
      assert_includes stdout, "GENERATED_LOCALLY"
      assert_includes stdout, "Git commit and remote publication NOT verified"
      refute_includes stdout, "READY FOR SUBMISSION"
      assert_equal ["synthetic_submission"], PulseProof::InputLoader.json(decisions_path).map { |row| row["operation_id"] }
      assert_equal 1, PulseProof::InputLoader.json(report_path).fetch("total_operations")
    end
  end

  def test_verified_and_standard_generation_are_byte_identical
    Dir.mktmpdir("pulseproof-equivalent-generation-") do |directory|
      queue_path = File.join(directory, "queue.json")
      operation = queue.first.merge("operation_id" => "synthetic_equivalence")
      File.binwrite(queue_path, JSON.generate([operation]))
      fast_decisions = File.join(directory, "fast-decisions.json")
      fast_report = File.join(directory, "fast-report.json")
      full_decisions = File.join(directory, "full-decisions.json")
      full_report = File.join(directory, "full-report.json")

      _stdout, stderr, status = Open3.capture3(RbConfig.ruby, File.join(ROOT, "bin/pulseproof"),
        "run", "--verify-write", "--queue", queue_path, "--decisions", fast_decisions, "--report", fast_report,
        chdir: directory, binmode: true)
      assert status.success?, stderr
      _stdout, stderr, status = Open3.capture3(RbConfig.ruby, File.join(ROOT, "bin/pulseproof"),
        "run", "--queue", queue_path, "--decisions", full_decisions, "--report", full_report,
        chdir: directory, binmode: true)
      assert status.success?, stderr

      assert_equal File.binread(full_decisions), File.binread(fast_decisions)
      assert_equal File.binread(full_report), File.binread(fast_report)
    end
  end
end
