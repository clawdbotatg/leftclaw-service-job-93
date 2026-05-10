// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// ---------------------------------------------------------------------------
// External interfaces — minimal, inlined to avoid dependency management
// ---------------------------------------------------------------------------

interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);

    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}

interface IQuoterV2 {
    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    function quoteExactInputSingle(QuoteExactInputSingleParams memory params)
        external
        returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate);

    function quoteExactInput(bytes memory path, uint256 amountIn)
        external
        returns (
            uint256 amountOut,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksCrossedList,
            uint256 gasEstimate
        );
}

interface IEndaomentEntity {
    function donate(uint256 amount) external;
}

/**
 * @title ClawdSearch
 * @notice On-chain "Creature Feature" tournament — Phase 3.
 *         Every payment is split 80/10/10: 80% is swapped to USDC via Uniswap V3 and
 *         donated to WWF via Endaoment; 10% is burned; 10% goes to the CLAWD builders fund.
 *
 * @dev    Phase 2: dynamic categories (6 seeded in constructor).
 *         Phase 3: replaces the 50/50 burn/treasury split with 80/10/10 three-way split
 *         and adds Uniswap V3 charity routing + Endaoment donation.
 *
 *         CLAWD trust assumption: the hardcoded CLAWD token at
 *         `0x9f86dB9fc6f7c9408e8Fda3Ff8ce4e78ac7a6b07` is treated as a vetted, standard
 *         OpenZeppelin-style ERC20 with no transfer hooks, no rebasing, no fee-on-transfer,
 *         and no callbacks into this contract during `transferFrom`. `nonReentrant` applied
 *         to all state-mutating user entry points as belt-and-suspenders.
 *
 *         Swap path: SINGLE_HOP (CLAWD→USDC) or TWO_HOP (CLAWD→WETH→USDC). Set in
 *         constructor; owner can change via `setSwapPath`. Fee tiers tunable by owner.
 *
 *         Endaoment: charity portion swaps to USDC then calls `donate(amount)` on the
 *         WWF_ENTITY. Both the swap and the donation are wrapped in try/catch — a failed
 *         call strands CLAWD/USDC in this contract for owner rescue via `rescueToken`.
 */
