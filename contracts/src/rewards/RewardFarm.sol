// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title RewardFarm
 * @author MySun
 * @notice Multi-pool farm for MySun receipt tokens (`contracts/TASK_REWARDFARM.md`). Each pool = ONE stake token + up to
 *         {MAX_REWARDS_PER_POOL} reward streams; every (pool, rewardToken) stream is an independent Synthetix
 *         accumulator with its own rate / period, funded per epoch via {fund} by the owner (treasury / ops) or by
 *         that stream's owner-designated supplier ({setRewardSupplier}; one per stream, with its own tokens).
 *
 *         Semantics (canonical Synthetix `StakingRewards`, per stream):
 *         - `rewardPerToken` is frozen while the pool's `totalStaked == 0` — emissions of that window are NOT
 *           distributed (they stay in the contract; see {recoverERC20} for why they are not sweepable);
 *         - accrual clamps at `periodFinish` (`lastTimeRewardApplicable = min(now, periodFinish)`);
 *         - every division floors: a user is never overpaid; sub-wei dust may remain in the contract.
 *
 *         Liveness: {withdraw} performs NO reward transfer and its accounting step makes no external call, so no reward
 *         token — however hostile — can ever trap stake. {claimSelected} lets a user skip a reward token that reverts
 *         for them (blacklist, pause, broken token) and still collect the others. A pool's pause flag blocks {stake}
 *         ONLY; {withdraw} / {claim} / {claimSelected} / {exit} / {fund} keep working.
 *
 *         Immutable, non-upgradeable, ERC-20 rewards only; no vote / gauge / lock logic (deferred). Neither stake nor
 *         reward tokens may be fee-on-transfer or rebasing: {stake} and {fund} require exact delivery.
 */
