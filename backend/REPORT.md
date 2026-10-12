# REPORT — backend keeper service

Date: 2026-09-22. Scope: `backend/` only. Nothing outside `backend/` was modified (verified with
`git status --porcelain`, output at the end). No git commands beyond read-only `status` were run.

---

## 1. What was built

A deployable keeper service for `PoolmigoVaultUpgradeable`: Node 20+ / TypeScript strict / viem v2,
single process, interval loop, structured JSON logs, atomic durable state, Docker + systemd
deployment artifacts.

It calls exactly two contract functions — the keeper-gated `deployTo(adapter, amounts)` and
`rebalance()`. The owner-only surface is not merely unused: `scripts/sync-abis.mjs` narrows the
generated ABI to the keeper's own functions, so `addAdapter` / `setKeeper` / `setRebalancePaused` /
`setPerformanceFeeBps` / `setTreasury` / `emergencyUnwind` / upgrades **cannot be encoded** by this
codebase at all.

Design points worth flagging to the reviewer:

- **Token-order alignment is structural, not incidental.** `deployTo` requires `amounts` aligned to
  the *adapter's* `position()` order, which need not match the vault registry order. Plans carry the
  adapter's token vector next to the amounts and are built by address lookup, never by index. Unit
  tests cover a reordered adapter, two adapters with different orders in one tick, an adapter that
  holds a strict subset of the basket, a duplicated adapter token, and an adapter token absent from
  the registry.
- **`MAX_DEPLOY_PER_TICK_BPS` is measured against per-token TOTAL (idle + positions), not idle.**
  Total does not move as the tick deploys, so the cap behaves identically whether the vault is fully
  idle or nearly fully deployed, and successive ticks converge on the target rather than oscillating
  (covered by a unit test that iterates the rule and lands exactly on the target).
- **Per-token budgets are split only among adapters that actually report that token**, with weights
  renormalised per token. Splitting globally would assign a slice to an adapter that cannot hold it.
- **Rounding always rounds down**; the dust stays idle rather than overdrawing a budget.
- **`MIN_DEPLOY_AMOUNT_RAW` accepts per-token floors**, because a 6-decimal and an 18-decimal basket
  token cannot share one raw scalar sensibly.
- **`ADAPTER_WEIGHTS` supports an address-keyed form and it is the recommended one**, because
  `removeAdapter` uses swap-and-pop: a positional list silently re-targets itself when the registry
  changes. A positional list whose length no longer matches `adapters()` is rejected, not guessed.
- **Only a *confirmed* `rebalance()` advances the harvest interval gate.** Dry runs and failures do
  not.
- **The private key is unloggable by construction**: the startup line runs the config through
  `describeConfig`, which omits the key and reports `signer: "configured" | "absent"`. A malformed
  key is rejected without echoing the value. Both are unit-tested.

## 2. File map

```
backend/
├── README.md                 quick start, full env table, Docker/systemd, monitoring, exit codes
├── REPORT.md                 this file
├── .env.example              every variable documented, with defaults
├── Dockerfile                multi-stage (deps→build→runtime), node:20-alpine, non-root
├── docker-compose.yml        service, env_file, state volume, host-anvil + secrets examples
├── .dockerignore / .gitignore
├── package.json · tsconfig.json · tsconfig.build.json · vitest.config.ts
├── scripts/
│   └── sync-abis.mjs         ../shared/abis/*.json -> src/abi/generated.ts (narrowed, committed)
├── src/
│   ├── cli.ts        (193)   tick | run | status, --dry-run/--execute, exit codes, signals
│   ├── keeper.ts     (571)   tick orchestration, post-condition verification, supervision loop
│   ├── policy.ts     (293)   THE STRATEGY — pure, deterministic, no IO
│   ├── vault.ts      (289)   the only module that touches contracts
│   ├── config.ts     (449)   env -> validated config; pure parsers; secret redaction
│   ├── chain.ts      (162)   viem clients, chain def, retryable-vs-terminal split, backoff
│   ├── state.ts      (149)   atomic durable state, corrupt-file recovery
│   ├── logger.ts      (93)   structured JSON, bigint-safe
│   ├── types.ts        (4)
│   └── abi/generated.ts      AUTO-GENERATED — do not edit
└── test/
    ├── unit/         (114 tests)  policy · config · state · chain · cli+logger · guards
    └── integration/    (5 tests)  against the LIVE local anvil
```

`src/abi/generated.ts` is committed on purpose: `shared/abis/` remains the single source of truth,
but the Docker build context is `backend/` alone, so the image must not need `../shared`. Re-run
`npm run sync-abis` after any contract change.

## 3. Real command output

### 3.1 `npm install` / `npm run build`

```
$ rm -rf node_modules && npm install
added 57 packages, and audited 58 packages in 2s

22 packages are looking for funding
  run `npm fund` for details

found 0 vulnerabilities

$ npm run build
> @poolmigo/keeper@0.1.0 build
> tsc -p tsconfig.build.json
```

