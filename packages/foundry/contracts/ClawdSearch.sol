// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title ClawdSearch
 * @notice On-chain "Creature Feature" tournament: anyone can submit a creature observation as the
 *         champion of a dynamic category, and any holder can challenge by paying CLAWD.
 *         Voters spend CLAWD to support either side. After 48h, the side with the most votes wins;
 *         ties go to the defender. Tokens are split 50/50 burn/treasury, with any odd-amount
 *         remainder going to the burn side.
 *
 * @dev    Phase 2: replaces the static Category enum with a dynamic mapping-based category system.
 *         All existing logic is preserved; the uint256 categoryId replaces the enum parameter.
 *         Six categories are seeded in the constructor; future categories can be added via
 *         `addCategory` without redeploying.
 *
 *         CLAWD trust assumption: the hardcoded CLAWD token at
 *         `0x9f86dB9fc6f7c9408e8Fda3Ff8ce4e78ac7a6b07` is treated as a vetted, standard
 *         OpenZeppelin-style ERC20 with no transfer hooks, no rebasing, no fee-on-transfer,
 *         and no callbacks into this contract during `transferFrom`. We additionally apply
 *         `nonReentrant` to all state-mutating user entry points (`submit`, `challenge`,
 *         `vote`, `resolve`) as belt-and-suspenders.
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

    // -----------------------------------------------------------------------
    // Storage
    // -----------------------------------------------------------------------

    address public treasury;

    uint256 public submitPrice = 1000 * 1e18;
    uint256 public challengePrice = 100 * 1e18;
    uint256 public votePrice = 100 * 1e18;

    /// @notice Total number of categories ever created (next ID to assign).
    uint256 public nextCategoryId;

    /// @notice Metadata for each category (dynamic, owner-managed).
    struct CategoryData {
        string name;
        uint32 taxonId;
        bool active;
        uint64 createdAt;
    }

    /// @notice Per-category tournament state. Timestamps packed into uint64 for efficiency.
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

    /// @notice Category metadata by categoryId.
    mapping(uint256 => CategoryData) public categoryData;

    /// @notice Tournament state by categoryId.
    mapping(uint256 => CategoryState) public categoryStates;

    /// @notice Total wins per (categoryId, observationId).
    mapping(uint256 => mapping(uint256 => uint256)) public categoryChampionWins;

    /// @notice Has `voter` already voted in this (categoryId, challengeRound)?
    mapping(uint256 => mapping(uint64 => mapping(address => bool))) public hasVoted;

    /// @notice An observation that lost in a category cannot be re-challenged in that same category.
    mapping(uint256 => mapping(uint256 => bool)) public hasLostInCategory;

    mapping(address => UserStats) public userStats;

    // -----------------------------------------------------------------------
    // Events
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
    // Custom errors
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

    // -----------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------

    constructor(address initialOwner) Ownable(initialOwner) {
        if (initialOwner == address(0)) revert ZeroAddress();
        CLAWD = IERC20(0x9f86dB9fc6f7c9408e8Fda3Ff8ce4e78ac7a6b07);
        treasury = 0x90eF2A9211A3E7CE788561E5af54C76B0Fa3aEd0;

        emit TreasuryUpdated(treasury);
        emit PricesUpdated(submitPrice, challengePrice, votePrice);

        // Seed 6 categories as specified by job #146.
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
    // Owner controls
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
    // Views
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
    // Internal
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

    function _spendClawd(uint256 amount) internal {
        if (amount == 0) return;
        uint256 treasuryAmount = amount / 2;
        uint256 burnAmount = amount - treasuryAmount;
        CLAWD.safeTransferFrom(msg.sender, BURN_ADDRESS, burnAmount);
        if (treasuryAmount > 0) {
            CLAWD.safeTransferFrom(msg.sender, treasury, treasuryAmount);
        }
    }
}
