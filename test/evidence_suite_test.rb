# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "rbconfig"
require "tmpdir"

class EvidenceSuiteTest < Minitest::Test
  include PulseProofTestData

  def setup
    @result = PulseProof::EvidenceSuite.new(root: PulseProofTestData::ROOT).call
  end

  def test_all_requirement_evidence_is_executable_and_green
    assert_equal 31, @result.dig("summary", "total")
    assert_equal 31, @result.dig("summary", "passed")
    assert_equal true, @result.dig("summary", "all_passed")
    assert_equal %w[challenge hard runtime soft], @result.dig("summary", "groups").keys.sort
    assert @result.fetch("cases").all? { |item| item.fetch("observed").is_a?(Hash) }
  end

  def test_every_soft_factor_has_a_causal_winner_flip_with_eligible_candidates
    soft = @result.fetch("cases").select { |item| item.fetch("group") == "soft" }

    assert_equal %w[amount_fit conversion count load margin priority turnover_min volume], soft.map { |item| item.dig("observed", "factor") }.sort
    soft.each do |item|
      assert item.fetch("passed"), item.fetch("id")
      assert item.dig("observed", "before", "all_eligible"), item.fetch("id")
      assert item.dig("observed", "after", "all_eligible"), item.fetch("id")
      refute_equal item.dig("observed", "before", "winner"), item.dig("observed", "after", "winner"), item.fetch("id")
    end
  end

  def test_inverse_boundary_and_hard_veto_are_both_visible
    switch = case_by_id("challenge_weight_boundary")
    veto = case_by_id("challenge_hard_veto")

    assert switch.fetch("passed")
    assert_equal 0.6, switch.dig("observed", "current_weight")
    assert_in_delta 0.7985512111061964, switch.dig("observed", "boundary"), 1e-15
    assert_equal "payflow", switch.dig("observed", "original_chain", 0)
    assert_equal "vipay", switch.dig("observed", "verified_chain", 0)
    assert veto.fetch("passed")
    assert_equal "not_eligible", veto.dig("observed", "status")
  end

  def test_serialized_evidence_contains_no_queue_phone
    serialized = JSON.generate(@result)
    queue.each do |operation|
      phone = operation.dig("payout_requisite", "sbp", "phone")
      refute_includes serialized, phone if phone
    end
  end

  def test_cli_exports_the_same_green_matrix_it_prints
    Dir.mktmpdir("pulseproof-evidence-") do |directory|
      output = File.join(directory, "evidence.json")
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, File.join(PulseProofTestData::ROOT, "bin/pulseproof"),
        "evidence", "--human", "--evidence-output", output, chdir: PulseProofTestData::ROOT, binmode: true)
      stdout = stdout.dup.force_encoding(Encoding::UTF_8)
      stderr = stderr.dup.force_encoding(Encoding::UTF_8)

      assert status.success?, stderr
      assert_includes stdout, "31/31 PASS"
      assert_includes stdout, "alpha → beta"
      assert_equal 31, PulseProof::InputLoader.json(output).dig("summary", "passed")
    end
  end

  private

  def case_by_id(id)
    @result.fetch("cases").find { |item| item.fetch("id") == id } || flunk("missing evidence #{id}")
  end
end