(`npm audit` reports **0 vulnerabilities**. The natural `vitest@^2` pin produced
`5 vulnerabilities (3 moderate, 1 high, 1 critical)` in the dev-only vite / esbuild / @vitest/mocker
chain; the pin was moved to `vitest@^5.0.1` and the tree reinstalled clean. The only runtime
dependency is `viem`.)

`npx tsc -p tsconfig.json --noEmit` (src **and** tests, strict + `noUncheckedIndexedAccess` +
`exactOptionalPropertyTypes`) produces no output.

### 3.2 `npm test` — 119 passing, 7 files

```
$ npm test
> @poolmigo/keeper@0.1.0 test
> vitest run

 RUN  v5.0.1 /Users/Hermes/poolmigo/backend

 Test Files  7 passed (7)
      Tests  119 passed (119)
   Start at  20:15:05
   Duration  16.82s (tests 98%, import 2%)
```

Per file (counts from a `--reporter=verbose` run of the same suite):

```
   5 test/integration/keeper.integration.test.ts
  10 test/unit/chain.test.ts
  15 test/unit/cli.test.ts
  40 test/unit/config.test.ts
   6 test/unit/guards.test.ts
  31 test/unit/policy.test.ts
  12 test/unit/state.test.ts
```

The five integration tests, named as they run (timings from the verbose run; the integration
suite dominates the wall clock because each transaction waits for a real Anvil block):

```
 ✓ keeper against the live local stack > a) dry run: plans the expected deployments and changes nothing on chain 19ms
 ✓ keeper against the live local stack > b) execute: one real deployTo grows the adapter position by exactly the amounts sent 4024ms
 ✓ keeper against the live local stack > c) rebalance: harvests seeded fees and sends exactly performanceFeeBps to the treasury 12072ms
 ✓ keeper against the live local stack > d) a not-yet-due harvest is skipped with an explicit reason 11ms
 ✓ keeper against the live local stack > e) preflight rejects an address the vault does not recognise as a keeper 2ms
```

Test (a) asserts the plan against a **longhand restatement** of the policy arithmetic written out in
the test file, so a bug in `policy.ts` cannot make the assertion pass by agreeing with itself, and
then asserts that idle balances and every adapter position are byte-identical afterwards.

### 3.3 Dry-run tick (service CLI, against the live anvil)

Verbatim, unedited:

