# PulseProof UI v2

Visual reference: `docs/pulseproof-ui-concept-v2.png`.

## Primary story

The screen must answer four questions in order, without requiring technical knowledge:

1. Which payout is being processed?
2. What happened to every attempt?
3. Why was the final provider selected?
4. Can the decision be independently checked?

## Layout

- Quiet white command bar: product, scenario switch, validation state, one playback action.
- Left queue: ten official operations with amount and state; selected operation is obvious.
- Center operation stage: large amount/bank and a route line showing attempt, timeout, confirmed cancellation, capacity release, fallback and approval.
- Center provider comparison: hard-rule result, target/actual traffic, conservative reliability, available daily capacity and final state.
- Right explanation: three plain-language reasons and an oversized final provider.
- Bottom: full-queue policy comparison and expandable proof hashes.

## Tokens

- Background `#f4f7fb`, primary surfaces `#ffffff`, subtle surfaces `#f8fafc`.
- Ink `#101828`, secondary `#667085`, hairline `#dbe2ea`.
- Cobalt `#176bff`, success `#16a34a`, warning `#f59e0b`, failure `#ef4444`.
- Sans typography throughout; monospace only for operation ids and hashes.
- Body/control text 13–16px; operation value 50px; no tiny terminal labels.
- 12px radii on major functional surfaces, 8px on controls and rows.

## Allowed first-viewport copy

`PulseProof`, `Умный роутинг выплат`, `Live`, `Chaos`, `Все проверки пройдены`, `Запустить демо`, `Очередь`, `Операция`, `Жёсткие ограничения`, `Баланс трафика`, `Надёжность`, `Свободный лимит`, `Почему`, `Итоговый провайдер`, `Сравнение стратегий`, `Доказательство решения`.

## Responsive behavior

- Desktop: queue / decision / explanation columns, bottom comparison band.
- Tablet: queue becomes a horizontal rail; explanation sits beside or below the decision.
- Mobile: every region stacks; provider rows become readable summaries; no document-level horizontal overflow.
