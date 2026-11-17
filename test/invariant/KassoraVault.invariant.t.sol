// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "../Base.t.sol";
import {Handler} from "./Handler.sol";

contract KassoraVaultInvariantTest is BaseTest {
    Handler internal handler;

    function setUp() public override {
        super.setUp();
        vm.prank(owner);
        vault.submitFee(0.1e18);
        skip(TIMELOCK);
        vault.acceptFee();

        handler = new Handler(vault, strategy, usdg, target, curator);
        targetContract(address(handler));
    }

    /// totalAssets is exactly idle plus what the strategy reports.
    function invariant_TotalAssetsIsIdlePlusStrategies() public view {
        assertEq(vault.totalAssets(), vault.idleAssets() + strategy.totalAssets());
    }

    /// Every share is held by an actor or the fee recipient. No shares appear from nowhere.
    function invariant_SupplyIsSumOfBalances() public view {
        uint256 sum = vault.balanceOf(feeRecipient);
        for (uint256 i; i < handler.actorsLength(); ++i) {
            sum += vault.balanceOf(handler.actors(i));
        }
        assertEq(vault.totalSupply(), sum);
    }

    /// The vault can always cover all shares at the current share price (solvency).
    function invariant_Solvent() public view {
        assertLe(vault.convertToAssets(vault.totalSupply()), vault.totalAssets());
    }

    /// Users cannot pull out more than they put in plus the yield that exists in the target.
    function invariant_UsersNeverWithdrawMoreThanDepositedPlusYield() public view {
        assertLe(handler.ghostWithdrawn(), handler.ghostDeposited() + usdg.balanceOf(address(target)) + 1e15);
    }
}
