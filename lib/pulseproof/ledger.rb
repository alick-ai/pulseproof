# frozen_string_literal: true

require "set"

module PulseProof
  class Ledger
    attr_reader :providers, :event_store, :machine, :settlements, :pending

    def initialize(provider_states, event_store = EventStore.new)
      @providers = provider_states
      @event_store = event_store
      @machine = AttemptStateMachine.new(event_store)
      @settlements = {}
      @pending = {}
      @processed_status_events = {}
    end

    def begin_attempt!(operation, attempt)
      at = operation.fetch("created_at")
      machine.transition!(operation_id: operation.fetch("operation_id"), attempt: attempt, to: "received", at: at)
      machine.transition!(operation_id: operation.fetch("operation_id"), attempt: attempt, to: "evaluated", at: at)
    end

    def reserve!(operation, provider_name, attempt, state_hash:)
      operation_id = operation.fetch("operation_id")
      at = operation.fetch("created_at")
      provider = providers.fetch(provider_name)
      reservation = {
        "reservation_id" => reservation_id(operation_id, provider_name, attempt),
        "operation_id" => operation_id,
        "provider" => provider_name,
        "attempt" => attempt,
        "amount" => operation.fetch("amount").to_f,
        "at" => at,
        "state_hash_before" => state_hash
      }
      provider.reserve!(reservation)
      provider.record_request!(Time.parse(at))
      machine.transition!(operation_id: operation_id, attempt: attempt, to: "reserved", at: at, metadata: reservation)
      machine.transition!(operation_id: operation_id, attempt: attempt, to: "sent", at: at, metadata: { "provider" => provider_name })
      reservation
    end

    def approve!(operation_id, provider_name, attempt, at:, latency_sec:)
      ensure_not_final!(operation_id)
      machine.transition!(operation_id: operation_id, attempt: attempt, to: "approved", at: at, metadata: { "latency_sec" => latency_sec })
      reservation = providers.fetch(provider_name).commit!(operation_id)
      settlement = {
        "operation_id" => operation_id,
        "provider" => provider_name,
        "amount" => reservation.fetch("amount"),
        "status" => "approved",
        "attempt" => attempt,
        "latency_sec" => latency_sec.to_f,
        "settled_at" => at
      }
      settlements[operation_id] = settlement
      pending.delete(operation_id)
      machine.transition!(operation_id: operation_id, attempt: attempt, to: "committed", at: at, metadata: settlement)
      settlement
    end

    def reject!(operation_id, provider_name, attempt, at:, status: "rejected")
      terminal = status == "cancelled" ? "cancelled" : "rejected"
      machine.transition!(operation_id: operation_id, attempt: attempt, to: terminal, at: at)
      reservation = providers.fetch(provider_name).release!(operation_id)
      pending.delete(operation_id)
      machine.transition!(operation_id: operation_id, attempt: attempt, to: "released", at: at, metadata: reservation)
      machine.transition!(operation_id: operation_id, attempt: attempt, to: "reroute", at: at, metadata: { "provider" => provider_name })
      reservation
    end

    def timeout!(operation_id, provider_name, attempt, at:, latency_sec:)
      machine.transition!(operation_id: operation_id, attempt: attempt, to: "timeout", at: at, metadata: { "latency_sec" => latency_sec })
      pending[operation_id] = {
        "operation_id" => operation_id,
        "provider" => provider_name,
        "attempt" => attempt,
        "latency_sec" => latency_sec.to_f,
        "at" => at
      }
      pending[operation_id]
    end

    def reconcile_timeout!(operation_id, provider_name:, attempt:, status:, at:, latency_sec:, status_event_id:)
      raise TransitionError, "unsupported timeout resolution: #{status}" unless %w[approved rejected cancelled].include?(status)
      key = [operation_id, provider_name, attempt, status_event_id]
      if @processed_status_events.key?(key)
        raise TransitionError, "conflicting status event: #{status_event_id}" unless @processed_status_events[key] == status
        return { "duplicate" => true, "status_event_id" => status_event_id }
      end
      timeout_state = pending[operation_id]
      unless timeout_state && timeout_state["provider"] == provider_name && timeout_state["attempt"] == attempt
        event_store.append("status_event_ignored", {
          "operation_id" => operation_id,
          "provider" => provider_name,
          "attempt" => attempt,
          "status" => status,
          "status_event_id" => status_event_id,
          "at" => at,
          "reason" => timeout_state ? "stale_attempt" : "no_matching_pending_timeout"
        })
        return { "ignored" => true, "status_event_id" => status_event_id }
      end

      event_store.append("status_confirmed", {
        "operation_id" => operation_id, "provider" => provider_name, "attempt" => attempt,
        "status" => status, "status_event_id" => status_event_id, "at" => at
      })
      if status == "approved"
        result = approve!(operation_id, provider_name, attempt, at: at, latency_sec: latency_sec)
      else
        result = reject!(operation_id, provider_name, attempt, at: at, status: status)
      end
      @processed_status_events[key] = status
      result
    end

    def verify!
      event_store.verify!
      verify_reservation_invariants!
    end

    def verify_current!
      event_store.verify_tail!
      verify_reservation_invariants!
    end

    def snapshot
      {
        "providers" => providers.each_with_object({}) { |(name, provider), out| out[name] = provider.snapshot },
        "settlements" => settlements.dup,
        "pending" => pending.dup,
        "event_head" => event_store.events.empty? ? nil : event_store.events.last["event_hash"]
      }
    end

    def routing_snapshot
      {
        "settled_count" => settlements.length,
        "pending" => pending.dup,
        "reservations" => providers.each_with_object({}) do |(name, provider), out|
          out[name] = provider.reservations.values.map do |reservation|
            reservation.slice("reservation_id", "operation_id", "amount", "attempt")
          end
        end,
        "event_head" => event_store.events.empty? ? nil : event_store.events.last["event_hash"]
      }
    end

    private

    def verify_reservation_invariants!
      duplicate_reservations = providers.values.flat_map { |provider| provider.reservations.keys }
      if duplicate_reservations.length != duplicate_reservations.uniq.length
        raise InvariantError, "operation reserved by more than one provider"
      end
      overlap = settlements.keys & duplicate_reservations
      raise InvariantError, "settled operation remains reserved: #{overlap.join(', ')}" if overlap.any?
      true
    end

    def ensure_not_final!(operation_id)
      raise InvariantError, "operation already settled: #{operation_id}" if settlements.key?(operation_id)
    end

    def reservation_id(operation_id, provider_name, attempt)
      "res_#{Canonical.digest([operation_id, provider_name, attempt])[0, 14]}"
    end
  end
end
