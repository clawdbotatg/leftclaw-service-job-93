// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { ClawdSearch } from "../contracts/ClawdSearch.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

// =========================================================================
//                              MOCK CONTRACTS
// =========================================================================

contract MockClawd is ERC20 {
    constructor() ERC20("Clawd", "CLAWD") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Swaps CLAWD for mock USDC at a fixed rate (1000 CLAWD = 1 USDC in 6-decimal units).
///      Uses immutable USDC address so vm.etch captures it in bytecode.
contract MockSwapRouter {
    address private immutable usdc;

    constructor(address _usdc) {
        usdc = _usdc;
    }

    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256) {
        IERC20(params.tokenIn).transferFrom(msg.sender, address(this), params.amountIn);
        uint256 out = params.amountIn / 1e12; // 1e18 CLAWD → 1e6 USDC
        MockUSDC(usdc).mint(params.recipient, out);
        return out;
    }

    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(ExactInputParams calldata params) external payable returns (uint256) {
        address tokenIn;
        bytes memory path = params.path;
        assembly {
            tokenIn := shr(96, mload(add(path, 0x20)))
        }
        IERC20(tokenIn).transferFrom(msg.sender, address(this), params.amountIn);
        uint256 out = params.amountIn / 1e12;
        MockUSDC(usdc).mint(params.recipient, out);
        return out;
    }
}

/// @dev Returns a fixed quote of amountIn / 1e12 (same rate as MockSwapRouter).
contract MockQuoterV2 {
    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    function quoteExactInputSingle(QuoteExactInputSingleParams memory params)
        external
        pure
        returns (uint256, uint160, uint32, uint256)
    {
        return (params.amountIn / 1e12, 0, 0, 0);
    }

    function quoteExactInput(bytes memory, uint256 amountIn)
        external
        pure
        returns (uint256, uint160[] memory, uint32[] memory, uint256)
    {
        uint160[] memory a;
        uint32[] memory b;
        return (amountIn / 1e12, a, b, 0);
    }
}

/// @dev Accepts any `donate` call (no-op).
contract MockEndaomentEntity {
    function donate(uint256) external { }
}

// =========================================================================
//                              TEST BASE
// =========================================================================