```
$ KEEPER_PRIVATE_KEY=0x59c6…690d STATE_FILE=/tmp/kdry.json node dist/cli.js tick --dry-run
{"ts":"2026-09-22T12:12:27.449Z","level":"info","msg":"starting","svc":"poolmigo-keeper","command":"tick","effectiveDryRun":true,"config":{"rpcUrl":"http://127.0.0.1:8547","chainId":46630,"vault":"0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9","dryRun":true,"tickIntervalSec":60,"rebalanceIntervalSec":86400,"targetIdleBps":2000,"maxDeployPerTickBps":5000,"adapterWeights":"equal","minDeployDefault":"0","minDeployByToken":{},"stateFile":"/tmp/kdry.json","logLevel":"info","confirmations":1,"keeperAddressOverride":null,"signer":"configured"}}
{"ts":"2026-09-22T12:12:27.480Z","level":"info","msg":"preflight ok","svc":"poolmigo-keeper","keeper":"0x70997970C51812dc3A010C7d01b50e0d17dc79C8","vault":"0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9","chainId":46630,"signer":"present"}
{"ts":"2026-09-22T12:12:27.485Z","level":"info","msg":"observed vault","svc":"poolmigo-keeper","tick":1,"dryRun":true,"block":"58","paused":false,"performanceFeeBps":1000,"treasury":"0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266","tokens":["0x5FbDB2315678afecb367f032d93F642f64180aa3","0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512"],"idle":["21791000000","2358200000000000000"],"adapters":[{"address":"0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9","tokens":["0x5FbDB2315678afecb367f032d93F642f64180aa3","0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512"],"amounts":["59254000000","6350800000000000000"]},{"address":"0x5FC8d32690cc91D4c39d9d3abcBD16989F875707","tokens":["0x5FbDB2315678afecb367f032d93F642f64180aa3","0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512"],"amounts":["25210000000","2542000000000000000"]}]}
{"ts":"2026-09-22T12:12:27.486Z","level":"info","msg":"policy decision","svc":"poolmigo-keeper","tick":1,"dryRun":true,"budgets":[{"token":"0x5FbDB2315678afecb367f032d93F642f64180aa3","idle":"21791000000","inAdapters":"84464000000","total":"106255000000","targetIdle":"21251000000","excess":"540000000","tickCap":"53127500000","budget":"540000000"},{"token":"0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512","idle":"2358200000000000000","inAdapters":"8892800000000000000","total":"11251000000000000000","targetIdle":"2250200000000000000","excess":"108000000000000000","tickCap":"5625500000000000000","budget":"108000000000000000"}],"plans":[{"adapter":"0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9","amountsByToken":[{"token":"0x5FbDB2315678afecb367f032d93F642f64180aa3","amount":"270000000"},{"token":"0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512","amount":"54000000000000000"}]},{"adapter":"0x5FC8d32690cc91D4c39d9d3abcBD16989F875707","amountsByToken":[{"token":"0x5FbDB2315678afecb367f032d93F642f64180aa3","amount":"270000000"},{"token":"0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512","amount":"54000000000000000"}]}],"skipped":[]}
{"ts":"2026-09-22T12:12:27.488Z","level":"info","msg":"simulated deployTo","svc":"poolmigo-keeper","tick":1,"dryRun":true,"adapter":"0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9","amountsByToken":[{"token":"0x5FbDB2315678afecb367f032d93F642f64180aa3","amount":"270000000"},{"token":"0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512","amount":"54000000000000000"}],"gasEstimate":"191325"}
{"ts":"2026-09-22T12:12:27.488Z","level":"info","msg":"DRY RUN — not sending deployTo","svc":"poolmigo-keeper","tick":1,"dryRun":true,"adapter":"0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9","amountsByToken":[{"token":"0x5FbDB2315678afecb367f032d93F642f64180aa3","amount":"270000000"},{"token":"0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512","amount":"54000000000000000"}]}
{"ts":"2026-09-22T12:12:27.490Z","level":"info","msg":"simulated deployTo","svc":"poolmigo-keeper","tick":1,"dryRun":true,"adapter":"0x5FC8d32690cc91D4c39d9d3abcBD16989F875707","amountsByToken":[{"token":"0x5FbDB2315678afecb367f032d93F642f64180aa3","amount":"270000000"},{"token":"0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512","amount":"54000000000000000"}],"gasEstimate":"191337"}
{"ts":"2026-09-22T12:12:27.490Z","level":"info","msg":"DRY RUN — not sending deployTo","svc":"poolmigo-keeper","tick":1,"dryRun":true,"adapter":"0x5FC8d32690cc91D4c39d9d3abcBD16989F875707","amountsByToken":[{"token":"0x5FbDB2315678afecb367f032d93F642f64180aa3","amount":"270000000"},{"token":"0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512","amount":"54000000000000000"}]}
{"ts":"2026-09-22T12:12:27.491Z","level":"info","msg":"simulated rebalance","svc":"poolmigo-keeper","tick":1,"dryRun":true,"gasEstimate":"92415"}
{"ts":"2026-09-22T12:12:27.491Z","level":"info","msg":"DRY RUN — not sending rebalance","svc":"poolmigo-keeper","tick":1,"dryRun":true}
{"ts":"2026-09-22T12:12:27.492Z","level":"info","msg":"tick complete","svc":"poolmigo-keeper","tick":1,"dryRun":true,"ok":true,"deployed":0,"simulated":2,"failed":0,"rebalance":"simulated"}
EXIT=0
```

(Only the key in the shell line is redacted. `0x5FbDB…0aa3` is mUSDG (6dp), `0xe7f1…0512` is mWETH
(18dp). Chain state differs from §3.4 because this run was taken after the test suite; each block
is internally consistent.)

Arithmetic check on the USDG line: total 106,255,000,000; target idle 20% = 21,251,000,000; idle is
21,791,000,000, so excess = 540,000,000; the 50% tick cap of 53,127,500,000 does not bind; budget
540,000,000 split equally over two adapters = 270,000,000 each. ✔ And nothing was sent: two
`DRY RUN — not sending deployTo` lines plus `DRY RUN — not sending rebalance`.

### 3.4 Real executing tick — `deployTo` x2 + `rebalance`, with independent read-back

Fees were first seeded on both mock adapters (`simulateFees` is permissionless on the mock), then a
pre-state snapshot taken with `cast` — i.e. NOT through the service:

```
$ cast send 0xDc64...F6C9 "simulateFees(uint256[])" "[400000000,80000000000000000]"   # v3: 400 mUSDG, 0.08 mWETH
v3 simulateFees tx 0x4a4ae4681a6e5d5be99fb3c04afcb45a9fa9361bd18674d6c759cb945f1a0882 status 0x1
$ cast send 0x5FC8...5707 "simulateFees(uint256[])" "[200000000,40000000000000000]"   # v4: 200 mUSDG, 0.04 mWETH
v4 simulateFees tx 0x4bd5073467da0f2a732a53ccf1a5a8132ef197e145f38195d02ed6e2542642bc status 0x1

=== pre-state (cast) ===
idle USDG     : 21791000000
idle WETH     : 2358200000000000000
posV3         : [59654000000, 6430800000000000000]
posV4         : [25410000000, 2582000000000000000]
treasury USDG : 900695000000
treasury WETH : 490139000000000000000
```

