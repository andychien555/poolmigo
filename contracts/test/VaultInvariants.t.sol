// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.34;

import {Test, Vm, console2} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {StdAssertions} from "forge-std/StdAssertions.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {MySunVaultUpgradeable} from "contracts/MySunVaultUpgradeable.sol";
import {IPoolmigoVault} from "contracts/interfaces/IPoolmigoVault.sol";
import {IPositionAdapter} from "contracts/interfaces/IPositionAdapter.sol";
import {MockToken} from "test/mocks/MockToken.sol";
import {MockPositionAdapter} from "test/mocks/MockPositionAdapter.sol";
import {VaultImplArgs} from "test/utils/VaultImplArgs.sol";

/**
 * @notice Fuzzed actor surface of the vault invariant suite. Every action is bounded / clamped so it never reverts
 *         (the suite runs `fail_on_revert = true`): an action whose precondition cannot hold (no shares, no adapter,
 *         paused for a keeper op) either returns early or — where the revert IS the property — asserts the exact
 *         revert through try/catch (pause matrix, genesis gate, supply cap, out-of-range fee). Per-op properties
 *         (S-3 round trip, S-4, S-5, S-8 per-op cut, S-9) are asserted here; a failed assertion reverts the action,
 *         which `fail_on_revert` reports as a broken invariant.
 *
 *         Every action runs under {observed}: the vault's `PerformanceFeeAccrued` events are folded into the S-8
 *         ghost, and the state-diff recording is scanned for any call the vault makes into an adapter that was
 *         already removed when the action began (S-6).
 */
