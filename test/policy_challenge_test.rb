# frozen_string_literal: true

require_relative "test_helper"

class PolicyChallengeTest < Minitest::Test
  include PulseProofTestData

  def test_analytic_boundary_and_verified_interior_step
    frontier = [
      { "chain" => ["a", "b"], "raw_metrics" => { "count" => 0.0, "attempts" => 3.0 } },
      { "chain" => ["b", "a"], "raw_metrics" => { "count" => 2.0, "attempts" => 1.0 } }
    ]
    result = PulseProof::PolicyChallenge.new(frontier: frontier, weights: { "count" => 2.0, "attempts" => 1.0 }).call(prefer: "b", factor: "count")
    assert_equal "verified_counterfactual", result["status"]
    assert_in_delta 1.0, result["nearest_boundary"], 1e-9
    assert_operator result["proposed_weight"], :<, 1.0
    assert_equal "b", result["recalculated_candidates"].first["chain"].first
  end

  def test_no_single_weight_can_rescue_dominated_option
    frontier = [
      { "chain" => ["a", "b"], "raw_metrics" => { "count" => 0.0, "attempts" => 1.0 } },
      { "chain" => ["b", "a"], "raw_metrics" => { "count" => 1.0, "attempts" => 2.0 } }
    ]
    solver = PulseProof::PolicyChallenge.new(frontier: frontier, weights: { "count" => 1.0, "attempts" => 1.0 })
    assert_equal "no_single_weight_solution", solver.call(prefer: "b", factor: "count")["status"]
    assert_equal "not_eligible", solver.call(prefer: "blocked", factor: "count")["status"]
    assert_equal "already_selected", solver.call(prefer: "a", factor: "count")["status"]
  end

  def test_real_router_reproduces_proposed_change_on_same_initial_state
    policy = PulseProof::InputLoader.json(File.join(ROOT, "config/planner.json"))
    adapter = lambda { |_o,_p,_a| { "result" => "approved", "latency_sec" => 1 } }
    operation = queue.first
    session = PulseProof::RuntimeSession.new(providers_document: providers_document, profile: policy, history: history, outcome_model: adapter)
    session.process("type" => "operation", "operation" => operation)
    proof = session.router.proofs[operation["operation_id"]]
    plan = proof["candidate_rankings"].first.first["outcome_plan"]
    result = PulseProof::PolicyChallenge.new(model: plan["cascade_model"], weights: policy["outcome_planner"]["weights"])
      .call(prefer: "vipay", factor: "count_potential_change")
    assert_equal "verified_counterfactual", result["status"]
    changed = Marshal.load(Marshal.dump(policy))
    changed["outcome_planner"]["weights"]["count_potential_change"] = result["proposed_weight"]
    second = PulseProof::RuntimeSession.new(providers_document: providers_document, profile: changed, history: history, outcome_model: adapter)
    decision = second.process("type" => "operation", "operation" => operation)["decision"]
    assert_equal "vipay", decision["selected_provider"]
    assert second.report
    assert_equal 0.6, policy["outcome_planner"]["weights"]["count_potential_change"]
  end

  def test_search_uses_all_continuations_not_only_original_best_per_provider
    frontier = [
      { "chain" => ["a", "b", "c"], "raw_metrics" => { "x" => 1.0, "y" => 1.0 } },
      { "chain" => ["b", "a", "c"], "raw_metrics" => { "x" => 3.0, "y" => 0.0 } },
      { "chain" => ["b", "c", "a"], "raw_metrics" => { "x" => 0.0, "y" => 3.0 } }
    ]
    result = PulseProof::PolicyChallenge.new(frontier: frontier, weights: { "x" => 1.0, "y" => 1.0 }).call(prefer: "b", factor: "x")
    assert_equal "verified_counterfactual", result["status"]
    assert_equal "b", result["verified_chain"].first
  end
end
