// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {KassoraVault} from "../src/KassoraVault.sol";
import {ERC4626Strategy} from "../src/strategies/ERC4626Strategy.sol";

/// @notice Deploys KassoraVault (+ optional ERC4626Strategy) and writes deployments/<chainId>.json.
/// @dev Dry run:  forge script script/Deploy.s.sol --rpc-url robinhood_testnet
///      Broadcast: forge script script/Deploy.s.sol --rpc-url robinhood_testnet --account deployer --broadcast --verify
///      Roles default to the deployer when OWNER/CURATOR/GUARDIAN/FEE_RECIPIENT are empty.
///      Hand them to a multisig before opening deposits.
contract Deploy is Script {
    function run() external returns (KassoraVault vault, ERC4626Strategy strategy) {
        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();

        KassoraVault.InitParams memory p = KassoraVault.InitParams({
            asset: IERC20(vm.envAddress("ASSET")),
            name: vm.envOr("VAULT_NAME", string("Kassora USDG Vault")),
            symbol: vm.envOr("VAULT_SYMBOL", string("kUSDG")),
            owner: vm.envOr("OWNER", deployer),
            curator: vm.envOr("CURATOR", deployer),
            guardian: vm.envOr("GUARDIAN", deployer),
            feeRecipient: vm.envOr("FEE_RECIPIENT", deployer),
            timelock: vm.envOr("INITIAL_TIMELOCK", uint256(1 days)),
            depositCap: vm.envUint("DEPOSITCAP"),
            decimalsOffset: uint8(vm.envOr("DECIMALS_OFFSET", uint256(6)))
        });
        vault = new KassoraVault(p);

        address targetVault = vm.envOr("TARGET_VAULT", address(0));
        if (targetVault != address(0)) {
            strategy = new ERC4626Strategy(address(vault), IERC4626(targetVault));
            if (p.curator == deployer || p.owner == deployer) {
                vault.submitCap(strategy, vm.envOr("STRATEGY_CAP", uint256(0)));
                if (p.timelock == 0) vault.acceptCap(strategy);
            }
        }
        vm.stopBroadcast();

        _writeDeployment(vault, strategy, targetVault, p);
    }

    function _writeDeployment(
        KassoraVault vault,
        ERC4626Strategy strategy,
        address targetVault,
        KassoraVault.InitParams memory p
    ) internal {
        string memory k = "deployment";
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeUint(k, "deployedAtBlock", block.number);
        vm.serializeAddress(k, "asset", address(p.asset));
        vm.serializeAddress(k, "KassoraVault", address(vault));
        vm.serializeAddress(k, "ERC4626Strategy", address(strategy));
        vm.serializeAddress(k, "strategyTarget", targetVault);
        vm.serializeAddress(k, "owner", p.owner);
        vm.serializeAddress(k, "curator", p.curator);
        vm.serializeAddress(k, "guardian", p.guardian);
        vm.serializeAddress(k, "feeRecipient", p.feeRecipient);
        vm.serializeUint(k, "timelock", p.timelock);
        string memory json = vm.serializeUint(k, "depositCap", p.depositCap);

        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".json");
        vm.writeJson(json, path);
        console2.log("KassoraVault   ", address(vault));
        console2.log("ERC4626Strategy", address(strategy));
        console2.log("written        ", path);
    }
}
