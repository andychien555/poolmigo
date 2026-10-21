// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.34;

import {console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MySunVaultUpgradeable} from "contracts/MySunVaultUpgradeable.sol";
import {IPositionAdapter} from "contracts/interfaces/IPositionAdapter.sol";
import {TriPoolBase} from "./DemoTriPool.s.sol";

/**
 * @notice 3-token smoke test of the local `sunTriLP` vault (script/DemoTriPool.s.sol): deposit → keeper deployTo →
 *         redeem, on the LOCAL demo chain only. The depositor is anvil #4 (funded here by OWNER #201 — a wallet no
 *         FE/BE suite reads, and not the fee treasury, so the redeem's performance-fee cut is measured as a loss):
 *   1. deposit ≈ SMOKE_SHARES (default 10e18 ≈ $10 — demo scale, the genesis rule of contracts/AGENTS.md) worth of the basket, pro-rata to `totalTokens()` (+2% offered
 *      headroom; the vault pulls only `required`), minShares = 99% of the preview. The deposit itself fans out into
 *      the 18 adapters (DepositSplit) — every ratio swap included.
 *   2. keeper: `pullFrom(·, 50%)` on the first adapter of each pool, then `deployTo` the vault's whole idle back in
 *      equal slices over all 18 (each token over its 12 adapters) — the same blending as the genesis seed.
 *   3. redeem every minted share.
 * Asserts (in kind, per token; USDG value at the v3 reference spots is a DISPLAY yardstick only, as in the frontend):
 *   - supply math: the deposit's value / shares minted within 5% of 1 USDG per share (the K convention);
 *   - value conservation: redeemed value ≥ 97% of deposited value; each token's redeemed amount within 5% of its
 *     deposited amount (pool-ratio blending moves the legs a little — the legs are reported, the bound is loose).
 * Run (from contracts/; anvil #201 = OWNER key, LOCAL ONLY public test key):
 *   forge script script/DemoTriSmoke.s.sol --rpc-url http://127.0.0.1:8547 --broadcast --private-key $DEPLOYER_KEY
 */
contract DemoTriSmoke is TriPoolBase {
    using SafeERC20 for IERC20;

    uint256 internal constant DEFAULT_SMOKE_SHARES = 10e18;

    struct Run {
        MySunVaultUpgradeable vault;
        address user;
        address[] tokens;
        uint256[] offered;
        uint256[] required;
        uint256[] out;
        uint256 shares;
    }

    function run() external {
        require(block.chainid == EXPECTED_CHAIN_ID, "DemoTriSmoke: not the local demo chain (chain id)");
        Run memory r;
        r.vault = MySunVaultUpgradeable(_triVault());
        uint256 userKey = vm.deriveKey(TEST_MNEMONIC, 4);
        r.user = vm.addr(userKey);
        r.tokens = r.vault.tokens();
        require(r.tokens.length == 3, "tri vault is not a 3-token basket");
        uint256 target = vm.envOr("SMOKE_SHARES", DEFAULT_SMOKE_SHARES);
        uint256 supply0 = r.vault.totalSupply();
        (, uint256[] memory totals0) = r.vault.totalTokens();
        console2.log("vault / supply before :", address(r.vault), supply0);
        console2.log("USDG value per share (1e18 = 1 USDG):", _value(totals0) * 1e12 * 1e18 / supply0);

        // Offer pro-rata to the vault's basket (+2%); fund the smoke wallet from OWNER.
        r.offered = new uint256[](3);
        for (uint256 j; j < 3; ++j) {
            r.offered[j] = Math.mulDiv(totals0[j], target * 102, supply0 * 100) + 1;
        }
        vm.startBroadcast(OWNER);
        if (r.user.balance < 1 ether) payable(r.user).transfer(10 ether);
        for (uint256 j; j < 3; ++j) {
            uint256 have = IERC20(r.tokens[j]).balanceOf(r.user);
            if (have < r.offered[j]) IERC20(r.tokens[j]).safeTransfer(r.user, r.offered[j] - have);
        }
        vm.stopBroadcast();

        /* -------------------------------- 1. deposit (anvil #4) -------------------------------- */
        uint256 preview;
        (preview, r.required) = r.vault.previewDeposit(r.tokens, r.offered);
        vm.startBroadcast(userKey);
        for (uint256 j; j < 3; ++j) {
            IERC20(r.tokens[j]).forceApprove(address(r.vault), r.offered[j]);
        }
        r.shares = r.vault.deposit(r.tokens, r.offered, preview * 99 / 100, r.user);
        for (uint256 j; j < 3; ++j) {
            IERC20(r.tokens[j]).forceApprove(address(r.vault), 0);
        }
        vm.stopBroadcast();
        uint256 valueIn = _value(r.required);
        console2.log("deposit: shares minted / previewed:", r.shares, preview);
        _logLegs("  pulled  ", r.required);
        console2.log("  value in (USDG 6dp)  :", valueIn);
        console2.log("  USDG per share (1e18):", valueIn * 1e12 * 1e18 / r.shares);
        _logIdle(r, "  vault idle after deposit-deploy");

        /* ------------------------- 2. keeper: pull 50% of 3 adapters, deployTo all ------------------------- */
        vm.startBroadcast(ANVIL_KEY_1);
        IPositionAdapter[] memory all = r.vault.adapters();
        for (uint256 p; p < 3; ++p) {
            r.vault.pullFrom(all[p * TRI_PER_POOL], 5_000);
        }
        _deployIdle(r.vault, all, r.tokens);
        vm.stopBroadcast();
        _logIdle(r, "  vault idle after keeper deployTo");

        /* -------------------------------- 3. redeem (anvil #4) -------------------------------- */
        vm.startBroadcast(userKey);
        (, r.out) = r.vault.redeem(r.shares, r.user);
        vm.stopBroadcast();
        uint256 valueOut = _value(r.out);
        console2.log("redeem: shares burned", r.shares);
        _logLegs("  received", r.out);
        console2.log("  value out (USDG 6dp) :", valueOut);
        console2.log("  value out / in (bps) :", valueOut * 10_000 / valueIn);
        console2.log("vault supply after    :", r.vault.totalSupply());

        _check(r, valueIn, valueOut);
    }

    function _check(Run memory r, uint256 valueIn, uint256 valueOut) internal view {
        uint256 perShare = valueIn * 1e12 * 1e18 / r.shares;
        require(perShare >= 0.95e18 && perShare <= 1.05e18, "supply math: deposit not ~1 USDG per share");
        require(valueOut * 100 >= valueIn * 97, "value conservation: redeemed < 97% of deposited value");
        for (uint256 j; j < 3; ++j) {
            uint256 diff = r.out[j] > r.required[j] ? r.out[j] - r.required[j] : r.required[j] - r.out[j];
            console2.log("  token leg delta (bps of deposited):", diff * 10_000 / r.required[j]);
            require(diff * 100 <= r.required[j] * 5, "per-token conservation: a leg moved > 5%");
        }
        require(r.vault.balanceOf(r.user) == 0, "smoke wallet still holds shares");
        console2.log("SMOKE OK: deposit -> deployTo -> redeem conserved value per token");
    }

    function _logLegs(string memory title, uint256[] memory a) internal pure {
        console2.log(string.concat(title, " USDG / WETH / PONS:"), a[0], a[1], a[2]);
    }

    function _logIdle(Run memory r, string memory title) internal view {
        uint256[] memory idle = new uint256[](3);
        for (uint256 j; j < 3; ++j) {
            idle[j] = IERC20(r.tokens[j]).balanceOf(address(r.vault));
        }
        _logLegs(title, idle);
    }
}
