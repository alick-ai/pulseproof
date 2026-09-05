# frozen_string_literal: true

module PulseProof
  class PlannerLab < AdaptiveLab
    def initialize(providers_document:, profile:, baseline_profile:, adaptive_profile:, seeds: [11, 37, 91], phase_length: 40)
      super(providers_document: providers_document, profile: profile, baseline_profile: baseline_profile, seeds: seeds, phase_length: phase_length)
      @adaptive_profile = adaptive_profile
    end

    def call
      scenarios = %w[stable localized_recovery persistent_outage bank_specialization capacity_pressure]
      frozen = Marshal.load(Marshal.dump(@profile))
      frozen["adaptive_learning"]["learn_from_outcomes"] = false
      policies = { "balanced" => @baseline_profile, "adaptive" => @adaptive_profile, "planner_frozen" => frozen, "planner" => @profile }
      rows = scenarios.flat_map do |scenario|
        @seeds.map do |seed|
          policies.each_with_object({ "scenario" => scenario, "seed" => seed }) do |(name, policy), row|
            row[name] = run(policy, scenario, seed)
          end
        end
      end
      summary = scenarios.each_with_object({}) do |scenario, output|
        samples = rows.select { |r| r["scenario"] == scenario }
        output[scenario] = policies.keys.each_with_object({}) do |name, arms|
          arms[name] = %w[first_attempt_approval_pct mean_attempts count_l1_pp fallback_count mean_local_route_ms].each_with_object({}) do |metric, values|
            values[metric] = (samples.sum { |r| r[name][metric] }.to_f / samples.length).round(4)
          end
        end
      end
      { "kind" => "paired synthetic four-policy experiment, not measured bank uplift", "seeds" => @seeds,
        "operations_per_run" => @phase_length * 3, "summary" => summary, "results" => rows,
        "assumptions" => ["same chosen-action response mechanism, no future operations visible to router",
          "history contains only past selected outcomes, 120 synthetic records per scenario/seed",
          "capacity_pressure uses explicit artificial budgets and 150000 RUB every tenth operation",
          "other scenarios use ample daily capacity and no bank restrictions",
          "all outcomes simulated; rates independent across attempts; no real tariffs or bank connection",
          "seed ranges are not confidence intervals; all policies use the same hard gate and independent ledger validation"] }
    end

    private

    def document_for(scenario)
      document = Marshal.load(Marshal.dump(@document))
      if scenario == "capacity_pressure"
        document["providers"].each do |p|
          p["daily_amount_limit"] = { "vipay" => 200000, "payflow" => 200000, "quickpay" => 500000 }.fetch(p["payment_system"], 100_000_000)
        end
      end
      document
    end

    def history_for(scenario, seed)
      names = %w[vipay payflow quickpay]
      states = document_for(scenario)["providers"].each_with_object({}) { |p,h| h[p["payment_system"]] = ProviderState.new(p) }
      environment = Environment.new(seed: seed + 10000, scenario: scenario, phase_length: @phase_length, fallback: @profile.fetch("fallback_provider"))
      Array.new(120) do |index|
        name = names[index % names.length]
        operation = { "operation_id" => "historical_#{-index - 1}", "amount" => scenario == "capacity_pressure" && index % 10 == 9 ? 150000 : 2000,
          "bank" => index.even? ? "alfa" : "sberbank",
          "created_at" => (Time.iso8601(@document.fetch("snapshot_at")) - 86400 + index * 10).iso8601 }
        # History assigned round-robin among compatible providers, no oracle labels.
        name = "quickpay" if operation["amount"] == 150000
        response = environment.call(operation, states.fetch(name), 1)
        operation.merge("payment_system" => name, "status" => response["result"], "latency_sec" => response["latency_sec"])
      end
    end
  end
end
