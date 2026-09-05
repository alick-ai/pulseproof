# frozen_string_literal: true

require "digest"
require "json"

module PulseProof
  module Canonical
    module_function

    def sort(value)
      case value
      when Hash
        value.keys.sort.each_with_object({}) { |key, out| out[key] = sort(value[key]) }
      when Array
        value.map { |item| sort(item) }
      else
        value
      end
    end

    def json(value)
      JSON.generate(sort(value))
    end

    def digest(value)
      Digest::SHA256.hexdigest(json(value))
    end

    def event_id(index, payload)
      "evt_%04d_%s" % [index, digest(payload)[0, 10]]
    end
  end
end
