// SPDX-License-Identifier: LicenseRef-BUSL
pragma solidity 0.8.28;

/// @title ISolvencyRegistry
/// @author Aave Labs
/// @notice On-chain commit-reveal registry for an MPC-computed cross-platform solvency verdict, published directly
/// by the participating bank consortium's own nodes -- no relayer, oracle, or other intermediary ever touches a
/// commit or reveal transaction. Each node authenticates itself simply by being the `msg.sender` of its own
/// transaction (an Ethereum transaction is already ECDSA-signed by the sending address's key), so no additional
/// in-payload signature is verified here; see SolvencyRegistry's contract-level NatSpec for the full rationale.
/// @dev OPEN GOVERNANCE QUESTION, deliberately not resolved by this implementation: which real-world entity should
/// hold the `restricted` role permitted to call `proposeMembershipChange`, `applyQueuedMembershipChange`, and
/// `resolveManualReview` -- a multisig dedicated to the bank consortium, a subset of Aave's own governance, or a
/// separate DAO -- is a governance decision outside this codebase's scope. This contract only enforces that *some*
/// authorized role is required for those three actions, and that membership changes never overlap an active
/// session; it does not implement or assume a specific governance body.
interface ISolvencyRegistry {
  /// @notice Lifecycle of a single solvency-check session.
  /// @dev NONE: unused sessionId (never started). COMMIT/REVEAL: the two on-chain commit-reveal phases.
  /// MANUAL_REVIEW: the MPC computation itself concluded "review needed" (esito 1) -- resolved by a human operator,
  /// never by a timeout, deliberately (see `resolveManualReview`). APPROVED/REJECTED: terminal, no further writes.
  /// BLOCKED: terminal, reached only via `checkTimeout` when the expected participants never completed COMMIT or
  /// REVEAL in time -- nothing partial or inconsistent is ever published; the session simply dies.
  enum SessionPhase {
    NONE,
    COMMIT,
    REVEAL,
    MANUAL_REVIEW,
    APPROVED,
    REJECTED,
    BLOCKED
  }

  /// @notice Registry-wide phase, serializing solvency sessions against consortium membership changes.
  /// @dev IDLE: no active session, no membership change pending application -- a new session may start, or a
  /// membership change may be proposed (and, if IDLE, applied immediately-observable via MEMBERSHIP_APPLYING).
  /// SESSION_ACTIVE: exactly one solvency session is in COMMIT/REVEAL/MANUAL_REVIEW -- no new session may start, and
  /// a membership-change proposal is queued rather than applied. MEMBERSHIP_APPLYING: a queued membership change is
  /// ready to be applied -- no new session may start until `applyQueuedMembershipChange` clears it.
  /// @dev Only one solvency session may be active registry-wide at a time (not per-client) -- a deliberate
  /// simplification grounded in an operational limitation already observed in the underlying MP-SPDZ node network
  /// (independent, single-worker-per-node queues that documentedly desynchronize under concurrent load); see
  /// SolvencyRegistry's NatSpec for the full citation.
  enum RegistryPhase {
    IDLE,
    SESSION_ACTIVE,
    MEMBERSHIP_APPLYING
  }

