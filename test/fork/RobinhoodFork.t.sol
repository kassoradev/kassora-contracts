// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {KassoraVault} from "../../src/KassoraVault.sol";
import {ERC4626Strategy} from "../../src/strategies/ERC4626Strategy.sol";

/// @notice Fork test against a real ERC-4626 USDG vault on Robinhood Chain (chain 4663).
/// @dev Skipped unless both env vars are set:
///        ROBINHOOD_RPC_URL   = https://rpc.mainnet.chain.robinhood.com (or a provider URL)
///        FORK_TARGET_VAULT   = address of an ERC-4626 vault whose asset is USDG (e.g. Spark spUSDG)
///      Run: forge test --match-path test/fork/* -vvv
contract RobinhoodForkTest is Test {
    uint256 internal constant CHAIN_ID = 4663;
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    KassoraVault internal vault;
    ERC4626Strategy internal strategy;
    IERC4626 internal target;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");

    function setUp() public {
        string memory rpc = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        address targetAddr = vm.envOr("FORK_TARGET_VAULT", address(0));
        if (bytes(rpc).length == 0 || targetAddr == address(0)) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        assertEq(block.chainid, CHAIN_ID, "not Robinhood Chain mainnet");

        target = IERC4626(targetAddr);
        assertEq(target.asset(), USDG, "target asset is not USDG");

        vault = new KassoraVault(
            KassoraVault.InitParams({
                asset: IERC20(USDG),
                name: "Kassora USDG Vault",
                symbol: "kUSDG",
                owner: owner,
                curator: owner,
                guardian: owner,
                feeRecipient: owner,
                timelock: 0,
                depositCap: 1_000_000e6,
                decimalsOffset: 6
            })
        );
        strategy = new ERC4626Strategy(address(vault), target);

        vm.startPrank(owner);
        vault.submitCap(strategy, 1_000_000e6);
        vault.acceptCap(strategy);
        vm.stopPrank();
    }

    function test_Fork_DepositAllocateWithdraw() public {
        uint256 amount = 10_000e6;
        deal(USDG, alice, amount);

        vm.startPrank(alice);
        IERC20(USDG).approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, alice);
        vm.stopPrank();

        vm.prank(owner);
        vault.allocate(strategy, amount);
        assertApproxEqAbs(vault.totalAssets(), amount, 2, "allocation changed totalAssets");

        skip(7 days);

        vm.prank(alice);
        uint256 out = vault.redeem(shares, alice, alice);
        assertGe(out + 2, amount, "lost principal on a live savings vault");
    }
}
