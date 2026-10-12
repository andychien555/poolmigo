// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.34;

/**
 * @title IAdapterFees
 * @notice OPTIONAL fees view of a {IPositionAdapter} (advertised through ERC-165): splits what {position} reports into
 *         its fee part so callers (keepers, the FE, off-chain accounting) can tell principal from fees. Purely
 *         additive — the vault never reads it, capability masks do not cover it, and an adapter without it is still a
 *         complete {IPositionAdapter}. Raw token units only — no USD, no valuation.
 * @custom:security-contact security@mysun.example
 */
interface IAdapterFees {
    /// @notice The GROSS fee part of each position token: fees settled to the adapter but not yet delivered (the v4 fee
    ///         bank / the v3 NFPM `tokensOwed`) + fees accrued in the venue since the position's last modification
    ///         (feeGrowthInside accounting — no price involved). Exactly the sum {IPositionAdapter-position} nets the
    ///         vault's performance fee out of; principal and free idle are NOT included. Never pokes the venue: an
    ///         empty (or zero-liquidity) position reports the settled part only.
    /// @return tokens The adapter's tokens, index-aligned with and in the same (stable) order as `position()`.
    /// @return amounts `amounts[i]` = the gross fee part of `tokens[i]`.
    function fees() external view returns (address[] memory tokens, uint256[] memory amounts);
}