  /// @notice A single solvency-check session.
  /// @param phase Current lifecycle phase, see `SessionPhase`.
  /// @param client The wallet (`onBehalfOf`) this session was requested for.
  /// @param reserveId The reserve identifier the eventual borrow would draw from.
  /// @param amount The requested loan amount ceiling this session was opened for; an approved session can only be
  /// consumed for a `borrow()` of at most this amount.
  /// @param policyVersion The off-chain MPC policy version under which the verdict was computed, agreed at reveal.
  /// @param timestamp The off-chain MPC computation timestamp, agreed at reveal (distinct from `block.timestamp`).
  /// @param esito The agreed verdict once REVEAL completes: 0 = RIFIUTATO, 1 = REVIEW_MANUALE, 2 = APPROVATO.
  /// @param consumed Whether an APPROVED session has already been consumed by a matching `borrow()` call.
  /// @param deadline `block.timestamp` after which `checkTimeout` may move a still-COMMIT/REVEAL session to BLOCKED.
  /// This is the only time bound reveal is subject to -- there is deliberately no separate "earliest reveal block":
  /// commit-before-reveal already prevents a participant from tailoring its reveal to what others committed (the
  /// commit hash binds the tuple before any reveal is visible), `msg.sender` already authenticates who is
  /// revealing, and `RevealDisagreement`/`CommitMismatch` already reject any inconsistent or forged tuple. A
  /// public "synchronization block" added no verifiable guarantee beyond what those three properties already give,
  /// since Ethereum does not guarantee a transaction lands in any particular block -- it only added a liveness
  /// hazard (an early node's reveal transaction could be stuck waiting on a target block that a chain reorg or gas
  /// spike delays past `deadline`) for no corresponding security benefit, so it was removed.
  /// @param finalizedAt `block.timestamp` at which the session reached APPROVED (directly, or via manual review) --
  /// used by `consumeApprovedSession` to enforce `APPROVAL_VALIDITY_SECONDS`.
  /// @param participants Frozen snapshot of the consortium's registered addresses at `startSession` time -- this
  /// exact set must commit and reveal for this session to complete, regardless of any membership change proposed
  /// or applied afterwards (a membership change can never be applied while this session is active, so the snapshot
  /// and the live registry cannot actually diverge mid-session -- see `RegistryPhase`).
  /// @param commitCount Number of distinct participants that have submitted a commit for this session.
  /// @param revealCount Number of distinct participants that have submitted a matching reveal for this session.
  struct Session {
    SessionPhase phase;
    address client;
    uint256 reserveId;
    uint256 amount;
    uint256 policyVersion;
    uint256 timestamp;
    uint8 esito;
    bool consumed;
    uint256 deadline;
    uint256 finalizedAt;
    address[] participants;
    uint256 commitCount;
    uint256 revealCount;
  }

  /// @notice A consortium membership change queued for application once no session is active.
  /// @param exists Whether a change is currently queued (distinguishes an empty struct from a genuine no-op).
  /// @param isAddition True to add `participant`, false to remove it.
  /// @param participant The bank/node address being added or removed.
  /// @param certificateRef Opaque off-chain reference (e.g. a hash of the party's MP-SPDZ SSL certificate) recorded
  /// for audit purposes only -- the actual certificate material is never published on-chain, consistent with the
  /// existing out-of-band certificate exchange already used by the off-chain MPC node network.
  /// @param depositDeclared For an addition only (ignored/must be 0 for a removal): a declared amount, recorded for
  /// display/audit only. This is NOT an economic requirement or a minimum-deposit rule -- the Hub's own supply()
  /// already imposes no minimum, and this contract never moves or escrows any funds. It exists purely as a cheap
  /// anti-spam check on proposeMembershipChange (a bare require(> 0), see that function) so a governance proposal
  /// cannot be a fully-zeroed no-op call; the actual Hub deposit, for whatever amount the new bank chooses, is a
  /// separate, later, ordinary supply() call the bank's own wallet makes -- conceptually linked to joining the
  /// consortium, architecturally independent of it.
  struct PendingChange {
    bool exists;
    bool isAddition;
    address participant;
    bytes32 certificateRef;
    uint256 depositDeclared;
  }

  // --- Events ---

  /// @notice Emitted when a new solvency session is opened.
  event SessionStarted(
    bytes32 indexed sessionId,
    address indexed client,
    uint256 indexed reserveId,
    uint256 amount,
    address[] participants
  );

  /// @notice Emitted when a participant submits its commit for a session.
  event CommitSubmitted(bytes32 indexed sessionId, address indexed participant);

  /// @notice Emitted once every expected participant has committed and the session moves to REVEAL.
  event AllCommitsReceived(bytes32 indexed sessionId);

  /// @notice Emitted when a participant submits a valid, agreeing reveal for a session.
  event RevealSubmitted(
    bytes32 indexed sessionId,
    address indexed participant,
    uint8 esito,
    uint256 policyVersion,
    uint256 timestamp
  );

  /// @notice Emitted when a session reaches a terminal (or manual-review) phase after all reveals agree.
  event SessionFinalized(bytes32 indexed sessionId, uint8 esito);

  /// @notice Emitted when a session is forced to BLOCKED after its deadline elapses without completing.
  event SessionBlocked(bytes32 indexed sessionId);

  /// @notice Emitted when an authorized operator resolves a MANUAL_REVIEW session.
  event ManualReviewResolved(bytes32 indexed sessionId, bool approved, address indexed resolver);

  /// @notice Emitted when an APPROVED session is consumed by a matching `borrow()` call.
  event SessionConsumed(bytes32 indexed sessionId);