abstract contract ClawdSearchTestBase is Test {
    address constant CLAWD_ADDR = 0x9f86dB9fc6f7c9408e8Fda3Ff8ce4e78ac7a6b07;
    address constant USDC_ADDR = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant ROUTER_ADDR = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address constant QUOTER_ADDR = 0x61fFE014bA17989E743c5F6cB21bF9697530B21e;
    address constant WWF_ADDR = 0x3c57365D198586d6Bc0e3e3f6b9a63E17425aC52;
    address constant TREASURY = 0x90eF2A9211A3E7CE788561E5af54C76B0Fa3aEd0;
    address constant BURN = 0x000000000000000000000000000000000000dEaD;

    uint256 constant CAT_PUDGY_PENGUIN = 0;
    uint256 constant CAT_DAPPER_LOBSTER = 1;
    uint256 constant CAT_PEPE_FROG = 2;
    uint256 constant CAT_CUTEST = 3;
    uint256 constant CAT_CAMOUFLAGE = 4;
    uint256 constant CAT_BEST_EYES = 5;

    ClawdSearch internal cs;
    MockClawd internal clawd;
    MockUSDC internal usdc;

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

    // Default split: 80/10/10
    uint256 constant CHARITY_BPS = 8000;
    uint256 constant BURN_BPS = 1000;
    uint256 constant TREASURY_BPS = 1000;

    function setUp() public virtual {
        // Etch MockClawd at CLAWD_ADDR
        MockClawd clawdTemplate = new MockClawd();
        vm.etch(CLAWD_ADDR, address(clawdTemplate).code);
        clawd = MockClawd(CLAWD_ADDR);

        // Etch MockUSDC at USDC_ADDR
        MockUSDC usdcTemplate = new MockUSDC();
        vm.etch(USDC_ADDR, address(usdcTemplate).code);
        usdc = MockUSDC(USDC_ADDR);

        // Etch MockSwapRouter at ROUTER_ADDR (immutable USDC_ADDR baked into bytecode)
        MockSwapRouter routerTemplate = new MockSwapRouter(USDC_ADDR);
        vm.etch(ROUTER_ADDR, address(routerTemplate).code);

        // Etch MockQuoterV2 at QUOTER_ADDR
        MockQuoterV2 quoterTemplate = new MockQuoterV2();
        vm.etch(QUOTER_ADDR, address(quoterTemplate).code);

        // Etch MockEndaomentEntity at WWF_ADDR
        MockEndaomentEntity endaoTemplate = new MockEndaomentEntity();
        vm.etch(WWF_ADDR, address(endaoTemplate).code);

        // Deploy ClawdSearch with TWO_HOP path
        cs = new ClawdSearch(owner, uint8(1));

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

    function _splitAmount(uint256 total, uint256 bps) internal pure returns (uint256) {
        return (total * bps) / 10_000;
    }
}

// =========================================================================
//                              SUBMIT TESTS
// =========================================================================

contract ClawdSearchSubmitTest is ClawdSearchTestBase {
    function test_submit_setsChampionAndSplitsClawd() public {
        uint256 aliceBalBefore = clawd.balanceOf(alice);
        uint256 burnBefore = clawd.balanceOf(BURN);
        uint256 trBefore = clawd.balanceOf(TREASURY);

        _submit(alice, CAT_CUTEST, 42);

        assertEq(clawd.balanceOf(alice), aliceBalBefore - SUBMIT_PRICE);
        // burn = 10% of 1000e18 = 100e18
        assertEq(clawd.balanceOf(BURN), burnBefore + _splitAmount(SUBMIT_PRICE, BURN_BPS));
        // treasury = 10% of 1000e18 = 100e18
        assertEq(clawd.balanceOf(TREASURY), trBefore + _splitAmount(SUBMIT_PRICE, TREASURY_BPS));

        ClawdSearch.CategoryState memory s = cs.getCategory(CAT_CUTEST);
        assertEq(s.championObsId, 42);
        assertEq(s.championOwner, alice);
        assertEq(s.reignStart, uint64(block.timestamp));

        (uint128 submitted, uint128 won, uint256 reign) = cs.userStats(alice);
        assertEq(submitted, 1);
        assertEq(won, 0);
        assertEq(reign, 0);
    }

    function test_submit_incrementsTotalCreaturesSubmitted() public {
        assertEq(cs.totalCreaturesSubmitted(), 0);
        _submit(alice, CAT_CUTEST, 1);
        assertEq(cs.totalCreaturesSubmitted(), 1);
        _submit(bob, CAT_BEST_EYES, 2);
        assertEq(cs.totalCreaturesSubmitted(), 2);
    }

    function test_submit_accumulatesTotalBurnedAndTreasury() public {
        _submit(alice, CAT_CUTEST, 42);
        assertEq(cs.totalBurned(), _splitAmount(SUBMIT_PRICE, BURN_BPS));
        assertEq(cs.totalTreasury(), _splitAmount(SUBMIT_PRICE, TREASURY_BPS));
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
        assertEq(cs.nextCategoryId(), 6);
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
        ClawdSearch.CategoryData memory d = cs.getCategoryData(CAT_CUTEST);
        assertTrue(d.active);

        vm.prank(owner);
        cs.setCategoryActive(CAT_CUTEST, false);
        d = cs.getCategoryData(CAT_CUTEST);
        assertFalse(d.active);

        vm.prank(alice);
        vm.expectRevert(ClawdSearch.CategoryNotActive.selector);
        cs.submit(CAT_CUTEST, 1);

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

    // Phase 3 admin tests
    function test_setSplit_ownerOnly() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        cs.setSplit(7000, 2000, 1000);
    }

    function test_setSplit_mustSumTo10000() public {
        vm.prank(owner);
        vm.expectRevert(ClawdSearch.InvalidSplit.selector);
        cs.setSplit(7000, 2000, 500); // sum = 9500, not 10000
    }

    function test_setSplit_happy() public {
        vm.prank(owner);
        cs.setSplit(7000, 2000, 1000);
        assertEq(cs.splitCharityBps(), 7000);
        assertEq(cs.splitBurnBps(), 2000);
        assertEq(cs.splitTreasuryBps(), 1000);
    }

    function test_setSlippageBps_ownerOnly() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        cs.setSlippageBps(200);
    }

    function test_setSlippageBps_capAt500() public {
        vm.prank(owner);
        vm.expectRevert(ClawdSearch.SlippageTooHigh.selector);
        cs.setSlippageBps(501);
    }

    function test_setSlippageBps_happy() public {
        vm.prank(owner);
        cs.setSlippageBps(200);
        assertEq(cs.slippageBps(), 200);
    }

    function test_setSwapPath_ownerOnly() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        cs.setSwapPath(uint8(0));
    }

    function test_setSwapPath_happy() public {
        vm.prank(owner);
        cs.setSwapPath(uint8(0));
        assertEq(cs.swapPath(), uint8(0));
    }
}

