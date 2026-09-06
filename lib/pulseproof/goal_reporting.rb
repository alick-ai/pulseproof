# frozen_string_literal: true

module PulseProof
  # Summarizes recorded decisions; never feeds a target or a score back to routing.
  class GoalReporting
    EXAMPLE_LIMIT = 3

    def initialize(providers:, profile:, controller:, proofs:, distribution:)
      @providers, @profile, @state = providers, profile, controller.snapshot
      @proofs, @distribution = proofs, distribution
      @fallback = profile.fetch("fallback_provider", "spacepayments")
    end

    def volume_row(name)
      configured = volume_inputs[name]
      effective = @state.fetch("volume_targets")[name]
      reason = if name == @fallback
                 "fallback_excluded_from_soft_targets"
               elsif @state.fetch("volume_targets").empty?
                 volume_inputs.empty? ? "volume_target_not_provided" : "no_positive_external_volume_targets"
               elsif effective.nil?
                 "provider_volume_target_not_provided"
               end
      {
        "configured_target_pct" => configured,
        "target_source" => name == @fallback ? "fallback_policy" : volume_source,
        "effective_target_pct" => effective && (effective * 100.0).round(6),
        "target_status" => reason ? "disabled" : "configured",
        "null_reason" => reason
      }
    end

    def volume_status
      configured = !@state.fetch("volume_targets").empty?
      {
        "status" => configured ? "configured" : "disabled_no_positive_targets",
        "explanation" => configured ?
          "Цели объёма заданы явно и нормализованы среди внешних провайдеров. Это мягкая цель: hard-ограничения имеют приоритет." :
          "Цель объёма отключена: положительные цели не заданы. null означает отсутствие цели, а не отсутствие механизма; фактические суммы и доли рассчитаны.",
        "target_source" => volume_source,
        "configured_external_targets" => volume_inputs,
        "effective_controller_targets_pct" => @state.fetch("volume_targets").transform_values { |value| (value * 100.0).round(6) },
        "controller_weight" => @profile.fetch("weights", {}).fetch("volume", 0),
        "selection_mode" => @profile.fetch("selection_mode", "balanced_minimax"),
        "planner_enabled" => @profile.dig("outcome_planner", "enabled") == true,
        "planner_volume_weight" => @profile.dig("outcome_planner", "weights", "volume_potential_change"),
        "scope" => "Targets used at the latest operation accrual (or initial controller before any operation). Configured volume_targets replaces provider volume_share_pct; omitted external providers then receive zero. An empty/zero override disables the goal. A configured weight alone does not activate an absent target or prove a change of winner.",
        "attribution" => "final selected_provider, including provisional pending attribution; denominator is total amount of this queue, not historical or daily turnover",
        "capability_example" => {
          "profile" => "config/volume_demo.json",
          "scope" => "Illustrative targets, not organizer targets and not applied to this run unless this profile is selected.",
          "command" => "bin/pulseproof run --policy config/volume_demo.json --queue data/operations_queue_10.json --decisions outputs/volume-demo-decisions.json --report outputs/volume-demo-report.json",
          "causal_evidence_command" => "rake evidence",
          "causal_evidence_case" => "soft_volume",
          "documentation" => "docs/GOAL_REPORTING.md"
        }
      }
    end

    def unavailable_status
      rows = @providers.keys.reject { |name| name == @fallback }.each_with_object({}) do |name, out|
        out[name] = {
          "ineligible_operations" => 0, "reason_counts" => {}, "exclusion_examples" => [],
          "business_count_entitlement_while_ineligible" => 0.0,
          "final_selected_provider_counts_after_exclusion" => {},
          "recovery_entries" => 0, "recovery_rankings" => 0,
          "recovery_cap_reductions" => 0, "recovery_examples" => []
        }
      end
      @proofs.each do |id, proof|
        first = proof.fetch("attempt_snapshots").first
        next unless first
        debt = first.fetch("snapshot").fetch("controller")
        proof.fetch("hard_evaluations").first.each do |rule|
          name = rule.fetch("provider")
          row = rows[name]
          next unless row
          if rule.fetch("eligible")
            row["recovery_entries"] += 1 if proof.dig("debt_before_accrual", "unavailable_streak", name).to_i.positive?
          else
            row["ineligible_operations"] += 1
            increment(row["reason_counts"], rule.fetch("reason"))
            row["business_count_entitlement_while_ineligible"] += debt.fetch("count_targets").fetch(name, 0)
            increment(row["final_selected_provider_counts_after_exclusion"], proof.fetch("winner"))
            append_example(row["exclusion_examples"], { "operation_id" => id, "reason" => rule.fetch("reason"),
              "final_selected_provider" => proof.fetch("winner") })
          end
        end
        proof.fetch("candidate_rankings").each_with_index do |ranking, index|
          ranking.each do |candidate|
            row = rows[candidate.fetch("provider")]
            next unless row && candidate["recovering"]
            row["recovery_rankings"] += 1
            before, effective = candidate.values_at("count_debt_before", "effective_count_debt")
            reduced = effective < before
            row["recovery_cap_reductions"] += 1 if reduced
            append_example(row["recovery_examples"], {
              "operation_id" => id, "attempt" => index + 1, "count_debt_before" => before,
              "effective_count_debt" => effective, "cap_reduced_debt" => reduced,
              "selected_on_attempt" => proof.fetch("attempt_snapshots")[index].fetch("provider") == candidate.fetch("provider")
            })
          end
        end
      end
      rows.each do |name, row|
        row["business_count_entitlement_while_ineligible"] = row["business_count_entitlement_while_ineligible"].round(8)
        row["final_distribution"] = @distribution.fetch(name)
        row["final_raw_count_debt"] = @state.fetch("raw_count_debt").fetch(name)
        row["final_bounded_count_debt"] = @state.fetch("count_debt").fetch(name)
        row["final_unavailable_streak"] = @state.fetch("unavailable_streak").fetch(name)
        row["final_recovering"] = @state.fetch("recovering").fetch(name)
        row["explanation"] = "Недопустим для #{row['ineligible_operations']} операций; возвратов в допустимые #{row['recovery_entries']}; ограничение восстановления уменьшило долг в #{row['recovery_cap_reductions']} ранжированиях. Исходное отклонение от цели сохранено."
      end
      redistribute = @profile.fetch("redistribute_unavailable", false)
      {
        "explanation" => "Недоступность здесь означает запрет для конкретной операции (сумма, банк, лимит или статус), а не обязательно сбой провайдера. Выбор идёт среди допустимых; при их исчерпании применяется fallback. Невыполнимая сейчас доля не отменяет hard-правила.",
        "redistribute_unavailable" => redistribute,
        "target_handling" => redistribute ?
          "Текущее начисление управляющего долга перераспределяется среди допустимых пропорционально целям; исходный бизнес-долг остаётся видимым." :
          "Исходные цели сохранены. Автоматическое перераспределение целей выключено; долг накапливается с ограничением, итоговый маршрут учитывается за фактически выбранным провайдером.",
        "count_debt_bound" => [@profile.fetch("traffic_debt_bound", 4).to_f, 1.0].max,
        "recovery_rate" => @profile.fetch("recovery_rate", 0.75),
        "recovery_rule" => "effective_count_debt = min(bounded_count_debt, max(other eligible bounded debts) + recovery_rate); with no other candidate no reduction is required. This limits ranking pressure, not requests per second or guaranteed final shares.",
        "scope" => "Ineligibility and recovery entries count the first evaluation once per operation. Recovery rankings count each recorded attempt. Only the first three examples are included; complete evidence is in proof_capsules. Failed attempts alone are not counted as hard ineligibility. A recovery flag is not evidence that the cap reduced debt or changed the winner.",
        "evaluated_operations" => @proofs.length,
        "providers" => rows
      }
    end

    private

    def volume_source
      @profile.key?("volume_targets") ? "profile.volume_targets" : "providers.volume_share_pct"
    end

    def volume_inputs
      @volume_inputs ||= begin
        names = @providers.keys.reject { |name| name == @fallback }
        if @profile.key?("volume_targets")
          names.each_with_object({}) { |name, out| out[name] = @profile.fetch("volume_targets").fetch(name, 0) }
        else
          latest = @proofs.values.map { |proof| proof.fetch("attempt_snapshots").first }.compact
                          .max_by { |attempt| attempt.dig("snapshot", "controller", "processed_count") }
          names.each_with_object({}) do |name, out|
            config = latest ? latest.dig("snapshot", "providers", name, "rules") : @providers.fetch(name).config
            out[name] = config["volume_share_pct"] unless config["volume_share_pct"].nil?
          end
        end
      end
    end

    def increment(hash, key)
      hash[key] = hash.fetch(key, 0) + 1
    end

    def append_example(examples, value)
      examples << value if examples.length < EXAMPLE_LIMIT
    end
  end
end
