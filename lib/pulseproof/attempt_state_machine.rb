# frozen_string_literal: true

module PulseProof
  class AttemptStateMachine
    TRANSITIONS = {
      nil => %w[received],
      "received" => %w[evaluated],
      "evaluated" => %w[reserved],
      "reserved" => %w[sent],
      "sent" => %w[approved rejected cancelled timeout],
      "timeout" => %w[approved rejected cancelled],
      "approved" => %w[committed],
      "rejected" => %w[released],
      "cancelled" => %w[released],
      "released" => %w[reroute],
      "committed" => [],
      "reroute" => []
    }.freeze

    attr_reader :states

    def initialize(event_store)
      @event_store = event_store
      @states = {}
    end

    def transition!(operation_id:, attempt:, to:, at:, metadata: {})
      key = key_for(operation_id, attempt)
      from = states[key]
      allowed = TRANSITIONS.fetch(from) { [] }
      raise TransitionError, "illegal transition #{from.inspect} -> #{to} for #{key}" unless allowed.include?(to)
      states[key] = to
      @event_store.append("attempt_#{to}", {
        "operation_id" => operation_id,
        "attempt" => attempt,
        "from" => from,
        "to" => to,
        "at" => at,
        "metadata" => metadata
      })
    end

    def state(operation_id, attempt)
      states[key_for(operation_id, attempt)]
    end

    private

    def key_for(operation_id, attempt)
      "#{operation_id}:#{attempt}"
    end
  end
end
