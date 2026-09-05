import { compactMoney, PROVIDER_COLORS } from '../utils.js'

export default function ProviderRails({ providers, frame }) {
  const external = providers.filter((provider) => !provider.fallback)

  return (
    <div className="provider-rails">
      <div className="provider-rails__labels">
        <span>PROVIDER</span><span>TARGET / ACTUAL</span><span>COUNT</span><span>VOLUME</span><span>DEBT</span><span>STATUS</span>
      </div>
      {external.map((provider) => {
        const actual = frame.shares[provider.name] || 0
        const debt = frame.debt[provider.name] || 0
        const count = frame.counts[provider.name] || 0
        const amount = frame.amounts[provider.name] || 0
        const color = PROVIDER_COLORS[provider.name]
        return (
          <div className="provider-rail" key={provider.name} style={{ '--provider-color': color }}>
            <strong><span className="provider-dot" />{provider.name}</strong>
            <div className="share-rail" aria-label={`${provider.name} target ${provider.target_pct} actual ${actual}`}>
              <span className="share-rail__fill" style={{ width: `${Math.min(actual, 100)}%` }} />
              <span className="share-rail__target" style={{ left: `${provider.target_pct}%` }} />
              <small>{provider.target_pct}% <b>{actual}%</b></small>
            </div>
            <code>{count}</code>
            <code>{compactMoney(amount)} ₽</code>
            <code className={debt > 0 ? 'debt-positive' : debt < 0 ? 'debt-negative' : ''}>{debt > 0 ? '+' : ''}{debt.toFixed(2)}</code>
            <span className="eligibility"><span className="status-dot status-dot--ok" /> ELIGIBLE</span>
          </div>
        )
      })}
      <div className="rail-legend">
        <span><i className="legend-live" /> ACTUAL SHARE</span>
        <span><i className="legend-target" /> TARGET</span>
        <span>prefix {frame.index + 1} · debt is bounded</span>
      </div>
    </div>
  )
}
