# frozen_string_literal: true

require_relative "test_helper"

class LedgerTest < Minitest::Test
  include PulseProofTestData

  def setup
    @states = provider_states
    @ledger = PulseProof::Ledger.new(@states)
    @operation = queue.first
  end

  def test_timeout_holds_reservation_until_cancel_and_duplicate_is_idempotent
    @ledger.begin_attempt!(@operation, 1)
    @ledger.reserve!(@operation, "vipay", 1, state_hash: "before")
    @ledger.timeout!(@operation["operation_id"], "vipay", 1, at: @operation["created_at"], latency_sec: 181)

    assert_equal 1, @states.fetch("vipay").reserved_count
    assert @ledger.pending.key?(@operation["operation_id"])

    @ledger.reconcile_timeout!(
      @operation["operation_id"], provider_name: "vipay", attempt: 1, status: "cancelled", at: @operation["created_at"], latency_sec: 181, status_event_id: "status-1"
    )
    assert_equal 0, @states.fetch("vipay").reserved_count
    refute @ledger.pending.key?(@operation["operation_id"])

    duplicate = @ledger.reconcile_timeout!(
      @operation["operation_id"], provider_name: "vipay", attempt: 1, status: "cancelled", at: @operation["created_at"], latency_sec: 181, status_event_id: "status-1"
    )
    assert_equal true, duplicate["duplicate"]
    assert @ledger.verify!
  end

  def test_stale_late_approved_event_cannot_create_a_second_settlement
    @ledger.begin_attempt!(@operation, 1)
    @ledger.reserve!(@operation, "vipay", 1, state_hash: "before")
    @ledger.timeout!(@operation["operation_id"], "vipay", 1, at: @operation["created_at"], latency_sec: 181)
    @ledger.reconcile_timeout!(
      @operation["operation_id"], provider_name: "vipay", attempt: 1, status: "cancelled", at: @operation["created_at"], latency_sec: 181, status_event_id: "cancel-1"
    )

    @ledger.begin_attempt!(@operation, 2)
    @ledger.reserve!(@operation, "quickpay", 2, state_hash: "after-cancel")
    @ledger.approve!(@operation["operation_id"], "quickpay", 2, at: @operation["created_at"], latency_sec: 29)
    ignored = @ledger.reconcile_timeout!(
      @operation["operation_id"], provider_name: "vipay", attempt: 1, status: "approved", at: @operation["created_at"], latency_sec: 210, status_event_id: "late-approved-1"
    )

    assert_equal true, ignored["ignored"]
    assert_equal "quickpay", @ledger.settlements.fetch(@operation["operation_id"])["provider"]
    assert_equal 1, @ledger.settlements.length
    assert @ledger.verify!
  end

  def test_illegal_state_transition_is_rejected
    assert_raises(PulseProof::TransitionError) do
      @ledger.machine.transition!(operation_id: "bad", attempt: 1, to: "approved", at: "now")
    end
  end

  def test_operation_event_index_matches_the_chain
    @ledger.begin_attempt!(@operation, 1)
    @ledger.reserve!(@operation, "vipay", 1, state_hash: "snapshot")
    @ledger.approve!(@operation["operation_id"], "vipay", 1, at: @operation["created_at"], latency_sec: 1)

    indexed = @ledger.event_store.for_operation(@operation["operation_id"])
    assert_equal @ledger.event_store.events, indexed
    assert @ledger.verify_current!
  end

  def test_routing_snapshot_is_compact_and_excludes_settlement_history
    @ledger.begin_attempt!(@operation, 1)
    @ledger.reserve!(@operation, "vipay", 1, state_hash: "snapshot")
    @ledger.approve!(@operation["operation_id"], "vipay", 1, at: @operation["created_at"], latency_sec: 1)

    snapshot = @ledger.routing_snapshot
    assert_equal 1, snapshot["settled_count"]
    refute snapshot.key?("settlements")
    assert_empty snapshot["pending"]
  end
end
