# frozen_string_literal: true

require_relative "test_helper"

# Independent exhaustive oracle: it does not call the optimizer's cost method,
# ordering key, evaluator, or any planner helper to decide the expected answer.
class CascadeOptimizerTest < Minitest::Test
  FEATURES = %w[count_potential_change volume_potential_change attempts latency_sec
    pending_ruble_seconds unresolved_or_failed_probability fallback_probability
    scarcity_slots business_factors].freeze

  def test_exact_optimum_matches_exhaustive_search_including_every_forced_first
    random = Random.new(92_417)
    40.times do |index|
      names = Array.new(2 + index % 5) { |i| "provider_#{i}" }.shuffle(random: random)
      fallback = index.even? ? "internal" : nil
      model = random_model(names, fallback, random)
      weights = FEATURES.each_with_object({}) do |feature, out|
        out[feature] = index % 11 == 0 ? 0.0 : [0.0, 0.1, 0.75, 1.0, 2.0].sample(random: random)
      end
      optimizer = PulseProof::CascadeOptimizer.new(model)
      oracle = exhaustive_options(model, weights)
      expected_cost, expected_chain = oracle.min
      actual = optimizer.best_chain(weights)
      assert_equal expected_chain, actual, "unconstrained case #{index}"
      assert_equal expected_cost, oracle_cost(model, actual, weights)
      assert_equal expected_cost, optimizer.exact_cost(actual, weights)

      names.each do |first|
        forced_cost, forced_chain = oracle.select { |_cost, chain| chain.first == first }.min
        chosen = optimizer.best_chain(weights, first: first)
        assert_equal forced_chain, chosen, "case #{index}, forced first #{first}"
        assert_equal forced_cost, oracle_cost(model, chosen, weights)
      end

      evaluation = optimizer.evaluate(actual, weights)
      assert_equal actual, evaluation.fetch("chain")
      assert_in_delta expected_cost.to_f, evaluation.fetch("objective"), 1e-7
      expected_raw = oracle_metrics(model, actual)
      expected_raw.each do |feature, expected|
        assert_in_delta expected.to_f, evaluation.fetch("raw_metrics").fetch(feature, 0.0), 1e-7
      end
    end
  end

  def test_neutral_actions_and_unreachable_suffixes_have_canonical_ties
    fixtures = [
      { "a" => [1.0, 0.0], "b" => [0.5, -2.0], "c" => [0.5, 1.0] },
      { "a" => [0.5, 1.0], "b" => [0.5, -2.0], "c" => [1.0, 0.0] },
      { "a" => [0.5, 4.0], "b" => [0.0, -1.0], "c" => [0.5, 1.0], "d" => [1.0, 0.0] },
      { "a" => [1.0, -1.0], "b" => [1.0, 0.0], "c" => [0.0, 0.0], "d" => [1.0, 1.0] }
    ]
    fixtures.each do |fixture|
      model = simple_model(fixture)
      weights = { "count_potential_change" => 1.0 }
      expected = exhaustive_options(model, weights).min.last
      fixture.keys.permutation.each do |input_order|
        shuffled = model.merge("external_providers" => input_order)
        assert_equal expected, PulseProof::CascadeOptimizer.new(shuffled).best_chain(weights)
      end
    end
  end

  def test_zero_weights_choose_lexical_order_but_never_move_forced_fallback
    model = simple_model("zeta" => [0.0, -5.0], "alpha" => [1.0, 8.0], "middle" => [0.5, 3.0])
    model["fallback_provider"] = "aaa_internal"
    model["actions"]["aaa_internal"] = action(0.0, { "count_potential_change" => -100.0 })
    optimizer = PulseProof::CascadeOptimizer.new(model)
    assert_equal %w[alpha middle zeta aaa_internal], optimizer.best_chain({})
    assert_equal %w[zeta alpha middle aaa_internal], optimizer.best_chain({}, first: "zeta")
  end

  def test_terminal_tail_is_included_without_a_fallback
    model = simple_model("a" => [0.7, 0.25], "b" => [0.9, -0.5])
    model["terminal_metrics"] = { "unresolved_or_failed_probability" => 1.0 }
    weights = { "count_potential_change" => 0.6, "unresolved_or_failed_probability" => 4.0 }
    optimizer = PulseProof::CascadeOptimizer.new(model)
    chain = optimizer.best_chain(weights)
    assert_equal exhaustive_options(model, weights).min.last, chain
    assert_equal oracle_cost(model, chain, weights), optimizer.exact_cost(chain, weights)
    assert_in_delta 0.63, optimizer.evaluate(chain, weights).fetch("raw_metrics").fetch("unresolved_or_failed_probability"), 1e-8
  end

  def test_large_provider_set_uses_exact_ordering_without_factorial_enumeration
    # Sixty-four actions make exhaustive search infeasible without relying on a
    # machine-dependent wall-clock assertion. Each has the same stopping rate,
    # so the strictly increasing local costs give an independently known order.
    names = Array.new(64) { |i| format("provider_%03d", i) }
    actions = names.each_with_index.each_with_object({}) do |(name, i), out|
      out[name] = action(0.5, { "count_potential_change" => i - 32.0 })
    end
    model = { "external_providers" => names.reverse, "fallback_provider" => "internal",
      "actions" => actions.merge("internal" => action(0.0, { "attempts" => 1.0 })),
      "terminal_metrics" => { "unresolved_or_failed_probability" => 1.0 } }
    optimizer = PulseProof::CascadeOptimizer.new(model)
    weights = { "count_potential_change" => 1.0 }
    assert_equal names + ["internal"], optimizer.best_chain(weights)
    assert_equal [names.last] + names[0...-1] + ["internal"], optimizer.best_chain(weights, first: names.last)
  end

  private

  def action(continuation, local)
    { "continue_probability" => continuation, "approval_given_terminal" => 1.0 - continuation,
      "pending_probability" => 0.0, "latency_sec" => local.fetch("latency_sec", 0.0), "local_metrics" => local }
  end

  def simple_model(values)
    { "external_providers" => values.keys.reverse, "fallback_provider" => nil,
      "actions" => values.each_with_object({}) { |(name, (continuation, cost)), out| out[name] = action(continuation, { "count_potential_change" => cost }) },
      "terminal_metrics" => { "unresolved_or_failed_probability" => 1.0 } }
  end

  def random_model(names, fallback, random)
    all_names = names + (fallback ? [fallback] : [])
    actions = all_names.each_with_object({}) do |name, out|
      accepted = [0.0, 0.13, 0.5, 0.93, 1.0].sample(random: random)
      pending = [0.0, 0.0, 0.125, 1.0].sample(random: random)
      continuation = (1.0 - pending) * (1.0 - accepted)
      seconds = [0.1, 1.0, 5.0].sample(random: random)
      local = {
        "count_potential_change" => (1.0 - continuation) * [-3.0, -0.5, 0.0, 0.25, 2.0].sample(random: random),
        "volume_potential_change" => (1.0 - continuation) * [-2.0, -0.25, 0.0, 0.75, 4.0].sample(random: random),
        "attempts" => 1.0, "latency_sec" => seconds,
        "pending_ruble_seconds" => pending * 2000.0,
        "unresolved_or_failed_probability" => pending,
        "fallback_probability" => name == fallback ? 1.0 : 0.0,
        "scarcity_slots" => random.rand(3).to_f, "business_factors" => random.rand(4) / 4.0
      }
      out[name] = { "continue_probability" => continuation, "approval_given_terminal" => accepted,
        "pending_probability" => pending, "latency_sec" => seconds, "local_metrics" => local }
    end
    { "external_providers" => names, "fallback_provider" => fallback,
      "actions" => actions, "terminal_metrics" => { "unresolved_or_failed_probability" => 1.0 } }
  end

  def exhaustive_options(model, weights)
    local_costs = model.fetch("actions").transform_values do |item|
      item.fetch("local_metrics").sum { |feature, value| value.to_r * weights.fetch(feature, 0).to_r }
    end
    terminal_cost = model.fetch("terminal_metrics").sum { |feature, value| value.to_r * weights.fetch(feature, 0).to_r }
    fallback = model["fallback_provider"]
    model.fetch("external_providers").permutation.map do |order|
      chain = order + (fallback ? [fallback] : [])
      reach = Rational(1)
      cost = Rational(0)
      chain.each do |name|
        cost += reach * local_costs.fetch(name)
        reach *= model.fetch("actions").fetch(name).fetch("continue_probability").to_r
      end
      [cost + reach * terminal_cost, chain]
    end
  end

  def oracle_metrics(model, chain)
    reach = Rational(1)
    totals = Hash.new { |h, k| h[k] = Rational(0) }
    chain.each do |name|
      item = model.fetch("actions").fetch(name)
      item.fetch("local_metrics").each { |feature, value| totals[feature] += reach * value.to_r }
      reach *= item.fetch("continue_probability").to_r
    end
    model.fetch("terminal_metrics").each { |feature, value| totals[feature] += reach * value.to_r }
    totals
  end

  def oracle_cost(model, chain, weights)
    oracle_metrics(model, chain).sum { |feature, value| value * weights.fetch(feature, 0).to_r }
  end
end
