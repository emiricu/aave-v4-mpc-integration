// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import 'tests/setup/Base.t.sol';
import {SolvencyTestBase} from 'tests/contracts/spoke/solvency/SolvencyTestBase.sol';
import {ISolvencyRegistry} from 'src/spoke/interfaces/ISolvencyRegistry.sol';

contract SpokeSolvencyBorrowIntegrationTest is SolvencyTestBase {
  uint8 constant ESITO_RIFIUTATO = 0;
  uint8 constant ESITO_REVIEW_MANUALE = 1;
  uint8 constant ESITO_APPROVATO = 2;
  uint256 constant POLICY_VERSION = 1;
  uint256 constant MPC_TIMESTAMP = 1_700_000_000;

  uint256 internal daiReserveId;
  uint256 internal wethReserveId;
  uint256 internal borrowAmount = 100e18;

  function setUp() public override {
    super.setUp();
    daiReserveId = _daiReserveId(spoke1);
    wethReserveId = _wethReserveId(spoke1);

    // Alice supplies dai liquidity, bob supplies weth collateral -- same shape as the existing
    // Spoke.Borrow.t.sol happy-path fixture, so bob has both the collateral and the liquidity available to
    // actually draw against once a solvency session approves him.
    SpokeActions.supplyCollateral({
      spoke: spoke1,
      reserveId: daiReserveId,
      caller: alice,
      amount: borrowAmount * 2,
      onBehalfOf: alice
    });
    SpokeActions.supplyCollateral({
      spoke: spoke1,
      reserveId: wethReserveId,
      caller: bob,
      amount: 10e18,
      onBehalfOf: bob
    });
  }

  function test_borrow_withApprovedSession_succeedsAndConsumesSession() public {
    bytes32 sessionId = _runFullSession(
      bob,
      daiReserveId,
      borrowAmount,
      ESITO_APPROVATO,
      POLICY_VERSION,
      MPC_TIMESTAMP
    );

    uint256 balanceBefore = tokenList.dai.balanceOf(bob);

    vm.prank(bob);
    spoke1.borrow(daiReserveId, borrowAmount, bob, sessionId);

    assertEq(tokenList.dai.balanceOf(bob), balanceBefore + borrowAmount);
    assertTrue(registry.getSession(sessionId).consumed);

    // A second attempt with the same (already consumed) session must fail -- no replay.
    vm.expectRevert(ISolvencyRegistry.SessionAlreadyConsumed.selector);
    vm.prank(bob);
    spoke1.borrow(daiReserveId, 1, bob, sessionId);
  }

  function test_borrow_withRejectedSession_movesNoFunds() public {
    bytes32 sessionId = _runFullSession(
      bob,
      daiReserveId,
      borrowAmount,
      ESITO_RIFIUTATO,
      POLICY_VERSION,
      MPC_TIMESTAMP
    );

    assertEq(uint256(registry.getSession(sessionId).phase), uint256(ISolvencyRegistry.SessionPhase.REJECTED));

    uint256 balanceBefore = tokenList.dai.balanceOf(bob);

    vm.expectRevert(ISolvencyRegistry.SessionNotApproved.selector);
    vm.prank(bob);
    spoke1.borrow(daiReserveId, borrowAmount, bob, sessionId);

    assertEq(tokenList.dai.balanceOf(bob), balanceBefore, 'no funds must move on a rejected solvency check');
  }

  function test_borrow_withManualReviewSession_pendingThenApproved() public {
    bytes32 sessionId = _runFullSession(
      bob,
      daiReserveId,
      borrowAmount,
      ESITO_REVIEW_MANUALE,
      POLICY_VERSION,
      MPC_TIMESTAMP
    );
    assertEq(
      uint256(registry.getSession(sessionId).phase),
      uint256(ISolvencyRegistry.SessionPhase.MANUAL_REVIEW)
    );

    // Pending: borrow must not succeed while awaiting the authorized operator.
    vm.expectRevert(ISolvencyRegistry.SessionNotApproved.selector);
    vm.prank(bob);
    spoke1.borrow(daiReserveId, borrowAmount, bob, sessionId);

    vm.prank(governor);
    registry.resolveManualReview(sessionId, true);
    assertEq(uint256(registry.getSession(sessionId).phase), uint256(ISolvencyRegistry.SessionPhase.APPROVED));

    uint256 balanceBefore = tokenList.dai.balanceOf(bob);
    vm.prank(bob);
    spoke1.borrow(daiReserveId, borrowAmount, bob, sessionId);
    assertEq(tokenList.dai.balanceOf(bob), balanceBefore + borrowAmount);
  }

  function test_borrow_withManualReviewSession_rejectedBranch() public {
    bytes32 sessionId = _runFullSession(
      bob,
      daiReserveId,
      borrowAmount,
      ESITO_REVIEW_MANUALE,
      POLICY_VERSION,
      MPC_TIMESTAMP
    );

    vm.prank(governor);
    registry.resolveManualReview(sessionId, false);
    assertEq(uint256(registry.getSession(sessionId).phase), uint256(ISolvencyRegistry.SessionPhase.REJECTED));

    vm.expectRevert(ISolvencyRegistry.SessionNotApproved.selector);
    vm.prank(bob);
    spoke1.borrow(daiReserveId, borrowAmount, bob, sessionId);
  }

  /// @dev Sanity regression check: the plain, unmodified 3-arg borrow() keeps working exactly as before,
  /// with no solvency session at all -- the gated overload is additive, not a replacement.
  function test_borrow_threeArgOverload_stillWorksUnaffected() public {
    uint256 balanceBefore = tokenList.dai.balanceOf(bob);
    vm.prank(bob);
    spoke1.borrow(daiReserveId, borrowAmount, bob);
    assertEq(tokenList.dai.balanceOf(bob), balanceBefore + borrowAmount);
  }
}
