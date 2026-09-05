# frozen_string_literal: true

module PulseProof
  # Receding one-operation cascade evaluation. Only the first action executes;
  # every confirmed failure causes a fresh hard gate and a new plan.
  class OutcomePlanner
    attr_reader :opportunity

    def initialize(profile:, history:, as_of: nil)
      @profile = profile
      @config = profile.fetch("outcome_planner")
      @fallback = profile.fetch("fallback_provider", "spacepayments")
      @opportunity = OpportunityModel.new(history: history, config: @config.fetch("opportunity", {}), fallback: @fallback, as_of: as_of)
    end

    def rank(ranking, providers:, metrics:, operation:, controller:)
      names = ranking.map { |row| row.fetch("provider") }
      fallback_ok = HardGate.new(fallback_provider: @fallback).evaluate(operation, providers.fetch(@fallback), fallback: true).eligible
      opportunity = @config.dig("opportunity", "enabled") ? @opportunity.assess(providers, operation, names + (fallback_ok ? [@fallback] : [])) : {}
      model = build_model(names, fallback_ok, providers, metrics, operation, controller, opportunity)
      optimizer = CascadeOptimizer.new(model)
      weights = @config.fetch("weights")
      chains = names.map { |name| optimizer.best_chain(weights, first: name) }
      best = chains.map { |chain| optimizer.evaluate(chain, weights) }
      best.sort_by! { |row| [optimizer.exact_cost(row["chain"], weights), row["chain"]] }
      winner = best.first
      best.map do |plan|
        original = ranking.find { |row| row["provider"] == plan["chain"].first }
        original.merge("outcome_plan" => plan.merge(
          "gap_to_best" => (plan["objective"] - winner["objective"]).round(8),
          "chains_evaluated" => chains.length, "all_external_orders_evaluated" => names.length <= 2,
          "optimization" => { "method" => "exact_pair_exchange", "exact_for_frozen_model" => true,
            "dependence_certificate_version" => 1,
            "numeric_scope" => "exact rational ordering of exported finite coefficients; displayed costs rounded", "factorial_search_used" => false },
          "alternative_terms_minus_best" => plan["terms"].each_with_object({}) { |(k,v),h| h[k] = (v - winner["terms"][k]).round(8) },
          "opportunity" => opportunity[plan["chain"].first],
          "evaluated_frontier" => plan.equal?(winner) ? best.map { |item| item.select { |key,_| %w[chain objective raw_metrics].include?(key) } } : nil,
          "cascade_model" => plan.equal?(winner) ? model : nil,
          "dependence_certificate" => DependenceCertificate.build(model: model, chain: plan.fetch("chain")),
          "scope" => "model-conditional candidate comparison; independent per-attempt rates, frozen current rules; no future queue; not a bank guarantee"))
      end
    end

    def summary(providers:, at:)
      { "enabled" => true, "execution" => "first step only; replan on confirmed failure",
        "objective" => @config.fetch("weights"), "pending_probabilities" => @config.fetch("pending_probabilities", {}),
        "model_recommendations" => @config.dig("opportunity", "enabled") ? opportunity.repairs(providers, at) : [] }
    end

    private

    def build_model(names, fallback_ok, providers, metrics, operation, controller, opportunity)
      debt = controller.snapshot
      average_amount = [debt["processed_amount"] / [debt["processed_count"], 1].max, 0.01].max
      units = operation.fetch("amount") / average_amount
      scorer = PolicyScorer.new(providers, @profile)
      actions = (names + (fallback_ok ? [@fallback] : [])).each_with_object({}) do |name, out|
        provider = providers.fetch(name)
        metric = metrics.fetch(name)
        p = metric.fetch("conservative_conversion").to_f
        sd = metric.dig("adaptive_prediction", "uncertainty_sd").to_f
        # Configurable model haircut; not a statistically calibrated bound.
        p = [[p - @config.fetch("uncertainty_haircut", 0.0) * sd, 0.0].max, 1.0].min
        t = @config.fetch("pending_probabilities", {}).fetch(name, 0.0).to_f
        seconds = provider.config.fetch("avg_latency_sec", 0).to_f
        penalties = scorer.penalties(name, metric, operation.fetch("amount"))
        business = %w[load margin priority amount_fit turnover_min].sum { |factor| penalties[factor] * @profile.fetch("weights", {}).fetch(factor, 0) }
        credit_probability = (1 - t) * p + t
        count_cost = name == @fallback ? 0.0 : credit_probability * (1 - 2 * debt["count_debt"].fetch(name))
        volume_cost = 0.0
        if name != @fallback && debt["volume_targets"].key?(name)
          d = debt["volume_debt"].fetch(name) / average_amount
          volume_cost = credit_probability * (units * units - 2 * units * d)
        end
        out[name] = { "continue_probability" => (1 - t) * (1 - p), "approval_given_terminal" => p,
          "pending_probability" => t, "latency_sec" => seconds,
          "local_metrics" => { "count_potential_change" => count_cost, "volume_potential_change" => volume_cost,
            "attempts" => 1.0, "latency_sec" => seconds,
            "pending_ruble_seconds" => t * operation.fetch("amount") * @config.fetch("pending_hold_sec", 180),
            "unresolved_or_failed_probability" => t, "fallback_probability" => name == @fallback ? 1.0 : 0.0,
            "scarcity_slots" => opportunity.fetch(name, {}).fetch("lost_service_slots", 0), "business_factors" => business } }
      end
      { "version" => 1, "external_providers" => names.sort, "fallback_provider" => fallback_ok ? @fallback : nil,
        "actions" => actions, "terminal_metrics" => { "unresolved_or_failed_probability" => 1.0 } }
    end
  end
end
