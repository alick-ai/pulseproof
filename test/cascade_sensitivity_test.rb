# frozen_string_literal: true

require_relative "test_helper"

class CascadeSensitivityTest < Minitest::Test
  def test_neutral_action_only_wins_after_an_unrelated_pair_crossing
    model = model_for("a" => [0.5, 1.0, 0.0], "b" => [1.0, 0.0, 0.0], "c" => [0.5, 0.0, 1.0])
    weights = { "x" => 0.0, "y" => 1.0 }
    result = challenge(model, weights, "b")
    assert_equal "verified_counterfactual", result.fetch("status")
    assert_equal [interval(1, nil, false, false)], exact_regions(result)
    assert_operator result.fetch("proposed_weight"), :>, 1.0
    assert_equal %w[b c a], result.fetch("verified_chain")
    verify_proposal(model, weights, result)
  end

  def test_reoptimizes_continuations_instead_of_freezing_original_best_per_first
    model = model_for("a" => [0.75, 3.0, -2.0], "b" => [0.75, -1.0, 4.0], "c" => [0.5, -1.0, 6.0])
    weights = { "x" => 1.0, "y" => 1.0 }
    lines = exhaustive_affine_lines(model, weights, "x")
    initial_best = model.fetch("external_providers").map do |name|
      lines.select { |line| line[:chain].first == name }.min_by { |line| [line[:base] + line[:slope], line[:chain]] }
    end
    # Even exhaustive analysis of this frozen three-chain frontier cannot make
    # b first. Its required continuation was not best at the original weight.
    assert oracle_probes(initial_best).none? { |weight| oracle_winner(initial_best, weight).first == "b" }
    result = challenge(model, weights, "b")
    assert_equal "verified_counterfactual", result.fetch("status")
    assert_equal [interval(2, nil, true, false)], exact_regions(result)
    assert_equal %w[b c a], result.fetch("verified_chain")
    assert_equal %w[b a c], initial_best.find { |line| line[:chain].first == "b" }[:chain]
    verify_proposal(model, weights, result)
  end

  def test_canonical_tie_can_make_a_single_exact_weight_the_entire_region
    model = model_for("a" => [0.5, 0.0, 0.0], "b" => [0.5, 1.0, -1.0], "c" => [0.5, -1.0, 1.0])
    weights = { "x" => 0.0, "y" => 1.0 }
    result = challenge(model, weights, "a")
    assert_equal "verified_counterfactual", result.fetch("status")
    assert_equal [interval(1, 1, true, true)], exact_regions(result)
    assert_equal 1.0, result.fetch("proposed_weight")
    verify_proposal(model, weights, result)
  end

  def test_neutral_provider_has_disconnected_winning_regions
    model = model_for("a" => [0.5, 3.0, 0.0], "b" => [1.0, 0.0, 0.0],
      "c" => [0.5, 2.0, 1.0], "aa" => [0.5, 1.0, 3.0], "d" => [0.5, 0.0, 6.0])
    weights = { "x" => 0.0, "y" => 1.0 }
    result = PulseProof::CascadeSensitivity.new(model: model, weights: weights).call(prefer: "b", factor: "x")
    assert_equal result, challenge(model, weights, "b")
    assert_equal "verified_counterfactual", result.fetch("status")
    assert_equal [interval(1, 2, false, false), interval(3, nil, false, false)], exact_regions(result)
    lines = exhaustive_affine_lines(model, weights, "x")
    oracle_probes(lines).each do |weight|
      assert_equal oracle_winner(lines, weight).first == "b", exact_regions(result).any? { |region| includes?(region, weight) }
    end
    verify_proposal(model, weights, result)
  end

  def test_forced_fallback_and_no_pending_terminal_risk_cannot_change_order
    model = model_for("a" => [0.25, 0.0, 1.0], "b" => [0.5, 0.0, 2.0], "c" => [0.75, 0.0, 3.0])
    model["fallback_provider"] = "internal"
    model["actions"]["internal"] = make_action(0.5, { "x" => 0.0, "y" => 1.0, "fallback_probability" => 1.0 })
    model["actions"].each_value { |row| row["local_metrics"]["unresolved_or_failed_probability"] = 0.0 }
    weights = { "x" => 0.0, "y" => 1.0, "fallback_probability" => 1.0, "unresolved_or_failed_probability" => 1.0 }
    %w[fallback_probability unresolved_or_failed_probability].each do |factor|
      result = PulseProof::PolicyChallenge.new(model: model, weights: weights).call(prefer: "b", factor: factor)
      assert_equal "no_single_weight_solution", result.fetch("status")
      assert_equal [], result.fetch("winning_regions")
      lines = exhaustive_affine_lines(model, weights, factor)
      assert_equal 1, lines.map { |line| line[:slope] }.uniq.length
      assert_equal "internal", oracle_winner(lines, 0).last
    end
  end

  def test_exact_region_can_exist_without_any_representable_float_inside
    # 1/3 < x <= (1 + 2^-55)/3: both endpoints round to the same Float,
    # which lies BELOW this region. All input coefficients are finite Floats.
    model = model_for("a" => [0.5, 3.0, -1.0], "b" => [0.5, 0.0, 0.0], "c" => [0.5, -3.0, 1.0])
    model["actions"]["c"]["local_metrics"]["epsilon"] = 2.0**-55
    weights = { "x" => 0.0, "y" => 1.0, "epsilon" => 1.0 }
    result = challenge(model, weights, "b")
    lower = Rational(1, 3)
    upper = (1 + Rational(1, 2**55)) / 3
    assert_equal "no_representable_weight", result.fetch("status")
    assert_equal [interval(lower, upper, false, true)], exact_regions(result)
    assert_equal "b", oracle_winner(exhaustive_affine_lines(model, weights, "x"), (lower + upper) / 2).first
    assert_operator lower.to_f.to_r, :<, lower
    assert_operator lower.to_f.next_float.to_r, :>, upper
    refute result.key?("proposed_weight")
  end

  def test_finite_but_out_of_float_range_boundary_is_not_called_no_solution
    model = model_for("a" => [0.5, Float::MIN, -Float::MAX], "b" => [0.5, 0.0, 0.0])
    result = challenge(model, { "x" => 0.0, "y" => 1.0 }, "b")
    assert_equal "no_representable_weight", result.fetch("status")
    lower = Float::MAX.to_r / Float::MIN.to_r
    assert_equal [interval(lower, nil, false, false)], exact_regions(result)
    region = result.fetch("winning_regions").first
    assert_nil region["lower"]
    refute_nil region["lower_exact"]
    assert_nil region["upper_exact"]
  end

  def test_large_representable_boundary_still_gets_a_verified_weight
    model = model_for("a" => [0.5, 1.0, -1e200], "b" => [0.5, 0.0, 0.0])
    weights = { "x" => 0.0, "y" => 1.0 }
    result = challenge(model, weights, "b")
    assert_equal "verified_counterfactual", result.fetch("status")
    assert_operator result.fetch("proposed_weight"), :>, 1e200
    verify_proposal(model, weights, result)
  end

  def test_reports_ineligible_and_rejects_unknown_or_invalid_coefficients
    model = model_for("a" => [0.5, 1.0, 0.0], "b" => [0.5, 0.0, 1.0])
    weights = { "x" => 0.0, "y" => 1.0 }
    assert_equal "not_eligible", challenge(model, weights, "absent").fetch("status")
    assert_equal "already_selected", challenge(model, weights, "a").fetch("status")
    assert_raises(PulseProof::InputError) { PulseProof::PolicyChallenge.new(model: model, weights: weights).call(prefer: "b", factor: "magic") }
    assert_raises(PulseProof::InputError) { challenge(model, weights.merge("x" => -1.0), "b") }
    assert_raises(PulseProof::InputError) { challenge(model, weights.merge("x" => Float::INFINITY), "b") }
  end

  def test_regions_match_independent_exhaustive_affine_oracle_for_seeded_models
    random = Random.new(407_319)
    18.times do |index|
      values = Array.new(2 + index % 3).each_with_index.each_with_object({}) do |(_unused, i), out|
        out["provider_#{i}"] = [[0.0, 0.25, 0.5, 0.75, 1.0].sample(random: random), random.rand(-3..3).to_f, random.rand(-2..6).to_f]
      end
      model = model_for(values)
      model["external_providers"].shuffle!(random: random)
      if index.even?
        model["fallback_provider"] = "internal"
        model["actions"]["internal"] = make_action(0.25, { "x" => 0.5, "y" => 2.0 })
      end
      # Pending affects fixed local costs; the oracle uses only the exported
      # additive coefficients, not any optimizer or sensitivity helper.
      model["actions"].each_value do |row|
        f = row.fetch("continue_probability")
        pending = f <= 0.5 ? [0.0, 0.125].sample(random: random) : 0.0
        row["pending_probability"] = pending
        row["approval_given_terminal"] = 1.0 - f / (1.0 - pending)
        row["local_metrics"]["unresolved_or_failed_probability"] = pending
      end
      weights = { "x" => 1.0, "y" => 1.0, "unresolved_or_failed_probability" => 0.25 }
      lines = exhaustive_affine_lines(model, weights, "x")
      probes = oracle_probes(lines)
      winners = probes.map { |weight| [weight, oracle_winner(lines, weight).first] }

      model.fetch("external_providers").each do |prefer|
        different = winners.find { |_weight, winner| winner != prefer }
        unless different
          assert_equal "already_selected", challenge(model, weights, prefer).fetch("status")
          next
        end
        # Choose a non-winning current coefficient to exercise region output
        # even for the provider that happened to win at the default weight.
        current = weights.merge("x" => different.first)
        result = challenge(model, current, prefer)
        regions = exact_regions(result)
        winners.each do |weight, winner|
          included = regions.any? { |region| includes?(region, weight) }
          assert_equal winner == prefer, included, "case #{index}, #{prefer}, x=#{weight}, regions=#{regions.inspect}"
        end
        if winners.none? { |_weight, winner| winner == prefer }
          assert_equal "no_single_weight_solution", result.fetch("status")
          assert_empty regions
        else
          assert_includes %w[verified_counterfactual no_representable_weight], result.fetch("status")
          verify_proposal(model, current, result) if result["status"] == "verified_counterfactual"
        end
      end
    end
  end

  private

  def challenge(model, weights, prefer)
    PulseProof::PolicyChallenge.new(model: model, weights: weights).call(prefer: prefer, factor: "x")
  end

  def make_action(continuation, local)
    { "continue_probability" => continuation, "approval_given_terminal" => 1.0 - continuation,
      "pending_probability" => 0.0, "latency_sec" => 1.0, "local_metrics" => local }
  end

  def model_for(values)
    { "external_providers" => values.keys.reverse, "fallback_provider" => nil,
      "actions" => values.each_with_object({}) { |(name, (f, slope, base)), out| out[name] = make_action(f, { "x" => slope, "y" => base }) },
      "terminal_metrics" => { "unresolved_or_failed_probability" => 1.0 } }
  end

  def interval(lower, upper, lower_closed, upper_closed)
    { lower: lower.to_r, upper: upper && upper.to_r, lower_closed: lower_closed, upper_closed: upper_closed }
  end

  def exact_regions(result)
    result.fetch("winning_regions").map do |row|
      assert_kind_of String, row.fetch("lower_exact")
      assert_kind_of String, row["upper_exact"] if row["upper_exact"]
      interval(Rational(row.fetch("lower_exact")), row["upper_exact"] && Rational(row["upper_exact"]), row.fetch("lower_closed"), row.fetch("upper_closed"))
    end
  end

  def includes?(region, point)
    (point > region[:lower] || (point == region[:lower] && region[:lower_closed])) &&
      (region[:upper].nil? || point < region[:upper] || (point == region[:upper] && region[:upper_closed]))
  end

  def verify_proposal(model, weights, result)
    proposed = result.fetch("proposed_weight")
    assert_kind_of Float, proposed
    assert proposed.finite?
    assert_operator proposed, :>=, 0.0
    lines = exhaustive_affine_lines(model, weights, result.fetch("factor"))
    expected = oracle_winner(lines, proposed.to_r)
    assert_equal result.fetch("provider"), expected.first
    assert_equal expected, result.fetch("verified_chain")
    assert_equal expected, PulseProof::CascadeOptimizer.new(model).best_chain(weights.merge(result.fetch("factor") => proposed))
    assert exact_regions(result).any? { |region| includes?(region, proposed.to_r) }
  end

  # Enumerate the full legal chain space, integrate every metric with exact
  # reach probabilities, and derive each chain's affine objective ourselves.
  def exhaustive_affine_lines(model, weights, factor)
    fallback = model["fallback_provider"]
    model.fetch("external_providers").permutation.map do |order|
      chain = order + (fallback ? [fallback] : [])
      raw = Hash.new { |h, k| h[k] = Rational(0) }
      reach = Rational(1)
      chain.each do |name|
        row = model.fetch("actions").fetch(name)
        row.fetch("local_metrics").each { |key, value| raw[key] += reach * value.to_r }
        reach *= row.fetch("continue_probability").to_r
      end
      model.fetch("terminal_metrics").each { |key, value| raw[key] += reach * value.to_r }
      base = raw.sum { |key, value| key == factor ? 0 : value * weights.fetch(key, 0).to_r }
      { chain: chain, base: base, slope: raw.fetch(factor, 0) }
    end
  end

  # Unlike the implementation's action-pair crossings, this oracle partitions
  # using intersections of ALL full-chain objective lines, including lines
  # that never win. It checks every boundary and every intervening open cell.
  def oracle_probes(lines)
    roots = [Rational(0)]
    lines.combination(2) do |a, b|
      difference = a[:slope] - b[:slope]
      next if difference.zero?
      root = (b[:base] - a[:base]) / difference
      roots << root if root >= 0
    end
    roots = roots.uniq.sort
    roots.each_with_index.flat_map do |low, index|
      high = roots[index + 1]
      [low, high ? (low + high) / 2 : low + 1]
    end
  end

  def oracle_winner(lines, weight)
    lines.min_by { |line| [line[:base] + line[:slope] * weight.to_r, line[:chain]] }[:chain]
  end
end