contract ClawdSearch is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // -----------------------------------------------------------------------
    // Constants & Immutables
    // -----------------------------------------------------------------------

    IERC20 public immutable CLAWD;

    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    uint256 public constant CHALLENGE_DURATION = 48 hours;
    uint256 public constant COOLDOWN = 1 hours;

    // Charity infrastructure (Base mainnet)
    address public constant WWF_ENTITY = 0x3c57365D198586d6Bc0e3e3f6b9a63E17425aC52;
    address public constant UNISWAP_V3_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address public constant UNISWAP_V3_QUOTER = 0x61fFE014bA17989E743c5F6cB21bF9697530B21e;
    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public constant WETH = 0x4200000000000000000000000000000000000006;

    uint8 public constant SINGLE_HOP = 0;
    uint8 public constant TWO_HOP = 1;

    // -----------------------------------------------------------------------
    // Storage — Phase 2 (tournament state, unchanged)
    // -----------------------------------------------------------------------

    address public treasury;

    uint256 public submitPrice = 1000 * 1e18;
    uint256 public challengePrice = 100 * 1e18;
    uint256 public votePrice = 100 * 1e18;

    uint256 public nextCategoryId;

    struct CategoryData {
        string name;
        uint32 taxonId;
        bool active;
        uint64 createdAt;
    }

    struct CategoryState {
        uint256 championObsId;
        address championOwner;
        uint256 challengerObsId;
        address challengerOwner;
        uint256 championVotes;
        uint256 challengerVotes;
        uint64 challengeStart;
        uint64 cooldownEnd;
        uint64 reignStart;
        uint64 challengeRound;
    }

    struct UserStats {
        uint128 championsSubmitted;
        uint128 challengesWon;
        uint256 totalReignSeconds;
    }

    mapping(uint256 => CategoryData) public categoryData;
    mapping(uint256 => CategoryState) public categoryStates;
    mapping(uint256 => mapping(uint256 => uint256)) public categoryChampionWins;
    mapping(uint256 => mapping(uint64 => mapping(address => bool))) public hasVoted;
    mapping(uint256 => mapping(uint256 => bool)) public hasLostInCategory;
    mapping(address => UserStats) public userStats;

    // -----------------------------------------------------------------------
    // Storage — Phase 3 (charity routing)
    // -----------------------------------------------------------------------

    uint16 public splitCharityBps = 8000;
    uint16 public splitBurnBps = 1000;
    uint16 public splitTreasuryBps = 1000;
    uint16 public slippageBps = 100;
    uint8 public swapPath;

    uint24 public singleHopFee = 10_000;
    uint24 public twoHopFee1 = 10_000;
    uint24 public twoHopFee2 = 500;

    uint256 public totalCharityDonatedUsdc;
    uint256 public totalBurned;
    uint256 public totalTreasury;
    uint256 public totalCreaturesSubmitted;

    // -----------------------------------------------------------------------
    // Events — Phase 2 (unchanged)
    // -----------------------------------------------------------------------

    event CategoryAdded(uint256 indexed categoryId, string name, uint32 taxonId);
    event CategorySetActive(uint256 indexed categoryId, bool active);
    event ChampionCrowned(uint256 indexed categoryId, uint256 indexed observationId, address indexed submitter);
    event ChallengeStarted(uint256 indexed categoryId, uint256 indexed challengerObsId, address indexed challenger);
    event VoteCast(uint256 indexed categoryId, address indexed voter, bool forChallenger);
    event ChallengeResolved(
        uint256 indexed categoryId,
        uint256 indexed winnerObsId,
        address indexed winner,
        uint256 championVotes,
        uint256 challengerVotes
    );
    event TreasuryUpdated(address indexed newTreasury);
    event PricesUpdated(uint256 submitPrice, uint256 challengePrice, uint256 votePrice);

    // -----------------------------------------------------------------------
    // Events — Phase 3 (new)
    // -----------------------------------------------------------------------

    event PaymentProcessed(
        address indexed payer,
        uint256 totalAmount,
        uint256 burnAmount,
        uint256 treasuryAmount,
        uint256 charityAmount,
        uint256 usdcDonated
    );
    event SplitUpdated(uint16 charity, uint16 burn, uint16 treasury);
    event SwapPathUpdated(uint8 path);

    // -----------------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------------

    error InvalidObservation();
    error CategoryDoesNotExist();
    error CategoryNotActive();
    error CategoryAlreadyHasChampion();
    error CategoryHasNoChampion();
    error ChallengeAlreadyActive();
    error ChallengeNotActive();
    error ChallengeWindowClosed();
    error ChallengeWindowOpen();
    error OnCooldown();
    error ObservationLockedOut();
    error SameAsChampion();
    error AlreadyVoted();
    error ZeroAddress();
    error OwnershipCannotBeRenounced();
    error InvalidSplit();
    error SlippageTooHigh();

    // -----------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------

    constructor(address initialOwner, uint8 _swapPath) Ownable(initialOwner) {
        if (initialOwner == address(0)) revert ZeroAddress();
        CLAWD = IERC20(0x9f86dB9fc6f7c9408e8Fda3Ff8ce4e78ac7a6b07);
        treasury = 0x90eF2A9211A3E7CE788561E5af54C76B0Fa3aEd0;
        swapPath = _swapPath;

        emit TreasuryUpdated(treasury);
        emit PricesUpdated(submitPrice, challengePrice, votePrice);
        emit SplitUpdated(splitCharityBps, splitBurnBps, splitTreasuryBps);
        emit SwapPathUpdated(swapPath);

        _seedCategory("Most Pudgy Penguin", 3956);
        _seedCategory("Most Dapper Lobster", 47764);
        _seedCategory("Most Pepe Frog", 20979);
        _seedCategory("Cutest", 1);
        _seedCategory("Best Camouflage", 1);
        _seedCategory("Best Eyes", 1);
    }

    // -----------------------------------------------------------------------
    // Tournament — public entry points
    // -----------------------------------------------------------------------

    function submit(uint256 categoryId, uint256 observationId) external nonReentrant {
        if (observationId == 0) revert InvalidObservation();
        _assertCategoryActive(categoryId);
        CategoryState storage cat = categoryStates[categoryId];
        if (cat.championObsId != 0) revert CategoryAlreadyHasChampion();

        cat.championObsId = observationId;
        cat.championOwner = msg.sender;
        cat.reignStart = uint64(block.timestamp);

        unchecked {
            userStats[msg.sender].championsSubmitted += 1;
            totalCreaturesSubmitted += 1;
        }

        _spendClawd(submitPrice);

        emit ChampionCrowned(categoryId, observationId, msg.sender);
    }

    function challenge(uint256 categoryId, uint256 observationId) external nonReentrant {
        if (observationId == 0) revert InvalidObservation();
        _assertCategoryActive(categoryId);
        CategoryState storage cat = categoryStates[categoryId];
        if (cat.championObsId == 0) revert CategoryHasNoChampion();
        if (cat.challengerObsId != 0) revert ChallengeAlreadyActive();
        if (block.timestamp < cat.cooldownEnd) revert OnCooldown();
        if (hasLostInCategory[categoryId][observationId]) revert ObservationLockedOut();
        if (observationId == cat.championObsId) revert SameAsChampion();

        cat.challengerObsId = observationId;
        cat.challengerOwner = msg.sender;
        cat.challengeStart = uint64(block.timestamp);
        cat.championVotes = 0;
        cat.challengerVotes = 0;
        unchecked {
            cat.challengeRound += 1;
        }

        _spendClawd(challengePrice);

        emit ChallengeStarted(categoryId, observationId, msg.sender);
    }

    function vote(uint256 categoryId, bool forChallenger) external nonReentrant {
        _assertCategoryExists(categoryId);
        CategoryState storage cat = categoryStates[categoryId];
        if (cat.challengerObsId == 0) revert ChallengeNotActive();
        if (block.timestamp >= uint256(cat.challengeStart) + CHALLENGE_DURATION) {
            revert ChallengeWindowClosed();
        }
        if (hasVoted[categoryId][cat.challengeRound][msg.sender]) revert AlreadyVoted();

        hasVoted[categoryId][cat.challengeRound][msg.sender] = true;
        if (forChallenger) {
            cat.challengerVotes += 1;
        } else {
            cat.championVotes += 1;
        }

        _spendClawd(votePrice);

        emit VoteCast(categoryId, msg.sender, forChallenger);
    }

    function resolve(uint256 categoryId) external nonReentrant {
        _assertCategoryExists(categoryId);
        CategoryState storage cat = categoryStates[categoryId];
        if (cat.challengerObsId == 0) revert ChallengeNotActive();
        if (block.timestamp < uint256(cat.challengeStart) + CHALLENGE_DURATION) {
            revert ChallengeWindowOpen();
        }

        uint256 oldChampionObsId = cat.championObsId;
        address oldChampionOwner = cat.championOwner;
        uint256 newChampionCandidateObsId = cat.challengerObsId;
        address newChampionCandidateOwner = cat.challengerOwner;
        uint256 finalChampionVotes = cat.championVotes;
        uint256 finalChallengerVotes = cat.challengerVotes;
        uint64 oldReignStart = cat.reignStart;

        bool challengerWins;
        if (finalChampionVotes == 0 && finalChallengerVotes == 0) {
            challengerWins = true;
        } else {
            challengerWins = finalChallengerVotes > finalChampionVotes;
        }

        uint256 winnerObsId;
        address winnerOwner;
        uint256 loserObsId;

        if (challengerWins) {
            winnerObsId = newChampionCandidateObsId;
            winnerOwner = newChampionCandidateOwner;
            loserObsId = oldChampionObsId;

            unchecked {
                userStats[oldChampionOwner].totalReignSeconds += block.timestamp - uint256(oldReignStart);
            }
            unchecked {
                userStats[newChampionCandidateOwner].challengesWon += 1;
            }

            cat.championObsId = newChampionCandidateObsId;
            cat.championOwner = newChampionCandidateOwner;
            cat.reignStart = uint64(block.timestamp);
        } else {
            winnerObsId = oldChampionObsId;
            winnerOwner = oldChampionOwner;
            loserObsId = newChampionCandidateObsId;
        }

        unchecked {
            categoryChampionWins[categoryId][winnerObsId] += 1;
        }
        hasLostInCategory[categoryId][loserObsId] = true;

        cat.cooldownEnd = uint64(block.timestamp + COOLDOWN);
        cat.challengerObsId = 0;
        cat.challengerOwner = address(0);
        cat.championVotes = 0;
        cat.challengerVotes = 0;
        cat.challengeStart = 0;

        emit ChallengeResolved(categoryId, winnerObsId, winnerOwner, finalChampionVotes, finalChallengerVotes);
        if (challengerWins) {
            emit ChampionCrowned(categoryId, newChampionCandidateObsId, newChampionCandidateOwner);
        }
    }

    // -----------------------------------------------------------------------
    // Owner controls — Phase 2 (unchanged)
    // -----------------------------------------------------------------------

    function addCategory(string calldata name, uint32 taxonId) external onlyOwner returns (uint256 categoryId) {
        categoryId = nextCategoryId;
        _seedCategory(name, taxonId);
    }

    function setCategoryActive(uint256 categoryId, bool active) external onlyOwner {
        _assertCategoryExists(categoryId);
        categoryData[categoryId].active = active;
        emit CategorySetActive(categoryId, active);
    }

    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        treasury = newTreasury;
        emit TreasuryUpdated(newTreasury);
    }

    function setPrices(uint256 newSubmit, uint256 newChallenge, uint256 newVote) external onlyOwner {
        submitPrice = newSubmit;
        challengePrice = newChallenge;
        votePrice = newVote;
        emit PricesUpdated(newSubmit, newChallenge, newVote);
    }

    function renounceOwnership() public view override onlyOwner {
        revert OwnershipCannotBeRenounced();
    }

    // -----------------------------------------------------------------------
    // Owner controls — Phase 3 (new)
    // -----------------------------------------------------------------------

    function setSplit(uint16 charity, uint16 burn, uint16 treasury_) external onlyOwner {
        if (uint256(charity) + uint256(burn) + uint256(treasury_) != 10_000) revert InvalidSplit();
        splitCharityBps = charity;
        splitBurnBps = burn;
        splitTreasuryBps = treasury_;
        emit SplitUpdated(charity, burn, treasury_);
    }

    function setSlippageBps(uint16 bps) external onlyOwner {
        if (bps > 500) revert SlippageTooHigh();
        slippageBps = bps;
    }

    function setSwapPath(uint8 path) external onlyOwner {
        swapPath = path;
        emit SwapPathUpdated(path);
    }

    function setFees(uint24 _singleHopFee, uint24 _twoHopFee1, uint24 _twoHopFee2) external onlyOwner {
        singleHopFee = _singleHopFee;
        twoHopFee1 = _twoHopFee1;
        twoHopFee2 = _twoHopFee2;
    }

    /// @notice Owner rescue for stranded tokens (failed swaps or donations leave tokens here).
    function rescueToken(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
    }

    // -----------------------------------------------------------------------
    // Views — Phase 2 (unchanged)
    // -----------------------------------------------------------------------

    function getCategoryData(uint256 categoryId) external view returns (CategoryData memory) {
        return categoryData[categoryId];
    }

    function getCategory(uint256 categoryId) external view returns (CategoryState memory) {
        return categoryStates[categoryId];
    }

    function isChallengeActive(uint256 categoryId) public view returns (bool) {
        CategoryState storage cat = categoryStates[categoryId];
        return cat.challengerObsId != 0 && block.timestamp < uint256(cat.challengeStart) + CHALLENGE_DURATION;
    }

    function challengeDeadline(uint256 categoryId) external view returns (uint64) {
        CategoryState storage cat = categoryStates[categoryId];
        if (cat.challengerObsId == 0) return 0;
        return cat.challengeStart + uint64(CHALLENGE_DURATION);
    }

    // -----------------------------------------------------------------------
    // Internal — Phase 2 helpers (unchanged)
    // -----------------------------------------------------------------------

    function _seedCategory(string memory name, uint32 taxonId) internal {
        uint256 id = nextCategoryId;
        unchecked {
            nextCategoryId = id + 1;
        }
        categoryData[id] = CategoryData({ name: name, taxonId: taxonId, active: true, createdAt: uint64(block.timestamp) });
        emit CategoryAdded(id, name, taxonId);
    }

    function _assertCategoryExists(uint256 categoryId) internal view {
        if (categoryId >= nextCategoryId) revert CategoryDoesNotExist();
    }

    function _assertCategoryActive(uint256 categoryId) internal view {
        if (categoryId >= nextCategoryId) revert CategoryDoesNotExist();
        if (!categoryData[categoryId].active) revert CategoryNotActive();
    }

    // -----------------------------------------------------------------------
    // Internal — Phase 3: charity routing
    // -----------------------------------------------------------------------

    function _spendClawd(uint256 amount) internal {
        if (amount == 0) return;

        // Compute three portions; charity gets any rounding remainder so it is never shorted.
        uint256 burnAmount = (amount * splitBurnBps) / 10_000;
        uint256 treasuryAmount = (amount * splitTreasuryBps) / 10_000;
        uint256 charityAmount = amount - burnAmount - treasuryAmount;

        // Effects: update accumulators before any external calls.
        totalBurned += burnAmount;
        totalTreasury += treasuryAmount;

        // Burn and treasury transfers directly from payer.
        if (burnAmount > 0) CLAWD.safeTransferFrom(msg.sender, BURN_ADDRESS, burnAmount);
        if (treasuryAmount > 0) CLAWD.safeTransferFrom(msg.sender, treasury, treasuryAmount);

        // Charity routing: pull CLAWD → swap to USDC → donate via Endaoment.
        uint256 usdcDonated = 0;
        if (charityAmount > 0) {
            CLAWD.safeTransferFrom(msg.sender, address(this), charityAmount);
            usdcDonated = _swapAndDonate(charityAmount);
        }

        emit PaymentProcessed(msg.sender, amount, burnAmount, treasuryAmount, charityAmount, usdcDonated);
    }

    function _swapAndDonate(uint256 charityAmount) internal returns (uint256 usdcDonated) {
        uint256 minOut = _getMinOut(charityAmount);

        // Approve router to spend CLAWD held by this contract.
        CLAWD.forceApprove(UNISWAP_V3_ROUTER, charityAmount);

        uint256 received = 0;
        if (swapPath == SINGLE_HOP) {
            try ISwapRouter(UNISWAP_V3_ROUTER).exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: address(CLAWD),
                    tokenOut: USDC,
                    fee: singleHopFee,
                    recipient: address(this),
                    amountIn: charityAmount,
                    amountOutMinimum: minOut,
                    sqrtPriceLimitX96: 0
                })
            ) returns (uint256 out) {
                received = out;
            } catch {
                // Reset allowance on failure; CLAWD stays in contract for rescue.
                CLAWD.forceApprove(UNISWAP_V3_ROUTER, 0);
            }
        } else {
            bytes memory path = abi.encodePacked(address(CLAWD), twoHopFee1, WETH, twoHopFee2, USDC);
            try ISwapRouter(UNISWAP_V3_ROUTER).exactInput(
                ISwapRouter.ExactInputParams({
                    path: path,
                    recipient: address(this),
                    amountIn: charityAmount,
                    amountOutMinimum: minOut
                })
            ) returns (uint256 out) {
                received = out;
            } catch {
                CLAWD.forceApprove(UNISWAP_V3_ROUTER, 0);
            }
        }

        if (received > 0) {
            // Approve Endaoment entity for received USDC.
            IERC20(USDC).forceApprove(WWF_ENTITY, received);
            try IEndaomentEntity(WWF_ENTITY).donate(received) {
                usdcDonated = received;
                totalCharityDonatedUsdc += received;
            } catch {
                // Reset USDC allowance on failure; USDC stays in contract for rescue.
                IERC20(USDC).forceApprove(WWF_ENTITY, 0);
            }
        }
    }

    function _getMinOut(uint256 clawd) internal returns (uint256 minOut) {
        if (swapPath == SINGLE_HOP) {
            try IQuoterV2(UNISWAP_V3_QUOTER).quoteExactInputSingle(
                IQuoterV2.QuoteExactInputSingleParams({
                    tokenIn: address(CLAWD),
                    tokenOut: USDC,
                    amountIn: clawd,
                    fee: singleHopFee,
                    sqrtPriceLimitX96: 0
                })
            ) returns (uint256 amountOut, uint160, uint32, uint256) {
                minOut = (amountOut * (10_000 - slippageBps)) / 10_000;
            } catch {
                minOut = 0;
            }
        } else {
            bytes memory path = abi.encodePacked(address(CLAWD), twoHopFee1, WETH, twoHopFee2, USDC);
            try IQuoterV2(UNISWAP_V3_QUOTER).quoteExactInput(path, clawd)
            returns (uint256 amountOut, uint160[] memory, uint32[] memory, uint256) {
                minOut = (amountOut * (10_000 - slippageBps)) / 10_000;
            } catch {
                minOut = 0;
            }
        }
    }
}
