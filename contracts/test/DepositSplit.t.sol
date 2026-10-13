// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {DepositSplit} from "contracts/periphery/DepositSplit.sol";
import {IDepositSplit} from "contracts/interfaces/IDepositSplit.sol";
import {IPositionAdapter} from "contracts/interfaces/IPositionAdapter.sol";

/// @dev Reports a settable `position()` — the only adapter call the splitter makes.
contract StaticReportAdapter {
    address[] internal _tokens;
    uint256[] internal _amounts;

    function set(address[] memory tokens_, uint256[] memory amounts_) external {
        _tokens = tokens_;
        _amounts = amounts_;
    }

    function position() external view returns (address[] memory, uint256[] memory) {
        return (_tokens, _amounts);
    }
}

/// @dev Stands in for the vault: exposes `adapters()` and calls the splitter itself (the splitter reads `msg.sender`).
contract SplitCallerHarness {
    DepositSplit public immutable SPLIT;
    IPositionAdapter[] internal _adapters;

    constructor(DepositSplit split_) {
        SPLIT = split_;
    }

    function push(address adapter) external {
        _adapters.push(IPositionAdapter(adapter));
    }

    function adapters() external view returns (IPositionAdapter[] memory) {
        return _adapters;
    }

    function split(address[] calldata registry, uint256[] calldata required) external view returns (uint256[] memory) {
        return SPLIT.split(registry, required);
    }
}

/**
 * @notice {DepositSplit} unit + fuzz suite: the proportional rule amount_ij = floor(required_r * a_ij / D_r), the frame
 *         layout `[n_i][amounts..]` / `[0]`, unregistered / unheld tokens, the length guard, and conservation
 *         (Σ per token <= required, dust < number of holders).
 */
