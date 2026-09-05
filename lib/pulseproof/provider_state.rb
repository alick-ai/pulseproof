# frozen_string_literal: true

module PulseProof
  class ProviderState
    attr_reader :config, :reservations, :rpm_timestamps

    def initialize(config)
      @config = Marshal.load(Marshal.dump(config))
      @daily_approved_cents = Money.cents(config["daily_approved_amount"])
      @base_in_progress_count = integer(config["in_progress_count"])
      @base_in_progress_amount = number(config["in_progress_amount"])
      @reservations = {}
      @rpm_timestamps = []
    end

    def name
      config.fetch("payment_system")
    end

    def daily_approved_amount
      Money.rubles(@daily_approved_cents)
    end

    def daily_approved_amount=(value)
      @daily_approved_cents = Money.cents(value)
    end

    def target_count_pct
      number(config["traffic_percentage"])
    end

    def target_volume_pct
      value = config["volume_share_pct"]
      value.nil? ? nil : number(value)
    end

    def reserved_count
      reservations.length
    end

    def reserved_amount
      Money.rubles(reservations.values.inject(0) { |sum, reservation| sum + Money.cents(reservation.fetch("amount")) })
    end

    def effective_in_progress_count
      @base_in_progress_count + reserved_count
    end

    def effective_in_progress_amount
      Money.sum(@base_in_progress_amount, reserved_amount)
    end

    def effective_daily_amount
      Money.sum(daily_approved_amount, reserved_amount)
    end

    def available_requisites
      [integer(config["available_requisites"]) - reserved_count, 0].max
    end

    def reserve!(reservation)
      operation_id = reservation.fetch("operation_id")
      raise InvariantError, "duplicate reservation for #{operation_id}" if reservations.key?(operation_id)
      reservations[operation_id] = reservation
    end

    def release!(operation_id)
      reservations.delete(operation_id) || raise(InvariantError, "missing reservation for #{operation_id}")
    end

    def commit!(operation_id)
      reservation = release!(operation_id)
      @daily_approved_cents += Money.cents(reservation.fetch("amount"))
      reservation
    end

    def prune_rpm!(at, window_sec = 60)
      threshold = at.to_f - window_sec
      rpm_timestamps.reject! { |timestamp| timestamp.to_f <= threshold }
    end

    def record_request!(at)
      prune_rpm!(at)
      rpm_timestamps << at
    end

    def rpm_count(at)
      prune_rpm!(at)
      rpm_timestamps.length
    end

    def load_ratio
      ratios = []
      if config["in_progress_count_limit"]
        limit = config["in_progress_count_limit"].to_f
        ratios << (limit.zero? ? 1.0 : effective_in_progress_count.to_f / limit)
      end
      if config["in_progress_amount_limit"]
        limit = config["in_progress_amount_limit"].to_f
        ratios << (limit.zero? ? 1.0 : effective_in_progress_amount.to_f / limit)
      end
      ratios.empty? ? 0.0 : ratios.max
    end

    def snapshot(at = nil)
      {
        "rules" => Marshal.load(Marshal.dump(config)),
        "payment_system" => name,
        "status" => config["status"],
        "traffic_percentage" => target_count_pct,
        "daily_approved_amount" => rounded(daily_approved_amount),
        "reserved_count" => reserved_count,
        "reserved_amount" => rounded(reserved_amount),
        "effective_in_progress_count" => effective_in_progress_count,
        "effective_in_progress_amount" => rounded(effective_in_progress_amount),
        "available_requisites" => available_requisites,
        "rpm_count" => at ? rpm_count(at) : rpm_timestamps.length,
        "load_ratio" => load_ratio.round(6)
      }
    end

    private

    def integer(value)
      value.nil? ? 0 : value.to_i
    end

    def number(value)
      value.nil? ? 0.0 : value.to_f
    end

    def rounded(value)
      value.to_f.round(2)
    end
  end
end