The tick, verbatim and unedited (only the key in the shell line is redacted):

```
$ KEEPER_PRIVATE_KEY=0x59c6...690d STATE_FILE=/tmp/kexec2.json node dist/cli.js tick --execute
{"ts":"2026-09-22T12:13:27.870Z","level":"info","msg":"starting","svc":"poolmigo-keeper","command":"tick","effectiveDryRun":false,"config":{"rpcUrl":"http://127.0.0.1:8547","chainId":46630,"vault":"0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9","dryRun":true,"tickIntervalSec":60,"rebalanceIntervalSec":86400,"targetIdleBps":2000,"maxDeployPerTickBps":5000,"adapterWeights":"equal","minDeployDefault":"0","minDeployByToken":{},"stateFile":"/tmp/kexec2.json","logLevel":"info","confirmations":1,"keeperAddressOverride":null,"signer":"configured"}}
{"ts":"2026-09-22T12:13:27.903Z","level":"info","msg":"preflight ok","svc":"poolmigo-keeper","keeper":"0x70997970C51812dc3A010C7d01b50e0d17dc79C8","vault":"0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9","chainId":46630,"signer":"present"}
{"ts":"2026-09-22T12:13:27.910Z","level":"info","msg":"observed vault","svc":"poolmigo-keeper","tick":1,"dryRun":false,"block":"60","paused":false,"performanceFeeBps":1000,"treasury":"0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266","tokens":["0x5FbDB2315678afecb367f032d93F642f64180aa3","0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512"],"idle":["21791000000","2358200000000000000"],"adapters":[{"address":"0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9","tokens":["0x5FbDB2315678afecb367f032d93F642f64180aa3","0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512"],"amounts":["59654000000","6430800000000000000"]},{"address":"0x5FC8d32690cc91D4c39d9d3abcBD16989F875707","tokens":["0x5FbDB2315678afecb367f032d93F642f64180aa3","0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512"],"amounts":["25410000000","2582000000000000000"]}]}
{"ts":"2026-09-22T12:13:27.910Z","level":"info","msg":"policy decision","svc":"poolmigo-keeper","tick":1,"dryRun":false,"budgets":[{"token":"0x5FbDB2315678afecb367f032d93F642f64180aa3","idle":"21791000000","inAdapters":"85064000000","total":"106855000000","targetIdle":"21371000000","excess":"420000000","tickCap":"53427500000","budget":"420000000"},{"token":"0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512","idle":"2358200000000000000","inAdapters":"9012800000000000000","total":"11371000000000000000","targetIdle":"2274200000000000000","excess":"84000000000000000","tickCap":"5685500000000000000","budget":"84000000000000000"}],"plans":[{"adapter":"0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9","amountsByToken":[{"token":"0x5FbDB2315678afecb367f032d93F642f64180aa3","amount":"210000000"},{"token":"0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512","amount":"42000000000000000"}]},{"adapter":"0x5FC8d32690cc91D4c39d9d3abcBD16989F875707","amountsByToken":[{"token":"0x5FbDB2315678afecb367f032d93F642f64180aa3","amount":"210000000"},{"token":"0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512","amount":"42000000000000000"}]}],"skipped":[]}
{"ts":"2026-09-22T12:13:27.913Z","level":"info","msg":"simulated deployTo","svc":"poolmigo-keeper","tick":1,"dryRun":false,"adapter":"0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9","amountsByToken":[{"token":"0x5FbDB2315678afecb367f032d93F642f64180aa3","amount":"210000000"},{"token":"0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512","amount":"42000000000000000"}],"gasEstimate":"191325"}
{"ts":"2026-09-22T12:13:31.926Z","level":"info","msg":"deployTo confirmed","svc":"poolmigo-keeper","tick":1,"dryRun":false,"adapter":"0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9","amountsByToken":[{"token":"0x5FbDB2315678afecb367f032d93F642f64180aa3","amount":"210000000"},{"token":"0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512","amount":"42000000000000000"}],"txHash":"0x04eb91acdefbd9d3c12b4c9483caa40b4cbcf0afd534c2adcbbe4473e3ae0af1","block":"61","gasUsed":"151034"}
{"ts":"2026-09-22T12:13:31.927Z","level":"info","msg":"post-condition verified","svc":"poolmigo-keeper","tick":1,"dryRun":false,"adapter":"0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9","amountsByToken":[{"token":"0x5FbDB2315678afecb367f032d93F642f64180aa3","amount":"210000000"},{"token":"0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512","amount":"42000000000000000"}],"txHash":"0x04eb91acdefbd9d3c12b4c9483caa40b4cbcf0afd534c2adcbbe4473e3ae0af1"}
{"ts":"2026-09-22T12:13:31.930Z","level":"info","msg":"simulated deployTo","svc":"poolmigo-keeper","tick":1,"dryRun":false,"adapter":"0x5FC8d32690cc91D4c39d9d3abcBD16989F875707","amountsByToken":[{"token":"0x5FbDB2315678afecb367f032d93F642f64180aa3","amount":"210000000"},{"token":"0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512","amount":"42000000000000000"}],"gasEstimate":"185648"}
{"ts":"2026-09-22T12:13:35.942Z","level":"info","msg":"deployTo confirmed","svc":"poolmigo-keeper","tick":1,"dryRun":false,"adapter":"0x5FC8d32690cc91D4c39d9d3abcBD16989F875707","amountsByToken":[{"token":"0x5FbDB2315678afecb367f032d93F642f64180aa3","amount":"210000000"},{"token":"0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512","amount":"42000000000000000"}],"txHash":"0xc0c2ec6311eae89f5756e362b6435e510fc93c0f012191726370345bf53f2408","block":"62","gasUsed":"146564"}
{"ts":"2026-09-22T12:13:35.943Z","level":"info","msg":"post-condition verified","svc":"poolmigo-keeper","tick":1,"dryRun":false,"adapter":"0x5FC8d32690cc91D4c39d9d3abcBD16989F875707","amountsByToken":[{"token":"0x5FbDB2315678afecb367f032d93F642f64180aa3","amount":"210000000"},{"token":"0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512","amount":"42000000000000000"}],"txHash":"0xc0c2ec6311eae89f5756e362b6435e510fc93c0f012191726370345bf53f2408"}
{"ts":"2026-09-22T12:13:35.947Z","level":"info","msg":"simulated rebalance","svc":"poolmigo-keeper","tick":1,"dryRun":false,"gasEstimate":"179338"}
{"ts":"2026-09-22T12:13:39.963Z","level":"info","msg":"rebalance confirmed","svc":"poolmigo-keeper","tick":1,"dryRun":false,"txHash":"0x748622120c0928b0c9e99d483a3904d6cde0619812ac61a82cb9efd6a731f584","block":"63","gasUsed":"157839","harvested":[{"token":"0x5FbDB2315678afecb367f032d93F642f64180aa3","amount":"600000000","fee":"60000000"},{"token":"0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512","amount":"120000000000000000","fee":"12000000000000000"}]}
{"ts":"2026-09-22T12:13:39.965Z","level":"info","msg":"tick complete","svc":"poolmigo-keeper","tick":1,"dryRun":false,"ok":true,"deployed":2,"simulated":0,"failed":0,"rebalance":"sent"}
EXIT=0
```

