// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {MySunVaultUpgradeable} from "contracts/MySunVaultUpgradeable.sol";
import {ISwapExecutor} from "contracts/swap/UniversalRouterSwapExecutor.sol";
import {PoolKey} from "contracts/adapters/uniswap/v4/IPoolManagerMinimal.sol";
import {IPositionManagerMinimal} from "contracts/adapters/uniswap/v4/IPositionManagerMinimal.sol";

/// @notice Mainnet 4663: swap the burner's PONS -> USDG on the PONS/USDG v4 FablesRamp hook pool.
///         BROADCAST SAFE: only msg.sender's own tokens move; no vault interaction.
///         Args: none (amounts hardcoded — one-off test op).
contract SwapPonsForUsdg is Script {
    ISwapExecutor internal immutable EXECUTOR =
        ISwapExecutor(0x413a67ca4E83A4782F7745858979fE059ccbB431);

    address internal immutable PONS = 0x39dBED3a2bd333467115dE45665cC57F813C4571;
    address internal immutable USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    // currency0 = PONS (18 dp), fee -60 (demo pons mirror), FablesRamp impl.
    function _key() internal pure returns (PoolKey memory key) {
        key = PoolKey({
            currency0: 0x39dBED3a2bd333467115dE45665cC57F813C4571,
            currency1: 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168,
            fee: uint24(0x800000),
            tickSpacing: int24(60),
            hooks: 0x08E52564Bad99E05a694b4809F397edcA417A080
        });
    }

    // Exact half of the received 26.612050... PONS, and a ~2% slippage buffer.
    uint256 internal constant AMOUNT_IN = 13_306_025_005_984_145_109; // PONS (18 dp)
    uint256 internal constant MIN_OUT = 4_600_000; // USDG (6 dp); spot 0.35499 -> ~4.7235e6 expected

    function run() external {
        uint256 in0 = IERC20(PONS).balanceOf(msg.sender);
        uint256 usdgBefore = IERC20(USDG).balanceOf(msg.sender);

        // Two-layer permission is executor-internal; the caller only pre-approves the token.
        IERC20(PONS).approve(address(EXECUTOR), AMOUNT_IN);
        uint256 out = EXECUTOR.swapV4ExactIn(_key(), true, AMOUNT_IN, MIN_OUT);

        console2.log("PONS balance in: ", in0);
        console2.log("USDG out (delta): ", out);
        console2.log("USDG balance: ", usdgBefore, "->", IERC20(USDG).balanceOf(msg.sender));
        require(out >= MIN_OUT, "slippage exceeded");
    }
}