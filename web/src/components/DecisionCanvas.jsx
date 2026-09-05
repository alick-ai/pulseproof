import { Check, CircleDot, Filter, GitBranch, LockKeyhole, RadioTower } from 'lucide-react'
import ProviderRails from './ProviderRails.jsx'
import { money, shortTime } from '../utils.js'

const stages = [
  { label: 'Snapshot', icon: RadioTower, meta: 'immutable' },
  { label: 'Hard Gate', icon: Filter, meta: 'safety' },
  { label: 'Vector Deficit', icon: GitBranch, meta: 'minimax' },
  { label: 'Reserve', icon: LockKeyhole, meta: 'atomic' },
  { label: 'Reconcile', icon: CircleDot, meta: 'event-ledger' },
]

export default function DecisionCanvas({ operation, frame, providers }) {
  const decision = frame.decision
  const hasTimeout = decision.attempts.some((attempt) => attempt.decision === 'selected' && attempt.result === 'expired')

  return (
    <section className="decision-canvas" aria-labelledby="current-operation-title">
      <div className="current-operation">
        <div className="panel-heading panel-heading--inline">
          <div>
            <h2 id="current-operation-title">CURRENT OPERATION</h2>
            <code>{operation.operation_id}</code>
          </div>
          <div className="operation-facts">
            <span><small>Amount</small>{money(operation.amount)}</span>
            <span><small>Bank</small>{operation.bank}</span>
            <span><small>Arrived</small>{shortTime(operation.created_at)}</span>
            <span><small>Attempts</small>{decision.attempts.filter((item) => item.decision === 'selected').length}</span>
          </div>
        </div>

        <div className={`pipeline ${hasTimeout ? 'pipeline--timeout' : ''}`}>
          {stages.map(({ label, icon: Icon, meta }, index) => (
            <div className="pipeline__part" key={label}>
              <div className="pipeline__stage">
                <span className="pipeline__number">{index + 1}</span>
                <Icon size={18} strokeWidth={1.6} />
                <span><strong>{label}</strong><small>{hasTimeout && label === 'Reconcile' ? 'late cancel' : meta}</small></span>
                {label === 'Reconcile' && <Check className="pipeline__check" size={15} />}
              </div>
              {index < stages.length - 1 && <div className="pipeline__connector"><span /></div>}
            </div>
          ))}
        </div>
      </div>

      <ProviderRails providers={providers} frame={frame} />
    </section>
  )
}
