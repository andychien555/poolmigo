// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.34;

/**
 * @title IDepositSplit
 * @notice Stateless split of a deposit's pulled amounts across the CALLER vault's adapters, in proportion to what
 *         each adapter currently reports holding per token (deposit-deploy, T2d). Raw token units only — no USD,
 *         no valuation, no oracle.
 * @custom:security-contact security@mysun.example
 */
interface IDepositSplit {
    /// @dev `required.length != registry.length`.
    error DepositSplit__LengthMismatch();

    /// @notice Per-adapter deploy vectors for `required` (aligned to `registry`), over `msg.sender`'s `adapters()`.
    /// @dev amount_ij = floor(required_r * a_ij / D_r), with a_ij = adapter i's reported `position()` amount of its
    ///      j-th token, r = that token's index in `registry` and D_r = Σ_i a_ir. A token absent from `registry`, or
    ///      one with D_r == 0, gets 0. Σ_ij amount_ij (per token r) <= required_r; the floor dust is not assigned.
    /// @param registry Tokens the amounts are denominated in (the vault passes the deposit's `tokens_`).
    /// @param required Amount per `registry` token to split.
    /// @return flat ONE flat vector of frames, one per adapter in `adapters()` order: `[n_i][amount_i1 .. amount_in]`
    ///         (n_i = the adapter's `position()` token count, amounts in that token order), or the single word `[0]`
    ///         when every amount of adapter i is 0. Each non-empty frame is ABI-shaped like a `uint256[]` in memory.
    function split(address[] calldata registry, uint256[] calldata required)
        external
        view
        returns (uint256[] memory flat);
}
