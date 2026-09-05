# frozen_string_literal: true

module PulseProof
  # Contextual, recency-weighted Beta estimate. Fractional decayed counts are
  # a heuristic under nonstationarity, not a calibrated confidence guarantee.
  # Only selected attempts with a confirmed terminal outcome are observations.
  class AdaptiveLearning
    attr_reader :config, :observed_count, :probe_count

    def initialize(providers:, history:, config:, as_of: nil)
      @providers, @config = providers, config
      @series = Hash.new { |h, k| h[k] = [] }
      @slow_history = []
      @seen = {}
      @context_requests = Hash.new(0)
      @observed_count = 0
      @probe_count = 0
      @history_count = 0
      @history = history
      @history_cutoff = as_of && Time.iso8601(as_of)
      @seeded = false
    end

    def context(operation)
      bounds = config.fetch("amount_bands", [1000, 5000, 10000, 50000, 100000])
      band = bounds.index { |upper| operation.fetch("amount").to_f <= upper } || bounds.length
      [operation.fetch("bank"), operation["card_brand"].to_s, band]
    end

    def estimate(provider_name, operation, at:)
      seed_history!(at) unless @seeded
      records = @series.fetch([provider_name, *context(operation)], []).select { |row| row[:at] <= at }
      effective_n = 0.0
      effective_success = 0.0
      half_life = config.fetch("half_life_sec", 300).to_f
      records.each do |row|
        weight = 2.0**(-[at - row[:at], 0].max / half_life)
        effective_n += weight
        effective_success += weight * row[:reward]
      end
      snapshot = @providers.fetch(provider_name).config.fetch("conversion_24h", 0.5).to_f
      slow = slow_prior(provider_name, operation, at, snapshot)
      reference = slow.fetch("mean")
      prior = config.fetch("prior_strength", 8).to_f
      alpha = 0.5 + prior * reference + effective_success
      beta = 0.5 + prior * (1 - reference) + effective_n - effective_success
      total = alpha + beta
      mean = alpha / total
      uncertainty = Math.sqrt(alpha * beta / (total * total * (total + 1)))
      signal = effective_n >= config.fetch("minimum_evidence", 6) &&
        mean + config.fetch("uncertainty_multiplier", 1.5) * uncertainty < reference - config.fetch("minimum_drop", 0.10)
      {
        "context" => context(operation), "mean" => mean.round(8),
        "uncertainty_sd" => uncertainty.round(8), "degradation_signal" => signal,
        "effective_samples" => effective_n.round(6), "observations_in_window" => records.length,
        "last_confirmed_at" => records.last && records.last[:at].iso8601,
        "slow_prior" => slow,
        "backing" => records.empty? ? (slow["effective_samples"] > 0 ? "pooled_history_prior" : "snapshot_prior_only") : "contextual_confirmed_outcomes",
        "method" => "recency-weighted Beta mean; uncertainty is model-based, not a calibrated guarantee"
      }
    end

    def metrics_for(operation, base_metrics)
      at = Time.iso8601(operation.fetch("created_at"))
      base_metrics.each_with_object({}) do |(name, metric), output|
        prediction = estimate(name, operation, at: at)
        output[name] = metric.merge("conservative_conversion" => prediction["mean"], "adaptive_prediction" => prediction)
      end
    end

    def observe(operation:, provider_name:, attempt:, status:, at:, source: "adapter_response")
      return nil unless config.fetch("learn_from_outcomes", true)
      return nil unless %w[approved rejected cancelled].include?(status)
      seed_history!(Time.iso8601(operation.fetch("created_at"))) unless @seeded
      key = [operation.fetch("operation_id"), provider_name, attempt]
      reward = status == "approved" ? 1 : 0
      if @seen.key?(key)
        raise InvariantError, "conflicting learning outcome for #{key}" unless @seen[key] == reward
        return nil
      end
      @seen[key] = reward
      add_record(provider_name, operation, reward, Time.iso8601(at))
      @observed_count += 1
      { "operation_id" => operation.fetch("operation_id"), "provider" => provider_name, "attempt" => attempt,
        "status" => status, "reward" => reward, "context" => context(operation), "at" => at, "source" => source }
    end

    # A bounded recovery probe on every K-th first attempt in this context.
    # Deterministic scheduling is reproducible, NOT unbiased random exploration.
    def probe(ranking, operation:, attempt:, providers:)
      return ranking unless attempt == 1
      key = context(operation)
      @context_requests[key] += 1
      interval = config.fetch("probe_every", 20)
      return ranking if interval.zero? || @context_requests[key] % interval != 0
      return ranking if operation.fetch("amount").to_f > config.fetch("probe_max_amount", 5000)
      at = Time.iso8601(operation.fetch("created_at"))
      baseline = ranking.first
      candidates = ranking.drop(1).select do |row|
        prediction = row.fetch("adaptive_prediction")
        last = prediction["last_confirmed_at"]
        stale = !last || at - Time.iso8601(last) >= config.fetch("probe_after_sec", 60)
        primary_ok = row["primary_regret"] <= baseline["primary_regret"] + config.fetch("max_probe_regret_delta", 0.25)
        capacity_ok = !row["capacity_guard"] || row.dig("capacity_guard", "lost_historical_support_count") <= baseline.dig("capacity_guard", "lost_historical_support_count")
        prediction["degradation_signal"] && stale && primary_ok && capacity_ok && providers.fetch(row["provider"]).reserved_count.zero?
      end
      chosen = candidates.min_by do |row|
        last = row.dig("adaptive_prediction", "last_confirmed_at")
        [last ? Time.iso8601(last).to_f : -Float::INFINITY, row["provider"]]
      end
      return ranking unless chosen
      @probe_count += 1
      chosen["adaptive_probe"] = { "reason" => "bounded_stale_context_recheck", "replaced_provider" => baseline["provider"],
        "context_request" => @context_requests[key], "schedule" => "one opportunity per #{interval} first attempts" }
      [chosen] + ranking.reject { |row| row.equal?(chosen) }
    end

    def summary
      { "enabled" => true, "learn_from_outcomes" => config.fetch("learn_from_outcomes", true),
        "observed_terminal_attempts" => observed_count, "history_terminal_attempts" => @history_count,
        "context_buckets" => @series.length, "recovery_probes" => probe_count,
        "two_speed" => config.fetch("two_speed", false), "slow_history_rows" => @slow_history.length,
        "unresolved_timeouts_used_as_failures" => false, "unselected_provider_outcomes_observed" => false,
        "scope" => "in-memory contextual adaptation; no causal uplift estimate from biased history" }
    end

    private

    # Disjoint pooling: each historical row contributes once, at its nearest
    # context level. Old history supplies a slow prior, never fast observations.
    def slow_prior(name, operation, at, snapshot)
      return { "mean" => snapshot, "effective_samples" => 0.0, "source" => "snapshot" } unless config["two_speed"]
      levels = { "exact" => 0.0, "bank" => 0.0, "provider" => 0.0 }
      successes = 0.0
      key = context(operation)
      @slow_history.each do |row|
        next unless row[:provider] == name && row[:at] <= at
        level = row[:context] == key ? "exact" : (row[:context][0] == key[0] ? "bank" : "provider")
        pooling = { "exact" => 1.0, "bank" => 0.35, "provider" => 0.1 }.fetch(level)
        weight = pooling * 2.0**(-(at - row[:at]) / config.fetch("history_half_life_sec", 604800).to_f)
        levels[level] += weight
        successes += weight * row[:reward]
      end
      count = levels.values.sum
      strength = config.fetch("history_snapshot_strength", 8).to_f
      { "mean" => (strength * snapshot + successes) / (strength + count),
        "effective_samples" => count.round(6), "pooling_weights" => levels.transform_values { |v| v.round(6) },
        "source" => "disjoint pooled historical outcomes plus current snapshot; model-based prior" }
    end

    def add_record(provider, operation, reward, at)
      bucket = @series[[provider, *context(operation)]]
      bucket << { at: at, reward: reward }
      bucket.sort_by! { |row| row[:at] }
      bucket.shift while bucket.length > config.fetch("window_size", 40)
    end

    def seed_history!(at)
      cutoff = @history_cutoff ? [at, @history_cutoff].min : at
      @history.each do |row|
        next unless %w[approved rejected].include?(row["status"])
        provider = @providers[row["payment_system"]]
        next unless provider
        begin
          latency = Float(row.fetch("latency_sec", 0))
          next unless latency.finite? && latency >= 0
          available = Time.iso8601(row.fetch("created_at")) + latency
          next if available > cutoff
          operation = row.merge("amount" => Float(row.fetch("amount")))
          next unless compatible?(operation, provider.config)
          if config["two_speed"]
            @slow_history << { provider: provider.name, context: context(operation),
              reward: row["status"] == "approved" ? 1 : 0, at: available }
          else
            add_record(provider.name, operation, row["status"] == "approved" ? 1 : 0, available)
          end
          @history_count += 1
        rescue KeyError, ArgumentError, TypeError
          next
        end
      end
      @history = nil
      @seeded = true
    end

    def compatible?(row, config)
      amount = row["amount"]
      return false unless amount.finite? && amount.positive? && !row["bank"].to_s.empty?
      return false if config["limit_amount_min"] && amount < config["limit_amount_min"]
      return false if config["limit_amount_max"] && amount > config["limit_amount_max"]
      banks = config.fetch("banks", [])
      return false if !banks.empty? && (config["exclude_banks"] ? banks.include?(row["bank"]) : !banks.include?(row["bank"]))
      cards = config.fetch("card_brands", [])
      cards.empty? || row["card_brand"].to_s.empty? || cards.include?(row["card_brand"])
    end
  end
end
