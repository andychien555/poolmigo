# TASK_REWARDFARM — RewardFarm: multi-pool, per-pool reward streams

Status: done (2026-10-08) — implemented in `src/rewards/RewardFarm.sol` (verification: `REPORT-REWARDFARM.md`).
Revision 2026-10-08b (owner feedback): per-stream supplier; cap 4→8.
Revision 2026-10-08c: stateful invariants + echidna harness.
Owner decision (2026-10-08): go with the **multi-pool / multi-reward farm** now; the vote layer is
deferred ("投票之後再說"). Each pool may carry a different reward token — not necessarily SUN.
This extends the root-scope line "Reward/tokenomics: not in scope (PRD §6)" by explicit owner call.

## Goal

One non-upgradeable farm contract that can carry every MySun receipt token (sunEthLP first, more
vaults / pools later). Each pool = one stake token + a small set of reward streams, each stream with
its own emission schedule funded by the owner (treasury / ops) per epoch. No vote logic yet — the
future Snapshot-vote → apply-weights layer will only change *how funding is decided*.

## Non-goals (deferred, do NOT build)

- Voting / gauges / ve-locks / bribes.
- Lockups, cooldowns, staking-time weighting, penalties.
- FE / BE wiring, local-demo integration, any chain deployment.
- Upgradeability / proxies (the farm is a plain immutable contract).
- Native-ETH rewards (ERC-20 only). Performance-fee integration (fee-at-exit stays vault-side).

## Spec (normative)

### Pool lifecycle (owner)
- `createPool(IERC20 stakeToken) returns (uint16 poolId)` — one pool per stake token; reverts on
  duplicate stake token or zero address. Pool array + `stakeTokenToPool` mapping for O(1) checks.
- `addReward(uint16 poolId, IERC20 rewardToken)` — registers one reward stream; at most
  `MAX_REWARDS_PER_POOL = 8` (hard constant; raised from 4 by owner call 2026-10-08 — the cap bounds the
  per-action checkpoint loop over every stream of the pool, so a user's `withdraw` can never become unaffordably
  expensive; streams are never removed); reverts on duplicate (per pool), on `rewardToken ==` that pool's stake
  token, on unknown pool. (A reward token may be another pool's stake token — allowed.)

### Funding (owner or the stream's supplier)
- `fund(uint16 poolId, IERC20 rewardToken, uint256 amount, uint256 duration)`
  - `updateReward(pool, address(0))` first; then Synthetix rollover:
    `leftover = periodFinish > now ? (periodFinish - now) * rate : 0`,
    `rate = (amount + leftover) / duration`, `periodFinish = now + duration`,
    `lastUpdateTime = now`.
  - Requires `amount > 0`, `duration > 0`, computed `rate > 0`, token registered for the pool.
  - Pulls `amount` via SafeERC20 from `msg.sender`. Callable while paused (streams keep running for current stakers).
  - Authorization: the owner OR the stream's supplier, else `RewardFarm__NotRewardSupplier(poolId, rewardToken,
    msg.sender)`. No permissionless funding.

### Per-stream supplier (designated funder)
- `setRewardSupplier(uint16 poolId, IERC20 rewardToken, address supplier)` — onlyOwner; ONE supplier per
  (pool, rewardToken) stream; reverts on unknown pool / unregistered token; `address(0)` = owner-only (the
  default); emits `RewardSupplierSet(poolId, rewardToken, supplier)`. The owner can rotate or clear it at any
  time and can always fund any stream itself.
- The supplier funds with its own tokens (pulled from `msg.sender`); its power is `fund` on that one stream only.
- Storage: a per-pool `rewardToken → supplier` mapping in the `Pool` struct.

### User ops
- `stake(poolId, amount)` / `withdraw(poolId, amount)` — `updateReward(pool, msg.sender)` first;
  paused blocks **stake only** — `withdraw` / `claim` / `exit` must always work.
- `claim(poolId)` — pays ALL registered reward tokens; skips zero balances (no 0-transfers).
- `claimSelected(poolId, IERC20[] tokens)` — pays the listed subset (reverts on unregistered token).
  This exists so one hostile / bricked reward token can never block the others (e.g. a blacklisting
  token for one user). `withdraw` never touches reward transfers, so it can never be bricked.
- `exit(poolId)` — withdraw all + claim all.

### Canonical semantics to match (Synthetix accumulator, per (pool, rewardToken))
- `rewardPerToken` frozen while `totalSupply == 0` (that window emits nothing; rate math unchanged);
  `lastTimeRewardApplicable = min(now, periodFinish)` — accrual clamps at `periodFinish`.
- Rounding floors everywhere: users are never overpaid; sub-wei dust may remain in the contract
  (never sweepable if in a registered reward token — see `recoverERC20`).
- Standard guard pattern: nonReentrant on every mutating external fn that moves tokens.

### Admin
- `setPoolPaused(uint16 poolId, bool)` — owner; paused blocks staking only.
- `recoverERC20(IERC20 token, address to, uint256 amount)` — owner; reverts if `token` is any pool's
  stake token or ANY registered reward token (unclaimed finished-stream rewards belong to users;
  no sweep path for them in v1 — recorded as a known limitation).

### Views (for FE / ops)
- `poolCount()`, `poolInfo(poolId) -> (stakeToken, totalStaked, paused)`,
  `poolRewards(poolId) -> IERC20[]`, `rewardState(poolId, token) -> (rate, periodFinish, lastUpdateTime, rewardPerTokenStored)`,
  `rewardSupplier(poolId, token) -> address` (reverts on an unregistered token, like `rewardState`),
  `earned(poolId, token, user)`, `earnedAll(poolId, user) -> uint256[]`, `balanceOf(poolId, user)`, `totalStaked(poolId)`.

### Conventions (repo rules)
- OZ v5.1.0 (`Ownable`, `ReentrancyGuard`, `SafeERC20`, `IERC20`); solc 0.8.34; `optimizer_runs = 100`.
- Custom errors `RewardFarm__…` (style: `PoolmigoVault__InexactDelivery`); NatSpec on every external
  fn, with security-relevant rationales inline.
- `forge fmt` clean (line_length 120). Non-upgradeable; constructor takes `initialOwner`.
- EIP-170: measure `forge build --sizes` and record the number (expect small; the farm is a new
  standalone artifact — no existing size budget is affected).

### Tests (must)
- Unit: create/addReward revert matrix; fund math; rollover funding mid-stream (leftover);
  emission clamps at periodFinish; stake/withdraw/claim across 2 users / 2 pools / different reward
  tokens; `claimSelected` isolation with a hostile (reverting-transfer) reward token; paused blocks
  stake only; recoverERC20 blocks; zero-supply window emits nothing.
- Fuzz: earned monotonicity; sum of claims ≤ funded; no underflow/overpay across random warps.
- One time-warped scenario simulating several epochs of funding + multiple stakers (repo preference:
  realistic activity, not toy mocks).
- The FULL non-fork `forge test` suite must stay green.

## Deliverables

1. `contracts/src/rewards/RewardFarm.sol`
2. `contracts/test/RewardFarm.t.sol` (+ optional extra scenario file if cleaner)
3. `contracts/script/DeployRewardFarm.s.sol`
4. `contracts/REPORT-REWARDFARM.md` — design decisions, audit-attention list, exact size, test
   counts, deviations from this doc + why, deferrals.

Hard rules for the implementer: no commits, no deploys, no network, do not touch AGENTS.md or this
task doc, don't modify existing contracts.
