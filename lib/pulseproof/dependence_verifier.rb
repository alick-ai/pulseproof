# frozen_string_literal: true

module PulseProof
  # Independent reconstruction using failure intersections (the producer uses
  # success unions). Never invokes the producer or the cascade optimizer.
  # PlanVerifier first binds these model inputs to the operation's snapshot.
  class DependenceVerifier
    def self.verify!(certificate, inputs:, chain:, fallback:)
      probabilities = chain.each_with_object({}) { |name, out| out[name] = inputs.fetch(name).fetch("approval_given_terminal").to_f }
      pending = chain.select { |name| inputs.fetch(name).fetch("pending_probability") > 0 }
      expected = {
        "version" => 1, "kind" => "frechet_terminal_success", "chain" => chain,
        "scope" => DependenceCertificate::SCOPE.dup, "terminal_approval_inputs" => probabilities,
        "pending_providers" => pending
      }
      if chain.empty? || !pending.empty?
        expected.merge!("status" => "not_applicable", "reason" => chain.empty? ? "empty_chain" : "pending_blocks_later_attempts")
      else
        q = probabilities.transform_values { |p| Rational(1) - p.to_r }
        failure_upper = q.values.min
        failure_lower = [Rational(0), q.values.sum - (chain.length - 1)].max
        reference = q.values.inject(Rational(1), :*)
        fallback_p = fallback && probabilities.fetch(fallback).to_r
        expected.merge!(
          "status" => "certified",
          "success_probability" => { "lower" => (1 - failure_upper).to_f, "upper" => (1 - failure_lower).to_f },
          "all_failed_probability" => { "lower" => failure_lower.to_f, "upper" => failure_upper.to_f },
          "exact_bounds" => {
            "success" => { "lower" => (1 - failure_upper).to_s, "upper" => (1 - failure_lower).to_s },
            "all_failed" => { "lower" => failure_lower.to_s, "upper" => failure_upper.to_s }
          },
          "independent_reference" => { "success" => (1 - reference).to_f, "all_failed" => reference.to_f },
          "lower_bound_drivers" => q.select { |_name, value| value == failure_upper }.keys.sort,
          "attainment" => { "success_lower" => "nested_success_events", "success_upper" => "maximal_union_of_success_events",
            "scope" => "each_event_probability_endpoint_is_sharp_not_all_objective_extrema_together" },
          "fallback" => { "provider" => fallback, "included" => !fallback.nil?,
            "success_probability" => fallback_p && fallback_p.to_f,
            "determines_success_lower_bound" => !fallback_p.nil? && (1 - fallback_p) == failure_upper,
            "success_lower_bound_gain_over_fallback" => fallback_p && (1 - failure_upper - fallback_p).to_f }
        )
      end
      raise InvariantError, "dependence certificate differs from frozen inputs or scope" unless certificate == expected
      true
    rescue KeyError, TypeError, NoMethodError => error
      raise InvariantError, "malformed dependence certificate: #{error.message}"
    end
  end
end
