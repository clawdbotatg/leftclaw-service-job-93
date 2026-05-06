// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./DeployHelpers.s.sol";
import { ClawdSearch } from "../contracts/ClawdSearch.sol";

/**
 * @notice Deploy script for ClawdSearch.
 * @dev    The constructor argument is the contract owner. Per the LeftClaw rule, this is
 *         hardcoded to the job client address — never a worker / LeftClaw wallet.
 *
 * Example:
 *     yarn deploy --file DeployClawdSearch.s.sol --network base
 */
contract DeployClawdSearch is ScaffoldETHDeploy {
    /// @notice The LeftClaw job #93 client. This account becomes the contract owner.
    address public constant JOB_CLIENT = 0xC99F74bC7c065d8c51BD724Da898d44F775a8a19;

    function run() external ScaffoldEthDeployerRunner {
        ClawdSearch clawdSearch = new ClawdSearch(JOB_CLIENT);
        deployments.push(Deployment({ name: "ClawdSearch", addr: address(clawdSearch) }));
    }
}
