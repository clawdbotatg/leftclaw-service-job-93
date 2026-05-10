// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { ClawdSearch } from "../contracts/ClawdSearch.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

contract MockClawd is ERC20 {
    constructor() ERC20("Clawd", "CLAWD") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

abstract contract ClawdSearchTestBase is Test {
    address constant CLAWD_ADDR = 0x9f86dB9fc6f7c9408e8Fda3Ff8ce4e78ac7a6b07;
    address constant TREASURY = 0x90eF2A9211A3E7CE788561E5af54C76B0Fa3aEd0;

    // Seeded category IDs (constructor order)
    uint256 constant CAT_PUDGY_PENGUIN = 0;
    uint256 constant CAT_DAPPER_LOBSTER = 1;
    uint256 constant CAT_PEPE_FROG = 2;
    uint256 constant CAT_CUTEST = 3;
    uint256 constant CAT_CAMOUFLAGE = 4;
    uint256 constant CAT_BEST_EYES = 5;

    ClawdSearch internal cs;
    MockClawd internal clawd;

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
        MockClawd template = new MockClawd();
        bytes memory rt = address(template).code;
        vm.etch(CLAWD_ADDR, rt);
        clawd = MockClawd(CLAWD_ADDR);

        cs = new ClawdSearch(owner);

        for (uint256 i = 0; i < 4; i++) {
            address user = [alice, bob, carol, dave][i];
            clawd.mint(user, 10_000_000 * 1e18);
            vm.prank(user);
            clawd.approve(address(cs), type(uint256).max);
        }
    }

    function _submit(address who, uint256 catId, uint256 obsId) internal {
        vm.prank(who);
        cs.submit(catId, obsId);
    }

    function _challenge(address who, uint256 catId, uint256 obsId) internal {
        vm.prank(who);
        cs.challenge(catId, obsId);
    }

    function _vote(address who, uint256 catId, bool forChallenger) internal {
        vm.prank(who);
        cs.vote(catId, forChallenger);
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

        _submit(alice, CAT_CUTEST, 42);

        assertEq(clawd.balanceOf(alice), aliceBalBefore - SUBMIT_PRICE);
        assertEq(clawd.balanceOf(0x000000000000000000000000000000000000dEaD), burnBefore + 500 * 1e18);
        assertEq(clawd.balanceOf(TREASURY), trBefore + 500 * 1e18);

        ClawdSearch.CategoryState memory s = cs.getCategory(CAT_CUTEST);
        assertEq(s.championObsId, 42);
        assertEq(s.championOwner, alice);
        assertEq(s.reignStart, uint64(block.timestamp));

        (uint128 submitted, uint128 won, uint256 reign) = cs.userStats(alice);
        assertEq(submitted, 1);
        assertEq(won, 0);
        assertEq(reign, 0);
    }

    function test_submit_revertsWhenCategoryAlreadyHasChampion() public {
        _submit(alice, CAT_CUTEST, 42);
        vm.prank(bob);
        vm.expectRevert(ClawdSearch.CategoryAlreadyHasChampion.selector);
        cs.submit(CAT_CUTEST, 99);
    }

    function test_submit_revertsOnZeroObsId() public {
        vm.prank(alice);
        vm.expectRevert(ClawdSearch.InvalidObservation.selector);
        cs.submit(CAT_CUTEST, 0);
    }

    function test_submit_revertsOnNonexistentCategory() public {
        vm.prank(alice);
        vm.expectRevert(ClawdSearch.CategoryDoesNotExist.selector);
        cs.submit(999, 1);
    }
}

// =========================================================================
//                            CHALLENGE TESTS
// =========================================================================

