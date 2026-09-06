# frozen_string_literal: true

module PulseProof
  # A post-run relaxation, not a routing signal or a joint allocation solver.
  class CapacityExplanation
    SCOPE = {
      "changes_routing" => false,
      "uses_completed_queue_for_analysis_only" => true,
      "joint_optimum_certified" => false,
      "individual_ceiling_attainability_certified" => false,
      "ceilings_are_individual_relaxations" => true,
      "starting_in_progress_load_relaxed" => true,
      "rpm_and_competition_relaxed" => true,
      "daily_budget_semantics" => "daily_limit_minus_initial_daily_approved; initial_in_progress_is_not_daily_approved",
      "scope" => "unchanged_single_day_snapshot_and_immediate_approved_attempts"
    }.freeze

    def initialize(queue:, decisions:, providers_document:, fallback_provider: "spacepayments", snapshot_unchanged: true)
      @queue = queue
      @decisions = decisions
      @document = providers_document
      @fallback = fallback_provider
      @snapshot_unchanged = snapshot_unchanged
    end

    def build
      return unavailable("provider_snapshot_changed") unless @snapshot_unchanged
      return unavailable("empty_queue", status: "empty") if @queue.empty?
      return unavailable("queue_and_decisions_do_not_match") unless complete_coverage?
      return unavailable("pending_or_failed_attempts_present") unless immediate_approvals?
      return unavailable("missing_or_invalid_snapshot_time") unless snapshot_time
      return unavailable("multiple_snapshot_days") unless same_day?

      rows = @document.fetch("providers").each_with_object({}) do |config, out|
        row = provider_row(config)
        return unavailable("observed_assignment_outside_relaxation") unless row
        out[config.fetch("payment_system")] = row
      end
      {
        "status" => "explained", "scope" => SCOPE.dup, "queue_operations" => @queue.length,
        "interpretation" => "Это отдельные верхние границы для каждого провайдера, а не совместно достижимый план и не доказательство минимального суммарного отклонения долей. Анализ завершённой очереди не участвует в выборе маршрутов.",
        "providers" => rows
      }
    end

    private

    def unavailable(reason, status: "not_applicable")
      { "status" => status, "reason" => reason, "scope" => SCOPE.dup, "providers" => {} }
    end

    def complete_coverage?
      ids = @queue.map { |operation| operation["operation_id"] }
      selected_ids = @decisions.map { |decision| decision["operation_id"] }
      names = @document.fetch("providers").map { |provider| provider.fetch("payment_system") }
      ids.uniq.length == ids.length && selected_ids.uniq.length == selected_ids.length &&
        ids.sort == selected_ids.sort && @decisions.all? { |decision| names.include?(decision["selected_provider"]) }
    end

    def immediate_approvals?
      @decisions.all? do |decision|
        attempts = decision.fetch("attempts", [])
        selected = attempts.select { |attempt| attempt["decision"] == "selected" }
        decision["simulated_result"] == "approved" && selected.length == 1 &&
          selected.first["provider"] == decision["selected_provider"] && selected.first["result"] == "approved" &&
          attempts.all? { |attempt| attempt["result"].nil? || attempt["result"] == "approved" } &&
          attempts.all? { |attempt| %w[selected skipped].include?(attempt["decision"]) }
      end
    end

    def same_day?
      snapshot = snapshot_time
      day = snapshot.strftime("%Y-%m-%d")
      @queue.all? do |operation|
        Time.iso8601(operation.fetch("created_at")).getlocal(snapshot.utc_offset).strftime("%Y-%m-%d") == day
      end
    end

    def snapshot_time
      value = @document["snapshot_at"]
      return nil unless value.is_a?(String)
      Time.iso8601(value)
    rescue ArgumentError, TypeError
      nil
    end

    def provider_row(config)
      name = config.fetch("payment_system")
      # Dropping constraints only enlarges the candidate set. In particular,
      # temporary initial load must not become a permanent eligibility ceiling.
      relaxed = Marshal.load(Marshal.dump(config))
      relaxed["daily_amount_limit"] = nil
      relaxed["in_progress_count"] = 0
      relaxed["in_progress_amount"] = 0
      relaxed["requests_per_minute_limit"] = nil
      provider = ProviderState.new(relaxed)
      gate = HardGate.new(fallback_provider: @fallback)
      eligible = @queue.select do |operation|
        gate.evaluate(operation, provider, fallback: name == @fallback).eligible
      end
      sorted_cents = eligible.map { |operation| Money.cents(operation.fetch("amount")) }.sort
      budget = config["daily_amount_limit"].nil? ? nil :
        [Money.cents(config["daily_amount_limit"]) - Money.cents(config["daily_approved_amount"]), 0].max
      prefix = 0
      count = 0
      sorted_cents.each do |amount|
        break if budget && prefix + amount > budget
        prefix += amount
        count += 1
      end
      next_prefix = count < sorted_cents.length ? prefix + sorted_cents[count] : nil
      selected_ids = @decisions.select { |decision| decision["selected_provider"] == name }.map { |decision| decision["operation_id"] }
      selected_operations = @queue.select { |operation| selected_ids.include?(operation["operation_id"]) }
      eligible_ids = eligible.map { |operation| operation["operation_id"] }
      allocated = selected_operations.inject(0) { |sum, operation| sum + Money.cents(operation.fetch("amount")) }
      return nil unless (selected_ids - eligible_ids).empty? && selected_ids.length <= count && (!budget || allocated <= budget)

      target = config.fetch("traffic_percentage", 0).to_f * @queue.length / 100.0
      {
        "target_operation_count" => target,
        "relaxed_eligible_operations" => eligible.length,
        "individual_count_upper_bound" => count,
        "individual_share_upper_bound_pct" => percentage(count, @queue.length),
        "target_exceeds_individual_upper_bound" => target > count,
        "final_selected_count" => selected_ids.length,
        "selected_count_to_individual_ceiling_pct" => percentage(selected_ids.length, count),
        "initial_remaining_daily_amount" => budget.nil? ? nil : Money.rubles(budget),
        "allocated_queue_amount" => Money.rubles(allocated),
        "initial_daily_budget_used_pct" => budget.nil? ? nil : percentage(allocated, budget),
        "daily_budget_witness" => {
          "currency_unit" => "kopeck", "initial_remaining_cents" => budget,
          "cheapest_feasible_count" => count, "cheapest_feasible_sum_cents" => prefix,
          "next_count" => next_prefix.nil? ? nil : count + 1,
          "next_cheapest_sum_cents" => next_prefix,
          "next_count_exceeds_daily_budget" => !next_prefix.nil? && !budget.nil? && next_prefix > budget
        },
        "interpretation" => target > count ?
          "Целевая доля превышает отдельную верхнюю границу при исходных правилах и дневном остатке; увеличение веса доли само по себе это ограничение не снимет." :
          "Отдельная верхняя граница не исключает целевую долю; совместная достижимость со всеми остальными провайдерами здесь не доказана."
      }
    end

    def percentage(value, total)
      total.zero? ? nil : (value * 100.0 / total).round(6)
    end
  end
end
