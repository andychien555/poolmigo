# Deployments — Robinhood Chain (4663)

Live contract addresses for the MySun rehearsal stack on Robinhood Chain mainnet
(Arbitrum Orbit, chain id **4663** / `0x122b`). For integrators, indexers and dashboards.

**Source of truth**: `shared/deployments.json` (read by the frontend and the keeper backend).
This page is the human-readable mirror — regenerate or update it whenever a deployment changes.
All addresses can be verified on the public explorer; the table carries deployment artifacts only —
no credential material of any kind.

- Explorer: https://robinhoodchain.blockscout.com
- RPC: https://robinhood.drpc.org
- Chain: Robinhood Chain, mainnet — testnet `false`, status `deployed`

## Tokens

| Token | Address | Decimals |
|---|---|---|
| PONS | `0x39dBED3a2bd333467115dE45665cC57F813C4571` | 18 |
| USDG | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` | 6 |
| WETH | `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` | 18 |

## Vaults

Receipt tokens are ERC-20, 18 decimals, per-vault name/symbol (set at initialization).

### sunEthLP — basket `[USDG, WETH]`

- Vault (UUPS proxy): `0x6767257AAFfCE82f6ba4B6E96EDBa80e9e1112FC`
- Implementation: `0x1b8a02FeF41cAA651a6C275d859D1950e08605E8`
- Adapters:
  - Uniswap V3 ×3 (interim slots, currently unallocated):
    `0x00015d96e0A278d0bF53ebD2E217A58d85a1790B`,
    `0x26E6ceEE3C7c97a3A2bDbB273462A6d9712387d1`,
    `0x83AB318eEFc766bb7755B671F332d92b8CbdCEC3`
  - Uniswap V4 Native-ETH ×3 (live, ETH/USDG FablesRampETH pool):
    `0x32Db585E449154BD47b785D6F9929D7b3D78B7b4`,
    `0xa02Cfdf34093437E0AbBD449927844e777765dFd`,
    `0xD5fb0DEfE2545E779271e2E7B132816806fAf361`

### sunPonsLP — basket `[USDG, PONS]`

- Vault (UUPS proxy): `0x0621252C87307Ed4F07a644F1Ad3a7bb7340c35f`
- Implementation: `0x5af750fdf74e92fdfd4bcf24e8a576db0a8b5446`
- DepositSplit (stateless, shared): `0xe4339d8787296AAf206C1590E4A909cCabE766C1`
- Adapters (Uniswap V4 Hooked ×3 — PONS/USDG FablesRamp pool):
  - `0x2a487c436433341db8ec829670c27461dd4e50d6` (live)
  - `0x92e6e3a746181759564abe7a5e119082573b2824` (live)
  - `0x1a922561cbA3F0Def03E34e0d9D2F368DC29F856` (spare)

## Periphery

| Artifact | Address |
|---|---|
| ZapIn (USDG-only deposits) | `0x8187691738907dCCBB34f6Aa82059CCF1Ae3870f` |
| ZapOut (single-token exits) | `0xd9151216e2Ab52b446aAb0207Ab34652b44D228C` |
| PlanExecutor (keeper plans) | `0xbE744F7685bd7fa6365B6519CE66DeDa71873139` |
| Swap Executor (ERC-20, UniversalRouter) | `0x413a67ca4E83A4782F7745858979fE059ccbB431` |
| Native Swap Executor (v4 native) | `0x58452cf80a0819a75a3b94347f706280ccc03d04` |

## Venue & infrastructure

| Artifact | Address / ID |
|---|---|
| PoolManager (v4) | `0x8366a39CC670B4001A1121B8F6A443A643e40951` |
| Pool Operating State Manager (POSM) | `0x58daec3116aae6D93017bAAea7749052E8a04fA7` |
| Uniswap v3 adapter factory | `0x1f7d7550B1b028f7571E69A784071F0205FD2EfA` |
| FablesRamp hook — ETH/USDG | `0x06a889870C8f83640D6816319f72e2aA579b6080` |
| FablesRamp hook — PONS/USDG | `0x08E52564Bad99E05a694b4809F397edcA417A080` |
| V4 pool id — ETH/USDG | `0xbac3aa3b91584a53a579b3c999a56756e954e59247e497bad1d25a4334bde551` |
| V4 pool id — PONS/USDG | `0x486435a1f76cd58193f854c6e6213cd05fd58d637865d02065ff558b387fa6ea` |

## Roles (on-chain permission holders)

| Role | Address |
|---|---|
| Owner / treasury | `0x27447D6F3eCAA5f0c6b89a5b3D2FA03ff3392eaa` |
| Keeper (ops, both vaults + PlanExecutor) | `0x0856965c4A6346C5E33352A670CEb6E569DeF678` |
| Keeper (genesis stage) | `0x27447D6F3eCAA5f0c6b89a5b3D2FA03ff3392eaa` |

Owner == treasury == genesis keeper on the rehearsal stack; ownership migrates to a multisig
before production. Risk managers: none configured yet (owner-whitelisted role stays free for
incident-response services).

## Historical deployments

Retired artifacts are intentionally not listed. Previous sunPonsLP proxies (K-scale iterations)
and pre-upgrade implementations remain verifiable on-chain or in the repository's private docs.