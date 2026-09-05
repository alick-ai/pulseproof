# frozen_string_literal: true

require_relative 'test_helper'
require_relative '../lib/pulseproof/challenge_presenter'

class ChallengePresenterTest < Minitest::Test
  def verified_result
    { 'operation_id' => 'op_101', 'attempt' => 1, 'provider' => 'vipay',
      'status' => 'verified_counterfactual', 'factor' => 'count_potential_change', 'method' => 'exact_parametric_pair_exchange',
      'current_weight' => 0.6, 'proposed_weight' => 0.7985512111061965,
      'original_chain' => %w[payflow vipay quickpay spacepayments],
      'verified_chain' => %w[vipay payflow quickpay spacepayments],
      'winning_interval' => { 'lower' => 0.7985512111061964, 'upper' => nil,
        'lower_closed' => false, 'upper_closed' => false,
        'lower_exact' => '327629177053936238978961247420313008738662545983/410279481763087596553634316845801565678236336128', 'upper_exact' => nil },
      'adjacent_weight_toward_current' => { 'weight' => 0.7985512111061964,
        'chain' => %w[payflow vipay quickpay spacepayments] },
      'recalculated_candidates' => [{ 'cost_after_exact' => '1234567890987654321/99999999999999' }] }
  end

  def present(result)
    PulseProof::ChallengePresenter.new(result: result).call
  end

  def test_verified_switch_keeps_full_precision_and_adjacent_boundary_evidence
    result = verified_result
    before = Marshal.dump(result)
    text = present(result)
    assert_includes text, 'Операция op_101 · попытка 1'
    assert_includes text, '0.6 → 0.7985512111061965'
    assert_includes text, '(0.7985512111061964; +∞)'
    assert_includes text, 'Проверенная цепочка: vipay → payflow → quickpay → spacepayments'
    assert_includes text, 'Соседний машинный вес к исходному: 0.7985512111061964 → payflow'
    assert_includes text, 'правила не изменены'
    refute_includes text, result['winning_interval']['lower_exact']
    refute_includes text, result['recalculated_candidates'].first['cost_after_exact']
    assert_equal before, Marshal.dump(result)
  end

  def test_hard_boundary_does_not_invent_the_exclusion_reason
    text = present('operation_id' => 'op_103', 'attempt' => 2, 'provider' => 'vipay', 'status' => 'not_eligible')
    assert_includes text, 'попытка 2'
    assert_includes text, 'НЕ ДОПУЩЕН'
    assert_includes text, 'исчерпанный маршрут'
    refute_includes text, '100000'
    refute_includes text, 'максимальная сумма'
    refute_includes text, 'ПЕРЕКЛЮЧЕНИЕ ПРОВЕРЕНО'
  end

  def test_already_selected_is_not_a_new_switch
    result = verified_result.merge('status' => 'already_selected')
    text = present(result)
    assert_includes text, 'УЖЕ ВЫБРАН'
    assert_includes text, 'count_potential_change: 0.6'
    refute_includes text, 'ПЕРЕКЛЮЧЕНИЕ ПРОВЕРЕНО'
    refute_includes text, '0.7985512111061965'
  end

  def test_no_single_weight_solution_explains_only_one_factor_scope
    text = present(verified_result.merge('status' => 'no_single_weight_solution'))
    assert_includes text, 'ОДНОГО ВЕСА НЕДОСТАТОЧНО'
    assert_includes text, 'Нет неотрицательного значения count_potential_change'
    refute_includes text, 'ПЕРЕКЛЮЧЕНИЕ ПРОВЕРЕНО'
  end

  def test_no_representable_weight_preserves_closed_singleton_region
    result = verified_result.merge('status' => 'no_representable_weight',
      'winning_regions' => [{ 'lower' => 0.1, 'upper' => 0.1, 'lower_closed' => true, 'upper_closed' => true }])
    text = present(result)
    assert_includes text, 'МАШИННОГО ВЕСА НЕТ'
    assert_includes text, '[0.1; 0.1]'
    assert_includes text, 'Переключение не подтверждено'
    refute_includes text, 'ПЕРЕКЛЮЧЕНИЕ ПРОВЕРЕНО'
  end

  def test_finite_out_of_float_range_boundary_is_not_printed_as_infinity
    result = verified_result.merge('winning_interval' => {
      'lower' => 1.0, 'upper' => nil, 'lower_closed' => true, 'upper_closed' => true,
      'upper_exact' => '9' * 400 })
    text = present(result)
    assert_includes text, '[1.0; вне диапазона Float]'
    refute_includes text, '+∞'
    refute_includes text, '9' * 400
  end

  def test_legacy_inclusive_interval_is_supported_without_claiming_an_exact_certificate
    result = verified_result.merge('method' => nil, 'winning_interval' => { 'lower_inclusive' => 0.8, 'upper_inclusive' => 1.2 })
    text = present(result)
    assert_includes text, '[0.8; 1.2]'
    assert_includes text, 'область вывода ограничена рассмотренными цепочками'
    refute_includes text, 'продолжение пересчитано при новом весе'
  end

  def test_unknown_status_does_not_claim_success_and_control_characters_are_sanitized
    text = present('status' => 'new_status', 'operation_id' => "op\nspoof\e", 'provider' => 'vipay')
    assert_includes text, 'Статус: new_status'
    assert_includes text, 'попытка не указана'
    assert_includes text, 'Операция op spoof '
    refute_includes text, "\e"
    refute_includes text, 'ПЕРЕКЛЮЧЕНИЕ ПРОВЕРЕНО'
  end
end
