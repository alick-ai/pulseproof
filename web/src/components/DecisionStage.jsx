import { Check, Clock3, Landmark, Route, ShieldX, UnlockKeyhole, WalletCards } from 'lucide-react'
import { money } from '../utils.js'

const providerLabel = (name) => ({ vipay: 'ViPay', payflow: 'PayFlow', quickpay: 'QuickPay', spacepayments: 'SpacePayments' }[name] || name)

function buildRoute(frame) {
  const attempts = (frame.decision?.attempts || []).filter((attempt) => attempt.decision === 'selected')
  if (attempts.some((attempt) => attempt.result === 'expired')) {
    return [
      { eyebrow: 'Попытка 1', label: providerLabel(attempts[0]?.provider), tone: 'violet', Icon: WalletCards },
      { eyebrow: 'Нет ответа', label: 'Таймаут', tone: 'danger', Icon: Clock3 },
      { eyebrow: 'Статус получен', label: 'Отмена подтверждена', tone: 'danger', Icon: ShieldX },
      { eyebrow: 'Резерв', label: 'Лимит освобождён', tone: 'warning', Icon: UnlockKeyhole },
      { eyebrow: 'Попытка 2', label: providerLabel(attempts.at(-1)?.provider), tone: 'blue', Icon: Route },
      { eyebrow: 'Результат', label: 'Выплата принята', tone: 'success', Icon: Check },
    ]
  }

  return [
    { eyebrow: 'Выбор', label: providerLabel(attempts[0]?.provider), tone: 'blue', Icon: Route },
    { eyebrow: 'До запроса', label: 'Лимит зарезервирован', tone: 'warning', Icon: UnlockKeyhole },
    { eyebrow: 'Ответ провайдера', label: 'Выплата принята', tone: 'success', Icon: Check },
  ]
}

export default function DecisionStage({ operation, frame, playbackPhase = 5, onPhaseSelect }) {
  const route = buildRoute(frame)
  const activePhase = route.length === 6 ? Math.min(playbackPhase, route.length - 1) : route.length - 1
  const progress = route.length === 1 ? 100 : (activePhase / (route.length - 1)) * 86
  return (
    <section className="decision-stage" aria-labelledby="operation-title">
      <div className="operation-title-row">
        <div>
          <span>Операция <code>{operation.operation_id}</code></span>
          <h1 id="operation-title">{money(operation.amount)}</h1>
        </div>
        <div className="bank-name"><Landmark /> <span>{operation.bank}</span></div>
      </div>

      <ol className={`route-story route-story--${route.length}`} aria-label="Путь выплаты">
        <span className="route-story__base" aria-hidden="true" />
        <span className="route-story__progress" style={{ width: `${progress}%` }} aria-hidden="true" />
        {route.map(({ eyebrow, label, tone, Icon }, index) => (
          <li className={`route-node route-node--${tone} ${index > activePhase ? 'is-future' : ''} ${index === activePhase ? 'is-current' : ''}`} key={`${label}-${index}`}>
            <button
              type="button"
              className="route-node__control"
              disabled={route.length !== 6}
              onClick={() => onPhaseSelect?.(index)}
              aria-label={`${eyebrow}: ${label}`}
              aria-current={index === activePhase ? 'step' : undefined}
            >
              <small>{eyebrow}</small>
              <span className="route-node__icon"><Icon /></span>
              <strong>{label}</strong>
            </button>
          </li>
        ))}
      </ol>
    </section>
  )
}