contract ClawdSearchChallengeTest is ClawdSearchTestBase {
    function test_challenge_setsChallengerAndOpensWindow() public {
        _submit(alice, CAT_CUTEST, 1);

        uint256 bobBalBefore = clawd.balanceOf(bob);
        _challenge(bob, CAT_CUTEST, 2);

        ClawdSearch.CategoryState memory s = cs.getCategory(CAT_CUTEST);
        assertEq(s.challengerObsId, 2);
        assertEq(s.challengerOwner, bob);
        assertEq(s.challengeStart, uint64(block.timestamp));
        assertEq(s.challengeRound, 1);

        assertEq(clawd.balanceOf(bob), bobBalBefore - CHALLENGE_PRICE);
        assertTrue(cs.isChallengeActive(CAT_CUTEST));
    }

    function test_challenge_revertsNoChampion() public {
        vm.prank(alice);
        vm.expectRevert(ClawdSearch.CategoryHasNoChampion.selector);
        cs.challenge(CAT_CUTEST, 7);
    }

    function test_challenge_revertsAlreadyActive() public {
        _submit(alice, CAT_CUTEST, 1);
        _challenge(bob, CAT_CUTEST, 2);
        vm.prank(carol);
        vm.expectRevert(ClawdSearch.ChallengeAlreadyActive.selector);
        cs.challenge(CAT_CUTEST, 3);
    }

    function test_challenge_revertsOnCooldown() public {
        _submit(alice, CAT_CUTEST, 1);
        _challenge(bob, CAT_CUTEST, 2);
        _vote(alice, CAT_CUTEST, false);
        vm.warp(block.timestamp + CHALLENGE_DURATION);
        cs.resolve(CAT_CUTEST);
        vm.prank(carol);
        vm.expectRevert(ClawdSearch.OnCooldown.selector);
        cs.challenge(CAT_CUTEST, 3);

        vm.warp(block.timestamp + COOLDOWN + 1);
        _challenge(carol, CAT_CUTEST, 3);
    }

    function test_challenge_revertsLockedOut() public {
        _submit(alice, CAT_CUTEST, 1);
        _challenge(bob, CAT_CUTEST, 2);
        _vote(alice, CAT_CUTEST, false);
        vm.warp(block.timestamp + CHALLENGE_DURATION);
        cs.resolve(CAT_CUTEST);
        vm.warp(block.timestamp + COOLDOWN + 1);

        vm.prank(carol);
        vm.expectRevert(ClawdSearch.ObservationLockedOut.selector);
        cs.challenge(CAT_CUTEST, 2);
    }

    function test_challenge_revertsSameAsChampion() public {
        _submit(alice, CAT_CUTEST, 1);
        vm.prank(bob);
        vm.expectRevert(ClawdSearch.SameAsChampion.selector);
        cs.challenge(CAT_CUTEST, 1);
    }

    function test_challenge_revertsZeroId() public {
        _submit(alice, CAT_CUTEST, 1);
        vm.prank(bob);
        vm.expectRevert(ClawdSearch.InvalidObservation.selector);
        cs.challenge(CAT_CUTEST, 0);
    }
}

// =========================================================================
//                              VOTE TESTS
// =========================================================================

contract ClawdSearchVoteTest is ClawdSearchTestBase {
    function test_vote_incrementsCorrectSide() public {
        _submit(alice, CAT_CUTEST, 1);
        _challenge(bob, CAT_CUTEST, 2);

        _vote(carol, CAT_CUTEST, true);
        _vote(dave, CAT_CUTEST, false);

        ClawdSearch.CategoryState memory s = cs.getCategory(CAT_CUTEST);
        assertEq(s.challengerVotes, 1);
        assertEq(s.championVotes, 1);
        assertTrue(cs.hasVoted(CAT_CUTEST, s.challengeRound, carol));
        assertTrue(cs.hasVoted(CAT_CUTEST, s.challengeRound, dave));
    }

    function test_vote_revertsNoActiveChallenge() public {
        _submit(alice, CAT_CUTEST, 1);
        vm.prank(bob);
        vm.expectRevert(ClawdSearch.ChallengeNotActive.selector);
        cs.vote(CAT_CUTEST, true);
    }

    function test_vote_revertsWindowClosed() public {
        _submit(alice, CAT_CUTEST, 1);
        _challenge(bob, CAT_CUTEST, 2);
        vm.warp(block.timestamp + CHALLENGE_DURATION);
        vm.prank(carol);
        vm.expectRevert(ClawdSearch.ChallengeWindowClosed.selector);
        cs.vote(CAT_CUTEST, true);
    }

    function test_vote_revertsAlreadyVoted() public {
        _submit(alice, CAT_CUTEST, 1);
        _challenge(bob, CAT_CUTEST, 2);
        _vote(carol, CAT_CUTEST, true);
        vm.prank(carol);
        vm.expectRevert(ClawdSearch.AlreadyVoted.selector);
        cs.vote(CAT_CUTEST, false);
    }

    function test_vote_separatePerCategory() public {
        _submit(alice, CAT_CUTEST, 1);
        _submit(alice, CAT_DAPPER_LOBSTER, 11);
        _challenge(bob, CAT_CUTEST, 2);
        _challenge(bob, CAT_DAPPER_LOBSTER, 12);

        _vote(carol, CAT_CUTEST, true);
        _vote(carol, CAT_DAPPER_LOBSTER, false);
    }
}

