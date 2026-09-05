import { Check, Copy, ShieldAlert } from 'lucide-react'
import { shortHash, uniqueBy } from '../utils.js'

function exclusionRows(proof) {
  const all = (proof.hard_evaluations || []).flat().filter((row) => !row.eligible)
  return uniqueBy(all, (row) => `${row.provider}:${row.reason}`)
}

export default function ProofInspector({ frame }) {
  const proof = frame.proof
  const attempts = (frame.decision?.attempts || []).filter((attempt) => attempt.decision === 'selected')
  const exclusions = exclusionRows(proof)
  const ranking = proof.candidate_rankings?.at(-1) || []
  const winner = ranking.find((item) => item.provider === proof.winner) || ranking[0]
  const runner = ranking.find((item) => item.provider === proof.runner_up)
  const reservation = proof.reservations?.at(-1)
  const debtBefore = proof.debt_before_choice?.count_debt || {}
  const debtAfter = proof.debt_after?.count_debt || {}

  return (
    <aside className="proof-inspector" aria-labelledby="decision-proof-title">
      <div className="panel-heading panel-heading--inline proof-title">
        <div><ShieldAlert size={17} /><h2 id="decision-proof-title">DECISION PROOF</h2></div>
        <code>{shortHash(proof.snapshot_hash, 8)}</code>
      </div>

      <div className="proof-block proof-block--exclusions">
        <h3>HARD EXCLUSIONS <span>{exclusions.length}</span></h3>
        {exclusions.length ? exclusions.slice(0, 3).map((row) => (
          <div className="exclusion" key={`${row.provider}-${row.reason}`}>
            <span>{row.provider}</span><code>{row.reason}</code>
          </div>
        )) : <div className="proof-empty"><Check size={14} /> all external providers passed</div>}
      </div>

      <div className="proof-block">
        <h3>DEBT VECTOR <span>BEFORE → AFTER</span></h3>
        <div className="debt-vector">
          {Object.keys(debtBefore).filter((name) => name !== 'spacepayments').map((name) => (
            <div key={name}>
              <span>{name}</span>
              <code>{Number(debtBefore[name]).toFixed(2)}</code>
              <i>→</i>
              <code>{Number(debtAfter[name]).toFixed(2)}</code>
            </div>
          ))}
        </div>
      </div>

      <div className="proof-block proof-candidates">
        <div>
          <h3>WINNER</h3>
          <strong><span className="status-dot status-dot--ok" />{proof.winner}</strong>
          <code>regret {winner?.primary_regret ?? '0'}</code>
        </div>
        <div>
          <h3>RUNNER-UP</h3>
          <strong>{runner?.provider || '—'}</strong>
          <code>{runner ? `regret ${runner.primary_regret}` : 'only eligible'}</code>
        </div>
      </div>

      <div className="proof-block">
        <h3>ATTEMPT TRACE <span>{attempts.length} {attempts.length === 1 ? 'ATTEMPT' : 'ATTEMPTS'}</span></h3>
        <div className="attempt-trace">
          {attempts.map((attempt, index) => (
            <div className={`attempt-trace__item attempt-trace__item--${attempt.result}`} key={`${attempt.provider}-${index}`}>
              <span>{index + 1}</span>
              <strong>{attempt.provider}</strong>
              <code>{attempt.result === 'expired' ? 'TIMEOUT → CANCEL → RELEASE' : attempt.result?.toUpperCase()}</code>
            </div>
          ))}
        </div>
      </div>

      <div className="proof-block proof-reservation">
        <h3>RESERVATION</h3>
        <div><span>ID</span><code>{shortHash(reservation?.reservation_id, 17)}</code><Copy size={13} /></div>
        <div><span>Event head</span><code>{shortHash(proof.event_head, 17)}</code></div>
        <div><span>Winning factor</span><code>{proof.winning_factor?.replaceAll('_', ' ')}</code></div>
      </div>

      <div className="final-provider">
        <span>FINAL SELECTED PROVIDER</span>
        <strong>{proof.winner}</strong>
        <Check size={20} />
      </div>
    </aside>
  )
}