`post-condition verified` is emitted by the service itself: after each transaction it re-reads
`adapter.position()` and confirms the delta equals the intent exactly. A mismatch would instead be a
`WARN` carrying per-token `expected` / `observed` / `delta`.

Independent verification afterwards with `cast`, again not through the service:

```
=== post-state (cast) ===
idle USDG     : 21911000000
idle WETH     : 2382200000000000000
posV3         : [59464000000, 6392800000000000000]
posV4         : [25420000000, 2584000000000000000]
treasury USDG : 900755000000
treasury WETH : 490151000000000000000
harvestable left v3 (USDG,WETH): 0 0
harvestable left v4 (USDG,WETH): 0 0
vault->v3 allowance USDG/WETH : 0 / 0
vault->v4 allowance USDG/WETH : 0 / 0
```

Every figure reconciles:

| Quantity | Expected | Observed |
| --- | --- | --- |
| posV3 USDG | 59,654,000,000 + 210,000,000 deployed - 400,000,000 harvested | **59,464,000,000** OK |
| posV3 WETH | 6.4308e18 + 0.042e18 - 0.08e18 | **6.3928e18** OK |
| posV4 USDG | 25,410,000,000 + 210,000,000 - 200,000,000 | **25,420,000,000** OK |
| posV4 WETH | 2.582e18 + 0.042e18 - 0.04e18 | **2.584e18** OK |
| idle USDG | 21,791,000,000 - 420,000,000 + 600,000,000 - 60,000,000 fee | **21,911,000,000** OK |
| idle WETH | 2.3582e18 - 0.084e18 + 0.12e18 - 0.012e18 | **2.3822e18** OK |
| **treasury USDG delta** | 10% of 600,000,000 harvested = **60,000,000** | 900,755,000,000 - 900,695,000,000 = **60,000,000** OK |
| **treasury WETH delta** | 10% of 0.12e18 = **0.012e18** | 490.151e18 - 490.139e18 = **0.012e18** OK |

Harvest totals match the seed exactly (400 + 200 = 600 mUSDG; 0.08 + 0.04 = 0.12 mWETH), nothing
harvestable is left behind, and the vault holds **zero standing allowance** to either adapter
afterwards. `performanceFeeBps()` was read on-chain as `1000` (10%) and appears in the
`observed vault` line above, as the brief states.

