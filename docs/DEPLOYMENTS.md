# MySun — Robinhood Chain 部署地址

供 integrators、indexers 與 dashboards 使用。以下為 Robinhood Chain（Arbitrum Orbit，chain ID
`4663` / `0x122b`）上的 MySun rehearsal deployment。

> **尚未審計，也不是 production deployment；不要用於真實資金。** 本頁於 2026-10-12 透過公開 RPC
> 核對；核對時 RPC 回報區塊 `86,447,908`。Vault 的 `tokens()`、`adapters()` 與 EIP-1967
> implementation slot 以鏈上讀值為準。整合前請重新讀取，因為 proxy implementation 與 adapter 清單可能改變。

`shared/deployments.json` 是 frontend／keeper backend 使用的 chain、vault 與 periphery registry；本頁補充
token、adapter、executor 與 venue 地址。兩處重複欄位應保持一致。本頁只列整合所需地址，不列內部操作角色。

- Explorer：<https://robinhoodchain.blockscout.com>
- RPC：<https://robinhood.drpc.org>
- Network：Robinhood Chain mainnet — chain ID `4663`

## Tokens

| Token | Address | Decimals |
|---|---|---|
| PONS | `0x39dBED3a2bd333467115dE45665cC57F813C4571` | 18 |
| USDG | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` | 6 |
| WETH | `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` | 18 |

## Vaults

Receipt tokens 為 ERC-20、18 decimals；每個 vault 的 name／symbol 在初始化時設定。

### sunEthLP — basket `[USDG, WETH]`

- Vault (UUPS proxy): `0x6767257AAFfCE82f6ba4B6E96EDBa80e9e1112FC`
- Implementation（current EIP-1967 slot）：`0x1b8a02FeF41cAA651a6C275d859D1950e08605E8`
- Basket order（鏈上 `tokens()`）：`[USDG, WETH]`
- Adapters（鏈上 `adapters()` 順序；2026-10-19 移除 3 顆空的 V3 placeholder 後 → 6）：
  - `0xAdEC6dD17ecdaCB51676f745883a620CCf390Ab7` — V4 native-ETH（ETH/USDG）
  - `0xCC7A750507DCCDa8f76728Fb412BbAc6Ba04be7B` — V4 native-ETH（ETH/USDG）
  - `0xd06Ce50C9a57999ec225A4BC2215410b8A3c41e8` — V4 native-ETH（ETH/USDG）
  - `0x66181c9043d56C2A524192920e4F476E683E284e` — V4 native-ETH（ETH/USDG）
  - `0x282CaF98CFEB0B4cA624A39B8910248963b9D517` — V4 native-ETH（ETH/USDG）
  - `0x03B2FeE013D5A4769e2d44c9EB320dd8b3d74786` — V4 native-ETH（ETH/USDG）

### sunPonsLP — basket `[USDG, PONS]`

- Vault (UUPS proxy): `0x0621252C87307Ed4F07a644F1Ad3a7bb7340c35f`
- Implementation（current EIP-1967 slot）：`0x8bd16efce86b7bacd2c3d3184f6e10e0ad1c6f60`
- Basket order（鏈上 `tokens()`）：`[USDG, PONS]`
- DepositSplit helper（stateless）：`0xe4339d8787296AAf206C1590E4A909cCabE766C1`
- Adapters（鏈上 `adapters()` 順序；issue-8 換血後，2026-10-19；全 V4 hooked PONS/USDG）：
  - `0x04D9b0701d980D9d2cA779BDaa60240b0cFa0e75`
  - `0x62B0E69D798FeD6FCcEe98d5fa92371B585D6Da3`
  - `0xC5E09EC720758753B2f18329052b6B82fd2a6989`
  - `0xed152FD5a70981847c727B82447FFe05Cf72B388`
  - `0x7D2BD9F190026778C64CF9dd24B717D2b19e46a1`
  - `0xe431af961272C84E1F8c78396CA69BbAAF445Bd5`

### sunTriLP — basket `[USDG, WETH, PONS]`

- Vault (UUPS proxy): `0x4bbfd5c66e5df6cbebb3240027f9f8194bcebb98`
- Implementation（current EIP-1967 slot）：`0xfb2b8bb278ed4f794508fb1967be280dda03f020`
- Basket order（鏈上 `tokens()`）：`[USDG, WETH, PONS]`
- DepositSplit helper（stateless）：`0xe2fb4ad3751cacd756bccf5938e0d7b3bcd77a01`
- Adapters（鏈上 `adapters()` 順序；issue-8 換血後，2026-10-19；v4 全 FablesRamp 市場池）：
  - `0xFF484F98C018E541f4C27218597Ba7D12ED67210` — native-ETH（ETH/USDG）
  - `0xF9F883ca4B671a560D987E7d55997c98c7C4611d` — native-ETH（ETH/USDG）
  - `0x0bbDC0d9d892d0a590eDe11dFC6aEe38dC197727` — native-ETH（ETH/USDG）
  - `0x7C2FF6240Feb7634A56774DA72D68e67Ba27501e` — native-ETH（ETH/USDG）
  - `0x6469A4D085479422C3fFd471462B4BEa4fee82DD` — native-ETH（ETH/USDG）
  - `0x7f117DFdC555B40FF505D28D91ecB892111021f1` — native-ETH（ETH/USDG）
  - `0xfdFd5e885Dbd3bAC3997d45B8F629987e7C7b032` — native-ETH（ETH/USDG）
  - `0x8275Fe3A2B17D0099cB9e218EbBeA72724A595aA` — hooked（PONS/USDG）
  - `0xeECC49eb69aa1F85b37dc45cc3D0dA5265E8844e` — hooked（PONS/USDG）
  - `0xe90C772e2Ca3ee6bdce7B69764d596F99e91a2E5` — hooked（PONS/USDG）
  - `0x934Cf0BcA9438A706aCA5f396088bdD904c885e0` — hooked（PONS/USDG）
  - `0x8164200d30aD8e5435e56bDCCe6CbF1cd3cE1EbD` — hooked（PONS/USDG）
  - `0x0FB7a474ACC06D61B57cCE14d66a29E22E83188D` — hooked（PONS/USDG）
  - `0x6e606eCda979c774E7E90aD272f7F90dDE4b2A97` — native-ETH（ETH/PONS）
  - `0x6EBeeb97E36e599c273D0Bb2f0385980C6bc4294` — native-ETH（ETH/PONS）
  - `0x2CaF7Df4582e314fBb1539d1A09C175B7e6BbE1c` — native-ETH（ETH/PONS）
  - `0xEbF3d5C00F4bc03C7294BcE7564F4e3fF86553ec` — native-ETH（ETH/PONS）
  - `0xa7702970f9587be4E59948cB0993e0b450f0AAfE` — native-ETH（ETH/PONS）

## Periphery

| Artifact | Address |
|---|---|
| ZapIn (USDG-only deposits) | `0x8187691738907dCCBB34f6Aa82059CCF1Ae3870f` |
| ZapOut (single-token exits) | `0xd9151216e2Ab52b446aAb0207Ab34652b44D228C` |
| PlanExecutor (keeper plans) | `0xbE744F7685bd7fa6365B6519CE66DeDa71873139` (sunEthLP); sunPonsLP `0x792Efc2e0D59679390742203F664c67F9D02F8cA`; sunTriLP `0x4d6a45Aa30c2832bB88c9a24bBdD3aCAD7f1b31F` |
| Swap Executor (ERC-20, UniversalRouter) | `0x413a67ca4E83A4782F7745858979fE059ccbB431` |
| Native Swap Executor (v4 native) | `0x58452cf80a0819a75a3b94347f706280ccc03d04` |

## Venue & infrastructure

| Artifact | Address / ID |
|---|---|
| PoolManager (v4) | `0x8366a39CC670B4001A1121B8F6A443A643e40951` |
| PositionManager (POSM, v4) | `0x58daec3116aae6D93017bAAea7749052E8a04fA7` |
| Uniswap V3 Factory | `0x1f7d7550B1b028f7571E69A784071F0205FD2EfA` |
| FablesRamp hook — ETH/USDG | `0x06a889870C8f83640D6816319f72e2aA579b6080` |
| FablesRamp hook — PONS/USDG | `0x08E52564Bad99E05a694b4809F397edcA417A080` |
| V4 pool id — ETH/USDG | `0xbac3aa3b91584a53a579b3c999a56756e954e59247e497bad1d25a4334bde551` |
| V4 pool id — PONS/USDG | `0x486435a1f76cd58193f854c6e6213cd05fd58d637865d02065ff558b387fa6ea` |

## 整合注意事項

- 對 vault 互動請使用 **proxy address**；implementation 只供核對，升級後可能更換。
- Basket token 順序以鏈上 `tokens()` 為準，不要依 UI 標籤自行假設。
- `shared/deployments.json` 提供 app 使用的 chain、vault 與 periphery 設定；本頁補充 adapter、token 與 venue 地址。
- 本頁不列本機 demo chain（46630）的地址；其 RPC 是本機端點，demo stack 也可能重新部署。