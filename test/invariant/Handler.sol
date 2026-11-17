// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {KassoraVault} from "../../src/KassoraVault.sol";
import {ERC4626Strategy} from "../../src/strategies/ERC4626Strategy.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockYieldVault} from "../mocks/MockYieldVault.sol";

/// @dev Drives random deposits, withdrawals, allocations and yield against the vault.
contract Handler is Test {
    KassoraVault internal vault;
    ERC4626Strategy internal strategy;
    MockERC20 internal usdg;
    MockYieldVault internal target;
    address internal curator;

    address[] public actors;
    uint256 public ghostDeposited;
    uint256 public ghostWithdrawn;

    constructor(KassoraVault v, ERC4626Strategy s, MockERC20 a, MockYieldVault t, address c) {
        vault = v;
        strategy = s;
        usdg = a;
        target = t;
        curator = c;
        for (uint256 i; i < 4; ++i) {
            actors.push(makeAddr(string(abi.encodePacked("actor", vm.toString(i)))));
        }
    }

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }

    function deposit(uint256 actorSeed, uint256 assets) external {
        address actor = actors[actorSeed % actors.length];
        uint256 max = vault.maxDeposit(actor);
        if (max == 0) return;
        assets = bound(assets, 1, max < 1e15 ? max : 1e15);
        usdg.mint(actor, assets);
        vm.startPrank(actor);
        usdg.approve(address(vault), assets);
        vault.deposit(assets, actor);
        vm.stopPrank();
        ghostDeposited += assets;
    }

    function redeem(uint256 actorSeed, uint256 shares) external {
        address actor = actors[actorSeed % actors.length];
        uint256 max = vault.maxRedeem(actor);
        if (max == 0) return;
        shares = bound(shares, 1, max);
        vm.prank(actor);
        ghostWithdrawn += vault.redeem(shares, actor, actor);
    }

    function allocate(uint256 assets) external {
        (uint192 cap,) = vault.config(strategy);
        uint256 room = cap > strategy.totalAssets() ? cap - strategy.totalAssets() : 0;
        uint256 idle = vault.idleAssets();
        uint256 max = room < idle ? room : idle;
        if (max == 0) return;
        assets = bound(assets, 1, max);
        vm.prank(curator);
        vault.allocate(strategy, assets);
    }

    function deallocate(uint256 assets) external {
        uint256 max = strategy.maxWithdraw();
        if (max == 0) return;
        assets = bound(assets, 1, max);
        vm.prank(curator);
        vault.deallocate(strategy, assets);
    }

    function yield(uint256 assets) external {
        if (target.totalSupply() == 0) return;
        assets = bound(assets, 1, target.totalAssets() / 100 + 1); // up to ~1% per call
        usdg.mint(address(target), assets);
    }

    function accrue() external {
        vault.accrueFee();
    }
}
