// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import 'tests/setup/Base.t.sol';
import {SolvencyRegistry} from 'src/spoke/SolvencyRegistry.sol';
import {ISolvencyRegistry} from 'src/spoke/interfaces/ISolvencyRegistry.sol';

/// @title SolvencyTestBase
/// @notice Shared fixture for the SolvencyRegistry / consortium-gated borrow() test suite: deploys a
/// SolvencyRegistry with 3 participants, wires it into spoke1, and wires the SolvencyRegistry's own
/// `restricted` functions to a dedicated `governor` address via the existing AccessManager fixture.
abstract contract SolvencyTestBase is Base {
  SolvencyRegistry internal registry;
  address internal node0;
  address internal node1;
  address internal node2;
  address internal governor;
  address[] internal participants;

  uint256 internal constant SESSION_TIMEOUT = 1200;
  uint256 internal constant APPROVAL_VALIDITY = 3600;
  /// @dev Small on purpose: tests advance past it with a single vm.roll, they don't need to model real
  /// Sepolia block timing (see REVEAL_TARGET_BLOCK_OFFSET's own NatSpec in SolvencyRegistry.sol for the real
  /// deployment's margin reasoning, which this constant deliberately does not attempt to mirror).
  uint256 internal constant REVEAL_TARGET_BLOCK_OFFSET = 5;

  function setUp() public virtual override {
    super.setUp();

    node0 = makeAddr('node0');
    node1 = makeAddr('node1');
    node2 = makeAddr('node2');
    governor = makeAddr('governor');

    participants = new address[](3);
    participants[0] = node0;
    participants[1] = node1;
    participants[2] = node2;

    bytes32[] memory certs = new bytes32[](3);
    certs[0] = keccak256('node0-cert');
    certs[1] = keccak256('node1-cert');
    certs[2] = keccak256('node2-cert');

    registry = new SolvencyRegistry({
      authority_: address(accessManager),
      spoke_: address(spoke1),
      initialParticipants_: participants,
      initialCertificateRefs_: certs,
      sessionTimeoutSeconds_: SESSION_TIMEOUT,
      approvalValiditySeconds_: APPROVAL_VALIDITY,
      revealTargetBlockOffset_: REVEAL_TARGET_BLOCK_OFFSET
    });

    // Base._configureHubsAndSpokes() (part of super.setUp()) grants itself SPOKE_CONFIGURATOR_ROLE only
    // temporarily and renounces it again before returning -- by this point address(this) no longer holds
    // it. Re-grant it (ADMIN retains ACCESS_MANAGER_ADMIN_ROLE permanently, see Base._setupFixturesRoles)
    // so this fixture can call the restricted setSolvencyRegistry() (wired to that same role, see
    // Roles.getSpokeConfiguratorRoleSelectors()).
    vm.prank(ADMIN);
    accessManager.grantRole(Roles.SPOKE_CONFIGURATOR_ROLE, address(this), 0);
    spoke1.setSolvencyRegistry(address(registry));

    bytes4[] memory selectors = new bytes4[](3);
    selectors[0] = ISolvencyRegistry.proposeMembershipChange.selector;
    selectors[1] = ISolvencyRegistry.applyQueuedMembershipChange.selector;
    selectors[2] = ISolvencyRegistry.resolveManualReview.selector;

    vm.startPrank(ADMIN);
    accessManager.grantRole(Roles.SOLVENCY_REGISTRY_DOMAIN_ADMIN_ROLE, governor, 0);
    accessManager.setTargetFunctionRole(
      address(registry),
      selectors,
      Roles.SOLVENCY_REGISTRY_DOMAIN_ADMIN_ROLE
    );
    vm.stopPrank();
  }

  /// @dev Opens a session for `client`/`reserveId`/`amount` via spoke1.requestBorrowSolvencyCheck, called as
  /// `client` itself (self position-managed, same convention existing borrow tests already use for bob/alice).
  function _startSession(
    address client,
    uint256 reserveId,
    uint256 amount
  ) internal returns (bytes32 sessionId) {
    vm.prank(client);
    sessionId = spoke1.requestBorrowSolvencyCheck(reserveId, amount, client);
  }

  /// @dev Submits a commit for `participant`, hashing `(sessionId, esito, policyVersion, timestamp, salt)`.
  function _commit(
    bytes32 sessionId,
    address participant,
    uint8 esito,
    uint256 policyVersion,
    uint256 timestamp,
    bytes32 salt
  ) internal {
    bytes32 commitHash = keccak256(abi.encode(sessionId, esito, policyVersion, timestamp, salt));
    vm.prank(participant);
    registry.submitCommit(sessionId, commitHash);
  }

  /// @dev Advances past this session's revealTargetBlock -- every test that reveals must call this (or
  /// otherwise advance the block number) after committing and before revealing, now that reveal is gated on
  /// the family-wide synchronized reveal block fixed at startSession.
  function _rollToRevealTarget() internal {
    vm.roll(block.number + REVEAL_TARGET_BLOCK_OFFSET);
  }

  /// @dev Submits a reveal for `participant`.
  function _reveal(
    bytes32 sessionId,
    address participant,
    uint8 esito,
    uint256 policyVersion,
    uint256 timestamp,
    bytes32 salt
  ) internal {
    vm.prank(participant);
    registry.submitReveal(sessionId, esito, policyVersion, timestamp, salt);
  }

  /// @dev Runs a full commit+reveal round for all 3 fixture participants agreeing on the same
  /// (esito, policyVersion, timestamp), each with its own deterministic salt. Returns the session id.
  function _runFullSession(
    address client,
    uint256 reserveId,
    uint256 amount,
    uint8 esito,
    uint256 policyVersion,
    uint256 timestamp
  ) internal returns (bytes32 sessionId) {
    sessionId = _startSession(client, reserveId, amount);

    bytes32 salt0 = keccak256('salt-node0');
    bytes32 salt1 = keccak256('salt-node1');
    bytes32 salt2 = keccak256('salt-node2');

    _commit(sessionId, node0, esito, policyVersion, timestamp, salt0);
    _commit(sessionId, node1, esito, policyVersion, timestamp, salt1);
    _commit(sessionId, node2, esito, policyVersion, timestamp, salt2);

    _rollToRevealTarget();

    _reveal(sessionId, node0, esito, policyVersion, timestamp, salt0);
    _reveal(sessionId, node1, esito, policyVersion, timestamp, salt1);
    _reveal(sessionId, node2, esito, policyVersion, timestamp, salt2);
  }
}
