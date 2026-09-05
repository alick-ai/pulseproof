# frozen_string_literal: true

require "time"

module PulseProof
  RuleResult = Struct.new(:provider, :eligible, :reason, :details, :facts, keyword_init: true) do
    def to_h
      {
        "provider" => provider,
        "eligible" => eligible,
        "reason" => reason,
        "details" => details,
        "facts" => facts
      }
    end
  end

  class HardGate
    def initialize(fallback_provider: "spacepayments")
      @fallback_provider = fallback_provider
    end

    def evaluate(operation, provider, at: nil, fallback: false)
      at ||= Time.parse(operation.fetch("created_at"))
      config = provider.config
      amount = operation.fetch("amount").to_f
      bank = operation.fetch("bank")
      facts = base_facts(operation, provider, at)

      return failed(provider, "provider_inactive", "status=#{config['status']}", facts) unless config["status"] == "active"
      if provider.name == @fallback_provider && !fallback
        return failed(provider, "fallback_only", "self-provider is excluded while an external candidate exists", facts)
      end
      if !fallback && provider.target_count_pct.zero?
        return failed(provider, "traffic_disabled", "traffic_percentage=0", facts)
      end
      if config["limit_amount_min"] && amount < config["limit_amount_min"].to_f
        return failed(provider, "amount_below_minimum", "#{format_number(amount)} < #{format_number(config['limit_amount_min'])}", facts)
      end
      if config["limit_amount_max"] && amount > config["limit_amount_max"].to_f
        return failed(provider, "amount_exceeds_limit", "#{format_number(amount)} > #{format_number(config['limit_amount_max'])}", facts)
      end
      if config["daily_amount_limit"] && Money.cents(provider.effective_daily_amount) + Money.cents(amount) > Money.cents(config["daily_amount_limit"])
        return failed(provider, "daily_amount_limit_exceeded", "#{format_number(provider.effective_daily_amount + amount)} > #{format_number(config['daily_amount_limit'])}", facts)
      end
      if config["in_progress_count_limit"] && provider.effective_in_progress_count + 1 > config["in_progress_count_limit"].to_i
        return failed(provider, "in_progress_count_limit_exceeded", "#{provider.effective_in_progress_count + 1} > #{config['in_progress_count_limit']}", facts)
      end
      if config["in_progress_amount_limit"] && Money.cents(provider.effective_in_progress_amount) + Money.cents(amount) > Money.cents(config["in_progress_amount_limit"])
        return failed(provider, "in_progress_amount_limit_exceeded", "#{format_number(provider.effective_in_progress_amount + amount)} > #{format_number(config['in_progress_amount_limit'])}", facts)
      end
      return failed(provider, "no_available_requisites", "available_requisites=0", facts) if provider.available_requisites.zero?
      if config["requests_per_minute_limit"] && provider.rpm_count(at) + 1 > config["requests_per_minute_limit"].to_i
        return failed(provider, "rpm_limit_exceeded", "#{provider.rpm_count(at) + 1} > #{config['requests_per_minute_limit']}", facts)
      end
      if config["provider_margin_pct"].to_f > config["merchant_margin_pct"].to_f && !config["allow_negative_agreement"]
        return failed(provider, "negative_margin", "provider_margin=#{config['provider_margin_pct']} > merchant_margin=#{config['merchant_margin_pct']}", facts)
      end

      banks = config["banks"] || []
      if banks.any?
        if config["exclude_banks"] && banks.include?(bank)
          return failed(provider, "bank_excluded", "#{bank} is denied", facts)
        elsif !config["exclude_banks"] && !banks.include?(bank)
          return failed(provider, "bank_not_in_list", "#{bank} is not allowed", facts)
        end
      end

      card_brands = config["card_brands"] || []
      card_brand = operation["card_brand"]
      if card_brands.any? && card_brand && !card_brands.include?(card_brand)
        return failed(provider, "card_brand_not_allowed", "#{card_brand} is not allowed", facts)
      end

      RuleResult.new(provider: provider.name, eligible: true, reason: "eligible", details: "all hard constraints passed", facts: facts)
    end

    private

    def base_facts(operation, provider, at)
      {
        "amount" => operation["amount"],
        "bank" => operation["bank"],
        "effective_daily_amount" => provider.effective_daily_amount.round(2),
        "effective_in_progress_count" => provider.effective_in_progress_count,
        "effective_in_progress_amount" => provider.effective_in_progress_amount.round(2),
        "available_requisites" => provider.available_requisites,
        "rpm_count" => provider.rpm_count(at)
      }
    end

    def failed(provider, reason, details, facts)
      RuleResult.new(provider: provider.name, eligible: false, reason: reason, details: details, facts: facts)
    end

    def format_number(value)
      value.to_f % 1 == 0 ? value.to_i : value.to_f.round(2)
    end
  end
end