  /// @notice Emitted when a membership change is proposed (whether queued or immediately made ready to apply).
  event MembershipChangeQueued(bool isAddition, address indexed participant, bytes32 certificateRef, uint256 depositDeclared);

  /// @notice Emitted when the registry transitions to MEMBERSHIP_APPLYING (queued change now safe to apply).
  event MembershipChangeReadyToApply(bool isAddition, address indexed participant);

  /// @notice Emitted when a queued membership change is actually applied to `participants`.
  event MembershipChangeApplied(bool isAddition, address indexed participant, bytes32 certificateRef, uint256 depositDeclared);

  // --- Errors ---

  /// @notice Thrown when a non-Spoke caller attempts a Spoke-only action.
  error OnlySpoke();

  /// @notice Thrown when the registry-wide phase does not permit the attempted action.
  error RegistryBusy();

  /// @notice Thrown when the caller is not one of the session's expected participants.
  error NotExpectedParticipant();

  /// @notice Thrown when a participant attempts to commit twice for the same session.
  error AlreadyCommitted();

  /// @notice Thrown when a participant attempts to reveal twice for the same session.
  error AlreadyRevealed();

  /// @notice Thrown when `submitCommit` is called for a session not currently in COMMIT phase.
  error NotInCommitPhase();

  /// @notice Thrown when `submitReveal` is called for a session not currently in REVEAL phase.
  error NotInRevealPhase();

  /// @notice Thrown when `resolveManualReview` is called for a session not currently in MANUAL_REVIEW phase.
  error NotInManualReview();

  /// @notice Thrown when `checkTimeout` is called for a session not currently in COMMIT or REVEAL phase.
  error InvalidPhaseForTimeout();

  /// @notice Thrown when `submitCommit`/`submitReveal` is attempted after the session's deadline has elapsed.
  error SessionExpired();

  /// @notice Thrown when `checkTimeout` is called before the session's deadline has elapsed.
  error SessionNotExpired();

  /// @notice Thrown when a revealed tuple does not hash to the commit previously stored for that participant.
  error CommitMismatch();

  /// @notice Thrown when a participant reveals a tuple that disagrees with the session's already-agreed tuple.
  error RevealDisagreement();

  /// @notice Thrown when a revealed `esito` is outside the valid {0, 1, 2} range.
  error InvalidEsito();

  /// @notice Thrown when consuming a session that is not APPROVED (never existed, rejected, blocked, or already
  /// superseded by a newer approval for the same client/reserve).
  error SessionNotApproved();

  /// @notice Thrown when attempting to consume a session that was already consumed.
  error SessionAlreadyConsumed();

  /// @notice Thrown when consuming an APPROVED session whose `APPROVAL_VALIDITY_SECONDS` window has elapsed.
  error ApprovalExpired();

  /// @notice Thrown when the requested borrow amount exceeds what the approved session covers.
  error AmountExceedsApprovedSession();

  /// @notice Thrown when proposing a membership change while one is already queued.
  error ChangeAlreadyQueued();

  /// @notice Thrown when applying a membership change while none is ready (`RegistryPhase` is not
  /// MEMBERSHIP_APPLYING).
  error NoQueuedChange();

  /// @notice Thrown when proposing to add a participant that is already registered.
  error ParticipantAlreadyRegistered();

  /// @notice Thrown when proposing to remove a participant that is not registered, or removing the last one.
  error ParticipantNotRegistered();

  /// @notice Thrown when `depositDeclared` is invalid for the proposed change (zero for an addition, or nonzero
  /// for a removal).
  error InvalidDepositDeclared();

  /// @notice Thrown when constructor arguments are invalid (zero addresses, empty/mismatched arrays, zero
  /// durations).
  error InvalidConstructorArgs();

  // --- Spoke-only session lifecycle ---

  /// @notice Opens a new solvency-check session for `client`, snapshotting the current consortium as its expected
  /// participants. Callable only by the configured Spoke contract.
  /// @dev Reverts `RegistryBusy` unless the registry is IDLE -- see `RegistryPhase`.
  /// @param client The wallet the solvency check is being run for.
  /// @param reserveId The reserve identifier the eventual borrow would draw from.
  /// @param amount The requested loan amount ceiling.
  /// @return sessionId The newly created session's identifier.
  function startSession(
    address client,
    uint256 reserveId,
    uint256 amount
  ) external returns (bytes32 sessionId);

