// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {RewardFarm} from "contracts/rewards/RewardFarm.sol";
import {MockToken} from "test/mocks/MockToken.sol";

/// @dev The hevm cheatcode subset Echidna supports; only `warp` is used.
interface IHevm {
    function warp(uint256 timestamp) external;
}

/// @notice A staker: holds its own tokens and calls the farm as `msg.sender`.
contract RewardFarmEchidnaActor {
    RewardFarm internal immutable farm;

    constructor(RewardFarm farm_) {
        farm = farm_;
    }

    function stake(IERC20 stakeToken, uint16 poolId, uint256 amount) external {
        stakeToken.approve(address(farm), amount);
        farm.stake(poolId, amount);
    }

    function withdraw(uint16 poolId, uint256 amount) external {
        farm.withdraw(poolId, amount);
    }

    function claim(uint16 poolId) external {
        farm.claim(poolId);
    }

    function claimSelected(uint16 poolId, IERC20[] calldata tokens) external {
        farm.claimSelected(poolId, tokens);
    }

    function exit(uint16 poolId) external {
        farm.exit(poolId);
    }
}

/**
 * @notice Echidna property harness for {RewardFarm} (run recipe: `contracts/echidna.yaml`; the Foundry counterpart is
 *         `test/RewardFarmInvariants.t.sol`). The harness is the farm owner and funder. Two actors, two pools, three
 *         streams: pool 0 streams SUN (18 dp) + USDG (6 dp), pool 1 streams SUN too (one token across two pools).
 *         Wrapper inputs are bounded by modulo so calls rarely revert; a revert just discards that call.
 *
 *         Ghosts: `funded` / `claimed` per stream (claims measured as the actor's balance delta), and the last seen
 *         `rewardPerTokenStored` per stream (checked + refreshed after every wrapper call).
 */
