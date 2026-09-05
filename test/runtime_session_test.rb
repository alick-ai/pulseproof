# frozen_string_literal: true

require_relative "test_helper"
require "open3"

class RuntimeSessionTest < Minitest::Test
  include PulseProofTestData

  def session(scripts = {})
    @session ||= PulseProof::RuntimeSession.new(providers_document: providers_document,
      profile: profile.merge("selection_mode" => "cascade"), history: history,
      outcome_model: PulseProof::OutcomeModel.new(scripts: scripts))
  end

  def op(id, at)
    queue.first.merge("operation_id" => id, "amount" => 10000, "bank" => "sberbank", "created_at" => at)
  end

  def submit(operation)
    session.process("type" => "operation", "operation" => operation).fetch("decision")
  end

  def status(id, provider, attempt, result, event_id)
    session.process("type" => "status", "operation_id" => id, "provider" => provider,
      "attempt" => attempt, "status" => result, "event_id" => event_id, "at" => "2026-07-30T09:10:00+03:00").fetch("result")
  end

  def test_late_cancel_continues_only_its_operation_on_current_rules
    session("runtime_a" => [{ "result" => "expired", "latency_sec" => 181 }])
    a = op("runtime_a", "2026-07-30T09:01:00+03:00")
    first = submit(a)
    b = submit(op("runtime_b", "2026-07-30T09:05:00+03:00"))
    untouched = PulseProof::Canonical.digest(session.router.proofs.fetch("runtime_b"))
    assert_equal "expired", first["simulated_result"]
    assert_equal "approved", b["simulated_result"]
    session.process("type" => "provider_update", "provider" => "payflow",
      "changes" => { "status" => "inactive" }, "at" => "2026-07-30T09:06:00+03:00")
    result = status("runtime_a", "vipay", 1, "cancelled", "cancel-a")
    assert_equal "quickpay", result["selected_provider"]
    assert_equal "approved", result["simulated_result"]
    assert_equal untouched, PulseProof::Canonical.digest(session.router.proofs.fetch("runtime_b"))
    assert_equal 2, session.router.controller.processed_count
    assert_equal 2, session.router.ledger.settlements.length
    assert_empty session.router.ledger.pending
    assert_equal result, submit(a)
    assert status("runtime_a", "vipay", 1, "cancelled", "cancel-a")["duplicate"]
    report = session.report
    assert_equal 2, report["reconciliation"]["settled_count"]
    assert_equal false, report.dig("soft_goal_analysis", "post_run_feasibility_envelope", "exact")
  end

  def test_stale_approval_cannot_steal_another_attempts_reserve
    session("runtime_a" => ["expired", "expired"])
    submit(op("runtime_a", "2026-07-30T09:01:00+03:00"))
    next_result = status("runtime_a", "vipay", 1, "cancelled", "cancel-a")
    next_provider = next_result["selected_provider"]
    assert_equal "expired", next_result["simulated_result"]
    assert status("runtime_a", "vipay", 1, "approved", "stale-a")["ignored"]
    assert_equal next_provider, session.router.ledger.pending["runtime_a"]["provider"]
    assert_equal 1, session.report.dig("reconciliation", "pending_count")
    status("runtime_a", next_provider, 2, "approved", "approve-a2")
    assert_equal 1, session.report.dig("reconciliation", "settled_count")
  end

  def test_operation_id_reuse_with_new_amount_is_rejected_without_mutation
    operation = op("idempotent", "2026-07-30T09:01:00+03:00")
    submit(operation)
    before = session.router.ledger.event_store.events.length
    assert_raises(PulseProof::InputError) { submit(operation.merge("amount" => 20000)) }
    assert_equal before, session.router.ledger.event_store.events.length
    assert_equal 1, session.router.controller.processed_count
  end

  def test_transport_timeout_keeps_reservation_and_does_not_send_cascade
    calls = 0
    adapter = lambda do |*_args|
      calls += 1
      raise Timeout::Error, "no response"
    end
    @session = PulseProof::RuntimeSession.new(providers_document: providers_document, profile: profile,
      history: history, outcome_model: adapter)
    result = submit(op("network_timeout", "2026-07-30T09:01:00+03:00"))
    assert_equal "expired", result["simulated_result"]
    assert_equal 1, calls
    assert_equal 1, session.report.dig("reconciliation", "reserved_count")
  end

  def test_updated_conversion_and_targets_are_in_the_next_attempt_snapshot
    submit(op("before", "2026-07-30T09:01:00+03:00"))
    session.process("type" => "provider_update", "provider" => "vipay", "at" => "2026-07-30T09:03:00+03:00",
      "changes" => { "conversion_24h" => 0.1, "traffic_percentage" => 10 })
    session.process("type" => "provider_update", "provider" => "payflow", "at" => "2026-07-30T09:03:00+03:00",
      "changes" => { "traffic_percentage" => 65 })
    submit(op("after", "2026-07-30T09:05:00+03:00"))
    snapshot = session.router.proofs.fetch("after")["attempt_snapshots"].first["snapshot"]
    assert_equal 0.1, snapshot["metrics"]["vipay"]["snapshot_conversion"]
    assert_in_delta 0.1, snapshot["controller"]["count_targets"]["vipay"], 0.000001
    assert session.report
  end

  def test_stream_command_reads_one_event_per_line_without_a_queue_file
    event = { "type" => "operation", "operation" => op("cli", "2026-07-30T09:01:00+03:00") }
    output, warning, status = Open3.capture3("ruby", File.join(PulseProofTestData::ROOT, "bin/pulseproof"),
      "stream", "--queue", "/does/not/exist.json", stdin_data: JSON.generate(event) + "\n")
    assert status.success?, warning
    assert_equal "cli", JSON.parse(output).dig("decision", "operation_id")
    assert_match(/no external payout calls/, warning)
  end
end
