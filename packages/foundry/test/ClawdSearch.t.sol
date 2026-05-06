// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { ClawdSearch } from "../contracts/ClawdSearch.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/// @dev Mock CLAWD token for tests. Mintable, standard ERC20 behavior.
contract MockClawd is ERC20 {
    constructor() ERC20("Clawd", "CLAWD") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev We can't use the real CLAWD token address baked into ClawdSearch's constructor
///      directly (immutable). To test cleanly we deploy a "Harness" subclass that swaps in
///      a mock token. We do this by `etch`ing the mock's runtime code at the canonical
///      CLAWD address so the immutable read in the production contract resolves to a
///      mintable mock with full ERC20 behavior.
abstract contract ClawdSearchTestBase is Test {
    address constant CLAWD_ADDR = 0x9f86dB9fc6f7c9408e8Fda3Ff8ce4e78ac7a6b07;
    address constant TREASURY = 0x90eF2A9211A3E7CE788561E5af54C76B0Fa3aEd0;

    ClawdSearch internal cs;
    MockClawd internal clawd; // the mock at CLAWD_ADDR

    address internal owner = address(0xC0FFEE);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal carol = address(0xCAFE01);
    address internal dave = address(0xDA1E);

    uint256 constant SUBMIT_PRICE = 1000 * 1e18;
    uint256 constant CHALLENGE_PRICE = 100 * 1e18;
    uint256 constant VOTE_PRICE = 100 * 1e18;
    uint256 constant CHALLENGE_DURATION = 48 hours;
    uint256 constant COOLDOWN = 1 hours;

    function setUp() public virtual {
        // Deploy a real MockClawd, then etch its bytecode at the canonical CLAWD address.
        MockClawd template = new MockClawd();
        bytes memory rt = address(template).code;
        vm.etch(CLAWD_ADDR, rt);
        clawd = MockClawd(CLAWD_ADDR);

        cs = new ClawdSearch(owner);

        // Fund participants.
        for (uint256 i = 0; i < 4; i++) {
            address user = [alice, bob, carol, dave][i];
            clawd.mint(user, 10_000_000 * 1e18);
            vm.prank(user);
            clawd.approve(address(cs), type(uint256).max);
        }
    }

    // -------------------------- helpers --------------------------

    function _submit(address who, ClawdSearch.Category cat, uint256 obsId) internal {
        vm.prank(who);
        cs.submit(cat, obsId);
    }

    function _challenge(address who, ClawdSearch.Category cat, uint256 obsId) internal {
        vm.prank(who);
        cs.challenge(cat, obsId);
    }

    function _vote(address who, ClawdSearch.Category cat, bool forChallenger) internal {
        vm.prank(who);
        cs.vote(cat, forChallenger);
    }
}

// =========================================================================
//                              SUBMIT TESTS
// =========================================================================

contract ClawdSearchSubmitTest is ClawdSearchTestBase {
    function test_submit_setsChampionAndSplitsClawd() public {
        uint256 aliceBalBefore = clawd.balanceOf(alice);
        uint256 burnBefore = clawd.balanceOf(0x000000000000000000000000000000000000dEaD);
        uint256 trBefore = clawd.balanceOf(TREASURY);

        _submit(alice, ClawdSearch.Category.Cutest, 42);

        // 50/50 split (1000 even → 500 burn, 500 treasury)
        assertEq(clawd.balanceOf(alice), aliceBalBefore - SUBMIT_PRICE);
        assertEq(clawd.balanceOf(0x000000000000000000000000000000000000dEaD), burnBefore + 500 * 1e18);
        assertEq(clawd.balanceOf(TREASURY), trBefore + 500 * 1e18);

        ClawdSearch.CategoryState memory s = cs.getCategory(ClawdSearch.Category.Cutest);
        assertEq(s.championObsId, 42);
        assertEq(s.championOwner, alice);
        assertEq(s.reignStart, uint64(block.timestamp));

        (uint128 submitted, uint128 won, uint256 reign) = cs.userStats(alice);
        assertEq(submitted, 1);
        assertEq(won, 0);
        assertEq(reign, 0);
    }

    function test_submit_revertsWhenCategoryAlreadyHasChampion() public {
        _submit(alice, ClawdSearch.Category.Cutest, 42);
        vm.prank(bob);
        vm.expectRevert(ClawdSearch.CategoryAlreadyHasChampion.selector);
        cs.submit(ClawdSearch.Category.Cutest, 99);
    }

    function test_submit_revertsOnZeroObsId() public {
        vm.prank(alice);
        vm.expectRevert(ClawdSearch.InvalidObservation.selector);
        cs.submit(ClawdSearch.Category.Cutest, 0);
    }
}

// =========================================================================
//                            CHALLENGE TESTS
// =========================================================================

contract ClawdSearchChallengeTest is ClawdSearchTestBase {
    function test_challenge_setsChallengerAndOpensWindow() public {
        _submit(alice, ClawdSearch.Category.Cutest, 1);

        uint256 bobBalBefore = clawd.balanceOf(bob);
        _challenge(bob, ClawdSearch.Category.Cutest, 2);

        ClawdSearch.CategoryState memory s = cs.getCategory(ClawdSearch.Category.Cutest);
        assertEq(s.challengerObsId, 2);
        assertEq(s.challengerOwner, bob);
        assertEq(s.challengeStart, uint64(block.timestamp));
        assertEq(s.challengeRound, 1);

        // 50 burn, 50 treasury.
        assertEq(clawd.balanceOf(bob), bobBalBefore - CHALLENGE_PRICE);
        assertTrue(cs.isChallengeActive(ClawdSearch.Category.Cutest));
    }

    function test_challenge_revertsNoChampion() public {
        vm.prank(alice);
        vm.expectRevert(ClawdSearch.CategoryHasNoChampion.selector);
        cs.challenge(ClawdSearch.Category.Cutest, 7);
    }

    function test_challenge_revertsAlreadyActive() public {
        _submit(alice, ClawdSearch.Category.Cutest, 1);
        _challenge(bob, ClawdSearch.Category.Cutest, 2);
        vm.prank(carol);
        vm.expectRevert(ClawdSearch.ChallengeAlreadyActive.selector);
        cs.challenge(ClawdSearch.Category.Cutest, 3);
    }

    function test_challenge_revertsOnCooldown() public {
        _submit(alice, ClawdSearch.Category.Cutest, 1);
        _challenge(bob, ClawdSearch.Category.Cutest, 2);
        // Champion wins on tie (no votes ⇒ challenger wins per spec; cast a champion vote).
        _vote(alice, ClawdSearch.Category.Cutest, false);
        vm.warp(block.timestamp + CHALLENGE_DURATION);
        cs.resolve(ClawdSearch.Category.Cutest);
        // We're now in cooldown.
        vm.prank(carol);
        vm.expectRevert(ClawdSearch.OnCooldown.selector);
        cs.challenge(ClawdSearch.Category.Cutest, 3);

        // After cooldown expires, a new challenge succeeds.
        vm.warp(block.timestamp + COOLDOWN + 1);
        _challenge(carol, ClawdSearch.Category.Cutest, 3);
    }

    function test_challenge_revertsLockedOut() public {
        _submit(alice, ClawdSearch.Category.Cutest, 1);
        _challenge(bob, ClawdSearch.Category.Cutest, 2);
        // Champion wins via vote → bob's obs 2 is locked out in this category.
        _vote(alice, ClawdSearch.Category.Cutest, false);
        vm.warp(block.timestamp + CHALLENGE_DURATION);
        cs.resolve(ClawdSearch.Category.Cutest);
        vm.warp(block.timestamp + COOLDOWN + 1);

        vm.prank(carol);
        vm.expectRevert(ClawdSearch.ObservationLockedOut.selector);
        cs.challenge(ClawdSearch.Category.Cutest, 2);
    }

    function test_challenge_revertsSameAsChampion() public {
        _submit(alice, ClawdSearch.Category.Cutest, 1);
        vm.prank(bob);
        vm.expectRevert(ClawdSearch.SameAsChampion.selector);
        cs.challenge(ClawdSearch.Category.Cutest, 1);
    }

    function test_challenge_revertsZeroId() public {
        _submit(alice, ClawdSearch.Category.Cutest, 1);
        vm.prank(bob);
        vm.expectRevert(ClawdSearch.InvalidObservation.selector);
        cs.challenge(ClawdSearch.Category.Cutest, 0);
    }
}

// =========================================================================
//                              VOTE TESTS
// =========================================================================

contract ClawdSearchVoteTest is ClawdSearchTestBase {
    function test_vote_incrementsCorrectSide() public {
        _submit(alice, ClawdSearch.Category.Cutest, 1);
        _challenge(bob, ClawdSearch.Category.Cutest, 2);

        _vote(carol, ClawdSearch.Category.Cutest, true); // for challenger
        _vote(dave, ClawdSearch.Category.Cutest, false); // for champion

        ClawdSearch.CategoryState memory s = cs.getCategory(ClawdSearch.Category.Cutest);
        assertEq(s.challengerVotes, 1);
        assertEq(s.championVotes, 1);
        assertTrue(cs.hasVoted(ClawdSearch.Category.Cutest, s.challengeRound, carol));
        assertTrue(cs.hasVoted(ClawdSearch.Category.Cutest, s.challengeRound, dave));
    }

    function test_vote_revertsNoActiveChallenge() public {
        _submit(alice, ClawdSearch.Category.Cutest, 1);
        vm.prank(bob);
        vm.expectRevert(ClawdSearch.ChallengeNotActive.selector);
        cs.vote(ClawdSearch.Category.Cutest, true);
    }

    function test_vote_revertsWindowClosed() public {
        _submit(alice, ClawdSearch.Category.Cutest, 1);
        _challenge(bob, ClawdSearch.Category.Cutest, 2);
        vm.warp(block.timestamp + CHALLENGE_DURATION);
        vm.prank(carol);
        vm.expectRevert(ClawdSearch.ChallengeWindowClosed.selector);
        cs.vote(ClawdSearch.Category.Cutest, true);
    }

    function test_vote_revertsAlreadyVoted() public {
        _submit(alice, ClawdSearch.Category.Cutest, 1);
        _challenge(bob, ClawdSearch.Category.Cutest, 2);
        _vote(carol, ClawdSearch.Category.Cutest, true);
        vm.prank(carol);
        vm.expectRevert(ClawdSearch.AlreadyVoted.selector);
        cs.vote(ClawdSearch.Category.Cutest, false);
    }

    function test_vote_separatePerCategory() public {
        _submit(alice, ClawdSearch.Category.Cutest, 1);
        _submit(alice, ClawdSearch.Category.WouldWinInAFight, 11);
        _challenge(bob, ClawdSearch.Category.Cutest, 2);
        _challenge(bob, ClawdSearch.Category.WouldWinInAFight, 12);

        // Carol can vote in BOTH categories, same round indexing.
        _vote(carol, ClawdSearch.Category.Cutest, true);
        _vote(carol, ClawdSearch.Category.WouldWinInAFight, false);
    }
}

// =========================================================================
//                             RESOLVE TESTS
// =========================================================================

contract ClawdSearchResolveTest is ClawdSearchTestBase {
    function test_resolve_challengerWinsOnMoreVotes() public {
        _submit(alice, ClawdSearch.Category.Cutest, 1);
        uint256 reignStart = block.timestamp;
        vm.warp(reignStart + 1 hours);
        _challenge(bob, ClawdSearch.Category.Cutest, 2);
        _vote(carol, ClawdSearch.Category.Cutest, true);
        _vote(dave, ClawdSearch.Category.Cutest, true);
        _vote(alice, ClawdSearch.Category.Cutest, false); // 1 vs 2 → challenger wins

        vm.warp(block.timestamp + CHALLENGE_DURATION);
        cs.resolve(ClawdSearch.Category.Cutest);

        ClawdSearch.CategoryState memory s = cs.getCategory(ClawdSearch.Category.Cutest);
        assertEq(s.championObsId, 2);
        assertEq(s.championOwner, bob);
        assertEq(s.challengerObsId, 0);
        assertEq(s.championVotes, 0);
        assertEq(s.challengerVotes, 0);
        assertEq(s.cooldownEnd, uint64(block.timestamp + COOLDOWN));

        // alice (loser) accrued reign seconds
        (, , uint256 aliceReign) = cs.userStats(alice);
        assertEq(aliceReign, block.timestamp - reignStart);

        // bob's challengesWon ticked
        (, uint128 bobWon, ) = cs.userStats(bob);
        assertEq(bobWon, 1);

        // win counter for the new champion's obs id ticked
        assertEq(cs.categoryChampionWins(ClawdSearch.Category.Cutest, 2), 1);

        // alice's obs 1 is locked out
        assertTrue(cs.hasLostInCategory(ClawdSearch.Category.Cutest, 1));
    }

    function test_resolve_championWinsOnTie() public {
        _submit(alice, ClawdSearch.Category.Cutest, 1);
        _challenge(bob, ClawdSearch.Category.Cutest, 2);
        _vote(carol, ClawdSearch.Category.Cutest, true);
        _vote(dave, ClawdSearch.Category.Cutest, false); // 1-1 tie → defender wins

        vm.warp(block.timestamp + CHALLENGE_DURATION);
        cs.resolve(ClawdSearch.Category.Cutest);

        ClawdSearch.CategoryState memory s = cs.getCategory(ClawdSearch.Category.Cutest);
        assertEq(s.championObsId, 1);
        assertEq(s.championOwner, alice);

        // bob locked out, alice wins counter incremented
        assertTrue(cs.hasLostInCategory(ClawdSearch.Category.Cutest, 2));
        assertEq(cs.categoryChampionWins(ClawdSearch.Category.Cutest, 1), 1);

        // alice still has reignStart unchanged → no reignSeconds yet (champion stayed)
        (, , uint256 aliceReign) = cs.userStats(alice);
        assertEq(aliceReign, 0);
    }

    function test_resolve_challengerWinsOnZeroVotes() public {
        _submit(alice, ClawdSearch.Category.Cutest, 1);
        _challenge(bob, ClawdSearch.Category.Cutest, 2);

        vm.warp(block.timestamp + CHALLENGE_DURATION);
        cs.resolve(ClawdSearch.Category.Cutest);

        ClawdSearch.CategoryState memory s = cs.getCategory(ClawdSearch.Category.Cutest);
        assertEq(s.championObsId, 2);
        assertEq(s.championOwner, bob);
    }

    function test_resolve_loserLockedOutCategoryButCanPlayOthers() public {
        _submit(alice, ClawdSearch.Category.Cutest, 1);
        _submit(alice, ClawdSearch.Category.WouldWinInAFight, 100);
        _challenge(bob, ClawdSearch.Category.Cutest, 2);
        _vote(alice, ClawdSearch.Category.Cutest, false);
        vm.warp(block.timestamp + CHALLENGE_DURATION);
        cs.resolve(ClawdSearch.Category.Cutest); // bob's obs 2 loses in Cutest

        // Bob's obs 2 cannot challenge in Cutest...
        assertTrue(cs.hasLostInCategory(ClawdSearch.Category.Cutest, 2));
        assertFalse(cs.hasLostInCategory(ClawdSearch.Category.WouldWinInAFight, 2));

        // ...but CAN challenge in WouldWinInAFight
        _challenge(bob, ClawdSearch.Category.WouldWinInAFight, 2);
        ClawdSearch.CategoryState memory s = cs.getCategory(ClawdSearch.Category.WouldWinInAFight);
        assertEq(s.challengerObsId, 2);
    }

    function test_resolve_emitsChampionCrownedOnlyWhenChampionChanges() public {
        _submit(alice, ClawdSearch.Category.Cutest, 1);
        _challenge(bob, ClawdSearch.Category.Cutest, 2);
        _vote(alice, ClawdSearch.Category.Cutest, false); // champion wins 1-0

        vm.warp(block.timestamp + CHALLENGE_DURATION);

        vm.recordLogs();
        cs.resolve(ClawdSearch.Category.Cutest);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 crownedSig = keccak256("ChampionCrowned(uint8,uint256,address)");
        bytes32 resolvedSig = keccak256("ChallengeResolved(uint8,uint256,address,uint256,uint256)");
        bool sawCrowned;
        bool sawResolved;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == crownedSig) sawCrowned = true;
            if (logs[i].topics[0] == resolvedSig) sawResolved = true;
        }
        assertTrue(sawResolved, "expected ChallengeResolved");
        assertFalse(sawCrowned, "should NOT emit ChampionCrowned when champion stays");

        // Now do a flip and confirm we DO emit ChampionCrowned.
        vm.warp(block.timestamp + COOLDOWN + 1);
        _challenge(carol, ClawdSearch.Category.Cutest, 3);
        _vote(carol, ClawdSearch.Category.Cutest, true);
        vm.warp(block.timestamp + CHALLENGE_DURATION);

        vm.recordLogs();
        cs.resolve(ClawdSearch.Category.Cutest);
        logs = vm.getRecordedLogs();
        sawCrowned = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == crownedSig) sawCrowned = true;
        }
        assertTrue(sawCrowned, "expected ChampionCrowned on flip");
    }

    function test_resolve_revertsBeforeWindow() public {
        _submit(alice, ClawdSearch.Category.Cutest, 1);
        _challenge(bob, ClawdSearch.Category.Cutest, 2);
        vm.expectRevert(ClawdSearch.ChallengeWindowOpen.selector);
        cs.resolve(ClawdSearch.Category.Cutest);
    }

    function test_resolve_revertsNoActive() public {
        _submit(alice, ClawdSearch.Category.Cutest, 1);
        vm.expectRevert(ClawdSearch.ChallengeNotActive.selector);
        cs.resolve(ClawdSearch.Category.Cutest);
    }
}

