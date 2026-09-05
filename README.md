# PulseProof

PulseProof is a Ruby online payout-routing engine and simulator built for the Hack.Genesis 2026 “Умный роутинг выплат” case. The submission runs without the dashboard or external APIs. It is not a connected banking service.

It does not optimize a known batch. Every operation is routed sequentially from the state available at that moment. Hard constraints form a safety gate; soft count and volume goals are reconciled by bounded deficit controllers; capacity is reserved before a provider request; timeout remains pending until a status event resolves it; late cancellation releases capacity and produces a compensating event rather than rewriting history.

## Challenge the decision before looking at the pitch

The experimental planner answers three testable questions: can a forbidden provider be made eligible by changing weights (**no**); what single weight change makes a legal alternative win; and which modeled consequences explain the original choice. `challenge` calculates and verifies a switching boundary on a saved snapshot. It does not deploy a policy or send a payout.

Prepare `rake jury` before the presentation, then run the short checks live:

```bash
bin/pulseproof evidence --human
bin/pulseproof challenge op_103 --prefer vipay --human --report outputs/planner-report.json
bin/pulseproof challenge op_101 --prefer vipay --factor count_potential_change --human --report outputs/planner-report.json
bin/pulseproof explain op_101 --decisions outputs/planner-decisions.json --report outputs/planner-report.json
```

`evidence` executes 31 public, deterministic examples instead of displaying a checklist: 14 hard-rule gates, 8 isolated soft-factor winner flips, 7 streaming-runtime invariants and 2 inverse-decision challenges. The first challenge answer is `not_eligible`: the 150,000-ruble payment exceeds vipay's 100,000-ruble limit. A soft objective cannot overrule that gate. For op_101, `challenge` calculates the legal alternative's winning regions and verifies a proposed change from the current count weight of 0.6. On the current public snapshot, **0.7985512111061965** selects vipay while the adjacent lower Float **0.7985512111061964** still selects payflow; the actual router reproduces the switch. The continuation is reoptimized for every tested weight. `--human` gives concise Russian output; omitting it preserves the full JSON output, including exact boundaries. See the short walkthrough in [`docs/JURY_DEMO.md`](docs/JURY_DEMO.md).

## Stopcode: generate, commit, verify publication

**The default submission policy remains `config/balanced.json`, not the experimental planner.** The public validator yields 28/29 on the planner's probabilistic run when op_104 legally falls back after quickpay rejects. The separately labeled no-rejection `approve` simulation yields 29/29. That compatibility check is not an outage-quality result, and the hidden validator's behavior is unknown. Experimental reports stay in separate paths.

Before the organizer queue arrives, commit and push the final source on `main`, make sure the worktree is clean, then run the full gate once:

```bash
rake arm_stopcode
```

This writes an ignored local receipt bound to the exact `main` commit, its tree, the local `origin/main` tracking ref and the current Ruby runtime. At preflight time it also reads the real remote `origin/main` and requires the same commit. It succeeds only after the complete tests, validators, evidence suite, privacy checks and frontend build pass. It does not claim that the remote server remains reachable or unchanged later; verify the final publication separately.

Put the file issued by the organizers in the repository root with its original name:

```text
operations_queue_test.json
```

Then use the queue-dependent fast path:

```bash
rake stopcode
```

The fast gate verifies that code, configuration, tests, commit and Ruby version still match the fully tested receipt. Only the ignored organizer queue and the two generated artifacts may differ. It then routes every operation, strictly validates coverage and hard limits, checks private data and file layout, and writes the required files in the repository root (each file uses atomic replacement; the pair is not one filesystem transaction):

- `routing_decisions_test.json`
- `routing_report_test.json`

If the receipt is missing or anything in the source tree changed, `rake stopcode` stops. Run the conservative full path instead (or remove the organizer queue, commit/push the intended source, and arm it again):

```bash
rake submit
```

For a direct run without either Rake safety gate:

```bash
bin/pulseproof submit
```

The command prints `[STOPCODE TEST]` beside the selected queue. Both submission commands block the normal public-sample path when a file named `operations_queue_test.json` is missing. The filename does not establish authenticity: use the actual file issued by the organizers, not a renamed sample. Use `bin/pulseproof run` while developing against the public sample.

Both Rake paths finish with a local-generation status, not a delivery-ready claim. Review and commit the code and both JSON files on `main`, then run:

```bash
rake submission_git
```

This read-only check requires a real `HEAD` commit, both required JSON blobs in its root, matching index/worktree bytes, and validation against the selected organizer queue. It does not regenerate files, create commits, or push. `LOCAL_ARTIFACTS_COMMITTED` concerns these two artifacts only; publication and the completeness of the committed source code must be checked separately. A local `rake release` or `submission_layout` pass does **not** establish Git delivery. Confirm the final commit and both files in the repository actually submitted to the organizers.

