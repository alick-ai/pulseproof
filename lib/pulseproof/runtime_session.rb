# frozen_string_literal: true

module PulseProof
  # Streaming boundary: one request, control update or correlated status per
  # message. It never receives future operations. Memory only, not a database.
  class RuntimeSession
    attr_reader :router, :operations, :decisions

    def initialize(providers_document:, profile:, history:, outcome_model: nil)
      @document = Marshal.load(Marshal.dump(InputLoader.validate_provider_document!(providers_document)))
      @profile = InputLoader.validate_profile!(profile, @document)
      @history = history
      @outcome_model = outcome_model
      @operations = {}
      @decisions = {}
    end

    def process(event)
      raise InputError, "runtime event must be an object" unless event.is_a?(Hash)
      type = event.fetch("type")
      initialize_router!(event) unless router
      case type
      when "operation"
        operation = event.fetch("operation")
        decision = router.route(operation)
        id = operation.fetch("operation_id")
        operations[id] ||= Marshal.load(Marshal.dump(operation))
        decisions[id] = decision
        { "type" => "decision", "decision" => decision }
      when "provider_update"
        snapshot = router.update_provider!(provider_name: event.fetch("provider"), changes: event.fetch("changes"), at: event.fetch("at"))
        { "type" => "provider_updated", "snapshot" => snapshot }
      when "status"
        result = router.reconcile(operation_id: event.fetch("operation_id"), provider_name: event.fetch("provider"),
          attempt: event.fetch("attempt"), status: event.fetch("status"), at: event.fetch("at"), status_event_id: event.fetch("event_id"))
        decisions[result["operation_id"]] = result if result.key?("selected_provider")
        { "type" => "status_result", "result" => result }
      when "report"
        { "type" => "report", "report" => report }
      else
        raise InputError, "unsupported runtime event type: #{type}"
      end
    rescue KeyError, ArgumentError, TypeError => error
      raise InputError, "invalid runtime event: #{error.message}"
    end

    def report
      raise InputError, "no runtime session yet" unless router
      value = ReportBuilder.new(queue: operations.values, decisions: decisions.values,
        provider_states: router.providers, providers_document: @document,
        metrics: router.metrics, router: router, profile: @profile).build
      StrictValidator.new(queue: operations.values, providers_document: @document,
        decisions: decisions.values, report: value, fallback_provider: @profile.fetch("fallback_provider", "spacepayments")).validate!
      value
    end

    private

    def initialize_router!(event)
      states = @document.fetch("providers").each_with_object({}) do |config, out|
        state = ProviderState.new(config)
        out[state.name] = state
      end
      as_of = @document["snapshot_at"] || event["at"] || event.dig("operation", "created_at")
      metrics = MetricTrustGate.new(@history, states, prior_strength: @profile.fetch("history_prior_strength", 12), as_of: as_of).all
      @router = Router.new(provider_states: states, profile: @profile, metrics: metrics, outcome_model: @outcome_model,
        history: @history, history_as_of: as_of)
    end
  end
end
