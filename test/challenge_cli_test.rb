# frozen_string_literal: true

require_relative "test_helper"
require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"

class ChallengeCliTest < Minitest::Test
  def self.report_json
    @report_json ||= begin
      root = PulseProofTestData::ROOT
      result = PulseProof::Runner.new(
        providers_path: File.join(root, "data/providers.json"),
        queue_path: File.join(root, "data/operations_queue_10.json"),
        history_path: File.join(root, "data/operations_history.csv"),
        profile_path: File.join(root, "config/planner.json"),
        simulation_mode: "approve"
      ).run
      JSON.generate(result.report).freeze
    end
  end

  def setup
    @directory = Dir.mktmpdir("pulseproof-challenge-cli-")
    @report_path = File.join(@directory, "planner-report.json")
    @output_path = File.join(@directory, "challenge-result.json")
    File.binwrite(@report_path, self.class.report_json)
  end

  def teardown
    FileUtils.remove_entry(@directory) if @directory && File.directory?(@directory)
  end

  def test_default_stdout_is_verified_json_and_does_not_create_outputs
    stdout, stderr, status = invoke
    assert status.success?, stderr
    assert_empty stderr
    result = JSON.parse(stdout)
    assert_equal "verified_counterfactual", result.fetch("status")
    assert_equal true, result.fetch("snapshot_certificate_verified")
    assert_equal "op_101", result.fetch("operation_id")
    assert_equal 1, result.fetch("attempt")
    assert_equal "vipay", result.fetch("verified_chain").first
    assert_operator result.fetch("proposed_weight"), :>, result.fetch("current_weight")
    assert_equal ["planner-report.json"], Dir.children(@directory)
    assert_equal self.class.report_json, File.read(@report_path, encoding: Encoding::UTF_8)
  end

  def test_human_stdout_and_saved_json_describe_the_same_verified_switch
    stdout, stderr, status = invoke
    assert status.success?, stderr
    json_result = JSON.parse(stdout)
    human, warning, human_status = invoke("--human", "--challenge-output", @output_path)
    assert human_status.success?, warning
    assert_empty warning
    assert human.valid_encoding?, "human output must be valid UTF-8"
    assert_includes human, "Операция op_101"
    assert_includes human, "ПЕРЕКЛЮЧЕНИЕ ПРОВЕРЕНО"
    assert_includes human, "Проверенная цепочка: vipay"
    assert_includes human, "Выплата не отправлена"
    assert_raises(JSON::ParserError) { JSON.parse(human) }
    assert File.file?(@output_path)
    saved = JSON.parse(File.read(@output_path, encoding: Encoding::UTF_8))
    assert_equal json_result, saved
    assert_equal true, saved.fetch("snapshot_certificate_verified")
    assert_equal json_result.fetch("proposed_weight"), saved.fetch("proposed_weight")
    assert_equal self.class.report_json, File.read(@report_path, encoding: Encoding::UTF_8)
  end

  def test_invalid_attempts_fail_without_stdout_or_output_file
    %w[0 -1 999].each do |attempt|
      stdout, stderr, status = invoke("--attempt", attempt, "--challenge-output", @output_path)
      refute status.success?, "attempt #{attempt} unexpectedly succeeded"
      assert_equal 1, status.exitstatus
      assert_empty stdout
      assert_match(/PulseProof error: (attempt must be positive|no planner frontier for this attempt)/, stderr)
      refute File.exist?(@output_path)
    end
    assert_equal self.class.report_json, File.read(@report_path, encoding: Encoding::UTF_8)
  end

  def test_one_float_step_tamper_of_local_coefficient_is_rejected_before_writing
    report = JSON.parse(self.class.report_json)
    model = report.fetch("proof_capsules").fetch("op_101").fetch("candidate_rankings").first.first
      .fetch("outcome_plan").fetch("cascade_model")
    metrics = model.fetch("actions").fetch("vipay").fetch("local_metrics")
    original = metrics.fetch("count_potential_change")
    metrics["count_potential_change"] = original.to_f.next_float
    refute_equal original, metrics.fetch("count_potential_change")
    File.binwrite(@report_path, JSON.generate(report))

    stdout, stderr, status = invoke("--challenge-output", @output_path)
    refute status.success?
    assert_equal 1, status.exitstatus
    assert_empty stdout
    assert_includes stderr, "cascade coefficient differs from snapshot"
    refute File.exist?(@output_path)
    refute_includes stdout, "verified_counterfactual"
  end

  private

  def invoke(*extra)
    # JSON and --human are UTF-8 protocols. Pipe/file encodings must not
    # inherit a C/POSIX shell locale; keep the process defaults untouched.
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, File.join(PulseProofTestData::ROOT, "bin/pulseproof"),
      "challenge", "op_101", "--report", @report_path,
      "--prefer", "vipay", "--factor", "count_potential_change", *extra,
      chdir: @directory, binmode: true)
    [stdout.force_encoding(Encoding::UTF_8), stderr.force_encoding(Encoding::UTF_8), status]
  end
end
