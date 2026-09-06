# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/pulseproof/capacity_explanation"

class CapacityExplanationTest < Minitest::Test
  def provider(overrides = {})
    {
      "payment_system" => "alpha", "status" => "active", "traffic_percentage" => 60,
      "daily_approved_amount" => 0, "available_requisites" => 1,
      "in_progress_count" => 0, "in_progress_amount" => 0,
      "provider_margin_pct" => 0, "merchant_margin_pct" => 1
    }.merge(overrides)
  end

  def queue(amounts)
    amounts.each_with_index.map do |amount, index|
      { "operation_id" => "sample_#{index}", "amount" => amount, "bank" => "bank_a",
        "created_at" => "2026-07-30T10:00:00+03:00", "payout_requisite" => { "phone" => "+79991234567" } }
    end
  end

  def decisions(operations, selected = [])
    operations.each_with_index.map do |operation, index|
      name = selected.include?(index) ? "alpha" : "fallback"
      { "operation_id" => operation.fetch("operation_id"), "selected_provider" => name,
        "simulated_result" => "approved",
        "attempts" => [{ "provider" => name, "decision" => "selected", "result" => "approved" }] }
    end
  end

  def analyze(operations, config = provider, selected: [], results: nil, unchanged: true)
    document = { "snapshot_at" => "2026-07-30T09:00:00+03:00",
      "providers" => [config, provider("payment_system" => "fallback", "traffic_percentage" => 0)] }
    PulseProof::CapacityExplanation.new(queue: operations, decisions: results || decisions(operations, selected),
      providers_document: document, fallback_provider: "fallback", snapshot_unchanged: unchanged).build
  end

  def test_daily_budget_uses_exact_cheapest_sum_witness
    operations = queue([15, 5, 20, 10])
    result = analyze(operations, provider("daily_amount_limit" => 125, "daily_approved_amount" => 100), selected: [0, 1])
    assert_equal "explained", result["status"]
    row = result.fetch("providers").fetch("alpha")
    assert_equal 4, row["relaxed_eligible_operations"]
    assert_equal 2, row["individual_count_upper_bound"]
    assert_equal 2.4, row["target_operation_count"]
    assert row["target_exceeds_individual_upper_bound"]
    assert_equal 25.0, row["initial_remaining_daily_amount"]
    assert_equal 20.0, row["allocated_queue_amount"]
    assert_equal 80.0, row["initial_daily_budget_used_pct"]
    witness = row.fetch("daily_budget_witness")
    assert_equal 1500, witness["cheapest_feasible_sum_cents"]
    assert_equal 3000, witness["next_cheapest_sum_cents"]
    assert witness["next_count_exceeds_daily_budget"]
    refute result.dig("scope", "joint_optimum_certified")
    refute result.dig("scope", "individual_ceiling_attainability_certified")
    refute result.dig("scope", "changes_routing")
  end

  def test_cents_do_not_lose_a_payment_to_binary_float_rounding
    operations = queue([0.1, 0.2, 0.01])
    row = analyze(operations, provider("daily_amount_limit" => 1.3, "daily_approved_amount" => 1), selected: [0, 1]).dig("providers", "alpha")
    assert_equal 2, row["individual_count_upper_bound"]
    assert_equal 30, row.dig("daily_budget_witness", "initial_remaining_cents")
    assert_equal 31, row.dig("daily_budget_witness", "next_cheapest_sum_cents")
    assert_equal 100.0, row["initial_daily_budget_used_pct"]
  end

  def test_initial_transient_load_and_rpm_do_not_create_false_permanent_exclusions
    config = provider("in_progress_count" => 3, "in_progress_count_limit" => 3,
      "in_progress_amount" => 999, "in_progress_amount_limit" => 1000,
      "requests_per_minute_limit" => 1, "daily_amount_limit" => 20)
    row = analyze(queue([5, 5, 5]), config).dig("providers", "alpha")
    assert_equal 3, row["relaxed_eligible_operations"]
    assert_equal 3, row["individual_count_upper_bound"]
    assert_equal 20.0, row["initial_remaining_daily_amount"]
  end

  def test_per_attempt_amount_bank_margin_and_disabled_traffic_remain_hard_constraints
    operations = queue([4, 10, 16])
    row = analyze(operations, provider("limit_amount_min" => 5, "limit_amount_max" => 15)).dig("providers", "alpha")
    assert_equal 1, row["individual_count_upper_bound"]
    [provider("banks" => ["bank_b"]), provider("status" => "inactive"), provider("traffic_percentage" => 0),
      provider("provider_margin_pct" => 2), provider("available_requisites" => 0),
      provider("in_progress_amount_limit" => 3), provider("in_progress_count_limit" => 0)].each do |config|
      assert_equal 0, analyze(operations, config).dig("providers", "alpha", "individual_count_upper_bound")
    end
  end

  def test_unlimited_daily_budget_is_not_reported_as_zero
    row = analyze(queue([10, 20]), selected: [0, 1]).dig("providers", "alpha")
    assert_equal 2, row["individual_count_upper_bound"]
    assert_nil row["initial_remaining_daily_amount"]
    assert_nil row["initial_daily_budget_used_pct"]
    assert_nil row.dig("daily_budget_witness", "next_cheapest_sum_cents")
    assert_equal 100.0, row["selected_count_to_individual_ceiling_pct"]
  end

  def test_zero_remaining_budget_has_no_fake_utilization_ratio
    row = analyze(queue([1]), provider("daily_amount_limit" => 10, "daily_approved_amount" => 10)).dig("providers", "alpha")
    assert_equal 0, row["individual_count_upper_bound"]
    assert_equal 0, row.dig("daily_budget_witness", "cheapest_feasible_sum_cents")
    assert_nil row["initial_daily_budget_used_pct"]
    assert_nil row["selected_count_to_individual_ceiling_pct"]
  end

  def test_empty_changed_snapshots_and_day_changes_do_not_emit_ceilings
    assert_equal "empty", analyze([])["status"]
    changed = analyze(queue([1]), unchanged: false)
    assert_equal "provider_snapshot_changed", changed["reason"]
    assert_empty changed["providers"]
    operations = queue([1])
    operations.first["created_at"] = "2026-07-31T00:01:00+03:00"
    assert_equal "multiple_snapshot_days", analyze(operations)["reason"]
  end

  def test_missing_malformed_and_wrong_type_snapshot_times_refuse_without_crashing
    operations = queue([1])
    [nil, "not-a-time", 123, {}].each do |snapshot|
      document = { "providers" => [provider, provider("payment_system" => "fallback", "traffic_percentage" => 0)] }
      document["snapshot_at"] = snapshot unless snapshot.nil?
      result = PulseProof::CapacityExplanation.new(queue: operations, decisions: decisions(operations),
        providers_document: document, fallback_provider: "fallback").build
      assert_equal "not_applicable", result["status"]
      assert_equal "missing_or_invalid_snapshot_time", result["reason"]
      assert_empty result["providers"]
    end
  end

  def test_pending_declines_prior_failures_and_incomplete_coverage_are_not_certified
    operations = queue([1, 2])
    %w[expired declined pending].each do |outcome|
      results = decisions(operations)
      results.first["attempts"].first["result"] = outcome
      result = analyze(operations, results: results)
      assert_equal "pending_or_failed_attempts_present", result["reason"]
      assert_empty result["providers"]
    end
    results = decisions(operations)
    results.first["attempts"].unshift({ "provider" => "alpha", "decision" => "selected", "result" => "declined" })
    assert_equal "pending_or_failed_attempts_present", analyze(operations, results: results)["reason"]
    assert_equal "queue_and_decisions_do_not_match", analyze(operations, results: results.take(1))["reason"]
  end

  def test_invalid_assignment_cannot_be_wrapped_in_an_explanation
    result = analyze(queue([20]), provider("daily_amount_limit" => 10), selected: [0])
    assert_equal "observed_assignment_outside_relaxation", result["reason"]
    assert_empty result["providers"]
  end

  def test_small_exhaustive_subsets_never_exceed_individual_ceiling
    amounts = [1, 3, 4, 7]
    operations = queue(amounts)
    (0..16).each do |budget|
      ceiling = analyze(operations, provider("daily_amount_limit" => budget)).dig("providers", "alpha", "individual_count_upper_bound")
      feasible = (0...(1 << amounts.length)).map do |mask|
        chosen = amounts.each_with_index.select { |_amount, index| mask[index] == 1 }.map(&:first)
        chosen.length if chosen.sum <= budget
      end.compact
      assert_equal feasible.max, ceiling
    end
  end

  def test_output_contains_neither_operation_identifiers_nor_requisites_and_preserves_input
    operations = queue([10, 20])
    config = provider
    before = Marshal.dump([operations, config])
    result = analyze(operations, config)
    assert_equal before, Marshal.dump([operations, config])
    encoded = JSON.generate(result)
    refute_includes encoded, "sample_0"
    refute_includes encoded, "+79991234567"
    refute_includes encoded, "payout_requisite"
    assert_equal result, analyze(operations, config)
  end
end
