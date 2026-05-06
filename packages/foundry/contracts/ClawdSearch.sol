// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title ClawdSearch
 * @notice On-chain "Clawd Search" tournament: anyone can submit a Clawd observation as the
 *         champion of a category, and any holder can challenge by paying CLAWD. Voters spend
 *         CLAWD to support either side. After 48h, the side with the most votes wins; ties
 *         go to the defender. Tokens are split 50/50 burn/treasury, with any odd-amount
 *         remainder going to the burn side (e.g. 101 → 51 burn, 50 treasury).
 *
 * @dev    CLAWD has 18 decimals (assumption — verified off-chain against the deployed token).
 *         Token amounts (`submitPrice`, `challengePrice`, `votePrice`) use 1e18 scaling.
 *
 *         The on-chain spec referred to a `totalReignBlocks` user stat. We expose it here as
 *         `userStats.totalReignSeconds` because reign duration is naturally tracked via
 *         `block.timestamp` (i.e. seconds), not block numbers — the spec wording was loose.
 *
 *         The spec's `categoryChampionWins[category][obsId]` was described as
 *         "total wins for leaderboard". We implement it as: every successful resolve
 *         increments the win counter for the WINNER's observation id. That makes the metric
 *         a true Hall-of-Fame counter — it captures both successful defenses (champion stays)
 *         and successful overthrows (challenger wins).
 *
 *         `setPrices` allows zero values intentionally: the owner may run a free promotional
 *         period. There is no zero-check.
 */
