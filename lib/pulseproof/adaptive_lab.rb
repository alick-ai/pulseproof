# frozen_string_literal: true

module PulseProof
  class AdaptiveLab
    # Hidden response mechanism: the router receives only the chosen attempt's
    # outcome. Each arm shares deterministic potential outcomes across policies.
    class Environment < OutcomeModel
      def initialize(seed:, scenario:, phase_length:, fallback:)
        @seed, @scenario, @phase_length, @fallback = seed, scenario, phase_length, fallback
      end

      def call(operation, provider, _attempt)
        index = operation.fetch("operation_id").split("_").last.to_i - 1
        phase = index / @phase_length
        rate = { "payflow" => 0.96, "vipay" => 0.90, "quickpay" => 0.88 }.fetch(provider.name, 0.98)
        affected = provider.name == "payflow" && operation["bank"] == "alfa"
        outage = (@scenario == "localized_recovery" && phase == 1) || (@scenario == "persistent_outage" && phase >= 1)
        rate = 0.10 if affected && outage
        if @scenario == "bank_specialization"
          rate = { "payflow" => operation["bank"] == "alfa" ? 0.98 : 0.20,
            "quickpay" => operation["bank"] == "alfa" ? 0.35 : 0.97, "vipay" => 0.8 }.fetch(provider.name, 0.98)
        end
        rate = 0.98 if provider.name == @fallback
        word = Canonical.digest([@seed, operation["operation_id"], provider.name])[0, 12].to_i(16)
        approved = word.to_f / 0xffffffffffff < rate
        { "result" => approved ? "approved" : "rejected", "latency_sec" => approved ? 1 : 0.1 }
      end
    end

    def initialize(providers_document:, profile:, baseline_profile:, seeds: [11, 37, 91], phase_length: 80)
      @document = Marshal.load(Marshal.dump(providers_document))
      @profile = profile
      @baseline_profile = baseline_profile
      missing = %w[vipay payflow quickpay] - @document.fetch("providers").map { |p| p["payment_system"] }
      raise InputError, "learning lab fixture needs providers: #{missing.join(', ')}" if missing.any?
      raise InputError, "learning lab requires one or more seeds" if seeds.empty?
      @seeds, @phase_length = seeds, phase_length
      # Synthetic fixture deliberately removes capacity and bank constraints
      # as confounders. HardGate and the real ledger remain enabled in both arms.
      @document.fetch("providers").each do |provider|
        provider["banks"] = []
        provider["daily_amount_limit"] = 100_000_000
        provider["daily_approved_amount"] = 0
      end
    end

    def call
      scenarios = %w[stable localized_recovery persistent_outage]
      rows = scenarios.flat_map do |scenario|
        @seeds.map do |seed|
          fixed = Marshal.load(Marshal.dump(@profile))
          fixed["adaptive_learning"]["learn_from_outcomes"] = false
          fixed["adaptive_learning"]["probe_every"] = 0
          { "scenario" => scenario, "seed" => seed,
            "balanced" => run(@baseline_profile, scenario, seed),
            "fixed" => run(fixed, scenario, seed), "adaptive" => run(@profile, scenario, seed) }
        end
      end
      { "kind" => "paired synthetic learning experiment; not measured business uplift",
        "model" => "fixed vs adaptive: identical weights and initial priors, only feedback and probes differ; balanced: original submission policy as additional comparator",
        "seeds" => @seeds, "operations_per_run" => @phase_length * 3,
        "assumptions" => ["synthetic banks and ample daily capacity", "history empty; no future training labels",
          "hidden payflow/alfa approval probability 0.96→0.10→0.96 in recovery case",
          "same potential outcome for each operation/provider in both arms", "only chosen outcomes reach learner",
          "deterministic probe schedule; not unbiased exploration for off-policy evaluation"],
        "results" => rows,
        "summary" => scenarios.to_h { |scenario| [scenario, summarize(rows.select { |row| row["scenario"] == scenario })] } }
    end

    private

    def run(policy, scenario, seed)
      fallback = policy.fetch("fallback_provider", "spacepayments")
      environment = Environment.new(seed: seed, scenario: scenario, phase_length: @phase_length, fallback: fallback)
      session = RuntimeSession.new(providers_document: document_for(scenario), profile: policy, history: history_for(scenario, seed), outcome_model: environment)
      phase_stats = Hash.new { |h, k| h[k] = { "operations" => 0, "first_approved" => 0, "first_providers" => Hash.new(0) } }
      first_approved = 0
      attempts = 0
      first_brier = 0.0
      before = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      (@phase_length * 3).times do |index|
        operation = { "operation_id" => "experiment_#{index + 1}", "amount" => 2000,
          "bank" => index.even? ? "alfa" : "sberbank",
          "created_at" => (Time.iso8601(@document.fetch("snapshot_at")) + index * 10).iso8601 }
        operation["amount"] = 150000 if scenario == "capacity_pressure" && index % 10 == 9
        decision = session.process("type" => "operation", "operation" => operation).fetch("decision")
        selected = decision["attempts"].select { |attempt| attempt["decision"] == "selected" }
        first = selected.first
        success = first["result"] == "approved" ? 1 : 0
        first_approved += success
        attempts += selected.length
        metric = session.router.proofs[operation["operation_id"]]["attempt_snapshots"].first["snapshot"]["metrics"][first["provider"]]
        prediction = metric.dig("adaptive_prediction", "mean") || metric["conservative_conversion"]
        first_brier += (prediction - success)**2
        stat = phase_stats["phase_#{index / @phase_length + 1}:#{operation['bank']}"]
        stat["operations"] += 1
        stat["first_approved"] += success
        stat["first_providers"][first["provider"]] += 1
      end
      routing_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - before) * 1000
      report = session.report # full independent validation, excluded from timing
      count = session.decisions.length
      { "first_attempt_approval_pct" => (first_approved * 100.0 / count).round(3),
        "mean_attempts" => (attempts.to_f / count).round(5), "first_attempt_brier" => (first_brier / count).round(6),
        "count_l1_pp" => report.dig("soft_goal_analysis", "raw_target_deviation_l1_pp"),
        "fallback_count" => report.dig("distribution", fallback, "count"),
        "learning" => report["adaptive_learning"], "phases" => phase_stats,
        "planning" => report["outcome_planning"],
        "mean_local_route_ms" => (routing_ms / count).round(3), "validated" => true }
    end

    def summarize(rows)
      differences = rows.map { |row| row["adaptive"]["first_attempt_approval_pct"] - row["fixed"]["first_attempt_approval_pct"] }
      balanced_differences = rows.map { |row| row["adaptive"]["first_attempt_approval_pct"] - row["balanced"]["first_attempt_approval_pct"] }
      { "mean_first_attempt_delta_pp" => (differences.sum / differences.length).round(3),
        "min_seed_delta_pp" => differences.min.round(3), "max_seed_delta_pp" => differences.max.round(3),
        "seeds_improved" => differences.count { |delta| delta > 0 }, "seeds_worsened" => differences.count { |delta| delta < 0 },
        "mean_target_error_delta_pp" => (rows.sum { |row| row["adaptive"]["count_l1_pp"] - row["fixed"]["count_l1_pp"] } / rows.length).round(3),
        "mean_first_attempt_delta_vs_balanced_pp" => (balanced_differences.sum / rows.length).round(3),
        "min_seed_delta_vs_balanced_pp" => balanced_differences.min.round(3),
        "max_seed_delta_vs_balanced_pp" => balanced_differences.max.round(3),
        "mean_target_error_delta_vs_balanced_pp" => (rows.sum { |row| row["adaptive"]["count_l1_pp"] - row["balanced"]["count_l1_pp"] } / rows.length).round(3),
        "caution" => "small synthetic seed set; not a confidence interval or production guarantee" }
    end

    def document_for(_scenario)
      @document
    end

    def history_for(_scenario, _seed)
      []
    end
  end
end