// =========================================================================
//                               ADMIN TESTS
// =========================================================================

contract ClawdSearchAdminTest is ClawdSearchTestBase {
    function test_setTreasury_ownerOnly() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        cs.setTreasury(address(0xBEEF));
    }

    function test_setTreasury_revertsZero() public {
        vm.prank(owner);
        vm.expectRevert(ClawdSearch.ZeroAddress.selector);
        cs.setTreasury(address(0));
    }

    function test_setTreasury_happy() public {
        vm.prank(owner);
        cs.setTreasury(address(0xBEEF));
        assertEq(cs.treasury(), address(0xBEEF));
    }

    function test_setPrices_ownerOnly() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        cs.setPrices(1, 2, 3);
    }

    function test_setPrices_acceptsZero() public {
        vm.prank(owner);
        cs.setPrices(0, 0, 0);
        assertEq(cs.submitPrice(), 0);
        assertEq(cs.challengePrice(), 0);
        assertEq(cs.votePrice(), 0);
    }

    function test_ownable2Step_transferOwnership() public {
        vm.prank(owner);
        cs.transferOwnership(alice);
        // Two-step: pending owner needs to accept.
        assertEq(cs.owner(), owner);
        assertEq(cs.pendingOwner(), alice);
        vm.prank(alice);
        cs.acceptOwnership();
        assertEq(cs.owner(), alice);
    }

    // -----------------------------------------------------------------------
    // M-2: renounceOwnership is permanently disabled
    // -----------------------------------------------------------------------

    function test_renounceOwnership_revertsForOwner() public {
        vm.prank(owner);
        vm.expectRevert(ClawdSearch.OwnershipCannotBeRenounced.selector);
        cs.renounceOwnership();
        // Owner unchanged.
        assertEq(cs.owner(), owner);
    }

    function test_renounceOwnership_revertsForNonOwner() public {
        // OZ Ownable's `onlyOwner` check fires first, so a non-owner sees
        // OwnableUnauthorizedAccount, not OwnershipCannotBeRenounced. Either way,
        // the function never zeroes the owner.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        cs.renounceOwnership();
        assertEq(cs.owner(), owner);
    }
}

