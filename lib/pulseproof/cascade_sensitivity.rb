# frozen_string_literal: true

module PulseProof
  # Parametric exact ordering, including neutral actions and canonical ties.
  # All pair-exchange signs are constant between their affine crossings.
  # Reoptimize each cell/boundary; never freeze the original best continuations.
  class CascadeSensitivity
    def initialize(model:, weights:)
      @model, @weights = model, weights
      @optimizer = CascadeOptimizer.new(model)
      @names = model.fetch("external_providers").sort
      @optimizer.local_costs(weights) # validate before rational arithmetic
    end

    def call(prefer:, factor:)
      factors = @model.fetch("actions").values.flat_map { |a| a.fetch("local_metrics").keys } + @model.fetch("terminal_metrics").keys
      raise InputError, "unknown challenge factor #{factor}" unless factors.include?(factor)
      common = { "provider" => prefer, "factor" => factor,
        "method" => "exact_parametric_pair_exchange",
        "scope" => "same exported frozen model, all legal external orders, one nonnegative coefficient; fallback remains last; no real rules or future outcomes changed" }
      unless @names.include?(prefer)
        return common.merge("status" => "not_eligible", "reason" => "no legal first action in this attempt; soft weights cannot bypass hard exclusions or retry an exhausted provider")
      end
      old = @weights.fetch(factor, 0).to_r
      raise InputError, "challenge requires nonnegative current weight" if old < 0
      baseline = @optimizer.best_chain(@weights)
      common.merge!("current_weight" => old.to_f, "original_chain" => baseline)
      return common.merge("status" => "already_selected") if baseline.first == prefer

      boundaries = crossings(factor)
      regions = []
      boundaries.each_with_index do |low, index|
        regions << region(low, low, true, true) if wins?(prefer, factor, low)
        high = boundaries[index + 1]
        probe = high ? (low + high) / 2 : low + 1
        regions << region(low, high, false, false) if wins?(prefer, factor, probe)
      end
      regions = merge_regions(regions)
      common.merge!("crossing_count" => boundaries.length - 1, "winning_regions" => regions.map { |r| export_region(r) })
      if regions.empty?
        return common.merge("status" => "no_single_weight_solution", "reason" => "no nonnegative weight selects this provider under canonical exact ordering, including every boundary and open cell")
      end

      candidates = regions.flat_map do |r|
        float_candidates(r, old).map do |value|
          next unless contains?(r, value.to_r) && wins?(prefer, factor, value)
          { value: value, region: r, distance: (value.to_r - old).abs }
        end.compact
      end
      chosen = candidates.min_by { |c| [c[:distance], c[:value]] }
      unless chosen
        return common.merge("status" => "no_representable_weight", "reason" => "winning real-valued regions exist but contain no verified finite Float weight")
      end
      value = chosen[:value]
      changed = @weights.merge(factor => value)
      verified = @optimizer.best_chain(changed)
      exact_candidates = @names.map do |name|
        chain = @optimizer.best_chain(changed, first: name)
        [@optimizer.exact_cost(chain, changed), chain]
      end.sort_by { |cost, chain| [cost, chain] }
      costs = exact_candidates.map do |cost, chain|
        { "chain" => chain, "cost_after" => finite_float(cost),
          "cost_after_exact" => cost.to_s, "gap_to_best_unrounded" => finite_float(cost - exact_candidates.first.first) }
      end
      r = chosen[:region]
      nearest = old < r[:low] ? r[:low] : (r[:high] && old > r[:high] ? r[:high] : old)
      common.merge("status" => "verified_counterfactual", "proposed_weight" => value,
        "absolute_change" => finite_float(chosen[:distance]), "verified_chain" => verified,
        "adjacent_weight_toward_current" => adjacent_toward_current(value, old, factor),
        "winning_interval" => export_region(r), "nearest_boundary" => finite_float(nearest),
        "recalculated_candidates" => costs,
        "boundary_note" => "exact rational boundaries of exported finite coefficients; open endpoints reflect canonical ties; proposed Float is verified after reoptimizing the entire cascade")
    end

    private

    def adjacent_toward_current(value, old, factor)
      adjacent = value.to_r > old ? value.prev_float : value.next_float
      return nil unless adjacent.finite? && adjacent >= 0
      { "weight" => adjacent, "chain" => @optimizer.best_chain(@weights.merge(factor => adjacent)) }
    end

    def crossings(factor)
      fixed = @optimizer.local_costs(@weights.merge(factor => 0))
      roots = [Rational(0)]
      @names.combination(2) do |a, b|
        qa, qb = 1 - @optimizer.continuation(a), 1 - @optimizer.continuation(b)
        ma = @model["actions"][a]["local_metrics"].fetch(factor, 0).to_r
        mb = @model["actions"][b]["local_metrics"].fetch(factor, 0).to_r
        slope = ma * qb - mb * qa
        next if slope.zero?
        root = -(fixed[a] * qb - fixed[b] * qa) / slope
        roots << root if root >= 0
      end
      roots.uniq.sort
    end

    def wins?(prefer, factor, value)
      @optimizer.best_chain(@weights.merge(factor => value)).first == prefer
    end

    def region(low, high, low_closed, high_closed)
      { low: low, high: high, low_closed: low_closed, high_closed: high_closed }
    end

    def merge_regions(regions)
      regions.each_with_object([]) do |r, merged|
        previous = merged.last
        if previous && previous[:high] == r[:low] && (previous[:high_closed] || r[:low_closed])
          previous[:high], previous[:high_closed] = r[:high], r[:high_closed]
        else
          merged << r.dup
        end
      end
    end

    def contains?(r, value)
      (value > r[:low] || (r[:low_closed] && value == r[:low])) &&
        (r[:high].nil? || value < r[:high] || (r[:high_closed] && value == r[:high]))
    end

    def float_candidates(r, old)
      anchors = [old, r[:low]]
      anchors += r[:high] ? [r[:high], (r[:low] + r[:high]) / 2] : [r[:low] + 1]
      anchors.flat_map do |exact|
        value = exact.to_f
        # next/prev include the closest Float on either side of an exact root.
        value.finite? ? [value.prev_float, value, value.next_float] : [Float::MAX]
      end.select { |v| v.finite? && v >= 0 }.uniq
    end

    def export_region(r)
      { "lower" => finite_float(r[:low]), "upper" => r[:high] && finite_float(r[:high]),
        "lower_closed" => r[:low_closed], "upper_closed" => r[:high_closed],
        "lower_exact" => r[:low].to_s, "upper_exact" => r[:high] && r[:high].to_s }
    end

    def finite_float(value)
      number = value.to_f
      number.finite? ? number : nil # exact strings distinguish huge finite bounds from infinity
    end
  end
end
