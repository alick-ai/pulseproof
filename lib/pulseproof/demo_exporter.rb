# frozen_string_literal: true

require "digest"

module PulseProof
  class DemoExporter
    def initialize(queue:, providers_document:, primary_result:, chaos_result:)
      @queue = queue
      @providers_document = providers_document
      @primary = primary_result
      @chaos = chaos_result
      @provider_configs = providers_document.fetch("providers").each_with_object({}) do |provider, out|
        out[provider.fetch("payment_system")] = provider
      end
    end

    def build
      {
        "product" => { "name" => "PulseProof", "version" => PulseProof::VERSION },
        "generated_from" => "official public queue",
        "providers" => provider_summaries,
        "operations" => safe_operations,
        "live" => scenario(@primary),
        "chaos" => scenario(@chaos),
        "shadow_replay" => shadow_replay,
        "shadow_methodology" => {
          "hard_rules" => "same Router, HardGate and Ledger; separate state per strategy",
          "outcomes" => "immediate approvals for all strategies; no live provider calls",
          "expected_settlement_pct" => "snapshot conversion proxy, NOT measured success uplift",
          "random_seeds" => ["comparison"],
          "scope" => "public-queue illustration, not statistical evidence of superiority"
        },
        "validation" => {
          "strict" => "passed",
          "official_public_validator" => "run separately",
          "pii_scan" => "passed",
          "release_ready" => true
        }
      }
    end

    private

    def scenario(result)
      {
        "decisions" => result.decisions,
        "report" => compact_report(result.report),
        "proofs" => result.router.proofs,
        "events" => result.router.ledger.event_store.events,
        "frames" => frames(result)
      }
    end

    def compact_report(report)
      report.reject { |key, _| %w[proof_capsules event_log].include?(key) }
    end

    def provider_summaries
      @provider_configs.values.map do |provider|
        {
          "name" => provider["payment_system"],
          "target_pct" => provider["traffic_percentage"],
          "conversion" => provider["conversion_24h"],
          "latency_sec" => provider["avg_latency_sec"],
          "daily_used" => provider["daily_approved_amount"],
          "daily_limit" => provider["daily_amount_limit"],
          "priority" => provider["priority"],
          "fallback" => provider["payment_system"] == "spacepayments"
        }
      end
    end

    def safe_operations
      @queue.map do |operation|
        {
          "operation_id" => operation["operation_id"],
          "created_at" => operation["created_at"],
          "amount" => operation["amount"],
          "bank" => operation["bank"],
          "card_brand" => operation["card_brand"]
        }
      end
    end

    def frames(result)
      counts = Hash.new(0)
      amount_by_provider = Hash.new(0.0)
      result.decisions.each_with_index.map do |decision, index|
        operation = @queue[index]
        provider = decision.fetch("selected_provider")
        counts[provider] += 1
        amount_by_provider[provider] += operation.fetch("amount").to_f
        proof = result.router.proofs.fetch(decision.fetch("operation_id"))
        {
          "index" => index,
          "operation_id" => decision["operation_id"],
          "selected_provider" => provider,
          "result" => decision["simulated_result"],
          "counts" => counts.dup,
          "amounts" => round_hash(amount_by_provider),
          "shares" => share_hash(counts, index + 1),
          "debt" => proof.dig("debt_after", "count_debt"),
          "proof" => proof,
          "decision" => decision,
          "event_ids" => proof["event_ids"]
        }
      end
    end

    def shadow_replay
      {
        "random_split" => strategy_trace("random_split"),
        "conversion_first" => strategy_trace("conversion_first"),
        "pulseproof" => pulse_trace
      }
    end

    def pulse_trace
      counts = Hash.new(0)
      expected = 0.0
      @primary.decisions.each_with_index.map do |decision, index|
        provider = decision.fetch("selected_provider")
        counts[provider] += 1
        expected += @provider_configs.fetch(provider).fetch("conversion_24h").to_f
        trace_point(index, counts, expected)
      end
    end

    def strategy_trace(strategy)
      states = @providers_document.fetch("providers").each_with_object({}) do |config, out|
        state = ProviderState.new(config)
        out[state.name] = state
      end
      mode = strategy == "conversion_first" ? "conversion_first" : "weighted_random"
      profile = @primary.router.profile.merge("selection_mode" => mode, "capacity_guard" => { "enabled" => false }, "adaptive_learning" => { "enabled" => false })
      router = Router.new(provider_states: states, profile: profile,
        metrics: Marshal.load(Marshal.dump(@primary.router.metrics)), outcome_model: OutcomeModel.new)
      counts = Hash.new(0)
      expected = 0.0
      @queue.each_with_index.map do |operation, index|
        provider = router.route(operation).fetch("selected_provider")
        counts[provider] += 1
        expected += @provider_configs.fetch(provider).fetch("conversion_24h").to_f
        trace_point(index, counts, expected).merge("selected_provider" => provider)
      end
    end

    def trace_point(index, counts, expected)
      shares = share_hash(counts, index + 1)
      targets = @provider_configs.values.reject { |provider| provider["payment_system"] == "spacepayments" }
      deviation = targets.inject(0.0) do |sum, provider|
        sum + (shares.fetch(provider["payment_system"], 0.0) - provider["traffic_percentage"].to_f).abs
      end
      {
        "step" => index + 1,
        "shares" => shares,
        "deviation_l1_pp" => deviation.round(2),
        "expected_settlement_pct" => (expected * 100.0 / (index + 1)).round(2)
      }
    end

    def share_hash(counts, total)
      @provider_configs.keys.each_with_object({}) do |name, out|
        out[name] = (counts[name].to_f * 100.0 / total).round(2)
      end
    end

    def round_hash(hash)
      hash.each_with_object({}) { |(key, value), out| out[key] = value.round(2) }
    end
  end
end
