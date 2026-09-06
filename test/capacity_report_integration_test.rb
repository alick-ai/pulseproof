# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "tmpdir"
require "rbconfig"

class CapacityReportIntegrationTest < Minitest::Test
  include PulseProofTestData

  def validate(result, report)
    PulseProof::StrictValidator.new(queue: queue, providers_document: providers_document,
      decisions: result.decisions, report: report).validate!
  end

  def test_report_is_bound_to_original_inputs_and_decisions
    result = runner.run
    assert_equal 1, result.report.dig("audit", "capacity_explanation_schema")
    assert_equal PulseProof::CapacityExplanation.new(queue: queue, decisions: result.decisions,
      providers_document: providers_document).build, result.report.fetch("capacity_explanation")
    assert validate(result, result.report)
  end

  def test_arbitrary_addition_to_explanation_is_detected
    result = runner.run
    result.report.fetch("capacity_explanation")["unsupported_global_optimum"] = true
    error = assert_raises(PulseProof::InvariantError) { validate(result, result.report) }
    assert_includes error.message, "capacity explanation differs"
  end

  def test_live_schema_marker_detects_missing_explanation
    result = runner.run
    result.report.delete("capacity_explanation")
    error = assert_raises(PulseProof::InvariantError) { validate(result, result.report) }
    assert_includes error.message, "capacity explanation is missing"
  end

  def test_legacy_reports_without_module_remain_valid
    result = runner.run
    result.report.delete("capacity_explanation")
    result.report.fetch("audit").delete("capacity_explanation_schema")
    assert validate(result, result.report)
  end

  def test_optional_snapshot_time_does_not_break_a_valid_runtime_report
    document = Marshal.load(Marshal.dump(providers_document))
    document.delete("snapshot_at")
    session = PulseProof::RuntimeSession.new(providers_document: document, profile: profile, history: history)
    session.process("type" => "operation", "operation" => queue.first)
    report = session.report
    assert_equal "not_applicable", report.dig("capacity_explanation", "status")
    assert_equal "missing_or_invalid_snapshot_time", report.dig("capacity_explanation", "reason")
    assert_equal 1, report["total_operations"]
  end

  def test_default_cli_retains_balanced_and_public_validator_compatibility
    Dir.mktmpdir("pulseproof-final-public-") do |directory|
      decisions = File.join(directory, "decisions.json")
      report = File.join(directory, "report.json")
      _stdout, stderr, status = Open3.capture3(RbConfig.ruby, File.join(ROOT, "bin/pulseproof"), "run",
        "--queue", File.join(ROOT, "data/operations_queue_10.json"), "--decisions", decisions, "--report", report,
        chdir: directory, binmode: true)
      assert status.success?, stderr
      exported = PulseProof::InputLoader.json(report)
      assert_equal "balanced", exported.dig("policy", "profile")
      assert_equal "balanced_minimax", exported.dig("policy", "selection_mode")
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, File.join(ROOT, "scripts/validate_10.rb"), decisions,
        chdir: ROOT, binmode: true)
      assert status.success?, (stdout + stderr).force_encoding(Encoding::UTF_8)
      assert_includes stdout.force_encoding(Encoding::UTF_8), "Пройдено: 29"
    end
  end
end
