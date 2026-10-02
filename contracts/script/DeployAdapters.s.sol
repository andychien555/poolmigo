// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.34;

import {Script, console2} from "forge-std/Script.sol";
import {PoolmigoVaultUpgradeable} from "contracts/PoolmigoVaultUpgradeable.sol";
import {IPositionAdapter} from "contracts/interfaces/IPositionAdapter.sol";
import {UniswapV3Adapter} from "contracts/adapters/UniswapV3Adapter.sol";
import {UniswapV4Adapter} from "contracts/adapters/UniswapV4Adapter.sol";
import {PoolKey} from "contracts/adapters/uniswap/v4/IPoolManagerMinimal.sol";
import {UniversalRouterSwapExecutor} from "contracts/swap/UniversalRouterSwapExecutor.sol";

/**
 * @notice Deploy the real Uniswap adapters (v3 + v4) for a deployed vault, one chain at a time. Nothing is
 *         signed here by anyone but the operator's own keystore account:
 *
 *   cd contracts
 *   VAULT=0x… forge script script/DeployAdapters.s.sol --rpc-url rhc --account <keystore> --broadcast
 *
 * Env:
 *   VAULT  — the vault PROXY the adapters serve (required — it is an immutable of both adapters; deploy the
 *            vault first, script/DeployPoolmigoVaultUpgradeable.s.sol).
 *   OWNER  — the adapters' parameter admin (default: the broadcasting account; a production chain should
 *            use the team's multisig).
 *   KEEPER — optional keeper to enable in the same run (needs VAULT set and a broadcasting account that
 *            owns the vault).
 *   UR / PERMIT2 / WETH / USDG / POOL / NFPM / POSM — address overrides; the defaults are RHC mainnet
 *   (v3 fee-100 USDG/WETH pool as reference venue).
 *   SWAP_EXECUTOR — optional already-deployed UniversalRouterSwapExecutor (stateless, no privileges) on exactly
 *   (UR, PERMIT2); unset = deploy a fresh one first in this run. Both adapters wire it immutably (their
 *   constructors reject an executor on another router / Permit2).
 *
 * When the broadcasting account owns the vault, both adapters are added to it (and the keeper enabled);
 * otherwise the exact follow-up calls are printed for the vault owner. Parameters mirror the fork suites:
 * range ±300 ticks around TWAP, window 1800 s, max slippage 100 bps; the v4 pool is fee 500 / spacing 10 /
 * no hooks, its reference venue (and default swap pool) the v3 fee-100 pool.
 */
contract DeployAdapters is Script {
    /* --------------------------- venue defaults (notes/RHC_ADDRESSES.md) --------------------------- */
    address internal constant DEFAULT_UR = 0x204FAca1764B154221e35c0d20aBb3c525710498; // UniversalRouter 2.1.2
    address internal constant PERMIT2_CANONICAL = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant DEFAULT_WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address internal constant DEFAULT_USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant DEFAULT_POOL = 0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca; // v3 fee 100
    address internal constant DEFAULT_NFPM = 0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3;
    address internal constant DEFAULT_POSM = 0x58daec3116aae6D93017bAAea7749052E8a04fA7; // v4 PositionManager

    /* --------------------------------- parameters (fork-suite values) -------------------------------- */
    int24 internal constant RANGE_BELOW = 300;
    int24 internal constant RANGE_ABOVE = 300;
    uint32 internal constant TWAP_WINDOW = 1800;
    uint16 internal constant MAX_SLIPPAGE_BPS = 100;
    uint24 internal constant V4_FEE = 500;
    int24 internal constant V4_TICK_SPACING = 10;

    function run() external returns (address adapterV3, address adapterV4) {
        address vault = vm.envAddress("VAULT");
        address owner = vm.envOr("OWNER", msg.sender);
        address keeper = vm.envOr("KEEPER", address(0));
        address ur = vm.envOr("UR", DEFAULT_UR);
        address permit2 = vm.envOr("PERMIT2", PERMIT2_CANONICAL);
        address weth = vm.envOr("WETH", DEFAULT_WETH);
        address usdg = vm.envOr("USDG", DEFAULT_USDG);
        address pool = vm.envOr("POOL", DEFAULT_POOL);
        address nfpm = vm.envOr("NFPM", DEFAULT_NFPM);
        address posm = vm.envOr("POSM", DEFAULT_POSM);
        address executor = vm.envOr("SWAP_EXECUTOR", address(0));

        require(msg.sender == owner, "DeployAdapters: OWNER must be the broadcasting account");

        vm.startBroadcast();
        if (executor == address(0)) {
            executor = address(new UniversalRouterSwapExecutor(ur, permit2));
        }
        adapterV3 = address(
            new UniswapV3Adapter(
                UniswapV3Adapter.Config({
                    vault: vault,
                    pool: pool,
                    positionManager: nfpm,
                    swapRouter: ur,
                    permit2: permit2,
                    swapExecutor: executor,
                    owner: owner,
                    rangeTicksBelow: RANGE_BELOW,
                    rangeTicksAbove: RANGE_ABOVE,
                    twapWindow: TWAP_WINDOW,
                    maxSlippageBps: MAX_SLIPPAGE_BPS
                })
            )
        );
        adapterV4 = address(
            new UniswapV4Adapter(
                UniswapV4Adapter.Config({
                    vault: vault,
                    positionManager: posm,
                    poolKey: PoolKey({
                        currency0: weth, currency1: usdg, fee: V4_FEE, tickSpacing: V4_TICK_SPACING, hooks: address(0)
                    }),
                    refPool: pool,
                    swapRouter: ur,
                    swapExecutor: executor,
                    owner: owner,
                    rangeTicksBelow: RANGE_BELOW,
                    rangeTicksAbove: RANGE_ABOVE,
                    twapWindow: TWAP_WINDOW,
                    maxSlippageBps: MAX_SLIPPAGE_BPS
                })
            )
        );

        bool canSetup = vault.code.length > 0 && PoolmigoVaultUpgradeable(vault).owner() == msg.sender;
        if (canSetup) {
            PoolmigoVaultUpgradeable(vault).addAdapter(IPositionAdapter(adapterV3));
            PoolmigoVaultUpgradeable(vault).addAdapter(IPositionAdapter(adapterV4));
            if (keeper != address(0)) PoolmigoVaultUpgradeable(vault).setKeeper(keeper, true);
        }
        vm.stopBroadcast();

        console2.log("chainId   :", block.chainid);
        console2.log("vault     :", vault);
        console2.log("adapterV3 :", adapterV3);
        console2.log("adapterV4 :", adapterV4);
        console2.log("owner     :", owner);
        console2.log("ur        :", ur);
        console2.log("executor  :", executor);
        console2.log("pool (v3) :", pool);
        console2.log("nfpm      :", nfpm);
        console2.log("posm      :", posm);
        if (canSetup) {
            console2.log("vault: both adapters added; keeper enabled:", keeper != address(0));
        } else {
            console2.log("vault has no code OR is not owned by the sender - run these from the vault owner:");
            console2.log("  vault.addAdapter(", adapterV3);
            console2.log("  vault.addAdapter(", adapterV4);
            if (keeper != address(0)) {
                console2.log("  vault.setKeeper(keeper, true) with keeper:", keeper);
            }
        }
        console2.log("next: the zap periphery (script/DeployPeriphery.s.sol), then the keeper service");
    }
}
