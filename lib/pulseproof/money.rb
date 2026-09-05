# frozen_string_literal: true

require "bigdecimal"

module PulseProof
  module Money
    module_function

    def cents(value)
      decimal = BigDecimal((value || 0).to_s)
      raise InputError, "money must be finite" unless decimal.finite?
      (decimal * 100).round(0, BigDecimal::ROUND_HALF_UP).to_i
    end

    def rubles(cents)
      cents / 100.0
    end

    def sum(*values)
      rubles(values.inject(0) { |total, value| total + cents(value) })
    end
  end
end
