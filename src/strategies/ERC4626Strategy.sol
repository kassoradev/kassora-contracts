// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IStrategy} from "../interfaces/IStrategy.sol";

/// @title ERC4626Strategy
/// @notice Adapter that deposits the vault's asset into an existing ERC-4626 vault
///         (e.g. Spark spUSDG Savings or a Morpho USDG vault on Robinhood Chain).
/// @dev Holds the target's shares on behalf of exactly one KassoraVault. No owner, no admin keys.
contract ERC4626Strategy is IStrategy {
    using SafeERC20 for IERC20;

    address public immutable vault;
    address public immutable asset;
    IERC4626 public immutable target;

    error OnlyVault();
    error AssetMismatch();

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    constructor(address vault_, IERC4626 target_) {
        address asset_ = target_.asset();
        if (IERC4626(vault_).asset() != asset_) revert AssetMismatch();
        vault = vault_;
        target = target_;
        asset = asset_;
    }

    function totalAssets() external view returns (uint256) {
        return target.previewRedeem(target.balanceOf(address(this))) + _idle();
    }

    function maxWithdraw() external view returns (uint256) {
        return target.maxWithdraw(address(this)) + _idle();
    }

    function deposit(uint256 assets) external onlyVault {
        IERC20(asset).forceApprove(address(target), assets);
        target.deposit(assets, address(this));
    }

    function withdraw(uint256 assets, address to) external onlyVault returns (uint256 withdrawn) {
        uint256 idle = _idle();
        if (idle != 0) {
            withdrawn = Math.min(idle, assets);
            IERC20(asset).safeTransfer(to, withdrawn);
        }
        uint256 fromTarget = Math.min(assets - withdrawn, target.maxWithdraw(address(this)));
        if (fromTarget != 0) {
            target.withdraw(fromTarget, to, address(this));
            withdrawn += fromTarget;
        }
    }

    function withdrawAll(address to) external onlyVault returns (uint256 withdrawn) {
        uint256 shares = target.maxRedeem(address(this));
        if (shares != 0) withdrawn = target.redeem(shares, to, address(this));
        uint256 idle = _idle();
        if (idle != 0) {
            IERC20(asset).safeTransfer(to, idle);
            withdrawn += idle;
        }
    }

    function _idle() internal view returns (uint256) {
        return IERC20(asset).balanceOf(address(this));
    }
}
