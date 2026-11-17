// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IStrategy
/// @notice Minimal adapter interface between KassoraVault and an external yield source.
/// @dev One strategy instance serves exactly one vault and one asset. The vault pushes
///      assets to the strategy before calling `deposit`, and the strategy transfers assets
///      straight to `to` on `withdraw`. All mutating functions MUST be restricted to `vault()`.
interface IStrategy {
    /// @notice The only address allowed to call mutating functions.
    function vault() external view returns (address);

    /// @notice The ERC-20 asset managed by this strategy. MUST equal `IERC4626(vault()).asset()`.
    function asset() external view returns (address);

    /// @notice Total assets attributable to the vault, denominated in `asset()`.
    /// @dev Should reflect what could realistically be redeemed (net of exit fees), not a mark-to-model value.
    function totalAssets() external view returns (uint256);

    /// @notice Assets that can be withdrawn right now without reverting.
    function maxWithdraw() external view returns (uint256);

    /// @notice Invest `assets` that the vault has already transferred to this contract.
    function deposit(uint256 assets) external;

    /// @notice Withdraw up to `assets` and send them to `to`. Returns the amount actually sent.
    /// @dev MUST NOT revert when `assets > maxWithdraw()`; it should cap and return the realised amount.
    function withdraw(uint256 assets, address to) external returns (uint256 withdrawn);

    /// @notice Exit the position entirely and send everything to `to`. Used by the vault's emergency path.
    function withdrawAll(address to) external returns (uint256 withdrawn);
}
