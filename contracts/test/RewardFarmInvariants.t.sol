// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {RewardFarm} from "contracts/rewards/RewardFarm.sol";
import {MockToken} from "test/mocks/MockToken.sol";

/**
 * @notice Fuzzed actor surface of the invariant suite. Every action is bounded / clamped so it never reverts (the
 *         suite runs `fail_on_revert = true`): an action whose precondition cannot hold (nothing staked, staking
 *         paused, no supplier) returns early instead of calling the farm.
 */
contract RewardFarmHandler is CommonBase, StdCheats, StdUtils {
    uint256 internal constant MAX_FUND = 1e30; // per call; a whole campaign stays far below ~1e40 (MAX_FUNDABLE ≈ 1e47)
    uint256 internal constant MAX_STAKE = 1e27;
    uint256 internal constant MAX_DURATION = 60 days;

    RewardFarm public immutable farm;
    address public immutable owner;
    address public immutable supplierA;
    address public immutable supplierB;
    IERC20 public immutable supplierStream; // the (pool 1) stream whose supplier rotates
    address[] internal _actors;

    constructor(RewardFarm farm_, address owner_, address supplierA_, address supplierB_, IERC20 supplierStream_) {
        farm = farm_;
        owner = owner_;
        supplierA = supplierA_;
        supplierB = supplierB_;
        supplierStream = supplierStream_;
    }

    function addActor(address a) external {
        _actors.push(a);
    }

    function actors() external view returns (address[] memory) {
        return _actors;
    }

    /* ------------------------------- user ops ------------------------------- */

    function stake(uint256 actorSeed, uint256 poolSeed, uint256 amount) external {
        uint16 poolId = _poolId(poolSeed);
        (IERC20 stakeToken,, bool paused) = farm.poolInfo(poolId);
        if (paused) return; // the pause gate is the only stake precondition the fuzzer could hit
        address a = _actor(actorSeed);
        amount = bound(amount, 1, MAX_STAKE);
        MockToken(address(stakeToken)).mint(a, amount);
        vm.startPrank(a);
        stakeToken.approve(address(farm), amount);
        farm.stake(poolId, amount);
        vm.stopPrank();
    }

    function withdraw(uint256 actorSeed, uint256 poolSeed, uint256 amount) external {
        uint16 poolId = _poolId(poolSeed);
        address a = _actor(actorSeed);
        uint256 bal = farm.balanceOf(poolId, a);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        vm.prank(a);
        farm.withdraw(poolId, amount);
    }

    function claim(uint256 actorSeed, uint256 poolSeed) external {
        vm.prank(_actor(actorSeed));
        farm.claim(_poolId(poolSeed));
    }

    function claimSelected(uint256 actorSeed, uint256 poolSeed, uint256 subsetSeed) external {
        uint16 poolId = _poolId(poolSeed);
        IERC20[] memory regs = farm.poolRewards(poolId);
        uint256 maxN = regs.length < 3 ? regs.length : 3;
        IERC20[] memory picked = new IERC20[](subsetSeed % (maxN + 1)); // size 0..min(3, registered)
        for (uint256 i; i < picked.length; ++i) {
            picked[i] = regs[uint256(keccak256(abi.encode(subsetSeed, i))) % regs.length]; // duplicates allowed
        }
        vm.prank(_actor(actorSeed));
        farm.claimSelected(poolId, picked);
    }

    function exit(uint256 actorSeed, uint256 poolSeed) external {
        vm.prank(_actor(actorSeed));
        farm.exit(_poolId(poolSeed));
    }

    /* -------------------------------- funding -------------------------------- */

    function fundByOwner(uint256 poolSeed, uint256 tokenSeed, uint256 amount, uint256 duration) external {
        uint16 poolId = _poolId(poolSeed);
        IERC20[] memory regs = farm.poolRewards(poolId);
        _fund(owner, poolId, regs[tokenSeed % regs.length], amount, duration);
    }

    function fundBySupplier(uint256 amount, uint256 duration) external {
        address s = farm.rewardSupplier(1, supplierStream);
        if (s == address(0)) return; // cleared: owner-only until rotated back
        _fund(s, 1, supplierStream, amount, duration);
    }

    /// @dev Duration ≤ amount guarantees `rate = (amount + leftover) / duration ≥ 1`.
    function _fund(address funder, uint16 poolId, IERC20 token, uint256 amount, uint256 duration) internal {
        duration = bound(duration, 1, MAX_DURATION);
        amount = bound(amount, duration, MAX_FUND);
        MockToken(address(token)).mint(funder, amount);
        vm.startPrank(funder);
        token.approve(address(farm), amount);
        farm.fund(poolId, token, amount, duration);
        vm.stopPrank();
    }

    /* --------------------------------- admin --------------------------------- */

    function setRewardSupplier(uint256 choice) external {
        address[3] memory options = [supplierA, supplierB, address(0)]; // rotate / clear
        vm.prank(owner);
        farm.setRewardSupplier(1, supplierStream, options[choice % 3]);
    }

    function setPoolPaused(uint256 poolSeed, bool paused) external {
        vm.prank(owner);
        farm.setPoolPaused(_poolId(poolSeed), paused);
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 0, 30 days));
    }

    /* -------------------------------- helpers -------------------------------- */

    function _poolId(uint256 seed) internal pure returns (uint16) {
        return uint16(seed % 2);
    }

    function _actor(uint256 seed) internal view returns (address) {
        return _actors[seed % _actors.length];
    }
}

