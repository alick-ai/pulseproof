# frozen_string_literal: true

require_relative "test_helper"

class CapacityGuardTest < Minitest::Test
  include PulseProofTestData

  def resilience
    PulseProof::InputLoader.json(File.join(PulseProofTestData::ROOT, "config/resilience.json"))
  end

  def tight_document
    document = Marshal.load(Marshal.dump(providers_document))
    document["providers"].find { |p| p["payment_system"] == "quickpay" }["daily_approved_amount"] = 7_880_000
    document
  end

  def operation(id, amount: 30000, bank: "tinkoff", minute: 1)
    { "operation_id" => id, "amount" => amount, "bank" => bank,
      "created_at" => (Time.iso8601(providers_document["snapshot_at"]) + minute * 120).iso8601 }
  end

  def run_events(policy, operations, document: tight_document, past: history)
    session = PulseProof::RuntimeSession.new(providers_document: document, profile: policy, history: past)
    operations.each { |op| session.process("type" => "operation", "operation" => op) }
    session
  end

  def test_preserves_last_external_route_using_history_not_future_queue
    prefix = [operation("first"), operation("second", minute: 2)]
    base = run_events(profile, prefix)
    guarded = run_events(resilience, prefix)
    assert_equal "quickpay", base.decisions["second"]["selected_provider"]
    assert_equal "vipay", guarded.decisions["second"]["selected_provider"]
    proof_before_suffix = PulseProof::Canonical.digest(guarded.router.proofs["second"])
    rare = operation("rare", amount: 120000, bank: "raiffeisen", minute: 3)
    [base, guarded].each { |s| s.process("type" => "operation", "operation" => rare) }
    assert_equal "spacepayments", base.decisions["rare"]["selected_provider"]
    assert_equal "quickpay", guarded.decisions["rare"]["selected_provider"]
    assert_equal proof_before_suffix, PulseProof::Canonical.digest(guarded.router.proofs["second"])
    assert base.report
    assert guarded.report
    assert_equal 1, guarded.report["capacity_protection"]["overrides"].length
  end

  def test_guard_does_not_claim_universal_improvement_when_rare_payment_never_arrives
    prefix = [operation("first"), operation("second", minute: 2)]
    base = run_events(profile, prefix)
    guarded = run_events(resilience, prefix)
    baseline_error = base.report.dig("soft_goal_analysis", "raw_target_deviation_l1_pp")
    guarded_error = guarded.report.dig("soft_goal_analysis", "raw_target_deviation_l1_pp")
    assert_operator guarded_error, :>, baseline_error
    assert_equal 0, guarded.report.dig("distribution", "spacepayments", "count")
  end

  def test_conversion_budget_can_veto_capacity_override
    states = provider_states
    model = PulseProof::CapacityGuard.new(history: history, config: resilience["capacity_guard"], fallback_provider: "spacepayments")
    states["quickpay"].daily_approved_amount = 7_880_000
    before = PulseProof::Canonical.digest(states.transform_values(&:snapshot))
    metrics = metric_map(states)
    metrics["quickpay"]["conservative_conversion"] = 0.99
    metrics["vipay"]["conservative_conversion"] = 0.5
    ranking = [{ "provider" => "quickpay", "primary_regret" => 0.0 }, { "provider" => "vipay", "primary_regret" => 0.0 }]
    result = model.rank(ranking, providers: states, metrics: metrics, operation: operation("budget"))
    assert_equal "quickpay", result.first["provider"]
    refute result.last["capacity_guard"]["within_policy_budget"]
    assert_equal before, PulseProof::Canonical.digest(states.transform_values(&:snapshot))
  end

  def test_primary_goal_budget_can_veto_capacity_override
    states = provider_states
    states["quickpay"].daily_approved_amount = 7_880_000
    model = PulseProof::CapacityGuard.new(history: history, config: resilience["capacity_guard"], fallback_provider: "spacepayments")
    metrics = states.to_h { |name, _| [name, { "conservative_conversion" => 0.9 }] }
    ranking = [{ "provider" => "quickpay", "primary_regret" => 0.0 }, { "provider" => "vipay", "primary_regret" => 0.3 }]
    result = model.rank(ranking, providers: states, metrics: metrics, operation: operation("budget"))
    assert_equal "quickpay", result.first["provider"]
    refute result.last["capacity_guard"]["within_policy_budget"]
  end

  def test_history_after_snapshot_is_not_visible_and_insufficient_history_is_noop
    future = history.map { |row| row.merge("created_at" => "2027-01-01T00:00:00Z") }
    model = PulseProof::CapacityGuard.new(history: future, config: resilience["capacity_guard"], fallback_provider: "spacepayments")
    assert_equal 0, model.model_at(Time.iso8601(providers_document["snapshot_at"]))["sample_size"]
    ranking = [{ "provider" => "quickpay", "primary_regret" => 0.0 }]
    assert_equal ranking, model.rank(ranking, providers: provider_states, metrics: metric_map, operation: operation("future"))
  end

  def test_no_special_provider_names_are_hardcoded
    document = tight_document
    names = { "vipay" => "provider_a", "payflow" => "provider_b", "quickpay" => "provider_c", "spacepayments" => "internal" }
    document["providers"].each { |p| p["payment_system"] = names.fetch(p["payment_system"]) }
    policy = resilience.merge("fallback_provider" => "internal", "amount_preferences" => {})
    past = history.map { |row| row.merge("payment_system" => names.fetch(row["payment_system"])) }
    s = run_events(policy, [operation("first"), operation("second", minute: 2), operation("rare", amount: 120000, bank: "raiffeisen", minute: 3)], document: document, past: past)
    assert_equal "provider_c", s.decisions["rare"]["selected_provider"]
    assert_equal "provider_a", s.decisions["second"]["selected_provider"]
    assert s.report
  end

  def test_public_queue_remains_valid_without_manufactured_capacity_stress
    s = run_events(resilience, queue, document: providers_document)
    assert_equal 10, s.report["total_operations"]
    assert_equal 0, s.report["capacity_protection"]["overrides"].length
    assert_equal 4, s.report.dig("distribution", "vipay", "count")
  end

  def test_lab_searches_a_counterexample_and_discloses_the_unfavorable_branch
    original = PulseProof::Canonical.digest(providers_document)
    result = PulseProof::CapacityLab.new(providers_document: providers_document, history: history, baseline_profile: profile).call
    assert result["prefix_independent_of_suffix"]
    assert_operator result["searched_cases"], :>, 1
    assert_equal 1, result.dig("exclusive_payment_arrives", "baseline", "fallback_count")
    assert_equal 0, result.dig("exclusive_payment_arrives", "guarded", "fallback_count")
    assert_operator result.dig("exclusive_payment_never_arrives", "guarded", "count_l1_pp_external_targets"), :>,
      result.dig("exclusive_payment_never_arrives", "baseline", "count_l1_pp_external_targets")
    assert_equal original, PulseProof::Canonical.digest(providers_document)
  end
end
