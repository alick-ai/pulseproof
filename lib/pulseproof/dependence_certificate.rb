# frozen_string_literal: true

module PulseProof
  # A success-event bound, NOT a robust optimizer. Supplied rates are treated
  # as marginals of potential binary outcomes for this frozen full cascade.
  # Pending stops execution before later successes, so this union bound must
  # not be applied to a cascade with any nonzero pending probability.
  class DependenceCertificate
    SCOPE = {
      "target" => "frozen_full_cascade",
      "marginals" => "supplied_estimates_not_confidence_bounds",
      "numeric_scope" => "exact_rational_bounds_for_exported_float_marginals_float_fields_rounded",
      "dependence" => "arbitrary_joint_distribution_with_supplied_marginals",
      "execution" => "fresh_snapshot_replanning_not_covered",
      "optimal_order_certified" => false,
      "objective_bounds_certified" => false,
      "changes_routing" => false
    }.freeze

    def self.build(model:, chain:)
      actions = model.fetch("actions")
      names = model.fetch("external_providers")
      fallback = model.fetch("fallback_provider")
      unless chain.is_a?(Array) && chain.all? { |name| name.is_a?(String) && !name.empty? } &&
          chain.uniq == chain && names.uniq == names && !names.include?(fallback) &&
          chain.sort == (names + [fallback].compact).sort && actions.keys.sort == chain.sort &&
          (!fallback || chain.last == fallback)
        raise InvariantError, "dependence certificate requires the complete frozen chain"
      end
      probabilities = chain.each_with_object({}) do |name, out|
        action = actions.fetch(name)
        %w[approval_given_terminal pending_probability].each do |key|
          value = action.fetch(key)
          unless (value.is_a?(Integer) || value.is_a?(Float) || value.is_a?(Rational)) && value.finite? && value >= 0 && value <= 1
            raise InvariantError, "invalid dependence probability: #{name}.#{key}"
          end
        end
        out[name] = action.fetch("approval_given_terminal").to_f
      end
      pending = chain.select { |name| actions.fetch(name).fetch("pending_probability") > 0 }
      certificate = {
        "version" => 1, "kind" => "frechet_terminal_success", "chain" => chain.dup,
        "scope" => SCOPE.dup, "terminal_approval_inputs" => probabilities,
        "pending_providers" => pending
      }
      reason = chain.empty? ? "empty_chain" : (pending.empty? ? nil : "pending_blocks_later_attempts")
      return certificate.merge("status" => "not_applicable", "reason" => reason) if reason

      p = probabilities.transform_values(&:to_r)
      lower = p.values.max
      upper = [p.values.sum, Rational(1)].min
      # Rational complements keep a singleton reference equal to its marginal.
      # The planner rounds each continuation to Float, so its reference can
      # differ at the last bit. Neither its coefficients nor ranking change.
      independent_fail = p.values.inject(Rational(1)) { |value, rate| value * (1 - rate) }
      fallback_p = fallback && p.fetch(fallback)
      certificate.merge(
        "status" => "certified",
        "success_probability" => { "lower" => lower.to_f, "upper" => upper.to_f },
        "all_failed_probability" => { "lower" => (1 - upper).to_f, "upper" => (1 - lower).to_f },
        "exact_bounds" => {
          "success" => { "lower" => lower.to_s, "upper" => upper.to_s },
          "all_failed" => { "lower" => (1 - upper).to_s, "upper" => (1 - lower).to_s }
        },
        "independent_reference" => { "success" => (1 - independent_fail).to_f, "all_failed" => independent_fail.to_f },
        "lower_bound_drivers" => p.keys.select { |name| p[name] == lower }.sort,
        "attainment" => { "success_lower" => "nested_success_events", "success_upper" => "maximal_union_of_success_events",
          "scope" => "each_event_probability_endpoint_is_sharp_not_all_objective_extrema_together" },
        "fallback" => { "provider" => fallback, "included" => !fallback.nil?,
          "success_probability" => fallback_p && fallback_p.to_f,
          "determines_success_lower_bound" => !fallback_p.nil? && fallback_p == lower,
          "success_lower_bound_gain_over_fallback" => fallback_p && (lower - fallback_p).to_f }
      )
    rescue KeyError, TypeError, NoMethodError => error
      raise InvariantError, "malformed dependence model: #{error.message}"
    end
  end
end