// =========================================================================
//                             RESOLVE TESTS
// =========================================================================

contract ClawdSearchResolveTest is ClawdSearchTestBase {
    function test_resolve_challengerWinsOnMoreVotes() public {
        _submit(alice, CAT_CUTEST, 1);
        uint256 reignStart = block.timestamp;
        vm.warp(reignStart + 1 hours);
        _challenge(bob, CAT_CUTEST, 2);
        _vote(carol, CAT_CUTEST, true);
        _vote(dave, CAT_CUTEST, true);
        _vote(alice, CAT_CUTEST, false);

        vm.warp(block.timestamp + CHALLENGE_DURATION);
        cs.resolve(CAT_CUTEST);

        ClawdSearch.CategoryState memory s = cs.getCategory(CAT_CUTEST);
        assertEq(s.championObsId, 2);
        assertEq(s.championOwner, bob);
        assertEq(s.challengerObsId, 0);
        assertEq(s.championVotes, 0);
        assertEq(s.challengerVotes, 0);
        assertEq(s.cooldownEnd, uint64(block.timestamp + COOLDOWN));

        (, , uint256 aliceReign) = cs.userStats(alice);
        assertEq(aliceReign, block.timestamp - reignStart);

        (, uint128 bobWon, ) = cs.userStats(bob);
        assertEq(bobWon, 1);

        assertEq(cs.categoryChampionWins(CAT_CUTEST, 2), 1);
        assertTrue(cs.hasLostInCategory(CAT_CUTEST, 1));
    }

    function test_resolve_championWinsOnTie() public {
        _submit(alice, CAT_CUTEST, 1);
        _challenge(bob, CAT_CUTEST, 2);
        _vote(carol, CAT_CUTEST, true);
        _vote(dave, CAT_CUTEST, false);

        vm.warp(block.timestamp + CHALLENGE_DURATION);
        cs.resolve(CAT_CUTEST);

        ClawdSearch.CategoryState memory s = cs.getCategory(CAT_CUTEST);
        assertEq(s.championObsId, 1);
        assertEq(s.championOwner, alice);

        assertTrue(cs.hasLostInCategory(CAT_CUTEST, 2));
        assertEq(cs.categoryChampionWins(CAT_CUTEST, 1), 1);

        (, , uint256 aliceReign) = cs.userStats(alice);
        assertEq(aliceReign, 0);
    }

    function test_resolve_challengerWinsOnZeroVotes() public {
        _submit(alice, CAT_CUTEST, 1);
        _challenge(bob, CAT_CUTEST, 2);

        vm.warp(block.timestamp + CHALLENGE_DURATION);
        cs.resolve(CAT_CUTEST);

        ClawdSearch.CategoryState memory s = cs.getCategory(CAT_CUTEST);
        assertEq(s.championObsId, 2);
        assertEq(s.championOwner, bob);
    }

    function test_resolve_loserLockedOutCategoryButCanPlayOthers() public {
        _submit(alice, CAT_CUTEST, 1);
        _submit(alice, CAT_DAPPER_LOBSTER, 100);
        _challenge(bob, CAT_CUTEST, 2);
        _vote(alice, CAT_CUTEST, false);
        vm.warp(block.timestamp + CHALLENGE_DURATION);
        cs.resolve(CAT_CUTEST);

        assertTrue(cs.hasLostInCategory(CAT_CUTEST, 2));
        assertFalse(cs.hasLostInCategory(CAT_DAPPER_LOBSTER, 2));

        _challenge(bob, CAT_DAPPER_LOBSTER, 2);
        ClawdSearch.CategoryState memory s = cs.getCategory(CAT_DAPPER_LOBSTER);
        assertEq(s.challengerObsId, 2);
    }

    function test_resolve_emitsChampionCrownedOnlyWhenChampionChanges() public {
        _submit(alice, CAT_CUTEST, 1);
        _challenge(bob, CAT_CUTEST, 2);
        _vote(alice, CAT_CUTEST, false);

        vm.warp(block.timestamp + CHALLENGE_DURATION);

        vm.recordLogs();
        cs.resolve(CAT_CUTEST);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 crownedSig = keccak256("ChampionCrowned(uint256,uint256,address)");
        bytes32 resolvedSig = keccak256("ChallengeResolved(uint256,uint256,address,uint256,uint256)");
        bool sawCrowned;
        bool sawResolved;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == crownedSig) sawCrowned = true;
            if (logs[i].topics[0] == resolvedSig) sawResolved = true;
        }
        assertTrue(sawResolved, "expected ChallengeResolved");
        assertFalse(sawCrowned, "should NOT emit ChampionCrowned when champion stays");

        vm.warp(block.timestamp + COOLDOWN + 1);
        _challenge(carol, CAT_CUTEST, 3);
        _vote(carol, CAT_CUTEST, true);
        vm.warp(block.timestamp + CHALLENGE_DURATION);

        vm.recordLogs();
        cs.resolve(CAT_CUTEST);
        logs = vm.getRecordedLogs();
        sawCrowned = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == crownedSig) sawCrowned = true;
        }
        assertTrue(sawCrowned, "expected ChampionCrowned on flip");
    }

    function test_resolve_revertsBeforeWindow() public {
        _submit(alice, CAT_CUTEST, 1);
        _challenge(bob, CAT_CUTEST, 2);
        vm.expectRevert(ClawdSearch.ChallengeWindowOpen.selector);
        cs.resolve(CAT_CUTEST);
    }

    function test_resolve_revertsNoActive() public {
        _submit(alice, CAT_CUTEST, 1);
        vm.expectRevert(ClawdSearch.ChallengeNotActive.selector);
        cs.resolve(CAT_CUTEST);
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
        assertEq(cs.owner(), owner);
        assertEq(cs.pendingOwner(), alice);
        vm.prank(alice);
        cs.acceptOwnership();
        assertEq(cs.owner(), alice);
    }

    function test_renounceOwnership_revertsForOwner() public {
        vm.prank(owner);
        vm.expectRevert(ClawdSearch.OwnershipCannotBeRenounced.selector);
        cs.renounceOwnership();
        assertEq(cs.owner(), owner);
    }

    function test_renounceOwnership_revertsForNonOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        cs.renounceOwnership();
        assertEq(cs.owner(), owner);
    }

    function test_addCategory_ownerOnly() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        cs.addCategory("New Cat", 12345);
    }

    function test_addCategory_incrementsNextId() public {
        assertEq(cs.nextCategoryId(), 6); // 6 seeded in constructor
        vm.prank(owner);
        uint256 newId = cs.addCategory("Best Tail", 9999);
        assertEq(newId, 6);
        assertEq(cs.nextCategoryId(), 7);
        ClawdSearch.CategoryData memory d = cs.getCategoryData(6);
        assertEq(d.name, "Best Tail");
        assertEq(d.taxonId, 9999);
        assertTrue(d.active);
    }

    function test_setCategoryActive_toggles() public {
        // All seeded categories start active.
        ClawdSearch.CategoryData memory d = cs.getCategoryData(CAT_CUTEST);
        assertTrue(d.active);

        vm.prank(owner);
        cs.setCategoryActive(CAT_CUTEST, false);
        d = cs.getCategoryData(CAT_CUTEST);
        assertFalse(d.active);

        // Submit should now revert.
        vm.prank(alice);
        vm.expectRevert(ClawdSearch.CategoryNotActive.selector);
        cs.submit(CAT_CUTEST, 1);

        // Re-enable.
        vm.prank(owner);
        cs.setCategoryActive(CAT_CUTEST, true);
        _submit(alice, CAT_CUTEST, 1);
    }

    function test_constructor_seeds6Categories() public {
        assertEq(cs.nextCategoryId(), 6);
        ClawdSearch.CategoryData memory d0 = cs.getCategoryData(0);
        assertEq(d0.name, "Most Pudgy Penguin");
        assertEq(d0.taxonId, 3956);
        assertTrue(d0.active);
        ClawdSearch.CategoryData memory d3 = cs.getCategoryData(3);
        assertEq(d3.name, "Cutest");
        assertEq(d3.taxonId, 1);
        assertTrue(d3.active);
    }
}

