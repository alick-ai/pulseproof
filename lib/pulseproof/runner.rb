# frozen_string_literal: true

require "json"

module PulseProof
  class Runner
    Result = Struct.new(:decisions, :report, :router, keyword_init: true)

    def initialize(providers_path:, queue_path:, history_path:, profile_path:, outcome_model: nil, simulation_mode: nil)
      @providers_document = InputLoader.validate_provider_document!(InputLoader.json(providers_path))
      @queue = InputLoader.validate_queue!(InputLoader.json(queue_path))
      @history = InputLoader.history(history_path)
      @profile = InputLoader.validate_profile!(InputLoader.json(profile_path), @providers_document)
      if simulation_mode
        raise InputError, "simulation_mode must be approve or deterministic" unless %w[approve deterministic].include?(simulation_mode)
        @profile["outcome_mode"] = simulation_mode
      end
      @outcome_model = outcome_model
    end

    def run
      provider_states = @providers_document.fetch("providers").each_with_object({}) do |config, out|
        state = ProviderState.new(config)
        out[state.name] = state
      end
      trust_gate = MetricTrustGate.new(@history, provider_states, prior_strength: @profile.fetch("history_prior_strength", 12),
        as_of: @providers_document["snapshot_at"] || @queue.first && @queue.first["created_at"])
      router = Router.new(
        provider_states: provider_states,
        profile: @profile,
        metrics: trust_gate.all,
        outcome_model: @outcome_model,
        history: @history,
        history_as_of: @providers_document["snapshot_at"] || @queue.first && @queue.first["created_at"]
      )
      decisions = []
      @queue.each { |operation| decisions << router.route(operation) }
      router.ledger.verify!
      report = ReportBuilder.new(
        queue: @queue,
        decisions: decisions,
        provider_states: provider_states,
        providers_document: @providers_document,
        metrics: trust_gate.all,
        router: router,
        profile: @profile
      ).build
      StrictValidator.new(
        queue: @queue,
        providers_document: @providers_document,
        decisions: decisions,
        report: report,
        fallback_provider: @profile.fetch("fallback_provider", "spacepayments")
      ).validate!
      Result.new(decisions: decisions, report: report, router: router)
    end
  end
end
