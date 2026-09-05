import { Check, Clock3, Database, Lightbulb, RefreshCw, Route, ShieldCheck, UnlockKeyhole } from 'lucide-react'

const providerLabel = (name) => ({ vipay: 'ViPay', payflow: 'PayFlow', quickpay: 'QuickPay', spacepayments: 'SpacePayments' }[name] || name)

const phaseMessages = [
  'ViPay выбран, лимит зарезервирован до отправки.',
  'Ответа нет. Это не отказ: повтор пока заблокирован.',
  'Статус-запрос подтвердил отмену. Повтор теперь безопасен.',
  'Резерв ViPay освобождён и возвращён в доступный лимит.',
  'На новом снимке выбран и зарезервирован QuickPay.',
  'QuickPay принял выплату. Теперь она учтена в доле трафика.',
]

const phaseResults = [
  ['ViPay', 'Лимит зарезервирован', 'blue'],
  ['Статус неизвестен', 'Повтор заблокирован', 'warning'],
  ['Отмена подтверждена', 'Повтор разрешён', 'warning'],
  ['Пересчёт маршрута', 'Новый снимок состояния', 'warning'],
  ['QuickPay', 'Запрос отправлен', 'blue'],
  ['QuickPay', 'Выплата принята', 'success'],
]

function fallbackContext(phase, operation) {
  const amount = operation.amount.toLocaleString('ru-RU')
  const bank = operation.bank
  const contexts = [
    {
      title: 'Почему ViPay',
      reasons: [
        { Icon: ShieldCheck, title: 'Hard gate пройден', body: `${amount} ₽ и ${bank} проходят обязательные правила ViPay.` },
        { Icon: Route, title: 'Минимальный regret', body: 'На текущем снимке ViPay даёт наименьшее худшее отклонение от целевых долей.' },
        { Icon: UnlockKeyhole, title: 'Резерв до запроса', body: 'Лимит и реквизит атомарно закреплены до обращения к провайдеру.' },
      ],
    },
    {
      title: 'Почему не повторяем',
      reasons: [
        { Icon: Clock3, title: 'Исход неизвестен', body: 'Таймаут означает отсутствие ответа, но не означает отказ провайдера.' },
        { Icon: ShieldCheck, title: 'Защита от дубля', body: 'Новая попытка заблокирована, пока статус первой выплаты не подтверждён.' },
        { Icon: Database, title: 'Резерв удерживается', body: 'Ёмкость остаётся занятой: оптимистичный возврат создал бы oversubscription.' },
      ],
    },
    {
      title: 'Почему можно продолжить',
      reasons: [
        { Icon: Check, title: 'Отмена подтверждена', body: 'Status API вернул терминальное состояние cancel для первой попытки.' },
        { Icon: ShieldCheck, title: 'Повтор безопасен', body: 'ViPay уже не может завершить эту попытку — риска двойной выплаты нет.' },
        { Icon: RefreshCw, title: 'Нужен новый снимок', body: 'Следующий маршрут будет выбран из актуальных лимитов, а не из устаревшего списка.' },
      ],
    },
    {
      title: 'Как восстановили состояние',
      reasons: [
        { Icon: UnlockKeyhole, title: 'Резерв освобождён', body: `${amount} ₽ возвращены в доступный дневной лимит ViPay.` },
        { Icon: Database, title: 'Компенсирующее событие', body: 'История не переписана: release добавлен новой записью в журнал.' },
        { Icon: ShieldCheck, title: 'Инварианты сохранены', body: 'Settled и reserved учитываются раздельно, поэтому лимиты не расходятся.' },
      ],
    },
    {
      title: 'Почему QuickPay',
      reasons: [
        { Icon: ShieldCheck, title: 'Hard gate пройден', body: `${amount} ₽ и ${bank} допустимы для QuickPay на новом снимке.` },
        { Icon: Route, title: 'Единственный маршрут', body: 'ViPay уже использован в каскаде, а лимит PayFlow на одну выплату — 50 000 ₽.' },
        { Icon: UnlockKeyhole, title: 'Новый резерв', body: 'QuickPay зарезервирован атомарно непосредственно перед второй попыткой.' },
      ],
    },
    {
      title: 'Почему QuickPay',
      reasons: [
        { Icon: Check, title: 'Заявка принята', body: 'Только подтверждённая QuickPay попытка становится итоговым провайдером.' },
        { Icon: Route, title: 'Честная доля трафика', body: 'Операция учитывается в фактической доле QuickPay, а не первой попытки ViPay.' },
        { Icon: Database, title: 'Решение доказуемо', body: 'Снимок, оценки кандидатов, резервы и статусы связаны хэш-цепочкой.' },
      ],
    },
  ]
  return contexts[phase]
}

export default function WhyPanel({ operation, frame, playbackPhase = 5 }) {
  const winner = providerLabel(frame.proof.winner)
  const selectedAttempts = (frame.decision?.attempts || []).filter((attempt) => attempt.decision === 'selected')
  const hadTimeout = selectedAttempts.some((attempt) => attempt.result === 'expired')
  const winnerEvaluation = frame.proof.hard_evaluations?.at(-1)?.find((item) => item.provider === frame.proof.winner)
  const visiblePhase = hadTimeout ? playbackPhase : 5
  const [visibleResult, visibleStatus, resultTone] = hadTimeout ? phaseResults[visiblePhase] : [winner, 'Выплата принята', 'success']
  const reason = frame.proof.winning_factor === 'only_eligible_provider'
    ? 'После подтверждённой отмены это единственный доступный внешний провайдер.'
    : 'Даёт минимальное худшее отклонение от целевых долей трафика.'

  const defaultReasons = [
    { Icon: ShieldCheck, title: 'Жёсткие ограничения', body: `Сумма ${operation.amount.toLocaleString('ru-RU')} ₽ и банк ${operation.bank} проходят все обязательные правила.` },
    { Icon: Route, title: hadTimeout ? 'Безопасный fallback' : 'Баланс трафика', body: hadTimeout ? 'Первый резерв освобождён только после подтверждённой отмены — риска двойной выплаты нет.' : reason },
    { Icon: Database, title: 'Резерв до отправки', body: `${winnerEvaluation?.facts?.available_requisites ?? 'Доступные'} реквизитов в снимке; ёмкость зарезервирована атомарно до запроса.` },
  ]
  const context = hadTimeout ? fallbackContext(visiblePhase, operation) : { title: `Почему ${winner}`, reasons: defaultReasons }

  return (
    <aside className="why-panel" aria-labelledby="why-title">
      <div className="why-title"><Lightbulb /><h2 id="why-title">{context.title}</h2></div>
      {hadTimeout && <div className={`live-event live-event--${resultTone}`} aria-live="polite"><span>Событие {visiblePhase + 1} / 6</span><strong>{phaseMessages[visiblePhase]}</strong></div>}
      <div className="reason-list">
        {context.reasons.map(({ Icon, title, body }) => (
          <article className="reason-item" key={title}>
            <span><Icon /></span>
            <div><h3>{title}</h3><p>{body}</p></div>
          </article>
        ))}
      </div>
      <div className="final-result">
        <span>{visiblePhase >= 4 ? 'Итоговый провайдер' : 'Состояние операции'}</span>
        <strong className={`final-result__value--${resultTone}`}>{visibleResult}</strong>
        <div className={`final-result__status--${resultTone}`}><Check /> {visibleStatus}</div>
      </div>
    </aside>
  )
}
