# TASK_DEPOSIT-DEPLOY — deposit 內的原子比例部署（T2d）

- **Status**: ready to implement (2026-10-08). Branch: `feat/deposit-deploy` (do NOT push; do NOT merge main).
- **Owner decision (D)**: `deposit()` 內原子比例部署；部署失敗 → **整筆 deposit revert**（不留 idle 的 best-effort 逃生門）。
- **分配政策（定案）**: 每個 registry token 按「各 adapter 對該代幣的現持有量」比例 split；floor；dust 留 idle；全零向量 adapter 跳過；無任何持有者（bootstrap）→ 留 idle。
- **誰做什麼**: 實作＋forge 測試＋CI＋腳本＋報告草稿＝本工單（Claude Code）。**本地鏈實測由 assistant 於驗收後執行**（不在本工單範圍；不要 deploy 任何鏈）。

## 已量測的 size 參考（throwaway probe，僅供對照；實作必須照 repo 規範「重寫」，不可複製 probe 檔）

- 裸增量骨架 +1,153B（vault 25,366 / −790）。優化後 hook 版（未抽 splitter）25,071 / −495。
- **選定形狀 T2d**：split 數學抽到獨立 stateless 合約；vault 只留一次外部呼叫＋薄迴圈。
  - 實測：constant 位址 + metadata on = 24,565 / **+11**；immutable + metadata on = 24,597 / **−21**；metadata off（`cbor_metadata=false`）再 **−53B** ⇒ **immutable + metadata off ≈ 24,544 / +32**（本工單目標形狀；final 以實測為準）。
  - `DepositSplit` 獨立合約 ≈ 2.6 KB（自身無 EIP-170 壓力）。
- 拆分參考：扁平 header-framed 陣列＋就地讀取(−397) > 扁平複製(−217) > 巢狀陣列(比不抽還大)。**不可**回頭用巢狀回傳。
- 六個 public 常量**收 internal 不在範圍**（owner 決定保留 ABI）；`_skimPerformanceFee` 的長度檢查**保留**（不為 bytes 弱化檢查）。
- `MySunVaultUpgradeExample` fixture 維持「test-only documented exception」；CI sizes gate 改白名單制（見下）。
- 參考檔（read-only）：`/tmp/mysun-size`（T2d 形狀與量測腳本 `sz.sh`）、`/tmp/mysun-size-states/`（各狀態備份）。不可 import / 引入其中的檔案。

## 介面規格

### 新合約 `contracts/src/periphery/DepositSplit.sol`
- **stateless**：無 storage、無 owner、無 constructor 參數、不可升級。
- `function split(address[] calldata registry, uint256[] calldata required) external view returns (uint256[] memory flat)`：
  - 讀 `msg.sender`（vault）的 `adapters()` getter 與各 adapter 的 `position()`（staticcall 視圖語義即可）。
  - `denom_r = Σ_i adapters[i] 對 registry token r 的回報持有量`；`amount_ij = floor(required_r × a_ij / denom_r)`；未在 registry 的 token 讀 0；`denom_r == 0` → 0。
  - 回傳 **一條扁平向量**：依 adapter 序（＝ registry 序）每個 adapter `[n_i | 0][amounts_i…]`（n_i = 該 adapter 的 token 數；全零 → 單一 `0` 字）；結尾以 `mstore` 截斷長度。
  - 防禦：`required.length != registry.length` → revert（自訂 error）。
- 命名/註解照 repo 風格；檔頭 natspec 說明「why stateless callee」與信任邊界（只決定金額；批准仍由 vault 自讀 `position()`）。

