import { Check, Clipboard, Download, ShieldCheck } from 'lucide-react'
import { useState } from 'react'
import { shortHash, shortTime } from '../utils.js'

export default function ProofDrawer({ operation, frame }) {
  const [copied, setCopied] = useState(false)
  const proofPacket = {
    operation,
    decision: frame.decision,
    proof: frame.proof,
  }
  const proofJson = JSON.stringify(proofPacket, null, 2)

  const copyProof = async () => {
    await navigator.clipboard?.writeText(proofJson)
    setCopied(true)
    window.setTimeout(() => setCopied(false), 1400)
  }

  const downloadProof = () => {
    const url = URL.createObjectURL(new Blob([proofJson], { type: 'application/json' }))
    const anchor = document.createElement('a')
    anchor.href = url
    anchor.download = `${operation.operation_id}-decision-proof.json`
    anchor.click()
    URL.revokeObjectURL(url)
  }

  return (
    <section className="proof-drawer" aria-labelledby="proof-title">
      <div className="section-heading proof-heading"><h2 id="proof-title"><ShieldCheck /> Доказательство решения</h2><span>воспроизводимо</span></div>
      <dl className="proof-summary">
        <div><dt>Алгоритм</dt><dd>Bounded minimax v1.0</dd></div>
        <div><dt>Время снимка</dt><dd>{shortTime(operation.created_at)} MSK</dd></div>
        <div><dt>Попыток</dt><dd>{frame.proof.reservations?.length || 1}</dd></div>
      </dl>
      <div className="proof-hash"><span>Хэш цепочки событий</span><div><code>{shortHash(frame.proof.event_head, 42)}</code></div></div>
      <div className="proof-actions">
        <button onClick={copyProof}>{copied ? <Check /> : <Clipboard />}{copied ? 'Скопировано' : 'Копировать proof'}</button>
        <button onClick={downloadProof}><Download />Экспорт JSON</button>
      </div>
      <details>
        <summary>Показать детали доказательства</summary>
        <dl className="proof-details">
          <div><dt>Snapshot</dt><dd><code>{frame.proof.snapshot_hash}</code></dd></div>
          <div><dt>Policy</dt><dd>{frame.proof.policy_profile}</dd></div>
          <div><dt>Событий</dt><dd>{frame.event_ids?.length || 0}</dd></div>
          <div><dt>PII</dt><dd>удалены до журналирования</dd></div>
        </dl>
      </details>
    </section>
  )
}