contract ClawdSearch is Ownable2Step {
    using SafeERC20 for IERC20;

    // -----------------------------------------------------------------------
    // Constants & Immutables
    // -----------------------------------------------------------------------

    /// @notice The CLAWD token used for all payments (set at deployment).
    IERC20 public immutable CLAWD;

    /// @notice 50% of every payment is burned to this address.
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @notice Active challenge window — voting only succeeds while we are inside it.
    uint256 public constant CHALLENGE_DURATION = 48 hours;

    /// @notice Minimum delay between consecutive challenges in the same category.
    uint256 public constant COOLDOWN = 1 hours;

    // -----------------------------------------------------------------------
    // Storage
    // -----------------------------------------------------------------------

    /// @notice Recipient of the non-burned half of every payment.
    address public treasury;

    /// @notice CLAWD required to submit a brand-new champion (first claim only).
    uint256 public submitPrice = 1000 * 1e18;

    /// @notice CLAWD required to start a challenge.
    uint256 public challengePrice = 100 * 1e18;

    /// @notice CLAWD required to cast one vote.
    uint256 public votePrice = 100 * 1e18;

    /// @notice The three contested categories.
    enum Category {
        WouldWinInAFight,
        Cutest,
        LooksMostLikeCLAWDMascot
    }

    /// @notice Per-category state. Timestamps packed into uint64 for efficiency.
    struct CategoryState {
        uint256 championObsId;
        address championOwner;
        uint256 challengerObsId; // 0 when no active challenge
        address challengerOwner;
        uint256 championVotes;
        uint256 challengerVotes;
        uint64 challengeStart; // when current challenge began
        uint64 cooldownEnd; // earliest time a new challenge may start
        uint64 reignStart; // when the current champion took the throne
        uint64 challengeRound; // monotonic counter per category, scopes hasVoted
    }

    /// @notice Aggregate stats for any address that has interacted as a champion or challenger.
    /// @dev `totalReignSeconds` is the spec's `totalReignBlocks`, expressed in seconds (which is
    ///      what `block.timestamp` actually returns). Renamed here for clarity.
    struct UserStats {
        uint128 championsSubmitted;
        uint128 challengesWon;
        uint256 totalReignSeconds;
    }

    /// @notice Current state per category.
    mapping(Category => CategoryState) public categories;

    /// @notice Total wins per (category, observationId) — incremented for the winning side
    ///         on every resolve.
    mapping(Category => mapping(uint256 => uint256)) public categoryChampionWins;

    /// @notice Has `voter` already voted in this (category, challengeRound)?
    mapping(Category => mapping(uint64 => mapping(address => bool))) public hasVoted;

    /// @notice An observation that lost in a category cannot be re-challenged in that same category.
    ///         Other categories remain open.
    mapping(Category => mapping(uint256 => bool)) public hasLostInCategory;

    /// @notice Per-user aggregate stats.
    mapping(address => UserStats) public userStats;

    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------

    event ChampionCrowned(Category indexed category, uint256 observationId, address indexed submitter);
    event ChallengeStarted(Category indexed category, uint256 challengerObsId, address indexed challenger);
    event VoteCast(Category indexed category, address indexed voter, bool forChallenger);
    event ChallengeResolved(
        Category indexed category,
        uint256 winnerObsId,
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

    // -----------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------

    /**
     * @param initialOwner Owner of the contract (typically the LeftClaw job client).
     *                     Cannot be address(0).
     */
    constructor(address initialOwner) Ownable(initialOwner) {
        if (initialOwner == address(0)) revert ZeroAddress();
        CLAWD = IERC20(0x9f86dB9fc6f7c9408e8Fda3Ff8ce4e78ac7a6b07);
        treasury = 0x90eF2A9211A3E7CE788561E5af54C76B0Fa3aEd0;
    }

    // -----------------------------------------------------------------------
    // Tournament — public entry points
    // -----------------------------------------------------------------------

    /**
     * @notice Crown the first-ever champion of `category`. Only callable while the category
     *         has no champion yet. Costs `submitPrice` CLAWD.
     * @param category      The category to claim.
     * @param observationId The Clawd observation id to enshrine. Must be non-zero.
     */
    function submit(Category category, uint256 observationId) external {
        if (observationId == 0) revert InvalidObservation();
        CategoryState storage cat = categories[category];
        if (cat.championObsId != 0) revert CategoryAlreadyHasChampion();

        _spendClawd(submitPrice);

        cat.championObsId = observationId;
        cat.championOwner = msg.sender;
        cat.reignStart = uint64(block.timestamp);

        unchecked {
            userStats[msg.sender].championsSubmitted += 1;
        }

        emit ChampionCrowned(category, observationId, msg.sender);
    }

    /**
     * @notice Open a challenge against the current champion. Costs `challengePrice` CLAWD.
     *         Only one challenge can be active per category at a time, and the same losing
     *         observation cannot challenge in the same category twice.
     * @param category      The category to challenge in.
     * @param observationId The challenger's observation id (non-zero, not the champion, not
     *                      already a loser in this category).
     */
    function challenge(Category category, uint256 observationId) external {
        if (observationId == 0) revert InvalidObservation();
        CategoryState storage cat = categories[category];
        if (cat.championObsId == 0) revert CategoryHasNoChampion();
        if (cat.challengerObsId != 0) revert ChallengeAlreadyActive();
        if (block.timestamp < cat.cooldownEnd) revert OnCooldown();
        if (hasLostInCategory[category][observationId]) revert ObservationLockedOut();
        if (observationId == cat.championObsId) revert SameAsChampion();

        _spendClawd(challengePrice);

        cat.challengerObsId = observationId;
        cat.challengerOwner = msg.sender;
        cat.challengeStart = uint64(block.timestamp);
        cat.championVotes = 0;
        cat.challengerVotes = 0;
        unchecked {
            cat.challengeRound += 1;
        }

        emit ChallengeStarted(category, observationId, msg.sender);
    }

    /**
     * @notice Cast a vote for either the defender or the challenger of an active challenge.
     *         One vote per address per challenge round. Costs `votePrice` CLAWD.
     * @param category       The category being voted in.
     * @param forChallenger  True to vote for the challenger, false for the champion.
     */
    function vote(Category category, bool forChallenger) external {
        CategoryState storage cat = categories[category];
        if (cat.challengerObsId == 0) revert ChallengeNotActive();
        if (block.timestamp >= uint256(cat.challengeStart) + CHALLENGE_DURATION) {
            revert ChallengeWindowClosed();
        }
        if (hasVoted[category][cat.challengeRound][msg.sender]) revert AlreadyVoted();

        _spendClawd(votePrice);

        hasVoted[category][cat.challengeRound][msg.sender] = true;
        if (forChallenger) {
            cat.challengerVotes += 1;
        } else {
            cat.championVotes += 1;
        }

        emit VoteCast(category, msg.sender, forChallenger);
    }

    /**
     * @notice Resolve a challenge once its 48-hour window has expired. Anyone may call.
     *         If challenger has strictly more votes, OR both sides have zero votes, the
     *         challenger wins. Otherwise the champion wins (ties go to defender).
     *
     *         On resolution: the loser's observation is locked out of this category, the
     *         winning observation's `categoryChampionWins` counter ticks up by one, and
     *         a new cooldown begins.
     *
     * @param category The category to resolve.
     */
    function resolve(Category category) external {
        CategoryState storage cat = categories[category];
        if (cat.challengerObsId == 0) revert ChallengeNotActive();
        if (block.timestamp < uint256(cat.challengeStart) + CHALLENGE_DURATION) {
            revert ChallengeWindowOpen();
        }

        // Snapshot fields we'll overwrite or clear before emitting the event.
        uint256 oldChampionObsId = cat.championObsId;
        address oldChampionOwner = cat.championOwner;
        uint256 newChampionCandidateObsId = cat.challengerObsId;
        address newChampionCandidateOwner = cat.challengerOwner;
        uint256 finalChampionVotes = cat.championVotes;
        uint256 finalChallengerVotes = cat.challengerVotes;
        uint64 oldReignStart = cat.reignStart;

        // Tie or zero-zero → challenger wins on zero, champion wins on tie with positive votes.
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

            // Outgoing champion's reign accounting
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
            // Champion stays — reignStart unchanged.
        }

        // Counters & lockout
        unchecked {
            categoryChampionWins[category][winnerObsId] += 1;
        }
        hasLostInCategory[category][loserObsId] = true;

        // Cooldown + clear challenge fields
        cat.cooldownEnd = uint64(block.timestamp + COOLDOWN);
        cat.challengerObsId = 0;
        cat.challengerOwner = address(0);
        cat.championVotes = 0;
        cat.challengerVotes = 0;
        cat.challengeStart = 0;

        emit ChallengeResolved(category, winnerObsId, winnerOwner, finalChampionVotes, finalChallengerVotes);
        if (challengerWins) {
            emit ChampionCrowned(category, newChampionCandidateObsId, newChampionCandidateOwner);
        }
    }

    // -----------------------------------------------------------------------
    // Owner controls
    // -----------------------------------------------------------------------

    /**
     * @notice Update the treasury address that receives the non-burned half of payments.
     * @param newTreasury Non-zero address.
     */
    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        treasury = newTreasury;
        emit TreasuryUpdated(newTreasury);
    }

    /**
     * @notice Update the action prices. Zero values are permitted (e.g. promotional period).
     */
    function setPrices(uint256 newSubmit, uint256 newChallenge, uint256 newVote) external onlyOwner {
        submitPrice = newSubmit;
        challengePrice = newChallenge;
        votePrice = newVote;
        emit PricesUpdated(newSubmit, newChallenge, newVote);
    }

    // -----------------------------------------------------------------------
    // Views
    // -----------------------------------------------------------------------

    function getCategory(Category category) external view returns (CategoryState memory) {
        return categories[category];
    }

    function isChallengeActive(Category category) public view returns (bool) {
        CategoryState storage cat = categories[category];
        return cat.challengerObsId != 0 && block.timestamp < uint256(cat.challengeStart) + CHALLENGE_DURATION;
    }

    /// @notice Returns the timestamp at which the active challenge window closes,
    ///         or 0 if no challenge is active.
    function challengeDeadline(Category category) external view returns (uint64) {
        CategoryState storage cat = categories[category];
        if (cat.challengerObsId == 0) return 0;
        return cat.challengeStart + uint64(CHALLENGE_DURATION);
    }

    // -----------------------------------------------------------------------
    // Internal
    // -----------------------------------------------------------------------

    /**
     * @dev Splits `amount` of CLAWD: half (rounded UP) to BURN_ADDRESS, the smaller half to
     *      the treasury. Per spec, odd-amount remainder goes to the burn side.
     *      Uses SafeERC20 to surface non-standard ERC20 return values cleanly.
     */
    function _spendClawd(uint256 amount) internal {
        if (amount == 0) return;
        uint256 treasuryAmount = amount / 2;
        uint256 burnAmount = amount - treasuryAmount; // odd remainder → burn
        CLAWD.safeTransferFrom(msg.sender, BURN_ADDRESS, burnAmount);
        if (treasuryAmount > 0) {
            CLAWD.safeTransferFrom(msg.sender, treasury, treasuryAmount);
        }
    }
}
