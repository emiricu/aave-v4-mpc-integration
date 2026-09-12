# Solvency MPC integration (thesis extension)

This document describes an addition to the Spoke that gates loan issuance on a
solvency verdict computed off-chain by a consortium of bank nodes via Secure
Multi-Party Computation (MP-SPDZ), published on-chain through a commit-reveal
protocol with **no relayer, oracle, or other intermediary**: every node sends
its own commit and reveal transactions directly to the contract. The Hub's
liquidity accounting, interest rates, collateral, LTV, and liquidation logic
are all unmodified.

This supersedes an earlier prototype design (documented in the sibling MPC
repository) built around a `CollateralRiskOracle` threshold-multisig contract
plus a `publisher` microservice that alone talked to the chain. That publisher
held only a gas-paying key and could never forge a quorum, but it was still a
single point of failure on *availability* — if it was down or censored,
nothing reached the chain even with a fully valid quorum of signatures ready.
The design here removes that role entirely: nodes publish for themselves.

## Update: the three-phase "hub replicato paritario" model

A later revision reframed the flow explicitly as three phases. Two of them
were already exactly what's described above; only the second gained new
on-chain behaviour.

1. **Local off-chain simulation (no on-chain footprint).** Before a node
   commits to signing consensus in phase 2, it should independently pre-validate
   — against a disposable local fork of the *real* shared Hub/Spoke state, not
   a second copy of the Hub with its own funds — whether the requested loan
   looks sustainable (health factor) *right now*, from its own point of view.
   A prototype of this lives in the sibling directory
   `~/tesi/aave-v4-mpc-node-sim/` (`simulate_borrow.py` — forks Sepolia with
   Anvil, replays the plain ungated `borrow()` on the fork, reads back
   `getUserAccountData().healthFactor`). Deliberately **not integrated** into
   the live `demo-node0/1/2` containers, and deliberately **not represented
   on-chain**: a node whose local simulation disagrees simply never submits
   its own commit, which the existing timeout/`BLOCKED` path already handles
   — no new contract state needed, and no attestation that would duplicate a
   guarantee the commit-reveal mechanism already provides at zero extra gas
   cost. See that directory's own `README.md` for exactly what a real
   integration into the node containers would still require.
2. **Family commit-reveal, extended with a synchronized reveal block.** Same
   mechanism as before, with one addition: reveal is now gated on a public
   block number (`Session.revealTargetBlock`) fixed once at `startSession`,
   so the family's reveal always happens together at a known point, never as
   a race to be first. Detailed below.
3. **Unblocking the real shared Hub.** This is **not new code** — it is
   `Spoke.borrow(reserveId, amount, onBehalfOf, sessionId)` +
   `SolvencyRegistry.consumeApprovedSession(...)`, already described above,
   already the only function that touches the Hub and moves funds, already
   gated on the session being `APPROVED`. Mapping the newer terminology onto
   the existing implementation: "the second reveal toward the shared hub" =
   this `borrow()` call; it was already a distinct, later, separately-gated
   action from the family's internal reveal, not something that needed
   building from scratch.

## What was built

### Contracts

- **`src/spoke/interfaces/ISolvencyRegistry.sol`** / **`src/spoke/SolvencyRegistry.sol`**
  (new). The commit-reveal registry and consortium membership registry.
- **`src/spoke/Spoke.sol`** / **`src/spoke/interfaces/ISpoke.sol`** (modified).
  Added:
  - `requestBorrowSolvencyCheck(reserveId, amount, onBehalfOf)` — opens a
    SolvencyRegistry session.
  - `borrow(reserveId, amount, onBehalfOf, solvencySessionId)` — a new
    **overload** of `borrow()` that requires and consumes an APPROVED session
    before running the existing borrow logic.
  - `setSolvencyRegistry(address)` / `solvencyRegistry()` — restricted
    setter/getter for the registry address.
  - The original 3-arg `borrow()` is **unchanged in behaviour and signature**;
    both overloads now share one internal `_borrow()` implementation so the
    actual Hub-draw / LTV / risk-premium logic exists exactly once.
- **`src/spoke/SpokeStorage.sol`** (modified). Added one storage slot
  (`_solvencyRegistry`), consuming one unit from the existing upgradeable-proxy
  storage gap (`uint256[50] → uint256[49]`).
- **`src/deployments/utils/libraries/Roles.sol`** (modified, purely additive).
  Added a new role namespace `SOLVENCY_REGISTRY_DOMAIN_ADMIN_ROLE = 500` and
  its selector getter, and appended `ISpoke.setSolvencyRegistry.selector` to
  the existing `SPOKE_CONFIGURATOR_ROLE` (301) selector list.
