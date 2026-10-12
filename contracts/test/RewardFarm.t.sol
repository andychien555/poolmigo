// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {RewardFarm} from "contracts/rewards/RewardFarm.sol";
import {MockToken} from "test/mocks/MockToken.sol";
import {MockBehaviorToken} from "test/mocks/MockBehaviorToken.sol";

/// @notice Reward token that misbehaves on demand: reverts transfers TO blocked addresses (a blacklisting token),
///         reverts any zero-value transfer (proves the farm never sends one), and can re-enter the farm from inside a
///         transfer (proves the guard).
contract HostileToken is ERC20 {
    mapping(address => bool) public blocked;
    bool public revertOnZero;
    RewardFarm public reenterFarm;
    uint16 public reenterPool;

    constructor() ERC20("Hostile", "HOST") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBlocked(address who, bool b) external {
        blocked[who] = b;
    }

    function setRevertOnZero(bool b) external {
        revertOnZero = b;
    }

    function setReenter(RewardFarm farm, uint16 poolId) external {
        reenterFarm = farm;
        reenterPool = poolId;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!blocked[to], "HostileToken: blocked");
        require(!(revertOnZero && value == 0), "HostileToken: zero transfer");
        super._update(from, to, value);
        if (address(reenterFarm) != address(0) && from == address(reenterFarm)) {
            reenterFarm.claim(reenterPool);
        }
    }
}

/**
 * @notice {RewardFarm} unit + fuzz coverage (`TASK_REWARDFARM.md` → Tests): pool / reward revert matrices, fund math
 *         and rollover, clamp at periodFinish, zero-supply window, 2 users × 2 pools × different reward tokens,
 *         `claimSelected` isolation vs a hostile token, paused = stake only, per-stream suppliers, a full 8-stream pool, recoverERC20 blocks, exact delivery,
 *         re-entry, precision at a large stake supply; fuzz: earned monotonicity, claims ≤ funded / solvency, rollover
 *         conservation. The multi-epoch time-warped scenario lives in `RewardFarmScenario.t.sol`.
 */
