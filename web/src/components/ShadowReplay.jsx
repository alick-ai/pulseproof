import { Crosshair, Dice5, Gauge } from 'lucide-react'
import { clamp } from '../utils.js'

const strategies = [
  { id: 'random_split', name: 'Random split', icon: Dice5 },
  { id: 'conversion_first', name: 'Conversion first', icon: Gauge },
  { id: 'pulseproof', name: 'PulseProof', icon: Crosshair, featured: true },
]

function points(values, key, width = 280, height = 54) {
  if (!values.length) return ''
  const max = Math.max(...values.map((item) => item[key]), 1)
  return values.map((item, index) => {
    const x = values.length === 1 ? 0 : index * width / (values.length - 1)
    const y = height - clamp(item[key] / max, 0, 1) * height
    return `${x.toFixed(1)},${y.toFixed(1)}`
  }).join(' ')
}

function MiniChart({ values }) {
  return (
    <svg viewBox="0 0 280 66" className="mini-chart" role="img" aria-label="Target deviation trajectory">
      <path d="M0 12H280 M0 33H280 M0 54H280" className="mini-chart__grid" />
      <polyline points={points(values, 'deviation_l1_pp')} className="mini-chart__line mini-chart__line--deviation" />
      <polyline points={points(values, 'expected_settlement_pct')} className="mini-chart__line mini-chart__line--success" />
    </svg>
  )
}

export default function ShadowReplay({ traces, activeIndex }) {
  return (
    <section className="shadow-replay" id="replay" aria-labelledby="shadow-title">
      <div className="panel-heading panel-heading--inline shadow-heading">
        <div><h2 id="shadow-title">SHADOW REPLAY</h2><span>same queue · same eligibility · different policy</span></div>
        <div className="chart-legend"><span className="chart-legend__success">EXPECTED SETTLEMENT</span><span className="chart-legend__deviation">TARGET ERROR</span></div>
      </div>
      <div className="strategy-grid">
        {strategies.map(({ id, name, icon: Icon, featured }) => {
          const values = traces[id].slice(0, activeIndex + 1)
          const last = values.at(-1) || { deviation_l1_pp: 0, expected_settlement_pct: 0 }
          return (
            <article className={`strategy ${featured ? 'strategy--featured' : ''}`} key={id}>
              <div className="strategy__top">
                <h3><Icon size={17} />{name}{featured && <small>LIVE</small>}</h3>
                <dl><div><dt>Target error</dt><dd>{last.deviation_l1_pp.toFixed(0)} pp</dd></div><div><dt>Expected</dt><dd>{last.expected_settlement_pct.toFixed(1)}%</dd></div></dl>
              </div>
              <MiniChart values={values} />
            </article>
          )
        })}
      </div>
    </section>
  )
}
