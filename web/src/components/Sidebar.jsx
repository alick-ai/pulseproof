import { Activity, CheckCircle2, FileSearch2, GitCompareArrows, ListTree, ShieldCheck } from 'lucide-react'
import BrandMark from './BrandMark.jsx'

const items = [
  { id: 'live', label: 'Live routing', icon: Activity },
  { id: 'replay', label: 'Replay arena', icon: GitCompareArrows },
  { id: 'decisions', label: 'Decisions', icon: ListTree },
  { id: 'policy', label: 'Policy', icon: ShieldCheck },
  { id: 'validation', label: 'Validation', icon: FileSearch2 },
]

export default function Sidebar({ active, onSelect }) {
  return (
    <aside className="sidebar">
      <button className="sidebar__brand" onClick={() => onSelect('live')} aria-label="Open live routing">
        <span>PulseProof</span>
        <BrandMark />
      </button>

      <nav className="sidebar__nav" aria-label="Primary navigation">
        {items.map(({ id, label, icon: Icon }) => (
          <button
            key={id}
            className={`nav-item ${active === id ? 'is-active' : ''}`}
            onClick={() => onSelect(id)}
          >
            <Icon size={18} strokeWidth={1.65} />
            <span>{label}</span>
          </button>
        ))}
      </nav>

      <div className="sidebar__runtime">
        <div className="runtime-title"><span className="status-dot status-dot--ok" /> CONTROL PLANE</div>
        <dl>
          <div><dt>Mode</dt><dd>offline-safe</dd></div>
          <div><dt>Runtime</dt><dd>Ruby 2.6+</dd></div>
          <div><dt>State</dt><dd><CheckCircle2 size={12} /> healthy</dd></div>
        </dl>
        <div className="runtime-version">v1.0.0</div>
      </div>
    </aside>
  )
}
