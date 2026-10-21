// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.34;

import {console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MySunVaultUpgradeable} from "contracts/MySunVaultUpgradeable.sol";
import {IPositionAdapter} from "contracts/interfaces/IPositionAdapter.sol";
import {PoolmigoZapIn} from "contracts/periphery/PoolmigoZapIn.sol";
import {PoolmigoZapOut} from "contracts/periphery/PoolmigoZapOut.sol";
import {TriPoolBase} from "./DemoTriPool.s.sol";

/// @dev The demo zap pair of ../shared/deployment.local.json (`periphery.zapIn` / `.zapOut`, DemoLocalFork deploys
///      them owned by OWNER #201 and wires the "demo" vault + the WETH routes) and the routes "tri" adds.
abstract contract TriZapBase is TriPoolBase {
    /// @dev The PONS leg trades on the only oracle-capable USDG/PONS v3 pool — the 1% tier (the pons adapters'
    ///      reference; RHC's 0.05% / 0.3% pools hold a 1-slot oracle ring, unusable as a TWAP reference). The zap's
    ///      per-leg bound is TWAP quote × (1 − slippage) with NO fee allowance, so the cap must clear the 100 bps
    ///      LP fee + the 50-tick deviation guard + impact: 200 bps (the contract allows up to 300). The USDG ↔ WETH
    ///      routes stay at the published 50 bps (fee 1 bp) — a zap that mixes both passes `slippageBps = 0`
    ///      (each route's own cap); the end-to-end bound is the caller's minShares / minAmountOut.
    uint24 internal constant PONS_ROUTE_FEE = 10_000;
    uint16 internal constant ZAP_TWAP_WINDOW = 600;
    uint16 internal constant PONS_ROUTE_SLIP_BPS = 200;
    uint16 internal constant ZAP_DEV_BPS = 50;

    function _zaps() internal view returns (PoolmigoZapIn zapIn, PoolmigoZapOut zapOut) {
        string memory json = vm.readFile("../shared/deployment.local.json");
        zapIn = PoolmigoZapIn(vm.parseJsonAddress(json, ".periphery.zapIn"));
        zapOut = PoolmigoZapOut(vm.parseJsonAddress(json, ".periphery.zapOut"));
    }
}

/**
 * @notice Wires the demo zap pair to `sunTriLP` on the LOCAL demo chain — IDEMPOTENT (only what differs is written),
 *         signed by OWNER (anvil #201, the zaps' owner): `registerVault(tri)` on zap-in + zap-out, route
 *         USDG → PONS on zap-in and PONS → USDG on zap-out (v3 fee-10000 `REF_POOL_PONS`, 600 s / 200 bps / 50 bps —
 *         see {TriZapBase}). The USDG ↔ WETH routes are the "demo" vault's (DemoLocalFork) and must already be set.
 *         State on existing contracts only — no CREATE, no address moves. script/tri-pool-up.sh runs it (step 8, and
 *         `tri-pool-up.sh zap` on a chain whose tri vault predates this step).
 */
contract DemoTriZapWire is TriZapBase {
    function run() external {
        require(block.chainid == EXPECTED_CHAIN_ID, "DemoTriZapWire: not the local demo chain (chain id)");
        address vault = _triVault();
        (PoolmigoZapIn zapIn, PoolmigoZapOut zapOut) = _zaps();
        require(zapIn.owner() == OWNER && zapOut.owner() == OWNER, "DemoTriZapWire: zaps not owned by OWNER #201");
        (address wethIn,,,,) = zapIn.routes(USDG, WETH);
        (address wethOut,,,,) = zapOut.routes(WETH, USDG);
        require(wethIn == POOL_FEE100 && wethOut == POOL_FEE100, "DemoTriZapWire: USDG<->WETH routes missing");

        vm.startBroadcast(OWNER);
        if (!zapIn.isVaultRegistered(vault)) zapIn.registerVault(vault);
        if (!zapOut.isVaultRegistered(vault)) zapOut.registerVault(vault);
        (address p, uint24 f, uint16 w, uint16 s, uint16 d) = zapIn.routes(USDG, PONS);
        if (!_isPonsRoute(p, f, w, s, d)) {
            zapIn.setRoute(USDG, PONS, PONS_ROUTE_FEE, REF_POOL_PONS, ZAP_TWAP_WINDOW, PONS_ROUTE_SLIP_BPS, ZAP_DEV_BPS);
        }
        (p, f, w, s, d) = zapOut.routes(PONS, USDG);
        if (!_isPonsRoute(p, f, w, s, d)) {
            zapOut.setRoute(
                PONS, USDG, PONS_ROUTE_FEE, REF_POOL_PONS, ZAP_TWAP_WINDOW, PONS_ROUTE_SLIP_BPS, ZAP_DEV_BPS
            );
        }
        vm.stopBroadcast();

        require(zapIn.isVaultRegistered(vault) && zapOut.isVaultRegistered(vault), "tri not registered");
        console2.log("zap-in  :", address(zapIn), "tri registered");
        console2.log("zap-out :", address(zapOut), "tri registered");
        console2.log("routes USDG->PONS / PONS->USDG on", REF_POOL_PONS, "fee / slippage bps:");
        console2.log(PONS_ROUTE_FEE, PONS_ROUTE_SLIP_BPS);
    }

    function _isPonsRoute(address p, uint24 f, uint16 w, uint16 s, uint16 d) internal pure returns (bool) {
        return p == REF_POOL_PONS && f == PONS_ROUTE_FEE && w == ZAP_TWAP_WINDOW && s == PONS_ROUTE_SLIP_BPS
            && d == ZAP_DEV_BPS;
    }
}

