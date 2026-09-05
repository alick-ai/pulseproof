# frozen_string_literal: true

module PulseProof
  # Ordering is exact only for the exported additive, prefix-invariant model.
  # Even with no pending and a fixed provider set, dependence can change prefix
  # reach, expected attempts, latency and attribution, hence the best order.
  # Full failure and fixed-last fallback reach are permutation-invariant for
  # that set, not the whole objective. Pending can make unresolved-or-failed
  # order-sensitive; changing composition can also change full failure.
  # Exact for this frozen additive model, not for an unknown real-world flow.
  # Pair exchange: i before j iff a_i*(1-f_j) <= a_j*(1-f_i).
  # Rational comparisons use the exact values of exported finite numbers.
  class CascadeOptimizer
    attr_reader :model

    def initialize(model)
      @model = model
      names = model.fetch("external_providers")
      raise InputError, "cascade requires unique external names" unless names.is_a?(Array) && !names.empty? && names.all? { |name| name.is_a?(String) && !name.empty? } && names.uniq == names
      raise InputError, "fallback cannot be an external candidate" if names.include?(model["fallback_provider"])
      (names + [model["fallback_provider"]].compact).each do |name|
        action = model.fetch("actions").fetch(name)
        f = action.fetch("continue_probability")
        raise InputError, "continuation must be finite in 0..1" unless f.is_a?(Numeric) && f.finite? && f.between?(0, 1)
        action.fetch("local_metrics").each_value { |value| finite!(value) }
      end
      model.fetch("terminal_metrics").each_value { |value| finite!(value) }
    end

    def local_costs(weights)
      weights.each_value { |value| finite!(value) }
      model.fetch("actions").transform_values { |action| dot(action.fetch("local_metrics"), weights) }
    end

    def best_chain(weights, first: nil)
      remaining = model.fetch("external_providers").sort
      raise InputError, "requested first provider is not eligible" if first && !remaining.include?(first)
      costs = local_costs(weights)
      chain = []
      if first
        chain << first
        remaining.delete(first)
      end
      until remaining.empty?
        if chain.any? && continuation(chain.last).zero?
          chain.concat(remaining.sort) # unreachable suffix: canonical lexical tie
          break
        end
        # Unlike comparator+name sort this handles neutral f=1,a=0 actions
        # without a non-transitive comparator. O(n^3), no factorial search.
        chosen = remaining.find do |name|
          remaining.all? { |other| costs[name] * (1 - continuation(other)) <= costs[other] * (1 - continuation(name)) }
        end
        raise InvariantError, "no exact cascade minimum" unless chosen
        chain << chosen
        remaining.delete(chosen)
      end
      chain << model["fallback_provider"] if model["fallback_provider"]
      chain
    end

    def exact_cost(chain, weights)
      costs = local_costs(weights)
      reach = Rational(1)
      total = Rational(0)
      chain.each do |name|
        total += reach * costs.fetch(name)
        reach *= continuation(name)
      end
      total + reach * dot(model.fetch("terminal_metrics"), weights)
    end

    def evaluate(chain, weights)
      raw = Hash.new(Rational(0))
      reach = Rational(1)
      approved, pending, inputs = {}, {}, {}
      chain.each do |name|
        action = model.fetch("actions").fetch(name)
        action.fetch("local_metrics").each { |key, value| raw[key] += reach * value.to_r }
        p, t = action.fetch("approval_given_terminal"), action.fetch("pending_probability")
        approved[name] = reach.to_f * (1 - t) * p
        pending[name] = reach.to_f * t
        inputs[name] = { "approval_given_terminal" => p, "pending_probability" => t,
          "latency_sec" => action.fetch("latency_sec"), "reach_probability" => reach.to_f,
          "probability_source" => "configured pending; estimated terminal acceptance" }
        reach *= action.fetch("continue_probability").to_r
      end
      model.fetch("terminal_metrics").each { |key, value| raw[key] += reach * value.to_r }
      terms = {}
      raw.each { |key, value| terms[key] = value * weights.fetch(key, 0).to_r }
      objective = exact_cost(chain, weights).to_f
      finite!(objective)
      { "chain" => chain, "objective" => objective.round(8), "objective_unrounded" => objective,
        "terms" => terms.transform_values { |value| rounded(value) },
        "raw_metrics" => raw.transform_values { |value| rounded(value) },
        "final_approval_probabilities" => approved, "pending_probabilities" => pending,
        "all_failed_probability" => reach.to_f, "model_inputs" => inputs }
    end

    def continuation(name)
      model.fetch("actions").fetch(name).fetch("continue_probability").to_r
    end

    private

    def rounded(value)
      number = value.to_f
      finite!(number)
      number.round(8)
    end

    def dot(metrics, weights)
      metrics.sum { |key, value| value.to_r * weights.fetch(key, 0).to_r }
    end

    def finite!(value)
      raise InputError, "cascade coefficients must be finite numeric" unless value.is_a?(Numeric) && value.finite?
    end
  end
end
