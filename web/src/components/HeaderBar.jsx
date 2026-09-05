import { Activity, CheckCircle2, Pause, Play, Zap } from 'lucide-react'

export default function HeaderBar({ scenario, onScenarioChange, playing, onToggleDemo, progress }) {
  return (
    <header className="command-bar">
      <div className="command-bar__brand">
        <strong>PulseProof</strong>
        <Activity aria-hidden="true" />
      </div>
      <div className="command-bar__title">Умный роутинг выплат</div>

      <div className="scenario-tabs" role="tablist" aria-label="Сценарий демонстрации">
        <button role="tab" aria-selected={scenario === 'live'} className={scenario === 'live' ? 'is-active' : ''} onClick={() => onScenarioChange('live')}>
          <span className="dot dot--green" /> Live
        </button>
        <button role="tab" aria-selected={scenario === 'chaos'} className={scenario === 'chaos' ? 'is-active is-chaos' : ''} onClick={() => onScenarioChange('chaos')}>
          <Zap size={18} /> Chaos
        </button>
      </div>

      <div className="validation-state"><CheckCircle2 /> Все проверки пройдены</div>
      <button className="demo-button" onClick={onToggleDemo}>
        {playing ? <Pause size={18} fill="currentColor" /> : <Play size={18} fill="currentColor" />}
        {playing ? 'Пауза' : 'Запустить демо'}
      </button>
      <div className="playback-progress" aria-label={`Демо выполнено на ${Math.round(progress * 100)}%`}><i style={{ width: `${progress * 100}%` }} /></div>
    </header>
  )
}
