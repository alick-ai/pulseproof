# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "rbconfig"
require "tmpdir"

class DependenceExplainTest < Minitest::Test
  include PulseProofTestData

  def session(pending: {}, fallback_only: false)
    config = PulseProof::InputLoader.json(File.join(ROOT, "config/planner.json"))
    config["outcome_planner"]["pending_probabilities"] = pending
    document = Marshal.load(Marshal.dump(providers_document))
    if fallback_only
      document["providers"].each { |p| p["status"] = "inactive" unless p["payment_system"] == "spacepayments" }
    end
    instance = PulseProof::RuntimeSession.new(providers_document: document, profile: config, history: [],
      outcome_model: lambda { |_o, _p, _a| { "result" => "approved", "latency_sec" => 1 } })
    result = instance.process("type" => "operation", "operation" => queue.first)
    [instance, result.fetch("decision")]
  end

  def invoke(instance, decision)
    report = instance.report
    yield report if block_given?
    Dir.mktmpdir("pulseproof-dependence-explain-") do |directory|
      decisions_path = File.join(directory, "decisions.json")
      report_path = File.join(directory, "report.json")
      File.binwrite(decisions_path, JSON.generate([decision]))
      File.binwrite(report_path, JSON.generate(report))
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, File.join(ROOT, "bin/pulseproof"), "explain", queue.first["operation_id"],
        "--decisions", decisions_path, "--report", report_path, chdir: directory, binmode: true)
      [stdout.force_encoding(Encoding::UTF_8), stderr.force_encoding(Encoding::UTF_8), status]
    end
  end

  def test_cli_shows_checked_bounds_separate_from_point_estimates_and_order_optimum
    stdout, stderr, status = invoke(*session)
    assert status.success?, stderr
    assert_empty stderr
    assert_includes stdout, "ЗАВИСИМОСТЬ ОТКАЗОВ"
    assert_includes stdout, "При любой зависимости и тех же маргиналах"
    assert_includes stdout, "относительно одного fallback spacepayments"
    assert_includes stdout, "Порядок НЕ сертифицирован"
    assert_includes stdout, "не гарантия реальных выплат"
  end

  def test_cli_rejects_forged_lower_bound_before_printing
    stdout, stderr, status = invoke(*session) do |report|
      cert = report["proof_capsules"][queue.first["operation_id"]]["candidate_rankings"].first.first["outcome_plan"]["dependence_certificate"]
      cert["success_probability"]["lower"] = cert["success_probability"]["lower"].next_float
    end
    refute status.success?
    assert_empty stdout
    assert_includes stderr, "dependence certificate differs"
  end

  def test_cli_explicitly_marks_older_reports_without_claiming_bounds
    stdout, stderr, status = invoke(*session) do |report|
      report["proof_capsules"][queue.first["operation_id"]]["candidate_rankings"].first.each do |row|
        row["outcome_plan"].delete("dependence_certificate")
        row["outcome_plan"]["optimization"].delete("dependence_certificate_version")
      end
    end
    assert status.success?, stderr
    assert_includes stdout, "Сертификат зависимости отсутствует"
    refute_includes stdout, "При любой зависимости и тех же маргиналах"
  end

  def test_pending_explanation_does_not_publish_inapplicable_bounds
    instance, decision = session(pending: { "vipay" => 0.1 })
    stdout, stderr, status = invoke(instance, decision)
    assert status.success?, stderr
    assert_includes stdout, "Границы Фреше не применены"
    assert_includes stdout, "ожидание статуса блокирует следующие попытки: vipay"
    refute_includes stdout, "При любой зависимости и тех же маргиналах"
    assert_equal 1, instance.report["outcome_planning"]["dependence_certificates"]["not_applicable"]
  end

  def test_report_coverage_counts_snapshots_not_alternative_chains
    instance, _decision = session
    coverage = instance.report["outcome_planning"]["dependence_certificates"]
    assert_equal 1, coverage["certified"]
    assert_equal 0, coverage["not_applicable"]
    assert_equal 0, coverage["without_model_certificate"]
    refute coverage["changes_routing"]
    refute coverage["actual_success_guaranteed"]
  end

  def test_fallback_only_runtime_is_not_silently_counted_as_certified
    instance, decision = session(fallback_only: true)
    coverage = instance.report["outcome_planning"]["dependence_certificates"]
    assert_equal "spacepayments", decision["selected_provider"]
    assert_equal 0, coverage["certified"]
    assert_equal 1, coverage["without_model_certificate"]
    stdout, stderr, status = invoke(instance, decision)
    assert status.success?, stderr
    refute_includes stdout, "При любой зависимости и тех же маргиналах"
  end

  def test_cli_cannot_print_an_unchecked_plan_on_fallback_only_shortcut
    sample, _decision = session
    injected = sample.report["proof_capsules"][queue.first["operation_id"]]["candidate_rankings"].first.first["outcome_plan"]
    stdout, stderr, status = invoke(*session(fallback_only: true)) do |report|
      report["proof_capsules"][queue.first["operation_id"]]["candidate_rankings"].first.first["outcome_plan"] = injected
    end
    refute status.success?
    assert_empty stdout
    assert_includes stderr, "fallback-only runtime does not emit an outcome plan"
  end
end
