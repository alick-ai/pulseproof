# frozen_string_literal: true

module PulseProof
  # Bounded capacity stress, NOT a forecast of the real queue or an exact flow
  # optimum. Shared resources are consumed jointly by a historical-shape tape.
  class OpportunityModel
    def initialize(history:, config:, fallback:, as_of: nil)
      @config, @fallback = config, fallback
      @cutoff = as_of && Time.iso8601(as_of)
      @gate = HardGate.new(fallback_provider: fallback)
      @seen = {}
      @rows = history.map do |row|
        begin
          amount = Float(row.fetch("amount"))
          next unless amount.finite? && amount > 0 && !row["bank"].to_s.empty?
          # Request shape, not response label: known at request arrival.
          { "amount" => amount, "bank" => row["bank"], "card_brand" => row["card_brand"],
            "created_at" => Time.iso8601(row.fetch("created_at")).iso8601 }
        rescue ArgumentError, TypeError, KeyError
          nil
        end
      end.compact.sort_by { |row| Time.iso8601(row["created_at"]) }.last(500)
    end

    def observe(operation)
      return if @seen[operation.fetch("operation_id")]
      @seen[operation.fetch("operation_id")] = true
      @rows << operation.select { |k, _| %w[amount bank card_brand created_at].include?(k) }.merge("online" => true)
      @rows.shift while @rows.length > 500
    end

    def tape(at)
      rows = @rows.select do |row|
        limit = row["online"] || !@cutoff ? at : [at, @cutoff].min
        Time.iso8601(row.fetch("created_at")) <= limit
      end
      return [] if rows.length < @config.fetch("minimum_samples", 10)
      horizon = @config.fetch("horizon_operations", 12)
      # Deterministic stratified sample; real future operations are never read.
      Array.new(horizon) { |i| rows[((i + 0.5) * rows.length / horizon).floor] }
    end

    def assess(providers, operation, names)
      at = Time.iso8601(operation.fetch("created_at"))
      demand = tape(at)
      before = simulate(providers, demand, at)
      names.each_with_object({}) do |name, out|
        hypothetical = Marshal.load(Marshal.dump(providers))
        key = "__opportunity_current"
        key += "_" while hypothetical.fetch(name).reservations.key?(key)
        hypothetical.fetch(name).reserve!({ "operation_id" => key, "amount" => operation.fetch("amount") })
        hypothetical.fetch(name).record_request!(at)
        after = simulate(hypothetical, demand, at)
        out[name] = { "historical_tape_size" => demand.length,
          "historical_tape" => demand,
          "served_before" => before, "served_after_reservation" => after,
          "lost_service_slots" => [before - after, 0].max,
          "scope" => "shared-capacity historical stress, current reserve held throughout; not predicted lost payouts" }
      end
    end

    def repairs(providers, at)
      demand = tape(at)
      return [] if demand.empty?
      before = simulate(providers, demand, at)
      providers.values.reject { |p| p.name == @fallback || !p.config["daily_amount_limit"] }.map do |provider|
        @config.fetch("repair_steps_rub", [1000, 10000, 50000, 100000]).sort.each do |delta|
          trial = Marshal.load(Marshal.dump(providers))
          trial[provider.name].config["daily_amount_limit"] += delta
          after = simulate(trial, demand, at)
          next unless after > before
          break({ "provider" => provider.name, "parameter" => "daily_amount_limit", "increase_rub" => delta,
            "current_value" => provider.config["daily_amount_limit"], "proposed_value" => provider.config["daily_amount_limit"] + delta,
            "served_before" => before, "served_after" => after, "tested_tape_size" => demand.length,
            "scope" => "smallest improving tested increment, not global minimum or forecast; operator approval required" })
        end
      end.select { |row| row.is_a?(Hash) }
    end

    private

    def simulate(providers, demand, at)
      return 0 if demand.empty?
      # Two packing orders, best feasible served count. Shared daily capacity,
      # RPM and existing reservations remain active. Synthetic sends approve.
      [demand, demand.reverse].map do |ordered|
        states = Marshal.load(Marshal.dump(providers))
        ordered.each_with_index.count do |shape, index|
          time = at + (index + 1) * @config.fetch("arrival_interval_sec", 10)
          key = "__stress_#{index}"
          key += "_" while states.values.any? { |p| p.reservations.key?(key) }
          op = shape.merge("operation_id" => key, "created_at" => time.iso8601)
          eligible = states.values.select { |p| @gate.evaluate(op, p, at: time).eligible }
          chosen = eligible.min_by do |p|
            limit = p.config["daily_amount_limit"]
            [limit ? limit - p.effective_daily_amount : Float::INFINITY, p.name]
          end
          next false unless chosen
          chosen.reserve!(op)
          chosen.record_request!(time)
          chosen.commit!(op["operation_id"])
          true
        end
      end.max
    end
  end
end
