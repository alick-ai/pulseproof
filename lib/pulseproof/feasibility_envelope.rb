# frozen_string_literal: true

module PulseProof
  # Count-only hindsight bound, never used by routing. Assumes static rules
  # and immediate approvals, not an optimum across all goals and outcomes.
  class FeasibilityEnvelope
    EXACT_LIMIT = 14
    NODE_LIMIT = 100_000

    def initialize(queue, providers_document, fallback_provider: "spacepayments", node_limit: NODE_LIMIT)
      @queue = queue
      @fallback = fallback_provider
      @providers = providers_document.fetch("providers").each_with_object({}) do |config, out|
        out[config.fetch("payment_system")] = ProviderState.new(config)
      end
      @targets = @providers.reject { |name, _| name == @fallback }.transform_values(&:target_count_pct)
      @gate = HardGate.new(fallback_provider: @fallback)
      @node_limit = node_limit
      @nodes = 0
      @best = nil
      @exhausted = false
    end

    def call
      return { "exact" => false, "reason" => "queue larger than #{EXACT_LIMIT}; no exhaustive bound" } if @queue.length > EXACT_LIMIT
      search(0, Hash.new(0), @providers)
      if @exhausted
        return { "exact" => false, "reason" => "search node budget exceeded", "visited_nodes" => @nodes,
                 "best_observed_l1_pp" => @best && @best["minimum_l1_deviation_pp"] }
      end
      (@best || { "exact" => true, "minimum_l1_deviation_pp" => nil, "optimal_distribution" => {} }).merge(
        "visited_nodes" => @nodes, "scope" => "count-only hindsight; static rules; immediate approvals; all HardGate constraints"
      )
    end

    private

    def search(index, counts, providers)
      @nodes += 1
      if @nodes > @node_limit
        @exhausted = true
        return
      end
      if index == @queue.length
        total = [@queue.length, 1].max.to_f
        deviation = @targets.sum { |name, target| (counts.fetch(name, 0) * 100.0 / total - target).abs }
        if @best.nil? || deviation < @best["minimum_l1_deviation_pp"] - 0.000001
          @best = { "exact" => true, "method" => "post-run exhaustive count search; never used by routing",
                    "minimum_l1_deviation_pp" => deviation.round(2), "optimal_distribution" => counts.dup }
        end
        return
      end
      operation = @queue[index]
      eligible = providers.values.reject { |p| p.name == @fallback }.select { |p| @gate.evaluate(operation, p).eligible }
      if eligible.empty?
        fallback = providers.fetch(@fallback)
        eligible = [fallback] if @gate.evaluate(operation, fallback, fallback: true).eligible
      end
      eligible.each do |provider|
        return if @exhausted
        branch = Marshal.load(Marshal.dump(providers))
        chosen = branch.fetch(provider.name)
        chosen.reserve!({ "operation_id" => operation.fetch("operation_id"), "amount" => operation.fetch("amount") })
        chosen.record_request!(Time.iso8601(operation.fetch("created_at")))
        chosen.commit!(operation.fetch("operation_id"))
        next_counts = counts.dup
        next_counts[provider.name] += 1
        search(index + 1, next_counts, branch)
      end
    end
  end
end
