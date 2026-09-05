# frozen_string_literal: true

module PulseProof
  # Independently rebuilds money and request counters from ordered transitions.
  # Hash integrity alone is insufficient: a perfectly hashed log may still
  # describe an illegal reservation or claim a settlement which never occurred.
  class AuditReplay
    attr_reader :providers, :settlements, :pending, :attempts, :learning_events

    def initialize(queue:, providers_document:, fallback_provider:)
      @operations = queue.each_with_object({}) { |op, out| out[op.fetch("operation_id")] = op }
      @providers = providers_document.fetch("providers").each_with_object({}) do |config, out|
        out[config.fetch("payment_system")] = ProviderState.new(config)
      end
      @fallback = fallback_provider
      @gate = HardGate.new(fallback_provider: @fallback)
      @states = {}
      @owners = {}
      @failed = Hash.new { |h, k| h[k] = [] }
      @settlements = {}
      @pending = {}
      @attempts = Hash.new { |h, k| h[k] = [] }
      @confirmed = {}
      @learning_events = {}
    end

    def call(events)
      events.each { |event| apply(event) }
      self
    end

    private

    def apply(event)
      payload = event.fetch("payload")
      if event["type"] == "learning_observed"
        id, name, attempt = payload.values_at("operation_id", "provider", "attempt")
        check(attempt.is_a?(Integer) && attempt.positive?, "invalid learning attempt")
        terminal = attempts.fetch(id, [])[attempt - 1]
        check(terminal && terminal[0] == name && %w[approved rejected].include?(terminal[1]), "learning from unconfirmed or unchosen attempt")
        expected_reward = terminal[1] == "approved" ? 1 : 0
        check(payload["reward"] == expected_reward, "learning reward differs from settled outcome")
        check(!learning_events.key?([id, attempt]), "duplicate learning observation")
        learning_events[[id, attempt]] = payload
        return
      end
      if event["type"] == "status_confirmed"
        id, name, attempt = payload.values_at("operation_id", "provider", "attempt")
        check(pending[id] == [name, attempt], "confirmed status has no matching pending owner")
        @confirmed[[id, attempt]] = payload.fetch("status")
        return
      end
      if event["type"] == "provider_rules_updated"
        name = payload.fetch("provider")
        changes = payload.fetch("changes")
        forbidden = %w[payment_system daily_approved_amount in_progress_count in_progress_amount]
        check((changes.keys & forbidden).empty?, "provider update overwrites balances")
        providers.fetch(name).config.merge!(changes)
        return
      end
      return unless event.fetch("type").start_with?("attempt_")

      id = payload.fetch("operation_id")
      operation = @operations.fetch(id) { raise InvariantError, "unknown operation in event log: #{id}" }
      attempt = payload.fetch("attempt")
      key = [id, attempt]
      state = payload.fetch("to")
      check(event["type"] == "attempt_#{state}", "event type does not match transition")
      check(payload["from"] == @states[key], "incorrect previous state for #{key}")
      check(AttemptStateMachine::TRANSITIONS.fetch(@states[key], []).include?(state), "illegal event transition for #{key}")
      if @states[key] == "timeout"
        check(@confirmed.delete(key) == state, "timeout resolved without confirmed provider status for #{id}")
      end
      metadata = payload.fetch("metadata", {})
      at = Time.iso8601(payload.fetch("at"))
      case state
      when "reserved"
        name = metadata.fetch("provider")
        check(!@owners.key?(id) && !settlements.key?(id), "multiple reservations or settlement for #{id}")
        check(Money.cents(metadata.fetch("amount")) == Money.cents(operation.fetch("amount")), "reservation amount mismatch for #{id}")
        provider = providers.fetch(name)
        if name == @fallback
          remaining = providers.values.reject { |p| p.name == @fallback || @failed[id].include?(p.name) }
          check(remaining.none? { |p| @gate.evaluate(operation, p, at: at).eligible }, "premature fallback for #{id}")
        end
        result = @gate.evaluate(operation, provider, at: at, fallback: name == @fallback)
        check(result.eligible, "hard violation for #{id}/#{name}: #{result.reason}")
        check(!@failed[id].include?(name), "retried failed provider for #{id}")
        provider.reserve!(metadata)
        provider.record_request!(at)
        @owners[id] = [name, attempt]
        check(attempt == attempts[id].length + 1, "nonsequential attempt for #{id}")
        attempts[id] << [name, nil]
      when "timeout"
        check(@owners.key?(id), "timeout without reservation for #{id}")
        check(@owners[id][1] == attempt, "timeout owner mismatch for #{id}")
        pending[id] = @owners.fetch(id)
        attempts[id].last[1] = "expired"
      when "committed"
        name, owner_attempt = @owners.fetch(id)
        check(owner_attempt == attempt && name == metadata["provider"], "settlement owner mismatch for #{id}")
        check(!settlements.key?(id), "duplicate settlement for #{id}")
        check(Money.cents(metadata.fetch("amount")) == Money.cents(operation.fetch("amount")), "settlement amount mismatch for #{id}")
        providers.fetch(name).commit!(id)
        settlements[id] = metadata
        attempts[id].last[1] = "approved"
        @owners.delete(id)
        pending.delete(id)
      when "released"
        name, owner_attempt = @owners.fetch(id)
        check(owner_attempt == attempt && name == metadata["provider"], "release owner mismatch for #{id}")
        providers.fetch(name).release!(id)
        @failed[id] << name
        attempts[id].last[1] = "rejected"
        @owners.delete(id)
        pending.delete(id)
      end
      @states[key] = state
    rescue KeyError, TypeError, ArgumentError => error
      raise InvariantError, "invalid event log: #{error.message}"
    end

    def check(condition, message)
      raise InvariantError, message unless condition
    end
  end
end