  /// @notice Consumes the latest APPROVED, unexpired, unconsumed session for `client`/`reserveId` if it covers at
  /// least `amount`. Callable only by the configured Spoke contract.
  /// @param client The wallet whose approved session is being consumed.
  /// @param reserveId The reserve identifier the borrow is drawing from.
  /// @param amount The amount actually being borrowed; must not exceed the session's approved ceiling.
  /// @return sessionId The consumed session's identifier.
  function consumeApprovedSession(
    address client,
    uint256 reserveId,
    uint256 amount
  ) external returns (bytes32 sessionId);

  // --- Consortium node actions (direct, no intermediary) ---

  /// @notice Submits this participant's commit hash for `sessionId`.
  /// @dev `commitHash` must equal `keccak256(abi.encode(sessionId, esito, policyVersion, timestamp, salt))` for the
  /// values this node will later reveal. No signature is verified beyond `msg.sender` itself -- see this
  /// interface's contract-level NatSpec.
  function submitCommit(bytes32 sessionId, bytes32 commitHash) external;

  /// @notice Reveals this participant's previously committed values for `sessionId`.
  /// @dev Reverts `CommitMismatch` if the tuple does not hash to this participant's stored commit. Reverts
  /// `RevealDisagreement` if a prior revealer already established a different agreed tuple for this session -- the
  /// call reverts entirely rather than persisting anything partial or inconsistent.
  function submitReveal(
    bytes32 sessionId,
    uint8 esito,
    uint256 policyVersion,
    uint256 timestamp,
    bytes32 salt
  ) external;

  /// @notice Permissionlessly forces an expired COMMIT/REVEAL session to BLOCKED. Anyone may call this so
  /// liveness never depends on one specific caller.
  function checkTimeout(bytes32 sessionId) external;

  // --- Manual review ---

  /// @notice Resolves a MANUAL_REVIEW session as approved or rejected. Restricted to an authorized operator role --
  /// see this interface's contract-level NatSpec for why that role is left an open governance question.
  /// @dev Deliberately has no timeout path: a pending manual review stays pending until a human acts, by design.
  function resolveManualReview(bytes32 sessionId, bool approve) external;

  // --- Consortium membership ---

  /// @notice Proposes adding or removing a consortium participant.
  /// @dev If the registry is IDLE, the registry immediately transitions to MEMBERSHIP_APPLYING (observable, not
  /// merely a same-transaction detail). If a session is active, the change is queued and applied automatically
  /// once that session ends (approved, rejected, or blocked by timeout). Reverts `ChangeAlreadyQueued` if a change
  /// is already queued or ready to apply.
  /// @param depositDeclared For `isAddition == true` only: must be nonzero (`InvalidDepositDeclared` otherwise) --
  /// a pure anti-spam check, not an economic minimum, see `PendingChange.depositDeclared`. Must be 0 for a removal
  /// (`InvalidDepositDeclared` otherwise), since it is meaningless there.
  function proposeMembershipChange(
    bool isAddition,
    address participant,
    bytes32 certificateRef,
    uint256 depositDeclared
  ) external;

  /// @notice Applies the queued membership change. Only callable while `RegistryPhase` is MEMBERSHIP_APPLYING.
  /// @dev Does NOT reconfigure the off-chain MP-SPDZ network -- see this function's implementation NatSpec in
  /// SolvencyRegistry for the operational steps this deliberately leaves manual/off-chain.
  function applyQueuedMembershipChange() external;

  // --- Views ---

  /// @notice Returns full session data for `sessionId`.
  function getSession(bytes32 sessionId) external view returns (Session memory);

  /// @notice Returns the current consortium participant set.
  function getParticipants() external view returns (address[] memory);

  /// @notice Returns whether `account` is currently a registered consortium participant.
  function isParticipant(address account) external view returns (bool);

  /// @notice Returns the declared deposit recorded for `account` when it was added (0 if never set/removed) --
  /// display/audit only, see `PendingChange.depositDeclared`.
  function declaredDeposit(address account) external view returns (uint256);

  /// @notice Returns the current registry-wide phase.
  function phase() external view returns (RegistryPhase);

  /// @notice Returns the currently queued membership change, if any (`exists` is false when none is queued).
  function queuedChange() external view returns (PendingChange memory);
}