// =========================================================================
//                        AUDIT-DRIVEN FIX TESTS
// =========================================================================

contract ClawdSearchAuditFixesTest is ClawdSearchTestBase {
    function test_split_charityGetsRemainder() public {
        // Verify split math: charity = total - burn - treasury (gets rounding remainder)
        vm.prank(owner);
        cs.setPrices(101, 0, 0); // odd amount

        uint256 aliceBefore = clawd.balanceOf(alice);
        uint256 burnBefore = clawd.balanceOf(BURN);
        uint256 trBefore = clawd.balanceOf(TREASURY);

        _submit(alice, CAT_CUTEST, 7);

        // burn = 101 * 1000 / 10000 = 10
        // treasury = 101 * 1000 / 10000 = 10
        // charity = 101 - 10 - 10 = 81 (gets remainder)
        assertEq(clawd.balanceOf(alice), aliceBefore - 101);
        assertEq(clawd.balanceOf(BURN), burnBefore + 10);
        assertEq(clawd.balanceOf(TREASURY), trBefore + 10);
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

        // treasury gets 10% of submitPrice
        assertEq(clawd.balanceOf(TREASURY), oldTrBefore);
        assertEq(clawd.balanceOf(newTreasury), newTrBefore + _splitAmount(SUBMIT_PRICE, TREASURY_BPS));
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

    function test_emit_paymentProcessed_onSubmit() public {
        uint256 burnAmt = _splitAmount(SUBMIT_PRICE, BURN_BPS);
        uint256 trAmt = _splitAmount(SUBMIT_PRICE, TREASURY_BPS);
        uint256 charityAmt = SUBMIT_PRICE - burnAmt - trAmt;
        uint256 expectedUsdc = charityAmt / 1e12; // mock rate

        vm.expectEmit(true, false, false, true, address(cs));
        emit ClawdSearch.PaymentProcessed(alice, SUBMIT_PRICE, burnAmt, trAmt, charityAmt, expectedUsdc);
        _submit(alice, CAT_CUTEST, 42);
    }

    function test_totalCharityDonatedUsdc_accumulatesOnSubmit() public {
        assertEq(cs.totalCharityDonatedUsdc(), 0);
        _submit(alice, CAT_CUTEST, 1);
        uint256 charityAmt = SUBMIT_PRICE - _splitAmount(SUBMIT_PRICE, BURN_BPS) - _splitAmount(SUBMIT_PRICE, TREASURY_BPS);
        uint256 expectedUsdc = charityAmt / 1e12;
        assertEq(cs.totalCharityDonatedUsdc(), expectedUsdc);
    }

    function test_constructor_emitsInitialConfigEvents() public {
        vm.recordLogs();
        ClawdSearch fresh = new ClawdSearch(owner, uint8(1));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 treasurySig = keccak256("TreasuryUpdated(address)");
        bytes32 pricesSig = keccak256("PricesUpdated(uint256,uint256,uint256)");
        bytes32 categoryAddedSig = keccak256("CategoryAdded(uint256,string,uint32)");
        bytes32 splitSig = keccak256("SplitUpdated(uint16,uint16,uint16)");
        bytes32 swapPathSig = keccak256("SwapPathUpdated(uint8)");

        bool sawTreasury;
        bool sawPrices;
        bool sawSplit;
        bool sawSwapPath;
        uint256 categoryAddedCount;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(fresh)) continue;
            if (logs[i].topics[0] == treasurySig) {
                sawTreasury = true;
            } else if (logs[i].topics[0] == pricesSig) {
                sawPrices = true;
            } else if (logs[i].topics[0] == categoryAddedSig) {
                categoryAddedCount++;
            } else if (logs[i].topics[0] == splitSig) {
                sawSplit = true;
            } else if (logs[i].topics[0] == swapPathSig) {
                sawSwapPath = true;
            }
        }
        assertTrue(sawTreasury, "constructor should emit TreasuryUpdated");
        assertTrue(sawPrices, "constructor should emit PricesUpdated");
        assertTrue(sawSplit, "constructor should emit SplitUpdated");
        assertTrue(sawSwapPath, "constructor should emit SwapPathUpdated");
        assertEq(categoryAddedCount, 6, "constructor should emit 6 CategoryAdded events");
    }
}