contract VaultHandler is CommonBase, StdCheats, StdUtils, StdAssertions {
    uint256 internal constant BPS = 10_000;
    /// @dev Harness ceiling on supply: keeps every amount far below overflow without ever binding the vault's math.
    uint256 internal constant MAX_SUPPLY = 1e30;
    bytes32 internal constant FEE_SIG = keccak256("PerformanceFeeAccrued(address,address[],uint256[])");

    MySunVaultUpgradeable public immutable vault;
    address public immutable owner;
    address public immutable keeper;
    address public immutable riskManager;
    address public immutable treasury;
    address public immutable donor;
    address public immutable outsider;

    address[] internal _holders; // depositors first, owner last (the genesis holder)
    uint256 internal _nDepositors;
    MockPositionAdapter[] internal _adapters;
    MockToken[] internal _ledgerTokens; // every token that can ever be registered (basket + listing candidates)
    MockToken[] internal _listings; // not-yet-registered candidates for `addToken`
    uint256 public listed;

    /* ghosts */
    mapping(address token => uint256) public ghostIn; // deposits pulled + simulated fees + donations
    mapping(address token => uint256) public ghostRedeemed; // delivered to redeem receivers
    mapping(address token => uint256) public ghostFeeEvents; // Σ PerformanceFeeAccrued cuts
    mapping(address adapter => bool) public ghostRemoved;
    bool public ghostPaused;
    uint256 public ghostRemovedCalls;
    address internal _exempt; // the adapter `readdAdapter` is re-registering (its `addAdapter` probes are expected)

    /* coverage */
    mapping(string => uint256) public hits;
    uint256 public roundTripChecked;
    uint256 public roundTripSkipped;

    constructor(
        MySunVaultUpgradeable vault_,
        address owner_,
        address keeper_,
        address riskManager_,
        address treasury_,
        address donor_,
        address outsider_
    ) {
        vault = vault_;
        owner = owner_;
        keeper = keeper_;
        riskManager = riskManager_;
        treasury = treasury_;
        donor = donor_;
        outsider = outsider_;
    }

    /* -------------------------------- wiring -------------------------------- */

    function addLedgerToken(MockToken t, bool registered) external {
        _ledgerTokens.push(t);
        if (!registered) _listings.push(t);
    }

    function addAdapter(MockPositionAdapter a) external {
        _adapters.push(a);
    }

    /// @dev Call after every ledger token is known: approves the vault for each of them.
    function addHolder(address h, bool isDepositor) external {
        _holders.push(h);
        if (isDepositor) ++_nDepositors;
        vm.startPrank(h);
        for (uint256 i; i < _ledgerTokens.length; ++i) {
            _ledgerTokens[i].approve(address(vault), type(uint256).max);
        }
        vm.stopPrank();
    }

    function holders() external view returns (address[] memory) {
        return _holders;
    }

    function adapters() external view returns (MockPositionAdapter[] memory) {
        return _adapters;
    }

    function ledgerTokens() external view returns (MockToken[] memory) {
        return _ledgerTokens;
    }

    modifier observed() {
        bool[] memory removedBefore = new bool[](_adapters.length);
        for (uint256 i; i < _adapters.length; ++i) {
            removedBefore[i] = ghostRemoved[address(_adapters[i])];
        }
        vm.recordLogs();
        vm.startStateDiffRecording();
        _;
        _scanRemovedCalls(vm.stopAndReturnStateDiff(), removedBefore);
        _scanFeeEvents(vm.getRecordedLogs());
        _exempt = address(0);
    }

    /* ------------------------------- user ops ------------------------------- */

    /// @notice Depositor offers the whole registry (strict participation) sized to a target share count plus slack.
    ///         Paused → asserts the freeze; empty vault → the genesis gate (S-9).
    function deposit(uint256 actorSeed, uint256 receiverSeed, uint256 sharesSeed, uint256 slackSeed) external observed {
        address a = _depositor(actorSeed);
        if (vault.paused()) {
            _assertDepositFrozen(a);
            return;
        }
        if (vault.totalSupply() == 0) {
            _genesis(a, sharesSeed);
            return;
        }
        _depositNormal(a, _holder(receiverSeed), sharesSeed, slackSeed);
    }

    function redeem(uint256 actorSeed, uint256 receiverSeed, uint256 sharesSeed) external observed {
        address a = _holder(actorSeed);
        uint256 bal = vault.balanceOf(a);
        if (vault.paused()) {
            _assertRedeemFrozen(a, bal);
            return;
        }
        if (bal == 0) return;
        uint256 shares = sharesSeed % 5 == 0 ? bal : bound(sharesSeed, 1, bal);
        _redeemChecked(a, _holder(receiverSeed), shares);
    }

    /// @notice Deposit then immediately redeem (a slice of) the minted shares: delivered ≤ pulled per token (S-3 /
    ///         INV-2), asserted whenever the INV-2 precondition S ≥ T_i holds (always, by the harness's sizing —
    ///         `roundTripSkipped` counts the exceptions).
    function roundTrip(uint256 actorSeed, uint256 sharesSeed, uint256 slackSeed, uint256 sliceSeed) external observed {
        if (vault.paused() || vault.totalSupply() == 0) return;
        address a = _depositor(actorSeed);
        bool pre = _roundTripPrecondition();
        (bool minted, uint256 shares, uint256[] memory pulled) = _depositNormal(a, a, sharesSeed, slackSeed);
        if (!minted) return;
        uint256 slice = sliceSeed % 2 == 0 ? shares : bound(sliceSeed, 1, shares);
        uint256[] memory delivered = _redeemChecked(a, a, slice);
        if (!pre) {
            ++roundTripSkipped;
            return;
        }
        for (uint256 i; i < delivered.length; ++i) {
            assertLe(delivered[i], pulled[i], "S-3 round trip never gains");
        }
        ++roundTripChecked;
    }

    /// @notice Receipt transfers between holders (never paused-gated; shares stay among the actors).
    function transferShares(uint256 fromSeed, uint256 toSeed, uint256 amount) external observed {
        address from = _holder(fromSeed);
        uint256 bal = vault.balanceOf(from);
        if (bal == 0) return;
        vm.prank(from);
        vault.transfer(_holder(toSeed), bound(amount, 1, bal));
        ++hits["transferShares"];
    }

    /* ------------------------------ keeper ops ------------------------------ */

    function deployTo(uint256 adapterSeed, uint256 amountsSeed) external observed {
        MockPositionAdapter ad = _pickRegistered(adapterSeed);
        if (address(ad) == address(0)) return;
        (address[] memory t,) = ad.position();
        uint256[] memory amts = new uint256[](t.length);
        for (uint256 i; i < t.length; ++i) {
            amts[i] = bound(_h(amountsSeed, i), 0, IERC20(t[i]).balanceOf(address(vault)));
        }
        if (vault.paused()) {
            vm.prank(keeper);
            try vault.deployTo(IPositionAdapter(address(ad)), amts) {
                fail("S-5 deployTo while paused");
            } catch (bytes memory err) {
                _assertPausedErr(err);
            }
            return;
        }
        (, uint256[] memory before) = vault.totalTokens();
        vm.prank(keeper);
        vault.deployTo(IPositionAdapter(address(ad)), amts);
        (, uint256[] memory afterT) = vault.totalTokens();
        for (uint256 i; i < before.length; ++i) {
            assertEq(afterT[i], before[i], "INV-15 deployTo is value-neutral");
        }
        for (uint256 i; i < t.length; ++i) {
            assertEq(IERC20(t[i]).allowance(address(vault), address(ad)), 0, "INV-19 approval reset");
        }
        ++hits["deployTo"];
    }

    function pullFrom(uint256 adapterSeed, uint256 bps) external observed {
        MockPositionAdapter ad = _pickRegistered(adapterSeed);
        if (address(ad) == address(0)) return;
        bps = bound(bps, 1, BPS);
        if (vault.paused()) {
            vm.prank(keeper);
            try vault.pullFrom(IPositionAdapter(address(ad)), bps) {
                fail("S-5 pullFrom while paused");
            } catch (bytes memory err) {
                _assertPausedErr(err);
            }
            return;
        }
        uint256 feeBps = vault.performanceFeeBps();
        uint256 rfb = ad.reportedFeeBps();
        (address[] memory reg, uint256[] memory before) = vault.totalTokens();
        uint256[] memory trBefore = _balances(reg, treasury);
        vm.prank(keeper);
        (address[] memory t, uint256[] memory amts) = vault.pullFrom(IPositionAdapter(address(ad)), bps);
        (, uint256[] memory afterT) = vault.totalTokens();
        uint256[] memory cut = _deltas(reg, treasury, trBefore);
        for (uint256 i; i < t.length; ++i) {
            uint256 expected = Math.mulDiv(Math.mulDiv(amts[i], rfb, BPS), feeBps, BPS);
            assertEq(cut[_idx(reg, t[i])], expected, "S-8 pullFrom cut = bps of the reported fee slice");
        }
        for (uint256 i; i < reg.length; ++i) {
            assertEq(afterT[i], before[i] - cut[i], "INV-6 pullFrom moves value to idle minus the cut");
        }
        ++hits["pullFrom"];
    }

    function rebalance() external observed {
        if (vault.adapterCount() == 0) return;
        if (vault.paused()) {
            vm.prank(keeper);
            try vault.rebalance() {
                fail("S-5 rebalance while paused");
            } catch (bytes memory err) {
                _assertPausedErr(err);
            }
            return;
        }
        uint256 feeBps = vault.performanceFeeBps();
        address[] memory reg = vault.tokens();
        uint256[] memory trBefore = _balances(reg, treasury);
        vm.prank(keeper);
        (, uint256[] memory harvested, uint256[] memory fees) = vault.rebalance();
        uint256[] memory cut = _deltas(reg, treasury, trBefore);
        for (uint256 i; i < reg.length; ++i) {
            assertEq(fees[i], Math.mulDiv(harvested[i], feeBps, BPS), "S-8 rebalance cut = bps of harvest");
            assertLe(fees[i], Math.mulDiv(harvested[i], vault.MAX_PERFORMANCE_FEE_BPS(), BPS), "S-8 <= 30%");
            assertEq(cut[i], fees[i], "S-8 treasury receives exactly the cut");
        }
        ++hits["rebalance"];
    }

    /* ------------------------------ venue / world --------------------------- */

    /// @notice A position accrues trading fees (minted into the adapter as harvestable) — any adapter, registered or
    ///         not (a force-removed position keeps earning). ≤ 1% of the vault's total of that token per call.
    function accrueFees(uint256 adapterSeed, uint256 amountsSeed) external observed {
        MockPositionAdapter ad = _adapters[adapterSeed % _adapters.length];
        (address[] memory t,) = ad.position();
        uint256[] memory fees = new uint256[](t.length);
        for (uint256 i; i < t.length; ++i) {
            fees[i] = bound(_h(amountsSeed, i), 0, Math.max(1, _total(t[i]) / 100));
            ghostIn[t[i]] += fees[i];
        }
        ad.simulateFees(fees);
        ++hits["accrueFees"];
    }

    /// @notice An outsider donates a registered token to the vault (plain transfer) or into a position (`donate`).
    function donate(uint256 targetSeed, uint256 tokenSeed, uint256 amount) external observed {
        address[] memory reg = vault.tokens();
        address token = reg[tokenSeed % reg.length];
        amount = bound(amount, 1, Math.max(1, _total(token) / 100));
        MockToken(token).mint(donor, amount);
        ghostIn[token] += amount;
        MockPositionAdapter ad = _adapters[targetSeed % _adapters.length];
        (address[] memory t,) = ad.position();
        uint256 j = _idx(t, token);
        if (targetSeed % 2 == 0 || j == type(uint256).max) {
            vm.prank(donor);
            IERC20(token).transfer(address(vault), amount);
        } else {
            uint256[] memory v = new uint256[](t.length);
            v[j] = amount;
            vm.startPrank(donor);
            IERC20(token).approve(address(ad), amount);
            ad.donate(v);
            vm.stopPrank();
        }
        ++hits["donate"];
    }

    /* --------------------------------- admin --------------------------------- */

    function setPerformanceFeeBps(uint256 bps) external observed {
        uint16 cap = vault.MAX_PERFORMANCE_FEE_BPS();
        if (bps % 7 == 0) {
            uint16 bad = uint16(bound(bps, uint256(cap) + 1, type(uint16).max));
            vm.prank(owner);
            try vault.setPerformanceFeeBps(bad) {
                fail("S-8 fee above cap accepted");
            } catch (bytes memory err) {
                assertEq(bytes4(err), IPoolmigoVault.PoolmigoVault__FeeTooHigh.selector, "S-8 FeeTooHigh");
            }
        }
        vm.prank(owner);
        vault.setPerformanceFeeBps(uint16(bound(bps, 0, cap)));
        ++hits["setPerformanceFeeBps"];
    }

    /// @notice Uncap / cap at exactly supply (deposits refused) / cap with headroom / a rejected below-supply cap.
    function setMaxTotalSupply(uint256 seed) external observed {
        uint256 supply = vault.totalSupply();
        uint256 choice = seed % 4;
        uint256 newCap;
        if (choice == 1) {
            newCap = supply;
        } else if (choice == 2) {
            newCap = supply + bound(seed, 1, supply + vault.genesisShares());
        } else if (choice == 3 && supply > 1) {
            uint256 low = bound(seed, 1, supply - 1);
            uint256 prev = vault.maxTotalSupply();
            vm.prank(owner);
            try vault.setMaxTotalSupply(low) {
                fail("S-7 cap below supply accepted");
            } catch (bytes memory err) {
                assertEq(bytes4(err), IPoolmigoVault.PoolmigoVault__InvalidSupplyCap.selector, "S-7 InvalidSupplyCap");
            }
            assertEq(vault.maxTotalSupply(), prev);
            return;
        }
        vm.prank(owner);
        vault.setMaxTotalSupply(newCap);
        ++hits["setMaxTotalSupply"];
    }

    /// @notice pause() from the owner, a risk manager, or (rejected) an outsider. One-way and idempotent.
    function pause(uint256 callerSeed) external observed {
        uint256 c = callerSeed % 3;
        if (c == 2) {
            vm.prank(outsider);
            try vault.pause() {
                fail("S-5 outsider paused");
            } catch (bytes memory err) {
                assertEq(bytes4(err), IPoolmigoVault.PoolmigoVault__NotRiskManager.selector, "S-5 NotRiskManager");
            }
            return;
        }
        vm.prank(c == 0 ? owner : riskManager);
        vault.pause();
        assertTrue(vault.paused(), "S-5 pause sets the flag");
        ghostPaused = true;
        ++hits["pause"];
    }

    /// @notice A risk manager can never unpause; the owner can, and a deposit works right after (S-5 restore).
    function unpause(uint256 actorSeed, uint256 sharesSeed) external observed {
        bool was = vault.paused();
        vm.prank(riskManager);
        try vault.setPaused(false) {
            fail("S-5 risk manager unpaused");
        } catch (bytes memory err) {
            assertEq(
                err,
                abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, riskManager),
                "S-5 only owner unpauses"
            );
        }
        assertEq(vault.paused(), was, "S-5 flag untouched by the rejected unpause");
        vm.prank(owner);
        vault.setPaused(false);
        ghostPaused = false;
        if (was && vault.totalSupply() != 0) {
            // Restore: the next deposit mints (or is refused by the supply cap only — `_depositNormal` asserts that).
            _depositNormal(_depositor(actorSeed), _depositor(actorSeed), sharesSeed, sharesSeed);
            ++hits["unpauseRestore"];
        }
        ++hits["unpause"];
    }

    /// @notice Unwind every position into the vault and pause; owner, risk manager, or (rejected) an outsider.
    function emergencyUnwind(uint256 callerSeed) external observed {
        uint256 c = callerSeed % 3;
        if (c == 2) {
            vm.prank(outsider);
            try vault.emergencyUnwind() {
                fail("S-5 outsider unwound");
            } catch (bytes memory err) {
                assertEq(bytes4(err), IPoolmigoVault.PoolmigoVault__NotRiskManager.selector, "S-5 NotRiskManager");
            }
            return;
        }
        (address[] memory reg, uint256[] memory before) = vault.totalTokens();
        uint256[] memory feeSum = new uint256[](reg.length);
        MockPositionAdapter[] memory live = _registered();
        for (uint256 k; k < live.length; ++k) {
            (address[] memory t,) = live[k].position();
            for (uint256 i; i < t.length; ++i) {
                uint256 out = IERC20(t[i]).balanceOf(address(live[k]));
                feeSum[_idx(reg, t[i])] += Math.mulDiv(out, live[k].reportedFeeBps(), BPS);
            }
        }
        uint256 feeBps = vault.performanceFeeBps();
        uint256[] memory trBefore = _balances(reg, treasury);
        vm.prank(c == 0 ? owner : riskManager);
        vault.emergencyUnwind();
        ghostPaused = true;
        assertTrue(vault.paused(), "INV-25 unwind pauses");
        (, uint256[] memory afterT) = vault.totalTokens();
        uint256[] memory cut = _deltas(reg, treasury, trBefore);
        for (uint256 i; i < reg.length; ++i) {
            assertEq(cut[i], Math.mulDiv(feeSum[i], feeBps, BPS), "S-8 unwind cut = bps of the reported fees");
            assertEq(afterT[i], before[i] - cut[i], "INV-25 unwind returns everything to idle minus the cut");
        }
        for (uint256 k; k < live.length; ++k) {
            (address[] memory t,) = live[k].position();
            for (uint256 i; i < t.length; ++i) {
                assertEq(IERC20(t[i]).balanceOf(address(live[k])), 0, "INV-25 adapter emptied");
            }
        }
        ++hits["emergencyUnwind"];
    }

    /// @notice Orderly removal: drain (`pullFrom` 100%) if needed, then `removeAdapter` (needs an all-zero report).
    function retireAdapter(uint256 adapterSeed) external observed {
        MockPositionAdapter ad = _pickRegistered(adapterSeed);
        if (address(ad) == address(0)) return;
        if (!_empty(ad)) {
            if (vault.paused()) return; // keeper path frozen; covered by pullFrom's paused branch
            vm.prank(keeper);
            vault.pullFrom(IPositionAdapter(address(ad)), BPS);
        }
        vm.prank(owner);
        vault.removeAdapter(IPositionAdapter(address(ad)));
        ghostRemoved[address(ad)] = true;
        ++hits["retireAdapter"];
    }

    /// @notice K-9 recovery lever: drop an adapter without calling it; its holdings stay in it (leave totalTokens).
    function forceRemoveAdapter(uint256 adapterSeed) external observed {
        MockPositionAdapter ad = _pickRegistered(adapterSeed);
        if (address(ad) == address(0)) return;
        vm.prank(owner);
        vault.forceRemoveAdapter(IPositionAdapter(address(ad)));
        ghostRemoved[address(ad)] = true;
        ++hits["forceRemoveAdapter"];
    }

    /// @notice Re-register a removed adapter (its holdings, if any, count again).
    function readdAdapter(uint256 adapterSeed) external observed {
        MockPositionAdapter ad = _adapters[adapterSeed % _adapters.length];
        if (!ghostRemoved[address(ad)]) return;
        _exempt = address(ad);
        vm.prank(owner);
        vault.addAdapter(IPositionAdapter(address(ad)));
        ghostRemoved[address(ad)] = false;
        ++hits["readdAdapter"];
    }

    /// @notice List a new basket token (≤ MAX_TOKENS); re-listing an existing one is rejected.
    function addToken(uint256 seed) external observed {
        address[] memory reg = vault.tokens();
        vm.prank(owner);
        try vault.addToken(reg[seed % reg.length]) {
            fail("S-6 duplicate token accepted");
        } catch (bytes memory err) {
            assertEq(bytes4(err), IPoolmigoVault.PoolmigoVault__TokenAlreadyRegistered.selector, "S-6 duplicate");
        }
        if (listed == _listings.length || reg.length >= vault.MAX_TOKENS()) return;
        vm.prank(owner);
        vault.addToken(address(_listings[listed++]));
        ++hits["addToken"];
    }

    /// @notice Bank run: every holder redeems everything → supply 0 → genesis re-arms (S-9 on the next deposit).
    function drainAll() external observed {
        if (vault.paused() || vault.totalSupply() == 0) return;
        for (uint256 i; i < _holders.length; ++i) {
            uint256 bal = vault.balanceOf(_holders[i]);
            if (bal != 0) _redeemChecked(_holders[i], _holders[i], bal);
        }
        assertEq(vault.totalSupply(), 0, "drain: supply 0");
        (, uint256[] memory totals) = vault.totalTokens();
        for (uint256 i; i < totals.length; ++i) {
            assertEq(totals[i], 0, "INV-5 full-supply redemption drains everything reachable");
        }
        ++hits["drainAll"];
    }

    /* ------------------------------- internals ------------------------------- */

    function _depositNormal(address a, address r, uint256 sharesSeed, uint256 slackSeed)
        internal
        returns (bool minted, uint256 shares, uint256[] memory pulled)
    {
        if (vault.totalSupply() >= MAX_SUPPLY) return (false, 0, pulled);
        (address[] memory reg, uint256[] memory offers, uint256 target) = _sizeOffer(a, sharesSeed, slackSeed);
        if (vault.totalSupply() != 0 && _nothingReachable()) {
            // Supply > 0 but every reachable total is 0 — the whole basket sits in force-removed adapters (reachable
            // since deposit-deploy: a genesis re-arm routes the full seed into the sole dust holder, which the owner
            // may then force-remove). No token participates, so no share can be priced: preview and deposit both
            // refuse with exactly `ZeroShares` (any other outcome fails). Re-adding the adapter restores pricing.
            try vault.previewDeposit(reg, offers) {
                fail("unpriceable deposit previewed");
            } catch (bytes memory err) {
                assertEq(bytes4(err), IPoolmigoVault.PoolmigoVault__ZeroShares.selector, "unpriceable: ZeroShares");
            }
            vm.prank(a);
            try vault.deposit(reg, offers, target, r) {
                fail("unpriceable deposit minted");
            } catch (bytes memory err2) {
                assertEq(bytes4(err2), IPoolmigoVault.PoolmigoVault__ZeroShares.selector, "unpriceable: deposit");
            }
            ++hits["unpriceable"];
            return (false, 0, pulled);
        }

        uint256[] memory expReq;
        try vault.previewDeposit(reg, offers) returns (uint256 s_, uint256[] memory q_) {
            shares = s_;
            expReq = q_;
        } catch (bytes memory err) {
            assertEq(bytes4(err), IPoolmigoVault.PoolmigoVault__SupplyCapExceeded.selector, "S-7 only the cap refuses");
            vm.prank(a);
            try vault.deposit(reg, offers, target, r) {
                fail("S-7 deposit over the cap");
            } catch (bytes memory err2) {
                assertEq(
                    bytes4(err2), IPoolmigoVault.PoolmigoVault__SupplyCapExceeded.selector, "S-7 deposit = preview"
                );
            }
            ++hits["capRefused"];
            return (false, 0, pulled);
        }
        assertGe(shares, target, "offer sized for target");
        pulled = _executeDeposit(a, r, reg, offers, target, shares, expReq);
        minted = true;
    }

    /// @dev The deposit itself, checked against its preview (shares, pulls) and INV-1 (pull <= offer).
    function _executeDeposit(
        address a,
        address r,
        address[] memory reg,
        uint256[] memory offers,
        uint256 target,
        uint256 shares,
        uint256[] memory expReq
    ) internal returns (uint256[] memory pulled) {
        (, uint256[] memory totalsBefore) = vault.totalTokens();
        uint256 supplyBefore = vault.totalSupply();
        pulled = _balances(reg, a);
        uint256 rBefore = vault.balanceOf(r);
        vm.prank(a);
        assertEq(vault.deposit(reg, offers, target, r), shares, "deposit == previewDeposit (shares)");
        assertEq(vault.balanceOf(r) - rBefore, shares, "shares to receiver");
        for (uint256 i; i < reg.length; ++i) {
            pulled[i] -= IERC20(reg[i]).balanceOf(a);
            assertEq(pulled[i], expReq[i], "deposit == previewDeposit (pulls)");
            assertLe(pulled[i], offers[i], "INV-1 required <= offer");
            // Independent recomputation of INV-1's design rule (NOT the vault's own preview): the pull must
            // equal required_i = ceil(shares·(T_i + VA)/(S + VS)), VA = VS = 1 (mirroring the vault's private
            // constants), and 0 for non-participating tokens (T_i == 0) — rounding favors the vault.
            uint256 req = totalsBefore[i] == 0 || offers[i] == 0
                ? 0
                : Math.mulDiv(shares, totalsBefore[i] + 1, supplyBefore + 1, Math.Rounding.Ceil);
            assertEq(pulled[i], req, "INV-1 pull == independent ceil(required)");
            ghostIn[reg[i]] += pulled[i];
        }
        ++hits["deposit"];
    }

    /// @dev A target share count (often tiny — rounding stress — else up to 25% of supply, inside the cap headroom)
    ///      and the strict full-registry offer for it: required_i for `target` (T_i == 0 tokens offered 1, pull 0)
    ///      plus ≤ 12.5% slack per token, minted to `a`.
    function _sizeOffer(address a, uint256 sharesSeed, uint256 slackSeed)
        internal
        returns (address[] memory reg, uint256[] memory offers, uint256 target)
    {
        uint256 supply = vault.totalSupply();
        uint256[] memory totals;
        (reg, totals) = vault.totalTokens();
        uint256 hi = Math.min(supply / 4, MAX_SUPPLY - supply);
        uint256 cap = vault.maxTotalSupply();
        if (cap != 0) hi = Math.min(hi, cap > supply ? cap - supply : 0); // 0 → target 1 → the cap-refusal path
        hi = Math.max(hi, 1);
        target = sharesSeed % 4 == 0 ? bound(sharesSeed, 1, Math.min(hi, 1e9)) : bound(sharesSeed, 1, hi);
        offers = new uint256[](reg.length);
        for (uint256 i; i < reg.length; ++i) {
            uint256 base = totals[i] == 0 ? 1 : Math.mulDiv(target, totals[i] + 1, supply + 1, Math.Rounding.Ceil);
            offers[i] = base + _h(slackSeed, i) % (base / 8 + 1);
            MockToken(reg[i]).mint(a, offers[i]);
        }
    }

    /// @dev S-9: a non-owner is rejected; the owner's full-basket seed mints exactly K (unless the cap is below K).
    function _genesis(address a, uint256 seed) internal {
        address[] memory reg = vault.tokens();
        uint256 k = vault.genesisShares();
        uint256[] memory amts = new uint256[](reg.length);
        for (uint256 i; i < reg.length; ++i) {
            uint256 unit = 10 ** MockToken(reg[i]).decimals();
            amts[i] = bound(_h(seed, i), unit, unit * 10_000); // 1 … 10k whole tokens: T_i ≤ 1e22 ≪ K (INV-2 pre)
            MockToken(reg[i]).mint(a, amts[i]);
            MockToken(reg[i]).mint(owner, amts[i]);
        }
        vm.prank(a);
        try vault.deposit(reg, amts, k, a) {
            fail("S-9 non-owner genesis");
        } catch (bytes memory err) {
            assertEq(bytes4(err), IPoolmigoVault.PoolmigoVault__GenesisNotOwner.selector, "S-9 GenesisNotOwner");
        }
        uint256 cap = vault.maxTotalSupply();
        if (cap != 0 && cap < k) {
            vm.prank(owner);
            try vault.deposit(reg, amts, k, owner) {
                fail("S-7 genesis over the cap");
            } catch (bytes memory err) {
                assertEq(bytes4(err), IPoolmigoVault.PoolmigoVault__SupplyCapExceeded.selector, "S-7 genesis capped");
            }
            ++hits["genesisCapRefused"];
            return;
        }
        uint256[] memory before = _balances(reg, owner);
        vm.prank(owner);
        uint256 shares = vault.deposit(reg, amts, k, owner);
        assertEq(shares, k, "S-9 genesis mints exactly K");
        assertEq(vault.totalSupply(), k, "S-9 supply == K");
        for (uint256 i; i < reg.length; ++i) {
            assertEq(before[i] - IERC20(reg[i]).balanceOf(owner), amts[i], "S-9 genesis pulls in full");
            ghostIn[reg[i]] += amts[i];
        }
        ++hits["genesis"];
    }

    /// @dev S-4: delivered ≤ previewRedeem per token, and (linear mock venues) the gap is exactly the fee cut.
    function _redeemChecked(address a, address r, uint256 shares) internal returns (uint256[] memory delivered) {
        (address[] memory reg, uint256[] memory preview) = vault.previewRedeem(shares);
        uint256[] memory rBefore = _balances(reg, r);
        uint256[] memory trBefore = _balances(reg, treasury);
        vm.prank(a);
        (, uint256[] memory amounts) = vault.redeem(shares, r);
        delivered = _deltas(reg, r, rBefore);
        uint256[] memory cut = _deltas(reg, treasury, trBefore);
        for (uint256 i; i < reg.length; ++i) {
            assertEq(delivered[i], amounts[i], "redeem return == measured delivery");
            assertLe(delivered[i], preview[i], "S-4 redeem <= preview");
            assertEq(preview[i] - delivered[i], cut[i], "S-4 preview gap == the fee cut (linear venues)");
            ghostRedeemed[reg[i]] += delivered[i];
        }
        ++hits["redeem"];
    }

    function _assertDepositFrozen(address a) internal {
        address[] memory reg = vault.tokens();
        uint256[] memory ones = new uint256[](reg.length);
        for (uint256 i; i < reg.length; ++i) {
            ones[i] = 1;
        }
        vm.prank(a);
        try vault.deposit(reg, ones, 1, a) {
            fail("S-5 deposit while paused");
        } catch (bytes memory err) {
            _assertPausedErr(err);
        }
        ++hits["pausedDepositProbe"];
    }

    function _assertRedeemFrozen(address a, uint256 bal) internal {
        vm.prank(a);
        try vault.redeem(bal == 0 ? 1 : bal, a) {
            fail("S-5 redeem while paused");
        } catch (bytes memory err) {
            _assertPausedErr(err);
        }
        ++hits["pausedRedeemProbe"];
    }

    function _assertPausedErr(bytes memory err) internal {
        assertEq(bytes4(err), IPoolmigoVault.PoolmigoVault__Paused.selector, "S-5 paused = full freeze");
        ++hits["pausedProbe"];
    }

    /// @dev INV-2's precondition VS/VA ≤ S/T_i, i.e. T_i ≤ S raw (VS = VA = 1), for every registry token.
    function _roundTripPrecondition() internal view returns (bool) {
        uint256 supply = vault.totalSupply();
        (, uint256[] memory totals) = vault.totalTokens();
        for (uint256 i; i < totals.length; ++i) {
            if (totals[i] > supply) return false;
        }
        return true;
    }

    function _scanRemovedCalls(Vm.AccountAccess[] memory acc, bool[] memory removedBefore) internal {
        for (uint256 i; i < acc.length; ++i) {
            Vm.AccountAccess memory x = acc[i];
            if (x.accessor != address(vault) || x.account == _exempt) continue;
            if (
                x.kind != VmSafe.AccountAccessKind.Call && x.kind != VmSafe.AccountAccessKind.StaticCall
                    && x.kind != VmSafe.AccountAccessKind.DelegateCall && x.kind != VmSafe.AccountAccessKind.CallCode
            ) continue;
            for (uint256 j; j < removedBefore.length; ++j) {
                if (removedBefore[j] && x.account == address(_adapters[j])) ++ghostRemovedCalls;
            }
        }
    }

    function _scanFeeEvents(Vm.Log[] memory logs) internal {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(vault) || logs[i].topics[0] != FEE_SIG) continue;
            assertEq(address(uint160(uint256(logs[i].topics[1]))), treasury, "S-8 fee goes to the treasury");
            (address[] memory t, uint256[] memory f) = abi.decode(logs[i].data, (address[], uint256[]));
            for (uint256 j; j < t.length; ++j) {
                ghostFeeEvents[t[j]] += f[j];
            }
        }
    }

    function _registered() internal view returns (MockPositionAdapter[] memory live) {
        uint256 n;
        for (uint256 i; i < _adapters.length; ++i) {
            if (vault.isAdapter(address(_adapters[i]))) ++n;
        }
        live = new MockPositionAdapter[](n);
        n = 0;
        for (uint256 i; i < _adapters.length; ++i) {
            if (vault.isAdapter(address(_adapters[i]))) live[n++] = _adapters[i];
        }
    }

    function _pickRegistered(uint256 seed) internal view returns (MockPositionAdapter) {
        MockPositionAdapter[] memory live = _registered();
        return live.length == 0 ? MockPositionAdapter(address(0)) : live[seed % live.length];
    }

    /// @dev Every registry total (idle + registered positions) is 0.
    function _nothingReachable() internal view returns (bool) {
        (, uint256[] memory totals) = vault.totalTokens();
        for (uint256 i; i < totals.length; ++i) {
            if (totals[i] != 0) return false;
        }
        return true;
    }

    function _empty(MockPositionAdapter ad) internal view returns (bool) {
        (, uint256[] memory a) = ad.position();
        for (uint256 i; i < a.length; ++i) {
            if (a[i] != 0) return false;
        }
        return true;
    }

    function _total(address token) internal view returns (uint256) {
        (address[] memory reg, uint256[] memory totals) = vault.totalTokens();
        uint256 j = _idx(reg, token);
        return j == type(uint256).max ? 0 : totals[j];
    }

    function _balances(address[] memory t, address who) internal view returns (uint256[] memory b) {
        b = new uint256[](t.length);
        for (uint256 i; i < t.length; ++i) {
            b[i] = IERC20(t[i]).balanceOf(who);
        }
    }

    function _deltas(address[] memory t, address who, uint256[] memory before)
        internal
        view
        returns (uint256[] memory d)
    {
        d = new uint256[](t.length);
        for (uint256 i; i < t.length; ++i) {
            d[i] = IERC20(t[i]).balanceOf(who) - before[i];
        }
    }

    function _idx(address[] memory t, address token) internal pure returns (uint256) {
        for (uint256 i; i < t.length; ++i) {
            if (t[i] == token) return i;
        }
        return type(uint256).max;
    }

    function _h(uint256 seed, uint256 i) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, i)));
    }

    function _holder(uint256 seed) internal view returns (address) {
        return _holders[seed % _holders.length];
    }

    function _depositor(uint256 seed) internal view returns (address) {
        return _holders[seed % _nDepositors];
    }
}