/**
 * @notice {RewardFarm} stateful invariants (handler-based). Two pools with different 18-dp stake tokens; pool 0 carries
 *         three streams (18 dp, 6 dp, and pool 1's stake token — cross-pool), pool 1 two (the shared 6-dp token and a
 *         partner token funded by a rotating supplier). Four actors; campaigns start live (one stream mid-period).
 *
 *         I-1 solvency: per token, farm balance ≥ Σ over its streams (Σ_actors earned + unemitted schedule) + the
 *             principal of any pool staking that token.
 *         I-2 stake solvency: per pool, the farm's stake-token balance ≥ totalStaked.
 *         I-3 totalStaked == Σ_actors balanceOf (every stake goes through an actor).
 *         I-4 per (pool, token, actor): userRewardPerTokenPaid ≤ rewardPerTokenStored (read from storage — no getter).
 *         I-5 caps / registration: ≤ MAX_REWARDS_PER_POOL streams per pool, poolCount == 2, and the registered set of
 *             each pool equals exactly the tokens `addReward`ed in setUp (no other token is registered).
 *
 * forge-config: default.invariant.runs = 256
 * forge-config: default.invariant.depth = 128
 * forge-config: default.invariant.fail-on-revert = true
 */
contract RewardFarmInvariantsTest is Test {
    /// @dev ERC-7201-less plain layout (`forge inspect RewardFarm storageLayout`): `_pools` at slot 2; `Pool` = 9 slots
    ///      (stakeToken+paused, totalStaked, rewardTokens, balances, isReward, suppliers, rewardData,
    ///      userRewardPerTokenPaid, rewards). Cross-checked against the public views in {_checkSlotMath}.
    uint256 internal constant POOLS_SLOT = 2;
    uint256 internal constant POOL_SIZE = 9;

    RewardFarm internal farm;
    RewardFarmHandler internal handler;
    MockToken internal stakeA;
    MockToken internal stakeB;
    MockToken internal r18;
    MockToken internal r6;
    MockToken internal rP; // partner token, pool 1, supplier-funded

    address internal owner = makeAddr("owner");
    address internal supplierA = makeAddr("supplierA");
    address internal supplierB = makeAddr("supplierB");
    address[] internal actors;

    IERC20[] internal tokens; // every token in play (stake + reward)
    mapping(uint16 => IERC20[]) internal expectedRewards;

    function setUp() public {
        vm.warp(1_700_000_000);
        farm = new RewardFarm(owner);
        stakeA = new MockToken("sunEthLP", "sunEthLP", 18);
        stakeB = new MockToken("sun5StocksLP", "sun5StocksLP", 18);
        r18 = new MockToken("Sun", "SUN", 18);
        r6 = new MockToken("USDG", "USDG", 6);
        rP = new MockToken("Partner", "PRT", 18);
        tokens.push(stakeA);
        tokens.push(stakeB);
        tokens.push(r18);
        tokens.push(r6);
        tokens.push(rP);

        expectedRewards[0].push(r18);
        expectedRewards[0].push(r6);
        expectedRewards[0].push(stakeB); // cross-pool: pool 1's stake token as a pool-0 reward
        expectedRewards[1].push(r6);
        expectedRewards[1].push(rP);

        vm.startPrank(owner);
        farm.createPool(stakeA);
        farm.createPool(stakeB);
        for (uint16 p; p < 2; ++p) {
            for (uint256 i; i < expectedRewards[p].length; ++i) {
                farm.addReward(p, expectedRewards[p][i]);
            }
        }
        farm.setRewardSupplier(1, rP, supplierA);
        vm.stopPrank();

        handler = new RewardFarmHandler(farm, owner, supplierA, supplierB, rP);
        string[4] memory names = ["alice", "bob", "carol", "dave"];
        for (uint256 i; i < names.length; ++i) {
            address a = makeAddr(names[i]);
            actors.push(a);
            handler.addActor(a);
        }

        // Live campaigns: stakers in both pools, every stream funded, then warp so all are mid-period.
        handler.stake(0, 0, 100e18);
        handler.stake(1, 0, 50e18);
        handler.stake(2, 1, 70e18);
        handler.fundByOwner(0, 0, 1_000_000e18, 14 days); // p0 r18
        handler.fundByOwner(0, 1, 50_000e6, 10 days); // p0 r6
        handler.fundByOwner(0, 2, 10_000e18, 7 days); // p0 stakeB
        handler.fundByOwner(1, 0, 20_000e6, 7 days); // p1 r6
        handler.fundBySupplier(500_000e18, 21 days); // p1 rP by supplierA
        handler.warp(3 days);
        handler.claim(0, 0);
        // A non-zero paid checkpoint proves the nested-mapping slot math behind I-4 (a wrong slot reads 0).
        (,,, uint256 stored) = farm.rewardState(0, r18);
        assertEq(_userRewardPerTokenPaid(0, r18, actors[0]), stored);
        assertGt(stored, 0);

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = RewardFarmHandler.stake.selector;
        selectors[1] = RewardFarmHandler.withdraw.selector;
        selectors[2] = RewardFarmHandler.claim.selector;
        selectors[3] = RewardFarmHandler.claimSelected.selector;
        selectors[4] = RewardFarmHandler.exit.selector;
        selectors[5] = RewardFarmHandler.fundByOwner.selector;
        selectors[6] = RewardFarmHandler.fundBySupplier.selector;
        selectors[7] = RewardFarmHandler.setRewardSupplier.selector;
        selectors[8] = RewardFarmHandler.setPoolPaused.selector;
        selectors[9] = RewardFarmHandler.warp.selector;
        selectors[10] = RewardFarmHandler.warp.selector; // double weight: time must pass for accrual to matter
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @notice I-1: per token, the farm can pay every actor's accrued reward plus every still-scheduled emission, on top
    ///         of any principal it holds in that token.
    function invariant_I1_rewardSolvency() public view {
        for (uint256 k; k < tokens.length; ++k) {
            IERC20 t = tokens[k];
            uint256 owed;
            for (uint16 p; p < 2; ++p) {
                (IERC20 stakeToken, uint256 staked,) = farm.poolInfo(p);
                if (address(stakeToken) == address(t)) owed += staked;
                if (!_registered(p, t)) continue;
                (uint256 rate, uint256 periodFinish,,) = farm.rewardState(p, t);
                if (periodFinish > block.timestamp) owed += (periodFinish - block.timestamp) * rate;
                for (uint256 i; i < actors.length; ++i) {
                    owed += farm.earned(p, t, actors[i]);
                }
            }
            assertGe(t.balanceOf(address(farm)), owed, "I-1 reward solvency");
        }
    }

    /// @notice I-2: per pool, the farm holds at least the staked principal in the stake token.
    function invariant_I2_stakeSolvency() public view {
        for (uint16 p; p < 2; ++p) {
            (IERC20 stakeToken, uint256 staked,) = farm.poolInfo(p);
            assertGe(stakeToken.balanceOf(address(farm)), staked, "I-2 stake solvency");
        }
    }

    /// @notice I-3: per pool, totalStaked equals the sum of the actors' balances.
    function invariant_I3_totalStakedIsSumOfBalances() public view {
        for (uint16 p; p < 2; ++p) {
            uint256 sum;
            for (uint256 i; i < actors.length; ++i) {
                sum += farm.balanceOf(p, actors[i]);
            }
            assertEq(farm.totalStaked(p), sum, "I-3 totalStaked == sum of balances");
        }
    }

    /// @notice I-4: no actor's paid checkpoint is ahead of its stream's stored accumulator.
    function invariant_I4_paidNotAheadOfStored() public view {
        _checkSlotMath();
        for (uint16 p; p < 2; ++p) {
            IERC20[] memory regs = farm.poolRewards(p);
            for (uint256 j; j < regs.length; ++j) {
                (,,, uint256 stored) = farm.rewardState(p, regs[j]);
                for (uint256 i; i < actors.length; ++i) {
                    assertLe(_userRewardPerTokenPaid(p, regs[j], actors[i]), stored, "I-4 paid <= stored");
                }
            }
        }
    }

    /// @notice I-5: stream cap, pool count, and the registered set equals exactly what setUp `addReward`ed.
    function invariant_I5_capsAndRegistration() public view {
        assertEq(farm.poolCount(), 2, "I-5 poolCount");
        for (uint16 p; p < 2; ++p) {
            IERC20[] memory regs = farm.poolRewards(p);
            assertLe(regs.length, farm.MAX_REWARDS_PER_POOL(), "I-5 cap");
            assertEq(regs.length, expectedRewards[p].length, "I-5 registered count");
            for (uint256 j; j < regs.length; ++j) {
                assertEq(address(regs[j]), address(expectedRewards[p][j]), "I-5 registered set");
            }
            for (uint256 k; k < tokens.length; ++k) {
                bool expected;
                for (uint256 j; j < expectedRewards[p].length; ++j) {
                    if (address(expectedRewards[p][j]) == address(tokens[k])) expected = true;
                }
                assertEq(_registered(p, tokens[k]), expected, "I-5 registered <=> addReward'd");
            }
        }
    }

    /* -------------------------------- helpers -------------------------------- */

    /// @dev Registration probe through the public surface: `rewardSupplier` reverts for an unregistered token.
    function _registered(uint16 p, IERC20 t) internal view returns (bool) {
        try farm.rewardSupplier(p, t) returns (address) {
            return true;
        } catch {
            return false;
        }
    }

    function _poolBase(uint16 p) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(POOLS_SLOT))) + uint256(p) * POOL_SIZE;
    }

    function _userRewardPerTokenPaid(uint16 p, IERC20 t, address user) internal view returns (uint256) {
        bytes32 inner = keccak256(abi.encode(t, _poolBase(p) + 7));
        return uint256(vm.load(address(farm), keccak256(abi.encode(user, inner))));
    }

    /// @dev Guards the hand-computed slots: `totalStaked` and every `rewardPerTokenStored` read via storage must match
    ///      the views, so a layout drift fails loudly instead of silently reading zeros.
    function _checkSlotMath() internal view {
        for (uint16 p; p < 2; ++p) {
            uint256 base = _poolBase(p);
            assertEq(uint256(vm.load(address(farm), bytes32(base + 1))), farm.totalStaked(p), "slot: totalStaked");
            IERC20[] memory regs = farm.poolRewards(p);
            for (uint256 j; j < regs.length; ++j) {
                uint256 rd = uint256(keccak256(abi.encode(regs[j], base + 6)));
                (,,, uint256 stored) = farm.rewardState(p, regs[j]);
                assertEq(uint256(vm.load(address(farm), bytes32(rd + 3))), stored, "slot: rewardPerTokenStored");
            }
        }
    }
}