contract RewardFarm is Ownable2Step, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /* ------------------------------------------------------------------ */
    /*                              Constants                             */
    /* ------------------------------------------------------------------ */

    /// @notice Hard cap on reward streams per pool. Liveness bound: every stake / withdraw / claim / fund checkpoints
    ///         EVERY stream of the pool, and streams can never be removed — so the cap is what guarantees a user's
    ///         {withdraw} can never grow unaffordably expensive. 8 (raised from 4) is an owner call (2026-10-08).
    uint256 public constant MAX_REWARDS_PER_POOL = 8;

    /// @notice Fixed-point scale of `rewardPerToken`. 1e30 (not Synthetix's 1e18) so the per-update floor loss —
    ///         strictly below `totalStaked / PRECISION` reward wei — stays sub-wei even for a 6-dp reward token
    ///         streamed to a large 18-dp stake supply. Overflow headroom is enforced in {fund} ({MAX_FUNDABLE}).
    uint256 public constant PRECISION = 1e30;

    /// @notice Max `amount + leftover` one {fund} call may schedule (≈1.16e47 wei): keeps
    ///         `elapsed · rate · PRECISION` inside uint256 for every accrual step of that period.
    uint256 public constant MAX_FUNDABLE = type(uint256).max / PRECISION;

    /* ------------------------------------------------------------------ */
    /*                               Storage                              */
    /* ------------------------------------------------------------------ */

    /// @notice One reward stream's Synthetix state.
    struct RewardData {
        uint256 rate; // reward wei per second
        uint256 periodFinish; // end of the current emission period (0 = never funded)
        uint256 lastUpdateTime; // last accrual checkpoint (≤ periodFinish)
        uint256 rewardPerTokenStored; // accumulator, scaled by PRECISION
    }

    struct Pool {
        IERC20 stakeToken;
        bool paused;
        uint256 totalStaked;
        IERC20[] rewardTokens;
        mapping(address user => uint256) balances;
        mapping(IERC20 rewardToken => bool) isReward;
        mapping(IERC20 rewardToken => address supplier) suppliers; // designated funder per stream (0 = owner-only)
        mapping(IERC20 rewardToken => RewardData) rewardData;
        mapping(IERC20 rewardToken => mapping(address user => uint256)) userRewardPerTokenPaid;
        mapping(IERC20 rewardToken => mapping(address user => uint256)) rewards;
    }

    Pool[] internal _pools;

    /// @dev Stake token → `poolId + 1` (0 = no pool). One pool per stake token.
    mapping(IERC20 stakeToken => uint256) internal _stakeTokenToPool;

    /// @dev Every token ever registered as a reward on ANY pool (streams are never removed) — blocks {recoverERC20}.
    mapping(IERC20 token => bool) internal _isAnyReward;

    /* ------------------------------------------------------------------ */
    /*                           Events / errors                          */
    /* ------------------------------------------------------------------ */

    event PoolCreated(uint16 indexed poolId, IERC20 indexed stakeToken);
    event RewardAdded(uint16 indexed poolId, IERC20 indexed rewardToken);
    event RewardFunded(
        uint16 indexed poolId,
        IERC20 indexed rewardToken,
        uint256 amount,
        uint256 leftover,
        uint256 duration,
        uint256 rate,
        uint256 periodFinish
    );
    event Staked(uint16 indexed poolId, address indexed user, uint256 amount);
    event Withdrawn(uint16 indexed poolId, address indexed user, uint256 amount);
    event RewardPaid(uint16 indexed poolId, address indexed user, IERC20 indexed rewardToken, uint256 amount);
    event RewardSupplierSet(uint16 indexed poolId, IERC20 indexed rewardToken, address indexed supplier);
    event PoolPausedSet(uint16 indexed poolId, bool paused);
    event Recovered(IERC20 indexed token, address indexed to, uint256 amount);

    error RewardFarm__ZeroAddress();
    error RewardFarm__ZeroAmount();
    error RewardFarm__ZeroDuration();
    error RewardFarm__ZeroRewardRate();
    error RewardFarm__FundTooLarge(uint256 total, uint256 max);
    error RewardFarm__TooManyPools();
    error RewardFarm__UnknownPool(uint16 poolId);
    error RewardFarm__UnknownStakeToken(IERC20 stakeToken);
    error RewardFarm__StakeTokenAlreadyPooled(IERC20 stakeToken, uint16 poolId);
    error RewardFarm__TooManyRewards(uint16 poolId);
    error RewardFarm__RewardAlreadyAdded(uint16 poolId, IERC20 rewardToken);
    error RewardFarm__RewardIsStakeToken(uint16 poolId, IERC20 rewardToken);
    error RewardFarm__RewardNotRegistered(uint16 poolId, IERC20 rewardToken);
    error RewardFarm__NotRewardSupplier(uint16 poolId, IERC20 rewardToken, address caller);
    error RewardFarm__PoolPaused(uint16 poolId);
    error RewardFarm__InsufficientBalance(uint16 poolId, address user, uint256 requested, uint256 balance);
    error RewardFarm__InexactDelivery(IERC20 token, uint256 expected, uint256 received);
    error RewardFarm__RecoverBlocked(IERC20 token);

    /* ------------------------------------------------------------------ */
    /*                             Constructor                            */
    /* ------------------------------------------------------------------ */

    /// @param initialOwner Owner (treasury / ops multisig): creates pools, registers + funds streams, designates stream
    ///        suppliers, pauses staking.
    constructor(address initialOwner) Ownable(initialOwner) {}

    /* ------------------------------------------------------------------ */
    /*                         Pool lifecycle (owner)                     */
    /* ------------------------------------------------------------------ */

    /**
     * @notice Creates a pool for `stakeToken`. One pool per stake token (O(1) duplicate check).
     * @dev Pools are never removed; `poolId`s are dense indices `0..poolCount()-1` (≤ 65 536 pools).
     * @param stakeToken The token staked into this pool (a MySun receipt token); must be a plain ERC-20 (exact
     *        transfers — {stake} enforces it).
     * @return poolId The new pool's id.
     */
    function createPool(IERC20 stakeToken) external onlyOwner returns (uint16 poolId) {
        if (address(stakeToken) == address(0)) revert RewardFarm__ZeroAddress();
        uint256 existing = _stakeTokenToPool[stakeToken];
        // forge-lint: disable-next-line(unsafe-typecast)
        if (existing != 0) revert RewardFarm__StakeTokenAlreadyPooled(stakeToken, uint16(existing - 1));
        uint256 id = _pools.length;
        if (id > type(uint16).max) revert RewardFarm__TooManyPools();
        // forge-lint: disable-next-line(unsafe-typecast)
        poolId = uint16(id); // bounded on the line above
        Pool storage p = _pools.push();
        p.stakeToken = stakeToken;
        _stakeTokenToPool[stakeToken] = id + 1;
        emit PoolCreated(poolId, stakeToken);
    }

    /**
     * @notice Registers `rewardToken` as a new reward stream on `poolId` (unfunded until {fund}).
     * @dev Streams cannot be removed: a stream's unclaimed rewards belong to users, and a removed stream would orphan
     *      them. The token may be ANOTHER pool's stake token (accounting is per pool), but never this pool's own stake
     *      token — that would let reward funding and principal share one balance-sheet line.
     *      A newly added stream starts at `rewardPerTokenStored = 0` and only accrues from its first {fund}, so
     *      existing stakers (paid checkpoint 0) earn exactly from that moment on.
     * @param poolId Target pool.
     * @param rewardToken ERC-20 reward token (not fee-on-transfer: {fund} requires exact delivery).
     */
    function addReward(uint16 poolId, IERC20 rewardToken) external onlyOwner {
        Pool storage p = _pool(poolId);
        if (address(rewardToken) == address(0)) revert RewardFarm__ZeroAddress();
        if (rewardToken == p.stakeToken) revert RewardFarm__RewardIsStakeToken(poolId, rewardToken);
        if (p.isReward[rewardToken]) revert RewardFarm__RewardAlreadyAdded(poolId, rewardToken);
        if (p.rewardTokens.length >= MAX_REWARDS_PER_POOL) revert RewardFarm__TooManyRewards(poolId);
        p.isReward[rewardToken] = true;
        p.rewardTokens.push(rewardToken);
        _isAnyReward[rewardToken] = true;
        emit RewardAdded(poolId, rewardToken);
    }

    /* ------------------------------------------------------------------ */
    /*                     Funding (owner / stream supplier)              */
    /* ------------------------------------------------------------------ */

    /**
     * @notice Designates `supplier` as the one address (besides the owner) allowed to {fund} the `rewardToken` stream
     *         of `poolId` — e.g. a partner protocol streaming its own token. Rotate by setting a new one; clear with
     *         `address(0)` (back to owner-only). The owner can always fund every stream.
     * @dev The supplier's power is exactly {fund} on that one stream, with its own tokens: it can never move user stake
     *      or rewards, nor touch another stream. Like any funder it can roll the stream over (e.g. a tiny amount over a
     *      long duration stretches the remaining emission) — the owner revokes by rotating / clearing.
     * @param poolId Target pool.
     * @param rewardToken A stream registered on `poolId`.
     * @param supplier The designated funder; `address(0)` = owner-only.
     */
    function setRewardSupplier(uint16 poolId, IERC20 rewardToken, address supplier) external onlyOwner {
        Pool storage p = _pool(poolId);
        if (!p.isReward[rewardToken]) revert RewardFarm__RewardNotRegistered(poolId, rewardToken);
        p.suppliers[rewardToken] = supplier;
        emit RewardSupplierSet(poolId, rewardToken, supplier);
    }

    /**
     * @notice Funds one stream: `amount` new reward plus any unemitted leftover of the running period are spread
     *         evenly over `duration` seconds starting now (Synthetix rollover).
     * @dev Checkpoints every stream of the pool first, so accrual up to now is booked at the OLD rate. Then
     *      `leftover = periodFinish > now ? (periodFinish - now) · rate : 0`, `rate = (amount + leftover) / duration`
     *      (floored — `rate · duration ≤ amount + leftover`, so a period never promises more than it holds),
     *      `periodFinish = now + duration`, `lastUpdateTime = now`.
     *      Callable by the owner or the stream's supplier ({setRewardSupplier}); the caller pays. Callable while the
     *      pool is paused: streams keep running for current stakers. The pull is checked for exact delivery — a fee-on-transfer reward token would
     *      otherwise schedule more than the farm received and make later claimants insolvent.
     * @param poolId Target pool.
     * @param rewardToken A stream registered on `poolId`.
     * @param amount New reward wei pulled from the caller — the owner or the stream's supplier (> 0).
     * @param duration Emission window in seconds (> 0).
     */
    function fund(uint16 poolId, IERC20 rewardToken, uint256 amount, uint256 duration) external nonReentrant {
        Pool storage p = _pool(poolId);
        if (!p.isReward[rewardToken]) revert RewardFarm__RewardNotRegistered(poolId, rewardToken);
        if (msg.sender != owner() && msg.sender != p.suppliers[rewardToken]) {
            revert RewardFarm__NotRewardSupplier(poolId, rewardToken, msg.sender);
        }
        if (amount == 0) revert RewardFarm__ZeroAmount();
        if (duration == 0) revert RewardFarm__ZeroDuration();

        _updateReward(p, address(0));

        RewardData storage r = p.rewardData[rewardToken];
        uint256 leftover = r.periodFinish > block.timestamp ? (r.periodFinish - block.timestamp) * r.rate : 0;
        uint256 total = amount + leftover;
        // Overflow headroom: elapsed ≤ duration and rate · duration ≤ total, so every accrual product
        // `elapsed · rate · PRECISION` of this period fits in uint256.
        if (total > MAX_FUNDABLE) revert RewardFarm__FundTooLarge(total, MAX_FUNDABLE);
        uint256 rate = total / duration;
        if (rate == 0) revert RewardFarm__ZeroRewardRate();

        r.rate = rate;
        r.lastUpdateTime = block.timestamp;
        r.periodFinish = block.timestamp + duration;

        emit RewardFunded(poolId, rewardToken, amount, leftover, duration, rate, block.timestamp + duration);
        _pullExact(rewardToken, msg.sender, amount);
    }

    /* ------------------------------------------------------------------ */
    /*                              User ops                              */
    /* ------------------------------------------------------------------ */

    /**
     * @notice Stakes `amount` of the pool's stake token. Blocked while the pool is paused (the only paused gate).
     * @dev Checkpoints the caller on every stream BEFORE the balance changes. Exact delivery is enforced (a
     *      fee-on-transfer / rebasing stake token would make `totalStaked` exceed the real holdings).
     * @param poolId Target pool.
     * @param amount Stake token wei (> 0).
     */
    function stake(uint16 poolId, uint256 amount) external nonReentrant {
        Pool storage p = _pool(poolId);
        if (p.paused) revert RewardFarm__PoolPaused(poolId);
        if (amount == 0) revert RewardFarm__ZeroAmount();
        _updateReward(p, msg.sender);
        p.totalStaked += amount;
        p.balances[msg.sender] += amount;
        emit Staked(poolId, msg.sender, amount);
        _pullExact(p.stakeToken, msg.sender, amount);
    }

    /**
     * @notice Withdraws `amount` of the caller's stake. Always available (never paused) and never transfers rewards —
     *         accrued rewards stay claimable — so no reward token can block a principal exit.
     * @param poolId Target pool.
     * @param amount Stake token wei (> 0, ≤ the caller's balance).
     */
    function withdraw(uint16 poolId, uint256 amount) external nonReentrant {
        Pool storage p = _pool(poolId);
        if (amount == 0) revert RewardFarm__ZeroAmount();
        _withdraw(p, poolId, amount);
    }

    /**
     * @notice Pays the caller every registered reward of `poolId` (zero balances skipped — no 0-value transfers).
     * @dev One reverting reward token reverts the whole call — use {claimSelected} to route around it.
     * @param poolId Target pool.
     */
    function claim(uint16 poolId) external nonReentrant {
        Pool storage p = _pool(poolId);
        _updateReward(p, msg.sender);
        _claimAll(p, poolId);
    }

    /**
     * @notice Pays the caller only the listed reward tokens of `poolId` (zero balances skipped). Exists so a hostile or
     *         bricked reward token (e.g. one that blacklists this user) can never block the others.
     * @dev Every listed token must be registered on the pool. A duplicate entry pays nothing the second time.
     * @param poolId Target pool.
     * @param tokens Subset of `poolRewards(poolId)`.
     */
    function claimSelected(uint16 poolId, IERC20[] calldata tokens) external nonReentrant {
        Pool storage p = _pool(poolId);
        for (uint256 i; i < tokens.length; ++i) {
            if (!p.isReward[tokens[i]]) revert RewardFarm__RewardNotRegistered(poolId, tokens[i]);
        }
        _updateReward(p, msg.sender);
        for (uint256 i; i < tokens.length; ++i) {
            _pay(p, poolId, tokens[i]);
        }
    }

    /**
     * @notice Withdraws the caller's whole stake and claims every reward. If a reward token reverts for the caller,
     *         use {withdraw} + {claimSelected} instead.
     * @param poolId Target pool.
     */
    function exit(uint16 poolId) external nonReentrant {
        Pool storage p = _pool(poolId);
        uint256 bal = p.balances[msg.sender];
        if (bal != 0) {
            _withdraw(p, poolId, bal); // checkpoints the caller
        } else {
            _updateReward(p, msg.sender);
        }
        _claimAll(p, poolId);
    }

    /* ------------------------------------------------------------------ */
    /*                                Admin                               */
    /* ------------------------------------------------------------------ */

    /**
     * @notice Pauses / unpauses STAKING on `poolId`. Withdraw, claims and funding are never paused — a pause must not
     *         be able to hold user principal or accrued rewards.
     */
    function setPoolPaused(uint16 poolId, bool paused) external onlyOwner {
        _pool(poolId).paused = paused;
        emit PoolPausedSet(poolId, paused);
    }

    /**
     * @notice Recovers a token sent here by mistake.
     * @dev Reverts for ANY pool's stake token (user principal) and ANY token ever registered as a reward on ANY pool
     *      (unclaimed — including finished-stream and zero-supply-window — rewards belong to users or to no one; v1 has
     *      no sweep path for them, a known limitation).
     */
    function recoverERC20(IERC20 token, address to, uint256 amount) external nonReentrant onlyOwner {
        if (to == address(0)) revert RewardFarm__ZeroAddress();
        if (_stakeTokenToPool[token] != 0 || _isAnyReward[token]) revert RewardFarm__RecoverBlocked(token);
        emit Recovered(token, to, amount);
        token.safeTransfer(to, amount);
    }

    /* ------------------------------------------------------------------ */
    /*                                Views                               */
    /* ------------------------------------------------------------------ */

    /// @notice Number of pools (`poolId`s are `0..poolCount()-1`).
    function poolCount() external view returns (uint256) {
        return _pools.length;
    }

    /// @notice The pool id of `stakeToken`; reverts if no pool stakes it.
    function poolIdOf(IERC20 stakeToken) external view returns (uint16) {
        uint256 idPlusOne = _stakeTokenToPool[stakeToken];
        if (idPlusOne == 0) revert RewardFarm__UnknownStakeToken(stakeToken);
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint16(idPlusOne - 1); // stored ids are `poolId + 1` of a uint16 id
    }

    /// @notice Pool summary: stake token, total staked, staking-paused flag.
    function poolInfo(uint16 poolId) external view returns (IERC20 stakeToken, uint256 totalStaked_, bool paused) {
        Pool storage p = _pool(poolId);
        return (p.stakeToken, p.totalStaked, p.paused);
    }

    /// @notice Registered reward tokens of `poolId`, in registration order.
    function poolRewards(uint16 poolId) external view returns (IERC20[] memory) {
        return _pool(poolId).rewardTokens;
    }

    /// @notice Raw stored state of one stream (`rewardPerTokenStored` is the last checkpoint, not live).
    function rewardState(uint16 poolId, IERC20 rewardToken)
        external
        view
        returns (uint256 rate, uint256 periodFinish, uint256 lastUpdateTime, uint256 rewardPerTokenStored)
    {
        Pool storage p = _pool(poolId);
        if (!p.isReward[rewardToken]) revert RewardFarm__RewardNotRegistered(poolId, rewardToken);
        RewardData storage r = p.rewardData[rewardToken];
        return (r.rate, r.periodFinish, r.lastUpdateTime, r.rewardPerTokenStored);
    }

    /// @notice The designated funder of one stream (`address(0)` = owner-only).
    function rewardSupplier(uint16 poolId, IERC20 rewardToken) external view returns (address) {
        Pool storage p = _pool(poolId);
        if (!p.isReward[rewardToken]) revert RewardFarm__RewardNotRegistered(poolId, rewardToken);
        return p.suppliers[rewardToken];
    }

    /// @notice Live accumulator of one stream (scaled by {PRECISION}).
    function rewardPerToken(uint16 poolId, IERC20 rewardToken) external view returns (uint256) {
        Pool storage p = _pool(poolId);
        if (!p.isReward[rewardToken]) revert RewardFarm__RewardNotRegistered(poolId, rewardToken);
        return _rewardPerToken(p.rewardData[rewardToken], p.totalStaked);
    }

    /// @notice `user`'s live claimable amount of `rewardToken` on `poolId`.
    function earned(uint16 poolId, IERC20 rewardToken, address user) external view returns (uint256) {
        Pool storage p = _pool(poolId);
        if (!p.isReward[rewardToken]) revert RewardFarm__RewardNotRegistered(poolId, rewardToken);
        return _earned(p, rewardToken, user, _rewardPerToken(p.rewardData[rewardToken], p.totalStaked));
    }

    /// @notice `user`'s live claimable amounts, aligned with `poolRewards(poolId)`.
    function earnedAll(uint16 poolId, address user) external view returns (uint256[] memory amounts) {
        Pool storage p = _pool(poolId);
        uint256 n = p.rewardTokens.length;
        amounts = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            IERC20 t = p.rewardTokens[i];
            amounts[i] = _earned(p, t, user, _rewardPerToken(p.rewardData[t], p.totalStaked));
        }
    }

    /// @notice `user`'s stake in `poolId`.
    function balanceOf(uint16 poolId, address user) external view returns (uint256) {
        return _pool(poolId).balances[user];
    }

    /// @notice Total stake in `poolId`.
    function totalStaked(uint16 poolId) external view returns (uint256) {
        return _pool(poolId).totalStaked;
    }

    /* ------------------------------------------------------------------ */
    /*                              Internals                             */
    /* ------------------------------------------------------------------ */

    function _pool(uint16 poolId) internal view returns (Pool storage) {
        if (poolId >= _pools.length) revert RewardFarm__UnknownPool(poolId);
        return _pools[poolId];
    }

    /// @dev `min(now, periodFinish)`; 0 for a never-funded stream (whose accumulator therefore never moves).
    function _lastTimeRewardApplicable(RewardData storage r) internal view returns (uint256) {
        return Math.min(block.timestamp, r.periodFinish);
    }

    /// @dev Frozen while `supply == 0`. `lastUpdateTime ≤ lastTimeRewardApplicable` always holds (it is only ever set
    ///      to that value or to `now` at {fund}, where `periodFinish > now`), so the subtraction cannot underflow.
    function _rewardPerToken(RewardData storage r, uint256 supply) internal view returns (uint256) {
        if (supply == 0) return r.rewardPerTokenStored;
        return
            r.rewardPerTokenStored + ((_lastTimeRewardApplicable(r) - r.lastUpdateTime) * r.rate * PRECISION) / supply;
    }

    /// @dev Floors. `mulDiv` (512-bit intermediate) so a long-untouched balance can never overflow the product; the
    ///      result is bounded by what was emitted to the user, which fits.
    function _earned(Pool storage p, IERC20 t, address user, uint256 rpt) internal view returns (uint256) {
        return p.rewards[t][user] + Math.mulDiv(p.balances[user], rpt - p.userRewardPerTokenPaid[t][user], PRECISION);
    }

    /// @dev Checkpoints every stream of the pool (and `account`, unless zero). Pure storage math — NO external call —
    ///      so it can never be bricked by a token, which is what keeps {withdraw} always available.
    function _updateReward(Pool storage p, address account) internal {
        uint256 supply = p.totalStaked;
        uint256 n = p.rewardTokens.length;
        for (uint256 i; i < n; ++i) {
            IERC20 t = p.rewardTokens[i];
            RewardData storage r = p.rewardData[t];
            uint256 rpt = _rewardPerToken(r, supply);
            r.rewardPerTokenStored = rpt;
            r.lastUpdateTime = _lastTimeRewardApplicable(r);
            if (account != address(0)) {
                p.rewards[t][account] = _earned(p, t, account, rpt);
                p.userRewardPerTokenPaid[t][account] = rpt;
            }
        }
    }

    function _withdraw(Pool storage p, uint16 poolId, uint256 amount) internal {
        uint256 bal = p.balances[msg.sender];
        if (amount > bal) revert RewardFarm__InsufficientBalance(poolId, msg.sender, amount, bal);
        _updateReward(p, msg.sender);
        p.balances[msg.sender] = bal - amount;
        p.totalStaked -= amount;
        emit Withdrawn(poolId, msg.sender, amount);
        p.stakeToken.safeTransfer(msg.sender, amount);
    }

    /// @dev Caller must have checkpointed `msg.sender` already.
    function _claimAll(Pool storage p, uint16 poolId) internal {
        uint256 n = p.rewardTokens.length;
        for (uint256 i; i < n; ++i) {
            _pay(p, poolId, p.rewardTokens[i]);
        }
    }

    /// @dev Checks-effects-interactions: the owed balance is zeroed before the transfer. Zero owed → no transfer.
    function _pay(Pool storage p, uint16 poolId, IERC20 t) internal {
        uint256 owed = p.rewards[t][msg.sender];
        if (owed == 0) return;
        p.rewards[t][msg.sender] = 0;
        emit RewardPaid(poolId, msg.sender, t, owed);
        t.safeTransfer(msg.sender, owed);
    }

    /// @dev Pulls `amount` and requires the farm's balance to grow by exactly `amount`.
    function _pullExact(IERC20 token, address from, uint256 amount) internal {
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(from, address(this), amount);
        uint256 received = token.balanceOf(address(this)) - before;
        if (received != amount) revert RewardFarm__InexactDelivery(token, amount, received);
    }
}
