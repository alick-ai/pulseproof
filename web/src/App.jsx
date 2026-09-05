import { useEffect, useMemo, useState } from 'react'
import DecisionStage from './components/DecisionStage.jsx'
import EvidenceBand from './components/EvidenceBand.jsx'
import HeaderBar from './components/HeaderBar.jsx'
import OperationQueue from './components/OperationQueue.jsx'
import ProofDrawer from './components/ProofDrawer.jsx'
import ProviderMatrix from './components/ProviderMatrix.jsx'
import WhyPanel from './components/WhyPanel.jsx'

function App() {
  const [data, setData] = useState(null)
  const [error, setError] = useState(null)
  const [scenario, setScenario] = useState('chaos')
  const [activeIndex, setActiveIndex] = useState(5)
  const [playbackPhase, setPlaybackPhase] = useState(5)
  const [playing, setPlaying] = useState(false)

  useEffect(() => {
    fetch('/demo-data.json')
      .then((response) => {
        if (!response.ok) throw new Error(`HTTP ${response.status}`)
        return response.json()
      })
      .then(setData)
      .catch((reason) => setError(reason.message))
  }, [])

  const scenarioData = data?.[scenario]
  const maxIndex = Math.max(0, (data?.operations?.length || 1) - 1)

  useEffect(() => {
    if (!playing || !data) return undefined
    const timer = window.setTimeout(() => {
      if (scenario === 'chaos' && activeIndex === 5 && playbackPhase < 5) {
        setPlaybackPhase((current) => current + 1)
        return
      }
      if (activeIndex >= maxIndex) {
        setPlaying(false)
        return
      }
      const nextIndex = activeIndex + 1
      setActiveIndex(nextIndex)
      setPlaybackPhase(scenario === 'chaos' && nextIndex === 5 ? 0 : 5)
    }, scenario === 'chaos' && activeIndex === 5 ? 1050 : 760)
    return () => window.clearTimeout(timer)
  }, [playing, data, maxIndex, scenario, activeIndex, playbackPhase])

  const frame = useMemo(() => scenarioData?.frames?.[activeIndex], [scenarioData, activeIndex])
  const operation = data?.operations?.[activeIndex]

  const changeScenario = (next) => {
    setScenario(next)
    setActiveIndex(next === 'chaos' ? 5 : 0)
    setPlaybackPhase(5)
    setPlaying(false)
  }

  const toggleDemo = () => {
    if (playing) {
      setPlaying(false)
      return
    }
    if (activeIndex >= maxIndex || (scenario === 'chaos' && activeIndex === 5)) {
      setActiveIndex(0)
      setPlaybackPhase(5)
    }
    setPlaying(true)
  }

  if (error) {
    return <main className="load-state"><h1>PulseProof</h1><p>Не удалось загрузить демо: {error}</p></main>
  }

  if (!data || !frame || !operation) {
    return <main className="load-state"><div className="loading-ring" /><h1>PulseProof</h1><p>Собираем журнал решений…</p></main>
  }

  return (
    <div className="product-shell">
      <HeaderBar
        scenario={scenario}
        onScenarioChange={changeScenario}
        playing={playing}
        onToggleDemo={toggleDemo}
        progress={(activeIndex + (scenario === 'chaos' && activeIndex === 5 ? (playbackPhase + 1) / 6 : 1)) / data.operations.length}
      />

      <main className="decision-theatre">
        <OperationQueue
          operations={data.operations}
          decisions={scenarioData.decisions}
          activeIndex={activeIndex}
          playbackPhase={playbackPhase}
          onSelect={(index) => { setActiveIndex(index); setPlaybackPhase(5); setPlaying(false) }}
        />

        <section className="operation-workspace" aria-label="Разбор текущей операции">
          <DecisionStage
            operation={operation}
            frame={frame}
            playbackPhase={playbackPhase}
            onPhaseSelect={(phase) => { setPlaybackPhase(phase); setPlaying(false) }}
          />
          <ProviderMatrix providers={data.providers} frame={frame} previousFrame={scenarioData.frames[activeIndex - 1]} report={scenarioData.report} playbackPhase={playbackPhase} />
        </section>

        <WhyPanel operation={operation} frame={frame} playbackPhase={playbackPhase} />
        <EvidenceBand evidence={data.evidence} traces={data.shadow_replay} />
        <ProofDrawer operation={operation} frame={frame} />
      </main>
    </div>
  )
}

export default App
