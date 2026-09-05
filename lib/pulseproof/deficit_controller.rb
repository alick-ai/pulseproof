# frozen_string_literal: true

module PulseProof
  class DeficitController
    attr_reader :providers, :profile, :count_debt, :volume_debt, :processed_count, :processed_amount

    def initialize(provider_states, profile)
      @providers = provider_states
      @profile = profile
      external = provider_states.values.reject { |provider| fallback?(provider) }
      @count_targets = normalized_targets(external, :target_count_pct)
      @volume_targets = configured_volume_targets(external)
      @count_debt = provider_states.keys.each_with_object({}) { |name, out| out[name] = 0.0 }
      @volume_debt = provider_states.keys.each_with_object({}) { |name, out| out[name] = 0.0 }
      @raw_count_debt = @count_debt.dup
      @raw_volume_debt = @volume_debt.dup
      @unavailable_streak = provider_states.keys.each_with_object({}) { |name, out| out[name] = 0 }
      @recovering = provider_states.keys.each_with_object({}) { |name, out| out[name] = false }
      @processed_count = 0
      @processed_amount = 0.0
      @policy_scorer = PolicyScorer.new(provider_states, profile)
    end

    def accrue!(amount)
      external = providers.values.reject { |provider| fallback?(provider) }
      @count_targets = normalized_targets(external, :target_count_pct)
      @volume_targets = configured_volume_targets(external)
      @processed_count += 1
      @last_amount = amount.to_f
      @processed_amount = Money.sum(@processed_amount, amount)
      @last_count_base = @count_debt.dup
      @last_volume_base = @volume_debt.dup
      @count_targets.each { |name, target| @raw_count_debt[name] += target }
      @volume_targets.each { |name, target| @raw_volume_debt[name] += target * amount.to_f }
      @count_targets.each { |name, target| @count_debt[name] = clamp(@count_debt[name] + target, count_bound) }
      @volume_targets.each { |name, target| @volume_debt[name] = clamp(@volume_debt[name] + target * amount.to_f, volume_bound_amount) }
      snapshot
    end

    def mark_eligibility!(rule_results)
      eligible = rule_results.select(&:eligible).map(&:provider)
      # Reallocate only this operation's controllable entitlement. Raw business
      # debt remains separate, so infeasibility is neither hidden nor allowed
      # to dominate the ranking of providers which can actually accept it.
      if profile.fetch("redistribute_unavailable", false)
        count = normalized_target_hash(@count_targets.select { |name, _| eligible.include?(name) })
        volume = normalized_target_hash(@volume_targets.select { |name, _| eligible.include?(name) })
        @count_targets.each_key do |name|
          @count_debt[name] = clamp(@last_count_base.fetch(name) + count.fetch(name, 0), count_bound)
        end
        @volume_targets.each_key do |name|
          @volume_debt[name] = clamp(@last_volume_base.fetch(name) + volume.fetch(name, 0) * @last_amount, volume_bound_amount)
        end
      end
      rule_results.each do |result|
        name = result.provider
        next if fallback?(providers.fetch(name))
        if result.eligible
          @recovering[name] ||= @unavailable_streak[name].positive?
          @unavailable_streak[name] = 0
        else
          @unavailable_streak[name] += 1
          @recovering[name] = false
          @count_debt[name] = clamp(@count_debt[name], count_bound)
        end
      end
    end

    def analyze(provider_name, eligible_names, metric)
      projected_count = count_debt.dup
      eligible_names.each { |name| projected_count[name] = effective_count_debt(name, eligible_names) }
      projected_volume = volume_debt.dup
      effective = effective_count_debt(provider_name, eligible_names)
      projected_count[provider_name] = effective - 1.0
      projected_volume[provider_name] -= current_amount if @volume_targets.key?(provider_name)

      count_regret = max_abs(projected_count, eligible_names & @count_targets.keys) / count_bound
      volume_regret = if @volume_targets.empty?
                        0.0
                      else
                        max_abs(projected_volume, eligible_names & @volume_targets.keys) / volume_bound_amount
                      end
      provider = providers.fetch(provider_name)
      penalties = @policy_scorer.penalties(provider_name, metric, current_amount)
      primary = [count_regret * weight("count"), volume_regret * weight("volume")].max
      secondary = @policy_scorer.weighted_total(penalties)

      {
        "provider" => provider_name,
        "primary_regret" => primary.round(8),
        "secondary_penalty" => secondary.round(8),
        "count_regret" => count_regret.round(8),
        "volume_regret" => volume_regret.round(8),
        "count_debt_before" => count_debt[provider_name].round(8),
        "effective_count_debt" => effective.round(8),
        "conversion_penalty" => penalties.fetch("conversion"),
        "load_penalty" => penalties.fetch("load"),
        "margin_penalty" => penalties.fetch("margin"),
        "priority_penalty" => penalties.fetch("priority"),
        "amount_fit_penalty" => penalties.fetch("amount_fit"),
        "turnover_min_penalty" => penalties.fetch("turnover_min"),
        "recovering" => @recovering[provider_name],
        "sort_key" => @policy_scorer.sort_key(primary: primary, secondary: secondary, penalties: penalties, provider: provider)
      }
    end

    def rank(eligible_names, metrics, amount)
      @current_amount = amount.to_f
      eligible_names.map { |name| analyze(name, eligible_names, metrics.fetch(name)) }
                    .sort_by { |analysis| analysis.fetch("sort_key") }
    ensure
      @current_amount = nil
    end

    def provisional_credit!(provider_name, amount)
      @raw_count_debt[provider_name] -= 1.0
      @raw_volume_debt[provider_name] -= amount.to_f unless @volume_targets.empty?
      @count_debt[provider_name] = clamp(@count_debt.fetch(provider_name) - 1.0, count_bound)
      if @volume_targets.key?(provider_name)
        @volume_debt[provider_name] = clamp(@volume_debt.fetch(provider_name) - amount.to_f, volume_bound_amount)
      end
      settle_recovery(provider_name)
      snapshot
    end

    def reverse_credit!(provider_name, amount)
      @raw_count_debt[provider_name] += 1.0
      @raw_volume_debt[provider_name] += amount.to_f unless @volume_targets.empty?
      @count_debt[provider_name] = clamp(@count_debt.fetch(provider_name) + 1.0, count_bound)
      if @volume_targets.key?(provider_name)
        @volume_debt[provider_name] = clamp(@volume_debt.fetch(provider_name) + amount.to_f, volume_bound_amount)
      end
      snapshot
    end

    def snapshot
      {
        "processed_count" => processed_count,
        "processed_amount" => processed_amount.round(2),
        "count_targets" => round_hash(@count_targets),
        "volume_targets" => round_hash(@volume_targets),
        "count_debt" => round_hash(count_debt),
        "volume_debt" => round_hash(volume_debt),
        "raw_count_debt" => round_hash(@raw_count_debt),
        "raw_volume_debt" => round_hash(@raw_volume_debt),
        "unavailable_streak" => @unavailable_streak.dup,
        "recovering" => @recovering.dup
      }
    end

    private

    def current_amount
      @current_amount || 0.0
    end

    def normalized_targets(items, method_name)
      sum = items.inject(0.0) { |total, provider| total + provider.public_send(method_name).to_f }
      return {} if sum.zero?
      items.each_with_object({}) { |provider, out| out[provider.name] = provider.public_send(method_name).to_f / sum }
    end

    def configured_volume_targets(external)
      configured = profile["volume_targets"]
      if configured
        values = external.each_with_object({}) { |provider, out| out[provider.name] = configured.fetch(provider.name, 0).to_f }
        return normalized_target_hash(values)
      end

      volume_values = external.select { |provider| !provider.target_volume_pct.nil? }
      normalized_targets(volume_values, :target_volume_pct)
    end

    def normalized_target_hash(values)
      sum = values.values.inject(0.0, :+)
      return {} if sum.zero?
      values.each_with_object({}) { |(name, value), out| out[name] = value / sum }
    end

    def fallback?(provider)
      provider.name == profile.fetch("fallback_provider", "spacepayments")
    end

    def weight(name)
      profile.fetch("weights", {}).fetch(name, 0).to_f
    end

    def count_bound
      [profile.fetch("traffic_debt_bound", 4).to_f, 1.0].max
    end

    def volume_bound_amount
      average = processed_count.zero? ? 1.0 : processed_amount / processed_count
      [profile.fetch("volume_debt_bound", 4).to_f * [average, 1.0].max, 1.0].max
    end

    def effective_count_debt(provider_name, eligible_names)
      raw = count_debt.fetch(provider_name)
      return raw unless @recovering[provider_name]
      others = eligible_names.reject { |name| name == provider_name }.map { |name| count_debt.fetch(name) }
      ceiling = (others.max || raw) + profile.fetch("recovery_rate", 0.75).to_f
      [raw, ceiling].min
    end

    def settle_recovery(provider_name)
      return unless @recovering[provider_name]
      others = count_debt.reject { |name, _| name == provider_name }.values
      @recovering[provider_name] = false if count_debt[provider_name] <= (others.max || count_debt[provider_name])
    end

    def max_abs(hash, keys)
      keys.map { |name| hash.fetch(name).abs }.max || 0.0
    end

    def clamp(value, bound)
      [[value, -bound].max, bound].min
    end

    def round_hash(hash)
      hash.each_with_object({}) { |(name, value), out| out[name] = value.round(8) }
    end
  end
end
