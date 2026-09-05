# frozen_string_literal: true

require "time"

module PulseProof
  class EventStore
    attr_reader :events

    def initialize
      @events = []
      @events_by_operation = Hash.new { |hash, key| hash[key] = [] }
    end

    def append(type, payload)
      body = Redactor.call(payload)
      event = {
        "event_id" => Canonical.event_id(events.length + 1, body.merge("type" => type)),
        "sequence" => events.length + 1,
        "type" => type,
        "recorded_at" => deterministic_recorded_at(body),
        "payload" => body,
        "previous_hash" => events.empty? ? nil : events.last.fetch("event_hash")
      }
      event["event_hash"] = Canonical.digest(event)
      events << event
      operation_id = body["operation_id"]
      @events_by_operation[operation_id] << event if operation_id
      event
    end

    def for_operation(operation_id)
      @events_by_operation.fetch(operation_id, []).dup
    end

    def verify_tail!
      return true if events.empty?

      event = events.last
      raise InvariantError, "event sequence broken at #{events.length}" unless event["sequence"] == events.length
      previous = events.length == 1 ? nil : events[-2]["event_hash"]
      raise InvariantError, "event chain broken at #{events.length}" unless event["previous_hash"] == previous
      check = event.dup
      expected = check.delete("event_hash")
      raise InvariantError, "event hash broken at #{events.length}" unless Canonical.digest(check) == expected
      true
    end

    def verify!
      previous = nil
      events.each_with_index do |event, index|
        raise InvariantError, "event sequence broken at #{index + 1}" unless event["sequence"] == index + 1
        raise InvariantError, "event chain broken at #{index + 1}" unless event["previous_hash"] == previous
        check = event.dup
        expected = check.delete("event_hash")
        raise InvariantError, "event hash broken at #{index + 1}" unless Canonical.digest(check) == expected
        previous = expected
      end
      true
    end

    private

    def deterministic_recorded_at(payload)
      payload["at"] || payload["created_at"] || "sequence:#{events.length + 1}"
    end
  end
end
