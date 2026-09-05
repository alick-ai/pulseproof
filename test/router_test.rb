# frozen_string_literal: true

require_relative "test_helper"

class RouterTest < Minitest::Test
  include PulseProofTestData

  def test_chaos_timeout_cancel_releases_credit_and_reroutes
    scripts = {
      "op_106" => [
        { "result" => "expired", "latency_sec" => 181, "resolution" => "cancelled" },
        { "result" => "approved", "latency_sec" => 29 }
      ]
    }
    result = runner(PulseProof::OutcomeModel.new(mode: "approve", scripts: scripts)).run
    decision = result.decisions.find { |row| row["operation_id"] == "op_106" }
    selected = decision["attempts"].select { |attempt| attempt["decision"] == "selected" }
    events = result.router.ledger.event_store.events.select { |event| event.dig("payload", "operation_id") == "op_106" }.map { |event| event["type"] }

    assert_equal %w[vipay quickpay], selected.map { |attempt| attempt["provider"] }
    assert_equal %w[expired approved], selected.map { |attempt| attempt["result"] }
    assert_equal "quickpay", decision["selected_provider"]
    assert_includes events, "attempt_timeout"
    assert_includes events, "attempt_cancelled"
    assert_includes events, "attempt_released"
    assert_includes events, "attempt_reroute"
    assert_equal 0, result.report.dig("reconciliation", "pending_count")

    proof = result.router.proofs.fetch("op_106")
    assert_equal 2, proof.fetch("attempt_snapshots").length
    refute_equal proof.dig("attempt_snapshots", 0, "snapshot_hash"), proof.dig("attempt_snapshots", 1, "snapshot_hash")
    assert_equal ["vipay"], proof.dig("attempt_snapshots", 1, "tried_before")
    assert_equal proof.dig("attempt_snapshots", 0, "snapshot_hash"), proof.dig("reservations", 0, "state_hash_before")
    assert_equal proof.dig("attempt_snapshots", 1, "snapshot_hash"), proof.dig("reservations", 1, "state_hash_before")
    before = proof.dig("debt_before_accrual", "unavailable_streak", "payflow")
    after = proof.dig("debt_after", "unavailable_streak", "payflow")
    assert_equal before + 1, after
  end

  def test_unresolved_timeout_keeps_capacity_reserved_without_double_payout
    scripts = {
      "op_101" => [{ "result" => "expired", "latency_sec" => 181 }]
    }
    result = runner(PulseProof::OutcomeModel.new(mode: "approve", scripts: scripts)).run
    decision = result.decisions.find { |row| row["operation_id"] == "op_101" }

    assert_equal "expired", decision["simulated_result"]
    assert_equal 1, result.report.dig("reconciliation", "pending_count")
    assert_equal 1, result.report.dig("reconciliation", "reserved_count")
    assert PulseProof::StrictValidator.new(
      queue: queue,
      providers_document: providers_document,
      decisions: result.decisions,
      report: result.report
    ).validate!
  end

  def test_rejected_fallback_finishes_as_rejected_instead_of_looping
    scripts = {
      "op_101" => Array.new(4) { { "result" => "rejected", "latency_sec" => 1 } }
    }
    result = runner(PulseProof::OutcomeModel.new(mode: "approve", scripts: scripts)).run
    decision = result.decisions.find { |row| row["operation_id"] == "op_101" }

    assert_equal "spacepayments", decision["selected_provider"]
    assert_equal "rejected", decision["simulated_result"]
    assert_equal 4, decision["attempts"].count { |attempt| attempt["decision"] == "selected" }
  end

  def test_concurrent_routes_cannot_reserve_the_same_last_requisite
    providers = [
      provider_config("vipay", available_requisites: 1, priority: 1),
      provider_config("spacepayments", available_requisites: 10, priority: 99)
    ].each_with_object({}) do |config, states|
      state = PulseProof::ProviderState.new(config)
      states[state.name] = state
    end
    profile = self.profile.merge("fallback_provider" => "spacepayments")
    metrics = {
      "vipay" => { "conservative_conversion" => 0.9 },
      "spacepayments" => { "conservative_conversion" => 0.95 }
    }
    slow_approve = Class.new do
      def call(_operation, _provider, _attempt)
        sleep 0.03
        { "result" => "approved", "latency_sec" => 0.03 }
      end
    end.new
    router = PulseProof::Router.new(provider_states: providers, profile: profile, metrics: metrics, outcome_model: slow_approve)
    operations = %w[concurrent_1 concurrent_2].map do |id|
      {
        "operation_id" => id,
        "amount" => 10_000,
        "bank" => "sberbank",
        "created_at" => "2026-07-30T09:00:00+03:00"
      }
    end

    decisions = operations.map { |operation| Thread.new { router.route(operation) } }.map(&:value)

    assert_equal %w[spacepayments vipay], decisions.map { |decision| decision["selected_provider"] }.sort
    assert router.ledger.verify!
  end

  def test_proof_capsule_contains_reasoning_and_no_phone
    result = runner.run
    proof = result.router.proofs.fetch("op_102")
    serialized = JSON.generate(proof)

    assert proof["snapshot_hash"]
    assert_equal "payflow", proof["winner"]
    assert_equal "lower_worst_goal_deviation", proof["winning_factor"]
    assert proof["hard_evaluations"].flatten.any? { |row| row["provider"] == "vipay" && row["reason"] == "bank_not_in_list" }
    refute PulseProof::Redactor.phone_like?(serialized)
    queue.each do |operation|
      phone = operation.dig("payout_requisite", "sbp", "phone")
      refute_includes serialized, phone
    end
  end

  def test_feasibility_envelope_is_post_run_and_matches_public_best
    envelope = PulseProof::FeasibilityEnvelope.new(queue, providers_document).call
    assert_equal true, envelope["exact"]
    assert_equal 10.0, envelope["minimum_l1_deviation_pp"]
    assert_equal({ "vipay" => 4, "payflow" => 3, "quickpay" => 3 }, envelope["optimal_distribution"])
    assert_match(/never used by routing/, envelope["method"])
  end

  private

  def provider_config(name, available_requisites:, priority:)
    {
      "payment_system" => name,
      "status" => "active",
      "traffic_percentage" => name == "vipay" ? 100 : 0,
      "priority" => priority,
      "limit_amount_min" => nil,
      "limit_amount_max" => nil,
      "daily_amount_limit" => nil,
      "daily_approved_amount" => 0,
      "in_progress_count_limit" => nil,
      "in_progress_count" => 0,
      "in_progress_amount_limit" => nil,
      "in_progress_amount" => 0,
      "available_requisites" => available_requisites,
      "conversion_24h" => 0.9,
      "avg_latency_sec" => 1,
      "banks" => [],
      "exclude_banks" => false,
      "provider_margin_pct" => 1.0,
      "merchant_margin_pct" => 1.5,
      "allow_negative_agreement" => false
    }
  end
end
