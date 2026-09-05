# frozen_string_literal: true

require_relative "test_helper"

class InputLoaderTest < Minitest::Test
  include PulseProofTestData

  def test_rejects_invalid_provider_conversion
    document = Marshal.load(Marshal.dump(providers_document))
    document.fetch("providers").first["conversion_24h"] = 1.2

    error = assert_raises(PulseProof::InputError) do
      PulseProof::InputLoader.validate_provider_document!(document)
    end
    assert_match(/between 0 and 1/, error.message)
  end

  def test_rejects_unknown_provider_in_amount_preferences
    invalid_profile = profile.merge(
      "amount_preferences" => profile.fetch("amount_preferences").merge("ghostpay" => { "min" => 1 })
    )

    error = assert_raises(PulseProof::InputError) do
      PulseProof::InputLoader.validate_profile!(invalid_profile, providers_document)
    end
    assert_match(/unknown providers: ghostpay/, error.message)
  end

  def test_rejects_non_iso_operation_timestamp
    invalid_queue = Marshal.load(Marshal.dump(queue))
    invalid_queue.first["created_at"] = "tomorrow"

    error = assert_raises(PulseProof::InputError) do
      PulseProof::InputLoader.validate_queue!(invalid_queue)
    end
    assert_match(/ISO-8601/, error.message)
  end
end
