# frozen_string_literal: true

module PulseProof
  class ExplanationPresenter
    def initialize(decision:, proof:)
      @decision = decision
      @proof = proof || {}
    end

    def call
      lines = []
      lines << "OPERATION #{@decision.fetch('operation_id')}"
      lines << "FINAL     #{@decision.fetch('selected_provider')} / #{@decision.fetch('simulated_result')} / #{format_number(@decision.fetch('latency_sec'))} sec"
      lines << ""
      lines << "ATTEMPTS"
      @decision.fetch("attempts").each_with_index do |attempt, index|
        outcome = attempt["result"] ? " -> #{attempt['result']}" : ""
        lines << format("%2d. %-14s %-8s %-30s%s", index + 1, attempt.fetch("provider"), attempt.fetch("decision"), attempt.fetch("reason"), outcome)
        lines << "    #{attempt['details']}" if attempt["details"]
      end
      lines << ""
      @proof.fetch("candidate_rankings", []).each_with_index do |ranking, index|
        next unless ranking.first && ranking.first["outcome_plan"]
        lines << "АЛЬТЕРНАТИВЫ ПЕРЕД ПОПЫТКОЙ #{index + 1} — модель, не известное будущее"
        ranking.each do |row|
          plan = row.fetch("outcome_plan")
          lines << "  #{plan['chain'].join(' → ')}: ожидаемые попытки #{plan['raw_metrics']['attempts'].round(3)}, разница целевой функции +#{plan['gap_to_best'].round(4)}"
          lines << "    Итоговое принятие в модели независимых попыток: #{plan['final_approval_probabilities'].map { |name,p| "#{name}=#{(p * 100).round(2)}%" }.join(', ')}"
          if plan["gap_to_best"] > 0
            differences = plan["alternative_terms_minus_best"].select { |_k,v| v.abs > 1e-6 }
            lines << "    Разложение разницы: #{differences}"
          end
        end
        lines.concat(dependence_lines(ranking.first.dig("outcome_plan", "dependence_certificate")))
        lines << "  Исполняется только первый шаг; после подтверждённого отказа — новый расчёт."
        lines << ""
      end
      lines << "PROOF"
      lines << "snapshot   #{@proof['snapshot_hash'] || 'n/a'}"
      lines << "policy     #{@proof['policy_profile'] || 'n/a'}"
      lines << "winner     #{@proof['winning_factor'] || 'n/a'}"
      lines << "event head #{@proof['event_head'] || 'n/a'}"
      snapshots = @proof.fetch("attempt_snapshots", [])
      snapshots.each do |snapshot|
        lines << "attempt #{snapshot['attempt']}  #{snapshot['provider']} @ #{snapshot['snapshot_hash']}"
      end
      lines.join("\n")
    end

    private

    def dependence_lines(certificate)
      return ["  Сертификат зависимости отсутствует: старый отчёт, границы не проверены."] unless certificate
      lines = ["  ЗАВИСИМОСТЬ ОТКАЗОВ — отдельный аналитический сертификат"]
      if certificate["status"] == "not_applicable"
        reason = certificate["reason"] == "empty_chain" ? "цепочка пуста" : "ожидание статуса блокирует следующие попытки: #{certificate['pending_providers'].join(', ')}"
        lines << "    Границы Фреше не применены: #{reason}."
      else
        reference = certificate.fetch("independent_reference")
        success = certificate.fetch("success_probability")
        failure = certificate.fetch("all_failed_probability")
        lines << "    Независимая модель: успех #{percent(reference['success'])}, полный отказ #{percent(reference['all_failed'])}."
        lines << "    При любой зависимости и тех же маргиналах: успех #{percent(success['lower'])}–#{percent(success['upper'])}; полный отказ #{percent(failure['lower'])}–#{percent(failure['upper'])}."
        lines << "    Нижнюю границу определяют: #{certificate.fetch('lower_bound_drivers').join(', ')}."
        fallback = certificate.fetch("fallback")
        if fallback["included"]
          gain = fallback.fetch("success_lower_bound_gain_over_fallback")
          lines << "    Прирост нижней границы успеха относительно одного fallback #{fallback['provider']}: #{(100 * gain).round(6)} п.п."
        else
          lines << "    Fallback не входит в допустимую цепочку; его вероятность в границах не используется."
        end
      end
      lines << "    Это границы для полного замороженного каскада при заданных оценках, не гарантия реальных выплат."
      lines << "    Порядок НЕ сертифицирован при произвольной зависимости: попытки, задержка и атрибуция зависят от неё уже сейчас."
      lines
    end

    def percent(value)
      "#{(value * 100).round(6)}%"
    end

    def format_number(value)
      number = value.to_f
      number % 1 == 0 ? number.to_i : number.round(2)
    end
  end
end
