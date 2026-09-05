const stages = ['Snapshot', 'Hard Gate', 'Vector Deficit', 'Reserve', 'Reconcile']

export default function Lifecycle({ decision, compact = false, active = false }) {
  const selected = decision?.attempts?.filter((attempt) => attempt.decision === 'selected') || []
  const timedOut = selected.some((attempt) => attempt.result === 'expired')
  const failed = decision?.simulated_result === 'rejected'
  const tone = timedOut ? 'pending' : failed ? 'failed' : 'success'

  return (
    <div className={`lifecycle lifecycle--${tone} ${compact ? 'lifecycle--compact' : ''} ${active ? 'is-active' : ''}`}>
      {stages.map((stage, index) => (
        <div className="lifecycle__stage" key={stage}>
          <span className="lifecycle__node">{index + 1}</span>
          <span className="lifecycle__label">{stage}</span>
          {index < stages.length - 1 && <span className="lifecycle__rail" />}
        </div>
      ))}
      {timedOut && <span className="lifecycle__flag">TIMEOUT → RECONCILED</span>}
    </div>
  )
}