Before stopcode, rehearse the exact generate → commit → push → Git-check path without touching the repository or its remote:

```bash
rake rehearse_submission
```

The rehearsal refuses a dirty source tree or a real root stopcode file, creates a disposable clone and disposable local bare remote, runs `rake arm_stopcode`, derives a synthetic queue from the public sample only inside that clone, times the real `rake stopcode`, commits and pushes the two changed output artifacts there, verifies `rake submission_git`, compares local and remote commit hashes, and removes the clone. The ignored input queue and receipt remain local to the disposable clone. This proves the mechanics and measures the queue-time critical path, not the unknown organizer queue or external GitHub availability.

Inspect any decision without opening the optional dashboard:

```bash
bin/pulseproof explain op_103
```

The router never receives future operations. `Runner` iterates the queue and calls `Router#route` once per current operation.

See [`JURY_GUIDE.md`](JURY_GUIDE.md) for the exact evaluation path and the 60-second technical walkthrough.
See [`docs/TECHNICAL_AUDIT.md`](docs/TECHNICAL_AUDIT.md) for the source review, reproduced defects, fixes and remaining limits. Passing local tests is not evidence of winning the hidden evaluation.

## Experimental capacity protection

`bin/pulseproof lab` searches a bounded family of synthetic examples where consuming a flexible provider's capacity removes the last external route for a historical payment shape. It compares baseline and protected routing, including the unfavorable branch where that rare payment never arrives. Output is isolated in `outputs/capacity-lab.json`.

The optional `config/resilience.json` profile protects historical-shape coverage using current snapshots, without passing future operations to the router. It may worsen count targets and is **not** enabled in the default submission policy. See [`docs/CAPACITY_GUARD.md`](docs/CAPACITY_GUARD.md) for the runnable example, budgets and limitations.

## Learning from confirmed outcomes

`config/adaptive.json` enables contextual online adaptation by provider, bank, card brand and amount band. Confirmed responses update recency-weighted estimates; unknown timeouts do not count as failures. The policy prioritizes goal balancing until there is evidence of degradation, then uses the configured quality/goal trade-off. Every accepted learning observation is linked to a terminal attempt in the audit journal.

Run the isolated three-policy experiment:

```bash
bin/pulseproof learn-lab --lab-seeds 404,505,606 --lab-output outputs/adaptive-holdout-v2.json
```

The lab compares the original balanced policy, a frozen adaptive-policy control, and online learning against identical hidden synthetic response mechanisms. It reports both first-attempt success and final share deviation. There is no universal uplift: the tested adaptive profile improves outage scenarios but loses to balanced in the stable scenario. It is **not** enabled in the default submission policy or browser replay. See [`docs/ADAPTIVE_ROUTING.md`](docs/ADAPTIVE_ROUTING.md) for the mechanism, reproducible results and deployment boundaries.

## Outcome-aware cascade planning

`config/planner.json` replaces the final ranking with cascade-consequence evaluation: expected final provider attribution, count/volume debt, retries, latency, pending exposure and shared-capacity stress. It executes only the first step and replans after a confirmed failure. A two-speed estimator retains yesterday's compatible history while tracking recent responses separately. An independent arithmetic verifier checks exported cascade explanations.

The cascade optimizer uses exact rational pair-exchange comparisons over the exported frozen additive model, not a truncated permutation prefix. It produces the optimal continuation for every legal first action. Thus `all_external_orders_evaluated: false` does not imply approximation: `optimization.exact_for_frozen_model: true` states the separate, model-conditional guarantee. The independent verifier checks each continuation's pair inequalities, exact ranking and local coefficients against the snapshot without calling the optimizer. The guarantee is about solving this objective, not knowing true provider probabilities or optimizing an unknown future stream.

```bash
bin/pulseproof run --policy config/planner.json --decisions outputs/planner-decisions.json --report outputs/planner-report.json
bin/pulseproof explain op_101 --decisions outputs/planner-decisions.json --report outputs/planner-report.json
bin/pulseproof plan-lab --lab-seeds 713,947,1201 --lab-output outputs/planner-exact-holdout.json
```

Recommendations test bounded limit changes in an isolated historical-capacity stress model; they never change real provider rules. This is a model-based experimental profile, not universally superior or enabled in the default dashboard/submission. The five-scenario benchmark was rerun after the exact solver change: all 60 runs validated, and the four non-timing summary metrics matched the previous report across all 20 scenario/policy combinations, including losses in the stable and capacity-pressure scenarios. This repeats the same seeds, not a new independent sample. Equal final count-L1 across its policies is an observation on those synthetic streams, not an architectural guarantee: count/volume remain soft objectives. The public all-approved sensitivity check was also repeated through the real runtime and verified reports after the solver change: count weights 0 / 0.6 / 0.8 give count-L1 of 50 / 30 / 10 percentage points; 0.6 therefore balances this queue worse than balanced. See [`docs/OUTCOME_PLANNER.md`](docs/OUTCOME_PLANNER.md) for full results, formulas, assumptions and limitations.

