import { Check, Clock3, RefreshCw, ShieldX } from 'lucide-react'
import { compactMoney } from '../utils.js'

const providerLabel = (name) => ({ vipay: 'ViPay', payflow: 'PayFlow', quickpay: 'QuickPay' }[name] || name)
const providerInitial = (name) => ({ vipay: 'vi', payflow: 'pf', quickpay: 'Q' }[name] || name[0])

function ruleText(evaluation) {
  if (!evaluation) return 'Нет данных'
  if (evaluation.eligible) return 'Все ограничения пройдены'
  const labels = {
    amount_exceeds_limit: 'Сумма выше допустимого лимита',
    amount_below_minimum: 'Сумма ниже минимального порога',
    bank_not_in_list: 'Банк не поддерживается',
    daily_amount_limit: 'Дневной лимит исчерпан',
    requisites_exhausted: 'Нет доступных реквизитов',
    rpm_limit: 'Превышен лимит запросов',
  }
  return labels[evaluation.reason] || evaluation.reason?.replaceAll('_', ' ')
}

function providerState(name, evaluation, frame, playbackPhase) {
  const attempt = frame.decision?.attempts?.find((item) => item.provider === name && item.decision === 'selected')
  if (!evaluation?.eligible) return { label: 'Исключён', tone: 'danger', Icon: ShieldX }
  const isFallbackStory = frame.proof.reservations?.length > 1
  if (isFallbackStory && name === 'vipay') {
    if (playbackPhase === 0) return { label: 'Резерв', tone: 'blue', Icon: Check }
    if (playbackPhase === 1) return { label: 'Таймаут', tone: 'warning', Icon: RefreshCw }
    if (playbackPhase === 2) return { label: 'Отмена', tone: 'warning', Icon: RefreshCw }
    return { label: 'Освобождён', tone: 'warning', Icon: RefreshCw }
  }
  if (isFallbackStory && name === 'quickpay') {
    if (playbackPhase < 4) return { label: 'Ожидает', tone: 'neutral', Icon: Clock3 }
    if (playbackPhase === 4) return { label: 'Резерв', tone: 'blue', Icon: Check }
  }
  if (attempt?.result === 'expired') return { label: 'Освобождён', tone: 'warning', Icon: RefreshCw }
  if (name === frame.proof.winner) return { label: 'Выбран', tone: 'blue', Icon: Check }
  return { label: 'Допустим', tone: 'neutral', Icon: Check }
}

export default function ProviderMatrix({ providers, frame, previousFrame, report, playbackPhase = 5 }) {
  const evaluations = frame.proof.hard_evaluations?.at(-1) || []
  const quality = report.history_quality || {}
  const order = ['vipay', 'quickpay', 'payflow']

  return (
    <section className="provider-matrix" aria-label="Сравнение провайдеров">
      <div className="provider-columns" aria-hidden="true">
        <span>Провайдер</span><span>Жёсткие ограничения</span><span>Баланс трафика</span><span>Надёжность</span><span>Свободный лимит</span><span>Результат</span>
      </div>
      {order.map((name) => {
        const provider = providers.find((item) => item.name === name)
        const evaluation = evaluations.find((item) => item.provider === name)
        const state = providerState(name, evaluation, frame, playbackPhase)
        const shareSource = frame.proof.reservations?.length > 1 && playbackPhase < 5 ? previousFrame?.shares : frame.shares
        const actual = Number(shareSource?.[name] || 0)
        const target = Number(provider?.target_pct || 0)
        const reliability = Number(quality[name]?.conservative_conversion || provider?.conversion || 0) * 100
        const available = provider?.daily_limit == null ? null : Math.max(0, provider.daily_limit - Number(evaluation?.facts?.effective_daily_amount || provider.daily_used || 0))
        return (
          <article className={`provider-row provider-row--${state.tone}`} key={name}>
            <div className="provider-identity"><span>{providerInitial(name)}</span><strong>{providerLabel(name)}</strong></div>
            <div className="provider-rule"><b>{evaluation?.eligible ? 'Подходит' : 'Не подходит'}</b><small>{ruleText(evaluation)}</small></div>
            <div className="traffic-balance">
              <div className="traffic-track"><i style={{ width: `${Math.min(actual, 100)}%` }} /><em style={{ left: `${target}%` }} /></div>
              <small>цель {target}% · факт {actual}%</small>
            </div>
            <div className="reliability"><strong>{reliability.toFixed(1)}%</strong><small>консервативная оценка</small></div>
            <div className="available-limit"><strong>{available == null ? '∞' : compactMoney(available)}</strong><small>до дневного лимита</small></div>
            <div className={`provider-status provider-status--${state.tone}`}><state.Icon size={15} /> {state.label}</div>
          </article>
        )
      })}
      <div className="matrix-legend"><span><i /> фактическая доля</span><span><em /> целевая доля</span></div>
    </section>
  )
}
