// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IDepositSplit} from "contracts/interfaces/IDepositSplit.sol";
import {IPositionAdapter} from "contracts/interfaces/IPositionAdapter.sol";

/// @dev The one vault getter the splitter reads (declared on the vault, not on {IPoolmigoVault}).
interface IDepositSplitVault {
    function adapters() external view returns (IPositionAdapter[] memory);
}

/**
 * @title DepositSplit
 * @author MySun
 * @notice Computes how a deposit's pulled amounts are deployed across the vault's adapters (deposit-deploy, T2d):
 *         per token, in proportion to what each adapter currently reports holding of it; floor; the dust stays
 *         idle in the vault. Raw token units only — no USD, no valuation, no oracle.
 * @dev Why a stateless callee: the split math (denominators, per-adapter scaling, framing) does not fit the vault's
 *      EIP-170 budget, so the vault keeps one external call + a thin frame walk and this contract carries the rest.
 *      No storage, no owner, no constructor arguments, not upgradeable — the vault pins its address as an
 *      immutable, so the split rule can only change with a new vault implementation.
 *
 *      Trust boundary: this contract only DECIDES AMOUNTS. It reads `msg.sender`'s `adapters()` and each adapter's
 *      `position()` (view calls); it holds, approves and moves nothing. The vault re-reads each adapter's
 *      `position()` itself for the token list it approves, checks every frame's length against it, and funds the
 *      amounts through its own idle check ({PoolmigoVaultUpgradeable-deployTo}'s path) — a wrong split can at worst
 *      make the deposit revert, never move a token outside a registered adapter's exact approval.
 *
 *      Output framing (one flat `uint256[]`, read IN PLACE by the vault): per adapter, in `adapters()` order,
 *      `[n_i][amount_i1 .. amount_in]` with n_i = the adapter's token count, or the single word `[0]` when all of
 *      its amounts are 0 (skip). A non-empty frame is laid out exactly like a memory `uint256[]` (length word first).
 *      The array is allocated for the all-frames-full case and its length word cut back to the words written.
 * @custom:security-contact security@mysun.example
 */
contract DepositSplit is IDepositSplit {
    using Math for uint256;

    /// @inheritdoc IDepositSplit
    function split(address[] calldata registry, uint256[] calldata required)
        external
        view
        returns (uint256[] memory flat)
    {
        if (required.length != registry.length) {
            revert DepositSplit__LengthMismatch();
        }
        IPositionAdapter[] memory adapters = IDepositSplitVault(msg.sender).adapters();
        uint256 len = adapters.length;
        address[][] memory tokensOf = new address[][](len);
        uint256[][] memory amountsOf = new uint256[][](len);
        uint256 words;
        for (uint256 i; i < len; ++i) {
            (tokensOf[i], amountsOf[i]) = adapters[i].position();
            words += tokensOf[i].length + 1;
        }
        uint256[] memory denom = _denominators(registry, tokensOf, amountsOf);

        flat = new uint256[](words);
        uint256 k;
        for (uint256 i; i < len; ++i) {
            address[] memory t = tokensOf[i];
            uint256[] memory a = amountsOf[i];
            if (!_scale(registry, required, denom, t, a)) {
                ++k; // all-zero adapter: the single skip word (already 0)
                continue;
            }
            uint256 n = t.length;
            flat[k++] = n;
            for (uint256 j; j < n; ++j) {
                flat[k++] = a[j];
            }
        }
        // k <= words: shrinking the length word only releases the unused tail of the allocation.
        assembly ("memory-safe") {
            mstore(flat, k)
        }
    }

    /// @dev D_r = Σ over adapters of the reported amount of registry token r (adapter tokens outside `registry` skip).
    function _denominators(address[] calldata registry, address[][] memory tokensOf, uint256[][] memory amountsOf)
        private
        pure
        returns (uint256[] memory denom)
    {
        uint256 m = registry.length;
        denom = new uint256[](m);
        uint256 len = tokensOf.length;
        for (uint256 i; i < len; ++i) {
            address[] memory t = tokensOf[i];
            uint256[] memory a = amountsOf[i];
            uint256 n = t.length;
            for (uint256 j; j < n; ++j) {
                uint256 r = _indexOf(registry, t[j]);
                if (r < m) {
                    denom[r] += a[j];
                }
            }
        }
    }

    /// @dev In place: a_j := floor(required_r * a_j / D_r), or 0 for a token outside `registry` / with D_r == 0
    ///      (a_j <= D_r, so the result is <= required_r; `mulDiv` keeps the product overflow-free). Returns whether
    ///      any scaled amount is non-zero.
    function _scale(
        address[] calldata registry,
        uint256[] calldata required,
        uint256[] memory denom,
        address[] memory t,
        uint256[] memory a
    ) private pure returns (bool any) {
        uint256 n = t.length;
        for (uint256 j; j < n; ++j) {
            uint256 r = _indexOf(registry, t[j]);
            uint256 v;
            if (r < registry.length && denom[r] != 0) {
                v = required[r].mulDiv(a[j], denom[r]);
            }
            a[j] = v;
            if (v != 0) {
                any = true;
            }
        }
    }

    /// @dev Index of `token` in `registry`, or `registry.length` if absent.
    function _indexOf(address[] calldata registry, address token) private pure returns (uint256 i) {
        uint256 m = registry.length;
        for (; i < m; ++i) {
            if (registry[i] == token) {
                return i;
            }
        }
    }
}
