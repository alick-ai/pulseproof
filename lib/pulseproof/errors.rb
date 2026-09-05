# frozen_string_literal: true

module PulseProof
  class Error < StandardError; end
  class InputError < Error; end
  class InvariantError < Error; end
  class TransitionError < Error; end
end
