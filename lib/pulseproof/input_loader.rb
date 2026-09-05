# frozen_string_literal: true

require "csv"
require "json"
require "time"

module PulseProof
  class InputLoader
    def self.json(path)
      JSON.parse(File.read(path))
    rescue Errno::ENOENT
      raise InputError, "input file not found: #{path}"
    rescue JSON::ParserError => e
      raise InputError, "invalid JSON in #{path}: #{e.message}"
    end

    def self.history(path)
      CSV.read(path, headers: true).map(&:to_h).sort_by do |row|
        Time.parse(row.fetch("created_at"))
      rescue ArgumentError
        Time.at(0)
      end
    rescue Errno::ENOENT
      raise InputError, "history file not found: #{path}"
    rescue CSV::MalformedCSVError => e
      raise InputError, "invalid CSV in #{path}: #{e.message}"
    end

    def self.validate_provider_document!(document)
      raise InputError, "providers.json must be an object" unless document.is_a?(Hash)
      providers = document["providers"]
      raise InputError, "providers.json must contain providers[]" unless providers.is_a?(Array) && !providers.empty?

      raise InputError, "every provider must be an object" unless providers.all? { |provider| provider.is_a?(Hash) }
      names = providers.map { |provider| provider["payment_system"] }
      raise InputError, "provider names must be unique and non-empty" if names.any? { |name| name.to_s.empty? } || names.uniq.length != names.length
      providers.each do |provider|
        name = provider.fetch("payment_system")
        raise InputError, "#{name}: status is required" if provider["status"].to_s.empty?
        numeric_fields = %w[
          traffic_percentage volume_share_pct priority limit_amount_min limit_amount_max
          daily_amount_limit daily_approved_amount daily_turnover_min
          in_progress_count_limit in_progress_count in_progress_amount_limit in_progress_amount
          available_requisites requests_per_minute_limit conversion_24h avg_latency_sec
          provider_margin_pct merchant_margin_pct
        ]
        numeric_fields.each do |field|
          value = provider[field]
          next if value.nil?
          raise InputError, "#{name}: #{field} must be finite numeric" unless value.is_a?(Numeric) && value.finite?
          raise InputError, "#{name}: #{field} must be non-negative" if value.negative?
        end
        if provider.key?("conversion_24h") && provider["conversion_24h"].to_f > 1.0
          raise InputError, "#{name}: conversion_24h must be between 0 and 1"
        end
        if provider.key?("banks") && !provider["banks"].is_a?(Array)
          raise InputError, "#{name}: banks must be an array"
        end
        if provider.key?("card_brands") && !provider["card_brands"].is_a?(Array)
          raise InputError, "#{name}: card_brands must be an array"
        end
        if provider["limit_amount_min"] && provider["limit_amount_max"] && provider["limit_amount_min"].to_f > provider["limit_amount_max"].to_f
          raise InputError, "#{name}: limit_amount_min exceeds limit_amount_max"
        end
      end
      document
    end

    def self.validate_queue!(queue)
      raise InputError, "operations queue must be an array" unless queue.is_a?(Array)
      raise InputError, "every operation must be an object" unless queue.all? { |operation| operation.is_a?(Hash) }
      ids = queue.map { |operation| operation["operation_id"] }
      raise InputError, "operation ids must be unique and non-empty" if ids.any? { |id| id.to_s.empty? } || ids.uniq.length != ids.length
      queue.each do |operation|
        id = operation["operation_id"]
        raise InputError, "#{id}: operation_id must be a string" unless id.is_a?(String)
        raise InputError, "#{id}: amount must be finite numeric" unless operation["amount"].is_a?(Numeric) && operation["amount"].finite?
        raise InputError, "#{id}: amount must be positive" unless operation["amount"].positive?
        kopecks = BigDecimal(operation["amount"].to_s) * 100
        raise InputError, "#{id}: amount must have at most two decimal places" unless kopecks == kopecks.round(0)
        raise InputError, "#{operation['operation_id']}: bank is required" if operation["bank"].to_s.empty?
        begin
          Time.iso8601(operation.fetch("created_at"))
        rescue KeyError, ArgumentError, TypeError
          raise InputError, "#{id}: created_at must be ISO-8601"
        end
      end
      queue
    end

    def self.validate_profile!(profile, providers_document)
      raise InputError, "policy profile must be an object" unless profile.is_a?(Hash)
      fallback = profile.fetch("fallback_provider", "spacepayments")
      names = providers_document.fetch("providers").map { |provider| provider["payment_system"] }
      raise InputError, "fallback provider #{fallback} is missing" unless names.include?(fallback)
      raise InputError, "policy weights must be an object" unless profile.fetch("weights", {}).is_a?(Hash)
      profile.fetch("weights", {}).each do |name, value|
        raise InputError, "policy weight #{name} must be a finite non-negative number" unless value.is_a?(Numeric) && value.finite? && !value.negative?
      end
      %w[history_prior_strength recovery_rate traffic_debt_bound volume_debt_bound latency_timeout_sec conversion_guardrail].each do |name|
        value = profile[name]
        next if value.nil?
        raise InputError, "policy #{name} must be a finite non-negative number" unless value.is_a?(Numeric) && value.finite? && !value.negative?
      end
      allowed_modes = %w[balanced_minimax cascade conversion_first weighted_sum weighted_random]
      mode = profile.fetch("selection_mode", "balanced_minimax")
      raise InputError, "unsupported selection_mode: #{mode}" unless allowed_modes.include?(mode)
      adaptive = profile.fetch("adaptive_learning", {})
      raise InputError, "adaptive_learning must be an object" unless adaptive.is_a?(Hash)
      if adaptive.fetch("enabled", false)
        raise InputError, "adaptive_learning requires weighted_sum or balanced_minimax" unless %w[weighted_sum balanced_minimax].include?(mode)
        { "half_life_sec" => 300, "prior_strength" => 8, "probe_after_sec" => 60, "probe_max_amount" => 5000,
          "minimum_evidence" => 6, "minimum_drop" => 0.1, "uncertainty_multiplier" => 1.5 }.each do |key, default|
          value = adaptive.fetch(key, default)
          raise InputError, "adaptive_learning #{key} must be finite and positive" unless value.is_a?(Numeric) && value.finite? && value > 0
        end
        window = adaptive.fetch("window_size", 40)
        raise InputError, "adaptive window_size must be an integer in 1..1000" unless window.is_a?(Integer) && window.between?(1, 1000)
        interval = adaptive.fetch("probe_every", 20)
        raise InputError, "probe_every must be 0 (off) or an integer >= 2" unless interval.is_a?(Integer) && (interval.zero? || interval >= 2)
        delta = adaptive.fetch("max_probe_regret_delta", 0.25)
        raise InputError, "max_probe_regret_delta must be in 0..1" unless delta.is_a?(Numeric) && delta.finite? && delta.between?(0, 1)
        bands = adaptive.fetch("amount_bands", [1000, 5000, 10000, 50000, 100000])
        raise InputError, "amount_bands must be sorted distinct positive bounds" unless bands.is_a?(Array) && !bands.empty? && bands.all? { |v| v.is_a?(Numeric) && v.finite? && v > 0 } && bands == bands.sort.uniq
        %w[history_half_life_sec history_snapshot_strength].each do |key|
          value = adaptive.fetch(key, 8)
          raise InputError, "#{key} must be finite and positive" unless value.is_a?(Numeric) && value.finite? && value > 0
        end
      end
      planner = profile.fetch("outcome_planner", {})
      raise InputError, "outcome_planner must be an object" unless planner.is_a?(Hash)
      if planner["enabled"]
        raise InputError, "outcome planner requires weighted_sum mode" unless mode == "weighted_sum"
        raise InputError, "outcome planner cannot combine capacity_guard overrides" if profile.dig("capacity_guard", "enabled")
        raise InputError, "outcome planner owns exploration; disable adaptive probes" if adaptive.fetch("probe_every", 0) != 0
        # Legacy profiles remain readable, but this field no longer limits
        # exact pair-exchange ordering. New profiles omit it entirely.
        if planner.key?("max_chains")
          limit = planner["max_chains"]
          raise InputError, "legacy max_chains must be integer 1..1000" unless limit.is_a?(Integer) && limit.between?(1, 1000)
        end
        weights = planner["weights"]
        raise InputError, "outcome planner weights must be nonempty object" unless weights.is_a?(Hash) && !weights.empty?
        allowed = %w[count_potential_change volume_potential_change attempts latency_sec pending_ruble_seconds unresolved_or_failed_probability fallback_probability scarcity_slots business_factors]
        raise InputError, "unknown outcome planner weight" unless (weights.keys - allowed).empty?
        weights.merge("pending_hold_sec" => planner.fetch("pending_hold_sec", 180), "uncertainty_haircut" => planner.fetch("uncertainty_haircut", 0)).each do |key, value|
          raise InputError, "planner #{key} must be finite nonnegative" unless value.is_a?(Numeric) && value.finite? && value >= 0
        end
        pending = planner.fetch("pending_probabilities", {})
        raise InputError, "pending probabilities must name existing providers" unless pending.is_a?(Hash) && (pending.keys - names).empty?
        pending.each_value { |v| raise InputError, "pending probability must be 0..1" unless v.is_a?(Numeric) && v.finite? && v.between?(0, 1) }
        opportunity = planner.fetch("opportunity", {})
        raise InputError, "opportunity must be object" unless opportunity.is_a?(Hash)
        { "minimum_samples" => 10, "horizon_operations" => 12, "arrival_interval_sec" => 10 }.each do |key, default|
          value = opportunity.fetch(key, default)
          raise InputError, "opportunity #{key} must be integer 1..100" unless value.is_a?(Integer) && value.between?(1, 100)
        end
        steps = opportunity.fetch("repair_steps_rub", [1000, 10000, 50000, 100000])
        raise InputError, "repair steps must be 1..20 finite positive values" unless steps.is_a?(Array) && steps.length.between?(1, 20) && steps.all? { |v| v.is_a?(Numeric) && v.finite? && v > 0 }
      end
      guard = profile.fetch("capacity_guard", {})
      raise InputError, "capacity_guard must be an object" unless guard.is_a?(Hash)
      if guard.fetch("enabled", false)
        raise InputError, "capacity_guard requires balanced_minimax or weighted_sum" unless %w[balanced_minimax weighted_sum].include?(mode)
        %w[max_primary_regret_delta max_conversion_drop].each do |key|
          value = guard.fetch(key, key == "max_conversion_drop" ? 0.02 : 0.25)
          raise InputError, "capacity_guard #{key} must be finite and between 0 and 1" unless value.is_a?(Numeric) && value.finite? && value >= 0 && value <= 1
        end
        %w[min_samples max_samples].each do |key|
          value = guard.fetch(key, key == "min_samples" ? 20 : 1000)
          raise InputError, "capacity_guard #{key} must be an integer from 1 to 10000" unless value.is_a?(Integer) && value >= 1 && value <= 10000
        end
      end
      preferences = profile.fetch("amount_preferences", {})
      raise InputError, "amount_preferences must be an object" unless preferences.is_a?(Hash)
      unknown = preferences.keys - names
      raise InputError, "amount_preferences contains unknown providers: #{unknown.join(', ')}" if unknown.any?
      volume_targets = profile.fetch("volume_targets", {})
      raise InputError, "volume_targets must be an object" unless volume_targets.is_a?(Hash)
      unknown = volume_targets.keys - names
      raise InputError, "volume_targets contains unknown providers: #{unknown.join(', ')}" if unknown.any?
      volume_targets.each do |name, value|
        raise InputError, "volume target #{name} must be a non-negative number" unless value.is_a?(Numeric) && !value.negative?
      end
      profile
    end
  end
end
