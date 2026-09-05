# frozen_string_literal: true

module PulseProof
  class MetricTrustGate
    attr_reader :rows, :providers, :prior_strength

    def initialize(history_rows, provider_states, prior_strength: 12, as_of: nil)
      @as_of = as_of && Time.iso8601(as_of)
      @excluded_rows = history_rows.reject { |row| available?(row) }
      @rows = history_rows.select { |row| available?(row) }
      @providers = provider_states
      @prior_strength = prior_strength.to_f
      @metrics = build_metrics
    end

    def fetch(provider_name)
      @metrics.fetch(provider_name) do
        provider = providers.fetch(provider_name)
        empty_metric(provider)
      end
    end

    def all
      providers.keys.each_with_object({}) { |name, out| out[name] = fetch(name) }
    end

    private

    def build_metrics
      grouped = rows.group_by { |row| row["payment_system"] }
      providers.each_with_object({}) do |(name, provider), out|
        sample = grouped.fetch(name, [])
        approved = sample.count { |row| row["status"] == "approved" }
        rejected = sample.count { |row| row["status"] == "rejected" }
        expired = sample.count { |row| row["status"] == "expired" }
        snapshot_rate = provider.config["conversion_24h"].to_f
        observed_rate = sample.empty? ? nil : approved.to_f / sample.length
        calibration = sample.select { |row| policy_compatible?(row, provider.config) }
        calibration_approved = calibration.count { |row| row["status"] == "approved" }
        denominator = calibration.length + prior_strength
        blended = denominator.zero? ? snapshot_rate : (calibration_approved + prior_strength * snapshot_rate) / denominator
        compatible = calibration.length
        latencies = sample.map { |row| row["latency_sec"].to_f }.sort
        out[name] = {
          "sample_size" => sample.length,
          "approved" => approved,
          "rejected" => rejected,
          "expired" => expired,
          "observed_conversion" => observed_rate && observed_rate.round(6),
          "snapshot_conversion" => snapshot_rate.round(6),
          "conservative_conversion" => blended.round(6),
          "estimator" => "compatible-history posterior mean with snapshot prior; not a confidence bound",
          "calibration_sample_size" => calibration.length,
          "calibration_approved" => calibration_approved,
          "excluded_unavailable_rows" => @excluded_rows.count { |row| row["payment_system"] == name },
          "as_of" => @as_of && @as_of.iso8601,
          "policy_compatible_rows" => compatible,
          "policy_mismatch_rows" => sample.length - compatible,
          "average_latency_sec" => average(latencies).round(2),
          "p95_latency_sec" => percentile(latencies, 0.95).round(2),
          "trust" => trust_label(sample.length, compatible)
        }
      end
    end

    def empty_metric(provider)
      snapshot = provider.config["conversion_24h"].to_f
      {
        "sample_size" => 0,
        "approved" => 0,
        "rejected" => 0,
        "expired" => 0,
        "observed_conversion" => nil,
        "snapshot_conversion" => snapshot.round(6),
        "conservative_conversion" => snapshot.round(6),
        "policy_compatible_rows" => 0,
        "policy_mismatch_rows" => 0,
        "average_latency_sec" => provider.config["avg_latency_sec"].to_f.round(2),
        "p95_latency_sec" => provider.config["avg_latency_sec"].to_f.round(2),
        "trust" => "snapshot_only"
      }
    end

    def policy_compatible?(row, config)
      amount = row["amount"].to_f
      bank = row["bank"]
      return false if config["limit_amount_min"] && amount < config["limit_amount_min"].to_f
      return false if config["limit_amount_max"] && amount > config["limit_amount_max"].to_f
      cards = config["card_brands"] || []
      return false if !cards.empty? && !cards.include?(row["card_brand"])
      banks = config["banks"] || []
      return true if banks.empty?
      config["exclude_banks"] ? !banks.include?(bank) : banks.include?(bank)
    end

    def available?(row)
      return false unless %w[approved rejected expired].include?(row["status"])
      return true unless @as_of
      # An outcome is not observable at request creation: exclude results which
      # would only finish after the routing snapshot.
      Time.iso8601(row.fetch("created_at")) + row.fetch("latency_sec", 0).to_f <= @as_of
    rescue KeyError, ArgumentError, TypeError
      false
    end

    def trust_label(sample_size, compatible)
      return "snapshot_only" if sample_size.zero?
      return "low" if sample_size < 20 || compatible.to_f / sample_size < 0.7
      sample_size < 50 ? "medium" : "high"
    end

    def average(values)
      return 0.0 if values.empty?
      values.inject(0.0, :+) / values.length
    end

    def percentile(values, percentile)
      return 0.0 if values.empty?
      values[[(values.length * percentile).ceil - 1, 0].max]
    end
  end
end