contract RewardFarmTest is Test {
    RewardFarm internal farm;
    MockToken internal stakeA; // e.g. sunEthLP
    MockToken internal stakeB; // e.g. sun5StocksLP
    MockToken internal r18; // 18-dp reward (e.g. SUN)
    MockToken internal r6; // 6-dp reward (e.g. USDG)
    MockToken internal r18b; // another 18-dp reward

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal supplier = makeAddr("supplier");
    address internal supplier2 = makeAddr("supplier2");

    uint16 internal p0;
    uint16 internal p1;

    function setUp() public {
        vm.warp(1_700_000_000);
        farm = new RewardFarm(owner);
        stakeA = new MockToken("sunEthLP", "sunEthLP", 18);
        stakeB = new MockToken("sun5StocksLP", "sun5StocksLP", 18);
        r18 = new MockToken("Sun", "SUN", 18);
        r6 = new MockToken("USDG", "USDG", 6);
        r18b = new MockToken("Other", "OTH", 18);
        vm.startPrank(owner);
        p0 = farm.createPool(stakeA);
        p1 = farm.createPool(stakeB);
        vm.stopPrank();
    }

    /* ------------------------------------------------------------------ */
    /*                               helpers                              */
    /* ------------------------------------------------------------------ */

    function _addReward(uint16 pid, IERC20 t) internal {
        vm.prank(owner);
        farm.addReward(pid, t);
    }

    function _fund(uint16 pid, MockToken t, uint256 amount, uint256 duration) internal {
        t.mint(owner, amount);
        vm.startPrank(owner);
        t.approve(address(farm), amount);
        farm.fund(pid, t, amount, duration);
        vm.stopPrank();
    }

    function _fundAs(address funder, uint16 pid, MockToken t, uint256 amount, uint256 duration) internal {
        t.mint(funder, amount);
        vm.startPrank(funder);
        t.approve(address(farm), amount);
        farm.fund(pid, t, amount, duration);
        vm.stopPrank();
    }

    function _setSupplier(uint16 pid, IERC20 t, address who) internal {
        vm.prank(owner);
        farm.setRewardSupplier(pid, t, who);
    }

    function _expectNotSupplier(address who, uint16 pid, MockToken t) internal {
        t.mint(who, 1e18);
        vm.startPrank(who);
        t.approve(address(farm), 1e18);
        vm.expectRevert(abi.encodeWithSelector(RewardFarm.RewardFarm__NotRewardSupplier.selector, pid, t, who));
        farm.fund(pid, t, 1e18, 100);
        vm.stopPrank();
    }

    /// @dev Registers 8 streams on `p0` (the cap): r18, r6, r18b, another pool's stake token (stakeB), + 4 fresh.
    function _addEightRewards() internal returns (MockToken[8] memory ts) {
        ts[0] = r18;
        ts[1] = r6;
        ts[2] = r18b;
        ts[3] = stakeB; // another pool's stake token is allowed
        for (uint256 i = 4; i < 8; ++i) {
            ts[i] = new MockToken("R", "R", 18);
        }
        vm.startPrank(owner);
        for (uint256 i; i < 8; ++i) {
            farm.addReward(p0, ts[i]);
        }
        vm.stopPrank();
    }

    function _stake(address user, uint16 pid, uint256 amount) internal {
        (IERC20 st,,) = farm.poolInfo(pid);
        MockToken(address(st)).mint(user, amount);
        vm.startPrank(user);
        st.approve(address(farm), amount);
        farm.stake(pid, amount);
        vm.stopPrank();
    }

    function _one(IERC20 t) internal pure returns (IERC20[] memory a) {
        a = new IERC20[](1);
        a[0] = t;
    }

    /* ------------------------------------------------------------------ */
    /*                       constructor / createPool                     */
    /* ------------------------------------------------------------------ */

    function test_constructor_owner() public {
        assertEq(farm.owner(), owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new RewardFarm(address(0));
    }

    function test_createPool_idsAndViews() public view {
        assertEq(farm.poolCount(), 2);
        assertEq(p0, 0);
        assertEq(p1, 1);
        assertEq(farm.poolIdOf(stakeA), 0);
        assertEq(farm.poolIdOf(stakeB), 1);
        (IERC20 st, uint256 tot, bool paused) = farm.poolInfo(p1);
        assertEq(address(st), address(stakeB));
        assertEq(tot, 0);
        assertFalse(paused);
        assertEq(farm.poolRewards(p0).length, 0);
    }

    function test_createPool_reverts() public {
        vm.startPrank(owner);
        vm.expectRevert(RewardFarm.RewardFarm__ZeroAddress.selector);
        farm.createPool(IERC20(address(0)));
        vm.expectRevert(abi.encodeWithSelector(RewardFarm.RewardFarm__StakeTokenAlreadyPooled.selector, stakeB, 1));
        farm.createPool(stakeB);
        vm.stopPrank();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        farm.createPool(r18);

        vm.expectRevert(abi.encodeWithSelector(RewardFarm.RewardFarm__UnknownStakeToken.selector, r18));
        farm.poolIdOf(r18);
    }

    function test_createPool_emits() public {
        vm.expectEmit(address(farm));
        emit RewardFarm.PoolCreated(2, r18);
        vm.prank(owner);
        farm.createPool(r18);
    }

    /* ------------------------------------------------------------------ */
    /*                              addReward                             */
    /* ------------------------------------------------------------------ */

    function test_addReward_revertMatrix() public {
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(RewardFarm.RewardFarm__UnknownPool.selector, 7));
        farm.addReward(7, r18);
        vm.expectRevert(RewardFarm.RewardFarm__ZeroAddress.selector);
        farm.addReward(p0, IERC20(address(0)));
        vm.expectRevert(abi.encodeWithSelector(RewardFarm.RewardFarm__RewardIsStakeToken.selector, p0, stakeA));
        farm.addReward(p0, stakeA);
        farm.addReward(p0, r18);
        vm.expectRevert(abi.encodeWithSelector(RewardFarm.RewardFarm__RewardAlreadyAdded.selector, p0, r18));
        farm.addReward(p0, r18);
        vm.stopPrank();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        farm.addReward(p0, r6);
    }

    function test_addReward_maxEight() public {
        assertEq(farm.MAX_REWARDS_PER_POOL(), 8);
        MockToken[8] memory ts = _addEightRewards();
        assertEq(farm.poolRewards(p0).length, farm.MAX_REWARDS_PER_POOL());
        MockToken extra = new MockToken("X", "X", 18);
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(RewardFarm.RewardFarm__TooManyRewards.selector, p0));
        farm.addReward(p0, extra);
        // the same reward token may serve several pools
        farm.addReward(p1, r18);
        vm.stopPrank();
        IERC20[] memory rs = farm.poolRewards(p0);
        for (uint256 i; i < 8; ++i) {
            assertEq(address(rs[i]), address(ts[i]));
        }
        assertEq(address(rs[3]), address(stakeB));
        assertEq(address(farm.poolRewards(p1)[0]), address(r18));
    }

    /// @notice A full pool (8 streams, all funded): stake / withdraw / claimSelected / claim / exit all work, withdraw
    ///         pays no reward, every stream pays out exactly, and a withdraw that checkpoints all 8 stays cheap (the
    ///         liveness rationale of the cap).
    function test_eightStreams_stakeWithdrawClaim() public {
        MockToken[8] memory ts = _addEightRewards();
        uint256 t0 = vm.getBlockTimestamp();
        _stake(alice, p0, 100e18);
        _stake(bob, p0, 300e18);
        for (uint256 i; i < 8; ++i) {
            _fund(p0, ts[i], (i + 1) * 1_000e6, 1_000);
        }

        vm.warp(t0 + 500);
        vm.prank(bob);
        uint256 g = gasleft();
        farm.withdraw(p0, 300e18);
        g -= gasleft();
        // worst case (every per-user slot of all 8 streams goes 0 → non-zero): ~716k gas measured
        assertLt(g, 1_000_000, "withdraw over 8 streams");
        for (uint256 i; i < 8; ++i) {
            if (ts[i] != stakeB) assertEq(ts[i].balanceOf(bob), 0); // no reward transfer on withdraw
        }

        vm.prank(alice);
        farm.claimSelected(p0, _one(ts[7]));
        assertEq(ts[7].balanceOf(alice), 8_000e6 / 8); // 1/4 of the first half (f / 2)

        vm.warp(t0 + 1_000);
        uint256[] memory all = farm.earnedAll(p0, alice);
        assertEq(all.length, 8);
        for (uint256 i; i < 8; ++i) {
            uint256 f = (i + 1) * 1_000e6;
            uint256 aliceTotal = f / 8 + f / 2; // 1/4 of the first half, all of the second
            assertEq(farm.earned(p0, ts[i], bob), 3 * f / 8); // 3/4 of the first half
            assertEq(all[i], i == 7 ? aliceTotal - f / 8 : aliceTotal);
        }

        vm.prank(alice);
        farm.claim(p0);
        vm.prank(bob);
        farm.exit(p0);
        vm.prank(alice);
        farm.exit(p0);
        for (uint256 i; i < 8; ++i) {
            uint256 f = (i + 1) * 1_000e6;
            assertEq(farm.earned(p0, ts[i], alice), 0);
            if (ts[i] != stakeB) {
                assertEq(ts[i].balanceOf(alice), f / 8 + f / 2);
                assertEq(ts[i].balanceOf(bob), 3 * f / 8);
                assertEq(ts[i].balanceOf(address(farm)), 0);
            }
        }
        // stakeB doubles as p0 reward: alice and bob got the full funded amount, the farm keeps nothing of it
        assertEq(stakeB.balanceOf(alice) + stakeB.balanceOf(bob), 4_000e6);
        assertEq(stakeB.balanceOf(address(farm)), 0);
        assertEq(stakeA.balanceOf(alice), 100e18);
        assertEq(stakeA.balanceOf(bob), 300e18);
        assertEq(farm.totalStaked(p0), 0);
    }

    /* ------------------------------------------------------------------ */
    /*                                 fund                               */
    /* ------------------------------------------------------------------ */

    function test_fund_revertMatrix() public {
        _addReward(p0, r18);
        r18.mint(owner, 1e30);
        vm.startPrank(owner);
        r18.approve(address(farm), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(RewardFarm.RewardFarm__UnknownPool.selector, 9));
        farm.fund(9, r18, 1e18, 100);
        vm.expectRevert(abi.encodeWithSelector(RewardFarm.RewardFarm__RewardNotRegistered.selector, p0, r6));
        farm.fund(p0, r6, 1e18, 100);
        vm.expectRevert(abi.encodeWithSelector(RewardFarm.RewardFarm__RewardNotRegistered.selector, p1, r18));
        farm.fund(p1, r18, 1e18, 100);
        vm.expectRevert(RewardFarm.RewardFarm__ZeroAmount.selector);
        farm.fund(p0, r18, 0, 100);
        vm.expectRevert(RewardFarm.RewardFarm__ZeroDuration.selector);
        farm.fund(p0, r18, 1e18, 0);
        vm.expectRevert(RewardFarm.RewardFarm__ZeroRewardRate.selector);
        farm.fund(p0, r18, 99, 100);
        uint256 max = farm.MAX_FUNDABLE();
        vm.expectRevert(abi.encodeWithSelector(RewardFarm.RewardFarm__FundTooLarge.selector, max + 1, max));
        farm.fund(p0, r18, max + 1, 100);
        vm.stopPrank();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RewardFarm.RewardFarm__NotRewardSupplier.selector, p0, r18, alice));
        farm.fund(p0, r18, 1e18, 100);
    }

    function test_fund_math() public {
        _addReward(p0, r18);
        uint256 amount = 7_000e18;
        uint256 duration = 7 days;
        uint256 t0 = vm.getBlockTimestamp();
        r18.mint(owner, amount);
        vm.startPrank(owner);
        r18.approve(address(farm), amount);
        vm.expectEmit(address(farm));
        emit RewardFarm.RewardFunded(p0, r18, amount, 0, duration, amount / duration, t0 + duration);
        farm.fund(p0, r18, amount, duration);
        vm.stopPrank();
        (uint256 rate, uint256 finish, uint256 last, uint256 rpt) = farm.rewardState(p0, r18);
        assertEq(rate, amount / duration);
        assertEq(finish, t0 + duration);
        assertEq(last, t0);
        assertEq(rpt, 0);
        assertEq(r18.balanceOf(address(farm)), amount);
        assertLe(rate * duration, amount); // never promises more than it holds
    }

    function test_fund_rolloverMidStream() public {
        _addReward(p0, r18);
        _stake(alice, p0, 100e18);
        uint256 t0 = vm.getBlockTimestamp();
        _fund(p0, r18, 1_000e18, 1_000); // 1e18 / s
        vm.warp(t0 + 400);
        _fund(p0, r18, 500e18, 1_000); // leftover 600e18 → (500 + 600) / 1000 = 1.1e18 / s
        (uint256 rate, uint256 finish, uint256 last,) = farm.rewardState(p0, r18);
        assertEq(rate, 1.1e18);
        assertEq(finish, t0 + 1_400);
        assertEq(last, t0 + 400);
        assertEq(farm.earned(p0, r18, alice), 400e18); // booked at the OLD rate
        vm.warp(t0 + 5_000);
        assertEq(farm.earned(p0, r18, alice), 1_500e18); // everything funded, exactly
    }

    function test_fund_afterPeriodEnd_noLeftover() public {
        _addReward(p0, r18);
        _stake(alice, p0, 1e18);
        _fund(p0, r18, 100e18, 100);
        vm.warp(vm.getBlockTimestamp() + 500);
        r18.mint(owner, 200e18);
        vm.startPrank(owner);
        r18.approve(address(farm), 200e18);
        vm.expectEmit(address(farm));
        emit RewardFarm.RewardFunded(p0, r18, 200e18, 0, 100, 2e18, vm.getBlockTimestamp() + 100);
        farm.fund(p0, r18, 200e18, 100);
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 100);
        assertEq(farm.earned(p0, r18, alice), 300e18);
    }

    function test_fund_rejectsFeeOnTransfer() public {
        MockBehaviorToken fot = new MockBehaviorToken("FoT", "FOT");
        fot.setBehavior(100, 0); // 1 % burnt on transfer
        _addReward(p0, fot);
        fot.mint(owner, 1_000e18);
        vm.startPrank(owner);
        fot.approve(address(farm), 1_000e18);
        vm.expectRevert(abi.encodeWithSelector(RewardFarm.RewardFarm__InexactDelivery.selector, fot, 1_000e18, 990e18));
        farm.fund(p0, fot, 1_000e18, 1_000);
        vm.stopPrank();
    }

    /* ------------------------------------------------------------------ */
    /*                       per-stream supplier                          */
    /* ------------------------------------------------------------------ */

    function test_setRewardSupplier_eventAndGetter() public {
        _addReward(p0, r18);
        assertEq(farm.rewardSupplier(p0, r18), address(0)); // default: owner-only
        vm.expectEmit(address(farm));
        emit RewardFarm.RewardSupplierSet(p0, r18, supplier);
        vm.prank(owner);
        farm.setRewardSupplier(p0, r18, supplier);
        assertEq(farm.rewardSupplier(p0, r18), supplier);
    }

    function test_supplier_fundsFromOwnBalance() public {
        _addReward(p0, r18);
        _addReward(p0, r6);
        _addReward(p1, r18);
        _setSupplier(p0, r18, supplier);
        _stake(alice, p0, 10e18);
        uint256 t0 = vm.getBlockTimestamp();

        r18.mint(supplier, 1_000e18);
        vm.startPrank(supplier);
        r18.approve(address(farm), 1_000e18);
        vm.expectEmit(address(farm));
        emit RewardFarm.RewardFunded(p0, r18, 1_000e18, 0, 1_000, 1e18, t0 + 1_000);
        farm.fund(p0, r18, 1_000e18, 1_000);
        vm.stopPrank();
        assertEq(r18.balanceOf(supplier), 0); // pulled from the supplier
        assertEq(r18.balanceOf(owner), 0);
        assertEq(r18.balanceOf(address(farm)), 1_000e18);

        // the supplier is scoped to its one stream: not another token of the pool, not the same token on another pool
        _expectNotSupplier(supplier, p0, r6);
        _expectNotSupplier(supplier, p1, r18);
        // a random address cannot fund
        _expectNotSupplier(carol, p0, r18);

        // the owner still funds the supplied stream (rollover on top of the supplier's period)
        vm.warp(t0 + 500);
        _fund(p0, r18, 500e18, 1_000);
        vm.warp(t0 + 5_000);
        assertEq(farm.earned(p0, r18, alice), 1_500e18);
        vm.prank(alice);
        farm.claim(p0);
        assertEq(r18.balanceOf(alice), 1_500e18);
    }

    function test_supplier_rotationAndClear() public {
        _addReward(p0, r18);
        _setSupplier(p0, r18, supplier);
        _fundAs(supplier, p0, r18, 100e18, 100);

        // rotation: the old supplier loses the right, the new one gains it
        vm.expectEmit(address(farm));
        emit RewardFarm.RewardSupplierSet(p0, r18, supplier2);
        _setSupplier(p0, r18, supplier2);
        _expectNotSupplier(supplier, p0, r18);
        _fundAs(supplier2, p0, r18, 100e18, 100);

        // clearing to zero restores owner-only
        _setSupplier(p0, r18, address(0));
        assertEq(farm.rewardSupplier(p0, r18), address(0));
        _expectNotSupplier(supplier2, p0, r18);
        _expectNotSupplier(supplier, p0, r18);
        _fund(p0, r18, 100e18, 100);
        assertEq(r18.balanceOf(address(farm)), 300e18);
    }

    function test_setRewardSupplier_reverts() public {
        _addReward(p0, r18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        farm.setRewardSupplier(p0, r18, alice);
        // the supplier itself cannot re-designate
        _setSupplier(p0, r18, supplier);
        vm.prank(supplier);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, supplier));
        farm.setRewardSupplier(p0, r18, supplier2);

        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(RewardFarm.RewardFarm__UnknownPool.selector, 9));
        farm.setRewardSupplier(9, r18, supplier);
        vm.expectRevert(abi.encodeWithSelector(RewardFarm.RewardFarm__RewardNotRegistered.selector, p0, r6));
        farm.setRewardSupplier(p0, r6, supplier);
        vm.expectRevert(abi.encodeWithSelector(RewardFarm.RewardFarm__RewardNotRegistered.selector, p1, r18));
        farm.setRewardSupplier(p1, r18, supplier);
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(RewardFarm.RewardFarm__UnknownPool.selector, 9));
        farm.rewardSupplier(9, r18);
        vm.expectRevert(abi.encodeWithSelector(RewardFarm.RewardFarm__RewardNotRegistered.selector, p0, r6));
        farm.rewardSupplier(p0, r6);
    }

    /* ------------------------------------------------------------------ */
    /*                       emission semantics                           */
    /* ------------------------------------------------------------------ */

    function test_emission_clampsAtPeriodFinish() public {
        _addReward(p0, r18);
        _stake(alice, p0, 100e18);
        uint256 t0 = vm.getBlockTimestamp();
        _fund(p0, r18, 1_000e18, 1_000);
        vm.warp(t0 + 1_000);
        assertEq(farm.earned(p0, r18, alice), 1_000e18);
        uint256 rptAtEnd = farm.rewardPerToken(p0, r18);
        vm.warp(t0 + 100_000);
        assertEq(farm.earned(p0, r18, alice), 1_000e18);
        assertEq(farm.rewardPerToken(p0, r18), rptAtEnd);
        // a checkpoint after the end clamps lastUpdateTime at periodFinish
        _stake(bob, p0, 1e18);
        (,, uint256 last,) = farm.rewardState(p0, r18);
        assertEq(last, t0 + 1_000);
        assertEq(farm.earned(p0, r18, bob), 0);
        vm.prank(alice);
        farm.claim(p0);
        assertEq(r18.balanceOf(alice), 1_000e18);
        assertEq(r18.balanceOf(address(farm)), 0);
    }

    function test_zeroSupplyWindow_emitsNothing() public {
        _addReward(p0, r18);
        uint256 t0 = vm.getBlockTimestamp();
        _fund(p0, r18, 1_000e18, 1_000);
        vm.warp(t0 + 300); // nobody staked: 300e18 of emission is never distributed
        assertEq(farm.rewardPerToken(p0, r18), 0);
        _stake(alice, p0, 50e18);
        (uint256 rate,,,) = farm.rewardState(p0, r18);
        assertEq(rate, 1e18); // rate math unchanged
        vm.warp(t0 + 2_000);
        assertEq(farm.earned(p0, r18, alice), 700e18);
        assertEq(r18.balanceOf(address(farm)), 1_000e18); // the 300e18 window stays in the farm, undistributed
    }

    function test_zeroSupplyWindow_midStream() public {
        _addReward(p0, r18);
        uint256 t0 = vm.getBlockTimestamp();
        _stake(alice, p0, 10e18);
        _fund(p0, r18, 1_000e18, 1_000);
        vm.warp(t0 + 200);
        vm.prank(alice);
        farm.withdraw(p0, 10e18); // supply → 0 for [200, 600)
        uint256 rptFrozen = farm.rewardPerToken(p0, r18);
        vm.warp(t0 + 600);
        assertEq(farm.rewardPerToken(p0, r18), rptFrozen);
        _stake(bob, p0, 10e18);
        vm.warp(t0 + 1_000);
        assertEq(farm.earned(p0, r18, alice), 200e18);
        assertEq(farm.earned(p0, r18, bob), 400e18);
    }

    function test_stakeBeforeFund_accruesFromFund() public {
        _addReward(p0, r18);
        _stake(alice, p0, 1e18);
        vm.warp(vm.getBlockTimestamp() + 10_000);
        assertEq(farm.earned(p0, r18, alice), 0);
        _fund(p0, r18, 100e18, 100);
        vm.warp(vm.getBlockTimestamp() + 50);
        assertEq(farm.earned(p0, r18, alice), 50e18);
    }

    function test_rewardAddedLater_existingStakerEarnsFromFundOnly() public {
        _addReward(p0, r18);
        _stake(alice, p0, 1e18);
        _fund(p0, r18, 100e18, 100);
        vm.warp(vm.getBlockTimestamp() + 50);
        _addReward(p0, r6);
        vm.warp(vm.getBlockTimestamp() + 20);
        assertEq(farm.earned(p0, r6, alice), 0);
        _fund(p0, r6, 1_000e6, 100);
        vm.warp(vm.getBlockTimestamp() + 100);
        assertEq(farm.earned(p0, r6, alice), 1_000e6);
        assertEq(farm.earned(p0, r18, alice), 100e18);
        uint256[] memory all = farm.earnedAll(p0, alice);
        assertEq(all.length, 2);
        assertEq(all[0], 100e18);
        assertEq(all[1], 1_000e6);
    }

    /* ------------------------------------------------------------------ */
    /*            2 users × 2 pools × different reward tokens             */
    /* ------------------------------------------------------------------ */

    function test_twoUsersTwoPoolsDifferentRewards() public {
        _addReward(p0, r18);
        _addReward(p0, r6);
        _addReward(p1, r6);
        _addReward(p1, r18b);

        uint256 t0 = vm.getBlockTimestamp();
        _stake(alice, p0, 100e18);
        _stake(bob, p0, 300e18);
        _stake(alice, p1, 50e18);
        _fund(p0, r18, 1_000e18, 1_000);
        _fund(p0, r6, 2_000e6, 1_000);
        _fund(p1, r6, 500e6, 1_000);
        _fund(p1, r18b, 100e18, 1_000);

        vm.warp(t0 + 500);
        vm.prank(bob);
        farm.withdraw(p0, 300e18); // no reward transfer on withdraw
        assertEq(r18.balanceOf(bob), 0);
        assertEq(r6.balanceOf(bob), 0);
        assertEq(stakeA.balanceOf(bob), 300e18);
        _stake(bob, p1, 150e18);

        vm.warp(t0 + 10_000);
        assertEq(farm.earned(p0, r18, alice), 625e18);
        assertEq(farm.earned(p0, r18, bob), 375e18);
        assertEq(farm.earned(p0, r6, alice), 1_250e6);
        assertEq(farm.earned(p0, r6, bob), 750e6);
        assertEq(farm.earned(p1, r6, alice), 312.5e6);
        assertEq(farm.earned(p1, r6, bob), 187.5e6);
        assertEq(farm.earned(p1, r18b, alice), 62.5e18);
        assertEq(farm.earned(p1, r18b, bob), 37.5e18);
        assertEq(farm.totalStaked(p0), 100e18);
        assertEq(farm.totalStaked(p1), 200e18);
        assertEq(farm.balanceOf(p1, bob), 150e18);

        // claims are per pool: claiming pool 0 does not touch pool 1's r6 stream
        vm.prank(alice);
        farm.claim(p0);
        assertEq(r18.balanceOf(alice), 625e18);
        assertEq(r6.balanceOf(alice), 1_250e6);
        assertEq(farm.earned(p1, r6, alice), 312.5e6);
        vm.prank(alice);
        farm.claim(p1);
        assertEq(r6.balanceOf(alice), 1_250e6 + 312.5e6);
        assertEq(r18b.balanceOf(alice), 62.5e18);

        vm.prank(bob);
        farm.claim(p0); // after a full withdraw, accrued rewards are still claimable
        vm.prank(bob);
        farm.exit(p1);
        assertEq(r18.balanceOf(bob), 375e18);
        assertEq(r6.balanceOf(bob), 750e6 + 187.5e6);
        assertEq(r18b.balanceOf(bob), 37.5e18);
        assertEq(stakeB.balanceOf(bob), 150e18);

        // everything funded is paid out exactly; only alice's stakes remain
        assertEq(r18.balanceOf(address(farm)), 0);
        assertEq(r6.balanceOf(address(farm)), 0);
        assertEq(r18b.balanceOf(address(farm)), 0);
        assertEq(stakeA.balanceOf(address(farm)), 100e18);
        assertEq(stakeB.balanceOf(address(farm)), 50e18);
    }

    /* ------------------------------------------------------------------ */
    /*                     stake / withdraw / claim / exit                */
    /* ------------------------------------------------------------------ */

    function test_stake_withdraw_reverts() public {
        vm.startPrank(alice);
        vm.expectRevert(RewardFarm.RewardFarm__ZeroAmount.selector);
        farm.stake(p0, 0);
        vm.expectRevert(abi.encodeWithSelector(RewardFarm.RewardFarm__UnknownPool.selector, 5));
        farm.stake(5, 1);
        vm.expectRevert(RewardFarm.RewardFarm__ZeroAmount.selector);
        farm.withdraw(p0, 0);
        vm.expectRevert(abi.encodeWithSelector(RewardFarm.RewardFarm__InsufficientBalance.selector, p0, alice, 1, 0));
        farm.withdraw(p0, 1);
        vm.expectRevert(abi.encodeWithSelector(RewardFarm.RewardFarm__UnknownPool.selector, 5));
        farm.claim(5);
        vm.expectRevert(abi.encodeWithSelector(RewardFarm.RewardFarm__UnknownPool.selector, 5));
        farm.exit(5);
        vm.stopPrank();
        _stake(alice, p0, 10e18);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(RewardFarm.RewardFarm__InsufficientBalance.selector, p0, alice, 11e18, 10e18)
        );
        farm.withdraw(p0, 11e18);
    }

    function test_stake_withdraw_events_and_balances() public {
        stakeA.mint(alice, 10e18);
        vm.startPrank(alice);
        stakeA.approve(address(farm), 10e18);
        vm.expectEmit(address(farm));
        emit RewardFarm.Staked(p0, alice, 10e18);
        farm.stake(p0, 10e18);
        vm.expectEmit(address(farm));
        emit RewardFarm.Withdrawn(p0, alice, 4e18);
        farm.withdraw(p0, 4e18);
        vm.stopPrank();
        assertEq(farm.balanceOf(p0, alice), 6e18);
        assertEq(farm.totalStaked(p0), 6e18);
        assertEq(stakeA.balanceOf(alice), 4e18);
        assertEq(stakeA.balanceOf(address(farm)), 6e18);
    }

    function test_stake_rejectsFeeOnTransfer() public {
        MockBehaviorToken fot = new MockBehaviorToken("FoT", "FOT");
        fot.setBehavior(0, 50); // rebase-up style excess delivery is rejected too
        vm.prank(owner);
        uint16 pid = farm.createPool(fot);
        fot.mint(alice, 100e18);
        vm.startPrank(alice);
        fot.approve(address(farm), 100e18);
        vm.expectRevert(abi.encodeWithSelector(RewardFarm.RewardFarm__InexactDelivery.selector, fot, 100e18, 100.5e18));
        farm.stake(pid, 100e18);
        vm.stopPrank();
    }

    function test_claim_paysAll_emits_andSkipsZero() public {
        HostileToken z = new HostileToken();
        z.setRevertOnZero(true); // any 0-value transfer would revert the claim
        _addReward(p0, r18);
        _addReward(p0, z); // registered, never funded → alice owes 0 of it
        _stake(alice, p0, 1e18);
        _fund(p0, r18, 100e18, 100);
        vm.warp(vm.getBlockTimestamp() + 100);
        vm.expectEmit(address(farm));
        emit RewardFarm.RewardPaid(p0, alice, r18, 100e18);
        vm.prank(alice);
        farm.claim(p0);
        assertEq(r18.balanceOf(alice), 100e18);
        assertEq(farm.earned(p0, r18, alice), 0);
        // nothing owed at all: still a clean no-op
        vm.prank(alice);
        farm.claim(p0);
        vm.prank(carol);
        farm.claim(p0);
        vm.prank(carol);
        farm.claimSelected(p0, _one(z));
    }

    function test_exit_withdrawsAllAndClaims() public {
        _addReward(p0, r18);
        _addReward(p0, r6);
        _stake(alice, p0, 40e18);
        _fund(p0, r18, 100e18, 100);
        _fund(p0, r6, 50e6, 100);
        vm.warp(vm.getBlockTimestamp() + 100);
        vm.prank(alice);
        farm.exit(p0);
        assertEq(stakeA.balanceOf(alice), 40e18);
        assertEq(r18.balanceOf(alice), 100e18);
        assertEq(r6.balanceOf(alice), 50e6);
        assertEq(farm.balanceOf(p0, alice), 0);
        assertEq(farm.totalStaked(p0), 0);
    }

    function test_exit_zeroBalance_justClaims() public {
        _addReward(p0, r18);
        _stake(alice, p0, 40e18);
        _fund(p0, r18, 100e18, 100);
        vm.warp(vm.getBlockTimestamp() + 100);
        vm.startPrank(alice);
        farm.withdraw(p0, 40e18);
        farm.exit(p0);
        vm.stopPrank();
        assertEq(r18.balanceOf(alice), 100e18);
    }

    /* ------------------------------------------------------------------ */
    /*                 claimSelected isolation (hostile token)            */
    /* ------------------------------------------------------------------ */

    function test_claimSelected_unregisteredReverts() public {
        _addReward(p0, r18);
        IERC20[] memory ts = new IERC20[](2);
        ts[0] = r18;
        ts[1] = r6;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RewardFarm.RewardFarm__RewardNotRegistered.selector, p0, r6));
        farm.claimSelected(p0, ts);
    }

    function test_claimSelected_isolatesHostileToken() public {
        HostileToken h = new HostileToken();
        _addReward(p0, r18);
        _addReward(p0, h);
        _stake(alice, p0, 1e18);
        _stake(bob, p0, 1e18);
        _fund(p0, r18, 100e18, 100);
        h.mint(owner, 100e18);
        vm.startPrank(owner);
        h.approve(address(farm), 100e18);
        farm.fund(p0, h, 100e18, 100);
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 100);

        h.setBlocked(alice, true); // the hostile token now refuses alice

        vm.startPrank(alice);
        vm.expectRevert("HostileToken: blocked");
        farm.claim(p0);
        vm.expectRevert("HostileToken: blocked");
        farm.exit(p0);
        IERC20[] memory both = new IERC20[](2);
        both[0] = r18;
        both[1] = h;
        vm.expectRevert("HostileToken: blocked");
        farm.claimSelected(p0, both);

        farm.claimSelected(p0, _one(r18)); // the good token still pays
        assertEq(r18.balanceOf(alice), 50e18);
        farm.withdraw(p0, 1e18); // principal is never trapped
        assertEq(stakeA.balanceOf(alice), 1e18);
        vm.stopPrank();
        assertEq(farm.earned(p0, h, alice), 50e18); // hostile accrual preserved

        vm.prank(bob);
        farm.claim(p0); // other users unaffected
        assertEq(r18.balanceOf(bob), 50e18);
        assertEq(h.balanceOf(bob), 50e18);

        h.setBlocked(alice, false);
        vm.prank(alice);
        farm.claimSelected(p0, _one(h));
        assertEq(h.balanceOf(alice), 50e18);
    }

    function test_claimSelected_duplicateEntryPaysOnce() public {
        _addReward(p0, r18);
        _stake(alice, p0, 1e18);
        _fund(p0, r18, 100e18, 100);
        vm.warp(vm.getBlockTimestamp() + 100);
        IERC20[] memory dup = new IERC20[](2);
        dup[0] = r18;
        dup[1] = r18;
        vm.prank(alice);
        farm.claimSelected(p0, dup);
        assertEq(r18.balanceOf(alice), 100e18);
    }

    function test_reentrancy_blocked() public {
        HostileToken h = new HostileToken();
        _addReward(p0, h);
        _stake(alice, p0, 1e18);
        h.mint(owner, 100e18);
        vm.startPrank(owner);
        h.approve(address(farm), 100e18);
        farm.fund(p0, h, 100e18, 100);
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 100);
        h.setReenter(farm, p0);
        vm.prank(alice);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        farm.claim(p0);
    }

    /* ------------------------------------------------------------------ */
    /*                                pause                               */
    /* ------------------------------------------------------------------ */

    function test_pause_blocksStakeOnly() public {
        _addReward(p0, r18);
        _stake(alice, p0, 10e18);
        _fund(p0, r18, 100e18, 100);
        vm.expectEmit(address(farm));
        emit RewardFarm.PoolPausedSet(p0, true);
        vm.prank(owner);
        farm.setPoolPaused(p0, true);
        (,, bool paused) = farm.poolInfo(p0);
        assertTrue(paused);

        stakeA.mint(bob, 1e18);
        vm.startPrank(bob);
        stakeA.approve(address(farm), 1e18);
        vm.expectRevert(abi.encodeWithSelector(RewardFarm.RewardFarm__PoolPaused.selector, p0));
        farm.stake(p0, 1e18);
        vm.stopPrank();

        _stake(bob, p1, 1e18); // other pools unaffected

        vm.warp(vm.getBlockTimestamp() + 50);
        _fund(p0, r18, 100e18, 100); // funding still works; streams keep running
        vm.startPrank(alice);
        farm.withdraw(p0, 5e18);
        farm.claim(p0);
        farm.claimSelected(p0, _one(r18));
        vm.warp(vm.getBlockTimestamp() + 1_000);
        farm.exit(p0);
        vm.stopPrank();
        assertEq(r18.balanceOf(alice), 200e18);
        assertEq(stakeA.balanceOf(alice), 10e18);

        vm.prank(owner);
        farm.setPoolPaused(p0, false);
        vm.prank(bob);
        farm.stake(p0, 1e18);
        assertEq(farm.balanceOf(p0, bob), 1e18);
    }

    function test_pause_onlyOwner_unknownPool() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        farm.setPoolPaused(p0, true);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(RewardFarm.RewardFarm__UnknownPool.selector, 3));
        farm.setPoolPaused(3, true);
    }

    /* ------------------------------------------------------------------ */
    /*                             recoverERC20                           */
    /* ------------------------------------------------------------------ */

    function test_recoverERC20_blocks() public {
        _addReward(p1, r6); // registered on a DIFFERENT pool: still blocked
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(RewardFarm.RewardFarm__RecoverBlocked.selector, stakeA));
        farm.recoverERC20(stakeA, owner, 0);
        vm.expectRevert(abi.encodeWithSelector(RewardFarm.RewardFarm__RecoverBlocked.selector, stakeB));
        farm.recoverERC20(stakeB, owner, 0);
        vm.expectRevert(abi.encodeWithSelector(RewardFarm.RewardFarm__RecoverBlocked.selector, r6));
        farm.recoverERC20(r6, owner, 0);
        vm.expectRevert(RewardFarm.RewardFarm__ZeroAddress.selector);
        farm.recoverERC20(r18, address(0), 0);
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        farm.recoverERC20(r18, alice, 0);
    }

    function test_recoverERC20_blocksFinishedStreamDust() public {
        _addReward(p0, r18);
        _fund(p0, r18, 1_000e18, 1_000);
        vm.warp(vm.getBlockTimestamp() + 2_000); // nobody staked: all of it is undistributable
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(RewardFarm.RewardFarm__RecoverBlocked.selector, r18));
        farm.recoverERC20(r18, owner, 1_000e18);
    }

    function test_recoverERC20_strayToken() public {
        r18b.mint(address(farm), 7e18);
        vm.expectEmit(address(farm));
        emit RewardFarm.Recovered(r18b, carol, 7e18);
        vm.prank(owner);
        farm.recoverERC20(r18b, carol, 7e18);
        assertEq(r18b.balanceOf(carol), 7e18);
    }

    /* ------------------------------------------------------------------ */
    /*                                views                               */
    /* ------------------------------------------------------------------ */

    function test_views_revertOnUnknown() public {
        vm.expectRevert(abi.encodeWithSelector(RewardFarm.RewardFarm__UnknownPool.selector, 2));
        farm.poolInfo(2);
        vm.expectRevert(abi.encodeWithSelector(RewardFarm.RewardFarm__UnknownPool.selector, 2));
        farm.poolRewards(2);
        vm.expectRevert(abi.encodeWithSelector(RewardFarm.RewardFarm__UnknownPool.selector, 2));
        farm.earnedAll(2, alice);
        vm.expectRevert(abi.encodeWithSelector(RewardFarm.RewardFarm__UnknownPool.selector, 2));
        farm.balanceOf(2, alice);
        vm.expectRevert(abi.encodeWithSelector(RewardFarm.RewardFarm__UnknownPool.selector, 2));
        farm.totalStaked(2);
        vm.expectRevert(abi.encodeWithSelector(RewardFarm.RewardFarm__RewardNotRegistered.selector, p0, r18));
        farm.rewardState(p0, r18);
        vm.expectRevert(abi.encodeWithSelector(RewardFarm.RewardFarm__RewardNotRegistered.selector, p0, r18));
        farm.earned(p0, r18, alice);
        vm.expectRevert(abi.encodeWithSelector(RewardFarm.RewardFarm__RewardNotRegistered.selector, p0, r18));
        farm.rewardPerToken(p0, r18);
        vm.expectRevert(abi.encodeWithSelector(RewardFarm.RewardFarm__RewardNotRegistered.selector, p0, r18));
        farm.rewardSupplier(p0, r18);
    }

    /* ------------------------------------------------------------------ */
    /*                              precision                             */
    /* ------------------------------------------------------------------ */

    /// @notice A 6-dp reward streamed to a 1e9-token (18-dp) stake supply, checkpointed EVERY second by a poker:
    ///         with PRECISION = 1e30 the per-update floor loss is sub-wei, so (almost) the whole emission reaches the
    ///         stakers. (At Synthetix's 1e18 each 1-s checkpoint here would floor 1e6 · 1e18 / 1e27 = 0 — everything lost.)
    function test_precision_largeSupplySmallDecimals() public {
        _addReward(p0, r6);
        _stake(alice, p0, 1e27);
        _fund(p0, r6, 100e6, 100); // 1 USDG / s
        for (uint256 i; i < 100; ++i) {
            vm.warp(vm.getBlockTimestamp() + 1);
            _stake(carol, p0, 1); // checkpoint
        }
        uint256 a = farm.earned(p0, r6, alice);
        assertApproxEqAbs(a, 100e6, 100);
        assertLe(a + farm.earned(p0, r6, carol), 100e6);
    }

    /* ------------------------------------------------------------------ */
    /*                                 fuzz                               */
    /* ------------------------------------------------------------------ */

    /// @notice `earned` never decreases while nobody claims — across warps, stakes, withdraws and re-funding.
    function testFuzz_earnedMonotonic(uint96 stakeAlice, uint96 stakeBob, uint128 amount, uint32 duration, uint256 seed)
        public
    {
        stakeAlice = uint96(bound(stakeAlice, 1, type(uint96).max));
        stakeBob = uint96(bound(stakeBob, 1, type(uint96).max));
        duration = uint32(bound(duration, 1, 365 days));
        amount = uint128(bound(amount, duration, type(uint128).max));
        _addReward(p0, r18);
        _stake(alice, p0, stakeAlice);
        _fund(p0, r18, amount, duration);
        uint256 lastA;
        uint256 lastB;
        for (uint256 i; i < 12; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            vm.warp(vm.getBlockTimestamp() + (r % (uint256(duration) / 3 + 2)));
            uint256 action = (r >> 64) % 4;
            if (action == 0) {
                _stake(bob, p0, stakeBob);
            } else if (action == 1 && farm.balanceOf(p0, bob) != 0) {
                uint256 w = farm.balanceOf(p0, bob) / 2 + 1;
                vm.prank(bob);
                farm.withdraw(p0, w);
            } else if (action == 2) {
                _fund(p0, r18, amount / 4 + duration, duration);
            }
            uint256 a = farm.earned(p0, r18, alice);
            uint256 b = farm.earned(p0, r18, bob);
            assertGe(a, lastA);
            assertGe(b, lastB);
            lastA = a;
            lastB = b;
        }
    }

    /// @notice Random multi-user activity on one pool with two reward streams: after EVERY step the farm holds at
    ///         least everything users could claim (solvency, no overpay); at the end every user exits and the sum of
    ///         claims never exceeds what was funded (paid + residual dust == funded, exactly).
    function testFuzz_claimsNeverExceedFunded(uint256 seed) public {
        _addReward(p0, r18);
        _addReward(p0, r6);
        address[3] memory users = [alice, bob, carol];
        uint256 funded18;
        uint256 funded6;
        for (uint256 i; i < 24; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            address u = users[r % 3];
            uint256 action = (r >> 8) % 6;
            uint256 x = r >> 16;
            if (action == 0) {
                _stake(u, p0, bound(x, 1, 1e30));
            } else if (action == 1) {
                uint256 bal = farm.balanceOf(p0, u);
                if (bal != 0) {
                    vm.prank(u);
                    farm.withdraw(p0, bound(x, 1, bal));
                }
            } else if (action == 2) {
                vm.prank(u);
                farm.claim(p0);
            } else if (action == 3) {
                uint256 d = bound(x, 1, 30 days);
                uint256 amt = bound(x >> 64, d, 1e36);
                _fund(p0, r18, amt, d);
                funded18 += amt;
            } else if (action == 4) {
                uint256 d = bound(x, 1, 30 days);
                uint256 amt = bound(x >> 64, d, 1e15);
                _fund(p0, r6, amt, d);
                funded6 += amt;
            } else {
                vm.prank(u);
                farm.claimSelected(p0, _one(r6));
            }
            vm.warp(vm.getBlockTimestamp() + bound(x >> 128, 0, 10 days));
            _assertSolvent(users);
        }
        for (uint256 k; k < 3; ++k) {
            vm.prank(users[k]);
            farm.exit(p0);
        }
        uint256 paid18 = r18.balanceOf(alice) + r18.balanceOf(bob) + r18.balanceOf(carol);
        uint256 paid6 = r6.balanceOf(alice) + r6.balanceOf(bob) + r6.balanceOf(carol);
        assertLe(paid18, funded18);
        assertLe(paid6, funded6);
        assertEq(paid18 + r18.balanceOf(address(farm)), funded18);
        assertEq(paid6 + r6.balanceOf(address(farm)), funded6);
        assertEq(farm.totalStaked(p0), 0);
        assertEq(stakeA.balanceOf(address(farm)), 0);
    }

    function _assertSolvent(address[3] memory users) internal view {
        uint256 owed18;
        uint256 owed6;
        for (uint256 k; k < 3; ++k) {
            owed18 += farm.earned(p0, r18, users[k]);
            owed6 += farm.earned(p0, r6, users[k]);
        }
        assertLe(owed18, r18.balanceOf(address(farm)));
        assertLe(owed6, r6.balanceOf(address(farm)));
    }

    /// @notice Rollover conservation: one staker present throughout two overlapping fundings receives everything
    ///         funded, minus at most the two rate floors (< d1 + d2 wei) — never more.
    function testFuzz_rolloverConservation(uint128 a1, uint128 a2, uint32 d1, uint32 d2, uint32 gap, uint96 st) public {
        d1 = uint32(bound(d1, 1, 365 days));
        d2 = uint32(bound(d2, 1, 365 days));
        a1 = uint128(bound(a1, d1, type(uint128).max));
        a2 = uint128(bound(a2, d2, type(uint128).max));
        gap = uint32(bound(gap, 0, uint256(d1) * 2));
        st = uint96(bound(st, 1, type(uint96).max));
        _addReward(p0, r18);
        _stake(alice, p0, st);
        _fund(p0, r18, a1, d1);
        vm.warp(vm.getBlockTimestamp() + gap);
        _fund(p0, r18, a2, d2);
        vm.warp(vm.getBlockTimestamp() + d2);
        uint256 e = farm.earned(p0, r18, alice);
        uint256 total = uint256(a1) + a2;
        assertLe(e, total);
        // floors: < d1 + d2 wei from the two rate divisions, ≤ 3 wei from accumulator / mulDiv floors
        assertGe(e + uint256(d1) + d2 + 3, total);
        vm.prank(alice);
        farm.claim(p0);
        assertEq(r18.balanceOf(alice), e);
    }
}
