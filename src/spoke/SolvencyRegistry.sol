// SPDX-License-Identifier: LicenseRef-BUSL
pragma solidity 0.8.28;

import {AccessManaged} from 'src/dependencies/openzeppelin/AccessManaged.sol';
import {ISolvencyRegistry} from 'src/spoke/interfaces/ISolvencyRegistry.sol';

/// @title SolvencyRegistry
/// @author Aave Labs
/// @notice On-chain commit-reveal registry for an MPC-computed cross-platform solvency verdict, replacing a prior
/// design's oracle/publisher relay entirely: every consortium bank node sends its own commit and reveal
/// transactions directly to this contract. Nothing between a node and this contract can delay, censor, or forge a
/// verdict on a node's behalf -- the closest thing to an "intermediary" left is this contract itself, which is
/// permissionless to read and requires no operator to keep running.
/// @dev Authentication without a redundant in-payload signature: because each node submits its own transaction
/// directly (no relayer batches signatures on a node's behalf, unlike the prior oracle design this supersedes), the
/// Ethereum transaction signature itself already proves which node authored a given commit/reveal -- `msg.sender`
/// IS the authenticated identity. Requiring an additional ECDSA signature verified via `ecrecover` over the same
/// payload would be pure redundant gas cost, paying to re-verify something the EVM already verified to accept the
/// transaction at all. This would stop being true only if a relayer or meta-transaction path were reintroduced --
/// deliberately not done here, since that would recreate the single point of failure on availability this design
/// exists to remove.
/// @dev Privacy continuity with the prior (superseded) oracle design: only `(esito, policyVersion, timestamp)` is
/// ever recorded on-chain by `submitReveal` -- never the numeric risk score or the max-LTV/liquidation-threshold
/// policy outputs the MPC computation also reveals to the participating nodes off-chain. A risk figure bound
/// permanently and publicly to a wallet address is a materially larger and more durable data exposure than sharing
/// it privately among consortium nodes, especially if that wallet is later linkable to a KYC'd identity -- the same
/// reasoning the superseded design's own documentation already established.
/// @dev Concurrency: only one solvency session may be active registry-wide at a time (`RegistryPhase.IDLE` gates
/// `startSession`), not one per client. This is not an arbitrary restriction: the underlying MP-SPDZ node network
/// this registry coordinates already has a documented, unresolved reliability issue under concurrent load (each
/// node's own request queue can desynchronize from its peers', causing spurious failures) -- reflecting that real
/// operational limit here, instead of pretending the contract can safely support concurrency the off-chain layer
/// cannot yet guarantee, was a deliberate choice over building false confidence into the on-chain design.
/// @dev OPEN GOVERNANCE QUESTION: see ISolvencyRegistry's contract-level NatSpec -- `proposeMembershipChange`,
/// `applyQueuedMembershipChange`, and `resolveManualReview` are all gated by the same `restricted` (AccessManager)
/// role, `Roles.SOLVENCY_REGISTRY_DOMAIN_ADMIN_ROLE`. WHO should hold that role in a real deployment is
/// intentionally left unresolved by this implementation.
contract SolvencyRegistry is AccessManaged, ISolvencyRegistry {
  /// @notice The Spoke contract authorized to open and consume solvency sessions.
  address public immutable SPOKE;

  /// @notice Duration, in seconds, a session's COMMIT/REVEAL window stays open before `checkTimeout` may block it.
  /// @dev Must exceed the off-chain MP-SPDZ layer's own internal computation timeout with real margin -- the
  /// existing node deployment this registry coordinates already budgets 600s for a single `mascot-party.x` run
  /// (its own `MPC_TIMEOUT_SECONDS`), on top of documented queueing/retry overhead on real hardware. 1200s is a
  /// reasonable default with that margin, but this is a deployment-specific operational parameter, not a protocol
  /// constant -- hence a constructor argument, not a hardcoded constant.
  uint256 public immutable SESSION_TIMEOUT_SECONDS;

  /// @notice Duration, in seconds, an APPROVED session remains consumable by `consumeApprovedSession` after
  /// finalizing, before it expires and can no longer be used to authorize a `borrow()`.
  uint256 public immutable APPROVAL_VALIDITY_SECONDS;

  RegistryPhase private _phase;
  address[] private _participants;
  mapping(address => bool) private _isParticipantMap;
  mapping(address => bytes32) private _certificateRef;
  PendingChange private _queuedChange;

  mapping(bytes32 => Session) private _sessions;
  mapping(bytes32 => mapping(address => bytes32)) private _commitOf;
  mapping(bytes32 => mapping(address => bool)) private _hasRevealed;
  /// @dev client => reserveId => sessionId of the latest APPROVED, not-yet-consumed session, if any.
  mapping(address => mapping(uint256 => bytes32)) private _latestApprovedSession;

  uint256 private _sessionNonce;

  modifier onlySpoke() {
    require(msg.sender == SPOKE, OnlySpoke());
    _;
  }

  /// @dev Constructor.
  /// @param authority_ The address of the AccessManager authority contract which manages `restricted` permissions.
  /// @param spoke_ The Spoke contract authorized to call `startSession`/`consumeApprovedSession`.
  /// @param initialParticipants_ The consortium's initial bank/node addresses.
  /// @param initialCertificateRefs_ Opaque off-chain certificate references, one per initial participant, same
  /// order as `initialParticipants_`.
  /// @param sessionTimeoutSeconds_ See `SESSION_TIMEOUT_SECONDS`.
  /// @param approvalValiditySeconds_ See `APPROVAL_VALIDITY_SECONDS`.
  constructor(
    address authority_,
    address spoke_,
    address[] memory initialParticipants_,
    bytes32[] memory initialCertificateRefs_,
    uint256 sessionTimeoutSeconds_,
    uint256 approvalValiditySeconds_
  ) AccessManaged(authority_) {
    require(
      spoke_ != address(0) &&
        initialParticipants_.length > 0 &&
        initialParticipants_.length == initialCertificateRefs_.length &&
        sessionTimeoutSeconds_ > 0 &&
        approvalValiditySeconds_ > 0,
      InvalidConstructorArgs()
    );
    SPOKE = spoke_;
    SESSION_TIMEOUT_SECONDS = sessionTimeoutSeconds_;
    APPROVAL_VALIDITY_SECONDS = approvalValiditySeconds_;
    for (uint256 i = 0; i < initialParticipants_.length; i++) {
      address participant = initialParticipants_[i];
      require(participant != address(0) && !_isParticipantMap[participant], InvalidConstructorArgs());
      _isParticipantMap[participant] = true;
      _certificateRef[participant] = initialCertificateRefs_[i];
      _participants.push(participant);
    }
  }

  // ─── Spoke-only session lifecycle ───

  /// @inheritdoc ISolvencyRegistry
  function startSession(
    address client,
    uint256 reserveId,
    uint256 amount
  ) external onlySpoke returns (bytes32 sessionId) {
    require(_phase == RegistryPhase.IDLE, RegistryBusy());

    sessionId = keccak256(
      abi.encode(address(this), client, reserveId, amount, block.timestamp, _sessionNonce++)
    );

    Session storage session = _sessions[sessionId];
    session.phase = SessionPhase.COMMIT;
    session.client = client;
    session.reserveId = reserveId;
    session.amount = amount;
    session.deadline = block.timestamp + SESSION_TIMEOUT_SECONDS;
    session.participants = _participants;

    _phase = RegistryPhase.SESSION_ACTIVE;

    emit SessionStarted(sessionId, client, reserveId, amount, session.participants);
  }

  /// @inheritdoc ISolvencyRegistry
  function consumeApprovedSession(
    address client,
    uint256 reserveId,
    uint256 amount
  ) external onlySpoke returns (bytes32 sessionId) {
    sessionId = _latestApprovedSession[client][reserveId];
    require(sessionId != bytes32(0), SessionNotApproved());

    Session storage session = _sessions[sessionId];
    require(session.phase == SessionPhase.APPROVED, SessionNotApproved());
    require(!session.consumed, SessionAlreadyConsumed());
    require(block.timestamp <= session.finalizedAt + APPROVAL_VALIDITY_SECONDS, ApprovalExpired());
    require(amount <= session.amount, AmountExceedsApprovedSession());

    // Deliberately NOT clearing _latestApprovedSession here: doing so would make a second consumption
    // attempt for the same (client, reserveId) fail with SessionNotApproved (no session found at all)
    // instead of the more precise SessionAlreadyConsumed -- found by this exact scenario in the test suite.
    // The pointer is only ever overwritten by a newer session's own approval (see submitReveal /
    // resolveManualReview), never cleared on consumption.
    session.consumed = true;

    emit SessionConsumed(sessionId);
  }

  // ─── Consortium node actions (direct, no intermediary) ───

  /// @inheritdoc ISolvencyRegistry
  function submitCommit(bytes32 sessionId, bytes32 commitHash) external {
    require(_phase == RegistryPhase.SESSION_ACTIVE, RegistryBusy());
    Session storage session = _sessions[sessionId];
    require(session.phase == SessionPhase.COMMIT, NotInCommitPhase());
    require(block.timestamp <= session.deadline, SessionExpired());
    require(_isExpectedParticipant(session, msg.sender), NotExpectedParticipant());
    require(_commitOf[sessionId][msg.sender] == bytes32(0), AlreadyCommitted());

    _commitOf[sessionId][msg.sender] = commitHash;
    session.commitCount++;

    emit CommitSubmitted(sessionId, msg.sender);

    if (session.commitCount == session.participants.length) {
      session.phase = SessionPhase.REVEAL;
      emit AllCommitsReceived(sessionId);
    }
  }

  /// @inheritdoc ISolvencyRegistry
  function submitReveal(
    bytes32 sessionId,
    uint8 esito,
    uint256 policyVersion,
    uint256 timestamp,
    bytes32 salt
  ) external {
    require(_phase == RegistryPhase.SESSION_ACTIVE, RegistryBusy());
    Session storage session = _sessions[sessionId];
    require(session.phase == SessionPhase.REVEAL, NotInRevealPhase());
    require(block.timestamp <= session.deadline, SessionExpired());
    require(_isExpectedParticipant(session, msg.sender), NotExpectedParticipant());
    require(!_hasRevealed[sessionId][msg.sender], AlreadyRevealed());
    require(esito <= 2, InvalidEsito());
    require(
      keccak256(abi.encode(sessionId, esito, policyVersion, timestamp, salt)) ==
        _commitOf[sessionId][msg.sender],
      CommitMismatch()
    );

    if (session.revealCount == 0) {
      session.esito = esito;
      session.policyVersion = policyVersion;
      session.timestamp = timestamp;
    } else {
      require(
        esito == session.esito &&
          policyVersion == session.policyVersion &&
          timestamp == session.timestamp,
        RevealDisagreement()
      );
    }

    _hasRevealed[sessionId][msg.sender] = true;
    session.revealCount++;

    emit RevealSubmitted(sessionId, msg.sender, esito, policyVersion, timestamp);

    if (session.revealCount == session.participants.length) {
      _finalizeSession(sessionId, session);
    }
  }

  /// @inheritdoc ISolvencyRegistry
  function checkTimeout(bytes32 sessionId) external {
    Session storage session = _sessions[sessionId];
    require(
      session.phase == SessionPhase.COMMIT || session.phase == SessionPhase.REVEAL,
      InvalidPhaseForTimeout()
    );
    require(block.timestamp > session.deadline, SessionNotExpired());

    session.phase = SessionPhase.BLOCKED;
    emit SessionBlocked(sessionId);

    _onSessionEnded();
  }

  // ─── Manual review ───

  /// @inheritdoc ISolvencyRegistry
  function resolveManualReview(bytes32 sessionId, bool approve) external restricted {
    Session storage session = _sessions[sessionId];
    require(session.phase == SessionPhase.MANUAL_REVIEW, NotInManualReview());

    if (approve) {
      session.phase = SessionPhase.APPROVED;
      session.finalizedAt = block.timestamp;
      _latestApprovedSession[session.client][session.reserveId] = sessionId;
    } else {
      session.phase = SessionPhase.REJECTED;
    }

    emit ManualReviewResolved(sessionId, approve, msg.sender);

    _onSessionEnded();
  }

  // ─── Consortium membership ───

  /// @inheritdoc ISolvencyRegistry
  function proposeMembershipChange(
    bool isAddition,
    address participant,
    bytes32 certificateRef
  ) external restricted {
    require(!_queuedChange.exists, ChangeAlreadyQueued());
    if (isAddition) {
      require(!_isParticipantMap[participant], ParticipantAlreadyRegistered());
    } else {
      require(_isParticipantMap[participant], ParticipantNotRegistered());
      require(_participants.length > 1, ParticipantNotRegistered());
    }

    _queuedChange = PendingChange(true, isAddition, participant, certificateRef);
    emit MembershipChangeQueued(isAddition, participant, certificateRef);

    if (_phase == RegistryPhase.IDLE) {
      _phase = RegistryPhase.MEMBERSHIP_APPLYING;
      emit MembershipChangeReadyToApply(isAddition, participant);
    }
  }

  /// @inheritdoc ISolvencyRegistry
  /// @dev Applying this on-chain change does NOT reconfigure the off-chain MP-SPDZ network. Before any new
  /// session can safely start with the new participant count, operators must, out-of-band: regenerate SSL
  /// certificates for the new party count (see the sibling MPC repository's `Scripts/setup-ssl.sh`), exchange the
  /// new certificate out-of-band per the existing manual process (never over the same untrusted network `-e`
  /// protects), and recompile `crypto_collateral_risk.mpc` for the new N. This contract cannot verify or enforce
  /// that off-chain step -- it only prevents a new session from starting while a membership change is pending
  /// application; it does not prevent someone from starting a session before the off-chain MPC layer is actually
  /// reconfigured for the new N. Flagged here explicitly, not silently assumed.
  function applyQueuedMembershipChange() external restricted {
    require(_phase == RegistryPhase.MEMBERSHIP_APPLYING, NoQueuedChange());

    PendingChange memory change = _queuedChange;
    if (change.isAddition) {
      _isParticipantMap[change.participant] = true;
      _certificateRef[change.participant] = change.certificateRef;
      _participants.push(change.participant);
    } else {
      _isParticipantMap[change.participant] = false;
      delete _certificateRef[change.participant];
      uint256 len = _participants.length;
      for (uint256 i = 0; i < len; i++) {
        if (_participants[i] == change.participant) {
          _participants[i] = _participants[len - 1];
          _participants.pop();
          break;
        }
      }
    }

    delete _queuedChange;
    _phase = RegistryPhase.IDLE;

    emit MembershipChangeApplied(change.isAddition, change.participant, change.certificateRef);
  }

  // ─── Internal ───

  function _finalizeSession(bytes32 sessionId, Session storage session) internal {
    if (session.esito == 2) {
      session.phase = SessionPhase.APPROVED;
      session.finalizedAt = block.timestamp;
      _latestApprovedSession[session.client][session.reserveId] = sessionId;
      emit SessionFinalized(sessionId, session.esito);
      _onSessionEnded();
    } else if (session.esito == 0) {
      session.phase = SessionPhase.REJECTED;
      emit SessionFinalized(sessionId, session.esito);
      _onSessionEnded();
    } else {
      // esito == 1, REVIEW_MANUALE: stays "busy" (no _onSessionEnded()) until a human resolves it via
      // resolveManualReview -- see that function's NatSpec for why this deliberately has no timeout path.
      session.phase = SessionPhase.MANUAL_REVIEW;
      emit SessionFinalized(sessionId, session.esito);
    }
  }

  function _onSessionEnded() internal {
    if (_queuedChange.exists) {
      _phase = RegistryPhase.MEMBERSHIP_APPLYING;
      emit MembershipChangeReadyToApply(_queuedChange.isAddition, _queuedChange.participant);
    } else {
      _phase = RegistryPhase.IDLE;
    }
  }

  function _isExpectedParticipant(
    Session storage session,
    address account
  ) internal view returns (bool) {
    address[] storage expected = session.participants;
    uint256 len = expected.length;
    for (uint256 i = 0; i < len; i++) {
      if (expected[i] == account) return true;
    }
    return false;
  }

  // ─── Views ───

  /// @inheritdoc ISolvencyRegistry
  function getSession(bytes32 sessionId) external view returns (Session memory) {
    return _sessions[sessionId];
  }

  /// @inheritdoc ISolvencyRegistry
  function getParticipants() external view returns (address[] memory) {
    return _participants;
  }

  /// @inheritdoc ISolvencyRegistry
  function isParticipant(address account) external view returns (bool) {
    return _isParticipantMap[account];
  }

  /// @inheritdoc ISolvencyRegistry
  function phase() external view returns (RegistryPhase) {
    return _phase;
  }

  /// @inheritdoc ISolvencyRegistry
  function queuedChange() external view returns (PendingChange memory) {
    return _queuedChange;
  }
}
