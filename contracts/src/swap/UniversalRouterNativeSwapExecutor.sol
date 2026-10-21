// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {INativeSwapExecutor} from "contracts/interfaces/INativeSwapExecutor.sol";
import {IUniversalRouter, UniversalRouterCodec} from "contracts/adapters/uniswap/IUniversalRouter.sol";
import {IPermit2Minimal} from "contracts/adapters/uniswap/v4/IPermit2Minimal.sol";
import {PoolKey} from "contracts/adapters/uniswap/v4/IPoolManagerMinimal.sol";
import {IWETH9Minimal} from "contracts/adapters/uniswap/IWETH9Minimal.sol";
import {UniversalRouterSwapExecutor} from "contracts/swap/UniversalRouterSwapExecutor.sol";

/**
 * @title UniversalRouterNativeSwapExecutor
 * @author MySun
 * @notice {UniversalRouterSwapExecutor} (inherited unchanged: {swapV3ExactIn} / {swapV4ExactIn} on ERC-20 venues) plus
 *         {swapV4NativeExactIn}: a single-hop exact-input `V4_SWAP` (SWAP_EXACT_IN_SINGLE + SETTLE + TAKE, the same
 *         {UniversalRouterCodec} encoding) on a v4 pool whose currency0 is NATIVE ETH, with the WETH⇄ETH bridge done
 *         here so the caller never handles native ETH:
 *         - ETH → currency1: pull exactly `amountIn` WETH, `WETH.withdraw(amountIn)`, `execute{value: amountIn}` — the
 *           router's SETTLE pays the PoolManager from that value (native settles ignore `payerIsUser`; SETTLE's explicit
 *           amount makes the router spend exactly `amountIn` or revert), TAKE sends currency1 to the caller. No
 *           approval of any kind exists on this path;
 *         - currency1 → ETH: pull exactly `amountIn`, Permit2 layers exact and zeroed per call (as the base), TAKE the
 *           native output to THIS contract, wrap exactly the received ETH, transfer that WETH to the caller.
 *         The router's min-out revert maps to `SwapExecutor__SlippageExceeded` (as the base) and the caller-side
 *         output delta is re-checked against `minOut`.
 *
 *         Same permissionless-safety argument as the base: only the caller's own `amountIn` moves, the output goes to
 *         the caller, nothing at rest — no ETH (a native leg is unwrapped and spent, or received and wrapped, inside the
 *         call), no token, no allowance. `receive` accepts ETH only from WETH (withdraw) and the router's PoolManager
 *         (TAKE), and only while a swap is running. Stateless: immutables only — no owner, no storage.
 *
 * @dev A separate instance, NOT a change to the shared ERC-20 executor the other adapters use. Not audited. Audit
 *      attention: the output deltas (`balanceOf(msg.sender)` / `address(this).balance` before → execute → after) carry
 *      the same benign `reentrancy-balance` triage as the base `_swap` — every entrypoint is `nonReentrant`, `receive`
 *      is closed outside a swap, and no path lets a reentrant actor shrink the measured balance.
 * @custom:security-contact security@mysun.example
 */