/**
 * @notice USDG-only zap e2e of `sunTriLP` on the LOCAL demo chain (wallet anvil #4, funded with USDG by OWNER #201):
 *   0. dust probe: `previewZap` of 1 USDG (the FE's minimum) offers every basket token non-zero (B-1 floor);
 *   1. zap in ZAP_USDG (default 10e6 ≈ $10) — minShares = preview × (1 − 25 bps) (the FE's τ), slippageBps
 *      ZAP_SLIPPAGE_BPS (default 0 = each route's cap; see {TriZapBase});
 *   2. keeper (#1): `pullFrom(·, 50%)` on the first adapter of each pool + `deployTo` the idle back over all 18;
 *   3. zap in again (the legs now land in re-deployed adapters);
 *   4. zap out every share to USDG — minAmountOut = preview × (1 − 25 bps).
 * Asserts: every leg of every zap reaches the vault (each token's total grows), nothing but dust is refunded, the
 * zap's USDG cost per share is within 2% of the vault's value per share, and the round trip returns ≥ 97% of the
 * USDG spent (two 1%-fee PONS legs + the vault's rounding). USDG values at the v3 reference spots are a DISPLAY
 * yardstick only, as in the frontend.
 * Run (from contracts/; LOCAL ONLY public test key of anvil #201):
 *   forge script script/DemoTriZap.s.sol:DemoTriZapSmoke --rpc-url http://127.0.0.1:8547 --broadcast \
 *     --private-key $DEPLOYER_KEY
 */