// =========================================================================
//                        AUDIT-DRIVEN FIX TESTS
// =========================================================================

contract ClawdSearchAuditFixesTest is ClawdSearchTestBase {
    address constant BURN = 0x000000000000000000000000000000000000dEaD;

    function test_oddAmountSplit_burnGetsLargerHalf() public {
        vm.prank(owner);
        cs.setPrices(101, 0, 0);

        uint256 aliceBefore = clawd.balanceOf(alice);
        uint256 burnBefore = clawd.balanceOf(BURN);
        uint256 trBefore = clawd.balanceOf(TREASURY);

        _submit(alice, CAT_CUTEST, 7);

        assertEq(clawd.balanceOf(alice), aliceBefore - 101);
        assertEq(clawd.balanceOf(BURN), burnBefore + 51);
        assertEq(clawd.balanceOf(TREASURY), trBefore + 50);
    }

    function test_hasVoted_roundScopingAcrossConsecutiveChallenges() public {
        _submit(alice, CAT_CUTEST, 1);
        _challenge(bob, CAT_CUTEST, 2);

        _vote(carol, CAT_CUTEST, false);
        ClawdSearch.CategoryState memory s1 = cs.getCategory(CAT_CUTEST);
        assertEq(s1.challengeRound, 1);
        assertTrue(cs.hasVoted(CAT_CUTEST, 1, carol));

        vm.warp(block.timestamp + CHALLENGE_DURATION);
        cs.resolve(CAT_CUTEST);

        vm.warp(block.timestamp + COOLDOWN + 1);
        _challenge(dave, CAT_CUTEST, 3);

        ClawdSearch.CategoryState memory s2 = cs.getCategory(CAT_CUTEST);
        assertEq(s2.challengeRound, 2);

        _vote(carol, CAT_CUTEST, true);
        assertTrue(cs.hasVoted(CAT_CUTEST, 2, carol));
        assertTrue(cs.hasVoted(CAT_CUTEST, 1, carol));

        vm.prank(carol);
        vm.expectRevert(ClawdSearch.AlreadyVoted.selector);
        cs.vote(CAT_CUTEST, true);
    }

    function test_submit_revertsOnInsufficientAllowance() public {
        vm.prank(alice);
        clawd.approve(address(cs), SUBMIT_PRICE - 1);

        vm.prank(alice);
        vm.expectRevert();
        cs.submit(CAT_CUTEST, 1);
    }

    function test_submit_revertsOnInsufficientBalance() public {
        uint256 bal = clawd.balanceOf(alice);
        vm.prank(alice);
        clawd.transfer(address(0xDEADBEEF), bal);
        assertEq(clawd.balanceOf(alice), 0);

        vm.prank(alice);
        vm.expectRevert();
        cs.submit(CAT_CUTEST, 1);
    }

    function test_setPrices_zeroAllowsFullCycleWithoutPaying() public {
        vm.prank(owner);
        cs.setPrices(0, 0, 0);

        uint256 aBal = clawd.balanceOf(alice);
        uint256 bBal = clawd.balanceOf(bob);
        uint256 cBal = clawd.balanceOf(carol);
        uint256 dBal = clawd.balanceOf(dave);
        vm.prank(alice); clawd.transfer(address(0xDEAD01), aBal);
        vm.prank(bob);   clawd.transfer(address(0xDEAD02), bBal);
        vm.prank(carol); clawd.transfer(address(0xDEAD03), cBal);
        vm.prank(dave);  clawd.transfer(address(0xDEAD04), dBal);

        assertEq(clawd.balanceOf(alice), 0);
        assertEq(clawd.balanceOf(bob), 0);

        uint256 burnBefore = clawd.balanceOf(BURN);
        uint256 trBefore = clawd.balanceOf(TREASURY);

        _submit(alice, CAT_CUTEST, 1);
        _challenge(bob, CAT_CUTEST, 2);
        _vote(carol, CAT_CUTEST, true);
        _vote(dave, CAT_CUTEST, true);
        vm.warp(block.timestamp + CHALLENGE_DURATION);
        cs.resolve(CAT_CUTEST);

        assertEq(clawd.balanceOf(BURN), burnBefore);
        assertEq(clawd.balanceOf(TREASURY), trBefore);

        ClawdSearch.CategoryState memory s = cs.getCategory(CAT_CUTEST);
        assertEq(s.championObsId, 2);
        assertEq(s.championOwner, bob);
    }

    function test_setTreasury_routesNextSpendToNewAddress() public {
        address newTreasury = address(0xBEEF);
        vm.prank(owner);
        cs.setTreasury(newTreasury);

        uint256 oldTrBefore = clawd.balanceOf(TREASURY);
        uint256 newTrBefore = clawd.balanceOf(newTreasury);

        _submit(alice, CAT_CUTEST, 1);

        assertEq(clawd.balanceOf(TREASURY), oldTrBefore);
        assertEq(clawd.balanceOf(newTreasury), newTrBefore + 500 * 1e18);
    }

    function test_emit_championCrowned_onSubmit() public {
        vm.expectEmit(true, true, true, true, address(cs));
        emit ClawdSearch.ChampionCrowned(CAT_CUTEST, 42, alice);
        _submit(alice, CAT_CUTEST, 42);
    }

    function test_emit_challengeStarted_onChallenge() public {
        _submit(alice, CAT_CUTEST, 1);

        vm.expectEmit(true, true, true, true, address(cs));
        emit ClawdSearch.ChallengeStarted(CAT_CUTEST, 7, bob);
        _challenge(bob, CAT_CUTEST, 7);
    }

    function test_emit_voteCast_onVote() public {
        _submit(alice, CAT_CUTEST, 1);
        _challenge(bob, CAT_CUTEST, 2);

        vm.expectEmit(true, true, true, true, address(cs));
        emit ClawdSearch.VoteCast(CAT_CUTEST, carol, true);
        _vote(carol, CAT_CUTEST, true);
    }

    function test_emit_challengeResolved_onResolve() public {
        _submit(alice, CAT_CUTEST, 1);
        _challenge(bob, CAT_CUTEST, 2);
        _vote(carol, CAT_CUTEST, true);
        _vote(dave, CAT_CUTEST, true);

        vm.warp(block.timestamp + CHALLENGE_DURATION);

        vm.expectEmit(true, true, true, true, address(cs));
        emit ClawdSearch.ChallengeResolved(CAT_CUTEST, 2, bob, 0, 2);
        cs.resolve(CAT_CUTEST);
    }

    function test_constructor_emitsInitialConfigEvents() public {
        vm.recordLogs();
        ClawdSearch fresh = new ClawdSearch(owner);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 treasurySig = keccak256("TreasuryUpdated(address)");
        bytes32 pricesSig = keccak256("PricesUpdated(uint256,uint256,uint256)");
        bytes32 categoryAddedSig = keccak256("CategoryAdded(uint256,string,uint32)");

        bool sawTreasury;
        bool sawPrices;
        uint256 categoryAddedCount;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(fresh)) continue;
            if (logs[i].topics[0] == treasurySig) {
                sawTreasury = true;
                assertEq(address(uint160(uint256(logs[i].topics[1]))), 0x90eF2A9211A3E7CE788561E5af54C76B0Fa3aEd0);
            } else if (logs[i].topics[0] == pricesSig) {
                sawPrices = true;
                (uint256 sP, uint256 cP, uint256 vP) = abi.decode(logs[i].data, (uint256, uint256, uint256));
                assertEq(sP, SUBMIT_PRICE);
                assertEq(cP, CHALLENGE_PRICE);
                assertEq(vP, VOTE_PRICE);
            } else if (logs[i].topics[0] == categoryAddedSig) {
                categoryAddedCount++;
            }
        }
        assertTrue(sawTreasury, "constructor should emit TreasuryUpdated");
        assertTrue(sawPrices, "constructor should emit PricesUpdated");
        assertEq(categoryAddedCount, 6, "constructor should emit 6 CategoryAdded events");
    }
}
