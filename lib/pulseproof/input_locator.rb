# frozen_string_literal: true

module PulseProof
  class InputLocator
    QUEUE_CANDIDATES = [
      "operations_queue_test.json",
      File.join("data", "operations_queue_test.json"),
      File.join("data", "operations_queue_10.json")
    ].freeze

    def self.queue(root:, explicit: nil)
      return File.expand_path(explicit, root) if explicit

      found = QUEUE_CANDIDATES.map { |path| File.join(root, path) }.find { |path| File.file?(path) }
      return found if found

      raise InputError, "queue not found; expected one of: #{QUEUE_CANDIDATES.join(', ')}"
    end

    def self.test_queue?(path)
      File.basename(path) == "operations_queue_test.json"
    end
  end
end
