# frozen_string_literal: true

require_relative "test_helper"

class HardGateTest < Minitest::Test
  include PulseProofTestData

  def setup
    @states = provider_states
    @gate = PulseProof::HardGate.new(fallback_provider: "spacepayments")
  end

  def test_amount_boundaries_are_inclusive
    operation = queue.first.merge("amount" => 1000)
    assert @gate.evaluate(operation, @states.fetch("vipay")).eligible

    result = @gate.evaluate(operation.merge("amount" => 999), @states.fetch("vipay"))
    refute result.eligible
    assert_equal "amount_below_minimum", result.reason
  end

  def test_bank_allowlist_has_a_specific_reason
    result = @gate.evaluate(queue[1], @states.fetch("vipay"))
    refute result.eligible
    assert_equal "bank_not_in_list", result.reason
    assert_match(/alfa/, result.details)
  end

  def test_reservations_are_included_in_daily_capacity
    payflow = @states.fetch("payflow")
    payflow.reserve!({ "operation_id" => "held", "amount" => 60_000 })
    operation = queue[1].merge("operation_id" => "next", "amount" => 50_000)
    result = @gate.evaluate(operation, payflow)

    refute result.eligible
    assert_equal "daily_amount_limit_exceeded", result.reason
  end

  def test_fallback_is_excluded_until_external_pool_is_empty
    fallback = @states.fetch("spacepayments")
    refute @gate.evaluate(queue.first, fallback).eligible
    assert @gate.evaluate(queue.first, fallback, fallback: true).eligible
  end

  def test_rpm_limit_uses_runtime_request_timestamps
    config = providers_document.fetch("providers").first.merge("requests_per_minute_limit" => 1)
    provider = PulseProof::ProviderState.new(config)
    operation = queue.first
    provider.record_request!(Time.parse(operation.fetch("created_at")))

    result = @gate.evaluate(operation.merge("operation_id" => "next"), provider)

    refute result.eligible
    assert_equal "rpm_limit_exceeded", result.reason
  end
end