// =========================================================================
//                        AUDIT-DRIVEN FIX TESTS (M-3..M-5, L-2)
// =========================================================================

contract ClawdSearchAuditFixesTest is ClawdSearchTestBase {
    address constant BURN = 0x000000000000000000000000000000000000dEaD;

    // -----------------------------------------------------------------------
    // M-3: odd-amount split — burn gets the LARGER half (101 → 51 burn, 50 treasury)
    // -----------------------------------------------------------------------

    function test_oddAmountSplit_burnGetsLargerHalf() public {
        // Set submitPrice to a tiny odd wei value so we can do exact arithmetic.
        vm.prank(owner);
        cs.setPrices(101, 0, 0);

        uint256 aliceBefore = clawd.balanceOf(alice);
        uint256 burnBefore = clawd.balanceOf(BURN);
        uint256 trBefore = clawd.balanceOf(TREASURY);

        _submit(alice, ClawdSearch.Category.Cutest, 7);

        // 101 → 50 treasury, 51 burn
        assertEq(clawd.balanceOf(alice), aliceBefore - 101);
        assertEq(clawd.balanceOf(BURN), burnBefore + 51);
        assertEq(clawd.balanceOf(TREASURY), trBefore + 50);
    }

    // -----------------------------------------------------------------------
    // M-4: hasVoted round-scoping across consecutive challenges
    // -----------------------------------------------------------------------

    function test_hasVoted_roundScopingAcrossConsecutiveChallenges() public {
        _submit(alice, ClawdSearch.Category.Cutest, 1);
        _challenge(bob, ClawdSearch.Category.Cutest, 2);

        // Round 1: carol votes for the champion (alice).
        _vote(carol, ClawdSearch.Category.Cutest, false);
        ClawdSearch.CategoryState memory s1 = cs.getCategory(ClawdSearch.Category.Cutest);
        assertEq(s1.challengeRound, 1);
        assertTrue(cs.hasVoted(ClawdSearch.Category.Cutest, 1, carol));

        // Resolve — alice (champion) wins 1-0; bob's obs 2 is locked out.
        vm.warp(block.timestamp + CHALLENGE_DURATION);
        cs.resolve(ClawdSearch.Category.Cutest);

        // Cooldown elapses, new challenger (dave with obs 3) opens round 2.
        vm.warp(block.timestamp + COOLDOWN + 1);
        _challenge(dave, ClawdSearch.Category.Cutest, 3);

        ClawdSearch.CategoryState memory s2 = cs.getCategory(ClawdSearch.Category.Cutest);
        assertEq(s2.challengeRound, 2);

        // Carol must be able to vote again — hasVoted is keyed by round.
        _vote(carol, ClawdSearch.Category.Cutest, true);
        assertTrue(cs.hasVoted(ClawdSearch.Category.Cutest, 2, carol));

        // And carol still shows as having voted in round 1 (per-round storage is independent).
        assertTrue(cs.hasVoted(ClawdSearch.Category.Cutest, 1, carol));

        // A second vote in round 2 reverts.
        vm.prank(carol);
        vm.expectRevert(ClawdSearch.AlreadyVoted.selector);
        cs.vote(ClawdSearch.Category.Cutest, true);
    }

    // -----------------------------------------------------------------------
    // M-5: SafeERC20 revert paths — insufficient allowance / balance
    // -----------------------------------------------------------------------

    function test_submit_revertsOnInsufficientAllowance() public {
        // Drop alice's approval below submitPrice.
        vm.prank(alice);
        clawd.approve(address(cs), SUBMIT_PRICE - 1);

        vm.prank(alice);
        // OZ ERC20 v5 uses custom errors. The exact error is
        // ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed).
        vm.expectRevert();
        cs.submit(ClawdSearch.Category.Cutest, 1);
    }

    function test_submit_revertsOnInsufficientBalance() public {
        // Drain alice's balance.
        uint256 bal = clawd.balanceOf(alice);
        vm.prank(alice);
        clawd.transfer(address(0xDEADBEEF), bal);
        assertEq(clawd.balanceOf(alice), 0);

        vm.prank(alice);
        vm.expectRevert();
        cs.submit(ClawdSearch.Category.Cutest, 1);
    }

    // -----------------------------------------------------------------------
    // M-5: setPrices(0,0,0) makes the full cycle free
    // -----------------------------------------------------------------------

    function test_setPrices_zeroAllowsFullCycleWithoutPaying() public {
        vm.prank(owner);
        cs.setPrices(0, 0, 0);

        // Drain alice and bob to prove no token movement is required.
        uint256 aBal = clawd.balanceOf(alice);
        uint256 bBal = clawd.balanceOf(bob);
        uint256 cBal = clawd.balanceOf(carol);
        uint256 dBal = clawd.balanceOf(dave);
        vm.prank(alice);
        clawd.transfer(address(0xDEAD01), aBal);
        vm.prank(bob);
        clawd.transfer(address(0xDEAD02), bBal);
        vm.prank(carol);
        clawd.transfer(address(0xDEAD03), cBal);
        vm.prank(dave);
        clawd.transfer(address(0xDEAD04), dBal);

        assertEq(clawd.balanceOf(alice), 0);
        assertEq(clawd.balanceOf(bob), 0);
        assertEq(clawd.balanceOf(carol), 0);
        assertEq(clawd.balanceOf(dave), 0);

        uint256 burnBefore = clawd.balanceOf(BURN);
        uint256 trBefore = clawd.balanceOf(TREASURY);

        // Full cycle: submit → challenge → vote → resolve, all free.
        _submit(alice, ClawdSearch.Category.Cutest, 1);
        _challenge(bob, ClawdSearch.Category.Cutest, 2);
        _vote(carol, ClawdSearch.Category.Cutest, true);
        _vote(dave, ClawdSearch.Category.Cutest, true);
        vm.warp(block.timestamp + CHALLENGE_DURATION);
        cs.resolve(ClawdSearch.Category.Cutest);

        // No CLAWD moved.
        assertEq(clawd.balanceOf(BURN), burnBefore);
        assertEq(clawd.balanceOf(TREASURY), trBefore);

        // Tournament state advanced as expected (challenger bob is now champion).
        ClawdSearch.CategoryState memory s = cs.getCategory(ClawdSearch.Category.Cutest);
        assertEq(s.championObsId, 2);
        assertEq(s.championOwner, bob);
    }

    // -----------------------------------------------------------------------
    // M-5: setTreasury actually routes the next spend
    // -----------------------------------------------------------------------

    function test_setTreasury_routesNextSpendToNewAddress() public {
        address newTreasury = address(0xBEEF);
        vm.prank(owner);
        cs.setTreasury(newTreasury);

        uint256 oldTrBefore = clawd.balanceOf(TREASURY);
        uint256 newTrBefore = clawd.balanceOf(newTreasury);

        _submit(alice, ClawdSearch.Category.Cutest, 1);

        // Old treasury balance is unchanged.
        assertEq(clawd.balanceOf(TREASURY), oldTrBefore);
        // New treasury received the 500 CLAWD half.
        assertEq(clawd.balanceOf(newTreasury), newTrBefore + 500 * 1e18);
    }

    // -----------------------------------------------------------------------
    // M-5: vm.expectEmit field-level matching on player-facing events
    // -----------------------------------------------------------------------

    function test_emit_championCrowned_onSubmit() public {
        // ChampionCrowned has 3 indexed: category, observationId, submitter — and no data fields.
        vm.expectEmit(true, true, true, true, address(cs));
        emit ClawdSearch.ChampionCrowned(ClawdSearch.Category.Cutest, 42, alice);
        _submit(alice, ClawdSearch.Category.Cutest, 42);
    }

    function test_emit_challengeStarted_onChallenge() public {
        _submit(alice, ClawdSearch.Category.Cutest, 1);

        vm.expectEmit(true, true, true, true, address(cs));
        emit ClawdSearch.ChallengeStarted(ClawdSearch.Category.Cutest, 7, bob);
        _challenge(bob, ClawdSearch.Category.Cutest, 7);
    }

    function test_emit_voteCast_onVote() public {
        _submit(alice, ClawdSearch.Category.Cutest, 1);
        _challenge(bob, ClawdSearch.Category.Cutest, 2);

        // VoteCast indexes category + voter; data field is `forChallenger`.
        vm.expectEmit(true, true, true, true, address(cs));
        emit ClawdSearch.VoteCast(ClawdSearch.Category.Cutest, carol, true);
        _vote(carol, ClawdSearch.Category.Cutest, true);
    }

    function test_emit_challengeResolved_onResolve() public {
        _submit(alice, ClawdSearch.Category.Cutest, 1);
        _challenge(bob, ClawdSearch.Category.Cutest, 2);
        _vote(carol, ClawdSearch.Category.Cutest, true);
        _vote(dave, ClawdSearch.Category.Cutest, true);
        // Champion (alice) gets 0 votes; challenger (bob) gets 2 → bob wins, obs 2.

        vm.warp(block.timestamp + CHALLENGE_DURATION);

        vm.expectEmit(true, true, true, true, address(cs));
        emit ClawdSearch.ChallengeResolved(ClawdSearch.Category.Cutest, 2, bob, 0, 2);
        cs.resolve(ClawdSearch.Category.Cutest);
    }

    // -----------------------------------------------------------------------
    // L-2: constructor emits initial TreasuryUpdated and PricesUpdated events
    // -----------------------------------------------------------------------

    function test_constructor_emitsInitialConfigEvents() public {
        // Use vm.recordLogs around a fresh deployment to capture constructor emits.
        vm.recordLogs();
        ClawdSearch fresh = new ClawdSearch(owner);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 treasurySig = keccak256("TreasuryUpdated(address)");
        bytes32 pricesSig = keccak256("PricesUpdated(uint256,uint256,uint256)");

        bool sawTreasury;
        bool sawPrices;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(fresh)) continue;
            if (logs[i].topics[0] == treasurySig) {
                sawTreasury = true;
                // newTreasury is indexed → topics[1].
                assertEq(address(uint160(uint256(logs[i].topics[1]))), 0x90eF2A9211A3E7CE788561E5af54C76B0Fa3aEd0);
            } else if (logs[i].topics[0] == pricesSig) {
                sawPrices = true;
                // All three prices are non-indexed data.
                (uint256 sP, uint256 cP, uint256 vP) = abi.decode(logs[i].data, (uint256, uint256, uint256));
                assertEq(sP, SUBMIT_PRICE);
                assertEq(cP, CHALLENGE_PRICE);
                assertEq(vP, VOTE_PRICE);
            }
        }
        assertTrue(sawTreasury, "constructor should emit TreasuryUpdated");
        assertTrue(sawPrices, "constructor should emit PricesUpdated");
    }
}
