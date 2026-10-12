// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.34;

import {Script, console2} from "forge-std/Script.sol";
import {PoolmigoVaultUpgradeable} from "contracts/PoolmigoVaultUpgradeable.sol";
import {IPositionAdapter} from "contracts/interfaces/IPositionAdapter.sol";
import {ISwapExecutor} from "contracts/interfaces/ISwapExecutor.sol";
import {UniswapV3Adapter} from "contracts/adapters/UniswapV3Adapter.sol";

/**
 * @notice DEMO-ONLY (the local RHC-fork stack): register a SECOND Uniswap v3 adapter on the SAME fee-100
 *         USDG/WETH pool as the demo vault's existing v3 adapter.
 *
 *         Each adapter owns exactly ONE live LP position (one range) — this is how the vault holds two
 *         different ranges in ONE pool: two adapters on that pool. This script deploys the extra adapter
 *         (venue wiring mirrored from the existing one: same pool / NFPM / router / executor) and the
 *         vault owner registers it. The keeper then opens the second position at a different range via
 *         `vault.addLiquidity(adapter2, params)`.
 *
 *   cd contracts
 *   forge script script/DemoAddRangeBand.s.sol --rpc-url http://127.0.0.1:8547 --broadcast \
 *     --private-key $DEPLOYER_KEY    # anvil #200 = the fork demo's OWNER — LOCAL ONLY (public test key;
 *                                    # cast wallet private-key --mnemonic "test … junk" --mnemonic-index 200)
 *
 * Env: VAULT (demo vault proxy), V3_ADAPTER (existing adapter to mirror), OWNER (default anvil #200 — the fork demo's deployer, script/fork-demo-up.sh).
 */
contract DemoAddRangeBand is Script {
    address internal constant DEFAULT_VAULT = 0x63763137C765BE274f1953e3C2e41E5668459977; // demo vault proxy
    address internal constant DEFAULT_V3_ADAPTER = 0x3369DA4782B69E8abD04bCDCAe761215825BD0E6; // existing v3 adapter
    address internal constant DEFAULT_OWNER = 0xCD5691EA878D262516be278cb46f2fd7fF132083; // anvil #200

    int24 internal constant RANGE_BELOW = 300;
    int24 internal constant RANGE_ABOVE = 300;
    uint32 internal constant TWAP_WINDOW = 1800;
    uint16 internal constant MAX_SLIPPAGE_BPS = 100;

    function run() external returns (address adapter2) {
        address vault = vm.envOr("VAULT", DEFAULT_VAULT);
        address existing = vm.envOr("V3_ADAPTER", DEFAULT_V3_ADAPTER);
        address owner = vm.envOr("OWNER", DEFAULT_OWNER);
        require(msg.sender == owner, "DemoAddRangeBand: OWNER must be the broadcasting account");

        UniswapV3Adapter a1 = UniswapV3Adapter(existing);
        ISwapExecutor exec = a1.SWAP_EXECUTOR();

        vm.startBroadcast();
        adapter2 = address(
            new UniswapV3Adapter(
                UniswapV3Adapter.Config({
                    vault: vault,
                    pool: address(a1.POOL()),
                    positionManager: address(a1.POSITION_MANAGER()),
                    swapRouter: exec.UNIVERSAL_ROUTER(),
                    permit2: exec.PERMIT2(),
                    swapExecutor: address(exec),
                    owner: owner,
                    rangeTicksBelow: RANGE_BELOW,
                    rangeTicksAbove: RANGE_ABOVE,
                    twapWindow: TWAP_WINDOW,
                    maxSlippageBps: MAX_SLIPPAGE_BPS
                })
            )
        );
        PoolmigoVaultUpgradeable(vault).addAdapter(IPositionAdapter(adapter2));
        vm.stopBroadcast();

        console2.log("adapter2 (same pool) :", adapter2);
        console2.log("pool                 :", address(a1.POOL()));
        console2.log("vault.adapterCount   :", PoolmigoVaultUpgradeable(vault).adapterCount());
        console2.log("existing tokenId     :", a1.tokenId());
        console2.log("existing tickLower   :", int256(a1.tickLower()));
        console2.log("existing tickUpper   :", int256(a1.tickUpper()));
        console2.log("next (keeper): vault.addLiquidity(adapter2, {different range});");
    }
}