contract UniversalRouterNativeSwapExecutor is UniversalRouterSwapExecutor, INativeSwapExecutor {
    using SafeERC20 for IERC20;

    /// @inheritdoc INativeSwapExecutor
    address public immutable WETH9;
    /// @inheritdoc INativeSwapExecutor
    address public immutable POOL_MANAGER;

    /// @dev `weth` must be non-zero with code; the PoolManager is the router's own (`poolManager()`, non-zero).
    constructor(address universalRouter, address permit2, address weth)
        UniversalRouterSwapExecutor(universalRouter, permit2)
    {
        if (weth == address(0)) {
            revert SwapExecutor__ZeroAddress();
        }
        if (weth.code.length == 0) {
            revert SwapExecutor__NoCode(weth);
        }
        address manager = IUniversalRouter(universalRouter).poolManager();
        if (manager == address(0)) {
            revert SwapExecutor__ZeroAddress();
        }
        WETH9 = weth;
        POOL_MANAGER = manager;
    }

    /// @dev Native ETH lands only mid-swap: WETH's withdraw payout and the PoolManager's TAKE. Fits WETH9's 2,300-gas
    ///      `transfer` stipend (one TLOAD + two immutable compares).
    receive() external payable {
        if (!_reentrancyGuardEntered() || (msg.sender != WETH9 && msg.sender != POOL_MANAGER)) {
            revert SwapExecutor__UnexpectedEth(msg.sender);
        }
    }

    /// @inheritdoc INativeSwapExecutor
    function swapV4NativeExactIn(PoolKey calldata key, bool zeroForOne, uint256 amountIn, uint256 minOut)
        external
        nonReentrant
        returns (uint256 amountOut)
    {
        if (key.currency0 != address(0)) {
            revert SwapExecutor__NotNativePool(key.currency0);
        }
        if (amountIn == 0) {
            revert SwapExecutor__ZeroAmount();
        }
        if (minOut == 0) {
            revert SwapExecutor__ZeroMinOut();
        }
        address weth = WETH9;
        address token1 = key.currency1;
        // The caller-facing input / output tokens (WETH stands in for the native leg).
        (address tokenIn, address tokenOut) = zeroForOne ? (weth, token1) : (token1, weth);
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        (bytes memory commands, bytes[] memory inputs) = UniversalRouterCodec.v4ExactInSingle(
            key,
            zeroForOne,
            SafeCast.toUint128(amountIn),
            SafeCast.toUint128(minOut),
            zeroForOne ? msg.sender : address(this)
        );

        if (zeroForOne) {
            uint256 outBefore = IERC20(token1).balanceOf(msg.sender);
            IWETH9Minimal(weth).withdraw(amountIn);
            _execute(amountIn, tokenIn, amountIn, minOut, commands, inputs);
            amountOut = IERC20(token1).balanceOf(msg.sender) - outBefore;
        } else {
            uint256 ethBefore = address(this).balance;
            IERC20(token1).forceApprove(PERMIT2, amountIn);
            IPermit2Minimal(PERMIT2)
                .approve(token1, UNIVERSAL_ROUTER, SafeCast.toUint160(amountIn), uint48(block.timestamp));
            _execute(0, tokenIn, amountIn, minOut, commands, inputs);
            // Never leave a standing allowance: both layers back to 0.
            IPermit2Minimal(PERMIT2).approve(token1, UNIVERSAL_ROUTER, 0, 0);
            IERC20(token1).forceApprove(PERMIT2, 0);
            amountOut = address(this).balance - ethBefore;
            IWETH9Minimal(weth).deposit{value: amountOut}();
            IERC20(weth).safeTransfer(msg.sender, amountOut);
        }
        if (amountOut < minOut) {
            revert SwapExecutor__SlippageExceeded(tokenIn, amountIn, minOut);
        }
        emit SwapExecuted(msg.sender, tokenIn, tokenOut, amountIn, amountOut);
    }

    /// @dev `execute{value}` with the base's error mapping: the router's min-out failure → `SwapExecutor__SlippageExceeded`,
    ///      any other revert bubbles raw.
    ///      The line below suppresses slither's arbitrary-send-eth here — Triaged FALSE-POSITIVE: the executor is
    ///      permissionless and stateless by design (only msg.sender's own tokens ever move; the output settles back
    ///      to msg.sender; both Permit2 layers zeroed per call, nothing at rest — see contracts/AGENTS.md "Swap
    ///      executor audit attention"). Do not widen the suppression. 0.11.4 matches marker comments ONLY on the
    ///      immediately preceding line, double-slash — keep the marker glued to the function.
    // slither-disable-next-line arbitrary-send-eth
    function _execute(
        uint256 value,
        address tokenIn,
        uint256 amountIn,
        uint256 minOut,
        bytes memory commands,
        bytes[] memory inputs
    ) private {
        try IUniversalRouter(UNIVERSAL_ROUTER).execute{value: value}(commands, inputs, block.timestamp) {}
        catch (bytes memory reason) {
            if (UniversalRouterCodec.isTooLittleReceived(reason)) {
                revert SwapExecutor__SlippageExceeded(tokenIn, amountIn, minOut);
            }
            assembly ("memory-safe") {
                revert(add(reason, 0x20), mload(reason))
            }
        }
    }
}
