import { ChevronRight } from 'lucide-react'
import Lifecycle from './Lifecycle.jsx'
import { money, shortTime } from '../utils.js'

export default function EventStream({ operations, decisions, activeIndex, onSelect }) {
  return (
    <section className="event-stream" aria-labelledby="event-stream-title">
      <div className="panel-heading event-stream__heading">
        <div>
          <h2 id="event-stream-title">EVENT STREAM</h2>
          <span>one operation · one current snapshot · no lookahead</span>
        </div>
        <span className="stream-progress">{String(activeIndex + 1).padStart(2, '0')} / {String(operations.length).padStart(2, '0')}</span>
      </div>

      <div className="event-table" role="table" aria-label="Payout operation stream">
        <div className="event-table__header" role="row">
          <span>TIME</span><span>EVENT ID</span><span>AMOUNT</span><span>BANK</span><span>PROVIDER</span><span>LIFECYCLE</span><span>STATUS</span>
        </div>
        {operations.map((operation, index) => {
          const decision = decisions[index]
          const isActive = index === activeIndex
          const isFuture = index > activeIndex
          const selectedAttempts = decision?.attempts?.filter((attempt) => attempt.decision === 'selected') || []
          const timedOut = selectedAttempts.some((attempt) => attempt.result === 'expired')
          return (
            <button
              className={`event-row ${isActive ? 'is-active' : ''} ${isFuture ? 'is-future' : ''} ${timedOut ? 'has-timeout' : ''}`}
              key={operation.operation_id}
              onClick={() => onSelect(index)}
              role="row"
            >
              <span className="event-row__time"><ChevronRight size={13} />{shortTime(operation.created_at)}</span>
              <code>{operation.operation_id}</code>
              <strong className="event-row__amount">{money(operation.amount)}</strong>
              <span className="event-row__bank">{operation.bank}</span>
              <span className="provider-name">{isFuture ? '—' : decision?.selected_provider}</span>
              <Lifecycle decision={decision} compact active={isActive} />
              <span className={`event-status ${isFuture ? '' : timedOut ? 'event-status--pending' : 'event-status--ok'}`}>
                {isFuture ? 'QUEUED' : timedOut ? 'RECONCILED' : 'SETTLED'}
              </span>
            </button>
          )
        })}
      </div>
    </section>
  )
}
