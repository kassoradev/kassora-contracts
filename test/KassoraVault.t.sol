// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {BaseTest} from "./Base.t.sol";
import {KassoraVault} from "../src/KassoraVault.sol";
import {ERC4626Strategy} from "../src/strategies/ERC4626Strategy.sol";
import {IStrategy} from "../src/interfaces/IStrategy.sol";
import {MockYieldVault} from "./mocks/MockYieldVault.sol";

contract KassoraVaultTest is BaseTest {
    /* ------------------------------- deposits ------------------------------- */

    function test_Deposit_MintsSharesAndTracksAssets() public {
        uint256 shares = _deposit(alice, 1_000 * USDG);
        assertEq(vault.balanceOf(alice), shares);
        assertEq(vault.totalAssets(), 1_000 * USDG);
        assertEq(vault.idleAssets(), 1_000 * USDG);
        assertEq(vault.lastTotalAssets(), 1_000 * USDG);
        assertApproxEqAbs(vault.convertToAssets(shares), 1_000 * USDG, 1); // virtual share rounding
    }

    function test_Deposit_RevertsAboveDepositCap() public {
        usdg.mint(alice, DEPOSIT_CAP + 1);
        vm.startPrank(alice);
        usdg.approve(address(vault), DEPOSIT_CAP + 1);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, alice, DEPOSIT_CAP + 1, DEPOSIT_CAP)
        );
        vault.deposit(DEPOSIT_CAP + 1, alice);
        vm.stopPrank();
    }

    function test_MaxDeposit_ShrinksAsVaultFills() public {
        _deposit(alice, 4_000_000 * USDG);
        assertEq(vault.maxDeposit(bob), DEPOSIT_CAP - 4_000_000 * USDG);
    }

    /* ------------------------------ allocation ------------------------------ */

    function test_Allocate_MovesIdleIntoStrategy() public {
        _deposit(alice, 1_000 * USDG);
        _allocate(600 * USDG);
        assertEq(vault.idleAssets(), 400 * USDG);
        assertEq(strategy.totalAssets(), 600 * USDG);
        assertEq(vault.totalAssets(), 1_000 * USDG);
    }

    function test_Allocate_RevertsAboveStrategyCap() public {
        _deposit(alice, STRATEGY_CAP + 1);
        vm.prank(curator);
        vm.expectRevert(KassoraVault.StrategyCapExceeded.selector);
        vault.allocate(strategy, STRATEGY_CAP + 1);
    }

    function test_Allocate_OnlyCuratorOrOwner() public {
        _deposit(alice, 1_000 * USDG);
        vm.prank(alice);
        vm.expectRevert(KassoraVault.NotCuratorRole.selector);
        vault.allocate(strategy, 1);

        vm.prank(owner);
        vault.allocate(strategy, 1);
    }

    function test_Allocate_RevertsForUnknownStrategy() public {
        ERC4626Strategy other = new ERC4626Strategy(address(vault), IERC4626(address(target)));
        _deposit(alice, 1_000 * USDG);
        vm.prank(curator);
        vm.expectRevert(KassoraVault.StrategyNotEnabled.selector);
        vault.allocate(other, 1);
    }

    function test_Deallocate_ReturnsAssetsToIdle() public {
        _deposit(alice, 1_000 * USDG);
        _allocate(1_000 * USDG);
        vm.prank(curator);
        vault.deallocate(strategy, 300 * USDG);
        assertEq(vault.idleAssets(), 300 * USDG);
        assertEq(strategy.totalAssets(), 700 * USDG);
    }

    /* ------------------------------ withdrawals ----------------------------- */

    function test_Withdraw_PullsFromStrategyWhenIdleIsShort() public {
        _deposit(alice, 1_000 * USDG);
        _allocate(900 * USDG);

        vm.prank(alice);
        vault.withdraw(500 * USDG, alice, alice);

        assertEq(usdg.balanceOf(alice), 500 * USDG);
        assertEq(vault.totalAssets(), 500 * USDG);
    }

    function test_Withdraw_RevertsWhenLiquidityIsLocked() public {
        _deposit(alice, 1_000 * USDG);
        _allocate(1_000 * USDG);
        target.setLiquidityCap(100 * USDG);

        assertEq(vault.maxWithdraw(alice), 100 * USDG);
        vm.prank(alice);
        vm.expectRevert();
        vault.withdraw(500 * USDG, alice, alice);
    }

    function test_Withdraw_SkipsBrokenStrategy() public {
        MockYieldVault target2 = new MockYieldVault(IERC20(address(usdg)));
        ERC4626Strategy s2 = new ERC4626Strategy(address(vault), IERC4626(address(target2)));
        _enableStrategy(s2, STRATEGY_CAP);

        _deposit(alice, 1_000 * USDG);
        _allocate(500 * USDG);
        vm.prank(curator);
        vault.allocate(s2, 500 * USDG);

        target.setBroken(true); // first in queue reverts on withdraw
        vm.prank(alice);
        vault.withdraw(400 * USDG, alice, alice);
        assertEq(usdg.balanceOf(alice), 400 * USDG);
    }

    function test_Redeem_FullExitAfterYield() public {
        uint256 shares = _deposit(alice, 1_000 * USDG);
        _allocate(1_000 * USDG);
        _accrueYield(100 * USDG);

        vm.prank(alice);
        uint256 assets = vault.redeem(shares, alice, alice);
        // fee is 0 by default, so alice gets (almost) everything
        assertApproxEqAbs(assets, 1_100 * USDG, 2);
    }

    /* ----------------------------- strategies/caps -------------------------- */

    function test_SubmitCap_NewStrategyIsTimelocked() public {
        ERC4626Strategy s2 = new ERC4626Strategy(address(vault), IERC4626(address(target)));
        vm.prank(curator);
        vault.submitCap(s2, 1_000 * USDG);

        vm.expectRevert(KassoraVault.TimelockNotElapsed.selector);
        vault.acceptCap(s2);

        skip(TIMELOCK);
        vault.acceptCap(s2);
        (uint192 cap, bool enabled) = vault.config(s2);
        assertEq(cap, 1_000 * USDG);
        assertTrue(enabled);
        assertEq(vault.withdrawQueueLength(), 2);
    }

    function test_SubmitCap_DecreaseIsImmediate() public {
        vm.prank(curator);
        vault.submitCap(strategy, 1 * USDG);
        (uint192 cap,) = vault.config(strategy);
        assertEq(cap, 1 * USDG);
    }

    function test_SubmitCap_RejectsStrategyForOtherVault() public {
        ERC4626Strategy foreign = new ERC4626Strategy(address(target), IERC4626(address(target)));
        vm.prank(curator);
        vm.expectRevert(KassoraVault.InvalidStrategy.selector);
        vault.submitCap(foreign, 1);
    }

    function test_RevokePendingCap_ByGuardian() public {
        ERC4626Strategy s2 = new ERC4626Strategy(address(vault), IERC4626(address(target)));
        vm.prank(curator);
        vault.submitCap(s2, 1_000 * USDG);
        vm.prank(guardian);
        vault.revokePendingCap(s2);

        skip(TIMELOCK);
        vm.expectRevert(KassoraVault.NoPendingValue.selector);
        vault.acceptCap(s2);
    }

    function test_RemoveStrategy_RequiresEmptyAndZeroCap() public {
        _deposit(alice, 1_000 * USDG);
        _allocate(100 * USDG);

        vm.startPrank(curator);
        vault.submitCap(strategy, 0);
        vm.expectRevert(KassoraVault.StrategyNotEmpty.selector);
        vault.removeStrategy(strategy);

        vault.deallocate(strategy, 100 * USDG);
        vault.removeStrategy(strategy);
        vm.stopPrank();

        assertEq(vault.withdrawQueueLength(), 0);
        assertEq(vault.totalAssets(), 1_000 * USDG);
    }

    function test_SetWithdrawQueue_MustBePermutation() public {
        ERC4626Strategy s2 = new ERC4626Strategy(address(vault), IERC4626(address(target)));
        _enableStrategy(s2, 1);

        IStrategy[] memory q = new IStrategy[](2);
        q[0] = s2;
        q[1] = s2;
        vm.prank(curator);
        vm.expectRevert(KassoraVault.InvalidQueue.selector);
        vault.setWithdrawQueue(q);

        q[1] = strategy;
        vm.prank(curator);
        vault.setWithdrawQueue(q);
        assertEq(address(vault.withdrawQueue(0)), address(s2));
    }

    function test_MaxStrategies() public {
        for (uint256 i = 1; i < vault.MAX_STRATEGIES(); ++i) {
            _enableStrategy(new ERC4626Strategy(address(vault), IERC4626(address(target))), 1);
        }
        ERC4626Strategy extra = new ERC4626Strategy(address(vault), IERC4626(address(target)));
        vm.prank(curator);
        vault.submitCap(extra, 1);
        skip(TIMELOCK);
        vm.expectRevert(KassoraVault.MaxStrategiesReached.selector);
        vault.acceptCap(extra);
    }

    /* --------------------------------- fees --------------------------------- */

    function test_Fee_MintsSharesOnProfitOnly() public {
        _setFee(0.1e18);
        _deposit(alice, 1_000 * USDG);
        _allocate(1_000 * USDG);
        _accrueYield(100 * USDG);

        vault.accrueFee();
        uint256 feeAssets = vault.convertToAssets(vault.balanceOf(feeRecipient));
        assertApproxEqAbs(feeAssets, 10 * USDG, 2); // 10% of 100 USDG profit

        // no new profit, no new fee
        uint256 before = vault.balanceOf(feeRecipient);
        vault.accrueFee();
        assertEq(vault.balanceOf(feeRecipient), before);
    }

    function test_Fee_PreviewMatchesExecution() public {
        _setFee(0.2e18);
        _deposit(alice, 1_000 * USDG);
        _allocate(1_000 * USDG);
        _accrueYield(50 * USDG);

        uint256 previewShares = vault.previewDeposit(500 * USDG);
        uint256 shares = _deposit(bob, 500 * USDG);
        assertEq(shares, previewShares);
    }

    function test_Fee_CannotExceedMax() public {
        uint256 maxFee = vault.MAX_FEE();
        vm.prank(owner);
        vm.expectRevert(KassoraVault.FeeTooHigh.selector);
        vault.submitFee(maxFee + 1);
    }

    function test_Fee_IncreaseIsTimelockedDecreaseIsNot() public {
        vm.prank(owner);
        vault.submitFee(0.1e18);
        assertEq(vault.fee(), 0);

        skip(TIMELOCK);
        vault.acceptFee();
        assertEq(vault.fee(), 0.1e18);

        vm.prank(owner);
        vault.submitFee(0.05e18);
        assertEq(vault.fee(), 0.05e18);
    }

    function test_Fee_RequiresRecipient() public {
        vm.prank(owner);
        vault.setFeeRecipient(address(0));
        vm.prank(owner);
        vm.expectRevert(KassoraVault.FeeRecipientNotSet.selector);
        vault.submitFee(0.1e18);
    }

    function test_Fee_NotChargedOnLoss() public {
        _setFee(0.1e18);
        _deposit(alice, 1_000 * USDG);
        _allocate(1_000 * USDG);
        usdg.burn(address(target), 100 * USDG); // strategy loses 10%
        vault.accrueFee();
        assertEq(vault.balanceOf(feeRecipient), 0);
    }

    /* ------------------------------- timelock ------------------------------- */

    function test_Timelock_IncreaseIsImmediate() public {
        vm.prank(owner);
        vault.submitTimelock(2 days);
        assertEq(vault.timelock(), 2 days);
    }

    function test_Timelock_DecreaseWaitsCurrentTimelock() public {
        vm.prank(owner);
        vault.submitTimelock(3 days);
        vm.prank(owner);
        vault.submitTimelock(1 days);
        assertEq(vault.timelock(), 3 days);

        skip(3 days - 1);
        vm.expectRevert(KassoraVault.TimelockNotElapsed.selector);
        vault.acceptTimelock();
        skip(1);
        vault.acceptTimelock();
        assertEq(vault.timelock(), 1 days);
    }

    function test_Timelock_Bounds() public {
        vm.startPrank(owner);
        vm.expectRevert(KassoraVault.TimelockOutOfBounds.selector);
        vault.submitTimelock(1 hours);
        vm.expectRevert(KassoraVault.TimelockOutOfBounds.selector);
        vault.submitTimelock(3 weeks);
        vm.stopPrank();
    }

    /* ------------------------------ pause/guardian -------------------------- */

    function test_Pause_BlocksDepositsAndAllocationButNotWithdrawals() public {
        _deposit(alice, 1_000 * USDG);
        _allocate(500 * USDG);

        vm.prank(guardian);
        vault.pause();
        assertEq(vault.maxDeposit(bob), 0);

        usdg.mint(bob, 1 * USDG);
        vm.startPrank(bob);
        usdg.approve(address(vault), 1 * USDG);
        vm.expectRevert();
        vault.deposit(1 * USDG, bob);
        vm.stopPrank();

        vm.prank(curator);
        vm.expectRevert();
        vault.allocate(strategy, 1);

        vm.prank(alice);
        vault.withdraw(800 * USDG, alice, alice);
        assertEq(usdg.balanceOf(alice), 800 * USDG);
    }

    function test_Unpause_OnlyOwner() public {
        vm.prank(guardian);
        vault.pause();
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        vault.unpause();
        vm.prank(owner);
        vault.unpause();
    }

    function test_EmergencyExit_PullsEverythingAndZeroesCap() public {
        _deposit(alice, 1_000 * USDG);
        _allocate(800 * USDG);
        _accrueYield(8 * USDG);

        vm.prank(guardian);
        vault.emergencyExit(strategy);

        (uint192 cap,) = vault.config(strategy);
        assertEq(cap, 0);
        assertEq(strategy.totalAssets(), 0);
        assertApproxEqAbs(vault.idleAssets(), 1_008 * USDG, 1);
    }

    function test_Fee_ChargedOnRecoveryAfterLoss_NoHighWaterMark() public {
        _setFee(0.1e18);
        _deposit(alice, 1_000 * USDG);
        _allocate(1_000 * USDG);
        usdg.burn(address(target), 100 * USDG);
        vault.accrueFee();
        _accrueYield(100 * USDG); // back to where it started
        vault.accrueFee();
        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(feeRecipient)), 10 * USDG, 2);
    }

    function test_ForceRemove_UnfreezesVaultWhenStrategyViewsRevert() public {
        MockYieldVault target2 = new MockYieldVault(IERC20(address(usdg)));
        ERC4626Strategy s2 = new ERC4626Strategy(address(vault), IERC4626(address(target2)));
        _enableStrategy(s2, STRATEGY_CAP);

        _deposit(alice, 1_000 * USDG);
        _allocate(400 * USDG);
        vm.prank(curator);
        vault.allocate(s2, 300 * USDG);

        target2.setBrokenViews(true);
        vm.expectRevert();
        vault.totalAssets();

        vm.prank(guardian);
        vault.forceRemoveStrategy(s2);
        assertTrue(vault.paused());
        assertEq(vault.totalAssets(), 700 * USDG);

        // withdrawals work again (at the written-down price)
        vm.prank(alice);
        vault.withdraw(500 * USDG, alice, alice);
        assertEq(usdg.balanceOf(alice), 500 * USDG);

        // strategy fixed and re-added: its assets count again
        target2.setBrokenViews(false);
        _enableStrategy(s2, STRATEGY_CAP);
        assertApproxEqAbs(strategy.totalAssets() + s2.totalAssets() + vault.idleAssets(), vault.totalAssets(), 0);
        assertEq(s2.totalAssets(), 300 * USDG);
    }

    function test_ForceRemove_OnlyGuardianRole() public {
        vm.prank(curator);
        vm.expectRevert(KassoraVault.NotGuardianRole.selector);
        vault.forceRemoveStrategy(strategy);
    }

    function test_Withdraw_WorksWhenStrategyMaxWithdrawReverts() public {
        _deposit(alice, 1_000 * USDG);
        _allocate(500 * USDG);
        // only maxWithdraw breaks; idle still covers the withdrawal
        target.setLiquidityCap(0);
        vm.prank(alice);
        vault.withdraw(400 * USDG, alice, alice);
        assertEq(usdg.balanceOf(alice), 400 * USDG);
    }

    function test_Roles_OnlyOwnerSetsRoles() public {
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, curator));
        vault.setGuardian(curator);
    }

    function test_Ownership_IsTwoStep() public {
        vm.prank(owner);
        vault.transferOwnership(bob);
        assertEq(vault.owner(), owner);
        vm.prank(bob);
        vault.acceptOwnership();
        assertEq(vault.owner(), bob);
    }

    /* --------------------------- inflation attack --------------------------- */

    /// @dev Classic first-depositor attack: attacker deposits 1 wei, donates a lot, victim gets 0 shares.
    ///      With a 6-decimal virtual offset the attack costs the attacker far more than it steals.
    function test_InflationAttack_IsUnprofitable() public {
        uint256 donation = 10_000 * USDG;
        address attacker = makeAddr("attacker");

        _deposit(attacker, 1);
        usdg.mint(attacker, donation);
        vm.prank(attacker);
        usdg.transfer(address(vault), donation);

        uint256 victimShares = _deposit(alice, 10_000 * USDG);
        assertGt(victimShares, 0);

        uint256 attackerShares = vault.balanceOf(attacker);
        vm.prank(attacker);
        uint256 attackerOut = vault.redeem(attackerShares, attacker, attacker);
        assertLt(attackerOut, donation + 1, "attacker profited");

        vm.prank(alice);
        uint256 aliceOut = vault.redeem(victimShares, alice, alice);
        assertApproxEqRel(aliceOut, 10_000 * USDG, 0.0001e18);
    }

    /* --------------------------------- fuzz --------------------------------- */

    function testFuzz_DepositRedeem_NeverReturnsMore(uint256 assets, uint256 allocated) public {
        assets = bound(assets, 1, DEPOSIT_CAP);
        allocated = bound(allocated, 0, assets < STRATEGY_CAP ? assets : STRATEGY_CAP);

        uint256 shares = _deposit(alice, assets);
        if (allocated > 0) _allocate(allocated);

        vm.prank(alice);
        uint256 out = vault.redeem(shares, alice, alice);
        assertLe(out, assets);
        assertApproxEqAbs(out, assets, 2);
    }

    function testFuzz_FeeNeverExceedsShareOfProfit(uint256 feeRate, uint256 profit) public {
        feeRate = bound(feeRate, 1, vault.MAX_FEE());
        profit = bound(profit, 1 * USDG, 1_000_000 * USDG);
        _setFee(feeRate);

        _deposit(alice, 1_000_000 * USDG);
        _allocate(1_000_000 * USDG);
        _accrueYield(profit);
        vault.accrueFee();

        uint256 feeAssets = vault.convertToAssets(vault.balanceOf(feeRecipient));
        assertLe(feeAssets, profit * feeRate / 1e18 + 1);
    }

    /* -------------------------------- helpers ------------------------------- */

    function _setFee(uint256 newFee) internal {
        vm.prank(owner);
        vault.submitFee(newFee);
        skip(TIMELOCK);
        vault.acceptFee();
    }
}
