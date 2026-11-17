// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {KassoraVault} from "../src/KassoraVault.sol";
import {ERC4626Strategy} from "../src/strategies/ERC4626Strategy.sol";
import {IStrategy} from "../src/interfaces/IStrategy.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockYieldVault} from "./mocks/MockYieldVault.sol";

abstract contract BaseTest is Test {
    uint256 internal constant USDG = 1e6;
    uint256 internal constant TIMELOCK = 1 days;
    uint256 internal constant DEPOSIT_CAP = 10_000_000 * USDG;
    uint256 internal constant STRATEGY_CAP = 5_000_000 * USDG;

    address internal owner = makeAddr("owner");
    address internal curator = makeAddr("curator");
    address internal guardian = makeAddr("guardian");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    MockERC20 internal usdg;
    MockYieldVault internal target;
    KassoraVault internal vault;
    ERC4626Strategy internal strategy;

    function setUp() public virtual {
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        target = new MockYieldVault(IERC20(address(usdg)));
        vault = new KassoraVault(
            KassoraVault.InitParams({
                asset: IERC20(address(usdg)),
                name: "Kassora USDG Vault",
                symbol: "kUSDG",
                owner: owner,
                curator: curator,
                guardian: guardian,
                feeRecipient: feeRecipient,
                timelock: TIMELOCK,
                depositCap: DEPOSIT_CAP,
                decimalsOffset: 6
            })
        );
        strategy = new ERC4626Strategy(address(vault), IERC4626(address(target)));
        _enableStrategy(strategy, STRATEGY_CAP);
    }

    function _enableStrategy(IStrategy s, uint256 cap) internal {
        vm.prank(curator);
        vault.submitCap(s, cap);
        skip(vault.timelock());
        vault.acceptCap(s);
    }

    function _deposit(address user, uint256 assets) internal returns (uint256 shares) {
        usdg.mint(user, assets);
        vm.startPrank(user);
        usdg.approve(address(vault), assets);
        shares = vault.deposit(assets, user);
        vm.stopPrank();
    }

    function _allocate(uint256 assets) internal {
        vm.prank(curator);
        vault.allocate(strategy, assets);
    }

    /// @dev Simulate yield in the target vault.
    function _accrueYield(uint256 assets) internal {
        usdg.mint(address(target), assets);
    }
}
