# frozen_string_literal: true

module PulseProof
  # Checks a current candidate against historical demand shapes. A probe is
  # NOT a predicted future payment: it asks whether this shape still has any
  # external route after reserving the current payment. No queue lookahead.
  class CapacityGuard
    attr_reader :config

    def initialize(history:, config:, fallback_provider:, as_of: nil)
      @config = config
      @fallback = fallback_provider
      @cutoff = as_of && Time.iso8601(as_of)
      @gate = HardGate.new(fallback_provider: @fallback)
      @samples = history.map { |row| sample(row) }.compact
      @samples.sort_by! { |row| row.fetch(:available_at) }
    end

    def model_at(at)
      cutoff = @cutoff ? [at, @cutoff].min : at
      rows = @samples.select { |row| row.fetch(:available_at) <= cutoff }.last(config.fetch("max_samples", 1000))
      groups = rows.group_by { |row| [row[:bank], row[:card_brand], row[:amount_cents]] }
      cohorts = groups.map do |(bank, card, cents), values|
        { "bank" => bank, "card_brand" => card, "amount" => Money.rubles(cents), "frequency" => values.length }
      end.sort_by { |row| [row["bank"], row["card_brand"].to_s, row["amount"]] }
      { "source" => "past request shapes only; not a forecast or future queue", "as_of" => cutoff.iso8601,
        "sample_size" => rows.length, "cohorts" => cohorts }
    end

    def rank(ranking, providers:, metrics:, operation:)
      at = Time.iso8601(operation.fetch("created_at"))
      model = model_at(at)
      return ranking if model["sample_size"] < config.fetch("min_samples", 20)

      # All hypothetical mutations are isolated from the real provider ledger.
      current = Marshal.load(Marshal.dump(providers))
      exclusive = Hash.new { |h, k| h[k] = [] }
      model.fetch("cohorts").each do |cohort|
        probe = cohort.merge("created_at" => at.iso8601)
        names = current.values.reject { |p| p.name == @fallback }.select { |p| @gate.evaluate(probe, p, at: at).eligible }.map(&:name)
        exclusive[names.first] << cohort if names.length == 1
      end

      baseline = ranking.first
      baseline_conversion = metrics.fetch(baseline.fetch("provider")).fetch("conservative_conversion")
      analyses = ranking.each_with_index.map do |row, index|
        name = row.fetch("provider")
        after = Marshal.load(Marshal.dump(current.fetch(name)))
        after.reserve!({ "operation_id" => operation.fetch("operation_id"), "amount" => operation.fetch("amount") })
        after.record_request!(at)
        lost = exclusive[name].map do |cohort|
          evaluation = @gate.evaluate(cohort.merge("created_at" => at.iso8601), after, at: at)
          next if evaluation.eligible
          cohort.merge("lost_because" => evaluation.reason, "constraint_details" => evaluation.details)
        end.compact
        protected_count = lost.sum { |cohort| cohort.fetch("frequency") }
        allowed = row.fetch("primary_regret") <= baseline.fetch("primary_regret") + config.fetch("max_primary_regret_delta", 0.25) + 1e-8 &&
          metrics.fetch(name).fetch("conservative_conversion") >= baseline_conversion - config.fetch("max_conversion_drop", 0.02) - 1e-8
        row.merge("capacity_guard" => {
          "baseline_provider" => baseline.fetch("provider"), "sample_size" => model["sample_size"],
          "lost_historical_support_count" => protected_count,
          "lost_historical_support_fraction" => protected_count.to_f / model["sample_size"],
          "lost_cohorts" => lost, "within_policy_budget" => allowed,
          "baseline_rank" => index, "scope" => "individual historical shapes after current reservation; not forecast losses"
        })
      end
      chosen = analyses.select { |row| row["capacity_guard"]["within_policy_budget"] }.min_by do |row|
        [row["capacity_guard"]["lost_historical_support_count"], row["capacity_guard"]["baseline_rank"]]
      end
      override = chosen.fetch("provider") != baseline.fetch("provider")
      chosen["capacity_guard"]["overrode_baseline"] = override
      [chosen] + analyses.reject { |row| row.equal?(chosen) }
    end

    private

    def sample(row)
      amount = Float(row.fetch("amount"))
      return nil unless amount.finite? && amount.positive? && !row["bank"].to_s.empty?
      available_at = Time.iso8601(row.fetch("created_at")) + [Float(row.fetch("latency_sec", 0)), 0].max
      { bank: row["bank"], card_brand: row["card_brand"].to_s.empty? ? nil : row["card_brand"],
        amount_cents: Money.cents(amount), available_at: available_at }
    rescue KeyError, ArgumentError, TypeError
      nil
    end
  end
end
