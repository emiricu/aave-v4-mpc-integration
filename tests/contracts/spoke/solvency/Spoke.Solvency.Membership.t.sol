// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {SolvencyTestBase} from 'tests/contracts/spoke/solvency/SolvencyTestBase.sol';
import {ISolvencyRegistry} from 'src/spoke/interfaces/ISolvencyRegistry.sol';
import {IAccessManaged} from 'src/dependencies/openzeppelin/IAccessManaged.sol';

contract SpokeSolvencyMembershipTest is SolvencyTestBase {
  uint8 constant ESITO_APPROVATO = 2;
  uint256 constant POLICY_VERSION = 1;
  uint256 constant MPC_TIMESTAMP = 1_700_000_000;

  function test_proposeMembershipChange_whileSessionActive_queuesWithoutApplying() public {
    uint256 reserveId = _daiReserveId(spoke1);
    bytes32 sessionId = _startSession(bob, reserveId, 100e18);
    assertEq(uint256(registry.phase()), uint256(ISolvencyRegistry.RegistryPhase.SESSION_ACTIVE));

    address node3 = makeAddr('node3');
    vm.prank(governor);
    registry.proposeMembershipChange(true, node3, keccak256('node3-cert'));

    // Still SESSION_ACTIVE, not yet applied: the queued change has not touched the live participant set.
    assertEq(uint256(registry.phase()), uint256(ISolvencyRegistry.RegistryPhase.SESSION_ACTIVE));
    assertEq(registry.getParticipants().length, 3);
    assertFalse(registry.isParticipant(node3));

    // A second, unrelated session cannot start while this one is still active -- sanity on the
    // single-session-at-a-time invariant, independent of the queued membership change.
    vm.prank(alice);
    vm.expectRevert(ISolvencyRegistry.RegistryBusy.selector);
    spoke1.requestBorrowSolvencyCheck(reserveId, 1, alice);

    // Finish the original session so the queued change can take effect.
    _commit(sessionId, node0, ESITO_APPROVATO, POLICY_VERSION, MPC_TIMESTAMP, keccak256('s0'));
    _commit(sessionId, node1, ESITO_APPROVATO, POLICY_VERSION, MPC_TIMESTAMP, keccak256('s1'));
    _commit(sessionId, node2, ESITO_APPROVATO, POLICY_VERSION, MPC_TIMESTAMP, keccak256('s2'));
    _reveal(sessionId, node0, ESITO_APPROVATO, POLICY_VERSION, MPC_TIMESTAMP, keccak256('s0'));
    _reveal(sessionId, node1, ESITO_APPROVATO, POLICY_VERSION, MPC_TIMESTAMP, keccak256('s1'));
    _reveal(sessionId, node2, ESITO_APPROVATO, POLICY_VERSION, MPC_TIMESTAMP, keccak256('s2'));

    // The registry must now be MEMBERSHIP_APPLYING, not IDLE, because a change was queued.
    assertEq(uint256(registry.phase()), uint256(ISolvencyRegistry.RegistryPhase.MEMBERSHIP_APPLYING));

    // A new session cannot start while the membership change is ready to apply but not yet applied.
    vm.prank(alice);
    vm.expectRevert(ISolvencyRegistry.RegistryBusy.selector);
    spoke1.requestBorrowSolvencyCheck(reserveId, 1, alice);

    vm.prank(governor);
    registry.applyQueuedMembershipChange();

    assertEq(uint256(registry.phase()), uint256(ISolvencyRegistry.RegistryPhase.IDLE));
    assertEq(registry.getParticipants().length, 4);
    assertTrue(registry.isParticipant(node3));

    // Now a new session can start again.
    vm.prank(alice);
    bytes32 newSessionId = spoke1.requestBorrowSolvencyCheck(reserveId, 1, alice);
    assertTrue(newSessionId != bytes32(0));
  }

  function test_proposeMembershipChange_whileIdle_goesStraightToApplying() public {
    assertEq(uint256(registry.phase()), uint256(ISolvencyRegistry.RegistryPhase.IDLE));

    address node3 = makeAddr('node3');
    vm.prank(governor);
    registry.proposeMembershipChange(true, node3, keccak256('node3-cert'));

    assertEq(uint256(registry.phase()), uint256(ISolvencyRegistry.RegistryPhase.MEMBERSHIP_APPLYING));

    vm.prank(governor);
    registry.applyQueuedMembershipChange();

    assertEq(uint256(registry.phase()), uint256(ISolvencyRegistry.RegistryPhase.IDLE));
    assertTrue(registry.isParticipant(node3));
  }

  function test_removeParticipant_worksAndCannotRemoveLastOne() public {
    vm.startPrank(governor);
    registry.proposeMembershipChange(false, node2, bytes32(0));
    registry.applyQueuedMembershipChange();
    assertFalse(registry.isParticipant(node2));
    assertEq(registry.getParticipants().length, 2);

    registry.proposeMembershipChange(false, node1, bytes32(0));
    registry.applyQueuedMembershipChange();
    assertEq(registry.getParticipants().length, 1);

    // Removing the last remaining participant must revert -- safety floor.
    vm.expectRevert(ISolvencyRegistry.ParticipantNotRegistered.selector);
    registry.proposeMembershipChange(false, node0, bytes32(0));
    vm.stopPrank();
  }

  function test_proposeMembershipChange_revertsWith_AccessManagedUnauthorized_forNonGovernor() public {
    address stranger = makeAddr('stranger');
    vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
    vm.prank(stranger);
    registry.proposeMembershipChange(true, makeAddr('node3'), bytes32(0));
  }

  function test_applyQueuedMembershipChange_revertsWith_AccessManagedUnauthorized_forNonGovernor() public {
    vm.prank(governor);
    registry.proposeMembershipChange(true, makeAddr('node3'), bytes32(0));

    address stranger = makeAddr('stranger');
    vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
    vm.prank(stranger);
    registry.applyQueuedMembershipChange();
  }

  function test_resolveManualReview_revertsWith_AccessManagedUnauthorized_forNonGovernor() public {
    uint256 reserveId = _daiReserveId(spoke1);
    bytes32 sessionId = _runFullSession(bob, reserveId, 1, 1, POLICY_VERSION, MPC_TIMESTAMP);

    address stranger = makeAddr('stranger');
    vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
    vm.prank(stranger);
    registry.resolveManualReview(sessionId, true);
  }
}