contract DemoTriZapSmoke is TriZapBase {
    using SafeERC20 for IERC20;

    uint256 internal constant DEFAULT_ZAP_USDG = 10e6;
    uint256 internal constant TAU_BPS = 25; // the FE's default minShares / minAmountOut tolerance

    struct Run {
        MySunVaultUpgradeable vault;
        PoolmigoZapIn zapIn;
        PoolmigoZapOut zapOut;
        uint256 userKey;
        address user;
        address[] tokens;
        uint16 slip;
        uint256 amount;
        uint256 spent; // USDG the two zaps consumed (net of refunds)
        uint256 shares;
    }

    function run() external {
        require(block.chainid == EXPECTED_CHAIN_ID, "DemoTriZapSmoke: not the local demo chain (chain id)");
        Run memory r;
        r.vault = MySunVaultUpgradeable(_triVault());
        (r.zapIn, r.zapOut) = _zaps();
        r.userKey = vm.deriveKey(TEST_MNEMONIC, 4);
        r.user = vm.addr(r.userKey);
        r.tokens = r.vault.tokens();
        r.slip = uint16(vm.envOr("ZAP_SLIPPAGE_BPS", uint256(0)));
        r.amount = vm.envOr("ZAP_USDG", DEFAULT_ZAP_USDG);
        require(r.tokens.length == 3 && r.tokens[0] == USDG, "tri vault is not [USDG, WETH, PONS]");
        require(r.vault.balanceOf(r.user) == 0, "smoke wallet already holds tri shares");

        vm.startBroadcast(OWNER);
        if (r.user.balance < 1 ether) payable(r.user).transfer(10 ether);
        uint256 have = IERC20(USDG).balanceOf(r.user);
        if (have < 2 * r.amount) IERC20(USDG).safeTransfer(r.user, 2 * r.amount - have);
        vm.stopBroadcast();

        /* ------------------------------ 0. dust probe (1 USDG) ------------------------------ */
        (, uint256[] memory dust, uint256 dustShares,) = r.zapIn.previewZap(address(r.vault), USDG, 1e6, r.slip);
        _logLegs("dust probe 1 USDG offers", dust);
        require(dust[0] != 0 && dust[1] != 0 && dust[2] != 0 && dustShares != 0, "1 USDG zap floors a leg to zero");

        /* ------------------------------ 1. zap in ------------------------------ */
        _zapIn(r, "zap 1");

        /* --------------- 2. keeper: pull 50% of 3 adapters, deployTo all --------------- */
        vm.startBroadcast(ANVIL_KEY_1);
        IPositionAdapter[] memory all = r.vault.adapters();
        for (uint256 p; p < 3; ++p) {
            r.vault.pullFrom(all[p * TRI_PER_POOL], 5_000);
        }
        _deployIdle(r.vault, all, r.tokens);
        vm.stopBroadcast();
        _logLegs("vault idle after keeper deployTo", _idle(r));

        /* ------------------------------ 3. zap in again ------------------------------ */
        _zapIn(r, "zap 2");

        /* ------------------------------ 4. zap out to USDG ------------------------------ */
        _zapOut(r);
        console2.log("ZAP SMOKE OK: USDG -> sunTriLP -> deployTo -> USDG -> sunTriLP -> USDG");
    }

    function _zapOut(Run memory r) internal {
        (, uint256[] memory sold, uint256 expOut, uint256[] memory pass) =
            r.zapOut.previewRedeem(address(r.vault), USDG, r.shares, r.slip);
        _logLegs("zap-out preview sold", sold);
        require(pass[1] == 0 && pass[2] == 0, "zap-out would pass a leg through unsold");
        uint256 usdgBefore = IERC20(USDG).balanceOf(r.user);
        vm.startBroadcast(r.userKey);
        IERC20(address(r.vault)).forceApprove(address(r.zapOut), r.shares);
        (uint256 out, uint256[] memory delivered) =
            r.zapOut.zapRedeem(address(r.vault), USDG, r.shares, expOut * (10_000 - TAU_BPS) / 10_000, r.slip, r.user);
        vm.stopBroadcast();
        require(IERC20(USDG).balanceOf(r.user) - usdgBefore == out, "zap-out delivery != amountOut");
        require(delivered[1] == 0 && delivered[2] == 0, "zap-out delivered WETH / PONS in kind");
        require(r.vault.balanceOf(r.user) == 0, "smoke wallet still holds shares");
        console2.log("zap out: shares / USDG out / previewed:", r.shares, out, expOut);
        console2.log("round trip USDG out / spent (bps):", out * 10_000 / r.spent);
        require(out * 100 >= r.spent * 97, "round trip returned < 97% of the USDG spent");
    }

    function _zapIn(Run memory r, string memory title) internal {
        (, uint256[] memory totals0) = r.vault.totalTokens();
        uint256 navPerShare = _value(totals0) * 1e30 / r.vault.totalSupply(); // USDG 6 dp → 1e18 per share
        uint256[] memory bal0 = _balances(r.user);
        (uint256 shares, uint256[] memory refunded) = _zapDeposit(r, title);

        (, uint256[] memory totals1) = r.vault.totalTokens();
        uint256[] memory bal1 = _balances(r.user);
        _logLegs("  refunded", refunded);
        uint256[] memory added = new uint256[](3);
        for (uint256 j; j < 3; ++j) {
            require(totals1[j] > totals0[j], "a zap leg did not reach the vault");
            added[j] = totals1[j] - totals0[j];
            if (j != 0) require(bal1[j] - bal0[j] == refunded[j], "refund accounting");
        }
        _logLegs("  vault totals grew by", added);
        uint256 cost = r.amount - refunded[0] - _value(_only12(refunded)); // USDG worth of what the zap kept
        uint256 costPerShare = cost * 1e30 / shares;
        console2.log("  USDG cost / vault value per share (1e18 = 1 USDG):", costPerShare, navPerShare);
        require(costPerShare * 100 <= navPerShare * 102, "zap cost per share > 102% of the vault's value per share");
        require(refunded[0] * 100 <= r.amount, "zap refunded > 1% of the USDG in");
        r.spent += r.amount - refunded[0];
        r.shares += shares;
    }

    /// @dev previewZap → minShares = preview × (1 − τ) → zapDeposit (anvil #4).
    function _zapDeposit(Run memory r, string memory title)
        internal
        returns (uint256 shares, uint256[] memory refunded)
    {
        (, uint256[] memory offers, uint256 expected, uint256[] memory refunds) =
            r.zapIn.previewZap(address(r.vault), USDG, r.amount, r.slip);
        uint256 minShares = expected * (10_000 - TAU_BPS) / 10_000;
        _logLegs(string.concat(title, ": preview offers"), offers);
        _logLegs("  preview refunds", refunds);
        vm.startBroadcast(r.userKey);
        IERC20(USDG).forceApprove(address(r.zapIn), r.amount);
        (shares, refunded) = r.zapIn.zapDeposit(address(r.vault), USDG, r.amount, minShares, r.slip, r.user);
        vm.stopBroadcast();
        console2.log("  shares minted / previewed / minShares:", shares, expected, minShares);
    }

    function _only12(uint256[] memory a) internal pure returns (uint256[] memory b) {
        b = new uint256[](3);
        b[1] = a[1];
        b[2] = a[2];
    }

    function _balances(address who) internal view returns (uint256[] memory b) {
        b = new uint256[](3);
        b[0] = IERC20(USDG).balanceOf(who);
        b[1] = IERC20(WETH).balanceOf(who);
        b[2] = IERC20(PONS).balanceOf(who);
    }

    function _idle(Run memory r) internal view returns (uint256[] memory idle) {
        idle = new uint256[](3);
        for (uint256 j; j < 3; ++j) {
            idle[j] = IERC20(r.tokens[j]).balanceOf(address(r.vault));
        }
    }

    function _logLegs(string memory title, uint256[] memory a) internal pure {
        console2.log(string.concat(title, " USDG / WETH / PONS:"), a[0], a[1], a[2]);
    }
}
