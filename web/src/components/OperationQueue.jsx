import { Check, Clock3, List, RefreshCw } from 'lucide-react'
import { money } from '../utils.js'

function operationState(decision, index, activeIndex, playbackPhase) {
  if (index > activeIndex) return { label: 'В очереди', tone: 'muted', Icon: Clock3 }
  const timedOut = decision?.attempts?.some((attempt) => attempt.result === 'expired')
  if (timedOut && index === activeIndex && playbackPhase < 2) return { label: 'Ожидаем статус', tone: 'warning', Icon: Clock3 }
  if (timedOut) return { label: 'Перенаправлена', tone: 'warning', Icon: RefreshCw }
  return { label: index === activeIndex ? 'Обрабатывается' : 'Готово', tone: 'success', Icon: Check }
}

export default function OperationQueue({ operations, decisions, activeIndex, playbackPhase, onSelect }) {
  return (
    <aside className="operation-queue" aria-labelledby="queue-title">
      <div className="section-heading queue-heading">
        <h2 id="queue-title"><List size={20} /> Очередь</h2>
        <span>{operations.length}</span>
      </div>
      <div className="queue-list">
        {operations.map((operation, index) => {
          const state = operationState(decisions[index], index, activeIndex, playbackPhase)
          return (
            <button className={`queue-item ${index === activeIndex ? 'is-selected' : ''}`} onClick={() => onSelect(index)} key={operation.operation_id}>
              <span className="queue-item__index">{index + 1}</span>
              <span className="queue-item__identity">
                <code>{operation.operation_id}</code>
                <small>{operation.bank}</small>
              </span>
              <strong>{money(operation.amount)}</strong>
              <span className={`queue-item__state queue-item__state--${state.tone}`} title={state.label}><state.Icon size={17} /></span>
            </button>
          )
        })}
      </div>
      <p className="queue-note">Операции поступают последовательно. Роутер не видит будущую очередь.</p>
    </aside>
  )
}
