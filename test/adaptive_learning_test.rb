# frozen_string_literal: true

require_relative "test_helper"

class AdaptiveLearningTest < Minitest::Test
  include PulseProofTestData

  def settings
    PulseProof::InputLoader.json(File.join(PulseProofTestData::ROOT, "config/adaptive.json"))
  end

  def op(id = "learn", bank: "sberbank", amount: 2000, second: 0)
    { "operation_id" => id, "bank" => bank, "amount" => amount,
      "created_at" => (Time.iso8601(providers_document["snapshot_at"]) + second).iso8601 }
  end

  def model(history_rows = [])
    @model ||= PulseProof::AdaptiveLearning.new(providers: provider_states, history: history_rows,
      config: settings["adaptive_learning"], as_of: providers_document["snapshot_at"])
  end

  def estimate(operation, provider = "vipay")
    model.estimate(provider, operation, at: Time.iso8601(operation["created_at"]))
  end

  def test_bad_bank_context_does_not_contaminate_other_banks_or_amount_bands
    initial = estimate(op)
    12.times { |i| model.observe(operation: op("bad#{i}"), provider_name: "vipay", attempt: 1, status: "rejected", at: op["created_at"]) }
    assert_operator estimate(op)["mean"], :<, initial["mean"] - 0.3
    assert_equal initial["mean"], estimate(op(bank: "tinkoff"))["mean"]
    assert_equal initial["mean"], estimate(op(amount: 80000))["mean"]
    assert_operator estimate(op)["effective_samples"], :>=, 12
  end

  def test_unknown_timeout_is_not_a_negative_training_label
    assert_nil model.observe(operation: op, provider_name: "vipay", attempt: 1, status: "expired", at: op["created_at"])
    assert_equal 0, model.observed_count
    assert_equal 0, estimate(op)["effective_samples"]
  end

  def test_degradation_requires_evidence_not_one_failure
    model.observe(operation: op("first"), provider_name: "vipay", attempt: 1, status: "rejected", at: op["created_at"])
    refute estimate(op)["degradation_signal"]
    11.times { |i| model.observe(operation: op("more#{i}"), provider_name: "vipay", attempt: 1, status: "rejected", at: op["created_at"]) }
    assert estimate(op)["degradation_signal"]
    refute estimate(op(bank: "alfa"))["degradation_signal"]
  end

  def test_cascade_learning_waits_for_cumulative_response_time
    adapter = lambda do |_operation, _provider, attempt|
      { "result" => attempt == 1 ? "rejected" : "approved", "latency_sec" => attempt == 1 ? 3 : 4 }
    end
    session = PulseProof::RuntimeSession.new(providers_document: providers_document, profile: settings, history: [], outcome_model: adapter)
    decision = session.process("type" => "operation", "operation" => op)["decision"]
    provider = decision["selected_provider"]
    learner = session.router.adaptive_learning
    assert_equal 0, learner.estimate(provider, op, at: Time.iso8601(op(second: 5)["created_at"]))["effective_samples"]
    assert_equal 1, learner.estimate(provider, op, at: Time.iso8601(op(second: 7)["created_at"]))["effective_samples"]
    assert session.report
  end

  def test_terminal_observation_is_idempotent_and_conflicts_are_rejected
    model.observe(operation: op, provider_name: "vipay", attempt: 1, status: "approved", at: op["created_at"])
    assert_nil model.observe(operation: op, provider_name: "vipay", attempt: 1, status: "approved", at: op["created_at"])
    assert_equal 1, model.observed_count
    assert_raises(PulseProof::InvariantError) { model.observe(operation: op, provider_name: "vipay", attempt: 1, status: "rejected", at: op["created_at"]) }
  end

  def test_stale_evidence_decays_and_uncertainty_increases
    20.times { |i| model.observe(operation: op("yes#{i}"), provider_name: "vipay", attempt: 1, status: "approved", at: op["created_at"]) }
    fresh = estimate(op)
    stale = estimate(op(second: 1200))
    assert_operator stale["effective_samples"], :<, fresh["effective_samples"]
    assert_operator stale["uncertainty_sd"], :>, fresh["uncertainty_sd"]
  end

  def test_future_history_and_unresolved_history_are_not_used
    rows = [op.merge("payment_system" => "vipay", "status" => "expired", "latency_sec" => 0),
            op(second: 1).merge("payment_system" => "vipay", "status" => "approved", "latency_sec" => -2),
            op(second: 3600).merge("payment_system" => "vipay", "status" => "approved", "latency_sec" => 0)]
    learner = model(rows)
    assert_equal 0, learner.estimate("vipay", op, at: Time.iso8601(op["created_at"]))["effective_samples"]
  end

  def test_observation_is_not_used_before_its_response_timestamp
    model.observe(operation: op, provider_name: "vipay", attempt: 1, status: "rejected", at: op(second: 20)["created_at"])
    assert_equal 0, estimate(op(second: 10))["effective_samples"]
    assert_equal 1, estimate(op(second: 20))["effective_samples"]
  end

  def test_router_learns_only_when_pending_status_is_confirmed_once
    selected = nil
    adapter = lambda do |_operation, provider, _attempt|
      selected = provider.name
      { "result" => "expired", "latency_sec" => 181 }
    end
    session = PulseProof::RuntimeSession.new(providers_document: providers_document, profile: settings, history: [], outcome_model: adapter)
    session.process("type" => "operation", "operation" => op)
    assert_equal 0, session.router.adaptive_learning.observed_count
    event = { "type" => "status", "operation_id" => "learn", "provider" => selected, "attempt" => 1,
      "status" => "approved", "at" => op(second: 200)["created_at"], "event_id" => "confirmed" }
    session.process(event)
    session.process(event)
    assert_equal 1, session.router.adaptive_learning.observed_count
    assert_equal 1, session.router.ledger.event_store.events.count { |e| e["type"] == "learning_observed" }
    assert session.report
  end

  def test_probe_is_bounded_small_and_does_not_ignore_primary_goal_budget
    settings = self.settings["adaptive_learning"].merge("probe_every" => 2)
    learner = PulseProof::AdaptiveLearning.new(providers: provider_states, history: [], config: settings)
    ranking = ["vipay", "quickpay"].map { |name| { "provider" => name, "primary_regret" => 0.1, "adaptive_prediction" => { "last_confirmed_at" => nil, "degradation_signal" => true } } }
    assert_equal "vipay", learner.probe(Marshal.load(Marshal.dump(ranking)), operation: op, attempt: 1, providers: provider_states).first["provider"]
    assert_equal "quickpay", learner.probe(Marshal.load(Marshal.dump(ranking)), operation: op("second"), attempt: 1, providers: provider_states).first["provider"]
    2.times { learner.probe(Marshal.load(Marshal.dump(ranking)), operation: op(amount: 80000), attempt: 1, providers: provider_states) }
    assert_equal 1, learner.probe_count
    ranking.last["primary_regret"] = 0.9
    2.times { learner.probe(Marshal.load(Marshal.dump(ranking)), operation: op, attempt: 1, providers: provider_states) }
    assert_equal 1, learner.probe_count
  end

  def test_runtime_changes_its_choice_from_confirmed_context_feedback
    policy = settings.merge("adaptive_learning" => settings["adaptive_learning"].merge("probe_every" => 0))
    adapter = lambda do |_operation, provider, _attempt|
      { "result" => provider.name == "payflow" ? "rejected" : "approved", "latency_sec" => 1 }
    end
    session = PulseProof::RuntimeSession.new(providers_document: providers_document, profile: policy, history: [], outcome_model: adapter)
    first_choices = 30.times.map do |i|
      decision = session.process("type" => "operation", "operation" => op("online#{i}", bank: "alfa", second: i * 5))["decision"]
      decision["attempts"].find { |a| a["decision"] == "selected" }["provider"]
    end
    assert_equal "payflow", first_choices.first
    assert_operator first_choices.last(5).count("payflow"), :<, first_choices.first(5).count("payflow")
    report = session.report
    assert_operator report.dig("adaptive_learning", "observed_terminal_attempts"), :>=, 12
    assert session.router.proofs["online11"]["candidate_rankings"].first.first["adaptive_prediction"]
  end

  def test_audit_rejects_a_learning_label_without_confirmed_attempt
    event = { "type" => "learning_observed", "payload" => {
      "operation_id" => "learn", "provider" => "vipay", "attempt" => 1, "reward" => 1 } }
    replay = PulseProof::AuditReplay.new(queue: [op], providers_document: providers_document, fallback_provider: "spacepayments")
    error = assert_raises(PulseProof::InvariantError) { replay.call([event]) }
    assert_match(/unconfirmed|unchosen/, error.message)
  end

  def test_benchmark_includes_both_controls_without_changing_inputs
    before = PulseProof::Canonical.digest(providers_document)
    result = PulseProof::AdaptiveLab.new(providers_document: providers_document, profile: settings,
      baseline_profile: profile, seeds: [11], phase_length: 8).call
    assert_equal 3, result["results"].length
    result["results"].each do |row|
      assert row["balanced"]["validated"]
      assert row["fixed"]["validated"]
      assert row["adaptive"]["validated"]
      assert_equal 0, row["fixed"]["learning"]["observed_terminal_attempts"]
      assert_operator row["adaptive"]["learning"]["observed_terminal_attempts"], :>=, 24
    end
    assert_equal before, PulseProof::Canonical.digest(providers_document)
  end
end
