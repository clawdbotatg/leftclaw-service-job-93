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
}