/**
 * @notice Vault core stateful invariants (handler-based) against MOCK venues: the real {MySunVaultUpgradeable} behind an
 *         ERC1967 proxy (the FeeAtExit / ZapIn deployment pattern — no OZ-plugin validation, so no clean build is
 *         needed), a 3-token basket (USDG 6 dp, WETH 18 dp, SUN 18 dp) plus two listing candidates (WBTC 8 dp,
 *         XSTK 18 dp) for `addToken`, three {MockPositionAdapter}s over different token subsets (C reports 15% of
 *         every delivery as accrued fees), four depositors + owner (genesis holder) + keeper + risk manager +
 *         treasury + donor + outsider. Campaigns start live: genesis, three deposits, deploys into every venue,
 *         fees accrued.
 *
 *         S-1 (INV-5 / ERC-20) shares conservation: totalSupply == Σ holder balances.
 *         S-2 (INV-5) in-kind solvency of previews: per token Σ_holders previewRedeem_i(balance) ≤ totalTokens_i, with
 *             ZERO tolerance — every term floors (idle `⌊b·x/S⌋`, adapter `⌊pos·⌊b·1e18/S⌋/1e18⌋`, and
 *             Σ⌊b_k·1e18/S⌋ ≤ 1e18), so the sum of floors cannot exceed the total; previewRedeem(S) == totalTokens.
 *         S-3 (INV-2 / INV-3 / INV-6 / INV-15) global conservation per token: OUT ≤ IN, and exactly
 *             IN − OUT == vault idle + Σ adapter balances (removed adapters included), IN = deposits pulled +
 *             simulated fees + donations, OUT = redemptions delivered + treasury cuts (from the events). Per-op:
 *             `roundTrip` asserts delivered ≤ pulled.
 *         S-4 (INV-5) redeem ≤ preview — per-op in the handler; with linear mocks the gap is exactly the fee cut.
 *         S-5 (INV-20 / INV-36) pause matrix — per-op (deposit, redeem, deployTo, pullFrom, rebalance revert `Paused`
 *             while paused; outsiders cannot pause/unwind; a risk manager cannot unpause; the owner's unpause restores
 *             deposits); here: the vault's flag equals the handler's ghost (no path flips it unobserved).
 *         S-6 (INV-14) registry bounds/consistency: ≤ MAX_TOKENS tokens, ≤ MAX_ADAPTERS adapters, unique, every
 *             reported token registered, removed adapters unregistered with a zero mask and NEVER called by the vault.
 *         S-7 (INV-21) supply cap: maxTotalSupply == 0 || totalSupply ≤ maxTotalSupply.
 *         S-8 (INV-7 / INV-9) fee discipline: treasury balance == Σ PerformanceFeeAccrued cuts per token (so ≤);
 *             performanceFeeBps ≤ MAX_PERFORMANCE_FEE_BPS. Per-op: the exact cut on rebalance / pullFrom / redeem /
 *             emergencyUnwind (bps of the reported fees, never of principal).
 *         S-9 (INV-22) genesis re-arm: with supply 0 a non-owner preview reverts GenesisNotOwner and the owner's
 *             full-basket preview yields exactly K (or the cap refusal); per-op on the deposit after a drain.
 *         S-10 (INV-4) totalTokens == idle + Σ registered adapters' `position()`; mock reports == mock balances.
 *
 * forge-config: default.invariant.runs = 64
 * forge-config: default.invariant.depth = 128
 * forge-config: default.invariant.fail-on-revert = true
 */
