// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./DeployHelpers.s.sol";
import { ClawdSearch } from "../contracts/ClawdSearch.sol";

/**
 * @notice Phase 3 deploy script for ClawdSearch.
 * @dev    Deploys with TWO_HOP swap path (CLAWD→WETH→USDC) as the default. The owner
 *         can call `setSwapPath(0)` to switch to SINGLE_HOP if a CLAWD/USDC direct
 *         pool has adequate liquidity.
 *
 *         Owner is hardcoded to the job client — never the deployer wallet.
 *
 * Example:
 *     yarn deploy --file DeployClawdSearch.s.sol --network base
 */
contract DeployClawdSearch is ScaffoldETHDeploy {
    /// @notice The LeftClaw job #93 client. This account becomes the contract owner.
    address public constant JOB_CLIENT = 0xC99F74bC7c065d8c51BD724Da898d44F775a8a19;

    uint8 constant TWO_HOP = 1;

    function run() external ScaffoldEthDeployerRunner {
        ClawdSearch clawdSearch = new ClawdSearch(JOB_CLIENT, TWO_HOP);
        deployments.push(Deployment({ name: "ClawdSearch", addr: address(clawdSearch) }));
    }
}
