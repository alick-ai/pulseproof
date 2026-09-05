# frozen_string_literal: true

module PulseProof
  # Reproducible adversarial experiment, isolated from the submission profile.
  # Searches a declared small family of synthetic queues and altered capacity
  # snapshots. Never changes the source providers or learns from a test suffix.
  class CapacityLab
    def initialize(providers_document:, history:, baseline_profile:)
      @document = providers_document
      @history = history
      @base = baseline_profile.merge("capacity_guard" => { "enabled" => false })
      @guarded = @base.merge("profile" => "capacity_lab_guarded", "capacity_guard" => {
        "enabled" => true, "min_samples" => 20, "max_samples" => 1000,
        "max_primary_regret_delta" => 0.25, "max_conversion_drop" => 0.02
      })
      @fallback = @base.fetch("fallback_provider", "spacepayments")
      @at = Time.iso8601(@document.fetch("snapshot_at"))
    end

    def call
      gate = HardGate.new(fallback_provider: @fallback)
      states = @document.fetch("providers").map { |config| ProviderState.new(config) }
      model = CapacityGuard.new(history: @history, config: @guarded["capacity_guard"], fallback_provider: @fallback, as_of: @document["snapshot_at"])
      shapes = model.model_at(@at).fetch("cohorts").map do |cohort|
        probe = cohort.merge("created_at" => @at.iso8601)
        names = states.reject { |p| p.name == @fallback }.select { |p| gate.evaluate(probe, p).eligible }.map(&:name)
        cohort.merge("eligible" => names)
      end
      exclusive = shapes.select { |row| row["eligible"].length == 1 }.sort_by { |row| [-row["amount"], row["bank"]] }
      tested = 0
      # Bound the work and search the shortest repeated flexible prefix first.
      (1..4).each do |length|
        exclusive.first(8).each do |rare|
          provider = rare["eligible"].first
          config = @document["providers"].find { |p| p["payment_system"] == provider }
          next unless config["daily_amount_limit"] && config["daily_amount_limit"] >= rare["amount"]
          flexible = shapes.select { |row| row["eligible"].length > 1 && row["eligible"].include?(provider) && row["amount"] < rare["amount"] }
          flexible.first(12).each do |common|
            altered = Marshal.load(Marshal.dump(@document))
            changed = altered["providers"].find { |p| p["payment_system"] == provider }
            changed["daily_approved_amount"] = Money.rubles(Money.cents(changed["daily_amount_limit"]) - Money.cents(rare["amount"]))
            prefix = length.times.map { |i| operation(common, i) }
            operations = prefix + [operation(rare, length)]
            before = run(altered, operations, @base)
            after = run(altered, operations, @guarded)
            tested += 1
            next unless fallback_count(before) > fallback_count(after)
            control_before = run(altered, prefix, @base)
            control_after = run(altered, prefix, @guarded)
            return {
              "kind" => "synthetic adversarial capacity experiment, not production or hidden-test uplift",
              "history_used" => model.model_at(@at)["sample_size"],
              "searched_cases" => tested,
              "search_scope" => "prefix lengths 1..4; at most 8 exclusive and 12 shared historical shapes; repeated common requests then one exclusive request",
              "minimality" => "first improvement in length-ordered bounded family, not globally smallest counterexample",
              "capacity_change" => { "provider" => provider, "original_daily_approved" => config["daily_approved_amount"],
                "experiment_daily_approved" => changed["daily_approved_amount"], "remaining_daily_capacity" => rare["amount"] },
              "policy" => @guarded["capacity_guard"],
              "assumptions" => ["all provider outcomes approved", "current and past data only inside each Router",
                "same starting snapshot and hard constraints in each arm", "no real money or inferred financial savings"],
              "exclusive_payment_arrives" => compare(operations, before, after),
              "exclusive_payment_never_arrives" => compare(prefix, control_before, control_after),
              "prefix_independent_of_suffix" => prefix.all? do |op|
                after.decisions.fetch(op["operation_id"]) == control_after.decisions.fetch(op["operation_id"])
              end
            }
          end
        end
      end
      { "kind" => "bounded synthetic experiment", "found" => false, "searched_cases" => tested,
        "conclusion" => "No improvement found in this search family; no superiority claim." }
    end

    private

    def operation(shape, index)
      { "operation_id" => "lab_#{index + 1}", "amount" => shape["amount"], "bank" => shape["bank"],
        "card_brand" => shape["card_brand"], "created_at" => (@at + 300 + index * 120).iso8601 }
    end

    def run(document, operations, policy)
      session = RuntimeSession.new(providers_document: document, profile: policy, history: @history, outcome_model: OutcomeModel.new)
      operations.each { |op| session.process("type" => "operation", "operation" => op) }
      session
    end

    def fallback_count(session)
      session.decisions.values.count { |d| d["selected_provider"] == @fallback }
    end

    def compare(operations, before, after)
      { "baseline" => summarize(before), "guarded" => summarize(after),
        "trace" => operations.map do |op|
          first = before.decisions.fetch(op["operation_id"])
          second = after.decisions.fetch(op["operation_id"])
          selected = second["attempts"].find { |attempt| attempt["decision"] == "selected" }
          { "operation" => op, "baseline_provider" => first["selected_provider"],
            "guarded_provider" => second["selected_provider"], "guarded_reason" => selected["reason"] }
        end }
    end

    def summarize(session)
      report = session.report # independent replay and full validation
      { "fallback_count" => fallback_count(session), "distribution" => report["distribution"],
        "count_l1_pp_external_targets" => report.dig("soft_goal_analysis", "raw_target_deviation_l1_pp"),
        "overrides" => report["capacity_protection"]["overrides"], "validated" => true }
    end
  end
end
