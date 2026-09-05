# frozen_string_literal: true

require_relative "test_helper"

class CascadeCertificateTest < Minitest::Test
  include PulseProofTestData

  def planner_policy
    result = PulseProof::InputLoader.json(File.join(ROOT, "config/planner.json"))
    result["adaptive_learning"]["enabled"] = false
    result
  end

  def proof(config: planner_policy, document: providers_document)
    session = PulseProof::RuntimeSession.new(providers_document: document, profile: config, history: [],
      outcome_model: lambda { |_operation, _provider, _attempt| { "result" => "approved", "latency_sec" => 1 } })
    session.process("type" => "operation", "operation" => queue.first)
    Marshal.load(Marshal.dump(session.router.proofs.fetch(queue.first.fetch("operation_id"))))
  end

  def ranking(item)
    item.fetch("candidate_rankings").first
  end

  def model(item)
    ranking(item).first.fetch("outcome_plan").fetch("cascade_model")
  end

  def verify(item)
    PulseProof::PlanVerifier.verify!(item, "spacepayments")
  end

  def rewrite_plan(item, row, chain)
    weights = item.fetch("attempt_snapshots").first.fetch("snapshot").fetch("policy").fetch("outcome_planner").fetch("weights")
    row["outcome_plan"].merge!(PulseProof::CascadeOptimizer.new(model(item)).evaluate(chain, weights))
  end

  def test_certificate_is_verified_without_calling_optimizer
    item = proof
    PulseProof::CascadeOptimizer.stub(:new, lambda { |_model| raise "verifier reused optimizer" }) do
      PulseProof::DependenceCertificate.stub(:build, lambda { |**_args| raise "verifier reused dependence producer" }) do
        assert verify(item)
      end
    end
  end

  def test_dependence_numbers_scope_and_fallback_attribution_cannot_be_tampered
    changes = [
      lambda { |c| c["success_probability"]["lower"] = c["success_probability"]["lower"].next_float },
      lambda { |c| c["exact_bounds"]["success"]["lower"] = "1/1" },
      lambda { |c| c["all_failed_probability"]["upper"] = 0.0 },
      lambda { |c| c["independent_reference"]["success"] = 1.0 },
      lambda { |c| c["fallback"]["success_lower_bound_gain_over_fallback"] = 0.1 },
      lambda { |c| c["lower_bound_drivers"] = ["vipay"] },
      lambda { |c| c["scope"]["optimal_order_certified"] = true },
      lambda { |c| c["status"] = "not_applicable" },
      lambda { |c| c["scope"]["marginals"] = "true_rates_guaranteed" }
    ]
    changes.each do |change|
      item = proof
      change.call(ranking(item).first["outcome_plan"]["dependence_certificate"])
      error = assert_raises(PulseProof::InvariantError) { verify(item) }
      assert_match(/dependence certificate differs/, error.message)
    end
  end

  def test_missing_or_unknown_dependence_certificate_fails_closed
    item = proof
    ranking(item).first["outcome_plan"].delete("dependence_certificate")
    assert_match(/dependence certificate is missing/, assert_raises(PulseProof::InvariantError) { verify(item) }.message)
    [2, false, nil].each do |version|
      item = proof
      ranking(item).first["outcome_plan"]["optimization"]["dependence_certificate_version"] = version
      assert_match(/unsupported dependence/, assert_raises(PulseProof::InvariantError) { verify(item) }.message)
    end
  end

  def test_old_exact_reports_without_dependence_marker_remain_verifiable
    item = proof
    ranking(item).each do |row|
      row["outcome_plan"].delete("dependence_certificate")
      row["outcome_plan"]["optimization"].delete("dependence_certificate_version")
    end
    assert verify(item)
  end

  def test_pending_cannot_be_relabelled_as_binary_success_certificate
    config = planner_policy
    config["outcome_planner"]["pending_probabilities"] = { "vipay" => 0.1 }
    item = proof(config: config)
    assert verify(item)
    cert = ranking(item).first["outcome_plan"]["dependence_certificate"]
    assert_equal "not_applicable", cert["status"]
    cert["status"] = "certified"
    assert_raises(PulseProof::InvariantError) { verify(item) }
  end

  def test_disabled_planner_cannot_smuggle_an_unchecked_outcome_plan
    item = proof
    item["attempt_snapshots"].first["snapshot"]["policy"]["outcome_planner"]["enabled"] = false
    assert_match(/disabled planner/, assert_raises(PulseProof::InvariantError) { verify(item) }.message)
  end

  def test_legacy_reports_without_exact_marker_keep_arithmetic_validation
    item = proof
    ranking(item).each do |row|
      row["outcome_plan"].delete("cascade_model")
      row["outcome_plan"].delete("optimization")
    end
    assert verify(item)
  end

  def test_deleting_new_certificate_does_not_silently_downgrade_validation
    item = proof
    ranking(item).first["outcome_plan"].delete("cascade_model")
    error = assert_raises(PulseProof::InvariantError) { verify(item) }
    assert_match(/certificate is missing/, error.message)
  end

  def test_continuation_and_local_goal_tampering_are_bound_to_snapshot
    ["continue_probability", "count_potential_change", "business_factors"].each do |field|
      item = proof
      action = model(item).fetch("actions").fetch("vipay")
      if field == "continue_probability"
        action[field] += 0.01
      else
        action["local_metrics"][field] += 0.01
      end
      error = assert_raises(PulseProof::InvariantError) { verify(item) }
      assert_match(/differs from snapshot/, error.message)
    end
  end

  def test_tiny_coefficient_tampering_is_not_hidden_by_display_tolerance
    item = proof
    action = model(item).fetch("actions").fetch("vipay")
    action["local_metrics"]["count_potential_change"] += 1e-12
    assert_raises(PulseProof::InvariantError) { verify(item) }
  end

  def test_terminal_vector_and_unknown_local_metric_are_rejected
    item = proof
    model(item)["terminal_metrics"]["unresolved_or_failed_probability"] = 0.9
    assert_raises(PulseProof::InvariantError) { verify(item) }
    item = proof
    model(item)["actions"]["vipay"]["local_metrics"]["unexplained_bonus"] = -100
    assert_raises(PulseProof::InvariantError) { verify(item) }
  end

  def test_snapshot_eligible_candidate_cannot_disappear_from_model_and_ranking
    item = proof
    removed = ranking(item).last.fetch("provider")
    model(item)["external_providers"].delete(removed)
    model(item)["actions"].delete(removed)
    ranking(item).pop
    error = assert_raises(PulseProof::InvariantError) { verify(item) }
    assert_match(/hard-eligible snapshot/, error.message)
  end

  def test_eligible_fallback_cannot_be_silently_omitted
    item = proof
    model(item)["fallback_provider"] = nil
    model(item)["actions"].delete("spacepayments")
    error = assert_raises(PulseProof::InvariantError) { verify(item) }
    assert_match(/fallback differs/, error.message)
  end

  def test_fallback_only_shortcut_cannot_hide_eligible_external_candidates
    item = proof
    item["candidate_rankings"][0] = [{ "provider" => "spacepayments" }]
    error = assert_raises(PulseProof::InvariantError) { verify(item) }
    assert_match(/hides an eligible external/, error.message)
  end

  def test_ineligible_fallback_is_absent_and_cannot_be_added
    document = Marshal.load(Marshal.dump(providers_document))
    document.fetch("providers").find { |provider| provider["payment_system"] == "spacepayments" }["status"] = "inactive"
    item = proof(document: document)
    assert_nil model(item)["fallback_provider"]
    assert verify(item)
    model(item)["fallback_provider"] = "spacepayments"
    assert_raises(PulseProof::InvariantError) { verify(item) }
  end

  def test_self_consistent_but_suboptimal_suffix_is_rejected
    item = proof
    row = ranking(item).first
    chain = row.fetch("outcome_plan").fetch("chain").dup
    chain[1], chain[2] = chain[2], chain[1]
    rewrite_plan(item, row, chain)
    error = assert_raises(PulseProof::InvariantError) { verify(item) }
    assert_match(/canonical exact optimum/, error.message)
  end

  def test_unreachable_suffix_still_requires_canonical_lexical_order
    document = Marshal.load(Marshal.dump(providers_document))
    document.fetch("providers").each { |provider| provider["conversion_24h"] = 1.0 }
    item = proof(document: document)
    row = ranking(item).first
    chain = row.fetch("outcome_plan").fetch("chain").dup
    old_objective = row["outcome_plan"]["objective_unrounded"]
    chain[1], chain[2] = chain[2], chain[1]
    rewrite_plan(item, row, chain)
    assert_equal old_objective, row["outcome_plan"]["objective_unrounded"]
    error = assert_raises(PulseProof::InvariantError) { verify(item) }
    assert_match(/canonical exact optimum/, error.message)
  end

  def test_exact_ranking_is_checked_even_when_displayed_objectives_tie
    config = planner_policy
    config["outcome_planner"]["weights"] = { "attempts" => 1e-12 }
    item = proof(config: config)
    rows = ranking(item)
    assert_equal [0.0], rows.map { |row| row["outcome_plan"]["objective"] }.uniq
    assert verify(item)
    certificate = rows.first["outcome_plan"].delete("cascade_model")
    frontier = rows.first["outcome_plan"].delete("evaluated_frontier")
    rows[0], rows[1] = rows[1], rows[0]
    rows.first["outcome_plan"]["cascade_model"] = certificate
    rows.first["outcome_plan"]["evaluated_frontier"] = frontier
    error = assert_raises(PulseProof::InvariantError) { verify(item) }
    assert_match(/exact objective or lexical tie/, error.message)
  end

  def test_scarcity_coefficient_must_match_visible_stress_evidence
    item = proof
    model(item)["actions"]["vipay"]["local_metrics"]["scarcity_slots"] += 1
    assert_raises(PulseProof::InvariantError) { verify(item) }
  end

  def test_large_weights_are_verified_from_unrounded_model_not_displayed_metrics
    config = planner_policy
    config["outcome_planner"]["weights"] = { "attempts" => 1e16, "count_potential_change" => 1e15 }
    document = Marshal.load(Marshal.dump(providers_document))
    document.fetch("providers").each { |provider| provider["conversion_24h"] = 0.94123456789 }
    item = proof(config: config, document: document)
    row = ranking(item).first.fetch("outcome_plan")
    rounded_product = row.fetch("raw_metrics").sum { |key, value| value * config["outcome_planner"]["weights"].fetch(key, 0) }
    assert_operator (rounded_product - row.fetch("objective")).abs, :>, 1
    assert verify(item)
  end

  def test_displayed_alternative_term_difference_cannot_be_tampered
    item = proof
    explanation = ranking(item).last.fetch("outcome_plan").fetch("alternative_terms_minus_best")
    explanation["count_potential_change"] += 0.000001
    assert_raises(PulseProof::InvariantError) { verify(item) }
  end

  def test_optimization_metadata_cannot_claim_work_not_performed
    changes = [
      ["chains_evaluated", 6], ["all_external_orders_evaluated", true],
      ["method", "full_permutation_search"], ["exact_for_frozen_model", false],
      ["factorial_search_used", true]
    ]
    changes.each do |key, value|
      item = proof
      plan = ranking(item).first.fetch("outcome_plan")
      target = %w[chains_evaluated all_external_orders_evaluated].include?(key) ? plan : plan.fetch("optimization")
      target[key] = value
      error = assert_raises(PulseProof::InvariantError) { verify(item) }
      assert_match(/optimization metadata/, error.message)
    end
  end
end
