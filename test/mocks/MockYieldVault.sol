// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

/// @dev Plain ERC-4626 standing in for Spark/Morpho. Yield is simulated by minting asset to it.
///      `liquidityCap` simulates a target that can only release part of its assets.
contract MockYieldVault is ERC4626 {
    uint256 public liquidityCap = type(uint256).max;
    bool public broken;
    bool public brokenViews;

    constructor(IERC20 asset_) ERC4626(asset_) ERC20("Mock Yield Vault", "myv") {}

    function setLiquidityCap(uint256 cap) external {
        liquidityCap = cap;
    }

    function setBroken(bool b) external {
        broken = b;
    }

    function setBrokenViews(bool b) external {
        brokenViews = b;
    }

    function previewRedeem(uint256 shares) public view override returns (uint256) {
        require(!brokenViews, "broken views");
        return super.previewRedeem(shares);
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        require(!brokenViews, "broken views");
        uint256 m = super.maxWithdraw(owner);
        return m < liquidityCap ? m : liquidityCap;
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        uint256 m = super.maxRedeem(owner);
        uint256 capShares = convertToShares(liquidityCap == type(uint256).max ? type(uint128).max : liquidityCap);
        return m < capShares ? m : capShares;
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        require(!broken, "broken");
        super._withdraw(caller, receiver, owner, assets, shares);
    }
}