State file written by that tick:

```json
{
  "version": 1,
  "lastTickAt": 1790079219,
  "lastSuccessfulTickAt": 1790079219,
  "lastRebalanceAt": 1790079219,
  "lastRebalanceTx": {
    "hash": "0x748622120c0928b0c9e99d483a3904d6cde0619812ac61a82cb9efd6a731f584",
    "at": 1790079219
  },
  "lastDeployTxs": [
    {
      "hash": "0x04eb91acdefbd9d3c12b4c9483caa40b4cbcf0afd534c2adcbbe4473e3ae0af1",
      "at": 1790079211,
      "adapter": "0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9"
    },
    {
      "hash": "0xc0c2ec6311eae89f5756e362b6435e510fc93c0f012191726370345bf53f2408",
      "at": 1790079215,
      "adapter": "0x5FC8d32690cc91D4c39d9d3abcBD16989F875707"
    }
  ],
  "tickCount": 1,
  "lastError": null
}
```

### 3.5 Loop mode, state persistence, graceful SIGTERM

`TICK_INTERVAL_SEC=2`, SIGTERM sent after ~5 seconds. Lines filtered to the heartbeat and shutdown
(the full observe/plan/simulate lines repeat per tick and are omitted for length):

```
$ STATE_FILE=/tmp/kloop2.json TICK_INTERVAL_SEC=2 LOG_LEVEL=debug node dist/cli.js run &   # SIGTERM after 5s
{"ts":"2026-09-22T12:14:24.742Z","level":"info","msg":"preflight ok","svc":"poolmigo-keeper","keeper":"0x70997970C51812dc3A010C7d01b50e0d17dc79C8","vault":"0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9","chainId":46630,"signer":"present"}
{"ts":"2026-09-22T12:14:24.754Z","level":"info","msg":"tick complete","svc":"poolmigo-keeper","tick":1,"dryRun":true,"ok":true,"deployed":0,"simulated":2,"failed":0,"rebalance":"simulated"}
{"ts":"2026-09-22T12:14:24.754Z","level":"debug","msg":"sleeping until next tick","svc":"poolmigo-keeper","delayMs":2000,"consecutiveFailures":0}
{"ts":"2026-09-22T12:14:26.775Z","level":"info","msg":"tick complete","svc":"poolmigo-keeper","tick":2,"dryRun":true,"ok":true,"deployed":0,"simulated":2,"failed":0,"rebalance":"simulated"}
{"ts":"2026-09-22T12:14:26.775Z","level":"debug","msg":"sleeping until next tick","svc":"poolmigo-keeper","delayMs":2000,"consecutiveFailures":0}
{"ts":"2026-09-22T12:14:28.799Z","level":"info","msg":"tick complete","svc":"poolmigo-keeper","tick":3,"dryRun":true,"ok":true,"deployed":0,"simulated":2,"failed":0,"rebalance":"simulated"}
{"ts":"2026-09-22T12:14:28.799Z","level":"debug","msg":"sleeping until next tick","svc":"poolmigo-keeper","delayMs":2000,"consecutiveFailures":0}
{"ts":"2026-09-22T12:14:29.646Z","level":"info","msg":"shutdown requested — finishing in-flight work","svc":"poolmigo-keeper","reason":"SIGTERM"}
{"ts":"2026-09-22T12:14:29.646Z","level":"info","msg":"loop stopped","svc":"poolmigo-keeper"}
EXIT=0
```

```json
{
  "version": 1,
  "lastTickAt": 1790079268,
  "lastSuccessfulTickAt": 1790079268,
  "lastRebalanceAt": null,
  "lastRebalanceTx": null,
  "lastDeployTxs": [],
  "tickCount": 3,
  "lastError": null
}
```

Three ticks ran on the 2-second interval, SIGTERM was acknowledged rather than swallowed, the
in-flight work was allowed to finish, and the process exited 0. `tickCount: 3` shows the state
survived across ticks; that a fresh process resumes from the file is covered separately in
`state.test.ts` ("survives a restart: the state file is what the next process reads").

### 3.6 Exit codes and failure handling (all observed, not inferred from the code)

