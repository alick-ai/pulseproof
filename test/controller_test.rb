# frozen_string_literal: true

require_relative "test_helper"

class ControllerTest < Minitest::Test
  include PulseProofTestData

  def test_public_queue_reaches_best_prefix_fair_distribution_without_lookahead
    result = runner.run
    counts = result.decisions.group_by { |decision| decision["selected_provider"] }

    assert_equal 4, counts.fetch("vipay").length
    assert_equal 3, counts.fetch("payflow").length
    assert_equal 3, counts.fetch("quickpay").length
    assert_equal false, result.report.dig("audit", "lookahead_used")
    assert_equal 10, result.router.controller.processed_count
    assert_nil result.report.dig("volume_distribution", "vipay", "target_pct")
    assert result.report.dig("volume_distribution", "vipay").key?("deviation_pp")
  end

  def test_unavailable_debt_is_bounded_and_recovery_is_rate_limited
    states = provider_states
    controller = PulseProof::DeficitController.new(states, profile)
    unavailable = PulseProof::RuleResult.new(provider: "vipay", eligible: false, reason: "provider_inactive", details: "", facts: {})
    eligible = states.keys.reject { |name| name == "spacepayments" }.map do |name|
      PulseProof::RuleResult.new(provider: name, eligible: name != "vipay", reason: "eligible", details: "", facts: {})
    end

    30.times do
      controller.accrue!(10_000)
      controller.mark_eligibility!(eligible.map { |row| row.provider == "vipay" ? unavailable : row })
    end
    assert_operator controller.count_debt.fetch("vipay"), :<=, profile["traffic_debt_bound"]

    recovered = eligible.map { |row| PulseProof::RuleResult.new(provider: row.provider, eligible: true, reason: "eligible", details: "", facts: {}) }
    controller.mark_eligibility!(recovered)
    ranking = controller.rank(%w[vipay payflow quickpay], metric_map(states), 10_000)
    vipay = ranking.find { |row| row["provider"] == "vipay" }
    other_max = %w[payflow quickpay].map { |name| controller.count_debt.fetch(name) }.max
    assert_operator vipay["effective_count_debt"], :<=, other_max + profile["recovery_rate"] + 0.000001
    assert vipay["recovering"]
  end

  def test_same_input_produces_identical_decisions_and_report
    first = runner.run
    second = runner.run
    assert_equal PulseProof::Canonical.digest(first.decisions), PulseProof::Canonical.digest(second.decisions)
    assert_equal PulseProof::Canonical.digest(first.report), PulseProof::Canonical.digest(second.report)
  end

  def test_amount_band_is_a_soft_preference_between_eligible_providers
    scorer = PulseProof::PolicyScorer.new(provider_states, profile)
    metric = { "conservative_conversion" => 0.9 }

    payflow = scorer.penalties("payflow", metric, 10_000)
    vipay = scorer.penalties("vipay", metric, 10_000)

    assert_equal 0.0, payflow.fetch("amount_fit")
    assert_operator vipay.fetch("amount_fit"), :>, 0.0
  end

  def test_every_shipped_policy_profile_runs_without_router_changes
    %w[balanced cascade conversion_first weighted_sum].each do |name|
      configured_runner = PulseProof::Runner.new(
        providers_path: File.join(PulseProofTestData::ROOT, "data/providers.json"),
        queue_path: File.join(PulseProofTestData::ROOT, "data/operations_queue_10.json"),
        history_path: File.join(PulseProofTestData::ROOT, "data/operations_history.csv"),
        profile_path: File.join(PulseProofTestData::ROOT, "config/#{name}.json")
      )
      result = configured_runner.run

      assert_equal 10, result.decisions.length, name
      assert_equal name, result.report.dig("policy", "profile"), name
    end
  end

  def test_volume_target_can_override_count_preference
    volume_profile = profile.merge("volume_targets" => { "vipay" => 0, "payflow" => 100, "quickpay" => 0 })
    controller = PulseProof::DeficitController.new(provider_states, volume_profile)
    controller.accrue!(10_000)

    ranking = controller.rank(%w[vipay payflow], metric_map, 10_000)

    assert_equal "payflow", ranking.first["provider"]
    assert_operator ranking.first["volume_regret"], :<, ranking.last["volume_regret"]
  end

  def test_optional_availability_redistribution_keeps_raw_business_debt_visible
    states = provider_states
    configured = profile.merge("redistribute_unavailable" => true)
    controller = PulseProof::DeficitController.new(states, configured)
    eligibility = %w[vipay payflow quickpay].map do |name|
      PulseProof::RuleResult.new(provider: name, eligible: name != "vipay", reason: "test", details: "", facts: {})
    end
    counts = Hash.new(0)
    metrics = metric_map(states)
    120.times do
      controller.accrue!(1000)
      controller.mark_eligibility!(eligibility)
      winner = controller.rank(%w[payflow quickpay], metrics, 1000).first["provider"]
      controller.provisional_credit!(winner, 1000)
      counts[winner] += 1
    end
    assert_in_delta 70, counts["payflow"], 1
    assert_in_delta 50, counts["quickpay"], 1
    assert_in_delta 48, controller.snapshot["raw_count_debt"]["vipay"], 0.000001
  end
end
