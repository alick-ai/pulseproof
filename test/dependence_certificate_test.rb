# frozen_string_literal: true

require_relative "test_helper"

class DependenceCertificateTest < Minitest::Test
  def model(rates, fallback: nil, pending: {})
    { "external_providers" => rates.keys - [fallback], "fallback_provider" => fallback,
      "actions" => rates.transform_values { |p| { "approval_given_terminal" => p } },
      "terminal_metrics" => { "unresolved_or_failed_probability" => 1.0 } }.tap do |result|
      rates.each do |name, p|
        t = pending.fetch(name, 0.0)
        result["actions"][name].merge!("pending_probability" => t,
          "continue_probability" => (1.0 - t) * (1.0 - p), "latency_sec" => 1.0,
          "local_metrics" => { "attempts" => 1.0, "unresolved_or_failed_probability" => t })
      end
    end
  end

  def certificate(rates, fallback: nil, pending: {})
    frozen = model(rates, fallback: fallback, pending: pending)
    result = PulseProof::DependenceCertificate.build(model: frozen, chain: rates.keys)
    assert PulseProof::DependenceVerifier.verify!(result, inputs: frozen["actions"], chain: rates.keys, fallback: fallback)
    result
  end

  def test_two_provider_example_and_exact_scope
    result = certificate("A" => 0.9, "B" => 0.8)
    assert_equal({ "lower" => 0.9, "upper" => 1.0 }, result["success_probability"])
    assert_in_delta 0.1, result["all_failed_probability"]["upper"], 1e-15
    assert_equal 0.0, result["all_failed_probability"]["lower"]
    assert_in_delta 0.98, result["independent_reference"]["success"], 1e-15
    assert_equal ["A"], result["lower_bound_drivers"]
    refute result["scope"]["optimal_order_certified"]
    refute result["scope"]["objective_bounds_certified"]
    refute result["scope"]["changes_routing"]
    assert_equal "supplied_estimates_not_confidence_bounds", result["scope"]["marginals"]
  end

  def test_public_snapshot_fallback_anchors_lower_bound_not_a_real_world_guarantee
    rates = { "vipay" => 0.80843443, "payflow" => 0.86811188, "quickpay" => 0.74864593, "spacepayments" => 0.9 }
    result = certificate(rates, fallback: "spacepayments")
    assert_in_delta 0.0006350516601357676, result["independent_reference"]["all_failed"], 1e-15
    assert_equal ["spacepayments"], result["lower_bound_drivers"]
    assert result["fallback"]["determines_success_lower_bound"]
    assert_equal 0.0, result["fallback"]["success_lower_bound_gain_over_fallback"]
  end

  def test_fallback_is_not_automatically_the_best_marginal
    result = certificate({ "A" => 0.95, "S" => 0.8 }, fallback: "S")
    refute result["fallback"]["determines_success_lower_bound"]
    assert_in_delta 0.15, result["fallback"]["success_lower_bound_gain_over_fallback"], 1e-15
    assert_equal ["A"], result["lower_bound_drivers"]
  end

  def test_tied_drivers_and_absent_fallback
    result = certificate("B" => 0.5, "A" => 0.5)
    assert_equal %w[A B], result["lower_bound_drivers"]
    refute result["fallback"]["included"]
    assert_nil result["fallback"]["success_probability"]
    assert_nil result["fallback"]["success_lower_bound_gain_over_fallback"]
  end

  def test_single_fallback_and_zero_one_endpoints
    [0.0, 0.3, 1.0].each do |p|
      result = certificate({ "S" => p }, fallback: "S")
      assert_equal({ "lower" => p, "upper" => p }, result["success_probability"])
      assert_equal p, result["independent_reference"]["success"]
      assert_equal 0.0, result["fallback"]["success_lower_bound_gain_over_fallback"]
    end
    assert_equal({ "lower" => 0.0, "upper" => 0.0 }, certificate("A" => 0.0, "B" => 0.0)["success_probability"])
    assert_equal({ "lower" => 1.0, "upper" => 1.0 }, certificate("A" => 1.0, "B" => 0.0)["success_probability"])
  end

  def test_exact_fraction_endpoints_are_preserved_beyond_float_display_precision
    rates = { "A" => 0.1, "B" => 0.2 }
    result = certificate(rates)
    upper = rates.values.sum(&:to_r)
    assert_equal upper, Rational(result["exact_bounds"]["success"]["upper"])
    assert_equal 1 - upper, Rational(result["exact_bounds"]["all_failed"]["lower"])
    refute_equal upper, result["success_probability"]["upper"].to_r
  end

  def test_empty_chain_is_explicitly_outside_scope
    result = certificate({})
    assert_equal "not_applicable", result["status"]
    assert_equal "empty_chain", result["reason"]
    refute result.key?("success_probability")
  end

  def test_any_pending_including_unreachable_or_fallback_disables_union_claim
    ["A", "B", "S"].each do |name|
      [Float::MIN, 0.1, 1.0].each do |t|
        result = certificate({ "A" => 1.0, "B" => 0.9, "S" => 0.8 }, fallback: "S", pending: { name => t })
        assert_equal "not_applicable", result["status"]
        assert_equal "pending_blocks_later_attempts", result["reason"]
        assert_equal [name], result["pending_providers"]
        refute result.key?("success_probability")
        refute result.key?("independent_reference")
      end
    end
  end

  def test_invalid_probabilities_and_malformed_chains_are_rejected
    [-0.01, 1.01, Float::INFINITY, Float::NAN, "0.9", nil, true].each do |value|
      %w[approval_given_terminal pending_probability].each do |field|
        frozen = model("A" => 0.8)
        frozen["actions"]["A"][field] = value
        assert_raises(PulseProof::InvariantError) { PulseProof::DependenceCertificate.build(model: frozen, chain: ["A"]) }
      end
    end
    frozen = model({ "A" => 0.8, "B" => 0.9, "S" => 0.7 }, fallback: "S")
    [%w[A S], %w[A B B S], %w[S A B], %w[A B X S]].each do |chain|
      assert_raises(PulseProof::InvariantError) { PulseProof::DependenceCertificate.build(model: frozen, chain: chain) }
    end
  end

  def test_build_is_non_mutating_deterministic_and_json_roundtrips
    frozen = model({ "A" => 0.8, "B" => 0.7, "S" => 0.9 }, fallback: "S")
    before = Marshal.dump(frozen)
    first = PulseProof::DependenceCertificate.build(model: frozen, chain: %w[A B S])
    assert_equal first, PulseProof::DependenceCertificate.build(model: frozen, chain: %w[A B S])
    assert_equal before, Marshal.dump(frozen)
    assert PulseProof::DependenceVerifier.verify!(JSON.parse(JSON.generate(first)), inputs: frozen["actions"], chain: %w[A B S], fallback: "S")
  end

  def test_endpoints_are_attained_by_joint_outcomes_with_unchanged_marginals
    # Independent finite sample-space oracle: nested sets realize max(p),
    # consecutive success sets around a circle realize min(1, sum(p)).
    [[2, 3], [8, 7, 9], [0, 0, 0], [10, 2, 3], [1, 2, 3, 1]].each do |counts|
      rates = counts.each_with_index.each_with_object({}) { |(n, i), out| out[i.to_s] = n / 10.0 }
      result = certificate(rates)
      nested = counts.map { |n| (0...n).to_a }
      offset = 0
      cyclic = counts.map do |n|
        cells = (offset...(offset + n)).map { |cell| cell % 10 }
        offset += n
        cells
      end
      [nested, cyclic].each do |sets|
        assert_equal counts, sets.map(&:length)
        sets.each_with_index { |cells, i| assert_in_delta rates[i.to_s], cells.uniq.length / 10.0, 1e-15 }
      end
      assert_in_delta result["success_probability"]["lower"], nested.flatten.uniq.length / 10.0, 1e-15
      assert_in_delta result["success_probability"]["upper"], cyclic.flatten.uniq.length / 10.0, 1e-15
    end
  end

  def test_bounds_contain_arbitrary_enumerated_joint_distributions
    random = Random.new(19_827)
    40.times do
      masses = Array.new(16) { random.rand(1..20) }
      total = masses.sum.to_f
      rates = (0...4).each_with_object({}) do |bit, out|
        out[bit.to_s] = masses.each_with_index.sum { |mass, atom| atom[bit] == 1 ? mass : 0 } / total
      end
      result = certificate(rates)
      success = 1 - masses.first / total
      assert_operator success + 1e-14, :>=, result["success_probability"]["lower"]
      assert_operator success - 1e-14, :<=, result["success_probability"]["upper"]
      assert_operator result["independent_reference"]["success"] + 1e-14, :>=, result["success_probability"]["lower"]
      assert_operator result["independent_reference"]["success"] - 1e-14, :<=, result["success_probability"]["upper"]
    end
  end

  def test_same_marginals_reverse_attempt_optimum_under_dependence
    rates = { "A" => 0.8, "B" => 0.75, "C" => 0.75, "S" => 0.9 }
    frozen = model(rates, fallback: "S")
    optimizer = PulseProof::CascadeOptimizer.new(frozen)
    a, b = %w[A B C S], %w[B C A S]
    assert_equal a, optimizer.best_chain("attempts" => 1.0)
    assert_in_delta 1.2625, optimizer.evaluate(a, "attempts" => 1.0)["objective"], 1e-12
    assert_in_delta 1.325, optimizer.evaluate(b, "attempts" => 1.0)["objective"], 1e-12
    atoms = [[0.10, %w[A B]], [0.10, %w[A C]], [0.15, ["B"]], [0.15, ["C"]], [0.50, []]]
    %w[A B C].each do |name|
      assert_in_delta 1 - rates[name], atoms.sum { |mass, failures| failures.include?(name) ? mass : 0 }, 1e-15
    end
    expected_attempts = lambda do |chain|
      atoms.sum { |mass, failures| mass * (chain.index { |name| !failures.include?(name) } + 1) }
    end
    assert_in_delta 1.30, expected_attempts.call(a), 1e-15
    assert_in_delta 1.25, expected_attempts.call(b), 1e-15
    ca = PulseProof::DependenceCertificate.build(model: frozen, chain: a)
    cb = PulseProof::DependenceCertificate.build(model: frozen, chain: b)
    assert_equal ca["success_probability"], cb["success_probability"]
    refute ca["scope"]["optimal_order_certified"]
  end

  def test_only_full_failure_term_is_order_neutral_under_no_pending_same_composition
    rates = { "A" => 0.8, "B" => 0.6, "S" => 0.9 }
    plain = PulseProof::CascadeOptimizer.new(model(rates, fallback: "S"))
    orders = [%w[A B S], %w[B A S]]
    failed = orders.map { |chain| plain.evaluate(chain, {})["raw_metrics"]["unresolved_or_failed_probability"] }
    assert_equal failed.first, failed.last
    pending = PulseProof::CascadeOptimizer.new(model(rates, fallback: "S", pending: { "A" => 0.2 }))
    failed = orders.map { |chain| pending.evaluate(chain, {})["raw_metrics"]["unresolved_or_failed_probability"] }
    refute_equal failed.first, failed.last
    refute_equal plain.evaluate(%w[A B S], {})["all_failed_probability"], plain.evaluate(%w[A S], {})["all_failed_probability"]
  end
end
