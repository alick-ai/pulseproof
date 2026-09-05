# frozen_string_literal: true

require_relative "test_helper"

class AdversarialRuntimeTest < Minitest::Test
  include PulseProofTestData

  def test_timeout_followed_by_approved_is_a_valid_final_result
    model = PulseProof::OutcomeModel.new(scripts: {
      "op_101" => [{ "result" => "expired", "latency_sec" => 181, "resolution" => "approved" }]
    })
    result = runner(model).run
    assert_equal "approved", result.decisions.first["simulated_result"]
    assert_equal 0, result.router.ledger.pending.length
  end

  def test_kopeck_boundary_does_not_reject_legal_payment
    config = providers_document["providers"].first.merge(
      "daily_amount_limit" => 0.3, "daily_approved_amount" => 0.1,
      "limit_amount_min" => nil, "limit_amount_max" => nil
    )
    gate = PulseProof::HardGate.new
    result = gate.evaluate(queue.first.merge("amount" => 0.2), PulseProof::ProviderState.new(config))
    assert result.eligible, result.to_h.inspect
  end

  def test_count_targets_follow_changed_provider_snapshot
    states = provider_states
    controller = PulseProof::DeficitController.new(states, profile)
    controller.accrue!(1000)
    states["vipay"].config["traffic_percentage"] = 10
    states["payflow"].config["traffic_percentage"] = 65
    controller.accrue!(1000)
    assert_in_delta 0.1, controller.snapshot["count_targets"]["vipay"], 0.00001
  end

  def test_repeated_operation_does_not_send_or_accrue_twice
    states = provider_states
    router = PulseProof::Router.new(provider_states: states, profile: profile, metrics: metric_map(states))
    first = router.route(queue.first)
    event_count = router.ledger.event_store.events.length
    assert_equal first, router.route(queue.first)
    assert_equal 1, router.controller.processed_count
    assert_equal event_count, router.ledger.event_store.events.length
  end

  def test_two_pending_attempts_do_not_accept_the_previous_attempts_status
    states = provider_states
    ledger = PulseProof::Ledger.new(states)
    op = queue.first
    ledger.begin_attempt!(op, 1)
    ledger.reserve!(op, "vipay", 1, state_hash: "one")
    ledger.timeout!(op["operation_id"], "vipay", 1, at: op["created_at"], latency_sec: 181)
    ledger.reconcile_timeout!(op["operation_id"], provider_name: "vipay", attempt: 1,
      status: "cancelled", at: op["created_at"], latency_sec: 181, status_event_id: "cancel-one")
    ledger.begin_attempt!(op, 2)
    ledger.reserve!(op, "quickpay", 2, state_hash: "two")
    ledger.timeout!(op["operation_id"], "quickpay", 2, at: op["created_at"], latency_sec: 181)
    result = ledger.reconcile_timeout!(op["operation_id"], provider_name: "vipay", attempt: 1,
      status: "approved", at: op["created_at"], latency_sec: 200, status_event_id: "late-one")
    assert result["ignored"]
    assert_equal "quickpay", ledger.pending[op["operation_id"]]["provider"]
    assert_empty ledger.settlements
    assert_equal 1, states["quickpay"].reserved_count
  end

  def test_altered_report_amount_is_rejected_even_if_count_is_correct
    result = runner.run
    result.report["projected_daily_utilization"]["vipay"]["used"] = 1
    error = assert_raises(PulseProof::InvariantError) do
      PulseProof::StrictValidator.new(queue: queue, providers_document: providers_document,
        decisions: result.decisions, report: result.report).validate!
    end
    assert_match(/amount|utilization|used/, error.message)
  end

  def test_correctly_rehashed_but_illegal_ledger_is_still_rejected
    result = runner.run
    events = result.report.fetch("event_log")
    reservation = events.find { |event| event["type"] == "attempt_reserved" }
    reservation["payload"]["metadata"]["amount"] += 1
    previous = nil
    events.each do |event|
      event["previous_hash"] = previous
      event.delete("event_hash")
      previous = event["event_hash"] = PulseProof::Canonical.digest(event)
    end
    result.report["reconciliation"]["event_head"] = previous
    error = assert_raises(PulseProof::InvariantError) do
      PulseProof::StrictValidator.new(queue: queue, providers_document: providers_document,
        decisions: result.decisions, report: result.report).validate!
    end
    assert_match(/reservation amount mismatch/, error.message)
  end

  def test_same_router_cannot_double_reserve_the_last_daily_capacity
    states = provider_states
    states.each_value { |state| state.config["traffic_percentage"] = state.name == "vipay" ? 100 : 0 }
    states["vipay"].daily_approved_amount = 0
    states["vipay"].config["daily_amount_limit"] = 10000
    entered = Queue.new
    release = Queue.new
    adapter = lambda do |_operation, provider, _attempt|
      if provider.name == "vipay"
        entered << true
        release.pop
      end
      { "result" => "approved", "latency_sec" => 1 }
    end
    router = PulseProof::Router.new(provider_states: states, profile: profile, metrics: metric_map(states), outcome_model: adapter)
    operation = queue.first.merge("amount" => 10000)
    worker = Thread.new { router.route(operation) }
    Timeout.timeout(5) { entered.pop }
    other = router.route(operation.merge("operation_id" => "concurrent"))
    assert_equal "spacepayments", other["selected_provider"]
    release << true
    assert_equal "vipay", Timeout.timeout(5) { worker.value }["selected_provider"]
    assert_equal 10000, states["vipay"].daily_approved_amount
    assert_equal 2, router.ledger.settlements.length
  ensure
    release << true if release
    worker.join(1) if worker
  end
end
