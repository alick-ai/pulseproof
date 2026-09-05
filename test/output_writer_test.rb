# frozen_string_literal: true

require "tmpdir"
require_relative "test_helper"

class OutputWriterTest < Minitest::Test
  def test_readable_verified_output_round_trips_exactly
    Dir.mktmpdir("pulseproof-output-writer-") do |directory|
      path = File.join(directory, "artifact.json")
      payload = { "русский" => [1, 2.5, true, nil, { "nested" => "value" }] }

      PulseProof::OutputWriter.json(path, payload, verify: true)

      assert_equal payload, JSON.parse(File.read(path, encoding: "UTF-8"))
      assert_includes File.read(path, encoding: "UTF-8"), "\n  "
      assert_equal 0o644, File.stat(path).mode & 0o777
    end
  end
end