The factorial search was removed, but an end-to-end speedup is not established. The new benchmark ran concurrently with tests, so its timing includes uncontrolled resource contention; neither those timings nor the exact-model guarantee constitute a production SLA. The original `outputs/planner-holdout.json` is retained alongside the new `outputs/planner-exact-holdout.json`.

`rake jury` runs tests and prepares the public walkthrough, including inverse routing. Run it and the longer `plan-lab` before presenting; the live demo uses only `challenge` and `explain` over prepared reports. This is an explainability tool, not automatic policy deployment or a future-performance guarantee.

For the short Russian walkthrough and verified results, see [`docs/JURY_DEMO.md`](docs/JURY_DEMO.md).

## Streaming runtime, independent of the dashboard

```bash
bin/pulseproof stream --policy config/cascade.json --outcomes examples/runtime_outcomes.json < examples/runtime_events.jsonl
```

Each input line is one event; each output line is its result. No queue file is read. The example sends A (timeout), sends B (approved), disables payflow, confirms cancellation of A, then sends a stale approval for A's old attempt. Only A is rerouted on the fresh state, and the stale status is recorded as ignored. The last event builds and independently checks the report.

Supported messages: `operation`, `provider_update`, `status`, `report`. A status must carry operation ID, provider, attempt number and event ID. Duplicate identical requests do not send again; an ID reused with different payment data is rejected. Control updates can change routing rules but cannot overwrite balances owned by the ledger.

This interface uses logical event timestamps and in-memory state. Provider responses in the supplied example are scripted. There is no real bank integration, restart recovery or multi-process transaction coordinator. Do not use it to send real funds.

## Full release gate

The experimental planner also exports a read-only [dependence certificate](docs/DEPENDENCE_CERTIFICATE.md): sharp Fréchet success/failure bounds conditional on supplied marginals, a separate independence reference, and the fallback's contribution to the success lower bound. Pending explicitly disables these bounds. An independent verifier checks the certificate before CLI explanation. This does **not** change routing or prove order optimality under arbitrary dependence; the default submission policy remains balanced.

Install the dashboard dependencies once:

```bash
cd web && npm install && cd ..
```

Then run:

```bash
rake release
```

The gate runs the Ruby test suite, generates both submission files, checks them with the strict validator and the official public validator, scans outputs for all sensitive queue values, verifies the Ruby-majority threshold, executes the 31-case requirements evidence, regenerates the demo trace, lints the interface and creates a production build.

Last verified test suite: **196 tests, 6334 assertions, no failures.** The complete release gate is rerun after every delivery change; its additional checks cover executable requirements evidence 31/31, official public balanced validation 29/29, authored Ruby share 75.0%, privacy, lint and production build. The locale regression suite also runs fresh CLI subprocesses with unset, C, POSIX and UTF-8 locale variables. These are local checks, not evidence of hidden-test success.

The normal suite also starts the CLI tests in fresh subprocesses under unset, C, POSIX and UTF-8 locales. UTF-8 file/pipe decoding is explicit in those tests; `Encoding.default_external` is not globally overridden. Reproduce the strict locale check with:

```bash
LC_ALL=C LANG=C LC_CTYPE=C rake release
```

## Live demo

```bash
bin/pulseproof demo
cd web
npm run dev
```

Open `http://127.0.0.1:4173`.

The console exposes two runs generated by the same engine:

- **Live run** — a precomputed simulation of the official public queue: 40/30/30 count distribution. The count-only hindsight bound is 10 percentage points of L1 deviation; this run reaches it. This does not prove a global optimum across quality, cost, volume or unknown future operations.
- **Chaos run** — an injected `op_106` timeout, late cancel, reservation release and reroute from `vipay` to `quickpay`.

Chaos opens on the exceptional operation so a judge sees the core safety story immediately. **Запустить демо** first replays the queue operation by operation, then slows down into six synchronized runtime events: reserve, timeout, confirmed cancel, compensating release, fresh-snapshot reroute and approval. The explanation and provider matrix change with the event, so the screen never uses future knowledge to justify a past decision. During a pitch, any of the six route nodes can be clicked to pause and inspect that exact state. The first-screen evidence band is generated by the Ruby engine and exposes the verified op_101 switching boundary, the op_103 hard veto, the 31/31 executable matrix and one isolated load-only winner flip. Its **Устойчивость** tab shows the complete exact-model cascade, the independence reference and sharp dependence-free outcome bounds; the existing strategy comparison remains a separate tab.

