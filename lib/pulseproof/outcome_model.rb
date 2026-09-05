# frozen_string_literal: true

require "digest"

module PulseProof
  class OutcomeModel
    def initialize(mode: "approve", seed: "hackgenesis-2026", scripts: {}, timeout_sec: 180)
      @mode = mode
      @seed = seed
      @scripts = scripts
      @timeout_sec = timeout_sec.to_f
    end

    def call(operation, provider, attempt)
      scripted = @scripts[operation.fetch("operation_id")]
      scripted_attempt = scripted && scripted[attempt - 1]
      return normalize(scripted_attempt, provider) if scripted_attempt
      return approved(provider) if @mode == "approve" || provider.name == "spacepayments"

      deterministic(operation, provider, attempt)
    end

    private

    def approved(provider)
      { "result" => "approved", "latency_sec" => provider.config["avg_latency_sec"].to_f }
    end

    def normalize(value, provider)
      result = value.is_a?(Hash) ? value.dup : { "result" => value.to_s }
      result["latency_sec"] ||= provider.config["avg_latency_sec"].to_f
      result
    end

    def deterministic(operation, provider, attempt)
      key = [@seed, operation.fetch("operation_id"), provider.name, attempt].join(":")
      bucket = Digest::SHA256.hexdigest(key)[0, 12].to_i(16).to_f / 0xffffffffffff
      conversion = provider.config["conversion_24h"].to_f
      latency = deterministic_latency(key, provider)
      if latency > @timeout_sec
        { "result" => "expired", "latency_sec" => latency, "resolution" => bucket < conversion ? "approved" : "rejected" }
      elsif bucket < conversion
        { "result" => "approved", "latency_sec" => latency }
      else
        { "result" => "rejected", "latency_sec" => latency }
      end
    end

    def deterministic_latency(key, provider)
      factor = Digest::SHA256.hexdigest("latency:#{key}")[0, 8].to_i(16).to_f / 0xffffffff
      (provider.config["avg_latency_sec"].to_f * (0.55 + factor * 1.9)).round(2)
    end
  end
end
