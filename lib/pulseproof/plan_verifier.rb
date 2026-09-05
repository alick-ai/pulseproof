# frozen_string_literal: true

module PulseProof
  # Independent arithmetic and pair-exchange certificate check. This proves
  # the chosen ordering in the frozen model, not that its probabilities are true.
  class PlanVerifier
    def self.verify!(proof, fallback)
      proof.fetch("candidate_rankings").each_with_index do |ranking, index|
        snapshot = proof.fetch("attempt_snapshots").fetch(index).fetch("snapshot")
        unless snapshot.dig("policy", "outcome_planner", "enabled")
          raise InvariantError, "outcome plan attached to disabled planner" if ranking.any? { |row| row["outcome_plan"] }
          next
        end
        if ranking.length == 1 && ranking.first["provider"] == fallback
          external = snapshot.fetch("providers").keys.reject do |name|
            name == fallback || snapshot.fetch("cascade").fetch("tried").include?(name) || !eligible_snapshot?(snapshot, name, false)
          end
          raise InvariantError, "fallback-only plan hides an eligible external provider" unless external.empty?
          raise InvariantError, "fallback-only plan violates snapshot constraints" unless eligible_snapshot?(snapshot, fallback, true) && !snapshot["cascade"]["tried"].include?(fallback)
          raise InvariantError, "fallback-only runtime does not emit an outcome plan" if ranking.first["outcome_plan"]
          next
        end
        config = snapshot.fetch("policy").fetch("outcome_planner")
        model = ranking.first.dig("outcome_plan", "cascade_model")
        certified = ranking.any? { |row| row.dig("outcome_plan", "optimization", "method") == "exact_pair_exchange" }
        raise InvariantError, "exact cascade certificate is missing" if certified && !model
        verify_model!(model, ranking, snapshot, fallback) if model
        frontier = ranking.first.dig("outcome_plan", "evaluated_frontier")
        if frontier
          expected_names = ranking.map { |r| r["provider"] }.sort
          raise InvariantError, "duplicate frontier chain" unless frontier.map { |p| p["chain"] }.uniq.length == frontier.length
          frontier.each do |plan|
            chain = plan.fetch("chain")
            raise InvariantError, "invalid frontier chain" unless chain.reject { |name| name == fallback }.sort == expected_names && chain.uniq == chain
            raise InvariantError, "frontier fallback not last" if chain.include?(fallback) && chain.last != fallback
            if model
              matching = ranking.find { |row| row.dig("outcome_plan", "chain") == chain }
              raise InvariantError, "frontier differs from exact fixed-first plans" unless matching && matching["outcome_plan"]["raw_metrics"] == plan["raw_metrics"] && matching["outcome_plan"]["objective"] == plan["objective"]
            else
              total = plan.fetch("raw_metrics").sum { |key, value| value * config.fetch("weights").fetch(key, 0) }
              close!(plan["objective"], total)
            end
          end
          ranking.each do |row|
            best = frontier.select { |p| p["chain"].first == row["provider"] }.map { |p| p["objective"] }.min
            raise InvariantError, "frontier lacks first action" unless best
            close!(row["outcome_plan"]["objective"], best)
          end
        end
        objectives = []
        ranking.each do |row|
          plan = row.fetch("outcome_plan")
          chain = plan.fetch("chain")
          raise InvariantError, "plan first action mismatch" unless chain.first == row["provider"]
          raise InvariantError, "plan duplicates provider" unless chain.uniq == chain
          raise InvariantError, "plan fallback not last" if chain.include?(fallback) && chain.last != fallback
          # HardGate for execution is independently covered by AuditReplay.
          # Here ensure future chain providers are not already failed and are
          # members of this attempt's hard-eligible candidate set.
          external = chain.reject { |name| name == fallback }
          raise InvariantError, "plan omitted eligible external candidate" unless external.sort == ranking.map { |r| r["provider"] }.sort
          raise InvariantError, "plan repeats tried provider" unless (chain & snapshot.fetch("cascade").fetch("tried")).empty?
          reach = 1.0
          attempts = 0.0
          latency = 0.0
          held = 0.0
          approvals = {}
          pending = {}
          chain.each do |name|
            input = plan.fetch("model_inputs").fetch(name)
            metric = snapshot.fetch("metrics").fetch(name)
            mean = metric.fetch("conservative_conversion").to_f
            sd = metric.dig("adaptive_prediction", "uncertainty_sd").to_f
            p = [[mean - config.fetch("uncertainty_haircut", 0) * sd, 0].max, 1].min
            t = config.fetch("pending_probabilities", {}).fetch(name, 0).to_f
            seconds = snapshot.fetch("providers").fetch(name).fetch("rules").fetch("avg_latency_sec", 0).to_f
            close!(input["approval_given_terminal"], p)
            close!(input["pending_probability"], t)
            close!(input["reach_probability"], reach)
            close!(input["latency_sec"], seconds)
            approvals[name] = reach * (1 - t) * p
            pending[name] = reach * t
            close!(plan.fetch("final_approval_probabilities").fetch(name), approvals[name])
            close!(plan.fetch("pending_probabilities").fetch(name), pending[name])
            attempts += reach
            latency += reach * seconds
            held += pending[name] * snapshot.fetch("operation").fetch("amount") * config.fetch("pending_hold_sec", 180)
            reach *= (1 - t) * (1 - p)
          end
          raw = plan.fetch("raw_metrics")
          close!(plan["all_failed_probability"], reach)
          unless model
            close!(raw["attempts"], attempts)
            close!(raw["latency_sec"], latency)
            close!(raw["pending_ruble_seconds"], held)
            close!(raw["unresolved_or_failed_probability"], reach + pending.values.sum)
            close!(raw["fallback_probability"], plan["model_inputs"].fetch(fallback, {}).fetch("reach_probability", 0))
            debt = snapshot.fetch("controller")
            average = [debt["processed_amount"] / [debt["processed_count"], 1].max, 0.01].max
            amount_units = snapshot["operation"]["amount"] / average
            count_change = 0.0
            volume_change = 0.0
            approvals.each do |name, probability|
              next if name == fallback
              attribution = probability + pending.fetch(name)
              count_change += attribution * (1 - 2 * debt["count_debt"][name])
              if debt["volume_targets"].key?(name)
                volume_change += attribution * (amount_units**2 - 2 * amount_units * debt["volume_debt"][name] / average)
              end
            end
            close!(raw["count_potential_change"], count_change)
            close!(raw["volume_potential_change"], volume_change)
            total = 0.0
            raw.each do |key, value|
              term = value * config.fetch("weights").fetch(key, 0)
              close!(plan.fetch("terms").fetch(key), term)
              total += term
            end
            close!(plan["objective"], total)
          end
          dependence = plan["dependence_certificate"]
          optimization = plan.fetch("optimization", {})
          if optimization.key?("dependence_certificate_version")
            raise InvariantError, "unsupported dependence certificate version" unless optimization["dependence_certificate_version"] == 1
            raise InvariantError, "dependence certificate is missing" unless dependence
          end
          if plan.key?("dependence_certificate")
            DependenceVerifier.verify!(dependence, inputs: plan.fetch("model_inputs"), chain: chain,
              fallback: chain.include?(fallback) ? fallback : nil)
          end
          objectives << plan["objective"]
        end
        raise InvariantError, "plan rankings not ordered by objective" if !model && objectives != objectives.sort
        ranking.each { |row| close!(row["outcome_plan"]["gap_to_best"], row["outcome_plan"]["objective"] - objectives.first) }
      end
      true
    rescue KeyError, TypeError, NoMethodError => error
      raise InvariantError, "malformed outcome plan: #{error.message}"
    end

    METRICS = %w[count_potential_change volume_potential_change attempts latency_sec pending_ruble_seconds unresolved_or_failed_probability fallback_probability scarcity_slots business_factors].freeze

    def self.verify_model!(model, ranking, snapshot, fallback)
      raise InvariantError, "unsupported cascade certificate version" unless model.fetch("version") == 1
      names = ranking.map { |row| row.fetch("provider") }
      raise InvariantError, "duplicate cascade first action" unless names.uniq == names
      tried = snapshot.fetch("cascade").fetch("tried")
      eligible = snapshot.fetch("providers").keys.reject do |name|
        name == fallback || tried.include?(name) || !eligible_snapshot?(snapshot, name, false)
      end.sort
      raise InvariantError, "cascade candidate set differs from hard-eligible snapshot" unless names.sort == eligible && model.fetch("external_providers").sort == eligible
      raise InvariantError, "duplicate model external provider" unless model["external_providers"].uniq == model["external_providers"]
      expected_fallback = !tried.include?(fallback) && eligible_snapshot?(snapshot, fallback, true) ? fallback : nil
      raise InvariantError, "cascade fallback differs from hard-eligible snapshot" unless model["fallback_provider"] == expected_fallback
      actions = model.fetch("actions")
      raise InvariantError, "cascade model action set differs" unless actions.keys.sort == (eligible + [expected_fallback].compact).sort
      raise InvariantError, "invalid cascade terminal vector" unless model.fetch("terminal_metrics") == { "unresolved_or_failed_probability" => 1.0 }
      config = snapshot.fetch("policy").fetch("outcome_planner")
      weights = config.fetch("weights")
      weights.each_value { |value| finite!(value) }
      actions.each do |name, action|
        expected = local_metrics(snapshot, name, fallback)
        metrics = action.fetch("local_metrics")
        raise InvariantError, "unexpected cascade local vector" unless metrics.keys.sort == METRICS.sort
        metrics.each_value { |value| finite!(value) }
        mean = snapshot.fetch("metrics").fetch(name).fetch("conservative_conversion").to_f
        sd = snapshot["metrics"][name].dig("adaptive_prediction", "uncertainty_sd").to_f
        p = [[mean - config.fetch("uncertainty_haircut", 0) * sd, 0.0].max, 1.0].min
        t = config.fetch("pending_probabilities", {}).fetch(name, 0).to_f
        exact_number!(action.fetch("approval_given_terminal"), p)
        exact_number!(action.fetch("pending_probability"), t)
        exact_number!(action.fetch("continue_probability"), (1 - t) * (1 - p))
        exact_number!(action.fetch("latency_sec"), expected.fetch("latency_sec"))
        expected.each { |key, value| exact_number!(metrics.fetch(key), value) }
        evidence = ranking.find { |row| row["provider"] == name }
        verify_scarcity!(metrics["scarcity_slots"], evidence && evidence.dig("outcome_plan", "opportunity"), config, name == fallback)
      end
      costs = actions.transform_values do |action|
        action.fetch("local_metrics").sum { |key, value| value.to_r * weights.fetch(key, 0).to_r }
      end
      exact_order = []
      ranking.each do |row|
        plan = row.fetch("outcome_plan")
        optimization = plan.fetch("optimization")
        unless plan.fetch("chains_evaluated") == eligible.length &&
            plan.fetch("all_external_orders_evaluated") == (eligible.length <= 2) &&
            optimization.fetch("method") == "exact_pair_exchange" &&
            optimization.fetch("exact_for_frozen_model") == true &&
            optimization.fetch("factorial_search_used") == false
          raise InvariantError, "cascade optimization metadata differs from certificate"
        end
        external = plan.fetch("chain").reject { |name| name == fallback }
        raise InvariantError, "certificate first action mismatch" unless external.first == row["provider"]
        raise InvariantError, "certificate chain action set differs" unless external.sort == eligible
        raise InvariantError, "certificate fallback missing or unexpected" unless plan["chain"] == external + [expected_fallback].compact
        verify_canonical_suffix!(external, actions, costs)
        reach = Rational(1)
        raw = Hash.new { |hash, key| hash[key] = Rational(0) }
        plan["chain"].each do |name|
          actions.fetch(name).fetch("local_metrics").each { |key, value| raw[key] += reach * value.to_r }
          reach *= actions[name].fetch("continue_probability").to_r
        end
        model.fetch("terminal_metrics").each { |key, value| raw[key] += reach * value.to_r }
        raise InvariantError, "certificate raw vector differs" unless plan.fetch("raw_metrics").keys.sort == raw.keys.sort
        raise InvariantError, "certificate term vector differs" unless plan.fetch("terms").keys.sort == raw.keys.sort
        raw.each do |key, value|
          exact_number!(plan["raw_metrics"].fetch(key), value.to_f.round(8))
          exact_number!(plan["terms"].fetch(key), (value * weights.fetch(key, 0).to_r).to_f.round(8))
        end
        total = raw.sum { |key, value| value * weights.fetch(key, 0).to_r }
        exact_number!(plan.fetch("objective"), total.to_f.round(8))
        exact_number!(plan.fetch("objective_unrounded"), total.to_f)
        exact_order << [total, plan["chain"]]
      end
      raise InvariantError, "cascade rankings violate exact objective or lexical tie" unless exact_order == exact_order.sort
      winner_terms = ranking.first.fetch("outcome_plan").fetch("terms")
      ranking.each do |row|
        plan = row.fetch("outcome_plan")
        deltas = plan.fetch("alternative_terms_minus_best")
        raise InvariantError, "alternative explanation term set differs" unless deltas.keys.sort == winner_terms.keys.sort
        winner_terms.each do |key, value|
          exact_number!(deltas.fetch(key), (plan.fetch("terms").fetch(key) - value).round(8))
        end
      end
      true
    end

    # Check each fixed-first optimal suffix without calling CascadeOptimizer.
    # A neutral f=1,a=0 action commutes with all others, so an ordinary sort
    # comparator with lexical tie breaking is not a valid certificate.
    def self.verify_canonical_suffix!(chain, actions, costs)
      remaining = chain.drop(1).sort
      unreachable = actions.fetch(chain.first).fetch("continue_probability").zero?
      chain.drop(1).each do |actual|
        expected = if unreachable
          remaining.first
        else
          remaining.find do |name|
            remaining.all? do |other|
              costs.fetch(name) * (1 - actions.fetch(other).fetch("continue_probability").to_r) <=
                costs.fetch(other) * (1 - actions.fetch(name).fetch("continue_probability").to_r)
            end
          end
        end
        raise InvariantError, "cascade suffix is not the canonical exact optimum" unless actual == expected
        remaining.delete(actual)
        unreachable ||= actions.fetch(actual).fetch("continue_probability").zero?
      end
    end

    def self.local_metrics(snapshot, name, fallback)
      config = snapshot.fetch("policy").fetch("outcome_planner")
      metric = snapshot.fetch("metrics").fetch(name)
      p = [[metric.fetch("conservative_conversion").to_f - config.fetch("uncertainty_haircut", 0) * metric.dig("adaptive_prediction", "uncertainty_sd").to_f, 0.0].max, 1.0].min
      t = config.fetch("pending_probabilities", {}).fetch(name, 0).to_f
      debt = snapshot.fetch("controller")
      amount = snapshot.fetch("operation").fetch("amount")
      average = [debt["processed_amount"] / [debt["processed_count"], 1].max, 0.01].max
      units = amount / average
      credit = (1 - t) * p + t
      volume = 0.0
      if name != fallback && debt.fetch("volume_targets").key?(name)
        d = debt.fetch("volume_debt").fetch(name) / average
        volume = credit * (units * units - 2 * units * d)
      end
      { "count_potential_change" => name == fallback ? 0.0 : credit * (1 - 2 * debt.fetch("count_debt").fetch(name)),
        "volume_potential_change" => volume, "attempts" => 1.0,
        "latency_sec" => snapshot.fetch("providers").fetch(name).fetch("rules").fetch("avg_latency_sec", 0).to_f,
        "pending_ruble_seconds" => t * amount * config.fetch("pending_hold_sec", 180),
        "unresolved_or_failed_probability" => t, "fallback_probability" => name == fallback ? 1.0 : 0.0,
        "business_factors" => business_cost(snapshot, name) }
    end

    def self.business_cost(snapshot, name)
      provider = snapshot.fetch("providers").fetch(name)
      rules = provider.fetch("rules")
      amount = snapshot.fetch("operation").fetch("amount").to_f
      loads = []
      { "in_progress_count_limit" => "effective_in_progress_count", "in_progress_amount_limit" => "effective_in_progress_amount" }.each do |limit_key, value_key|
        next unless rules[limit_key]
        limit = rules[limit_key].to_f
        loads << (limit.zero? ? 1.0 : provider.fetch(value_key).to_f / limit)
      end
      fit = 0.0
      preference = snapshot.fetch("policy").fetch("amount_preferences", {})[name]
      if preference
        low, high = preference["min"], preference["max"]
        if (low && amount < low.to_f) || (high && amount > high.to_f)
          boundary = low && amount < low.to_f ? low.to_f : high.to_f
          fit = (amount - boundary).abs / [amount.abs, boundary.abs, 1.0].max
        end
      end
      minimum = rules["daily_turnover_min"].to_f
      effective = Money.sum(provider.fetch("daily_approved_amount"), provider.fetch("reserved_amount"))
      turnover = minimum.positive? ? 1.0 - [[(minimum - effective) / minimum, 0.0].max, 1.0].min : 1.0
      penalties = { "load" => loads.empty? ? 0.0 : loads.max,
        "margin" => rules["provider_margin_pct"].to_f / [rules["merchant_margin_pct"].to_f, 0.01].max,
        "priority" => rules["priority"].to_i / 100.0, "amount_fit" => fit, "turnover_min" => turnover }
      penalties.sum do |key, value|
        [[value.to_f, 0.0].max, 1.0].min.round(8) * snapshot.fetch("policy").fetch("weights", {}).fetch(key, 0)
      end
    end

    def self.verify_scarcity!(value, evidence, config, fallback)
      if fallback || !config.dig("opportunity", "enabled")
        exact_number!(value, 0)
        return
      end
      raise InvariantError, "scarcity evidence is missing" unless evidence.is_a?(Hash)
      before = evidence.fetch("served_before")
      after = evidence.fetch("served_after_reservation")
      size = evidence.fetch("historical_tape_size")
      raise InvariantError, "invalid scarcity evidence counts" unless [before, after, size].all? { |n| n.is_a?(Integer) && n >= 0 } && before <= size && after <= size
      if evidence.key?("historical_tape")
        raise InvariantError, "scarcity tape size differs" unless evidence.fetch("historical_tape").length == size
      end
      exact_number!(value, [before - after, 0].max)
      exact_number!(evidence.fetch("lost_service_slots"), value)
    end

    # Reconstruct hard eligibility from immutable snapshot counters. Actual
    # reservations and timestamps remain independently covered by AuditReplay.
    def self.eligible_snapshot?(snapshot, name, fallback)
      state = snapshot.fetch("providers").fetch(name)
      rules = state.fetch("rules")
      operation = snapshot.fetch("operation")
      amount = operation.fetch("amount").to_f
      return false unless rules["status"] == "active"
      return false if !fallback && rules["traffic_percentage"].to_f.zero?
      return false if rules["limit_amount_min"] && amount < rules["limit_amount_min"].to_f
      return false if rules["limit_amount_max"] && amount > rules["limit_amount_max"].to_f
      daily = Money.sum(state.fetch("daily_approved_amount"), state.fetch("reserved_amount"))
      return false if rules["daily_amount_limit"] && Money.cents(daily) + Money.cents(amount) > Money.cents(rules["daily_amount_limit"])
      return false if rules["in_progress_count_limit"] && state.fetch("effective_in_progress_count") + 1 > rules["in_progress_count_limit"].to_i
      return false if rules["in_progress_amount_limit"] && Money.cents(state.fetch("effective_in_progress_amount")) + Money.cents(amount) > Money.cents(rules["in_progress_amount_limit"])
      return false if state.fetch("available_requisites").zero?
      return false if rules["requests_per_minute_limit"] && state.fetch("rpm_count") + 1 > rules["requests_per_minute_limit"].to_i
      return false if rules["provider_margin_pct"].to_f > rules["merchant_margin_pct"].to_f && !rules["allow_negative_agreement"]
      banks = rules["banks"] || []
      return false if banks.any? && (rules["exclude_banks"] ? banks.include?(operation["bank"]) : !banks.include?(operation["bank"]))
      brands = rules["card_brands"] || []
      return false if brands.any? && operation["card_brand"] && !brands.include?(operation["card_brand"])
      true
    end

    def self.finite!(value)
      raise InvariantError, "cascade coefficient must be finite numeric" unless value.is_a?(Numeric) && value.finite?
    end

    def self.exact_number!(actual, expected)
      finite!(actual)
      finite!(expected)
      raise InvariantError, "cascade coefficient differs from snapshot" unless actual == expected
    end

    def self.close!(actual, expected)
      unless actual.is_a?(Numeric) && actual.finite? && (actual - expected).abs <= 0.00001
        raise InvariantError, "outcome plan arithmetic mismatch: #{actual.inspect} != #{expected}"
      end
    end
  end
end
