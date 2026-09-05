# frozen_string_literal: true

module PulseProof
  class PolicyScorer
    FACTORS = %w[conversion load margin priority amount_fit turnover_min].freeze

    def initialize(providers, profile)
      @providers = providers
      @profile = profile
    end

    def penalties(provider_name, metric, amount)
      provider = @providers.fetch(provider_name)
      conversion = metric.fetch("conservative_conversion").to_f
      {
        "conversion" => conversion_penalty(conversion),
        "load" => provider.load_ratio,
        "margin" => provider.config["provider_margin_pct"].to_f / [provider.config["merchant_margin_pct"].to_f, 0.01].max,
        "priority" => provider.config["priority"].to_i / 100.0,
        "amount_fit" => amount_fit_penalty(provider_name, amount),
        "turnover_min" => turnover_min_penalty(provider)
      }.transform_values { |value| clamp(value).round(8) }
    end

    def weighted_total(penalties)
      FACTORS.inject(0.0) do |sum, factor|
        sum + penalties.fetch(factor, 0.0) * weight(factor)
      end
    end

    def sort_key(primary:, secondary:, penalties:, provider:)
      case @profile.fetch("selection_mode", "balanced_minimax")
      when "cascade"
        [penalties.fetch("priority"), primary, secondary, provider.name]
      when "conversion_first"
        [penalties.fetch("conversion"), primary, penalties.fetch("load"), provider.config["priority"].to_i, provider.name]
      when "weighted_sum"
        [primary + secondary, primary, provider.config["priority"].to_i, provider.name]
      else
        [primary, secondary, provider.config["priority"].to_i, provider.name]
      end
    end

    private

    def conversion_penalty(conversion)
      base = 1.0 - conversion
      guardrail = @profile["conversion_guardrail"].to_f
      return base unless guardrail.positive? && conversion < guardrail

      base + (guardrail - conversion) / guardrail
    end

    def amount_fit_penalty(provider_name, amount)
      preference = @profile.fetch("amount_preferences", {})[provider_name]
      return 0.0 unless preference

      minimum = preference["min"]
      maximum = preference["max"]
      value = amount.to_f
      return 0.0 if (minimum.nil? || value >= minimum.to_f) && (maximum.nil? || value <= maximum.to_f)

      boundary = minimum && value < minimum.to_f ? minimum.to_f : maximum.to_f
      (value - boundary).abs / [value.abs, boundary.abs, 1.0].max
    end

    def turnover_min_penalty(provider)
      minimum = provider.config["daily_turnover_min"]
      return 1.0 unless minimum && minimum.to_f.positive?

      remaining_ratio = [(minimum.to_f - provider.effective_daily_amount) / minimum.to_f, 0.0].max
      1.0 - [remaining_ratio, 1.0].min
    end

    def weight(name)
      @profile.fetch("weights", {}).fetch(name, 0).to_f
    end

    def clamp(value)
      [[value.to_f, 0.0].max, 1.0].min
    end
  end
end
