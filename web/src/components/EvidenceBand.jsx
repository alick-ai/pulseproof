import { Activity, ArrowRight, Gauge, GitBranch, LockKeyhole, Scale, ShieldCheck, ShieldQuestion } from 'lucide-react'
import { useMemo, useState } from 'react'
import { StrategyTable } from './StrategyBand.jsx'

const providerName = (value) => ({
  vipay: 'ViPay',
  payflow: 'PayFlow',
  quickpay: 'QuickPay',
  spacepayments: 'SpacePayments',
  alpha: 'Alpha',
  beta: 'Beta',
}[value] || value)

const shortChain = (chain = []) => chain.slice(0, 2).map(providerName).join(' → ')
const fixedWeight = (value) => Number(value).toFixed(6).replace('.', ',')
const fixedPercent = (value, digits = 2) => `${(Number(value) * 100).toFixed(digits).replace('.', ',')}%`
const initialView = () => {
  const requested = new URLSearchParams(window.location.search).get('panel')
  return ['evidence', 'robustness', 'strategies'].includes(requested) ? requested : 'evidence'
}

function RobustnessPanel({ plan }) {
  const certificate = plan.dependence_certificate
  return (
    <div className="robustness-grid">
      <article className="robustness-card robustness-card--chain">
        <div className="evidence-proof__label"><GitBranch /> Точный каскад · op_101</div>
        <div className="robustness-chain" aria-label={plan.chain.map(providerName).join(', затем ')}>
          {plan.chain.map((provider, index) => (
            <span key={provider}><b>{providerName(provider)}</b>{index < plan.chain.length - 1 ? <ArrowRight /> : null}</span>
          ))}
        </div>
        <strong className="robustness-cert"><ShieldCheck /> Точно для сохранённой модели</strong>
        <p>Порядок получен точным попарным правилом, без факториального перебора вариантов.</p>
      </article>

      <article className="robustness-card robustness-card--reference">
        <div className="evidence-proof__label"><Activity /> Если отказы независимы</div>
        <strong className="robustness-number">{fixedPercent(certificate.independent_reference.success, 3)}</strong>
        <span className="robustness-caption">расчётная успешность каскада</span>
        <small>Полный отказ: {fixedPercent(certificate.independent_reference.all_failed, 4)}</small>
      </article>

      <article className="robustness-card robustness-card--bounds">
        <div className="evidence-proof__label"><ShieldQuestion /> Без гипотезы о связи отказов</div>
        <div className="robustness-bounds">
          <strong>{fixedPercent(certificate.success_probability.lower, 0)}</strong>
          <span>—</span>
          <strong>{fixedPercent(certificate.success_probability.upper, 0)}</strong>
        </div>
        <p>Граница достижима при тех же оценках провайдеров. Нижние {fixedPercent(certificate.success_probability.lower, 0)} обеспечивает {providerName(certificate.lower_bound_drivers[0])}; внешний каскад повышает ожидание, но не эту гарантию.</p>
        <small>Сертификат оценивает исход, но не доказывает порядок при произвольной зависимости.</small>
      </article>
    </div>
  )
}

export default function EvidenceBand({ evidence, traces }) {
  const [view, setView] = useState(initialView)
  const indexed = useMemo(() => new Map((evidence?.cases || []).map((item) => [item.id, item])), [evidence])
  const boundary = indexed.get('challenge_weight_boundary')
  const veto = indexed.get('challenge_hard_veto')
  const load = indexed.get('soft_load')

  if (!evidence || !boundary || !veto || !load) return null

  const boundaryData = boundary.observed
  const vetoData = veto.observed
  const loadData = load.observed
  const summary = evidence.summary

  return (
    <section className="evidence-band" aria-labelledby="evidence-title">
      <div className="section-heading evidence-heading">
        <h2 id="evidence-title"><ShieldCheck /> Проверяемые свойства</h2>
        <div className="evidence-tabs" role="tablist" aria-label="Режим нижней панели">
          <button type="button" role="tab" aria-selected={view === 'evidence'} className={view === 'evidence' ? 'is-active' : ''} onClick={() => setView('evidence')}>Доказательства</button>
          <button type="button" role="tab" aria-selected={view === 'robustness'} className={view === 'robustness' ? 'is-active' : ''} onClick={() => setView('robustness')}><ShieldQuestion /> Устойчивость</button>
          <button type="button" role="tab" aria-selected={view === 'strategies'} className={view === 'strategies' ? 'is-active' : ''} onClick={() => setView('strategies')}><Scale /> Стратегии</button>
        </div>
      </div>

      {view === 'strategies' ? <StrategyTable traces={traces} /> : view === 'robustness' ? <RobustnessPanel plan={boundaryData.plan_context} /> : (
        <div className="evidence-grid">
          <article className="evidence-proof evidence-proof--boundary">
            <div className="evidence-proof__label"><Gauge /> Порог переключения · {boundaryData.operation_id}</div>
            <div className="evidence-weight"><strong>{fixedWeight(boundaryData.current_weight)}</strong><ArrowRight /><strong>{fixedWeight(boundaryData.proposed_weight)}</strong></div>
            <div className="evidence-route"><span>{shortChain(boundaryData.original_chain)}</span><ArrowRight /><b>{shortChain(boundaryData.verified_chain)}</b></div>
            <p>Соседнее машинное значение ещё оставляет прежний маршрут. Новое значение повторно проверено на всём каскаде.</p>
          </article>

          <article className="evidence-proof evidence-proof--veto">
            <div className="evidence-proof__label"><LockKeyhole /> Hard-veto · {vetoData.operation_id}</div>
            <strong className="evidence-verdict">{providerName(vetoData.provider)} не допущен</strong>
            <code>{vetoData.hard_reason}</code>
            <p>Мягкие коэффициенты не возвращают маршрут, нарушающий обязательное ограничение.</p>
          </article>

          <article className="evidence-proof evidence-proof--coverage">
            <div className="evidence-score"><strong>{summary.passed}/{summary.total}</strong><span>исполняемых проверок</span></div>
            <div className="evidence-causal">
              <span>Только нагрузка изменена</span>
              <strong>{providerName(loadData.before.winner)} <ArrowRight /> {providerName(loadData.after.winner)}</strong>
              <small>Оба кандидата прошли hard-gate</small>
            </div>
          </article>
        </div>
      )}
    </section>
  )
}
