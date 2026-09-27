// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {SolvencyTestBase} from 'tests/contracts/spoke/solvency/SolvencyTestBase.sol';
import {ISolvencyRegistry} from 'src/spoke/interfaces/ISolvencyRegistry.sol';

contract SpokeSolvencyRevealTest is SolvencyTestBase {
  uint8 constant ESITO_RIFIUTATO = 0;
  uint8 constant ESITO_APPROVATO = 2;
  uint256 constant POLICY_VERSION = 1;
  uint256 constant MPC_TIMESTAMP = 1_700_000_000;

  function test_reveal_happyPath_finalizesApproved() public {
    uint256 reserveId = _daiReserveId(spoke1);
    bytes32 sessionId = _runFullSession(bob, reserveId, 100e18, ESITO_APPROVATO, POLICY_VERSION, MPC_TIMESTAMP);

    ISolvencyRegistry.Session memory session = registry.getSession(sessionId);
    assertEq(uint256(session.phase), uint256(ISolvencyRegistry.SessionPhase.APPROVED));
    assertEq(session.esito, ESITO_APPROVATO);
    assertEq(session.policyVersion, POLICY_VERSION);
    assertEq(session.timestamp, MPC_TIMESTAMP);
    assertEq(session.revealCount, 3);
    assertFalse(session.consumed);
    assertEq(uint256(registry.phase()), uint256(ISolvencyRegistry.RegistryPhase.IDLE));
  }

  function test_reveal_revertsWith_CommitMismatch() public {
    uint256 reserveId = _daiReserveId(spoke1);
    bytes32 sessionId = _startSession(bob, reserveId, 100e18);

    bytes32 salt0 = keccak256('salt-node0');
    _commit(sessionId, node0, ESITO_APPROVATO, POLICY_VERSION, MPC_TIMESTAMP, salt0);
    _commit(sessionId, node1, ESITO_APPROVATO, POLICY_VERSION, MPC_TIMESTAMP, keccak256('salt-node1'));
    _commit(sessionId, node2, ESITO_APPROVATO, POLICY_VERSION, MPC_TIMESTAMP, keccak256('salt-node2'));

    // node0 attempts to reveal a different esito than it committed to -- the recomputed hash will not match.
    vm.expectRevert(ISolvencyRegistry.CommitMismatch.selector);
    vm.prank(node0);
    registry.submitReveal(sessionId, ESITO_RIFIUTATO, POLICY_VERSION, MPC_TIMESTAMP, salt0);
  }

  function test_reveal_missingParticipant_timesOutToBlocked() public {
    uint256 reserveId = _daiReserveId(spoke1);
    bytes32 sessionId = _startSession(bob, reserveId, 100e18);

    bytes32 salt0 = keccak256('salt-node0');
    bytes32 salt1 = keccak256('salt-node1');
    bytes32 salt2 = keccak256('salt-node2');
    _commit(sessionId, node0, ESITO_APPROVATO, POLICY_VERSION, MPC_TIMESTAMP, salt0);
    _commit(sessionId, node1, ESITO_APPROVATO, POLICY_VERSION, MPC_TIMESTAMP, salt1);
    _commit(sessionId, node2, ESITO_APPROVATO, POLICY_VERSION, MPC_TIMESTAMP, salt2);

    // node2 never reveals -- its own transaction, its own "signature", simply never arrives.
    _reveal(sessionId, node0, ESITO_APPROVATO, POLICY_VERSION, MPC_TIMESTAMP, salt0);
    _reveal(sessionId, node1, ESITO_APPROVATO, POLICY_VERSION, MPC_TIMESTAMP, salt1);

    assertEq(uint256(registry.getSession(sessionId).phase), uint256(ISolvencyRegistry.SessionPhase.REVEAL));

    vm.warp(block.timestamp + SESSION_TIMEOUT + 1);
    registry.checkTimeout(sessionId);

    assertEq(uint256(registry.getSession(sessionId).phase), uint256(ISolvencyRegistry.SessionPhase.BLOCKED));
    assertEq(uint256(registry.phase()), uint256(ISolvencyRegistry.RegistryPhase.IDLE));
  }

  function test_reveal_revertsWith_NotExpectedParticipant() public {
    uint256 reserveId = _daiReserveId(spoke1);
    bytes32 sessionId = _startSession(bob, reserveId, 100e18);

    _commit(sessionId, node0, ESITO_APPROVATO, POLICY_VERSION, MPC_TIMESTAMP, keccak256('s0'));
    _commit(sessionId, node1, ESITO_APPROVATO, POLICY_VERSION, MPC_TIMESTAMP, keccak256('s1'));
    _commit(sessionId, node2, ESITO_APPROVATO, POLICY_VERSION, MPC_TIMESTAMP, keccak256('s2'));

    address stranger = makeAddr('stranger');
    vm.expectRevert(ISolvencyRegistry.NotExpectedParticipant.selector);
    vm.prank(stranger);
    registry.submitReveal(sessionId, ESITO_APPROVATO, POLICY_VERSION, MPC_TIMESTAMP, bytes32(0));
  }

  function test_reveal_revertsWith_RevealDisagreement_andSessionNeverFinalizes() public {
    uint256 reserveId = _daiReserveId(spoke1);
    bytes32 sessionId = _startSession(bob, reserveId, 100e18);

    bytes32 salt0 = keccak256('salt-node0');
    bytes32 salt1 = keccak256('salt-node1');

    // node0 commits to APPROVATO, node1 commits to RIFIUTATO -- a genuinely disagreeing (malicious or buggy)
    // node, not merely a hash mismatch on the same value.
    _commit(sessionId, node0, ESITO_APPROVATO, POLICY_VERSION, MPC_TIMESTAMP, salt0);
    _commit(sessionId, node1, ESITO_RIFIUTATO, POLICY_VERSION, MPC_TIMESTAMP, salt1);
    _commit(sessionId, node2, ESITO_APPROVATO, POLICY_VERSION, MPC_TIMESTAMP, keccak256('s2'));

    _reveal(sessionId, node0, ESITO_APPROVATO, POLICY_VERSION, MPC_TIMESTAMP, salt0);

    vm.expectRevert(ISolvencyRegistry.RevealDisagreement.selector);
    vm.prank(node1);
    registry.submitReveal(sessionId, ESITO_RIFIUTATO, POLICY_VERSION, MPC_TIMESTAMP, salt1);

    // Nothing partial or inconsistent was ever persisted: the session is still stuck in REVEAL with only
    // node0's reveal recorded, not APPROVED, not REJECTED -- only resolvable via checkTimeout from here.
    ISolvencyRegistry.Session memory session = registry.getSession(sessionId);
    assertEq(uint256(session.phase), uint256(ISolvencyRegistry.SessionPhase.REVEAL));
    assertEq(session.revealCount, 1);
  }
}
