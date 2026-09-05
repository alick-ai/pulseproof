# frozen_string_literal: true

require_relative "test_helper"

class StrictValidatorTest < Minitest::Test
  include PulseProofTestData

  def test_valid_result_passes
    result = runner.run
    validator = PulseProof::StrictValidator.new(
      queue: queue,
      providers_document: providers_document,
      decisions: result.decisions,
      report: result.report
    )
    assert validator.validate!
  end

  def test_duplicate_operation_is_rejected
    result = runner.run
    decisions = result.decisions + [result.decisions.first]
    validator = PulseProof::StrictValidator.new(
      queue: queue,
      providers_document: providers_document,
      decisions: decisions,
      report: result.report
    )
    error = assert_raises(PulseProof::InvariantError) { validator.validate! }
    assert_match(/not unique/, error.message)
  end

  def test_phone_leak_is_rejected
    result = runner.run
    report = Marshal.load(Marshal.dump(result.report))
    report["debug"] = queue.first.dig("payout_requisite", "sbp", "phone")
    validator = PulseProof::StrictValidator.new(
      queue: queue,
      providers_document: providers_document,
      decisions: result.decisions,
      report: report
    )
    error = assert_raises(PulseProof::InvariantError) { validator.validate! }
    assert_match(/PII|sensitive/, error.message)
  end

  def test_unknown_simulated_result_is_rejected
    result = runner.run
    decisions = Marshal.load(Marshal.dump(result.decisions))
    decisions.first["simulated_result"] = "maybe"
    validator = PulseProof::StrictValidator.new(
      queue: queue,
      providers_document: providers_document,
      decisions: decisions,
      report: result.report
    )

    error = assert_raises(PulseProof::InvariantError) { validator.validate! }
    assert_match(/invalid simulated_result/, error.message)
  end

  def test_wrong_top_level_types_are_reported_as_input_errors
    validator = PulseProof::StrictValidator.new(
      queue: queue,
      providers_document: providers_document,
      decisions: {},
      report: []
    )

    error = assert_raises(PulseProof::InvariantError) { validator.validate! }
    assert_match(/decisions must be an array/, error.message)
    assert_match(/report must be an object/, error.message)
  end

  def test_tampered_event_log_is_rejected
    result = runner.run
    report = Marshal.load(Marshal.dump(result.report))
    report.fetch("event_log").first.fetch("payload")["attempt"] = 99
    validator = PulseProof::StrictValidator.new(
      queue: queue,
      providers_document: providers_document,
      decisions: result.decisions,
      report: report
    )

    error = assert_raises(PulseProof::InvariantError) { validator.validate! }
    assert_match(/event_log hash broken/, error.message)
  end
end
