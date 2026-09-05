# frozen_string_literal: true

require "time"
require "timeout"

module PulseProof
  class Router
    attr_reader :providers, :profile, :hard_gate, :metrics, :controller, :ledger, :outcome_model, :proofs, :adaptive_learning, :outcome_planner

    def initialize(provider_states:, profile:, metrics:, outcome_model: nil, history: [], history_as_of: nil)
      @providers = provider_states
      @profile = profile
      @hard_gate = HardGate.new(fallback_provider: fallback_name)
      @metrics = metrics
      @controller = DeficitController.new(provider_states, profile)
      @capacity_guard = nil
      @adaptive_learning = nil
      @outcome_planner = profile.dig("outcome_planner", "enabled") ? OutcomePlanner.new(profile: profile, history: history, as_of: history_as_of) : nil
      if profile.dig("adaptive_learning", "enabled")
        @adaptive_learning = AdaptiveLearning.new(providers: provider_states, history: history,
          config: profile.fetch("adaptive_learning"), as_of: history_as_of)
      end
      if profile.fetch("capacity_guard", {}).fetch("enabled", false)
        @capacity_guard = CapacityGuard.new(history: history, config: profile.fetch("capacity_guard"),
          fallback_provider: fallback_name, as_of: history_as_of)
      end
      @ledger = Ledger.new(provider_states)
      @outcome_model = outcome_model || OutcomeModel.new(
        mode: profile.fetch("outcome_mode", "approve"),
        timeout_sec: profile.fetch("latency_timeout_sec", 180)
      )
      @proofs = {}
      @state_lock = Mutex.new
      @sessions = {}
      @pending_contexts = {}
    end

    def route(operation)
      InputLoader.validate_queue!([operation])
      operation = Marshal.load(Marshal.dump(operation))
      id = operation.fetch("operation_id")
      fingerprint = Canonical.digest(operation)
      @state_lock.synchronize do
        session = @sessions[id]
        if session
          raise InputError, "operation_id reused with different payload: #{id}" unless session[:fingerprint] == fingerprint
          return Marshal.load(Marshal.dump(session[:response])) if session[:response]
          raise InputError, "operation is already in flight: #{id}"
        end
        @sessions[id] = { fingerprint: fingerprint, operation: operation }
      end
      advance(operation)
    end

    # Control-plane deltas exclude ledger-owned balances. A full external
    # snapshot adapter needs a reconciliation watermark to avoid double-counts.
    def update_provider!(provider_name:, changes:, at:)
      @state_lock.synchronize do
        raise InputError, "unknown provider: #{provider_name}" unless providers.key?(provider_name)
        raise InputError, "provider changes must be an object" unless changes.is_a?(Hash)
        forbidden = %w[payment_system daily_approved_amount in_progress_count in_progress_amount]
        raise InputError, "cannot overwrite ledger-owned fields" if (changes.keys & forbidden).any?
        Time.iso8601(at)
        state = providers.fetch(provider_name)
        candidate = state.config.merge(changes)
        InputLoader.validate_provider_document!({ "providers" => [candidate] })
        before = Canonical.digest(state.config)
        state.config.merge!(Marshal.load(Marshal.dump(changes)))
        if changes.key?("conversion_24h")
          metric = metrics.fetch(provider_name)
          metric["snapshot_conversion"] = changes.fetch("conversion_24h").to_f
          n = metric.fetch("calibration_sample_size", metric.fetch("sample_size", 0)).to_f
          approvals = metric.fetch("calibration_approved", metric.fetch("approved", 0)).to_f
          prior = profile.fetch("history_prior_strength", 12).to_f
          metric["conservative_conversion"] = (approvals + prior * metric["snapshot_conversion"]) / [n + prior, 1].max
        end
        ledger.event_store.append("provider_rules_updated", {
          "provider" => provider_name, "changes" => changes, "at" => at,
          "previous_rules_hash" => before, "rules_hash" => Canonical.digest(state.config)
        })
        state.snapshot(Time.iso8601(at))
      end
    end

    # Correlate a late status with the owner attempt, not just the payout ID.
    def reconcile(operation_id:, provider_name:, attempt:, status:, at:, status_event_id:)
      continuation = nil
      operation = nil
      @state_lock.synchronize do
        session = @sessions[operation_id]
        context = @pending_contexts[operation_id]
        parsed_at = Time.iso8601(at)
        if context && parsed_at < Time.iso8601(session.fetch(:operation).fetch("created_at"))
          raise InputError, "status timestamp predates operation"
        end
        latency = context ? context[:total_latency] : 0
        result = ledger.reconcile_timeout!(operation_id, provider_name: provider_name, attempt: attempt,
          status: status, at: at, latency_sec: latency, status_event_id: status_event_id)
        return result if result["ignored"] || result["duplicate"]
        raise InvariantError, "pending routing context is missing" unless session && context
        selected = context[:attempts].select { |row| row["decision"] == "selected" }.last
        selected["resolution"] = status
        selected["resolution_at"] = at
        operation = session.fetch(:operation).merge("created_at" => at)
        learn_outcome!(session.fetch(:operation), provider_name, attempt, status, at: at, source: "correlated_status_event")
        @pending_contexts.delete(operation_id)
        if status == "approved" || provider_name == fallback_name
          response = session.fetch(:response)
          response["simulated_result"] = status == "approved" ? "approved" : "rejected"
          response["attempts"] = context[:attempts]
          refresh_final_proof!(operation_id, response["simulated_result"])
          ledger.verify_current!
          return Marshal.load(Marshal.dump(response))
        end
        controller.reverse_credit!(provider_name, operation.fetch("amount"))
        context[:tried] << provider_name
        session.delete(:response)
        continuation = context
      end
      advance(operation, continuation: continuation)
    end

    def advance(operation, continuation: nil)
      operation_id = operation.fetch("operation_id")
      amount = operation.fetch("amount").to_f
      tried = []
      attempts = []
      hard_history = []
      ranking_history = []
      reservation_history = []
      attempt_snapshots = []
      total_latency = 0.0
      final_provider = nil
      final_result = nil
      attempt_number = 0
      eligibility_recorded = false
      initial_snapshot = nil
      debt_before_accrual = nil

      @state_lock.synchronize do
        if continuation
          tried = continuation[:tried]
          attempts = continuation[:attempts]
          hard_history = continuation[:hard_history]
          ranking_history = continuation[:ranking_history]
          reservation_history = continuation[:reservations]
          attempt_snapshots = continuation[:attempt_snapshots]
          total_latency = continuation[:total_latency]
          attempt_number = continuation[:attempt_number]
          initial_snapshot = continuation[:initial_snapshot]
          debt_before_accrual = continuation[:debt_before_accrual]
          eligibility_recorded = true
        else
          initial_snapshot = global_snapshot(operation, tried: tried, attempt: 0)
          debt_before_accrual = controller.snapshot
          controller.accrue!(amount)
        end
      end

      latency_before_continuation = total_latency
      loop do
        attempt_number += 1
        raise InvariantError, "all providers exhausted for #{operation_id}" if attempt_number > providers.length

        selected = nil
        ranking = nil
        provider_name = nil
        provider = nil
        debt_before_choice = nil

        @state_lock.synchronize do
          evaluated = evaluate_external(operation)
          unless eligibility_recorded
            controller.mark_eligibility!(evaluated)
            eligibility_recorded = true
          end
          hard_history << evaluated.map(&:to_h)
          append_hard_skips!(attempts, evaluated, tried)
          eligible_names = evaluated.select(&:eligible).map(&:provider).reject { |name| tried.include?(name) }

          if eligible_names.empty?
            raise InvariantError, "fallback provider exhausted for #{operation_id}" if tried.include?(fallback_name)
            fallback = providers.fetch(fallback_name)
            fallback_result = hard_gate.evaluate(operation, fallback, fallback: true)
            hard_history << [fallback_result.to_h]
            raise InvariantError, "fallback provider is not eligible for #{operation_id}: #{fallback_result.reason}" unless fallback_result.eligible
            eligible_names = [fallback_name]
          end

          current_metrics = decision_metrics(operation)
          ranking = rank_candidates(eligible_names, amount, operation_id, current_metrics)
          if adaptive_learning && eligible_names != [fallback_name]
            active_signal = eligible_names.any? { |name| current_metrics.dig(name, "adaptive_prediction", "degradation_signal") }
            unless active_signal
              ranking.sort_by! { |row| [row["primary_regret"], row["secondary_penalty"], providers.fetch(row["provider"]).config["priority"].to_i, row["provider"]] }
            end
            ranking.each { |row| row["adaptive_mode"] = active_signal ? "confirmed_degradation_response" : "balance_until_evidence" }
          end
          if @capacity_guard && eligible_names != [fallback_name]
            ranking = @capacity_guard.rank(ranking, providers: providers, metrics: current_metrics, operation: operation)
          end
          if adaptive_learning && eligible_names != [fallback_name]
            ranking.each { |row| row["adaptive_prediction"] = current_metrics.fetch(row["provider"]).fetch("adaptive_prediction") }
            ranking = adaptive_learning.probe(ranking, operation: operation, attempt: attempt_number, providers: providers) unless outcome_planner
          end
          if outcome_planner && eligible_names != [fallback_name]
            ranking = outcome_planner.rank(ranking, providers: providers, metrics: current_metrics,
              operation: operation, controller: controller)
          end
          ranking_history << serialize_ranking(ranking)
          selected = ranking.first
          provider_name = selected.fetch("provider")
          provider = providers.fetch(provider_name)
          debt_before_choice = controller.snapshot
          attempt_snapshot = global_snapshot(operation, tried: tried, attempt: attempt_number)
          attempt_hash = Canonical.digest(attempt_snapshot)
          attempt_snapshots << {
            "attempt" => attempt_number,
            "provider" => provider_name,
            "snapshot_hash" => attempt_hash,
            "snapshot" => attempt_snapshot,
            "tried_before" => tried.dup
          }

          ledger.begin_attempt!(operation, attempt_number)
          outcome_planner.opportunity.observe(operation) if outcome_planner && attempt_number == 1
          reservation = ledger.reserve!(operation, provider_name, attempt_number, state_hash: attempt_hash)
          reservation_history << reservation
          controller.provisional_credit!(provider_name, amount) unless provider_name == fallback_name
        end

        begin
          outcome = outcome_model.call(operation, provider, attempt_number)
        rescue IOError, SystemCallError, Timeout::Error => error
          outcome = { "result" => "expired", "latency_sec" => profile.fetch("latency_timeout_sec", 180), "transport_error" => error.class.name }
        end
        total_latency += outcome.fetch("latency_sec").to_f
        selected_count = ranking.length
        attempts << selected_attempt(provider_name, selected, ranking, outcome, selected_count)

        @state_lock.synchronize do
          case outcome.fetch("result")
          when "approved"
            ledger.approve!(operation_id, provider_name, attempt_number, at: operation.fetch("created_at"), latency_sec: outcome.fetch("latency_sec"))
            final_provider = provider_name
            final_result = "approved"
          when "rejected"
            ledger.reject!(operation_id, provider_name, attempt_number, at: operation.fetch("created_at"), status: "rejected")
            controller.reverse_credit!(provider_name, amount) unless provider_name == fallback_name
            tried << provider_name
            if provider_name == fallback_name
              final_provider = provider_name
              final_result = "rejected"
            end
          when "expired"
            ledger.timeout!(operation_id, provider_name, attempt_number, at: operation.fetch("created_at"), latency_sec: outcome.fetch("latency_sec"))
            resolution = outcome["resolution"]
            if resolution == "approved"
              ledger.reconcile_timeout!(
                operation_id,
                provider_name: provider_name, attempt: attempt_number,
                status: "approved",
                at: operation.fetch("created_at"),
                latency_sec: outcome.fetch("latency_sec"),
                status_event_id: "status_#{operation_id}_#{attempt_number}_approved"
              )
              final_provider = provider_name
              final_result = "approved"
            elsif %w[rejected cancelled].include?(resolution)
              ledger.reconcile_timeout!(
                operation_id,
                provider_name: provider_name, attempt: attempt_number,
                status: resolution,
                at: operation.fetch("created_at"),
                latency_sec: outcome.fetch("latency_sec"),
                status_event_id: "status_#{operation_id}_#{attempt_number}_#{resolution}"
              )
              controller.reverse_credit!(provider_name, amount) unless provider_name == fallback_name
              tried << provider_name
              if provider_name == fallback_name
                final_provider = provider_name
                final_result = "rejected"
              end
            else
              final_provider = provider_name
              final_result = "expired"
            end
          else
            raise InvariantError, "unknown outcome #{outcome['result']}"
          end

          confirmed = outcome["resolution"] || outcome["result"]
          learning_at = (Time.iso8601(operation.fetch("created_at")) + total_latency - latency_before_continuation).iso8601(6)
          learn_outcome!(operation, provider_name, attempt_number, confirmed, at: learning_at,
            source: outcome_model.is_a?(OutcomeModel) ? "simulation" : "adapter_response")

          if final_provider
            if final_result == "expired"
              @pending_contexts[operation_id] = {
                tried: tried, attempts: attempts, hard_history: hard_history, ranking_history: ranking_history,
                reservations: reservation_history, attempt_snapshots: attempt_snapshots, total_latency: total_latency,
                attempt_number: attempt_number, initial_snapshot: initial_snapshot, debt_before_accrual: debt_before_accrual
              }
            end
            append_soft_skips!(attempts, ranking, tried + [final_provider])
            proofs[operation_id] = build_proof(
              operation: operation,
              initial_snapshot: initial_snapshot,
              debt_before_accrual: debt_before_accrual,
              debt_before_choice: debt_before_choice,
              hard_history: hard_history,
              ranking_history: ranking_history,
              reservations: reservation_history,
              attempt_snapshots: attempt_snapshots,
              final_provider: final_provider,
              final_result: final_result
            )
            @sessions.fetch(operation_id)[:response] = {
              "operation_id" => operation_id, "selected_provider" => final_provider,
              "attempts" => attempts, "simulated_result" => final_result,
              "latency_sec" => total_latency.round(2)
            }
          end
          ledger.verify_current!
        end
        break if final_provider
      end

      @state_lock.synchronize { Marshal.load(Marshal.dump(@sessions.fetch(operation_id).fetch(:response))) }
    end

    private :advance

    private

    def decision_metrics(operation)
      adaptive_learning ? adaptive_learning.metrics_for(operation, metrics) : metrics
    end

    def learn_outcome!(operation, provider_name, attempt, status, at:, source:)
      return unless adaptive_learning
      event = adaptive_learning.observe(operation: operation, provider_name: provider_name, attempt: attempt,
        status: status, at: at, source: source)
      ledger.event_store.append("learning_observed", event) if event
    end

    def refresh_final_proof!(operation_id, state)
      proof = proofs.fetch(operation_id)
      events = ledger.event_store.for_operation(operation_id)
      proof["final_state"] = state
      proof["event_ids"] = events.map { |event| event["event_id"] }
      proof["event_head"] = events.last["event_hash"]
      proof["debt_after"] = controller.snapshot
    end

    def fallback_name
      profile.fetch("fallback_provider", "spacepayments")
    end

    def external_providers
      providers.values.reject { |provider| provider.name == fallback_name }
    end

    def evaluate_external(operation)
      external_providers.map { |provider| hard_gate.evaluate(operation, provider) }
    end

    def rank_candidates(names, amount, operation_id, current_metrics)
      if names == [fallback_name]
        provider = providers.fetch(fallback_name)
        [{
          "provider" => provider.name,
          "primary_regret" => 0.0,
          "secondary_penalty" => 0.0,
          "count_regret" => 0.0,
          "volume_regret" => 0.0,
          "count_debt_before" => 0.0,
          "effective_count_debt" => 0.0,
          "conversion_penalty" => 0.0,
          "load_penalty" => provider.load_ratio,
          "margin_penalty" => 0.0,
          "priority_penalty" => provider.config["priority"].to_i / 100.0,
          "recovering" => false,
          "sort_key" => [0, 0, provider.config["priority"].to_i, provider.name]
        }]
      else
        ranking = controller.rank(names, current_metrics, amount)
        if profile["selection_mode"] == "weighted_random"
          ranking.each do |row|
            name = row.fetch("provider")
            seed = profile.fetch("random_seed", "comparison")
            word = Canonical.digest([seed, operation_id, name])[0, 12].to_i(16)
            uniform = (word + 1).to_f / (0xffffffffffff + 2)
            row["random_priority"] = -Math.log(uniform) / providers.fetch(name).target_count_pct
          end
          ranking.sort_by { |row| row.fetch("random_priority") }
        else
          ranking
        end
      end
    end

    def append_hard_skips!(attempts, evaluated, tried)
      recorded = attempts.map { |attempt| [attempt["provider"], attempt["reason"]] }
      evaluated.reject(&:eligible).each do |result|
        next if tried.include?(result.provider)
        key = [result.provider, result.reason]
        next if recorded.include?(key)
        attempts << {
          "provider" => result.provider,
          "decision" => "skipped",
          "reason" => result.reason,
          "details" => result.details
        }
      end
    end

    def append_soft_skips!(attempts, ranking, used_names)
      recorded_names = attempts.map { |attempt| attempt["provider"] }
      ranking.drop(1).each do |analysis|
        name = analysis.fetch("provider")
        next if used_names.include?(name) || recorded_names.include?(name)
        attempts << {
          "provider" => name,
          "decision" => "skipped",
          "reason" => "outranked_by_policy",
          "details" => [
            "regret=#{analysis['primary_regret']}",
            "secondary=#{analysis['secondary_penalty']}",
            "conversion_penalty=#{analysis['conversion_penalty']}",
            "load_penalty=#{analysis['load_penalty']}",
            "amount_fit_penalty=#{analysis['amount_fit_penalty'] || 0}",
            "turnover_min_penalty=#{analysis['turnover_min_penalty'] || 0}"
          ].join("; ")
        }
      end
    end

    def selected_attempt(provider_name, selected, ranking, outcome, eligible_count)
      runner_up = ranking[1]
      reason = if provider_name == fallback_name
                 "fallback_no_external_provider"
               elsif selected["adaptive_probe"]
                 "bounded_context_recovery_probe"
               elsif selected.dig("capacity_guard", "overrode_baseline")
                 "preserve_unique_external_capacity"
               elsif eligible_count == 1
                 "only_eligible_provider"
               elsif selected["outcome_plan"]
                 "lowest_expected_cascade_cost"
               else
                 adaptive_learning ? selected.fetch("adaptive_mode", "adaptive_contextual_policy") : selection_reason
               end
      details = [
        "regret=#{selected['primary_regret']}",
        "secondary=#{selected['secondary_penalty']}",
        "conversion_penalty=#{selected['conversion_penalty']}",
        "load_penalty=#{selected['load_penalty']}",
        "amount_fit_penalty=#{selected['amount_fit_penalty'] || 0}",
        "turnover_min_penalty=#{selected['turnover_min_penalty'] || 0}"
      ].join("; ")
      details += "; runner_up=#{runner_up['provider']}@#{runner_up['primary_regret']}" if runner_up
      if selected["adaptive_prediction"]
        prediction = selected["adaptive_prediction"]
        details += "; contextual_mean=#{prediction['mean']}; evidence=#{prediction['effective_samples']}; uncertainty_sd=#{prediction['uncertainty_sd']}"
      end
      if selected["capacity_guard"]
        guard = selected["capacity_guard"]
        details += "; baseline=#{guard['baseline_provider']}; lost_historical_support=#{guard['lost_historical_support_count']}/#{guard['sample_size']}; policy_budget=#{guard['within_policy_budget']}"
      end
      if selected["outcome_plan"]
        plan = selected["outcome_plan"]
        details += "; model_chain=#{plan['chain'].join('>')}; expected_attempts=#{plan['raw_metrics']['attempts']}; objective=#{plan['objective']}; execute_first_step_only=true"
      end
      {
        "provider" => provider_name,
        "decision" => "selected",
        "reason" => reason,
        "details" => details,
        "result" => outcome.fetch("result"),
        "latency_sec" => outcome.fetch("latency_sec").to_f
      }.merge(outcome.key?("resolution") ? { "resolution" => outcome["resolution"] } : {})
    end

    def selection_reason
      case profile.fetch("selection_mode", "balanced_minimax")
      when "cascade" then "provider_priority"
      when "conversion_first" then "highest_trusted_conversion"
      when "weighted_sum" then "lowest_weighted_policy_cost"
      when "weighted_random" then "seeded_weighted_random"
      else "lowest_bounded_goal_regret"
      end
    end

    def serialize_ranking(ranking)
      ranking.map do |item|
        item.reject { |key, _| key == "sort_key" }
      end
    end

    def global_snapshot(operation, tried:, attempt:)
      at = Time.parse(operation.fetch("created_at"))
      {
        "operation" => Redactor.call(operation),
        "cascade" => { "attempt" => attempt, "tried" => tried.dup },
        "providers" => providers.each_with_object({}) { |(name, provider), out| out[name] = provider.snapshot(at) },
        "policy" => Marshal.load(Marshal.dump(profile)),
        "metrics" => Marshal.load(Marshal.dump(decision_metrics(operation))),
        "adaptive_learning" => adaptive_learning && adaptive_learning.summary,
        "capacity_guard_model" => @capacity_guard && @capacity_guard.model_at(at),
        "ledger" => ledger.routing_snapshot,
        "controller" => controller.snapshot
      }
    end

    def build_proof(operation:, initial_snapshot:, debt_before_accrual:, debt_before_choice:, hard_history:, ranking_history:, reservations:, attempt_snapshots:, final_provider:, final_result:)
      operation_id = operation.fetch("operation_id")
      events = ledger.event_store.for_operation(operation_id)
      final_ranking = ranking_history.last || []
      {
        "policy_profile" => profile.fetch("profile", "balanced"),
        "operation_id" => operation_id,
        "snapshot_at" => operation.fetch("created_at"),
        "snapshot_hash" => Canonical.digest(initial_snapshot),
        "attempt_snapshots" => attempt_snapshots,
        "hard_evaluations" => hard_history,
        "debt_before_accrual" => debt_before_accrual,
        "debt_before_choice" => debt_before_choice,
        "debt_after" => controller.snapshot,
        "candidate_rankings" => ranking_history,
        "winner" => final_provider,
        "runner_up" => final_ranking[1] && final_ranking[1]["provider"],
        "winning_factor" => final_ranking[0] && winning_factor(final_ranking[0], final_ranking[1]),
        "reservations" => reservations,
        "final_state" => final_result,
        "event_ids" => events.map { |event| event["event_id"] },
        "event_head" => events.empty? ? nil : events.last["event_hash"],
        "redaction" => { "payout_requisite" => "removed", "phone" => "removed" }
      }
    end

    def winning_factor(winner, runner_up)
      return "expected_cascade_outcomes_goals_and_capacity" if winner["outcome_plan"]
      return "bounded_recovery_probe_of_stale_context" if winner["adaptive_probe"]
      return winner.fetch("adaptive_mode", "contextual_learned_quality_and_configured_goals") if winner["adaptive_prediction"] && !winner.dig("capacity_guard", "overrode_baseline")
      return "preserves_last_external_route_for_historical_shapes" if winner.dig("capacity_guard", "overrode_baseline")
      return "only_eligible_provider" unless runner_up
      case profile.fetch("selection_mode", "balanced_minimax")
      when "cascade"
        return "higher_provider_priority"
      when "weighted_random"
        return "seeded_weighted_random_choice"
      when "conversion_first"
        return "higher_trusted_conversion" if winner["conversion_penalty"] < runner_up["conversion_penalty"]
      when "weighted_sum"
        return "lower_weighted_policy_cost"
      end
      if winner["primary_regret"] < runner_up["primary_regret"]
        "lower_worst_goal_deviation"
      elsif winner["secondary_penalty"] < runner_up["secondary_penalty"]
        "lower_quality_penalty"
      else
        "stable_tie_break"
      end
    end
  end
end