contract DepositSplitTest is Test {
    DepositSplit internal splitter;
    SplitCallerHarness internal vault;

    address internal constant TA = address(0xA0);
    address internal constant TB = address(0xB0);
    address internal constant TC = address(0xC0);
    address internal constant TZ = address(0xF0); // never registered

    function setUp() public {
        splitter = new DepositSplit();
        vault = new SplitCallerHarness(splitter);
    }

    /*//////////////////////////////////////////////////////////////
                                  UNIT
    //////////////////////////////////////////////////////////////*/

    function test_LengthMismatch_Reverts() public {
        vm.expectRevert(IDepositSplit.DepositSplit__LengthMismatch.selector);
        vault.split(_addrs2(TA, TB), _u1(1));
        vm.expectRevert(IDepositSplit.DepositSplit__LengthMismatch.selector);
        vault.split(_addrs1(TA), new uint256[](0));
    }

    function test_NoAdapters_EmptyVector() public view {
        assertEq(vault.split(_addrs2(TA, TB), _u2(100, 200)).length, 0);
    }

    /// @dev Bootstrap: registered adapters that hold nothing → one skip word each (everything stays idle).
    function test_NoHolder_SkipWordPerAdapter() public {
        _adapter(_addrs2(TA, TB), _u2(0, 0));
        _adapter(_addrs1(TA), _u1(0));
        uint256[] memory flat = vault.split(_addrs2(TA, TB), _u2(100, 200));
        assertEq(flat.length, 2);
        assertEq(flat[0], 0);
        assertEq(flat[1], 0);
    }

    /// @dev A token outside `registry` reads 0 (it neither receives nor counts toward any denominator); an adapter whose
    ///      every amount is then 0 is a single skip word.
    function test_UnregisteredToken_ReadsZero() public {
        _adapter(_addrs1(TZ), _u1(1e18)); // only an unregistered token → skip
        _adapter(_addrs2(TA, TZ), _u2(50, 1e18)); // TA counts, TZ reads 0
        uint256[] memory flat = vault.split(_addrs1(TA), _u1(10));
        assertEq(flat.length, 1 + 3);
        assertEq(flat[0], 0, "skip word");
        assertEq(flat[1], 2, "frame length");
        assertEq(flat[2], 10, "sole TA holder takes all");
        assertEq(flat[3], 0, "unregistered token");
    }

    /// @dev A registered token with D_r == 0 gets 0 (no division), while another token of the same adapter splits.
    function test_UnheldRegistryToken_ZeroSlice() public {
        _adapter(_addrs2(TA, TB), _u2(7, 0));
        uint256[] memory flat = vault.split(_addrs2(TA, TB), _u2(10, 99));
        assertEq(flat.length, 3);
        assertEq(flat[0], 2);
        assertEq(flat[1], 10);
        assertEq(flat[2], 0, "TB: nobody holds it");
    }

    /// @dev Three adapters, three tokens, one partial holder and one skipped — exact numbers + floor dust.
    ///      Holdings: A1 [TA 300, TB 200], A2 [TB 100, TC 0] (TC unheld anywhere), A3 [TA 0] (skip), A4 [TA 100].
    ///      required [TA 1_001, TB 1_000, TC 5]: D = [400, 300, 0].
    ///        A1: TA ⌊1001·300/400⌋ = 750, TB ⌊1000·200/300⌋ = 666; A2: TB ⌊1000·100/300⌋ = 333, TC 0;
    ///        A4: TA ⌊1001·100/400⌋ = 250. Dust: TA 1, TB 1, TC 5 (nobody holds TC).
    function test_MultiAdapter_ExactFramesAndDust() public {
        _adapter(_addrs2(TA, TB), _u2(300, 200));
        _adapter(_addrs2(TB, TC), _u2(100, 0));
        _adapter(_addrs1(TA), _u1(0));
        _adapter(_addrs1(TA), _u1(100));
        address[] memory registry = new address[](3);
        (registry[0], registry[1], registry[2]) = (TA, TB, TC);
        uint256[] memory required = new uint256[](3);
        (required[0], required[1], required[2]) = (1_001, 1_000, 5);

        uint256[] memory flat = vault.split(registry, required);
        uint256[9] memory want = [uint256(2), 750, 666, 2, 333, 0, 0, 1, 250];
        assertEq(flat.length, 9);
        for (uint256 k; k < 9; ++k) {
            assertEq(flat[k], want[k]);
        }
        assertEq(required[0] - (750 + 250), 1, "TA dust");
        assertEq(required[1] - (666 + 333), 1, "TB dust");
    }

    /// @dev The registry order is the caller's (any order): the same holdings split identically under a permutation.
    function test_RegistryOrderIndependent() public {
        _adapter(_addrs2(TA, TB), _u2(3, 1));
        _adapter(_addrs2(TA, TB), _u2(1, 1));
        uint256[] memory f1 = vault.split(_addrs2(TA, TB), _u2(40, 9));
        uint256[] memory f2 = vault.split(_addrs2(TB, TA), _u2(9, 40));
        assertEq(f1, f2);
        assertEq(f1[1], 30);
        assertEq(f1[2], 4);
        assertEq(f1[4], 10);
        assertEq(f1[5], 4);
    }

    /// @dev mulDiv keeps the product overflow-free: required · a_ij > 2^256 still splits exactly.
    function test_HugeAmounts_NoOverflow() public {
        _adapter(_addrs1(TA), _u1(type(uint128).max));
        _adapter(_addrs1(TA), _u1(type(uint128).max));
        uint256[] memory flat = vault.split(_addrs1(TA), _u1(type(uint200).max));
        assertEq(flat[1], uint256(type(uint200).max) / 2);
        assertEq(flat[3], uint256(type(uint200).max) / 2);
    }

    /*//////////////////////////////////////////////////////////////
                                  FUZZ
    //////////////////////////////////////////////////////////////*/

    /// @dev Up to 5 adapters over 4 tokens (3 registered + TZ), random subsets and holdings, random `required`: frames
    ///      are well-formed, every amount is the formula, per registry token Σ <= required and the dust is < the number
    ///      of holding entries (each floor loses < 1); an unheld token gets nothing.
    function testFuzz_SplitMatchesFormulaAndConserves(
        uint8 nAdapters,
        uint8[5] memory masks,
        uint96[4][5] memory holdings,
        uint96[3] memory req
    ) public {
        uint256 len = bound(nAdapters, 0, 5);
        address[4] memory universe = [TA, TB, TC, TZ];
        address[] memory registry = new address[](3);
        (registry[0], registry[1], registry[2]) = (TA, TB, TC);
        uint256[] memory required = new uint256[](3);
        for (uint256 r; r < 3; ++r) {
            required[r] = req[r];
        }

        address[][] memory toks = new address[][](len);
        uint256[][] memory amts = new uint256[][](len);
        uint256[3] memory denom;
        uint256[3] memory holders;
        for (uint256 i; i < len; ++i) {
            uint256 m = masks[i] & 0xF;
            uint256 n;
            for (uint256 u; u < 4; ++u) {
                if (m & (1 << u) != 0) ++n;
            }
            toks[i] = new address[](n);
            amts[i] = new uint256[](n);
            uint256 j;
            for (uint256 u; u < 4; ++u) {
                if (m & (1 << u) == 0) continue;
                toks[i][j] = universe[u];
                amts[i][j] = holdings[i][u];
                if (u < 3) {
                    denom[u] += holdings[i][u];
                    if (holdings[i][u] != 0) ++holders[u];
                }
                ++j;
            }
            _adapter(toks[i], amts[i]);
        }

        uint256[] memory flat = vault.split(registry, required);
        uint256[3] memory sum;
        uint256 k;
        for (uint256 i; i < len; ++i) {
            uint256 n = toks[i].length;
            uint256[] memory want = new uint256[](n);
            bool any;
            for (uint256 j; j < n; ++j) {
                uint256 r = _indexOf(toks[i][j]);
                if (r < 3 && denom[r] != 0) {
                    want[j] = Math.mulDiv(required[r], amts[i][j], denom[r]);
                }
                if (want[j] != 0) any = true;
            }
            if (!any) {
                assertEq(flat[k++], 0, "skip word");
                continue;
            }
            assertEq(flat[k++], n, "frame length = adapter token count");
            for (uint256 j; j < n; ++j) {
                assertEq(flat[k++], want[j], "amount = floor(required * a / D)");
                uint256 r = _indexOf(toks[i][j]);
                if (r < 3) sum[r] += want[j];
            }
        }
        assertEq(flat.length, k, "no trailing words");
        for (uint256 r; r < 3; ++r) {
            assertLe(sum[r], required[r], "sum <= required");
            if (denom[r] == 0) {
                assertEq(sum[r], 0, "unheld token gets nothing");
            } else {
                assertLt(required[r] - sum[r], holders[r] == 0 ? 1 : holders[r], "dust < holders");
            }
        }
    }

    /// @dev Any length mismatch reverts with the typed error, before any adapter read.
    function testFuzz_LengthGuard(uint8 a, uint8 b) public {
        uint256 la = bound(a, 0, 8);
        uint256 lb = bound(b, 0, 8);
        vm.assume(la != lb);
        vm.expectRevert(IDepositSplit.DepositSplit__LengthMismatch.selector);
        vault.split(new address[](la), new uint256[](lb));
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    function _adapter(address[] memory tokens_, uint256[] memory amounts_) internal returns (StaticReportAdapter a) {
        a = new StaticReportAdapter();
        a.set(tokens_, amounts_);
        vault.push(address(a));
    }

    function _indexOf(address t) internal pure returns (uint256) {
        if (t == TA) return 0;
        if (t == TB) return 1;
        if (t == TC) return 2;
        return 3;
    }

    function _addrs1(address a) internal pure returns (address[] memory r) {
        r = new address[](1);
        r[0] = a;
    }

    function _addrs2(address a, address b) internal pure returns (address[] memory r) {
        r = new address[](2);
        (r[0], r[1]) = (a, b);
    }

    function _u1(uint256 a) internal pure returns (uint256[] memory r) {
        r = new uint256[](1);
        r[0] = a;
    }

    function _u2(uint256 a, uint256 b) internal pure returns (uint256[] memory r) {
        r = new uint256[](2);
        (r[0], r[1]) = (a, b);
    }
}
