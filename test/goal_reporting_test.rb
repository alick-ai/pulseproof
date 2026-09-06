# frozen_string_literal: true

require_relative "test_helper"

class GoalReportingTest < Minitest::Test
  include PulseProofTestData

  def test_absent_volume_target_explains_null_without_inventing_a_goal
    report = runner.run.report
    status = report.fetch("volume_goal_status")
    assert_equal "disabled_no_positive_targets", status["status"]
    assert_equal 0.8, status["controller_weight"]
    assert_empty status["configured_external_targets"]
    assert_empty status["effective_controller_targets_pct"]
    assert_equal "soft_volume", status.dig("capability_example", "causal_evidence_case")
    assert File.file?(File.join(ROOT, status.dig("capability_example", "profile")))
    row = report.dig("volume_distribution", "vipay")
    assert_equal 26.44, row["share_pct"]
    assert_nil row["target_pct"]
    assert_nil row["deviation_pp"]
    assert_equal "volume_target_not_provided", row["null_reason"]
    assert_nil report.dig("soft_goal_analysis", "raw_volume_target_deviation_l1_pp")
  end

  def test_demo_is_balanced_with_only_illustrative_volume_targets_added
    configured = PulseProof::InputLoader.json(File.join(ROOT, "config/volume_demo.json"))
    assert_equal profile.reject { |key, _| key == "profile" },
      configured.reject { |key, _| %w[profile description volume_targets].include?(key) }
    example = run_session(configured)
    baseline = runner.run
    assert_equal "configured", example.dig("volume_goal_status", "status")
    assert_equal 25.0, example.dig("volume_distribution", "vipay", "target_pct")
    refute_nil example.dig("volume_distribution", "vipay", "deviation_pp")
    refute_equal baseline.decisions.map { |row| row["selected_provider"] },
      @session.decisions.values.map { |row| row["selected_provider"] }
  end

  def test_provider_targets_are_normalized_and_report_their_source
    document = Marshal.load(Marshal.dump(providers_document))
    document["providers"].each do |provider|
      provider["volume_share_pct"] = { "vipay" => 20, "payflow" => 10, "quickpay" => 10, "spacepayments" => 100 }.fetch(provider["payment_system"])
    end
    report = run_session(profile, document: document)
    row = report.dig("volume_distribution", "vipay")
    assert_equal 20, row["configured_target_pct"]
    assert_equal 50.0, row["target_pct"]
    assert_equal "providers.volume_share_pct", row["target_source"]
    assert_in_delta row["share_pct"] - 50.0, row["deviation_pp"], 0.01
    assert_nil report.dig("volume_distribution", "spacepayments", "target_pct")
    assert_equal "fallback_excluded_from_soft_targets", report.dig("volume_distribution", "spacepayments", "null_reason")
  end

  def test_partial_profile_override_does_not_fall_back_to_provider_targets
    document = Marshal.load(Marshal.dump(providers_document))
    document["providers"].each { |provider| provider["volume_share_pct"] = 40 }
    report = run_session(profile.merge("volume_targets" => { "payflow" => 30 }), document: document)
    assert_equal 100.0, report.dig("volume_distribution", "payflow", "target_pct")
    assert_equal 0.0, report.dig("volume_distribution", "vipay", "target_pct")
    assert_equal "profile.volume_targets", report.dig("volume_distribution", "vipay", "target_source")
    assert_equal 0, report.dig("volume_distribution", "vipay", "configured_target_pct")
  end

  def test_empty_and_zero_overrides_explicitly_disable_volume_goal
    document = Marshal.load(Marshal.dump(providers_document))
    document["providers"].each { |provider| provider["volume_share_pct"] = 40 }
    [{}, { "vipay" => 0, "payflow" => 0 }, { "spacepayments" => 100 }].each do |targets|
      report = run_session(profile.merge("volume_targets" => targets), document: document)
      assert_equal "disabled_no_positive_targets", report.dig("volume_goal_status", "status")
      assert_nil report.dig("volume_distribution", "vipay", "target_pct")
      assert_nil report.dig("soft_goal_analysis", "raw_volume_target_deviation_l1_pp")
      assert_equal "no_positive_external_volume_targets", report.dig("volume_distribution", "vipay", "null_reason")
    end
  end

  def test_runtime_targets_refer_to_the_snapshot_used_for_routing
    run_session(profile)
    @session.process("type" => "provider_update", "provider" => "vipay", "at" => "2026-07-30T10:00:00+03:00",
      "changes" => { "volume_share_pct" => 25 })
    assert_nil @session.report.dig("volume_distribution", "vipay", "target_pct")
    assert_empty @session.report.dig("volume_goal_status", "configured_external_targets")
    @session.process("type" => "operation", "operation" => operation("new-target", 60))
    assert_equal 100.0, @session.report.dig("volume_distribution", "vipay", "target_pct")
    assert_equal 25, @session.report.dig("volume_distribution", "vipay", "configured_target_pct")
  end

  def test_public_report_distinguishes_a_recovery_flag_from_an_actual_cap_reduction
    report = runner.run.report
    summary = report.fetch("unavailable_goal_handling")
    assert_equal false, summary["redistribute_unavailable"]
    payflow = summary.dig("providers", "payflow")
    assert_equal 6, payflow["ineligible_operations"]
    assert_equal({ "bank_not_in_list" => 4, "amount_exceeds_limit" => 2 }, payflow["reason_counts"])
    assert_equal 2, payflow["recovery_entries"]
    assert_equal 2, payflow["recovery_rankings"]
    assert_equal 1, payflow["recovery_cap_reductions"]
    first, second = payflow.fetch("recovery_examples")
    assert_equal "op_107", first["operation_id"]
    assert_equal false, first["cap_reduced_debt"]
    assert_equal "op_110", second["operation_id"]
    assert_equal 1.5, second["count_debt_before"]
    assert_equal 0.25, second["effective_count_debt"]
    assert_equal true, second["cap_reduced_debt"]
    assert_equal true, second["selected_on_attempt"]
    assert_equal report.dig("distribution", "payflow"), payflow["final_distribution"]
    assert_in_delta 2.1, payflow["business_count_entitlement_while_ineligible"], 1e-8
  end

  def test_real_inactivity_preserves_raw_debt_and_records_bounded_recovery
    document = Marshal.load(Marshal.dump(providers_document))
    document["providers"].find { |p| p["payment_system"] == "vipay" }["status"] = "inactive"
    run_session(profile, document: document, operations: (0...15).map { |i| operation("inactive-#{i}", i) })
    row = @session.report.dig("unavailable_goal_handling", "providers", "vipay")
    assert_equal 15, row["reason_counts"]["provider_inactive"]
    assert_equal 3, row["exclusion_examples"].length
    assert_in_delta 6.0, row["final_raw_count_debt"], 1e-8
    assert_equal 4.0, row["final_bounded_count_debt"]
    assert_equal 0, row["recovery_entries"]
    @session.process("type" => "provider_update", "provider" => "vipay", "at" => "2026-07-30T10:00:00+03:00",
      "changes" => { "status" => "active" })
    @session.process("type" => "operation", "operation" => operation("recovered", 61))
    row = @session.report.dig("unavailable_goal_handling", "providers", "vipay")
    assert_equal 1, row["recovery_entries"]
    assert_equal 1, row["recovery_cap_reductions"]
    assert_operator row["recovery_examples"].first["effective_count_debt"], :<, 4.0
  end

  def test_opt_in_redistribution_keeps_original_business_debt_visible
    document = Marshal.load(Marshal.dump(providers_document))
    document["providers"].find { |p| p["payment_system"] == "vipay" }["status"] = "inactive"
    report = run_session(profile.merge("redistribute_unavailable" => true), document: document,
      operations: (0...5).map { |i| operation("redistribute-#{i}", i) })
    assert_equal true, report.dig("unavailable_goal_handling", "redistribute_unavailable")
    row = report.dig("unavailable_goal_handling", "providers", "vipay")
    assert_in_delta 2.0, row["final_raw_count_debt"], 1e-8
    assert_equal 0.0, row["final_bounded_count_debt"]
    assert_in_delta 2.0, row["business_count_entitlement_while_ineligible"], 1e-8
    assert_equal(-40.0, row.dig("final_distribution", "deviation_pp"))
  end

  def test_cascades_do_not_multiply_first_operation_exclusions
    result = runner(PulseProof::OutcomeModel.new(scripts: { "op_103" => ["rejected", "approved"] })).run
    row = result.report.dig("unavailable_goal_handling", "providers", "vipay")
    assert_equal 6, row["ineligible_operations"]
    assert_equal 1, row["final_selected_provider_counts_after_exclusion"]["spacepayments"]
    assert_equal "spacepayments", row["exclusion_examples"].find { |e| e["operation_id"] == "op_103" }["final_selected_provider"]
    assert_equal 1, result.report.dig("unavailable_goal_handling", "providers", "quickpay", "ineligible_operations")
  end

  def test_empty_queue_has_no_manufactured_unavailability_or_recovery
    report = run_session(profile, operations: [])
    assert_equal 0, report.dig("unavailable_goal_handling", "evaluated_operations")
    report.dig("unavailable_goal_handling", "providers").each_value do |row|
      assert_equal 0, row["ineligible_operations"]
      assert_equal 0, row["recovery_entries"]
      assert_equal 0, row["recovery_cap_reductions"]
      assert_empty row["exclusion_examples"]
    end
  end

  def test_building_goal_summaries_does_not_mutate_routing_state
    run_session(profile)
    before = PulseProof::Canonical.digest([@session.router.controller.snapshot, @session.router.proofs,
      @session.router.ledger.event_store.events, @session.decisions])
    first = @session.report
    second = @session.report
    assert_equal first, second
    assert_equal before, PulseProof::Canonical.digest([@session.router.controller.snapshot, @session.router.proofs,
      @session.router.ledger.event_store.events, @session.decisions])
  end

  private

  def run_session(configured, document: providers_document, operations: queue)
    @session = PulseProof::RuntimeSession.new(providers_document: document, profile: configured, history: history)
    operations.each { |op| @session.process("type" => "operation", "operation" => op) }
    @session.process("type" => "report").fetch("report")
  end

  def operation(id, minute)
    queue.first.merge("operation_id" => id, "amount" => 1000, "bank" => "sberbank",
      "created_at" => (Time.iso8601("2026-07-30T09:00:00+03:00") + minute * 60).iso8601)
  end
end
