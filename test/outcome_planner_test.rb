# frozen_string_literal: true

require_relative "test_helper"

class OutcomePlannerTest < Minitest::Test
  include PulseProofTestData

  def policy
    PulseProof::InputLoader.json(File.join(ROOT, "config/planner.json"))
  end

  def operation(id = "plan", second: 0, amount: 2000, bank: "sberbank")
    { "operation_id" => id, "amount" => amount, "bank" => bank,
      "created_at" => (Time.iso8601(providers_document["snapshot_at"]) + second).iso8601 }
  end

  def model_rank(config = policy, metrics: nil, document: providers_document)
    states = document["providers"].each_with_object({}) { |p,h| h[p["payment_system"]] = PulseProof::ProviderState.new(p) }
    metrics ||= states.keys.each_with_object({}) { |name,h| h[name] = { "conservative_conversion" => 0.8 } }
    control = PulseProof::DeficitController.new(states, config)
    control.accrue!(2000)
    names = states.keys - ["spacepayments"]
    ranking = control.rank(names, metrics, 2000)
    planner = PulseProof::OutcomePlanner.new(profile: config, history: [])
    before = PulseProof::Canonical.digest(states.transform_values(&:config))
    result = planner.rank(ranking, providers: states, metrics: metrics, operation: operation, controller: control)
    assert_equal before, PulseProof::Canonical.digest(states.transform_values(&:config))
    assert states.values.all? { |s| s.reserved_count.zero? }
    result
  end

  def test_probabilities_are_cascade_terminal_outcomes_not_first_assignment
    result = model_rank
    plan = result.first.fetch("outcome_plan")
    probabilities = plan["final_approval_probabilities"]
    assert_in_delta 0.8, probabilities[plan["chain"][0]], 1e-8
    assert_in_delta 0.16, probabilities[plan["chain"][1]], 1e-8
    assert_in_delta 1, probabilities.values.sum + plan["pending_probabilities"].values.sum + plan["all_failed_probability"], 1e-8
    assert_in_delta 1.248, plan["raw_metrics"]["attempts"], 1e-8
    assert_equal "spacepayments", plan["chain"].last
    assert_equal 3, plan["chains_evaluated"]
    refute plan["all_external_orders_evaluated"]
    assert plan.dig("optimization", "exact_for_frozen_model")
    refute plan.dig("optimization", "factorial_search_used")
    assert_equal "certified", plan.dig("dependence_certificate", "status")
  end

  def test_dependence_analytics_cannot_influence_ranking_or_objective
    with_certificate = model_rank
    without_certificate = PulseProof::DependenceCertificate.stub(:build, lambda { |**_args| nil }) { model_rank }
    strip = lambda { |rows| rows.map { |row| row.merge("outcome_plan" => row["outcome_plan"].reject { |key, _value| key == "dependence_certificate" }) } }
    assert_equal strip.call(without_certificate), strip.call(with_certificate)
  end

  def test_unknown_timeout_stops_probability_flow_and_is_not_approval
    config = policy
    config["outcome_planner"]["pending_probabilities"] = { "vipay" => 1.0 }
    plan = model_rank(config).find { |row| row["provider"] == "vipay" }["outcome_plan"]
    assert_equal 1, plan["pending_probabilities"]["vipay"]
    assert_equal 0, plan["final_approval_probabilities"].values.sum
    assert_equal 1, plan["raw_metrics"]["attempts"]
    assert_equal "not_applicable", plan.dig("dependence_certificate", "status")
  end

  def test_rates_below_old_penalty_saturation_remain_distinct
    config = policy
    config["outcome_planner"]["weights"] = { "attempts" => 1.0 }
    metrics = { "vipay" => 0.1, "payflow" => 0.3, "quickpay" => 0.05, "spacepayments" => 0.9 }.transform_values { |p| { "conservative_conversion" => p } }
    assert_equal "payflow", model_rank(config, metrics: metrics).first["provider"]
  end

  def test_exact_optimizer_is_independent_of_legacy_chain_budget
    expected = model_rank
    [1, 120, 1000].each do |legacy_budget|
      config = policy
      config["outcome_planner"]["max_chains"] = legacy_budget
      result = model_rank(config)
      assert_equal expected, result
      assert_equal %w[payflow quickpay vipay], result.map { |row| row["provider"] }.sort
      result.each do |row|
        plan = row.fetch("outcome_plan")
        assert_equal 3, plan["chains_evaluated"]
        refute plan["all_external_orders_evaluated"]
        assert plan.dig("optimization", "exact_for_frozen_model")
        refute plan.dig("optimization", "factorial_search_used")
      end
    end
  end

  def test_yesterday_history_survives_only_in_slow_prior
    states = provider_states
    row = operation("yesterday", second: -86400).merge("payment_system" => "vipay", "status" => "rejected", "latency_sec" => 1)
    model = PulseProof::AdaptiveLearning.new(providers: states, history: [row], config: policy["adaptive_learning"], as_of: providers_document["snapshot_at"])
    estimate = model.estimate("vipay", operation, at: Time.iso8601(operation["created_at"]))
    assert_operator estimate["slow_prior"]["effective_samples"], :>, 0.8
    assert_equal 0, estimate["effective_samples"]
    assert_operator estimate["slow_prior"]["mean"], :<, states["vipay"].config["conversion_24h"]
    model.observe(operation: operation, provider_name: "vipay", attempt: 1, status: "rejected", at: operation["created_at"])
    updated = model.estimate("vipay", operation, at: Time.iso8601(operation["created_at"]))
    assert_equal estimate["slow_prior"], updated["slow_prior"]
    assert_equal 1, updated["effective_samples"]
  end

  def test_history_rows_count_once_across_backoff_levels
    rows = [operation("exact", second: -1), operation("bank", second: -1, amount: 80000), operation("provider", second: -1, bank: "tinkoff")].map { |r| r.merge("payment_system" => "vipay", "status" => "approved", "latency_sec" => 0) }
    model = PulseProof::AdaptiveLearning.new(providers: provider_states, history: rows, config: policy["adaptive_learning"])
    prediction = model.estimate("vipay", operation, at: Time.iso8601(operation["created_at"]))
    assert_in_delta 1.45, prediction["slow_prior"]["effective_samples"], 0.001
  end

  def test_runtime_replans_after_reject_and_keeps_hard_exclusions
    adapter = lambda { |_op, _p, attempt| { "result" => attempt == 1 ? "rejected" : "approved", "latency_sec" => 1 } }
    session = PulseProof::RuntimeSession.new(providers_document: providers_document, profile: policy, history: history, outcome_model: adapter)
    result = session.process("type" => "operation", "operation" => operation(bank: "alfa"))["decision"]
    attempts = result["attempts"].select { |r| r["decision"] == "selected" }
    refute_includes attempts.map { |r| r["provider"] }, "vipay"
    assert_equal 2, attempts.length
    proofs = session.router.proofs["plan"]["candidate_rankings"]
    refute_includes proofs.last.map { |r| r["provider"] }, attempts.first["provider"]
    assert session.report["outcome_planning"]["enabled"]
  end

  def test_opportunity_repairs_are_isolated_and_minimal_only_on_tested_grid
    document = providers_document
    document["providers"].each do |p|
      p["daily_approved_amount"] = 0
      p["daily_amount_limit"] = 0 unless p["payment_system"] == "spacepayments"
    end
    states = document["providers"].each_with_object({}) { |p,h| h[p["payment_system"]] = PulseProof::ProviderState.new(p) }
    shapes = Array.new(10) { |i| operation("past#{i}", second: -10, amount: 2000, bank: "alfa") }
    model = PulseProof::OpportunityModel.new(history: shapes, config: { "horizon_operations" => 3, "repair_steps_rub" => [1000, 2000, 10000] }, fallback: "spacepayments")
    before = states["payflow"].config["daily_amount_limit"]
    repairs = model.repairs(states, Time.iso8601(operation["created_at"]))
    repair = repairs.find { |r| r["provider"] == "payflow" }
    assert_equal 2000, repair["increase_rub"]
    assert_equal 0, repair["served_before"]
    assert_equal 1, repair["served_after"]
    assert_equal before, states["payflow"].config["daily_amount_limit"]
    assert states.values.all? { |s| s.reserved_count.zero? }
  end

  def test_profile_rejects_invalid_probabilities_and_unknown_objectives
    config = policy
    config["outcome_planner"]["pending_probabilities"] = { "vipay" => 2 }
    assert_raises(PulseProof::InputError) { PulseProof::InputLoader.validate_profile!(config, providers_document) }
    config = policy
    config["outcome_planner"]["weights"]["magic"] = 1
    assert_raises(PulseProof::InputError) { PulseProof::InputLoader.validate_profile!(config, providers_document) }
  end

  def test_probability_proof_tampering_is_rejected
    session = PulseProof::RuntimeSession.new(providers_document: providers_document, profile: policy, history: [],
      outcome_model: lambda { |_o,_p,_a| { "result" => "approved", "latency_sec" => 1 } })
    session.process("type" => "operation", "operation" => operation)
    proof = Marshal.load(Marshal.dump(session.router.proofs["plan"]))
    plan = proof["candidate_rankings"].first.first["outcome_plan"]
    plan["final_approval_probabilities"][plan["chain"].first] += 0.1
    assert_raises(PulseProof::InvariantError) { PulseProof::PlanVerifier.verify!(proof, "spacepayments") }
  end

  def test_shared_capacity_stress_consumes_resources_jointly_without_touching_ledger
    states = provider_states
    states.each_value do |p|
      p.config["banks"] = []
      p.config["daily_amount_limit"] = 4000
      p.daily_approved_amount = 0
    end
    shapes = Array.new(10) { |i| operation("past#{i}", second: -10) }
    model = PulseProof::OpportunityModel.new(history: shapes, config: { "horizon_operations" => 6 }, fallback: "spacepayments")
    result = model.assess(states, operation, %w[vipay payflow quickpay])
    # Every shape has three providers. No provider is individually exclusive,
    # but using one slot reduces the JOINT feasible historical-tape packing.
    assert_equal 6, result["vipay"]["served_before"]
    assert_equal 5, result["vipay"]["served_after_reservation"]
    assert_equal 1, result["vipay"]["lost_service_slots"]
    assert states.values.all? { |p| p.reserved_count.zero? && p.daily_approved_amount.zero? }
  end

  def test_same_prefix_is_independent_of_later_operations
    adapter = lambda { |_o,_p,_a| { "result" => "approved", "latency_sec" => 1 } }
    a = PulseProof::RuntimeSession.new(providers_document: providers_document, profile: policy, history: history, outcome_model: adapter)
    b = PulseProof::RuntimeSession.new(providers_document: providers_document, profile: policy, history: history, outcome_model: adapter)
    first = operation("prefix")
    assert_equal a.process("type" => "operation", "operation" => first), b.process("type" => "operation", "operation" => first)
    prefix_hash = PulseProof::Canonical.digest(a.router.proofs["prefix"])
    a.process("type" => "operation", "operation" => operation("suffix_a", second: 10, amount: 150000))
    b.process("type" => "operation", "operation" => operation("suffix_b", second: 10, amount: 1000))
    assert_equal prefix_hash, PulseProof::Canonical.digest(a.router.proofs["prefix"])
    assert_equal prefix_hash, PulseProof::Canonical.digest(b.router.proofs["prefix"])
  end

  def test_planner_lab_has_four_validated_controls_and_five_scenarios
    result = PulseProof::PlannerLab.new(providers_document: providers_document, profile: policy, baseline_profile: profile,
      adaptive_profile: PulseProof::InputLoader.json(File.join(ROOT, "config/adaptive.json")), seeds: [713], phase_length: 2).call
    assert_equal 5, result["results"].length
    result["results"].each do |row|
      %w[balanced adaptive planner_frozen planner].each { |name| assert row[name]["validated"] }
    end
  end

  def test_pending_plan_is_not_executed_after_rules_change
    selected = nil
    adapter = lambda do |_op, provider, attempt|
      selected ||= provider.name
      { "result" => attempt == 1 ? "expired" : "approved", "latency_sec" => attempt == 1 ? 181 : 1 }
    end
    session = PulseProof::RuntimeSession.new(providers_document: providers_document, profile: policy, history: [], outcome_model: adapter)
    first = session.process("type" => "operation", "operation" => operation(bank: "alfa"))["decision"]
    assert_equal "expired", first["simulated_result"]
    assert_equal 0, session.router.adaptive_learning.observed_count
    %w[payflow quickpay].each do |name|
      session.process("type" => "provider_update", "provider" => name, "changes" => { "status" => "inactive" }, "at" => operation(second: 190)["created_at"])
    end
    status = { "type" => "status", "operation_id" => "plan", "provider" => selected, "attempt" => 1,
      "status" => "cancelled", "at" => operation(second: 200)["created_at"], "event_id" => "cancel1" }
    result = session.process(status)["result"]
    assert_equal "spacepayments", result["selected_provider"]
    assert_equal 2, session.router.adaptive_learning.observed_count
    session.process(status)
    assert_equal 2, session.router.adaptive_learning.observed_count
    assert session.report
  end

  def test_pending_risk_and_latency_have_explicit_effects
    config = policy
    config["outcome_planner"]["weights"] = { "latency_sec" => 1.0 }
    assert_equal "quickpay", model_rank(config).first["provider"]
    config["outcome_planner"]["weights"] = { "unresolved_or_failed_probability" => 1.0 }
    config["outcome_planner"]["pending_probabilities"] = { "quickpay" => 0.9 }
    refute_equal "quickpay", model_rank(config).first["provider"]
  end

  def test_explicit_public_approval_simulation_is_recorded_and_matches_forced_routes
    result = PulseProof::Runner.new(providers_path: File.join(ROOT, "data/providers.json"), queue_path: File.join(ROOT, "data/operations_queue_10.json"),
      history_path: File.join(ROOT, "data/operations_history.csv"), profile_path: File.join(ROOT, "config/planner.json"), simulation_mode: "approve").run
    assert_equal "approve", result.report["audit"]["outcome_mode"]
    { "op_103" => "quickpay", "op_104" => "quickpay", "op_107" => "payflow", "op_108" => "quickpay" }.each do |id, name|
      assert_equal name, result.decisions.find { |d| d["operation_id"] == id }["selected_provider"]
    end
  end

  def test_volume_objective_changes_choice_without_disabling_hard_rules
    config = policy
    config["volume_targets"] = { "payflow" => 100 }
    config["outcome_planner"]["weights"] = { "volume_potential_change" => 1.0 }
    assert_equal "payflow", model_rank(config).first["provider"]
  end

  def test_runtime_accepts_renamed_providers_and_custom_self_provider
    document = providers_document
    document["providers"].zip(%w[oak pine elm internal]).each { |p,name| p["payment_system"] = name }
    config = policy
    config["fallback_provider"] = "internal"
    config["amount_preferences"] = {}
    session = PulseProof::RuntimeSession.new(providers_document: document, profile: config, history: [],
      outcome_model: lambda { |_o,_p,_a| { "result" => "approved", "latency_sec" => 1 } })
    result = session.process("type" => "operation", "operation" => operation)["decision"]
    assert_includes %w[oak pine elm], result["selected_provider"]
    assert session.report
  end
end
