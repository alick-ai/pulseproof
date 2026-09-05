# frozen_string_literal: true

module PulseProof
  # A concise read-only view of an existing result. This does not solve or
  # certify anything; exact coefficients and costs remain in the JSON output.
  class ChallengePresenter
    def initialize(result:)
      @result = result
    end

    def call
      lines = ["Операция #{label(@result['operation_id'], 'не указана')} · попытка #{label(@result['attempt'], 'не указана')}",
        "Запрошенный провайдер: #{label(@result['provider'], 'не указан')}"]
      case @result['status']
      when 'verified_counterfactual'
        lines << 'ПЕРЕКЛЮЧЕНИЕ ПРОВЕРЕНО'
        lines << "Вес #{label(@result['factor'])}: #{number(@result['current_weight'])} → #{number(@result['proposed_weight'])}"
        lines << "Исходная цепочка: #{chain(@result['original_chain'])}"
        lines << "Проверенная цепочка: #{chain(@result['verified_chain'])}"
        lines << "Выигрышный интервал (границы ≈): #{interval(@result['winning_interval'])}"
        adjacent = @result['adjacent_weight_toward_current']
        if adjacent
          lines << "Соседний машинный вес к исходному: #{number(adjacent['weight'])} → #{chain(adjacent['chain'])}"
        end
        if @result['method'] == 'exact_parametric_pair_exchange'
          lines << 'Точные границы и стоимости сохранены в JSON; продолжение пересчитано при новом весе.'
        else
          lines << 'Проверка по сохранённой матрице; область вывода ограничена рассмотренными цепочками. Подробности — в JSON.'
        end
      when 'not_eligible'
        lines << 'НЕ ДОПУЩЕН К ВЫБОРУ В ЭТОМ СНИМКЕ'
        lines << 'Провайдера нет среди допустимых первых действий: веса не обходят hard-ограничения и не возвращают исчерпанный маршрут.'
        lines << 'Конкретную причину исключения нужно смотреть в проверках допуска, а не выводить из этого ответа.'
      when 'already_selected'
        lines << 'УЖЕ ВЫБРАН: менять вес не требуется.'
        lines << "Текущий вес #{label(@result['factor'])}: #{number(@result['current_weight'])}"
        lines << "Текущая цепочка: #{chain(@result['original_chain'])}" if @result['original_chain']
      when 'no_single_weight_solution'
        lines << 'ОДНОГО ВЕСА НЕДОСТАТОЧНО'
        lines << "Нет неотрицательного значения #{label(@result['factor'])}, которое выберет этого провайдера в проверяемой модели."
      when 'no_representable_weight'
        lines << 'ВЕЩЕСТВЕННАЯ ОБЛАСТЬ ЕСТЬ, МАШИННОГО ВЕСА НЕТ'
        lines << 'Ни один проверенный конечный Float не реализует найденную область. Переключение не подтверждено.'
        Array(@result['winning_regions']).each do |region|
          lines << "Область (границы ≈): #{interval(region)}"
        end
      else
        lines << "Статус: #{label(@result['status'], 'не указан')}. Подтверждённое переключение не заявляется."
      end
      lines << 'Только тот же снимок и симуляционная модель. Выплата не отправлена, правила не изменены; будущий результат не гарантирован.'
      lines.join("\n")
    end

    private

    def label(value, missing = 'не указан')
      return missing if value.nil?
      value.to_s.gsub(/[\x00-\x1f\x7f]/, ' ')
    end

    def number(value)
      value.nil? ? 'не указан' : label(value)
    end

    def chain(value)
      Array(value).map { |name| label(name) }.join(' → ')
    end

    def interval(region)
      return 'не указан' unless region
      if region.key?('lower_closed')
        left = region['lower_closed'] ? '[' : '('
        right = region['upper_closed'] ? ']' : ')'
        lower = endpoint(region['lower'], region['lower_exact'], false)
        upper = endpoint(region['upper'], region['upper_exact'], true)
      else
        # Older saved frontier-only reports have inclusive numeric endpoints.
        left = '['
        right = region['upper_inclusive'].nil? ? ')' : ']'
        lower = number(region['lower_inclusive'])
        upper = region['upper_inclusive'].nil? ? '+∞' : number(region['upper_inclusive'])
      end
      "#{left}#{lower}; #{upper}#{right}"
    end

    def endpoint(value, exact, upper)
      return number(value) unless value.nil?
      return 'вне диапазона Float' unless exact.nil?
      upper ? '+∞' : 'не указана'
    end
  end
end
