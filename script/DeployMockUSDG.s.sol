// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";
import {MockYieldVault} from "../test/mocks/MockYieldVault.sol";

/// @notice Testnet only: a mintable 6-decimal "tUSDG" and a plain ERC-4626 target to point the strategy at.
/// @dev forge script script/DeployMockUSDG.s.sol --rpc-url robinhood_testnet --account deployer --broadcast
contract DeployMockUSDG is Script {
    function run() external {
        require(block.chainid != 4663, "mock tokens are for testnet only");
        vm.startBroadcast();
        MockERC20 usdg = new MockERC20("Test Global Dollar", "tUSDG", 6);
        MockYieldVault target = new MockYieldVault(IERC20(address(usdg)));
        vm.stopBroadcast();
        console2.log("ASSET=", address(usdg));
        console2.log("TARGET_VAULT=", address(target));
    }
}
