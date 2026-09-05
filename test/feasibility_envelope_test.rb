# frozen_string_literal: true

require_relative "test_helper"

class FeasibilityEnvelopeTest < Minitest::Test
  include PulseProofTestData

  def test_hindsight_bound_respects_request_rate_limits
    document = Marshal.load(Marshal.dump(providers_document))
    document["providers"].each do |config|
      config["traffic_percentage"] = config["payment_system"] == "vipay" ? 100 : 0
      config["requests_per_minute_limit"] = 1 if config["payment_system"] == "vipay"
    end
    a = queue.first.merge("amount" => 10000, "bank" => "sberbank")
    b = a.merge("operation_id" => "second")
    result = PulseProof::FeasibilityEnvelope.new([a, b], document).call
    assert result["exact"]
    assert_equal 1, result["optimal_distribution"]["vipay"]
    assert_equal 1, result["optimal_distribution"]["spacepayments"]
    assert_equal 50.0, result["minimum_l1_deviation_pp"]
  end

  def test_budget_exhaustion_is_never_reported_as_exact
    result = PulseProof::FeasibilityEnvelope.new(queue, providers_document, node_limit: 1).call
    refute result["exact"]
    refute result.key?("minimum_l1_deviation_pp")
  end
end