contract RewardFarmEchidna {
    IHevm internal constant HEVM = IHevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
    uint256 internal constant MAX_FUND = 1e30;
    uint256 internal constant MAX_STAKE = 1e27;
    uint256 internal constant MAX_DURATION = 60 days;
    uint256 internal constant N_STREAMS = 3;

    RewardFarm public immutable farm;
    MockToken public immutable stake0;
    MockToken public immutable stake1;
    MockToken public immutable sun; // 18 dp, pools 0 and 1
    MockToken public immutable usdg; // 6 dp, pool 0
    RewardFarmEchidnaActor[2] internal actors;

    // Stream i = (streamPool[i], streamToken[i]).
    uint16[N_STREAMS] internal streamPool;
    IERC20[N_STREAMS] internal streamToken;

    uint256[N_STREAMS] public funded;
    uint256[N_STREAMS] public claimed;
    uint256[N_STREAMS] public seenRpt;
    bool public rptDecreased;

    constructor() {
        farm = new RewardFarm(address(this));
        stake0 = new MockToken("sunEthLP", "sunEthLP", 18);
        stake1 = new MockToken("sun5StocksLP", "sun5StocksLP", 18);
        sun = new MockToken("Sun", "SUN", 18);
        usdg = new MockToken("USDG", "USDG", 6);
        farm.createPool(stake0);
        farm.createPool(stake1);
        streamPool = [uint16(0), 0, 1];
        streamToken = [IERC20(sun), usdg, sun];
        for (uint256 i; i < N_STREAMS; ++i) {
            farm.addReward(streamPool[i], streamToken[i]);
        }
        actors[0] = new RewardFarmEchidnaActor(farm);
        actors[1] = new RewardFarmEchidnaActor(farm);

        // Live start: both pools staked, every stream funded.
        stake(0, 0, 100e18);
        stake(1, 1, 40e18);
        fund(0, 1_000_000e18, 14 days);
        fund(1, 50_000e6, 10 days);
        fund(2, 300_000e18, 21 days);
    }

    /* -------------------------------- wrappers -------------------------------- */

    function stake(uint8 actor, uint8 pool, uint256 amount) public {
        RewardFarmEchidnaActor a = actors[actor % 2];
        uint16 p = pool % 2;
        MockToken t = p == 0 ? stake0 : stake1;
        amount = 1 + (amount % MAX_STAKE);
        t.mint(address(a), amount);
        a.stake(t, p, amount);
        _syncRpt();
    }

    function withdraw(uint8 actor, uint8 pool, uint256 amount) public {
        RewardFarmEchidnaActor a = actors[actor % 2];
        uint16 p = pool % 2;
        uint256 bal = farm.balanceOf(p, address(a));
        if (bal == 0) return;
        a.withdraw(p, 1 + (amount % bal));
        _syncRpt();
    }

    function claim(uint8 actor, uint8 pool) public {
        RewardFarmEchidnaActor a = actors[actor % 2];
        uint16 p = pool % 2;
        uint256[N_STREAMS] memory before = _balances(address(a));
        a.claim(p);
        _bookClaims(address(a), before, p);
        _syncRpt();
    }

    /// @param mask Bit i selects stream i's token (only those on `pool` are sent); bit 3 duplicates the first pick.
    function claimSelected(uint8 actor, uint8 pool, uint8 mask) public {
        RewardFarmEchidnaActor a = actors[actor % 2];
        uint16 p = pool % 2;
        IERC20[] memory picked = new IERC20[](N_STREAMS + 1);
        uint256 n;
        for (uint256 i; i < N_STREAMS; ++i) {
            if (streamPool[i] == p && (mask >> i) & 1 == 1) picked[n++] = streamToken[i];
        }
        if (n != 0 && (mask >> 3) & 1 == 1) picked[n++] = picked[0];
        assembly ("memory-safe") {
            mstore(picked, n)
        }
        uint256[N_STREAMS] memory before = _balances(address(a));
        a.claimSelected(p, picked);
        _bookClaims(address(a), before, p);
        _syncRpt();
    }

    function exit(uint8 actor, uint8 pool) public {
        RewardFarmEchidnaActor a = actors[actor % 2];
        uint16 p = pool % 2;
        uint256[N_STREAMS] memory before = _balances(address(a));
        a.exit(p);
        _bookClaims(address(a), before, p);
        _syncRpt();
    }

    function fund(uint8 stream, uint256 amount, uint256 duration) public {
        uint256 s = stream % N_STREAMS;
        duration = 1 + (duration % MAX_DURATION);
        amount = duration + (amount % MAX_FUND); // ≥ duration ⇒ rate ≥ 1
        MockToken t = MockToken(address(streamToken[s]));
        t.mint(address(this), amount);
        t.approve(address(farm), amount);
        farm.fund(streamPool[s], t, amount, duration);
        funded[s] += amount;
        _syncRpt();
    }

    function warp(uint256 secs) public {
        HEVM.warp(block.timestamp + (secs % 30 days));
        _syncRpt();
    }

    /* ------------------------------- properties ------------------------------- */

    /// @notice I-1: per reward token, farm balance ≥ Σ streams (Σ actors earned + unemitted schedule).
    function echidna_solvency() public view returns (bool) {
        uint256 owedSun;
        uint256 owedUsdg;
        for (uint256 s; s < N_STREAMS; ++s) {
            uint256 owed = _earnedSum(s);
            (uint256 rate, uint256 periodFinish,,) = farm.rewardState(streamPool[s], streamToken[s]);
            if (periodFinish > block.timestamp) owed += (periodFinish - block.timestamp) * rate;
            if (address(streamToken[s]) == address(sun)) owedSun += owed;
            else owedUsdg += owed;
        }
        return sun.balanceOf(address(farm)) >= owedSun && usdg.balanceOf(address(farm)) >= owedUsdg;
    }

    /// @notice I-2: per pool, the farm holds at least the staked principal.
    function echidna_stakeSolvency() public view returns (bool) {
        return stake0.balanceOf(address(farm)) >= farm.totalStaked(0)
            && stake1.balanceOf(address(farm)) >= farm.totalStaked(1);
    }

    /// @notice Per stream: everything ever funded ≥ everything claimed + everything still claimable.
    function echidna_paidNotMoreThanFunded() public view returns (bool) {
        for (uint256 s; s < N_STREAMS; ++s) {
            if (funded[s] < claimed[s] + _earnedSum(s)) return false;
        }
        return true;
    }

    /// @notice `rewardPerTokenStored` never decreased between any two observations.
    function echidna_rptMonotone() public view returns (bool) {
        if (rptDecreased) return false;
        for (uint256 s; s < N_STREAMS; ++s) {
            (,,, uint256 stored) = farm.rewardState(streamPool[s], streamToken[s]);
            if (stored < seenRpt[s]) return false;
        }
        return true;
    }

    /* --------------------------------- helpers -------------------------------- */

    function _earnedSum(uint256 s) internal view returns (uint256 sum) {
        for (uint256 i; i < 2; ++i) {
            sum += farm.earned(streamPool[s], streamToken[s], address(actors[i]));
        }
    }

    function _balances(address who) internal view returns (uint256[N_STREAMS] memory b) {
        for (uint256 s; s < N_STREAMS; ++s) {
            b[s] = streamToken[s].balanceOf(who);
        }
    }

    /// @dev Books the actor's reward-token gain on pool `p`'s streams. No stake token is a reward token here, so an
    ///      {exit}'s returned principal never shows up in these deltas.
    function _bookClaims(address who, uint256[N_STREAMS] memory before, uint16 p) internal {
        for (uint256 s; s < N_STREAMS; ++s) {
            if (streamPool[s] == p) claimed[s] += streamToken[s].balanceOf(who) - before[s];
        }
    }

    function _syncRpt() internal {
        for (uint256 s; s < N_STREAMS; ++s) {
            (,,, uint256 stored) = farm.rewardState(streamPool[s], streamToken[s]);
            if (stored < seenRpt[s]) rptDecreased = true;
            else seenRpt[s] = stored;
        }
    }
}
