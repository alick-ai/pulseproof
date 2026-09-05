import { Scale } from 'lucide-react'

const strategies = [
  { id: 'pulseproof', name: 'PulseProof', hint: 'умный роутинг', featured: true },
  { id: 'conversion_first', name: 'Conversion first', hint: 'максимум конверсии' },
  { id: 'random_split', name: 'Random split', hint: 'случайное распределение' },
]

export default function StrategyBand({ traces }) {
  const finals = strategies.map((strategy) => ({ ...strategy, value: traces[strategy.id]?.at(-1) }))
  const maxError = Math.max(...finals.map((item) => item.value?.deviation_l1_pp || 0), 1)
  return (
    <section className="strategy-band" aria-labelledby="strategy-title">
      <div className="section-heading strategy-heading"><h2 id="strategy-title"><Scale /> Сравнение стратегий</h2><span>одна очередь · одинаковые ограничения</span></div>
      <div className="strategy-table">
        <div className="strategy-table__head"><span>Стратегия</span><span>Отклонение от цели</span><span>Ожидаемая успешность</span></div>
        {finals.map((strategy) => (
          <div className={`strategy-row ${strategy.featured ? 'is-featured' : ''}`} key={strategy.id}>
            <div><i /><strong>{strategy.name}</strong><small>{strategy.hint}</small></div>
            <div className="strategy-error"><span><i style={{ width: `${(strategy.value.deviation_l1_pp / maxError) * 100}%` }} /></span><strong>{strategy.value.deviation_l1_pp.toFixed(0)} п.п.</strong></div>
            <strong className="strategy-success">{strategy.value.expected_settlement_pct.toFixed(1)}%</strong>
          </div>
        ))}
      </div>
    </section>
  )
}
