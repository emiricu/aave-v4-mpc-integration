// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {SolvencyTestBase} from 'tests/contracts/spoke/solvency/SolvencyTestBase.sol';
import {ISolvencyRegistry} from 'src/spoke/interfaces/ISolvencyRegistry.sol';

contract SpokeSolvencyCommitTest is SolvencyTestBase {
  uint8 constant ESITO_APPROVATO = 2;
  uint256 constant POLICY_VERSION = 1;
  uint256 constant MPC_TIMESTAMP = 1_700_000_000;

  function test_commit_happyPath_advancesToReveal() public {
    uint256 reserveId = _daiReserveId(spoke1);
    bytes32 sessionId = _startSession(bob, reserveId, 100e18);

    assertEq(uint256(registry.getSession(sessionId).phase), uint256(ISolvencyRegistry.SessionPhase.COMMIT));

    bytes32 salt0 = keccak256('salt-node0');
    bytes32 salt1 = keccak256('salt-node1');
    bytes32 salt2 = keccak256('salt-node2');

    _commit(sessionId, node0, ESITO_APPROVATO, POLICY_VERSION, MPC_TIMESTAMP, salt0);
    assertEq(uint256(registry.getSession(sessionId).phase), uint256(ISolvencyRegistry.SessionPhase.COMMIT));
    assertEq(registry.getSession(sessionId).commitCount, 1);

    _commit(sessionId, node1, ESITO_APPROVATO, POLICY_VERSION, MPC_TIMESTAMP, salt1);
    assertEq(registry.getSession(sessionId).commitCount, 2);
    assertEq(uint256(registry.getSession(sessionId).phase), uint256(ISolvencyRegistry.SessionPhase.COMMIT));

    _commit(sessionId, node2, ESITO_APPROVATO, POLICY_VERSION, MPC_TIMESTAMP, salt2);
    assertEq(registry.getSession(sessionId).commitCount, 3);
    assertEq(uint256(registry.getSession(sessionId).phase), uint256(ISolvencyRegistry.SessionPhase.REVEAL));
  }

  function test_commit_revertsWith_NotExpectedParticipant() public {
    uint256 reserveId = _daiReserveId(spoke1);
    bytes32 sessionId = _startSession(bob, reserveId, 100e18);

    address stranger = makeAddr('stranger');
    bytes32 commitHash = keccak256(abi.encode(sessionId, ESITO_APPROVATO, POLICY_VERSION, MPC_TIMESTAMP, bytes32(0)));

    vm.expectRevert(ISolvencyRegistry.NotExpectedParticipant.selector);
    vm.prank(stranger);
    registry.submitCommit(sessionId, commitHash);
  }

  function test_commit_revertsWith_AlreadyCommitted() public {
    uint256 reserveId = _daiReserveId(spoke1);
    bytes32 sessionId = _startSession(bob, reserveId, 100e18);

    bytes32 salt0 = keccak256('salt-node0');
    _commit(sessionId, node0, ESITO_APPROVATO, POLICY_VERSION, MPC_TIMESTAMP, salt0);

    bytes32 commitHash = keccak256(abi.encode(sessionId, ESITO_APPROVATO, POLICY_VERSION, MPC_TIMESTAMP, salt0));
    vm.expectRevert(ISolvencyRegistry.AlreadyCommitted.selector);
    vm.prank(node0);
    registry.submitCommit(sessionId, commitHash);
  }

  function test_commit_revertsWith_NotInCommitPhase_afterAllCommitsReceived() public {
    uint256 reserveId = _daiReserveId(spoke1);
    bytes32 sessionId = _startSession(bob, reserveId, 100e18);

    _commit(sessionId, node0, ESITO_APPROVATO, POLICY_VERSION, MPC_TIMESTAMP, keccak256('s0'));
    _commit(sessionId, node1, ESITO_APPROVATO, POLICY_VERSION, MPC_TIMESTAMP, keccak256('s1'));
    _commit(sessionId, node2, ESITO_APPROVATO, POLICY_VERSION, MPC_TIMESTAMP, keccak256('s2'));

    // Session is now in REVEAL: a late/duplicate commit attempt (out of sequence) must be rejected, not silently
    // accepted or misinterpreted as belonging to a new round.
    bytes32 commitHash = keccak256(abi.encode(sessionId, ESITO_APPROVATO, POLICY_VERSION, MPC_TIMESTAMP, keccak256('late')));
    vm.expectRevert(ISolvencyRegistry.NotInCommitPhase.selector);
    vm.prank(node0);
    registry.submitCommit(sessionId, commitHash);
  }

  function test_commit_revertsWith_RegistryBusy_afterTimeoutBlocksSession() public {
    uint256 reserveId = _daiReserveId(spoke1);
    bytes32 sessionId = _startSession(bob, reserveId, 100e18);

    _commit(sessionId, node0, ESITO_APPROVATO, POLICY_VERSION, MPC_TIMESTAMP, keccak256('s0'));

    vm.warp(block.timestamp + SESSION_TIMEOUT + 1);
    registry.checkTimeout(sessionId);
    assertEq(uint256(registry.getSession(sessionId).phase), uint256(ISolvencyRegistry.SessionPhase.BLOCKED));

    // checkTimeout already returned the registry itself to IDLE (no queued membership change), so any
    // further commit -- for this now-BLOCKED session or otherwise -- is rejected at the registry-wide gate
    // before the per-session phase is even consulted.
    bytes32 commitHash = keccak256(abi.encode(sessionId, ESITO_APPROVATO, POLICY_VERSION, MPC_TIMESTAMP, keccak256('s1')));
    vm.expectRevert(ISolvencyRegistry.RegistryBusy.selector);
    vm.prank(node1);
    registry.submitCommit(sessionId, commitHash);
  }
}