### Vault 變更 `contracts/src/PoolmigoVaultUpgradeable.sol`（＋子類）
- 增加 `constructor(address depositSplit_)` 設定 `DepositSplit` **immutable**；依 OZ plugin 要求處理 constructor 版面（必要時 `@custom:oz-upgrades-unsafe-allow constructor`）；跑 `Upgrades.validateImplementation` 確認可過。
- `deposit()`：mint 後呼叫 `_deployDeposit(tokens_, required)`；任何失敗一律 bubble（**嚴格 revert**）。
- `_deployDeposit`：一次 `DEPOSIT_SPLIT.split(tokens_, required)` → 以 `_s().adapters.length` 為上限走訪 frames（就地讀取，`assembly ("memory-safe")`＋註解說明不變式）→ 非零 slice 呼叫 `_deployInto` → 前進指標。
- 共用 helper：`_deployInto`（approve→deploy→revoke）＋`_revokeAll`；`deployTo` 改用同一 helper（行為不變）。
- **不新增 storage、不改既有函式簽名/ABI**；`previewDeposit`/`_previewDeposit` 完全不動。
- 觀察性：每個實際部署的 adapter 追加 `Deployed(msg.sender, adapter, t, amounts)`（與 `deployTo` 同事件）；**若 margin 掉到 < +16 則省略並在報告註記**。
- 所有 vault 子類/構造點（`MySunVaultUpgradeable`、fixtures `MySunVaultUpgradeExample` 等、scripts、tests）需帶入 splitter 位址；fixture 以自身 constructor 轉傳。

### 邊界（全部要有測試）
1. bootstrap：無 adapter 持有 → 全留 idle、不 revert。
2. adapter 對某 token 持有 0 → slice 0；全零 vector 跳過（含「部分 adapter 有、部分沒有」）。
3. 多 adapter 精確比例＋floor/dust 留 idle（2 個以上 adapter 的具體數字案例）。
4. **嚴格 revert**：任一 adapter `deploy` revert（guard/情境）→ 整筆 deposit revert（mint 回滾、餘額不變）。
5. splitter 單元＋fuzz：sum(amounts)=per-token ≤ required；未註冊 token 行為；`required.length` 防禦。單測需自備暴露 `adapters()` 的 harness（或直接穿 vault）。
6. invariant suites`VaultInvariants`/`PeripheryInvariants` 全綠；**只允許動 harness 管線**（若新路徑改變 handler 假設），斷言不得弱化。

## Build / CI / Scripts / 交付
- `contracts/foundry.toml` `[profile.default]`：加 `cbor_metadata = false` 與 `bytecode_hash = "none"`（註解寫明 size 預算理由）。
- `.github/workflows/ci.yml`：「Build (with sizes)」保留完整表（供 log；可 `|| true`）＋新步驟 `script/sizes-gate.sh`：**只擋「可部署合約」**（src/ 全部 deployable ＋ `DepositSplit`；`MySunVaultUpgradeExample` 等 test-only 豁免，yml 註解說明）。
- `contracts/script/sizes-gate.sh`：用 `forge build --sizes --json` 過濾白名單，任一 margin < 0 → fail（jq/awk 皆可；ubuntu runner 有 jq）。
- Scripts：`DeployDeterministic`、`UpgradeExample`、`DeployMySunVaultUpgradeable`、`DemoLocalFork` 等所有構造點更新；新增/擴充 periphery 部署步驟部署 `DepositSplit`（`DeployPeriphery.s.sol` 或新 script）；`shared/abis` 若流程會再生成（`script/export-abis.sh`）就跑，constructor 進 ABI 屬 artifact 變更，報告註明。
- 測試全家桶：`forge clean && forge build` → `forge fmt --check` → `forge test --no-match-path 'test/fork/*'`（全綠）；報告附 sizes 表（`forge build --sizes` 過濾 vault/fixture/DepositSplit）＋測試總數。
- 交付物：`contracts/REPORT-DEPOSIT-DEPLOY.md`（草稿：變更摘要、實測 sizes 表、測試數、已知注意點如 assembly 解碼/信任邊界）＋ branch 上 2–4 個乾淨 commit（訊息照 repo 風格 `feat(deposit): …`）。
- **硬約束**：不 deploy、不碰私鑰/keystore、不 push、不動 main、不改 optimizer_runs（100 為 pinned）、plugin-using 前必 `forge clean && forge build`、CI 預算（非 fork 全套）≤ ~5 分鐘。
