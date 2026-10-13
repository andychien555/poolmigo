// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {RewardFarm} from "contracts/rewards/RewardFarm.sol";
import {MockToken} from "test/mocks/MockToken.sol";

/**
 * @notice {RewardFarm} time-warped multi-epoch scenario (`TASK_REWARDFARM.md` → Tests): two pools (sunEthLP,
 *         sun5StocksLP), three reward tokens of mixed decimals (SUN 18 dp shared by both pools, USDG 6 dp, WETH
 *         18 dp added mid-life), four stakers, four weekly epochs with exact-at-boundary refunds, a mid-stream
 *         rollover top-up, a zero-supply window, a pause, claims / claimSelected / exits / re-stakes in between.
 *
 *         Every step is mirrored by an INDEPENDENT reference model that distributes each stream's emission directly
 *         and pro-rata over the stakers of each constant-balance segment (no accumulator). After every step, every
 *         (user, pool, token) `earned` must match the model within a few wei (the two round differently), every payout
 *         must match it, and per token `paid + farm balance == funded`, with the farm residual equal to the model's
 *         undistributed (zero-supply) emissions plus rate-floor dust.
 */
contract RewardFarmScenarioTest is Test {
    uint256 internal constant WEEK = 7 days;
    uint256 internal constant DAY = 1 days;
    uint256 internal constant TOL = 64; // wei: per-segment floor differences between farm and model

    RewardFarm internal farm;
    MockToken internal sunEthLP;
    MockToken internal sun5StocksLP;
    MockToken internal sun; // 18 dp, streamed on BOTH pools
    MockToken internal usdg; // 6 dp
    MockToken internal weth; // 18 dp, added to pool 1 in epoch 1

    address internal owner = makeAddr("treasury");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");
    address[4] internal users;

    uint16 internal p0;
    uint16 internal p1;
    uint256 internal t0;

    /* ---------------------------- reference model ---------------------------- */

    struct MStream {
        uint256 rate;
        uint256 finish;
        uint256 last;
        bool exists;
    }

    mapping(bytes32 => MStream) internal mStream; // key(pid, token)
    mapping(bytes32 => mapping(address => uint256)) internal mOwed; // key(pid, token) → user → ideal owed
    mapping(uint16 => mapping(address => uint256)) internal mBal;
    mapping(uint16 => uint256) internal mSupply;
    mapping(IERC20 => uint256) internal funded;
    mapping(IERC20 => uint256) internal undistributed; // zero-supply windows
    mapping(IERC20 => uint256) internal rateDust; // Σ (amount + leftover − rate · duration)
    IERC20[] internal allTokens;

    function _key(uint16 pid, IERC20 t) internal pure returns (bytes32) {
        return keccak256(abi.encode(pid, t));
    }

    /// @dev Brings every model stream up to `now`: each segment's emission is split pro-rata over the stakers of the
    ///      (constant) balances of that segment; nobody staked → the segment's emission is undistributed.
    function _advance() internal {
        uint256 nowTs = vm.getBlockTimestamp();
        for (uint16 pid; pid < 2; ++pid) {
            IERC20[] memory ts = farm.poolRewards(pid);
            for (uint256 k; k < ts.length; ++k) {
                MStream storage s = mStream[_key(pid, ts[k])];
                uint256 end = Math.min(nowTs, s.finish);
                if (end <= s.last) continue;
                uint256 emitted = s.rate * (end - s.last);
                if (mSupply[pid] == 0) {
                    undistributed[ts[k]] += emitted;
                } else {
                    for (uint256 u; u < 4; ++u) {
                        uint256 b = mBal[pid][users[u]];
                        if (b != 0) mOwed[_key(pid, ts[k])][users[u]] += Math.mulDiv(emitted, b, mSupply[pid]);
                    }
                }
                s.last = end;
            }
        }
    }

    /* ------------------------------- actions -------------------------------- */

    function _addReward(uint16 pid, IERC20 t) internal {
        _advance();
        vm.prank(owner);
        farm.addReward(pid, t);
        mStream[_key(pid, t)].exists = true;
    }

    function _fund(uint16 pid, MockToken t, uint256 amount, uint256 duration) internal {
        _advance();
        uint256 nowTs = vm.getBlockTimestamp();
        MStream storage s = mStream[_key(pid, t)];
        uint256 leftover = s.finish > nowTs ? (s.finish - nowTs) * s.rate : 0;
        s.rate = (amount + leftover) / duration;
        s.finish = nowTs + duration;
        s.last = nowTs;
        rateDust[t] += amount + leftover - s.rate * duration;
        funded[t] += amount;

        t.mint(owner, amount);
        vm.startPrank(owner);
        t.approve(address(farm), amount);
        farm.fund(pid, t, amount, duration);
        vm.stopPrank();
        (uint256 rate, uint256 finish,,) = farm.rewardState(pid, t);
        assertEq(rate, s.rate, "fund: rate");
        assertEq(finish, s.finish, "fund: finish");
    }

    function _stake(address u, uint16 pid, uint256 amount) internal {
        _advance();
        mBal[pid][u] += amount;
        mSupply[pid] += amount;
        (IERC20 st,,) = farm.poolInfo(pid);
        MockToken(address(st)).mint(u, amount);
        vm.startPrank(u);
        st.approve(address(farm), amount);
        farm.stake(pid, amount);
        vm.stopPrank();
    }

    function _withdraw(address u, uint16 pid, uint256 amount) internal {
        _advance();
        mBal[pid][u] -= amount;
        mSupply[pid] -= amount;
        vm.prank(u);
        farm.withdraw(pid, amount);
    }

    /// @dev Claims the listed tokens (all = `farm.claim`) and checks each payout against the model.
    function _claim(address u, uint16 pid, IERC20[] memory ts, bool all, bool exitToo) internal {
        _advance();
        uint256[] memory before = new uint256[](ts.length);
        for (uint256 k; k < ts.length; ++k) {
            before[k] = ts[k].balanceOf(u);
        }
        if (exitToo) {
            uint256 b = mBal[pid][u];
            mBal[pid][u] = 0;
            mSupply[pid] -= b;
            vm.prank(u);
            farm.exit(pid);
        } else if (all) {
            vm.prank(u);
            farm.claim(pid);
        } else {
            vm.prank(u);
            farm.claimSelected(pid, ts);
        }
        for (uint256 k; k < ts.length; ++k) {
            uint256 got = ts[k].balanceOf(u) - before[k];
            assertApproxEqAbs(got, mOwed[_key(pid, ts[k])][u], TOL, "claim vs model");
            mOwed[_key(pid, ts[k])][u] = 0;
            assertEq(farm.earned(pid, ts[k], u), 0, "claimed stream not zeroed");
        }
    }

    function _claimAll(address u, uint16 pid) internal {
        _claim(u, pid, farm.poolRewards(pid), true, false);
    }

    function _exit(address u, uint16 pid) internal {
        _claim(u, pid, farm.poolRewards(pid), true, true);
    }

    function _warpTo(uint256 offset) internal {
        vm.warp(t0 + offset);
        _check();
    }

    /// @dev Full cross-check: every (user, pool, token) earned vs the model; stake accounting; per-token solvency.
    function _check() internal {
        _advance();
        for (uint16 pid; pid < 2; ++pid) {
            IERC20[] memory ts = farm.poolRewards(pid);
            assertEq(farm.totalStaked(pid), mSupply[pid], "supply");
            for (uint256 u; u < 4; ++u) {
                assertEq(farm.balanceOf(pid, users[u]), mBal[pid][users[u]], "balance");
                for (uint256 k; k < ts.length; ++k) {
                    assertApproxEqAbs(
                        farm.earned(pid, ts[k], users[u]), mOwed[_key(pid, ts[k])][users[u]], TOL, "earned vs model"
                    );
                }
            }
        }
        for (uint256 i; i < allTokens.length; ++i) {
            IERC20 t = allTokens[i];
            uint256 owed;
            for (uint16 pid; pid < 2; ++pid) {
                if (!mStream[_key(pid, t)].exists) continue;
                for (uint256 u; u < 4; ++u) {
                    owed += farm.earned(pid, t, users[u]);
                }
            }
            assertLe(owed, t.balanceOf(address(farm)), "insolvent");
        }
    }

    function _one(IERC20 t) internal pure returns (IERC20[] memory a) {
        a = new IERC20[](1);
        a[0] = t;
    }

    /* -------------------------------- setup --------------------------------- */

    function setUp() public {
        vm.warp(1_760_000_000);
        t0 = vm.getBlockTimestamp();
        users = [alice, bob, carol, dave];
        farm = new RewardFarm(owner);
        sunEthLP = new MockToken("MySun ETH LP", "sunEthLP", 18);
        sun5StocksLP = new MockToken("MySun 5 Stocks LP", "sun5StocksLP", 18);
        sun = new MockToken("Sun", "SUN", 18);
        usdg = new MockToken("Global Dollar", "USDG", 6);
        weth = new MockToken("Wrapped Ether", "WETH", 18);
        allTokens.push(sun);
        allTokens.push(usdg);
        allTokens.push(weth);
        vm.startPrank(owner);
        p0 = farm.createPool(sunEthLP);
        p1 = farm.createPool(sun5StocksLP);
        vm.stopPrank();
        _addReward(p0, sun);
        _addReward(p0, usdg);
        _addReward(p1, sun);
    }

    /* ------------------------------- scenario ------------------------------- */

    function test_scenario_fourWeeklyEpochs() public {
        // ---- epoch 0 ----
        _fund(p0, sun, 10_000e18, WEEK);
        _fund(p0, usdg, 5_000e6, WEEK);
        _fund(p1, sun, 4_000e18, WEEK); // pool 1 is empty for 2 days: that emission is never distributed
        _stake(alice, p0, 10_000e18);
        _warpTo(1 * DAY);
        _stake(bob, p0, 30_000e18);
        _warpTo(2 * DAY);
        _stake(carol, p1, 5_000e18);
        _warpTo(3 * DAY + 12 hours);
        _claimAll(alice, p0);
        _warpTo(5 * DAY);
        _withdraw(bob, p0, 15_000e18);
        _warpTo(6 * DAY + 3 hours);
        _stake(dave, p0, 2_500e18);

        // ---- epoch 1 (refunds exactly at the boundary: no leftover) ----
        _warpTo(WEEK);
        _fund(p0, sun, 12_000e18, WEEK);
        _fund(p0, usdg, 5_000e6, WEEK);
        _fund(p1, sun, 4_000e18, WEEK);
        _addReward(p1, weth);
        _fund(p1, weth, 3e18, WEEK);
        _warpTo(WEEK + 1 * DAY);
        _stake(dave, p1, 20_000e18);
        _warpTo(WEEK + 3 * DAY);
        _fund(p0, usdg, 2_500e6, WEEK); // mid-stream top-up: rollover to day 17
        _claim(carol, p1, _one(sun), false, false); // claimSelected
        _warpTo(WEEK + 5 * DAY);
        _exit(alice, p0);
        _warpTo(WEEK + 6 * DAY);
        _stake(alice, p0, 8_000e18);

        // ---- epoch 2 (pause pool 1 for a day; streams keep running) ----
        _warpTo(2 * WEEK);
        _fund(p0, sun, 12_000e18, WEEK);
        _fund(p1, sun, 5_000e18, WEEK);
        _fund(p1, weth, 3e18, WEEK);
        _warpTo(2 * WEEK + 1 * DAY);
        vm.prank(owner);
        farm.setPoolPaused(p1, true);
        sun5StocksLP.mint(bob, 1e18);
        vm.startPrank(bob);
        sun5StocksLP.approve(address(farm), 1e18);
        vm.expectRevert(abi.encodeWithSelector(RewardFarm.RewardFarm__PoolPaused.selector, p1));
        farm.stake(p1, 1e18);
        vm.stopPrank();
        _withdraw(carol, p1, 2_000e18); // withdraw works while paused
        _claim(dave, p1, farm.poolRewards(p1), false, false);
        _warpTo(2 * WEEK + 2 * DAY);
        vm.prank(owner);
        farm.setPoolPaused(p1, false);
        _stake(bob, p1, 7_000e18);
        _warpTo(2 * WEEK + 4 * DAY);
        _claimAll(bob, p0);
        _claimAll(carol, p1);

        // ---- epoch 3 (only pool 1 WETH refunded; pool 0 streams run out) ----
        _warpTo(3 * WEEK);
        _fund(p1, weth, 2e18, 10 * DAY);
        _warpTo(3 * WEEK + 2 * DAY);
        _withdraw(dave, p1, 20_000e18); // full withdraw, rewards still accrued
        _warpTo(3 * WEEK + 4 * DAY);
        _claimAll(dave, p1);

        // ---- wind-down: well past every periodFinish, everyone leaves ----
        _warpTo(6 * WEEK);
        uint256 frozen = farm.earned(p0, sun, bob);
        _warpTo(8 * WEEK);
        assertEq(farm.earned(p0, sun, bob), frozen, "accrual past periodFinish");
        for (uint256 u; u < 4; ++u) {
            _exit(users[u], p0);
            _exit(users[u], p1);
        }
        _check();

        // ---- conservation per token ----
        assertEq(farm.totalStaked(p0), 0);
        assertEq(farm.totalStaked(p1), 0);
        assertEq(sunEthLP.balanceOf(address(farm)), 0);
        assertEq(sun5StocksLP.balanceOf(address(farm)), 0);
        for (uint256 i; i < allTokens.length; ++i) {
            IERC20 t = allTokens[i];
            uint256 paid;
            for (uint256 u; u < 4; ++u) {
                paid += t.balanceOf(users[u]);
            }
            uint256 residual = t.balanceOf(address(farm));
            assertEq(paid + residual, funded[t], "paid + residual == funded");
            assertLe(paid, funded[t], "overpaid");
            // residual = zero-supply emissions + rate-floor dust + per-claim floors (never negative)
            assertGe(residual + TOL, undistributed[t] + rateDust[t], "residual low");
            assertLe(residual, undistributed[t] + rateDust[t] + TOL * 8, "residual high");
        }
        // pool 1's empty first two days really were undistributed
        assertApproxEqAbs(undistributed[sun], (4_000e18 / WEEK) * 2 * DAY, 0);
        assertEq(undistributed[usdg], 0);
    }
}
