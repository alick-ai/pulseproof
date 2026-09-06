# frozen_string_literal: true

require_relative "test_helper"
require "digest"
require "open3"
require "rbconfig"
require "tmpdir"

class PolicyReviewTest < Minitest::Test
  include PulseProofTestData

  def protected_hashes
    %w[bin/pulseproof config/balanced.json routing_decisions_test.json routing_report_test.json].to_h do |path|
      absolute = File.join(ROOT, path)
      [path, File.file?(absolute) ? Digest::SHA256.file(absolute).hexdigest : nil]
    end
  end

  def execute(*arguments)
    Open3.capture3(RbConfig.ruby, File.join(ROOT, "scripts/compare_policies.rb"), *arguments, chdir: ROOT)
  end

  def test_public_comparison_is_isolated_sanitized_and_explicitly_retrospective
    before = protected_hashes
    Dir.mktmpdir("policy-review-test-") do |directory|
      output = File.join(directory, "review.json")
      stdout, stderr, status = execute("--queue", "data/operations_queue_10.json", "--output", output)
      assert status.success?, "#{stdout}\n#{stderr}"
      report = JSON.parse(File.read(output))
      assert_equal "RETROSPECTIVE_COMPARISON_VALIDATED", report.fetch("status")
      assert_equal %w[profile selection_mode], report.fetch("changed_config_keys")
      assert_equal true, report.fetch("retrospective")
      assert_equal true, report.fetch("comparison_selected_after_observing_queue_results")
      assert_equal false, report.fetch("held_out_evaluation")
      assert_equal false, report.fetch("changes_submission_policy")
      assert_equal false, report.fetch("changes_submission_artifacts")
      assert_equal false, report.fetch("external_provider_calls")
      assert_equal "approve", report.fetch("simulation_mode")
      report.fetch("policies").each_value do |policy|
        assert_equal({ "vipay" => 4, "payflow" => 3, "quickpay" => 3, "spacepayments" => 0 }, policy.fetch("distribution").transform_values { |row| row.fetch("count") })
        assert_equal 10, policy.fetch("total_operations")
        assert_equal 10, policy.fetch("simulated_approved_count")
        assert_equal "passed", policy.fetch("strict_validation")
        assert_equal 10.0, policy.fetch("external_l1_pp_unrounded")
        assert_equal 10.0, policy.fetch("all_providers_l1_pp_unrounded")
        assert_equal 10.0, policy.fetch("report_external_l1_pp_sum_of_rounded_rows")
      end
      assert_equal Digest::SHA256.file(File.join(ROOT, "data/operations_queue_10.json")).hexdigest, report.dig("input_sha256", "queue")
      refute_match(/op_10\d|\"payout_requisite\"|\"phone\"/, File.read(output))
      assert_includes report.dig("scope", "tradeoff"), "margin, amount_fit and turnover_min"
    end
    assert_equal before, protected_hashes
  end

  def test_required_artifacts_and_inputs_cannot_be_comparison_outputs
    before = protected_hashes
    %w[routing_decisions_test.json routing_report_test.json config/balanced.json data/providers.json].each do |path|
      stdout, stderr, status = execute("--queue", "data/operations_queue_10.json", "--output", path)
      refute status.success?, stdout
      assert_includes stderr, "comparison output"
    end
    assert_equal before, protected_hashes
  end

  def test_output_through_symlink_to_repository_cannot_replace_submission
    before = protected_hashes
    Dir.mktmpdir("policy-review-symlink-") do |directory|
      link = File.join(directory, "repository")
      File.symlink(ROOT, link)
      stdout, stderr, status = execute("--queue", "data/operations_queue_10.json", "--output", File.join(link, "routing_report_test.json"))
      refute status.success?, stdout
      assert_includes stderr, "comparison output"
    end
    assert_equal before, protected_hashes
  end
end