The Shadow Replay area compares deterministic weighted random, conversion-first and PulseProof using the same Router, HardGate and Ledger with separate states and immediate approved outcomes. “Expected” is a proxy derived from snapshot conversion, not observed success uplift. One queue and one random seed cannot establish statistical superiority. Every operation also has a downloadable decision-proof JSON containing sanitized snapshots, candidate evaluations, reservations and event-chain head.

## Architecture

```text
operation event
    ↓
current immutable snapshot
    ↓
HardGate → structured RuleResult for every provider
    ↓
DeficitController → bounded count/volume debt + anti-windup
    ↓
Router → lexicographic minimax + quality tie-breakers
    ↓
Ledger.reserve! → capacity reserved under one Router's in-process lock
    ↓
AttemptStateMachine
    ├── approved → committed settlement
    ├── rejected/cancelled → release → fresh-state reroute
    └── timeout → pending → status event → commit or release
    ↓
Decision Proof Capsule + required JSON + replay trace
```

Important components:

- `HardGate` — status, amount, daily/in-progress limits, requisites, RPM, margin, bank and card rules.
- `MetricTrustGate` — excludes future/unavailable outcomes and incompatible amount/bank/card rows from calibration; retains exclusion diagnostics. Its blended estimate is a posterior mean, not a statistical lower confidence bound.
- `DeficitController` — deterministic bounded-debt heuristic with count/volume objectives and a recovery cap; raw business debt is reported separately from bounded control debt.
- `Ledger` — separate reservation and settlement truth, idempotent status events and a SHA-256 event chain.
- `StrictValidator` + `AuditReplay` — verify coverage, final attempts, snapshot hashes and the ordered ledger; independently reconstruct reservations, settlements, RPM and balances against the original inputs. Reports must agree with the reconstructed state.
- `FeasibilityEnvelope` — bounded post-run count-only exhaustive search using the same HardGate. Never used during routing; does not claim exactness on failed attempts, changing rules or exhausted search budget.

## Policy profiles

Routing behavior is configured in `config/balanced.json`, not hard-coded in the router. The profile declares the selection mode, controller bounds, recovery rate, conversion guardrail and explicit weights for count, volume, conversion, load, margin, priority, preferred amount bands and minimum-turnover pressure. Alternative `cascade`, `conversion_first` and `weighted_sum` profiles demonstrate that the same engine changes policy without changing routing code.

Missing optional provider fields have safe semantics:

- missing `volume_share_pct` disables the volume target;
- missing RPM or turnover limits means the specific limit is unbounded;
- `traffic_percentage: 0` excludes a normal provider from routing;
- `spacepayments` is selected only after the external pool is empty or exhausted by confirmed failures.

The default balanced profile does not invent a volume target absent from the provider data. Other profiles contain explicitly illustrative volume targets. Amount bands in balanced follow the task's example, not a discovered business optimum. `redistribute_unavailable: true` is an optional policy for redistributing current entitlement among eligible providers; it is off by default because it changes the business objective. Neither policy erases raw deviation from original targets.

## Operational boundary

- Money accumulation and capacity comparisons use integer kopecks internally; JSON amounts remain in rubles.
- Atomicity and idempotency cover one live Router instance. They do not survive a process restart.
- Exported hash chains detect inconsistency but are not signed provider receipts. Audit replay needs the original input snapshot and operations, not the journal alone.
- A full external financial snapshot needs a version/watermark reconciliation contract; overwriting internal balances is deliberately rejected.
- The simulation does not implement midnight/day rollover, provider HTTP authentication, durable outbox, status polling or cross-process locks.
- If even fallback violates hard limits, routing fails closed; a production deployment still needs a durable deferred-payment queue and operational handling.

## Output semantics

`selected_provider` is the final provider that accepted the payout after fallback. Share is calculated over the issued queue from these final providers. Initial daily state comes from `providers.json`; history is used only for calibrated quality signals and is not mixed into the test share denominator.

The public run defaults to deterministic `approve` outcomes because no real status tape is supplied. Fallback and timeout behavior are executed by the test suite and the separately labeled chaos trace. A deterministic probabilistic `OutcomeModel` is also available for experiments.

## Privacy and constraints

- The payout requisite is removed before snapshots or proof capsules are recorded.
- A release fails if any phone from the input queue appears in decisions, report or browser data.
- The project is self-contained at runtime and uses no hosted decision services or proprietary runtime components.
- Ruby is the clear majority of authored source code; `rake release` enforces the written `>50%` requirement.

## Repository map

```text
bin/pulseproof               CLI
config/balanced.json         routing policy
data/                        official public inputs
lib/pulseproof/              Ruby control plane
scripts/validate_10.rb       official public validator
test/                        unit, invariant and integration tests
web/                         React/Vite replay console
routing_decisions_test.json  required submission output
routing_report_test.json     required analytics output
```
