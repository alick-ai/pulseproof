import { Check, Clipboard, Pause, Play, RotateCcw, StepForward } from 'lucide-react'

export default function TopBar({ policyHash, playing, onRun, onPause, onStep, onReset }) {
  const copyHash = () => navigator.clipboard?.writeText(policyHash || '')

  return (
    <header className="topbar">
      <div className="topbar__title">
        <span>LIVE ROUTING</span>
        <span className="live-state"><span className="status-dot status-dot--ok" /> LIVE</span>
      </div>

      <div className="topbar__actions">
        <button className="seed-control" onClick={copyHash} title="Copy policy hash">
          <span>Deterministic policy</span>
          <code>{policyHash?.slice(0, 12) || 'loading'}…</code>
          <Clipboard size={14} />
        </button>

        <div className="release-state">
          <Check size={17} />
          <span><small>Release validation</small>ALL CHECKS PASS</span>
        </div>

        <div className="run-controls" role="group" aria-label="Playback controls">
          <button className="icon-button" onClick={onReset} aria-label="Reset demo"><RotateCcw size={17} /></button>
          <button className="icon-button" onClick={onStep} aria-label="Step forward"><StepForward size={17} /></button>
          {playing ? (
            <button className="run-button" onClick={onPause}><Pause size={16} fill="currentColor" /> Pause</button>
          ) : (
            <button className="run-button" onClick={onRun}><Play size={16} fill="currentColor" /> Run demo</button>
          )}
        </div>
      </div>
    </header>
  )
}
