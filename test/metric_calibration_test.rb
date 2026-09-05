# frozen_string_literal: true

require_relative "test_helper"

class MetricCalibrationTest < Minitest::Test
  include PulseProofTestData

  def test_incompatible_and_future_outcomes_do_not_bias_calibration
    rows = [
      { "payment_system" => "vipay", "status" => "approved", "amount" => 10000, "bank" => "sberbank", "created_at" => "2026-07-29T09:00:00+03:00", "latency_sec" => 10 },
      { "payment_system" => "vipay", "status" => "rejected", "amount" => 999999, "bank" => "sberbank", "created_at" => "2026-07-29T09:00:00+03:00", "latency_sec" => 10 },
      { "payment_system" => "vipay", "status" => "rejected", "amount" => 10000, "bank" => "sberbank", "created_at" => "2026-07-30T08:59:59+03:00", "latency_sec" => 10 }
    ]
    metrics = PulseProof::MetricTrustGate.new(rows, provider_states, prior_strength: 0, as_of: "2026-07-30T09:00:00+03:00").all
    assert_equal 1, metrics["vipay"]["calibration_sample_size"]
    assert_equal 1, metrics["vipay"]["policy_mismatch_rows"]
    assert_equal 1, metrics["vipay"]["excluded_unavailable_rows"]
    assert_equal 1.0, metrics["vipay"]["conservative_conversion"]
    assert metrics["payflow"]["conservative_conversion"].finite?
    assert_equal provider_states["payflow"].config["conversion_24h"], metrics["payflow"]["conservative_conversion"]
  end
end
