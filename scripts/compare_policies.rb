#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "optparse"
require "tempfile"
require_relative "../lib/pulseproof"

# Retrospective analysis only: never changes the CLI default or submission files.
module PulseProofPolicyReview
  ROOT = File.expand_path("..", __dir__).freeze
  module_function

  def output_path!(path, inputs)
    expanded = File.expand_path(path, ROOT)
    directory = File.dirname(expanded)
    ancestor = directory
    ancestor = File.dirname(ancestor) until File.exist?(ancestor)
    resolved = File.join(File.realpath(ancestor), directory.delete_prefix(ancestor), File.basename(expanded))
    protected = inputs + %w[routing_decisions_test.json routing_report_test.json].map { |name| File.join(ROOT, name) }
    if protected.include?(resolved) || File.extname(resolved) != ".json"
      raise PulseProof::InputError, "comparison output must be a separate JSON artifact, not an input or submission file"
    end
    if resolved.start_with?("#{ROOT}/") && !["outputs/", "docs/evidence/"].any? { |prefix| resolved.start_with?(File.join(ROOT, prefix)) }
      raise PulseProof::InputError, "inside the repository comparison output must be under outputs/ or docs/evidence/"
    end
    expanded
  end

  def metrics(result, document, fallback)
    total = result.decisions.length
    distribution = document.fetch("providers").each_with_object({}) do |provider, rows|
      name = provider.fetch("payment_system")
      count = result.decisions.count { |decision| decision.fetch("selected_provider") == name }
      target = provider.fetch("traffic_percentage", 0).to_f
      share = total.zero? ? 0.0 : count * 100.0 / total
      rows[name] = { "count" => count, "share_pct" => share, "target_pct" => target,
                     "deviation_pp" => share - target }
    end
    external = distribution.reject { |name, _| name == fallback }
    {
      "total_operations" => total,
      "distribution" => distribution,
      "external_l1_pp_unrounded" => external.values.sum { |row| row.fetch("deviation_pp").abs },
      "report_external_l1_pp_sum_of_rounded_rows" => result.report.fetch("soft_goal_analysis").fetch("raw_target_deviation_l1_pp"),
      "all_providers_l1_pp_unrounded" => distribution.values.sum { |row| row.fetch("deviation_pp").abs },
      "fallback_count" => distribution.fetch(fallback).fetch("count"),
      "simulated_approved_count" => result.decisions.count { |decision| decision.fetch("simulated_result") == "approved" },
      "strict_validation" => "passed"
    }
  end

  def run(arguments)
    options = { output: File.join(ROOT, "outputs/policy-review.json") }
    OptionParser.new do |parser|
      parser.banner = "Usage: ruby scripts/compare_policies.rb [--queue PATH] [--output PATH]"
      parser.on("--queue PATH") { |value| options[:queue] = value }
      parser.on("--output PATH") { |value| options[:output] = value }
    end.parse!(arguments)
    raise PulseProof::InputError, "unexpected positional arguments" unless arguments.empty?

    queue = PulseProof::InputLocator.queue(root: ROOT, explicit: options[:queue])
    providers = File.join(ROOT, "data/providers.json")
    history = File.join(ROOT, "data/operations_history.csv")
    profile_path = File.join(ROOT, "config/balanced.json")
    paths = { "queue" => queue, "providers" => providers, "history" => history, "balanced_profile" => profile_path }
    output = output_path!(options.fetch(:output), paths.values)
    input_hashes = paths.transform_values { |path| Digest::SHA256.file(path).hexdigest }
    baseline = PulseProof::InputLoader.json(profile_path)
    alternative = Marshal.load(Marshal.dump(baseline))
    alternative["profile"] = "balanced_conversion_first_retrospective"
    alternative["selection_mode"] = "conversion_first"
    changed_keys = (baseline.keys | alternative.keys).select { |key| baseline[key] != alternative[key] }.sort
    raise PulseProof::InvariantError, "comparison changed more than the declared selection order" unless changed_keys == %w[profile selection_mode]

    runner_options = { providers_path: providers, queue_path: queue, history_path: history, simulation_mode: "approve" }
    balanced = PulseProof::Runner.new(**runner_options, profile_path: profile_path).run
    comparison = Tempfile.create(["pulseproof-policy-review-", ".json"]) do |file|
      file.write(JSON.generate(alternative))
      file.flush
      PulseProof::Runner.new(**runner_options, profile_path: file.path).run
    end
    raise PulseProof::InvariantError, "input changed during comparison" unless paths.all? { |name, path| Digest::SHA256.file(path).hexdigest == input_hashes.fetch(name) }

    document = PulseProof::InputLoader.json(providers)
    fallback = baseline.fetch("fallback_provider", "spacepayments")
    payload = {
      "schema" => "pulseproof.policy_review.v1",
      "status" => "RETROSPECTIVE_COMPARISON_VALIDATED",
      "input_sha256" => input_hashes,
      "alternative_profile_canonical_sha256" => PulseProof::Canonical.digest(alternative),
      "changed_config_keys" => changed_keys,
      "simulation_mode" => "approve",
      "external_provider_calls" => false,
      "changes_submission_policy" => false,
      "changes_submission_artifacts" => false,
      "retrospective" => true,
      "comparison_selected_after_observing_queue_results" => true,
      "held_out_evaluation" => false,
      "contains_operation_ids_or_requisites" => false,
      "policies" => {
        "balanced" => metrics(balanced, document, fallback),
        "balanced_conversion_first" => metrics(comparison, document, fallback)
      },
      "scope" => {
        "denominator" => "all operations in the supplied queue; history is calibration only",
        "attribution" => "final selected_provider, including fallback",
        "external_l1" => "sum of absolute deviations for providers other than fallback; shares use the full queue denominator",
        "comparison_control" => "same inputs, hard rules, weights and explicit approve simulation; only profile label and selection_mode differ",
        "tradeoff" => "conversion_first ranks by conversion, goal regret, load, priority and name; it does not rank by the weighted secondary total, so margin, amount_fit and turnover_min no longer affect that sort key",
        "interpretation" => "observed allocation difference only; no held-out improvement, actual payment success, conversion uplift or global optimality is claimed",
        "recommendation" => "review selection_mode=conversion_first as an operator-approved configuration alternative; retain balanced for this submission"
      }
    }
    PulseProof::OutputWriter.json(output, payload, verify: true)
    puts "Retrospective policy comparison: PASS (#{balanced.decisions.length} operations per policy; submission files unchanged)"
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    PulseProofPolicyReview.run(ARGV)
  rescue PulseProof::InputError, PulseProof::InvariantError, OptionParser::ParseError => error
    warn "Policy comparison failed: #{error.message}"
    exit 1
  end
end
