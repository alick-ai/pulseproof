import { ArrowRight, Gauge, LockKeyhole, Scale, ShieldCheck } from 'lucide-react'
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

export default function EvidenceBand({ evidence, traces }) {
  const [view, setView] = useState('evidence')
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
          <button type="button" role="tab" aria-selected={view === 'strategies'} className={view === 'strategies' ? 'is-active' : ''} onClick={() => setView('strategies')}><Scale /> Стратегии</button>
        </div>
      </div>

      {view === 'strategies' ? <StrategyTable traces={traces} /> : (
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