```
$ TARGET_IDLE_BPS=99999 node dist/cli.js tick
{"ts":"2026-09-22T12:14:41.696Z","level":"error","msg":"configuration error","svc":"poolmigo-keeper","errName":"ConfigError","errMsg":"TARGET_IDLE_BPS must be in [0, 10000], got 99999"}
EXIT=2

$ KEEPER_ADDRESS=0xa0Ee7A142d267C1f36714E4a8F75612F20a79720 node dist/cli.js tick    # anvil #9, not a keeper
{"ts":"2026-09-22T12:14:41.832Z","level":"error","msg":"preflight failed","svc":"poolmigo-keeper","errName":"PreflightError","errMsg":"0xa0Ee7A142d267C1f36714E4a8F75612F20a79720 is not an authorised keeper on vault 0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9 — the vault owner must call setKeeper(address,true). Refusing to run."}
EXIT=3

$ RPC_URL=http://127.0.0.1:59999 RPC_MAX_RETRIES=2 RPC_BACKOFF_BASE_MS=50 node dist/cli.js tick
{"ts":"2026-09-22T12:14:42.214Z","level":"warn","msg":"rpc call failed, backing off","svc":"poolmigo-keeper","op":"getChainId","attempt":1,"maxRetries":2,"delayMs":27,...}
{"ts":"2026-09-22T12:14:42.403Z","level":"warn","msg":"rpc call failed, backing off","svc":"poolmigo-keeper","op":"getChainId","attempt":2,"maxRetries":2,"delayMs":93,...}
{"ts":"2026-09-22T12:14:42.657Z","level":"error","msg":"fatal","svc":"poolmigo-keeper",...}
EXIT=1
```

(The `...` marks where the error detail fields were trimmed for width; nothing else is edited.)
The delays show exponential growth with full jitter: attempt 1 drew 27ms from [25, 50], attempt 2
drew 93ms from [50, 100]. Contract reverts are deliberately **not** retried — `isRetryable` treats a
revert as a deterministic answer from the chain rather than a blip; unit-tested in `chain.test.ts`.

### 3.7 `status` is genuinely read-only

```
$ STATE_FILE=/tmp/kstatus2.json node dist/cli.js status
{"ts":"2026-09-22T12:14:43.555Z","level":"info","msg":"status","svc":"poolmigo-keeper","block":"63","paused":false,"plannedDeploys":2,"rebalance":{"due":true,"outcome":"simulated"},"state":{"version":1,"lastTickAt":null,"lastSuccessfulTickAt":null,"lastRebalanceAt":null,"lastRebalanceTx":null,"lastDeployTxs":[],"tickCount":0,"lastError":null}}

$ ls /tmp/kstatus2.json
ls: /tmp/kstatus2.json: No such file or directory
```

No state file was created. That matters because `status` is the container `HEALTHCHECK`, and a
health probe must not be able to move the keeper's scheduling state.

### 3.8 Docker runtime stage, simulated outside Docker

Docker itself is unavailable here (see Limitations), so the runtime stage's two load-bearing steps
were reproduced by hand in an empty directory holding only `package.json`, `package-lock.json` and
`dist/` — i.e. exactly what the image's final layer contains, with no `../shared` in reach:

```
$ cd /tmp/runtime-sim && npm ci --omit=dev --omit=optional
found 0 vulnerabilities

$ ls node_modules
@adraffy  @noble  @scure  abitype  eventemitter3  isows  ox  viem  ws

$ du -sh node_modules
 75M	node_modules

$ VAULT_ADDRESS=0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9 RPC_URL=http://127.0.0.1:8547 CHAIN_ID=46630 \
    KEEPER_ADDRESS=0x70997970C51812dc3A010C7d01b50e0d17dc79C8 node dist/cli.js status
{"ts":"2026-09-22T12:15:57.018Z","level":"info","msg":"preflight ok","svc":"poolmigo-keeper","keeper":"0x70997970C51812dc3A010C7d01b50e0d17dc79C8","vault":"0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9","chainId":46630,"signer":"absent"}
{"ts":"2026-09-22T12:15:57.029Z","level":"info","msg":"status","svc":"poolmigo-keeper","block":"67","paused":false,"plannedDeploys":2,"rebalance":{"due":true,"outcome":"simulated"},"state":{…}}
EXIT=0
```

So: the compiled `dist/` runs standalone on production dependencies only, reads its addresses from
explicit env with no deployment file present, the signer-less (`KEEPER_ADDRESS`-only) mode works,
and the `HEALTHCHECK` command exits 0. Plain `--omit=dev` was dropped in favour of
`--omit=dev --omit=optional` after this check showed `typescript` (an optional peer of `viem`)
landing in the runtime tree.

### 3.9 Nothing outside `backend/` was touched

```
$ git status --porcelain | grep -v '^?? backend/'
(no output)
```

---

## 4. Decisions

1. **ABIs are generated into a committed `src/abi/generated.ts`.** `shared/abis/` stays the source
   of truth, but the Docker build context is `backend/` and must not reach outside it. The generator
   also *narrows* the ABI to the keeper's own surface, which turns "the keeper must not call owner
   functions" from a convention into a compile error.
2. **`MAX_DEPLOY_PER_TICK_BPS` denominated in per-token total, not idle.** Rationale in §1 and in
   the `policy.ts` header. The brief did not specify the denominator; this is the choice that makes
   the cap behave stably across vault states.
