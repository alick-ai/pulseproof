import { CircleDot, Zap } from 'lucide-react'

export default function ScenarioSwitch({ scenario, onChange }) {
  return (
    <div className="scenario-switch" role="tablist" aria-label="Runtime scenario">
      <button role="tab" aria-selected={scenario === 'live'} className={scenario === 'live' ? 'is-active' : ''} onClick={() => onChange('live')}>
        <CircleDot size={14} /> Live run
      </button>
      <button role="tab" aria-selected={scenario === 'chaos'} className={scenario === 'chaos' ? 'is-active is-chaos' : ''} onClick={() => onChange('chaos')}>
        <Zap size={14} /> Chaos run
      </button>
    </div>
  )
}