contract VaultInvariantsTest is Test {
    uint16 internal constant FEE_BPS = 1500;
    uint256 internal constant GENESIS = 1_000_000e18;

    MySunVaultUpgradeable internal vault;
    VaultHandler internal handler;
    MockToken internal usdg;
    MockToken internal weth;
    MockToken internal sun;
    MockPositionAdapter internal venueA;
    MockPositionAdapter internal venueB;
    MockPositionAdapter internal venueC;

    address internal owner = makeAddr("owner");
    address internal keeper = makeAddr("keeper");
    address internal riskManager = makeAddr("riskManager");
    address internal treasury = makeAddr("treasury");
    address internal donor = makeAddr("donor");
    address internal outsider = makeAddr("outsider");

    function setUp() public {
        usdg = new MockToken("Mock USDG", "USDG", 6);
        weth = new MockToken("Mock WETH", "WETH", 18);
        sun = new MockToken("Mock SUN", "SUN", 18);
        MockToken wbtc = new MockToken("Mock WBTC", "WBTC", 8);
        MockToken xstk = new MockToken("Mock XSTK", "XSTK", 18);
        address[] memory basket = new address[](3);
        (basket[0], basket[1], basket[2]) = (address(usdg), address(weth), address(sun));

        MySunVaultUpgradeable impl = new MySunVaultUpgradeable(VaultImplArgs.depositSplit());
        vault = MySunVaultUpgradeable(
            address(
                new ERC1967Proxy(
                    address(impl),
                    abi.encodeCall(
                        MySunVaultUpgradeable(address(0)).initialize,
                        (owner, "sunEthLP", "sunEthLP", basket, treasury, FEE_BPS, GENESIS, uint256(0))
                    )
                )
            )
        );

        venueA =
            new MockPositionAdapter(_list(address(usdg), address(weth)), address(vault), "UNIV3", bytes32(uint256(1)));
        venueB = new MockPositionAdapter(basket, address(vault), "UNIV4", bytes32(uint256(2)));
        venueC =
            new MockPositionAdapter(_list(address(weth), address(sun)), address(vault), "UNIV3", bytes32(uint256(3)));
        venueC.setReportedFeeBps(1500); // 15% of every delivery reported as accrued fees

        vm.startPrank(owner);
        vault.addAdapter(IPositionAdapter(address(venueA)));
        vault.addAdapter(IPositionAdapter(address(venueB)));
        vault.addAdapter(IPositionAdapter(address(venueC)));
        vault.setKeeper(keeper, true);
        vault.setRiskManager(riskManager, true);
        vm.stopPrank();

        handler = new VaultHandler(vault, owner, keeper, riskManager, treasury, donor, outsider);
        handler.addLedgerToken(usdg, true);
        handler.addLedgerToken(weth, true);
        handler.addLedgerToken(sun, true);
        handler.addLedgerToken(wbtc, false);
        handler.addLedgerToken(xstk, false);
        handler.addAdapter(venueA);
        handler.addAdapter(venueB);
        handler.addAdapter(venueC);
        string[4] memory names = ["alice", "bob", "carol", "dave"];
        for (uint256 i; i < names.length; ++i) {
            handler.addHolder(makeAddr(names[i]), true);
        }
        handler.addHolder(owner, false);

        // Live campaign: genesis (via the handler's S-9 path), three deposits, every venue funded, fees accrued.
        handler.deposit(0, 0, 1, 0);
        assertEq(vault.totalSupply(), GENESIS);
        handler.deposit(0, 0, 1e23 + 1, 7);
        handler.deposit(1, 1, 3e22 + 1, 8);
        handler.deposit(2, 2, 5e21 + 1, 9);
        handler.deployTo(0, 1);
        handler.deployTo(1, 2);
        handler.deployTo(2, 3);
        handler.accrueFees(1, 4);
        handler.accrueFees(2, 5);
        _checkRemovedCallDetector();

        targetContract(address(handler));
        bytes4[] memory s = new bytes4[](32);
        s[0] = VaultHandler.deposit.selector;
        s[1] = VaultHandler.deposit.selector;
        s[2] = VaultHandler.deposit.selector;
        s[3] = VaultHandler.redeem.selector;
        s[4] = VaultHandler.redeem.selector;
        s[5] = VaultHandler.redeem.selector;
        s[6] = VaultHandler.roundTrip.selector;
        s[7] = VaultHandler.roundTrip.selector;
        s[8] = VaultHandler.transferShares.selector;
        s[9] = VaultHandler.deployTo.selector;
        s[10] = VaultHandler.deployTo.selector;
        s[11] = VaultHandler.pullFrom.selector;
        s[12] = VaultHandler.pullFrom.selector;
        s[13] = VaultHandler.rebalance.selector;
        s[14] = VaultHandler.accrueFees.selector;
        s[15] = VaultHandler.accrueFees.selector;
        s[16] = VaultHandler.donate.selector;
        s[17] = VaultHandler.setPerformanceFeeBps.selector;
        s[18] = VaultHandler.setMaxTotalSupply.selector;
        s[19] = VaultHandler.pause.selector;
        s[20] = VaultHandler.unpause.selector;
        s[21] = VaultHandler.unpause.selector;
        s[22] = VaultHandler.emergencyUnwind.selector;
        s[23] = VaultHandler.retireAdapter.selector;
        s[24] = VaultHandler.forceRemoveAdapter.selector;
        s[25] = VaultHandler.readdAdapter.selector;
        s[26] = VaultHandler.readdAdapter.selector;
        s[27] = VaultHandler.addToken.selector;
        s[28] = VaultHandler.drainAll.selector;
        s[29] = VaultHandler.donate.selector;
        s[30] = VaultHandler.roundTrip.selector;
        s[31] = VaultHandler.unpause.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: s}));
    }

    /// @notice S-1: every share is held by a handler actor.
    function invariant_S1_sharesConservation() public view {
        address[] memory hs = handler.holders();
        uint256 sum;
        for (uint256 i; i < hs.length; ++i) {
            sum += vault.balanceOf(hs[i]);
        }
        assertEq(vault.totalSupply(), sum, "S-1 totalSupply == sum of holder balances");
    }

    /// @notice S-2: the holders' previews never promise more than the vault holds (zero tolerance), and the whole
    ///         supply previews exactly the whole basket.
    function invariant_S2_previewSolvency() public view {
        (address[] memory reg, uint256[] memory totals) = vault.totalTokens();
        uint256[] memory sum = new uint256[](reg.length);
        address[] memory hs = handler.holders();
        for (uint256 h; h < hs.length; ++h) {
            (, uint256[] memory owed) = vault.previewRedeem(vault.balanceOf(hs[h]));
            for (uint256 i; i < reg.length; ++i) {
                sum[i] += owed[i];
            }
        }
        uint256 supply = vault.totalSupply();
        (, uint256[] memory all) = vault.previewRedeem(supply);
        for (uint256 i; i < reg.length; ++i) {
            assertLe(sum[i], totals[i], "S-2 sum of previews <= totalTokens");
            assertEq(all[i], supply == 0 ? 0 : totals[i], "S-2 previewRedeem(totalSupply) == totalTokens");
        }
    }

    /// @notice S-3: no free lunch, as an exact per-token ledger over everything that ever entered or left.
    function invariant_S3_globalConservation() public view {
        MockToken[] memory toks = handler.ledgerTokens();
        MockPositionAdapter[] memory ads = handler.adapters();
        for (uint256 k; k < toks.length; ++k) {
            address t = address(toks[k]);
            uint256 inflow = handler.ghostIn(t);
            uint256 outflow = handler.ghostRedeemed(t) + handler.ghostFeeEvents(t);
            assertLe(outflow, inflow, "S-3 cumulative out <= cumulative in");
            uint256 held = toks[k].balanceOf(address(vault));
            for (uint256 a; a < ads.length; ++a) {
                held += toks[k].balanceOf(address(ads[a]));
            }
            assertEq(inflow - outflow, held, "S-3 in - out == vault idle + adapter balances");
        }
    }

    /// @notice S-5: the pause flag only ever changes through the observed pause / unpause / unwind paths.
    function invariant_S5_pauseFlagTracked() public view {
        assertEq(vault.paused(), handler.ghostPaused(), "S-5 paused == ghost");
    }

    /// @notice S-6: registry bounds and consistency; removed adapters are unregistered, maskless and never called.
    function invariant_S6_registry() public view {
        address[] memory reg = vault.tokens();
        assertLe(reg.length, vault.MAX_TOKENS(), "S-6 <= MAX_TOKENS");
        for (uint256 i; i < reg.length; ++i) {
            assertTrue(vault.isToken(reg[i]), "S-6 isToken");
            for (uint256 j; j < i; ++j) {
                assertTrue(reg[i] != reg[j], "S-6 unique tokens");
            }
        }
        IPositionAdapter[] memory live = vault.adapters();
        assertLe(live.length, vault.MAX_ADAPTERS(), "S-6 <= MAX_ADAPTERS");
        assertEq(live.length, vault.adapterCount(), "S-6 adapterCount");
        for (uint256 i; i < live.length; ++i) {
            assertTrue(vault.isAdapter(address(live[i])), "S-6 isAdapter");
            for (uint256 j; j < i; ++j) {
                assertTrue(live[i] != live[j], "S-6 unique adapters");
            }
            (address[] memory t,) = live[i].position();
            for (uint256 j; j < t.length; ++j) {
                assertTrue(vault.isToken(t[j]), "S-6 reported token registered");
            }
        }
        MockPositionAdapter[] memory ads = handler.adapters();
        for (uint256 i; i < ads.length; ++i) {
            bool removed = handler.ghostRemoved(address(ads[i]));
            assertEq(vault.isAdapter(address(ads[i])), !removed, "S-6 isAdapter == !removed");
            if (removed) assertEq(vault.adapterCapabilities(IPositionAdapter(address(ads[i]))), 0, "S-6 mask cleared");
        }
        assertEq(handler.ghostRemovedCalls(), 0, "S-6 removed adapters are never called");
    }

    /// @notice S-7: the supply cap always holds.
    function invariant_S7_supplyCap() public view {
        uint256 cap = vault.maxTotalSupply();
        assertTrue(cap == 0 || vault.totalSupply() <= cap, "S-7 totalSupply <= cap");
    }

    /// @notice S-8: the treasury holds exactly the cuts the vault announced; the fee rate stays capped.
    function invariant_S8_feeDiscipline() public view {
        assertLe(vault.performanceFeeBps(), vault.MAX_PERFORMANCE_FEE_BPS(), "S-8 bps <= cap");
        assertEq(vault.treasury(), treasury);
        MockToken[] memory toks = handler.ledgerTokens();
        for (uint256 k; k < toks.length; ++k) {
            assertEq(toks[k].balanceOf(treasury), handler.ghostFeeEvents(address(toks[k])), "S-8 treasury == cuts");
        }
    }

    /// @notice S-9: whenever supply is 0, genesis is owner-only and mints exactly K.
    function invariant_S9_genesisReArmed() public {
        if (vault.totalSupply() != 0) return;
        address[] memory reg = vault.tokens();
        uint256[] memory ones = new uint256[](reg.length);
        for (uint256 i; i < reg.length; ++i) {
            ones[i] = 1;
        }
        vm.prank(outsider);
        try vault.previewDeposit(reg, ones) {
            fail("S-9 non-owner genesis preview");
        } catch (bytes memory err) {
            assertEq(bytes4(err), IPoolmigoVault.PoolmigoVault__GenesisNotOwner.selector, "S-9 GenesisNotOwner");
        }
        uint256 cap = vault.maxTotalSupply();
        vm.prank(owner);
        try vault.previewDeposit(reg, ones) returns (uint256 shares, uint256[] memory) {
            assertEq(shares, GENESIS, "S-9 genesis == K");
        } catch (bytes memory err) {
            assertTrue(cap != 0 && cap < GENESIS, "S-9 only a cap below K refuses");
            assertEq(bytes4(err), IPoolmigoVault.PoolmigoVault__SupplyCapExceeded.selector);
        }
    }

    /// @notice S-10: totalTokens is exactly idle + the registered positions (mock reports match mock balances).
    function invariant_S10_totalTokensComposition() public view {
        (address[] memory reg, uint256[] memory totals) = vault.totalTokens();
        uint256[] memory sum = new uint256[](reg.length);
        for (uint256 i; i < reg.length; ++i) {
            sum[i] = IERC20(reg[i]).balanceOf(address(vault));
        }
        IPositionAdapter[] memory live = vault.adapters();
        for (uint256 a; a < live.length; ++a) {
            (address[] memory t, uint256[] memory amt) = live[a].position();
            for (uint256 j; j < t.length; ++j) {
                assertEq(amt[j], IERC20(t[j]).balanceOf(address(live[a])), "mock report == mock balance");
                for (uint256 i; i < reg.length; ++i) {
                    if (reg[i] == t[j]) sum[i] += amt[j];
                }
            }
        }
        for (uint256 i; i < reg.length; ++i) {
            assertEq(totals[i], sum[i], "S-10 totalTokens == idle + positions");
        }
    }

    function afterInvariant() public view {
        string[26] memory keys = [
            "deposit",
            "genesis",
            "genesisCapRefused",
            "capRefused",
            "unpriceable",
            "redeem",
            "transferShares",
            "deployTo",
            "pullFrom",
            "rebalance",
            "accrueFees",
            "donate",
            "setPerformanceFeeBps",
            "setMaxTotalSupply",
            "pause",
            "unpause",
            "unpauseRestore",
            "emergencyUnwind",
            "retireAdapter",
            "forceRemoveAdapter",
            "readdAdapter",
            "addToken",
            "drainAll",
            "pausedProbe",
            "pausedDepositProbe",
            "pausedRedeemProbe"
        ];
        for (uint256 i; i < keys.length; ++i) {
            console2.log(keys[i], handler.hits(keys[i]));
        }
        console2.log("roundTripChecked", handler.roundTripChecked());
        console2.log("roundTripSkipped", handler.roundTripSkipped());
    }

    /* -------------------------------- helpers -------------------------------- */

    /// @dev Self-test of the S-6 call detector: a recorded vault keeper op must show the vault (proxy) as the accessor
    ///      of a call into the adapter — otherwise the detector would be blind and S-6's "never called" vacuous.
    function _checkRemovedCallDetector() internal {
        vm.startStateDiffRecording();
        vm.prank(keeper);
        vault.pullFrom(IPositionAdapter(address(venueA)), 1);
        Vm.AccountAccess[] memory acc = vm.stopAndReturnStateDiff();
        bool seen;
        for (uint256 i; i < acc.length; ++i) {
            if (acc[i].accessor == address(vault) && acc[i].account == address(venueA)) seen = true;
        }
        assertTrue(seen, "detector sees vault -> adapter calls");
    }

    function _list(address a, address b) internal pure returns (address[] memory t) {
        t = new address[](2);
        (t[0], t[1]) = (a, b);
    }
}
