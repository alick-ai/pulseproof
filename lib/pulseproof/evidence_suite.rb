# frozen_string_literal: true

require "time"

module PulseProof
  class EvidenceSuite
    GROUP_TITLES = {
      "hard" => "Жёсткие ограничения",
      "soft" => "Причинное влияние факторов",
      "runtime" => "Потоковое исполнение",
      "challenge" => "Обратная проверка решения"
    }.freeze

    def initialize(root:)
      @root = File.expand_path(root)
      @providers_document = InputLoader.validate_provider_document!(InputLoader.json(path("data/providers.json")))
      @queue = InputLoader.validate_queue!(InputLoader.json(path("data/operations_queue_10.json")))
      @history = InputLoader.history(path("data/operations_history.csv"))
      @balanced_profile = InputLoader.validate_profile!(InputLoader.json(path("config/balanced.json")), @providers_document)
    end

    def call
      cases = hard_cases + soft_cases + runtime_cases + challenge_cases
      passed = cases.count { |item| item.fetch("passed") }
      groups = GROUP_TITLES.each_with_object({}) do |(group, title), out|
        selected = cases.select { |item| item.fetch("group") == group }
        out[group] = {
          "title" => title,
          "passed" => selected.count { |item| item.fetch("passed") },
          "total" => selected.length
        }
      end
      {
        "suite" => "public_requirements_evidence",
        "source" => "public sample and isolated counterfactual snapshots",
        "scope" => "Executable evidence for stated rules; not a claim about unknown organizer inputs or real bank connectivity.",
        "summary" => { "passed" => passed, "total" => cases.length, "all_passed" => passed == cases.length, "groups" => groups },
        "cases" => cases
      }
    end

    private

    def hard_cases
      base = deep_copy(@providers_document.fetch("providers").find { |item| item.fetch("payment_system") == "vipay" })
      operation = evidence_operation(amount: 15_000, bank: "sberbank")
      cases = []

      minimum = hard_evaluation(base, evidence_operation(amount: base.fetch("limit_amount_min"), bank: "sberbank"))
      maximum = hard_evaluation(base, evidence_operation(amount: base.fetch("limit_amount_max"), bank: "sberbank"))
      cases << item("hard_amount_boundaries", "hard", "Границы суммы включительны", "eligible at min and max",
        { "minimum" => minimum.reason, "maximum" => maximum.reason }, minimum.eligible && maximum.eligible)

      cases << hard_failure("hard_inactive", "Отключённый провайдер", base.merge("status" => "inactive"), operation, "provider_inactive")
      cases << hard_failure("hard_traffic_disabled", "Нулевая доля отключает внешний маршрут", base.merge("traffic_percentage" => 0), operation, "traffic_disabled")
      cases << hard_failure("hard_amount_min", "Сумма ниже минимума", base, evidence_operation(amount: base.fetch("limit_amount_min") - 0.01, bank: "sberbank"), "amount_below_minimum")
      cases << hard_failure("hard_amount_max", "Сумма выше максимума", base, evidence_operation(amount: base.fetch("limit_amount_max") + 0.01, bank: "sberbank"), "amount_exceeds_limit")
      cases << hard_failure("hard_daily_limit", "Дневной денежный лимит", base.merge("daily_approved_amount" => 4_999_001), evidence_operation(amount: 1000, bank: "sberbank"), "daily_amount_limit_exceeded")
      cases << hard_failure("hard_inflight_count", "Лимит одновременных операций", base.merge("in_progress_count" => base.fetch("in_progress_count_limit")), operation, "in_progress_count_limit_exceeded")
      cases << hard_failure("hard_inflight_amount", "Лимит суммы в обработке", base.merge("in_progress_amount_limit" => 380_999), evidence_operation(amount: 1000, bank: "sberbank"), "in_progress_amount_limit_exceeded")
      cases << hard_failure("hard_requisites", "Доступные реквизиты", base.merge("available_requisites" => 0), operation, "no_available_requisites")

      rpm_state = ProviderState.new(base.merge("requests_per_minute_limit" => 1))
      rpm_state.record_request!(Time.parse(operation.fetch("created_at")))
      rpm = HardGate.new.evaluate(operation, rpm_state)
      cases << item("hard_rpm", "hard", "Лимит запросов в минуту", "rpm_limit_exceeded", { "reason" => rpm.reason, "facts" => rpm.facts }, !rpm.eligible && rpm.reason == "rpm_limit_exceeded")

      cases << hard_failure("hard_margin", "Запрет отрицательной экономики", base.merge("provider_margin_pct" => 1.6), operation, "negative_margin")
      cases << hard_failure("hard_bank", "Банк вне allowlist", base, evidence_operation(amount: 15_000, bank: "alfa"), "bank_not_in_list")
      cases << hard_failure("hard_card", "Платёжная система карты", base.merge("card_brands" => ["visa"]), operation.merge("card_brand" => "mastercard"), "card_brand_not_allowed")

      fallback_config = deep_copy(@providers_document.fetch("providers").find { |provider| provider.fetch("payment_system") == "spacepayments" })
      fallback_state = ProviderState.new(fallback_config)
      normal = HardGate.new.evaluate(operation, fallback_state)
      exhausted = HardGate.new.evaluate(operation, fallback_state, fallback: true)
      cases << item("hard_fallback_discipline", "hard", "Fallback недоступен, пока есть внешние кандидаты", "fallback_only then eligible",
        { "normal_pool" => normal.reason, "after_exhaustion" => exhausted.reason }, !normal.eligible && normal.reason == "fallback_only" && exhausted.eligible)
      cases
    end

    def soft_cases
      [
        soft_flip("soft_count", "Целевая доля по количеству", "count",
          before: { configs: soft_configs(traffic: [70, 30]) },
          after: { configs: soft_configs(traffic: [30, 70]) }),
        soft_flip("soft_volume", "Целевая доля по объёму", "volume",
          before: { profile: { "volume_targets" => { "alpha" => 80, "beta" => 20 } } },
          after: { profile: { "volume_targets" => { "alpha" => 20, "beta" => 80 } } }),
        soft_flip("soft_conversion", "Консервативная конверсия", "conversion",
          before: { metrics: { "alpha" => 0.95, "beta" => 0.70 } },
          after: { metrics: { "alpha" => 0.70, "beta" => 0.95 } }),
        soft_flip("soft_load", "Текущая нагрузка", "load",
          before: { configs: soft_configs(load: [10, 80]) },
          after: { configs: soft_configs(load: [90, 10]) }),
        soft_flip("soft_margin", "Экономика провайдера", "margin",
          before: { configs: soft_configs(margin: [0.5, 1.3]) },
          after: { configs: soft_configs(margin: [1.3, 0.5]) }),
        soft_flip("soft_priority", "Приоритет договора", "priority",
          before: { configs: soft_configs(priority: [1, 10]) },
          after: { configs: soft_configs(priority: [10, 1]) }),
        soft_flip("soft_amount_fit", "Предпочтительный диапазон суммы", "amount_fit",
          before: { amount: 75, profile: { "amount_preferences" => { "alpha" => { "min" => 1, "max" => 100 }, "beta" => { "min" => 101, "max" => 200 } } } },
          after: { amount: 150, profile: { "amount_preferences" => { "alpha" => { "min" => 1, "max" => 100 }, "beta" => { "min" => 101, "max" => 200 } } } }),
        soft_flip("soft_turnover", "Минимальный оборот", "turnover_min",
          before: { configs: soft_configs(turnover: [0, 90_000]) },
          after: { configs: soft_configs(turnover: [90_000, 0]) })
      ]
    end

    def runtime_cases
      first = balanced_result
      second = run_profile("config/balanced.json")
      cases = []
      first_digest = Canonical.digest({ "decisions" => first.decisions, "report" => first.report })
      second_digest = Canonical.digest({ "decisions" => second.decisions, "report" => second.report })
      cases << item("runtime_deterministic", "runtime", "Повторяемость", "identical digest",
        { "first" => first_digest, "second" => second_digest }, first_digest == second_digest)

      expected_ids = @queue.map { |operation| operation.fetch("operation_id") }
      actual_ids = first.decisions.map { |decision| decision.fetch("operation_id") }
      cases << item("runtime_coverage", "runtime", "Полное покрытие очереди", "every operation exactly once",
        { "expected" => expected_ids.length, "actual" => actual_ids.length, "unique" => actual_ids.uniq.length }, actual_ids == expected_ids && actual_ids.uniq.length == actual_ids.length)

      chaos_model = OutcomeModel.new(mode: "approve", scripts: {
        "op_106" => [
          { "result" => "expired", "latency_sec" => 181, "resolution" => "cancelled" },
          { "result" => "approved", "latency_sec" => 29 }
        ]
      })
      chaos = run_profile("config/balanced.json", outcome_model: chaos_model)
      chaos_decision = chaos.decisions.find { |decision| decision.fetch("operation_id") == "op_106" }
      selected = chaos_decision.fetch("attempts").select { |attempt| attempt.fetch("decision") == "selected" }
      events = chaos.router.ledger.event_store.events.select { |event| event.dig("payload", "operation_id") == "op_106" }.map { |event| event.fetch("type") }
      cascade_ok = selected.map { |attempt| attempt.fetch("provider") } == %w[vipay quickpay] &&
        selected.map { |attempt| attempt.fetch("result") } == %w[expired approved] &&
        %w[attempt_timeout attempt_cancelled attempt_released attempt_reroute].all? { |name| events.include?(name) }
      cases << item("runtime_timeout_cascade", "runtime", "Timeout → подтверждённая отмена → освобождение → fallback", "safe reroute after release",
        { "providers" => selected.map { |attempt| attempt.fetch("provider") }, "results" => selected.map { |attempt| attempt.fetch("result") }, "events" => events }, cascade_ok)

      pending = run_profile("config/balanced.json", outcome_model: OutcomeModel.new(mode: "approve", scripts: {
        "op_101" => [{ "result" => "expired", "latency_sec" => 181 }]
      }))
      pending_decision = pending.decisions.find { |decision| decision.fetch("operation_id") == "op_101" }
      pending_ok = pending_decision.fetch("simulated_result") == "expired" &&
        pending.report.dig("reconciliation", "pending_count") == 1 && pending.report.dig("reconciliation", "reserved_count") == 1
      cases << item("runtime_pending_reserve", "runtime", "Неизвестный статус удерживает резерв", "pending=1 and reserved=1",
        { "result" => pending_decision.fetch("simulated_result"), "pending" => pending.report.dig("reconciliation", "pending_count"), "reserved" => pending.report.dig("reconciliation", "reserved_count") }, pending_ok)

      events_before = first.router.ledger.event_store.events.length
      original = first.decisions.first
      duplicate = first.router.route(@queue.first)
      events_after = first.router.ledger.event_store.events.length
      cases << item("runtime_idempotency", "runtime", "Повтор операции не создаёт вторую выплату", "same response and no new event",
        { "events_before" => events_before, "events_after" => events_after, "same_response" => duplicate == original }, duplicate == original && events_before == events_after)

      serialized = JSON.generate({ "decisions" => first.decisions, "report" => first.report })
      phones = @queue.map { |operation| operation.dig("payout_requisite", "sbp", "phone") }.compact
      leaked = phones.select { |phone| serialized.include?(phone) }
      cases << item("runtime_privacy", "runtime", "Чувствительные реквизиты не попадают в артефакты", "zero queue phones",
        { "checked" => phones.length, "leaked" => leaked.length }, leaked.empty?)

      cases << item("runtime_no_lookahead", "runtime", "Роутер не видит будущую очередь", "lookahead_used=false",
        { "lookahead_used" => first.report.dig("audit", "lookahead_used") }, first.report.dig("audit", "lookahead_used") == false)
      cases
    end

    def challenge_cases
      switch = policy_challenge("op_101", "vipay", "count_potential_change")
      veto = policy_challenge("op_103", "vipay", "count_potential_change")
      [
        item("challenge_weight_boundary", "challenge", "Минимальная цена переключения", "verified counterfactual with adjacent losing Float",
          {
            "operation_id" => "op_101",
            "provider" => "vipay",
            "factor" => switch["factor"],
            "current_weight" => switch["current_weight"],
            "boundary" => switch["nearest_boundary"],
            "proposed_weight" => switch["proposed_weight"],
            "original_chain" => switch["original_chain"],
            "verified_chain" => switch["verified_chain"],
            "adjacent_losing_chain" => switch.dig("adjacent_weight_toward_current", "chain"),
            "snapshot_hash" => switch["snapshot_hash"],
            "plan_context" => switch["plan_context"]
          }, switch["status"] == "verified_counterfactual" && switch["snapshot_certificate_verified"] && switch["original_chain"] != switch["verified_chain"]),
        item("challenge_hard_veto", "challenge", "Мягкий вес не обходит hard-ограничение", "not_eligible",
          { "operation_id" => "op_103", "provider" => "vipay", "status" => veto["status"], "hard_reason" => veto["hard_reason"], "snapshot_hash" => veto["snapshot_hash"] },
          veto["status"] == "not_eligible" && veto["snapshot_certificate_verified"])
      ]
    end

    def hard_failure(id, title, config, operation, expected)
      result = hard_evaluation(config, operation)
      item(id, "hard", title, expected, { "reason" => result.reason, "facts" => result.facts }, !result.eligible && result.reason == expected)
    end

    def hard_evaluation(config, operation)
      HardGate.new.evaluate(operation, ProviderState.new(config))
    end

    def soft_flip(id, title, factor, before:, after:)
      first = soft_selection(factor, **before)
      second = soft_selection(factor, **after)
      passed = first.fetch("all_eligible") && second.fetch("all_eligible") && first.fetch("winner") != second.fetch("winner")
      item(id, "soft", title, "one declared input change flips the winner",
        { "factor" => factor, "before" => first, "after" => second }, passed)
    end

    def soft_selection(factor, configs: soft_configs, metrics: nil, profile: {}, amount: 10_000)
      states = configs.each_with_object({}) do |config, out|
        state = ProviderState.new(config)
        out[state.name] = state
      end
      weights = PolicyScorer::FACTORS.each_with_object({ "count" => 0.0, "volume" => 0.0 }) { |name, out| out[name] = 0.0 }
      weights[factor] = 1.0
      configured = {
        "fallback_provider" => "internal",
        "selection_mode" => "balanced_minimax",
        "traffic_debt_bound" => 4.0,
        "volume_debt_bound" => 4.0,
        "recovery_rate" => 0.75,
        "weights" => weights
      }.merge(profile)
      metric_map = (metrics || { "alpha" => 0.9, "beta" => 0.9 }).transform_values { |value| { "conservative_conversion" => value } }
      operation = evidence_operation(amount: amount, bank: "sberbank")
      eligibility = states.values.map { |state| HardGate.new(fallback_provider: "internal").evaluate(operation, state) }
      controller = DeficitController.new(states, configured)
      controller.accrue!(amount)
      controller.mark_eligibility!(eligibility)
      ranking = controller.rank(states.keys, metric_map, amount)
      {
        "winner" => ranking.first.fetch("provider"),
        "all_eligible" => eligibility.all?(&:eligible),
        "ranking" => ranking.map { |row| { "provider" => row.fetch("provider"), "primary" => row.fetch("primary_regret"), "secondary" => row.fetch("secondary_penalty") } }
      }
    end

    def soft_configs(traffic: [50, 50], load: [10, 10], margin: [1.0, 1.0], priority: [1, 1], turnover: [0, 0])
      %w[alpha beta].each_with_index.map do |name, index|
        {
          "payment_system" => name,
          "status" => "active",
          "traffic_percentage" => traffic[index],
          "priority" => priority[index],
          "limit_amount_min" => nil,
          "limit_amount_max" => nil,
          "daily_amount_limit" => nil,
          "daily_approved_amount" => turnover[index],
          "daily_turnover_min" => 100_000,
          "in_progress_count_limit" => 100,
          "in_progress_count" => load[index],
          "in_progress_amount_limit" => nil,
          "in_progress_amount" => 0,
          "available_requisites" => 100,
          "conversion_24h" => 0.9,
          "avg_latency_sec" => 1,
          "banks" => [],
          "exclude_banks" => false,
          "provider_margin_pct" => margin[index],
          "merchant_margin_pct" => 1.5,
          "allow_negative_agreement" => false
        }
      end
    end

    def policy_challenge(operation_id, prefer, factor)
      proof = planner_result.report.fetch("proof_capsules").fetch(operation_id)
      ranking = proof.fetch("candidate_rankings").first
      selected_plan = ranking.first.fetch("outcome_plan")
      frontier = selected_plan.fetch("evaluated_frontier")
      model = selected_plan.fetch("cascade_model")
      snapshot = proof.fetch("attempt_snapshots").first.fetch("snapshot")
      fallback = snapshot.fetch("policy").fetch("fallback_provider", "spacepayments")
      hard_reason = proof.fetch("hard_evaluations").flatten.find { |row| row.fetch("provider") == prefer && row.fetch("eligible") == false }
      PlanVerifier.verify!(proof, fallback)
      PolicyChallenge.new(frontier: frontier, model: model, weights: snapshot.fetch("policy").fetch("outcome_planner").fetch("weights"))
        .call(prefer: prefer, factor: factor)
        .merge("snapshot_hash" => proof.fetch("attempt_snapshots").first.fetch("snapshot_hash"),
          "snapshot_certificate_verified" => true, "hard_reason" => hard_reason && hard_reason.fetch("reason"),
          "plan_context" => plan_context(selected_plan))
    end

    def plan_context(plan)
      certificate = plan.fetch("dependence_certificate")
      {
        "chain" => plan.fetch("chain"),
        "objective" => plan.fetch("objective"),
        "optimization_method" => plan.dig("optimization", "method"),
        "exact_for_frozen_model" => plan.dig("optimization", "exact_for_frozen_model"),
        "factorial_search_used" => plan.dig("optimization", "factorial_search_used"),
        "dependence_certificate" => {
          "status" => certificate.fetch("status"),
          "success_probability" => certificate.fetch("success_probability"),
          "all_failed_probability" => certificate.fetch("all_failed_probability"),
          "independent_reference" => certificate.fetch("independent_reference"),
          "lower_bound_drivers" => certificate.fetch("lower_bound_drivers"),
          "success_lower_bound_gain_over_fallback" => certificate.dig("fallback", "success_lower_bound_gain_over_fallback"),
          "optimal_order_certified" => certificate.dig("scope", "optimal_order_certified"),
          "changes_routing" => certificate.dig("scope", "changes_routing")
        }
      }
    end

    def item(id, group, title, expected, observed, passed)
      { "id" => id, "group" => group, "title" => title, "expected" => expected, "observed" => observed, "passed" => !!passed }
    end

    def balanced_result
      @balanced_result ||= run_profile("config/balanced.json")
    end

    def planner_result
      @planner_result ||= run_profile("config/planner.json")
    end

    def run_profile(profile, outcome_model: nil)
      Runner.new(
        providers_path: path("data/providers.json"),
        queue_path: path("data/operations_queue_10.json"),
        history_path: path("data/operations_history.csv"),
        profile_path: path(profile),
        outcome_model: outcome_model
      ).run
    end

    def evidence_operation(amount:, bank:)
      {
        "operation_id" => "evidence_operation",
        "amount" => amount,
        "bank" => bank,
        "created_at" => "2026-07-30T09:05:00+03:00"
      }
    end

    def path(relative)
      File.join(@root, relative)
    end

    def deep_copy(value)
      Marshal.load(Marshal.dump(value))
    end
  end
end
