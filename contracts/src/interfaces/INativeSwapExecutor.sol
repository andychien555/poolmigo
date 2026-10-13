// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.34;

import {PoolKey} from "contracts/adapters/uniswap/v4/IPoolManagerMinimal.sol";
import {ISwapExecutor} from "contracts/interfaces/ISwapExecutor.sol";

/**
 * @title INativeSwapExecutor
 * @notice {ISwapExecutor} plus a WETH-bridged single-hop exact-input swap on a v4 pool whose currency0 is NATIVE ETH
 *         (address(0)). The caller speaks WETH only: it approves EXACTLY `amountIn` of the input token (WETH when
 *         `zeroForOne`, else currency1); a native output is wrapped and delivered as WETH to the CALLER. Same rules as
 *         {ISwapExecutor}: only the caller's own tokens move, no recipient parameter, nothing at rest (no ETH, no
 *         token, no allowance).
 * @custom:security-contact security@mysun.example
 */
interface INativeSwapExecutor is ISwapExecutor {
    /// @dev `key.currency0` is not native ETH (address(0)).
    error SwapExecutor__NotNativePool(address currency0);
    /// @dev Native ETH sent by anyone but WETH (withdraw) or the router's PoolManager (TAKE).
    error SwapExecutor__UnexpectedEth(address sender);

    /// @notice The WETH9 every native leg is bridged through (immutable).
    function WETH9() external view returns (address);

    /// @notice The router's PoolManager — the only native-ETH sender besides WETH (immutable).
    function POOL_MANAGER() external view returns (address);

    /// @notice Swap exactly `amountIn` through the native-ETH v4 pool `key` (currency0 = address(0)) on the router's
    ///         PoolManager for at least `minOut`; output to the caller. `zeroForOne` (ETH → currency1): `amountIn` WETH
    ///         is pulled, unwrapped and sent as the router call's value; currency1 lands in the caller's balance.
    ///         Otherwise (currency1 → ETH): `amountIn` currency1 is pulled and paid through Permit2; the native output is
    ///         taken to the executor, wrapped, and transferred to the caller as WETH.
    /// @param key The v4 pool (currency0 MUST be address(0); any hooks are the caller's own choice).
    /// @param zeroForOne Direction: ETH → currency1.
    /// @param amountIn Exact input (> 0, <= uint128 max), pulled from the caller (WETH or currency1).
    /// @param minOut Output floor (> 0, <= uint128 max).
    /// @return amountOut The caller's output balance increase (currency1, or WETH) — >= `minOut`.
    function swapV4NativeExactIn(PoolKey calldata key, bool zeroForOne, uint256 amountIn, uint256 minOut)
        external
        returns (uint256 amountOut);
}
