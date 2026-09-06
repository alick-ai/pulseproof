# frozen_string_literal: true

module PulseProof
  class StrictValidator
    attr_reader :errors

    def initialize(queue:, providers_document:, decisions:, report:, fallback_provider: "spacepayments")
      @queue = queue
      @providers_document = providers_document
      @decisions = decisions
      @report = report
      @fallback_provider = fallback_provider
      @errors = []
    end

    def validate!
      errors << "decisions must be an array" unless @decisions.is_a?(Array)
      errors << "report must be an object" unless @report.is_a?(Hash)
      raise InvariantError, errors.join("\n") if errors.any?

      validate_coverage
      validate_structure
      raise InvariantError, errors.join("\n") if errors.any?
      validate_event_log
      raise InvariantError, errors.join("\n") if errors.any?
      validate_routing
      @report.fetch("proof_capsules").each_value do |proof|
        planned = proof.fetch("attempt_snapshots", []).any? { |s| s.dig("snapshot", "policy", "outcome_planner", "enabled") }
        PlanVerifier.verify!(proof, @fallback_provider) if planned
      end
      validate_report
      validate_capacity_explanation
      validate_pii
      raise InvariantError, errors.join("\n") if errors.any?
      true
    end

    private

    def validate_capacity_explanation
      marker = @report.dig("audit", "capacity_explanation_schema")
      return if marker.nil? && !@report.key?("capacity_explanation")

      unless marker == 1 && @report["capacity_explanation"].is_a?(Hash)
        errors << "capacity explanation is missing or has an unsupported schema"
        return
      end
      expected = CapacityExplanation.new(queue: @queue, decisions: @decisions,
        providers_document: @providers_document, fallback_provider: @fallback_provider,
        snapshot_unchanged: !@report.fetch("event_log").any? { |event| event["type"] == "provider_rules_updated" }).build
      unless Canonical.digest(expected) == Canonical.digest(@report["capacity_explanation"])
        errors << "capacity explanation differs from original inputs, decisions or scope"
      end
    end

    def validate_coverage
      unless @decisions.all? { |row| row.is_a?(Hash) }
        errors << "every decision must be an object"
        raise InvariantError, errors.join("\n")
      end
      queue_ids = @queue.map { |operation| operation["operation_id"] }
      decision_ids = @decisions.map { |decision| decision["operation_id"] }
      unless decision_ids.all? { |id| id.is_a?(String) && !id.empty? }
        errors << "decision operation_id must be a non-empty string"
        return
      end
      errors << "decision operation_id values are not unique" unless decision_ids.uniq.length == decision_ids.length
      errors << "decision coverage differs from queue" unless queue_ids.sort == decision_ids.sort
    end

    def validate_structure
      %w[distribution volume_distribution projected_daily_utilization provider_outcomes reconciliation audit proof_capsules].each do |field|
        errors << "report #{field} must be an object" unless @report[field].is_a?(Hash)
      end
      @decisions.each do |decision|
        id = decision["operation_id"] || "unknown"
        %w[operation_id selected_provider attempts simulated_result latency_sec].each do |field|
          errors << "#{id}: missing #{field}" unless decision.key?(field)
        end
        errors << "#{id}: invalid simulated_result" unless %w[approved rejected expired].include?(decision["simulated_result"])
        errors << "#{id}: latency_sec must be non-negative" unless decision["latency_sec"].is_a?(Numeric) && decision["latency_sec"] >= 0
        attempts = decision["attempts"]
        unless attempts.is_a?(Array) && !attempts.empty?
          errors << "#{id}: attempts must be a non-empty array"
          next
        end
        attempts.each_with_index do |attempt, index|
          unless attempt.is_a?(Hash)
            errors << "#{id}: attempts[#{index}] must be an object"
            next
          end
          %w[provider decision reason].each { |field| errors << "#{id}: attempts[#{index}] missing #{field}" unless attempt.key?(field) }
          errors << "#{id}: attempts[#{index}] invalid decision" unless %w[selected skipped].include?(attempt["decision"])
          errors << "#{id}: attempts[#{index}] empty reason" if attempt["reason"].to_s.empty?
          if attempt.key?("result") && !%w[approved rejected expired].include?(attempt["result"])
            errors << "#{id}: attempts[#{index}] invalid result"
          end
        end
        next unless attempts.all? { |attempt| attempt.is_a?(Hash) }
        selected = attempts.select { |attempt| attempt["decision"] == "selected" }
        errors << "#{id}: no selected attempt" if selected.empty?
        selected.each_with_index do |attempt, index|
          errors << "#{id}: selected attempt #{index + 1} missing result" unless attempt.key?("result")
          if attempt.key?("resolution") && (attempt["result"] != "expired" || !%w[approved rejected cancelled].include?(attempt["resolution"]))
            errors << "#{id}: invalid timeout resolution"
          end
          if index < selected.length - 1 && effective_result(attempt) != "rejected"
            errors << "#{id}: cascade continued before confirmed rejection"
          end
          if attempt.key?("latency_sec") && (!attempt["latency_sec"].is_a?(Numeric) || attempt["latency_sec"].negative?)
            errors << "#{id}: selected attempt #{index + 1} latency_sec must be non-negative"
          end
        end
        final_attempt = selected.last
        if final_attempt && final_attempt["provider"] != decision["selected_provider"]
          errors << "#{id}: selected_provider differs from final selected attempt"
        end
        if final_attempt && effective_result(final_attempt) != decision["simulated_result"]
          errors << "#{id}: simulated_result differs from final selected attempt"
        end
      end
    end

    def validate_routing
      if @report["event_log"].is_a?(Array)
        replay = AuditReplay.new(queue: @queue, providers_document: @providers_document, fallback_provider: @fallback_provider)
        begin
          replay.call(@report["event_log"])
          @replayed_providers = replay.providers
          learning = @report["adaptive_learning"]
          if learning && learning["enabled"]
            errors << "learning observations do not match ledger" unless learning["observed_terminal_attempts"] == replay.learning_events.length
            if learning["learn_from_outcomes"]
              confirmed = replay.attempts.values.flatten(1).count { |row| %w[approved rejected].include?(row[1]) }
              errors << "confirmed attempts missing from learning ledger" unless confirmed == replay.learning_events.length
            end
          end
          @decisions.each do |decision|
            id = decision.fetch("operation_id")
            selected = decision["attempts"].select { |row| row["decision"] == "selected" }
            logged = replay.attempts.fetch(id, [])
            expected = selected.map { |row| [row["provider"], effective_result(row)] }
            errors << "#{id}: attempts differ from event log" unless logged == expected
            final = replay.settlements[id]
            if decision["simulated_result"] == "approved"
              errors << "#{id}: approved result has no matching ledger settlement" unless final && final["provider"] == decision["selected_provider"]
            elsif decision["simulated_result"] == "expired"
              pending = replay.pending[id]
              errors << "#{id}: expired result has no matching pending reservation" unless pending && pending[0] == decision["selected_provider"]
            else
              errors << "#{id}: rejected result still reserved or settled" if final || replay.pending.key?(id)
            end
          end
          return
        rescue InvariantError => error
          errors << error.message
          raise InvariantError, errors.join("\n")
        end
      end
      provider_states = @providers_document.fetch("providers").each_with_object({}) do |config, out|
        state = ProviderState.new(config)
        out[state.name] = state
      end
      @replayed_providers = provider_states
      fallback_name = @fallback_provider
      gate = HardGate.new(fallback_provider: fallback_name)
      decisions_by_id = @decisions.each_with_object({}) { |decision, out| out[decision["operation_id"]] = decision }

      @queue.each do |operation|
        decision = decisions_by_id[operation["operation_id"]]
        next unless decision
        external = provider_states.values.reject { |provider| provider.name == fallback_name }
        eligible = external.select { |provider| gate.evaluate(operation, provider).eligible }.map(&:name)
        selected = decision["selected_provider"]
        if selected == fallback_name
          attempted_failures = decision.fetch("attempts", []).select do |attempt|
            attempt["decision"] == "selected" && attempt["provider"] != fallback_name && attempt["result"] != "approved"
          end.map { |attempt| attempt["provider"] }
          unresolved = eligible - attempted_failures
          errors << "#{operation['operation_id']}: fallback selected before exhausting eligible external providers #{unresolved.join(', ')}" if unresolved.any?
        elsif !eligible.include?(selected)
          errors << "#{operation['operation_id']}: final provider #{selected} violates hard constraints"
        end
        if selected && provider_states.key?(selected) && decision["simulated_result"] == "approved"
          provider_states[selected].daily_approved_amount = Money.sum(provider_states[selected].daily_approved_amount, operation["amount"])
        elsif selected && provider_states.key?(selected) && decision["simulated_result"] == "expired"
          provider_states[selected].reserve!({
            "operation_id" => operation.fetch("operation_id"),
            "amount" => operation.fetch("amount").to_f,
            "attempt" => decision.fetch("attempts", []).count { |attempt| attempt["decision"] == "selected" }
          })
        end
      end
    end

    def validate_report
      %w[period total_operations distribution skip_reasons projected_daily_utilization recommendations].each do |field|
        errors << "report missing #{field}" unless @report.key?(field)
      end
      errors << "report total_operations mismatch" unless @report["total_operations"] == @decisions.length
      errors << "report decisions_hash mismatch" unless @report.dig("audit", "decisions_hash") == Canonical.digest(@decisions)
      recomputed = @decisions.group_by { |decision| decision["selected_provider"] }
      amounts = @queue.each_with_object({}) { |op, out| out[op["operation_id"]] = Money.cents(op["amount"]) }
      provider_names = @providers_document.fetch("providers").map { |provider| provider["payment_system"] }
      provider_names.each do |name|
        row = @report.fetch("distribution", {})[name]
        unless row
          errors << "report distribution missing #{name}"
          next
        end
        errors << "report distribution mismatch for #{name}" unless row["count"] == recomputed.fetch(name, []).length
        share = recomputed.fetch(name, []).length * 100.0 / [@decisions.length, 1].max
        errors << "report share mismatch for #{name}" unless row["share_pct"] == share.round(2)
        provider = @replayed_providers.fetch(name)
        used = @report.dig("projected_daily_utilization", name, "used")
        errors << "report used amount mismatch for #{name}" unless used.is_a?(Numeric) && Money.cents(used) == Money.cents(provider.daily_approved_amount)
        reserved = @report.dig("projected_daily_utilization", name, "reserved")
        errors << "report reserved amount mismatch for #{name}" unless reserved.is_a?(Numeric) && Money.cents(reserved) == Money.cents(provider.reserved_amount)
        volume = @report.dig("volume_distribution", name, "amount")
        expected_volume = recomputed.fetch(name, []).sum { |decision| amounts.fetch(decision["operation_id"]) }
        errors << "report volume amount mismatch for #{name}" unless volume.is_a?(Numeric) && Money.cents(volume) == expected_volume
        attempts = @decisions.flat_map { |d| d["attempts"] }.select { |a| a["decision"] == "selected" && a["provider"] == name }
        %w[approved rejected expired].each do |status|
          actual = @report.dig("provider_outcomes", name, status)
          errors << "report #{status} count mismatch for #{name}" unless actual == attempts.count { |a| effective_result(a) == status }
        end
      end
      reconciliation = @report.fetch("reconciliation", {})
      errors << "report does not reconcile with ledger" unless reconciliation["ledger_matches_decisions"]
      expected_pending = @decisions.count { |decision| decision["simulated_result"] == "expired" }
      errors << "settled count does not match approved decisions" unless reconciliation["settled_count"] == @decisions.count { |d| d["simulated_result"] == "approved" }
      errors << "pending count does not match expired decisions" unless reconciliation["pending_count"].to_i == expected_pending
      errors << "reserved count does not match pending decisions" unless reconciliation["reserved_count"].to_i == expected_pending
      errors << "report pii_scan_clean=false" unless @report.dig("audit", "pii_scan_clean")
      errors << "report recommendations must be a non-empty array" unless @report["recommendations"].is_a?(Array) && @report["recommendations"].any?
    end

    def validate_event_log
      events = @report["event_log"]
      unless events.is_a?(Array)
        errors << "report event_log must be an array"
        return
      end

      previous = nil
      event_ids = []
      reservations = {}
      events.each_with_index do |event, index|
        unless event.is_a?(Hash)
          errors << "event_log[#{index}] must be an object"
          next
        end
        errors << "event_log sequence broken at #{index + 1}" unless event["sequence"] == index + 1
        errors << "event_log previous_hash broken at #{index + 1}" unless event["previous_hash"] == previous
        check = event.dup
        expected_hash = check.delete("event_hash")
        errors << "event_log hash broken at #{index + 1}" unless expected_hash && Canonical.digest(check) == expected_hash
        previous = expected_hash
        event_ids << event["event_id"]
        unless event["type"].is_a?(String) && event["payload"].is_a?(Hash)
          errors << "event_log[#{index}] needs type and payload"
          next
        end
        if event["type"] == "attempt_reserved"
          reservations[[event.dig("payload", "operation_id"), event.dig("payload", "attempt")]] = event
        end
      end
      errors << "event_log head differs from reconciliation" unless previous == @report.dig("reconciliation", "event_head")

      @report.fetch("proof_capsules", {}).each do |operation_id, proof|
        unless proof.is_a?(Hash) && proof["event_ids"].is_a?(Array) && proof["attempt_snapshots"].is_a?(Array)
          errors << "#{operation_id}: invalid proof capsule"
          next
        end
        missing = proof.fetch("event_ids", []) - event_ids
        errors << "#{operation_id}: proof references missing events #{missing.join(', ')}" if missing.any?
        proof.fetch("attempt_snapshots", []).each do |attempt|
          unless attempt.is_a?(Hash) && attempt["snapshot"].is_a?(Hash)
            errors << "#{operation_id}: invalid attempt snapshot"
            next
          end
          hash = attempt["snapshot_hash"]
          errors << "#{operation_id}: attempt snapshot hash mismatch" unless hash == Canonical.digest(attempt["snapshot"])
          reservation = reservations[[operation_id, attempt["attempt"]]]
          errors << "#{operation_id}: snapshot does not match reservation" unless reservation && reservation.dig("payload", "metadata", "state_hash_before") == hash
        end
      end
    end

    def validate_pii
      serialized = JSON.generate({ "decisions" => @decisions, "report" => @report })
      errors << "PII-like phone value found in outputs" if Redactor.phone_like?(serialized)
      raw_sensitive_values = []
      collect_sensitive_values(@queue, raw_sensitive_values)
      leaked = raw_sensitive_values.select { |value| serialized.include?(value) }
      errors << "#{leaked.length} raw sensitive queue values found in outputs" if leaked.any?
    end

    def effective_result(attempt)
      result = attempt["resolution"] || attempt["result"]
      result == "cancelled" ? "rejected" : result
    end

    def collect_sensitive_values(value, output)
      case value
      when Hash
        value.each do |key, item|
          if Redactor.sensitive?(key) && !item.is_a?(Hash) && !item.is_a?(Array)
            output << item.to_s unless item.nil? || item.to_s.empty?
          else
            collect_sensitive_values(item, output)
          end
        end
      when Array
        value.each { |item| collect_sensitive_values(item, output) }
      end
    end
  end
end
