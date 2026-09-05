# frozen_string_literal: true

require "json"
require "minitest/autorun"
require_relative "../lib/pulseproof"

module PulseProofTestData
  ROOT = File.expand_path("..", __dir__)

  def providers_document
    @providers_document ||= PulseProof::InputLoader.json(File.join(ROOT, "data/providers.json"))
  end

  def queue
    @queue ||= PulseProof::InputLoader.json(File.join(ROOT, "data/operations_queue_10.json"))
  end

  def history
    @history ||= PulseProof::InputLoader.history(File.join(ROOT, "data/operations_history.csv"))
  end

  def profile
    @profile ||= PulseProof::InputLoader.json(File.join(ROOT, "config/balanced.json"))
  end

  def provider_states
    providers_document.fetch("providers").each_with_object({}) do |config, out|
      state = PulseProof::ProviderState.new(config)
      out[state.name] = state
    end
  end

  def metric_map(states = provider_states)
    PulseProof::MetricTrustGate.new(history, states, prior_strength: profile["history_prior_strength"]).all
  end

  def runner(outcome_model = nil)
    PulseProof::Runner.new(
      providers_path: File.join(ROOT, "data/providers.json"),
      queue_path: File.join(ROOT, "data/operations_queue_10.json"),
      history_path: File.join(ROOT, "data/operations_history.csv"),
      profile_path: File.join(ROOT, "config/balanced.json"),
      outcome_model: outcome_model
    )
  end
end
