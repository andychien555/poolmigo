// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.34;

/// @notice Minimal WETH9 surface for the native-ETH bridging. RHC WETH 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73 (a
///         transparent proxy over a standard WETH9 implementation) — `deposit()` / `withdraw(uint256)` checked with
///         `cast` against RHC. `withdraw` pays the caller with native ETH (a receive hook is invoked).
interface IWETH9Minimal {
    /// @dev selector 0xd0e30db0. Mints `msg.value` WETH to the caller.
    function deposit() external payable;

    /// @dev selector 0x2e1a7d4d. Burns `wad` of the caller's WETH and sends `wad` native ETH to the caller.
    function withdraw(uint256 wad) external;
}

/// @notice v4-periphery `NativeWrapper.WETH9()` — the WETH the PositionManager (and its UNWRAP / WRAP actions) is
///         wired to. Selector 0x4aa4a4fc, checked with `cast` against the RHC PositionManager (returns RHC WETH).
interface INativeWrapperMinimal {
    function WETH9() external view returns (address);
}
