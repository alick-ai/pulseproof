# frozen_string_literal: true

module PulseProof
  module Redactor
    SENSITIVE_KEYS = %w[phone payout_requisite requisite card_number pan account].freeze

    module_function

    def call(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, item), out|
          out[key] = sensitive?(key) ? "[REDACTED]" : call(item)
        end
      when Array
        value.map { |item| call(item) }
      else
        value
      end
    end

    def sensitive?(key)
      normalized = key.to_s.downcase
      SENSITIVE_KEYS.any? { |candidate| normalized.include?(candidate) }
    end

    def phone_like?(text)
      !!text.to_s.match(/(?<![A-Za-z0-9])(?:\+7|8)[\s()\-]*\d{3}[\s()\-]*\d{3}[\s\-]*\d{2}[\s\-]*\d{2}(?![A-Za-z0-9])/)
    end
  end
end