3. **Per-token weight renormalisation.** Only adapters reporting a token share that token's budget.
4. **Signer-less mode (`KEEPER_ADDRESS` alone).** A dry-run monitor should not need a key at all;
   simulations only need a `from` address. Without this, "run a read-only watcher" would have forced
   a key onto a process that must never send.
5. **`status` does not persist.** Added after wiring it as the Docker `HEALTHCHECK` — a probe that
   silently incremented `tickCount` would have been a subtle bug.
6. **Brief's tick order kept (deploy, then harvest).** Harvesting first would let the tick deploy
   the freshly harvested fees immediately instead of next tick. That is arguably better, but it is a
   strategy change, so it stays as specified; noted here as an option for whoever owns the strategy.
7. **Post-condition mismatch is a WARN, not a failure.** A real Uniswap adapter will legitimately
   deploy less than offered (ratio adjustment), and fees accrue between the two reads. Failing the
   tick on that would make the service unusable with real adapters. It is loud, with full per-token
   detail.
8. **`vitest` pinned to `^5.0.1`.** The natural `^2` pin installs a dev tree reporting
   `5 vulnerabilities (3 moderate, 1 high, 1 critical)` (vite / esbuild / @vitest/mocker).
   `npm audit` is now clean at every level, dev included.
9. **`npm ci --omit=dev --omit=optional` in the Docker runtime stage.** `viem` declares `typescript`
   as an optional peer, and plain `--omit=dev` pulls the whole compiler into the runtime image.
   Verified (see §3.9) that the service still runs without it.

## 5. Limitations

- **Docker was NOT tested.** `docker` is not installed on this machine (`docker --version` →
  `command not found`), so `Dockerfile` and `docker-compose.yml` are written and reviewed but the
  image was never built. The runtime stage's substance was reproduced by hand instead (§3.8:
  prod-only `npm ci`, `dist/` running standalone with no `../shared`, the healthcheck command
  exiting 0), so the parts most likely to be wrong are covered — but layer ordering, the
  `node:20-alpine` base, the non-root `USER node` + volume ownership, and the compose wiring are
  unverified. Someone with Docker should run `docker compose build` plus the dry-run smoke command
  from the README before treating this as deployable.
- **The integration tests mutate the local anvil.** That is inherent to "perform one real execute"
  — they sent `deployTo` and `rebalance` transactions and seeded mock fees. The demo stack's
  originally seeded fees (250/0.05 on V3, 100/0.02 on V4) have therefore been harvested, and idle
  balances have shifted from the values `DemoLocal.s.sol` left behind. The stack is otherwise
  intact and fully functional; re-run `DemoLocal.s.sol` against a fresh anvil if a pristine state is
  wanted. The tests refuse to run against anything that is not a local RPC on chain 46630.
- **No remote-signer / KMS integration.** Documented as the preferred production option and
  scoped (a viem custom `Account` in `src/chain.ts`), but not implemented.
- **No nonce management or tx replacement.** Transactions are sent one at a time and awaited, which
  is correct for a single keeper process on a low-throughput chain. A stuck transaction at
  `TX_TIMEOUT_SEC` is reported and the tick ends; there is no automatic fee bump / replacement, and
  two keeper processes sharing one key would conflict. Both are worth adding before mainnet.
- **No metrics endpoint.** Monitoring is via structured logs and exit codes (documented in the
  README). A `/metrics` exporter was out of scope.
- **The strategy is plumbing, not alpha.** Stated plainly at the top of the README. `src/policy.ts`
  is isolated and pure precisely so it can be replaced wholesale.
- **The graceful-skip path of the integration suite** was verified by unit-testing its guard
  (`isStackReachable` with a stubbed `fetch`, in `test/unit/guards.test.ts`) rather than by taking
  the shared anvil down.

## 6. Requested upstream changes

None are required — the service works against the contracts as they stand. Two observations for
whoever owns `contracts/`:

1. **`deployTo` emits `Deployed(keeper, adapter, tokens, amounts)` with the amounts the vault
   *approved*, not the amounts the adapter actually pulled.** `IPositionAdapter.deploy` returns
   `(tokens, deployed)`, and `MockPositionAdapter` can already return less than offered; a real
   Uniswap adapter routinely will (ratio adjustment). The keeper therefore cannot trust the event
   for reconciliation and re-reads `position()` instead. Emitting the adapter's returned `deployed`
   vector would make the event self-sufficient. Low priority, but it would simplify every indexer
   and monitor downstream.
2. **`adapters()` order is not stable across `removeAdapter`** (swap-and-pop). This is fine and
   documented behaviour; the keeper defends against it by recommending address-keyed
   `ADAPTER_WEIGHTS` and by rejecting a stale positional list. Worth a line in the contract's natspec
   so the next integrator does not index into it.

Neither blocks anything.