- **`ISolvencyRegistry.sol`/`SolvencyRegistry.sol`** (modified, three-phase
  update). Added `Session.revealTargetBlock`, the constructor argument
  `REVEAL_TARGET_BLOCK_OFFSET`, a `RevealTargetNotReached` error, and a
  `require(block.number >= session.revealTargetBlock, ...)` gate at the top
  of `submitReveal`. `SessionStarted` and `getSession` both now surface the
  new field — an ABI change; every constructor call site and any code
  decoding those two shapes elsewhere in this repo was updated (see below).
  The demo console (`~/tesi/aave-v4-mpc-demo/console/`) was **not** touched —
  it decodes the old `getSession`/`SessionStarted` shapes and is now
  out of sync with the redeployed contract's ABI until it's updated
  separately; flagged here, not silently left for someone to discover.

### Tests

New directory `tests/contracts/spoke/solvency/`:

- `SolvencyTestBase.sol` — shared fixture (deploys a 3-participant
  SolvencyRegistry, wires it into `spoke1`, grants the governor role).
- `Spoke.Solvency.Commit.t.sol` (5 tests) — happy path, non-participant,
  duplicate commit, out-of-sequence commit, commit after timeout-block.
- `Spoke.Solvency.Reveal.t.sol` (8 tests) — happy path (APPROVED), commit
  mismatch, missing participant → timeout → BLOCKED, non-participant reveal,
  genuine disagreement between two participants, reveal attempted before
  `revealTargetBlock` (`RevealTargetNotReached`), reveal exactly at the
  target block (succeeds), reveal late after the target but before the
  session deadline (succeeds with no penalty).
- `Spoke.Solvency.BorrowIntegration.t.sol` (5 tests) — APPROVED → borrow
  succeeds and consumes the session (replay blocked); RIFIUTATO → no funds
  move; REVIEW_MANUALE → pending, then resolved both ways; a regression check
  that the untouched 3-arg `borrow()` still works.
- `Spoke.Solvency.Membership.t.sol` (8 tests) — change queued while a session
  is active and not applied early; registry blocks a new session both while
  `SESSION_ACTIVE` and while `MEMBERSHIP_APPLYING`; apply then start a new
  session; propose-while-idle applies immediately; cannot remove the last
  participant; access-control reverts for a non-governor caller (propose,
  apply, resolve-manual-review); invalid depositDeclared on both directions.

**26/26 solvency tests pass** (8+5+8+5 across the four files above). A full
`forge test` run against the whole existing suite (1952 passed, 135 failed)
shows **zero regressions from this work**: the 135 failures are all in
liquidation-only fuzz/gas tests, and were confirmed pre-existing and
unrelated by `git stash`-ing every change in this update and re-running the
same failing tests against the clean parent commit — identical failure set,
identical count, before any of this work existed. Earlier in this project's
history, getting to a clean baseline needed two mechanical fixes (a
selector-count assertion, two call sites needing disambiguation once
`borrow` became overloaded); this particular update needed no such fixes,
only the block-roll insertions described above.

### Repository cleanup

Removed (safe, unrelated to any code path): `audits/` (PDF-only, ~8 MB) and
`.github/` (CI workflows tied to the upstream `aave/aave-v4` repository's own
release process, not exercised by a local `forge build`/`forge test`).

**Not removed, flagged for your own review instead** (per your instruction to
signal doubtful cases rather than delete silently): `TokenizationSpoke.sol`,
`TreasurySpoke.sol`, `NativeTokenGateway.sol`, and the other
position-manager/gateway contracts. These are not touched by this change, but
they're live code exercised by the shared test fixtures (`Base.t.sol` deploys
the whole system), so removing them is a larger, separable decision with real
risk of breaking the build — left for you to decide, not silently kept or cut.

## Design

### Commit-reveal state machine

```mermaid
%%{init: {"theme": "dark"}}%%
stateDiagram-v2
  [*] --> COMMIT: startSession (Spoke only, fixes revealTargetBlock)
  COMMIT --> REVEAL: last expected commit received
  REVEAL --> REVEAL: submitReveal before revealTargetBlock -> reverts, no state change
  REVEAL --> APPROVED: all reveal esito=2, agree (only accepted at/after revealTargetBlock)
  REVEAL --> REJECTED: all reveal esito=0, agree
  REVEAL --> MANUAL_REVIEW: all reveal esito=1, agree
  COMMIT --> BLOCKED: checkTimeout (deadline elapsed)
  REVEAL --> BLOCKED: checkTimeout (deadline elapsed)
  MANUAL_REVIEW --> APPROVED: resolveManualReview(true)
  MANUAL_REVIEW --> REJECTED: resolveManualReview(false)
  APPROVED --> [*]: consumeApprovedSession (Spoke only)
```

A session is created by `Spoke.requestBorrowSolvencyCheck`, which snapshots
the *current* consortium as the session's expected participants. Each
participant node then, **directly, in its own transaction**:

1. `submitCommit(sessionId, keccak256(sessionId, esito, policyVersion, timestamp, salt))`
2. once all expected commits are in, `submitReveal(sessionId, esito, policyVersion, timestamp, salt)`

Only `(esito, policyVersion, timestamp)` ever reaches the chain — never the
numeric risk score or the LTV/liquidation-threshold figures the MPC
computation also reveals to the participating nodes off-chain. This mirrors
the privacy stance already established in the superseded oracle design: a
risk figure bound permanently and publicly to a wallet address is a larger,
longer-lived data exposure than sharing it privately among consortium nodes.

### No signature field on commit or reveal

The superseded oracle design needed ECDSA signatures verified via `ecrecover`
because a single relayer submitted every platform's agreement in one bundled
transaction — the signature was the only way to attribute a statement to a
specific platform. Here, every node sends its **own** transaction directly, so
`msg.sender` already *is* the authenticated identity (an Ethereum transaction
is inherently signed by its sender's key). Adding a redundant in-payload
ECDSA signature would just re-verify, at extra gas cost, something the EVM
already verified to accept the transaction. This stops being true only if a
relayer or meta-transaction path is reintroduced later — deliberately not
done here, since that would recreate the availability single point of failure
this design exists to remove.

### Synchronized reveal: a public target block, not a race

`Session.revealTargetBlock` is fixed once, at `startSession`, to
`block.number + REVEAL_TARGET_BLOCK_OFFSET` — a public, verifiable point every
participant knows from the `SessionStarted` event itself, before any of them
has even started committing. `submitReveal` reverts `RevealTargetNotReached`
before that block is reached; there is no separate deadline for the target
itself — if a reveal never arrives even after it, the *existing*
`SESSION_TIMEOUT_SECONDS` deadline and `checkTimeout` already cover that,
unchanged.

**The trade-off this offset represents, made explicit rather than picked
silently**: real MP-SPDZ computation time for the underlying node network has
been observed between ~45s and 300s+ depending on load and party count, and
COMMIT cannot even begin until that computation finishes.
- Set the offset too small (in block-time terms) and it becomes a pure no-op:
  commits themselves won't have arrived yet, so the floor is harmless but
  pointless.
- Set it too close to `SESSION_TIMEOUT_SECONDS` and there's no room left for
  the reveal transactions themselves to land before `checkTimeout` can fire —
  a session that was otherwise on track gets blocked purely for lack of
  margin, not for any real failure.

There is no way for the contract to derive a correct value on its own (it
cannot observe off-chain compute time or real block time, only
`block.number`) — `REVEAL_TARGET_BLOCK_OFFSET` is a constructor argument, not
a hardcoded constant, and the deploying operator must choose it with both
figures in mind. The current Sepolia deployment scripts use 60 blocks
(~720s at Sepolia's ~12s/block), leaving roughly 480s of margin before the
1200s `SESSION_TIMEOUT_SECONDS` deadline.

### Concurrency: one session at a time, registry-wide

Only one solvency session may be active across the whole registry, not one
per client. This is grounded in a documented, unresolved operational
limitation of the underlying MP-SPDZ node network this registry coordinates:
each node's own request queue is independent and single-worker, and has been
observed to desynchronize from its peers under concurrent load, producing
spurious failures unrelated to the cryptography itself. Reflecting that real
constraint in the contract — rather than allowing concurrent sessions the
off-chain layer cannot yet reliably support — was a deliberate choice. A
future revision that fixes the underlying queue-synchronization problem could
relax this to true per-client concurrency without changing the commit-reveal
mechanics themselves.

### `borrow()` overload vs. changing the existing signature

The gated path is a new 4-argument `borrow()` overload, not a change to the
existing 3-argument one. Changing the existing signature would have forced
either rewriting the whole pre-existing spoke test suite (borrow, liquidation,
multi-hub, risk-premium, …) or silently changing behaviour for callers
outside the MPC consortium flow. The trade-off: the plain 3-arg `borrow()`
remains reachable and **not** gated by any solvency check — making the gate
mandatory system-wide would require either that breaking signature change or
restricting, at the deployment/governance layer, which PositionManager
callers may reach the 3-arg path at all. Both are explicitly out of scope
here and are flagged rather than silently decided.

### Consortium scalability (adding/removing a bank)

A membership change (`proposeMembershipChange` / `applyQueuedMembershipChange`)
reuses the same registry-wide phase used for solvency sessions
(`IDLE` / `SESSION_ACTIVE` / `MEMBERSHIP_APPLYING`):

- Proposed while `IDLE` → the registry moves straight to
  `MEMBERSHIP_APPLYING`, an observable state, not just a same-transaction
  detail.
- Proposed while `SESSION_ACTIVE` → queued; applied automatically (registry
  moves to `MEMBERSHIP_APPLYING`) only once the active session ends
  (approved, rejected, or blocked by timeout) — a computation in progress can
  never be interrupted or have its participant set changed mid-flight.
- While `MEMBERSHIP_APPLYING`, `startSession` is refused (`RegistryBusy`) —
  no new computation can begin with an ambiguous "who's actually in the
  consortium right now" state.

**Explicitly out of scope, flagged rather than assumed**: applying the
on-chain membership change does **not** reconfigure the off-chain MP-SPDZ
network. Before a new session can safely run with the new participant count,
operators must, out-of-band: regenerate SSL certificates for the new party
count (`Scripts/setup-ssl.sh` in the sibling MPC repository), exchange the new
certificate manually (never over the network `-e` protects), and recompile
`crypto_collateral_risk.mpc` for the new N. The contract has no way to verify
or enforce that this happened before the next session starts.

### Manual review

`REVIEW_MANUALE` sessions have **no timeout path** — they stay pending until
an authorized operator calls `resolveManualReview`. This mirrors a principle
already established in the superseded design's own documentation: automating
manual review would reintroduce exactly the single point of trust/failure the
whole architecture exists to avoid. If this is ever automated, the
architecturally consistent path is a second MPC round with a more permissive
policy threshold agreed by the consortium — not an external, centralized
service.

## Open governance questions (deliberately not resolved here)

Both flagged prominently in the contracts' own NatSpec, repeated here:

1. **Who holds `SOLVENCY_REGISTRY_DOMAIN_ADMIN_ROLE`** — the role gating
   `proposeMembershipChange`, `applyQueuedMembershipChange`, and
   `resolveManualReview`? A dedicated consortium multisig, a subset of Aave's
   own governance, a separate DAO — this is a governance decision outside
   this codebase's scope. The implementation only enforces that *some*
   authorized role is required and that membership changes never overlap an
   active session.
2. Related: this same role currently covers **both** consortium-membership
   governance and manual-review resolution, as one role rather than two
   granular ones. Kept as a simplification for this prototype since both
   concern "who speaks for the consortium," not a requirement.

## Parameters

- `SESSION_TIMEOUT_SECONDS` (constructor argument, no protocol-level default):
  must exceed the off-chain MPC layer's own internal timeout with real
  margin. The existing node deployment budgets 600s per `mascot-party.x` run;
  1200s is a reasonable deployment default, but this is operational, not a
  protocol constant.
- `APPROVAL_VALIDITY_SECONDS` (constructor argument): how long an APPROVED,
  unconsumed session remains usable before `consumeApprovedSession` refuses
  it as expired.
- `REVEAL_TARGET_BLOCK_OFFSET` (constructor argument): blocks after
  `startSession` before `submitReveal` is accepted at all. See "Synchronized
  reveal" above for the margin trade-off against `SESSION_TIMEOUT_SECONDS` —
  60 blocks (~720s on Sepolia) in the current deployment scripts.

## Not done (explicitly, not silently)

- Multi-Spoke support: this integration targets a single Spoke instance per
  SolvencyRegistry (`SPOKE` is immutable).
- Any on-chain mechanism to verify the off-chain MP-SPDZ network was actually
  reconfigured for a new consortium size before the next session starts.
- A timelock on governance actions (membership changes, manual review
  resolution) — these execute immediately once the authorized role calls
  them.
- Splitting the single `SOLVENCY_REGISTRY_DOMAIN_ADMIN_ROLE` into more
  granular roles (see open questions above).
- **Minimum number of nodes required to start a session.** There is no
  configurable floor — `startSession` snapshots whatever the current
  consortium happens to be, even if that's a single participant. Left open
  because the thesis prompt introducing the three-phase model asked for it
  to be flagged, not silently assumed or arbitrarily decided here.
- **A node that disconnects while waiting for `revealTargetBlock`.** Not
  enforceable on-chain by construction: `revealTargetBlock` only gates when a
  reveal is *accepted*, it cannot compel a disconnected node's operator to
  actually submit one. The existing `checkTimeout`/`BLOCKED` path is the only
  on-chain consequence, exactly as it already was for a node that never
  reveals at all — this remains an operational risk, not a protocol gap.
- Real integration of the phase-1 local simulation
  (`~/tesi/aave-v4-mpc-node-sim/`) into the live node containers' actual
  request pipeline — the prototype there is a standalone script, not wired
  into `node/app/tasks.py`'s job flow, deliberately, per this update's own
  scope (see that directory's own README for what a real integration would
  still require).
- The demo console's `chain.py`/`app.py` ABI decoding of `getSession`
  (7 → 8 fields) and `SessionStarted` (5 → 6 fields) — not updated as part of
  this change, since the live `demo-node0/1/2` containers and console were
  explicitly out of scope here. The console will misdecode against a
  redeployed registry until it's updated to match.
