# frozen_string_literal: true

module PulseProof
  class ReportBuilder
    def initialize(queue:, decisions:, provider_states:, providers_document:, metrics:, router:, profile:)
      @queue = queue
      @decisions = decisions
      @providers = provider_states
      @providers_document = providers_document
      @metrics = metrics
      @router = router
      @profile = profile
    end

    def build
      {
        "period" => period,
        "total_operations" => @decisions.length,
        "distribution" => distribution,
        "volume_distribution" => volume_distribution,
        "volume_goal_status" => goal_reporting.volume_status,
        "unavailable_goal_handling" => goal_reporting.unavailable_status,
        "skip_reasons" => skip_reasons,
        "deviation_drivers" => deviation_drivers,
        "provider_outcomes" => provider_outcomes,
        "projected_daily_utilization" => projected_daily_utilization,
        "soft_goal_analysis" => soft_goal_analysis,
        "reconciliation" => reconciliation,
        "history_quality" => @metrics,
        "recommendations" => recommendations,
        "policy" => policy_summary,
        "capacity_protection" => capacity_protection,
        "adaptive_learning" => @router.adaptive_learning ? @router.adaptive_learning.summary : { "enabled" => false },
        "outcome_planning" => outcome_planning,
        "proof_capsules" => @router.proofs,
        "event_log" => @router.ledger.event_store.events,
        "audit" => audit
      }
    end

    private

    def goal_reporting
      @goal_reporting ||= GoalReporting.new(providers: @providers, profile: @profile,
        controller: @router.controller, proofs: @router.proofs, distribution: distribution)
    end

    def outcome_planning
      return { "enabled" => false } unless @router.outcome_planner
      @outcome_planning ||= begin
        timestamps = @queue.map { |op| op["created_at"] } + @router.ledger.event_store.events.map { |e| e.dig("payload", "at") }
        at = timestamps.compact.map { |time| Time.iso8601(time) }.max || Time.iso8601(@providers_document.fetch("snapshot_at"))
        @router.outcome_planner.summary(providers: @providers, at: at).merge("dependence_certificates" => dependence_coverage)
      end
    end

    def dependence_coverage
      rankings = @router.proofs.values.flat_map { |proof| proof.fetch("candidate_rankings", []) }
      certificates = rankings.map { |ranking| ranking.first && ranking.first.dig("outcome_plan", "dependence_certificate") }.compact
      { "unit" => "attempt_snapshot_not_operations_or_alternative_chains",
        "certified" => certificates.count { |item| item["status"] == "certified" },
        "not_applicable" => certificates.count { |item| item["status"] == "not_applicable" },
        "without_model_certificate" => rankings.length - certificates.length,
        "changes_routing" => false, "actual_success_guaranteed" => false }
    end

    def period
      first = @queue.first && @queue.first["created_at"]
      first ? first[0, 10] : nil
    end

    def provider_names
      @providers.keys
    end

    def operation_by_id
      @operation_by_id ||= @queue.each_with_object({}) { |operation, out| out[operation["operation_id"]] = operation }
    end

    def distribution
      total = [@decisions.length, 1].max.to_f
      provider_names.each_with_object({}) do |name, out|
        count = @decisions.count { |decision| decision["selected_provider"] == name }
        target = @providers.fetch(name).target_count_pct
        share = count * 100.0 / total
        out[name] = {
          "count" => count,
          "share_pct" => share.round(2),
          "target_pct" => target.round(2),
          "deviation_pp" => (share - target).round(2)
        }
      end
    end

    def volume_distribution
      total = @decisions.inject(0.0) do |sum, decision|
        operation = operation_by_id.fetch(decision["operation_id"])
        sum + operation.fetch("amount").to_f
      end
      provider_names.each_with_object({}) do |name, out|
        amount = @decisions.select { |decision| decision["selected_provider"] == name }.inject(0.0) do |sum, decision|
          sum + operation_by_id.fetch(decision["operation_id"]).fetch("amount").to_f
        end
        share = total.zero? ? 0.0 : amount * 100.0 / total
        metadata = goal_reporting.volume_row(name)
        target = metadata.fetch("effective_target_pct")
        out[name] = {
          "amount" => amount.round(2),
          "share_pct" => share.round(2),
          "target_pct" => target,
          "deviation_pp" => target.nil? ? nil : (share - target.to_f).round(2)
        }.merge(metadata)
      end
    end

    def skip_reasons
      @decisions.flat_map { |decision| decision.fetch("attempts") }
                .select { |attempt| attempt["decision"] == "skipped" }
                .group_by { |attempt| attempt["reason"] }
                .each_with_object({}) { |(reason, attempts), out| out[reason] = attempts.length }
    end

    def deviation_drivers
      provider_names.each_with_object({}) do |name, out|
        exclusions = @decisions.flat_map { |decision| decision.fetch("attempts", []) }
                               .select { |attempt| attempt["provider"] == name && attempt["decision"] == "skipped" && attempt["reason"] != "outranked_by_policy" }
                               .group_by { |attempt| attempt["reason"] }
                               .map { |reason, attempts| [reason, attempts.length] }
                               .sort_by { |reason, count| [-count, reason] }
                               .to_h
        out[name] = {
          "count_deviation_pp" => distribution.dig(name, "deviation_pp"),
          "volume_deviation_pp" => volume_distribution.dig(name, "deviation_pp"),
          "hard_exclusions" => exclusions
        }
      end
    end

    def provider_outcomes
      provider_names.each_with_object({}) do |name, out|
        attempts = @decisions.flat_map { |decision| decision.fetch("attempts", []) }
                             .select { |attempt| attempt["decision"] == "selected" && attempt["provider"] == name }
        latencies = attempts.map { |attempt| attempt["latency_sec"].to_f }.sort
        out[name] = {
          "attempts" => attempts.length,
          "approved" => attempts.count { |attempt| (attempt["resolution"] || attempt["result"]) == "approved" },
          "rejected" => attempts.count { |attempt| %w[rejected cancelled].include?(attempt["resolution"] || attempt["result"]) },
          "expired" => attempts.count { |attempt| attempt["result"] == "expired" && !attempt["resolution"] },
          "timeouts_observed" => attempts.count { |attempt| attempt["result"] == "expired" },
          "success_rate_pct" => (attempts.empty? ? 0.0 : attempts.count { |attempt| (attempt["resolution"] || attempt["result"]) == "approved" } * 100.0 / attempts.length).round(2),
          "average_latency_sec" => average(latencies).round(2),
          "p95_latency_sec" => percentile(latencies, 0.95).round(2),
          "current_load_ratio" => @providers.fetch(name).load_ratio.round(4)
        }
      end
    end

    def projected_daily_utilization
      provider_names.each_with_object({}) do |name, out|
        provider = @providers.fetch(name)
        limit = provider.config["daily_amount_limit"]
        used = provider.daily_approved_amount.round(2)
        out[name] = {
          "used" => used,
          "limit" => limit,
          "utilization_pct" => limit && limit.positive? ? (used * 100.0 / limit.to_f).round(2) : nil,
          "reserved" => provider.reserved_amount.round(2)
        }
      end
    end

    def soft_goal_analysis
      deviations = distribution.reject { |name, _| name == @profile.fetch("fallback_provider", "spacepayments") }
      changed_rules = @router.ledger.event_store.events.any? { |event| event["type"] == "provider_rules_updated" }
      failed_attempts = @decisions.any? { |d| d["attempts"].any? { |a| a["decision"] == "selected" && a["result"] != "approved" } }
      envelope = if changed_rules || failed_attempts
                   { "exact" => false, "reason" => "static approval-only hindsight bound does not apply to runtime updates or failures" }
                 else
                   FeasibilityEnvelope.new(@queue, @providers_document, fallback_provider: @profile.fetch("fallback_provider", "spacepayments")).call
                 end
      raw = deviations.values.inject(0.0) { |sum, row| sum + row["deviation_pp"].abs }.round(2)
      volume_deviations = volume_distribution.values.map { |row| row["deviation_pp"] }.compact
      volume_raw = volume_deviations.empty? ? nil : volume_deviations.inject(0.0) { |sum, value| sum + value.abs }.round(2)
      minimum = envelope["minimum_l1_deviation_pp"]
      {
        "raw_target_deviation_l1_pp" => raw,
        "raw_volume_target_deviation_l1_pp" => volume_raw,
        "controllable_excess_l1_pp" => minimum ? [raw - minimum, 0.0].max.round(2) : nil,
        "post_run_feasibility_envelope" => envelope,
        "final_controller_state" => @router.controller.snapshot,
        "method" => policy_method,
        "anti_windup" => "bounded debt with recovery_rate=#{@profile['recovery_rate']}"
      }
    end

    def reconciliation
      {
        "pending_count" => @router.ledger.pending.length,
        "settled_count" => @router.ledger.settlements.length,
        "reserved_count" => @providers.values.inject(0) { |sum, provider| sum + provider.reserved_count },
        "event_count" => @router.ledger.event_store.events.length,
        "event_head" => @router.ledger.event_store.events.last && @router.ledger.event_store.events.last["event_hash"],
        "ledger_matches_decisions" => @router.ledger.settlements.length == @decisions.count { |decision| decision["simulated_result"] == "approved" }
      }
    end

    def recommendations
      output = []
      outcome_planning.fetch("model_recommendations", []).each do |row|
        output << "#{row['provider']}: в историческом стресс-прогоне увеличение #{row['parameter']} с #{row['current_value']} до #{row['proposed_value']} повышает обслуженные операции #{row['served_before']} → #{row['served_after']} из #{row['tested_tape_size']}; минимальный улучшающий шаг среди проверенных, не прогноз. Изменение только после согласования оператором."
      end
      projected_daily_utilization.each do |name, row|
        if row["utilization_pct"] && row["utilization_pct"] >= 90
          output << "#{name}: дневной лимит использован на #{row['utilization_pct']}% — уменьшить traffic_percentage или увеличить daily_amount_limit"
        end
        provider = @providers.fetch(name)
        turnover_min = provider.config["daily_turnover_min"]
        if turnover_min && provider.effective_daily_amount < turnover_min.to_f
          gap = (turnover_min.to_f - provider.effective_daily_amount).round(2)
          output << if @router.outcome_planner
                      "#{name}: до daily_turnover_min не хватает #{gap}; проверить обязательство вместе с ожидаемыми итогами каскада, не менять веса автоматически"
                    else
                      "#{name}: до daily_turnover_min не хватает #{gap} — увеличить weights.turnover_min или целевую volume_share_pct"
                    end
        end
      end
      @metrics.each do |name, metric|
        if metric["trust"] == "low"
          output << "#{name}: history имеет низкую доверенность (n=#{metric['sample_size']}, policy mismatches=#{metric['policy_mismatch_rows']}) — применять conservative blend со snapshot"
        end
        if !@router.outcome_planner && metric["observed_conversion"] && metric["snapshot_conversion"] - metric["observed_conversion"] > 0.15
          output << "#{name}: историческая conversion ниже snapshot более чем на 15 п.п. — увеличить weights.conversion или временно выбрать selection_mode=conversion_first"
        end
      end
      deviation_drivers.each do |name, driver|
        next unless driver["count_deviation_pp"].to_f <= -5.0
        main_reason, count = driver.fetch("hard_exclusions", {}).first
        next unless main_reason
        output << "#{name}: доля ниже цели на #{driver['count_deviation_pp'].abs.round(2)} п.п.; главный ограничитель #{main_reason} (#{count}) — сначала изменить соответствующее hard-правило или покрытие, а не усиливать вес traffic"
      end
      output << "Сохранять timeout как pending reservation до подтвержденного reject/cancel; не запускать двойную выплату"
      output << "Использовать bounded recovery_rate после недоступности провайдера, чтобы избежать burst traffic"
      output.uniq
    end

    def policy_summary
      {
        "profile" => @profile["profile"],
        "selection_mode" => @profile.fetch("selection_mode", "balanced_minimax"),
        "weights" => @profile["weights"],
        "volume_targets" => @profile.fetch("volume_targets", {}),
        "amount_preferences" => @profile.fetch("amount_preferences", {}),
        "capacity_guard" => @profile.fetch("capacity_guard", { "enabled" => false }),
        "adaptive_learning" => @profile.fetch("adaptive_learning", { "enabled" => false }),
        "outcome_planner" => @profile.fetch("outcome_planner", { "enabled" => false }),
        "fallback_provider" => @profile["fallback_provider"],
        "policy_hash" => Canonical.digest(@profile),
        "conflict_resolution" => ["hard_constraints", "count_volume_objective", "quality_and_business_factors", "stable_tie_break"]
      }
    end

    def capacity_protection
      changes = @router.proofs.values.flat_map do |proof|
        proof.fetch("candidate_rankings", []).each_with_index.map do |ranking, index|
          winner = ranking.first
          guard = winner && winner["capacity_guard"]
          next unless guard && guard["overrode_baseline"]
          baseline = ranking.find { |row| row["provider"] == guard["baseline_provider"] }
          { "operation_id" => proof["operation_id"], "attempt" => index + 1,
            "baseline_provider" => guard["baseline_provider"], "selected_provider" => winner["provider"],
            "baseline_lost_support" => baseline.dig("capacity_guard", "lost_historical_support_count"),
            "selected_lost_support" => guard["lost_historical_support_count"] }
        end.compact
      end
      { "enabled" => @profile.dig("capacity_guard", "enabled") == true, "overrides" => changes,
        "scope" => "historical-shape coverage under a hypothetical reservation; not avoided losses or future predictions" }
    end

    def policy_method
      return "exact pair-exchange ordering for the frozen additive cascade model; expected terminal/provisional goal potential plus configured attempt, latency and resource costs; only first step executes" if @router.outcome_planner
      if @router.adaptive_learning
        return "contextual confirmed-outcome learning; lexicographic goal balancing until degradation evidence; configured selection mode under evidence; bounded stale-context probes"
      end
      case @profile.fetch("selection_mode", "balanced_minimax")
      when "weighted_random"
        "seeded weighted random among hard-eligible candidates; comparison baseline"
      when "cascade"
        "configured provider priority, then bounded goal regret and stable tie-break"
      when "conversion_first"
        "trusted conversion first, then bounded goal regret, load and stable tie-break"
      when "weighted_sum"
        "configured weighted policy cost across goal regret and business factors"
      else
        "lexicographic bounded minimax: count/volume regret, then conversion/load/margin/priority/amount/turnover"
      end
    end

    def audit
      serialized = JSON.generate({ "decisions" => @decisions, "proofs" => @router.proofs })
      {
        "generated_by" => "PulseProof #{PulseProof::VERSION}",
        "deterministic" => true,
        "lookahead_used" => false,
        "future_operations_visible_to_router" => false,
        "pii_scan_clean" => !Redactor.phone_like?(serialized),
        "decisions_hash" => Canonical.digest(@decisions),
        "report_rebuildable_from_ledger" => false,
        "ledger_balances_replayable_with_original_inputs" => true,
        "persistence" => "in-memory; exported journal is not a crash-recovery database",
        "outcome_mode" => @profile.fetch("outcome_mode", "approve"),
        "outcome_adapter" => @router.outcome_model.class.name,
        "external_provider_calls" => @router.outcome_model.is_a?(OutcomeModel) ? false : "adapter_defined",
        "proof_scope" => "snapshots, constraints and event reconciliation; not externally signed bank receipts"
      }
    end

    def average(values)
      return 0.0 if values.empty?
      values.inject(0.0, :+) / values.length
    end

    def percentile(values, percentile)
      return 0.0 if values.empty?
      values[[(values.length * percentile).ceil - 1, 0].max]
    end
  end
end
