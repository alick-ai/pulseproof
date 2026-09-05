# frozen_string_literal: true

module PulseProof
  # New reports use the complete local model with parametric reoptimization.
  # Older reports retain their explicitly scoped frozen-matrix analysis.
  # Does not claim a globally optimal configuration for the future stream.
  class PolicyChallenge
    def initialize(weights:, frontier: nil, model: nil)
      @frontier, @weights, @model = frontier, weights, model
    end

    def call(prefer:, factor:)
      return CascadeSensitivity.new(model: @model, weights: @weights).call(prefer: prefer, factor: factor) if @model
      raise InputError, "challenge requires a cascade model or legacy frontier" unless @frontier
      raise InputError, "unknown challenge factor #{factor}" unless @frontier.first && @frontier.first.fetch("raw_metrics").key?(factor)
      target = @frontier.select { |plan| plan.fetch("chain").first == prefer }
      return { "status" => "not_eligible", "provider" => prefer, "reason" => "no legal first action in this attempt; changing soft weights cannot bypass hard exclusions or retry an exhausted provider" } if target.empty?
      old = @weights.fetch(factor, 0.0)
      baseline = winner(factor, old)
      if baseline["chain"].first == prefer
        return { "status" => "already_selected", "provider" => prefer, "factor" => factor, "current_weight" => old }
      end
      solutions = target.map do |plan|
        interval = winning_interval(plan, factor)
        next unless interval
        low, high = interval
        closest = [[old, low].max, high].min
        epsilon = 1e-6 * (1 + closest.abs)
        candidates = [closest, closest + epsilon, closest - epsilon, low, low + epsilon]
        candidates += [high, high - epsilon, (low + high) / 2] if high.finite?
        verified = candidates.uniq.select { |w| w.finite? && w >= low && w <= high && w >= 0 }.map do |value|
          selected = winner(factor, value)
          next unless selected["chain"].first == prefer
          { "proposed_weight" => value, "verified_chain" => selected["chain"], "absolute_change" => (value - old).abs,
            "winning_interval" => { "lower_inclusive" => low, "upper_inclusive" => high.finite? ? high : nil },
            "nearest_boundary" => closest }
        end.compact
        verified.min_by { |row| row["absolute_change"] }
      end.compact
      chosen = solutions.min_by { |row| [row["absolute_change"], row["verified_chain"]] }
      return { "status" => "no_single_weight_solution", "provider" => prefer, "factor" => factor,
        "reason" => "no verified winning interval for this one nonnegative weight in the evaluated candidate set" } unless chosen
      changed = @weights.merge(factor => chosen["proposed_weight"])
      costs = @frontier.map { |plan| { "chain" => plan["chain"], "cost_after" => cost(plan, changed) } }.sort_by { |r| [r["cost_after"],r["chain"]] }
      chosen.merge("status" => "verified_counterfactual", "provider" => prefer, "factor" => factor,
        "current_weight" => old, "original_chain" => baseline["chain"], "recalculated_candidates" => costs,
        "boundary_note" => "linear boundary on exported rounded metrics; a small interior step may resolve ties",
        "scope" => "same snapshot, same candidate set, one nonnegative coefficient; no real rules changed, no future-performance claim")
    end

    private

    def cost(plan, weights)
      plan.fetch("raw_metrics").sum { |key, value| value * weights.fetch(key, 0.0) }.round(8)
    end

    def winner(factor, value)
      changed = @weights.merge(factor => value)
      @frontier.min_by { |plan| [cost(plan, changed), plan["chain"]] }
    end

    def winning_interval(plan, factor)
      low, high = 0.0, Float::INFINITY
      @frontier.each do |other|
        a = plan["raw_metrics"][factor] - other["raw_metrics"][factor]
        b = plan["raw_metrics"].sum { |key, value| key == factor ? 0 : (value - other["raw_metrics"][key]) * @weights.fetch(key, 0.0) }
        if a.abs < 1e-12
          return nil if b > 1e-10
        elsif a > 0
          high = [high, -b / a].min
        else
          low = [low, -b / a].max
        end
        return nil if low > high
      end
      [low, high]
    end
  end
end
