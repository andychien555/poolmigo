// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.34;

import {Script, console2} from "forge-std/Script.sol";
import {MySunVaultUpgradeable} from "contracts/MySunVaultUpgradeable.sol";
import {IPositionAdapter} from "contracts/interfaces/IPositionAdapter.sol";
import {IAdapterFees} from "contracts/interfaces/IAdapterFees.sol";
import {PoolKey} from "contracts/adapters/uniswap/v4/IPoolManagerMinimal.sol";
import {IPositionManagerMinimal} from "contracts/adapters/uniswap/v4/IPositionManagerMinimal.sol";
import {INativeWrapperMinimal} from "contracts/adapters/uniswap/IWETH9Minimal.sol";
import {UniswapV4NativeEthAdapter} from "contracts/adapters/UniswapV4NativeEthAdapter.sol";
import {UniversalRouterNativeSwapExecutor} from "contracts/swap/UniversalRouterNativeSwapExecutor.sol";

/// @notice OPS (4663 mainnet): register COUNT (default 3) UniswapV4NativeEthAdapter on the REAL mainnet
///         native ETH/USDG FablesRampETH v4 pool — the exact mirror of the demo chain's "demo" (sunEthLP)
///         vault adapter set (script/DemoLocalFork.s.sol `_deployNatives`): poolKey {currency0 address(0),
///         USDG, 0x800000 dynamic fee, spacing 10, FablesRampETH 0x06a8…}, v3 fee-100 pool TWAP reference,
///         a fresh UniversalRouterNativeSwapExecutor, range ±600 ticks, TWAP window 1800 s, slippage 200 bps,
///         swap venue = V4_POOL. The PONS/USDG FablesRamp (hooked) variant cannot attach to the sunEthLP
///         vault — its token registry is [USDG, WETH] and PONS is not registered (PoolmigoVault__AdapterTokenNotRegistered).
///   forge script script/AddEthNativeV4Adapters.s.sol --rpc-url rhc --sender <owner> \
///     --account mysun-rehearsal --password-file <path> --broadcast
///   Env: COUNT (default 3), OWNER (default msg.sender); broadcasting account must be the vault owner.
contract AddEthNativeV4Adapters is Script {
    address internal constant VAULT = 0x6767257AAFfCE82f6ba4B6E96EDBa80e9e1112FC; // 4663 sunEthLP
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168; // currency1
    address internal constant FABLES_RAMP_ETH = 0x06a889870C8f83640D6816319f72e2aA579b6080; // bits 0x2080
    address internal constant POSM = 0x58daec3116aae6D93017bAAea7749052E8a04fA7; // v4 PositionManager
    address internal constant POOL_FEE100 = 0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca; // v3 USDG/WETH 0.01%
    address internal constant UNIVERSAL_ROUTER = 0x204FAca1764B154221e35c0d20aBb3c525710498; // UR 2.1.2
    uint24 internal constant ETH_V4_FEE = 0x800000; // DYNAMIC_FEE_FLAG — the hook resolves each swap's fee
    int24 internal constant ETH_V4_TICK_SPACING = 10;
    int24 internal constant ETH_RANGE = 600; // ±600 ticks around the TWAP, snapped outward to spacing 10
    uint32 internal constant TWAP_WINDOW = 1800;
    uint16 internal constant ETH_MAX_SLIPPAGE_BPS = 200;

    function run() external {
        MySunVaultUpgradeable vault = MySunVaultUpgradeable(VAULT);
        uint256 count = vm.envOr("COUNT", uint256(3));
        address owner = vm.envOr("OWNER", msg.sender);

        require(msg.sender == owner, "AddEthNativeV4Adapters: OWNER must be the broadcasting account");
        require(vault.owner() == owner, "AddEthNativeV4Adapters: not the vault owner");
        require(vault.adapterCount() + count <= vault.MAX_ADAPTERS(), "AddEthNativeV4Adapters: COUNT exceeds MAX_ADAPTERS");

        PoolKey memory key = PoolKey({
            currency0: address(0), // NATIVE ETH
            currency1: USDG,
            fee: ETH_V4_FEE,
            tickSpacing: ETH_V4_TICK_SPACING,
            hooks: FABLES_RAMP_ETH
        });

        IPositionManagerMinimal posm = IPositionManagerMinimal(POSM);
        console2.log("chainId              :", block.chainid);
        console2.log("vault                :", VAULT);
        console2.log("posm.permit2         :", address(posm.permit2()));
        console2.log("posm.WETH9           :", address(INativeWrapperMinimal(POSM).WETH9()));
        console2.log("vault.adapterCount   :", vault.adapterCount());
        console2.log("adding               :", count);

        vm.startBroadcast();
        address nativeExecutor = address(
            new UniversalRouterNativeSwapExecutor(
                UNIVERSAL_ROUTER, address(posm.permit2()), address(INativeWrapperMinimal(POSM).WETH9())
            )
        );
        console2.log("native executor      :", nativeExecutor);

        UniswapV4NativeEthAdapter[] memory added = new UniswapV4NativeEthAdapter[](count);
        for (uint256 i; i < count; ++i) {
            added[i] = new UniswapV4NativeEthAdapter(
                UniswapV4NativeEthAdapter.Config({
                    vault: VAULT,
                    positionManager: POSM,
                    poolKey: key,
                    refPool: POOL_FEE100,
                    swapRouter: UNIVERSAL_ROUTER,
                    swapExecutor: nativeExecutor,
                    owner: owner,
                    rangeTicksBelow: ETH_RANGE,
                    rangeTicksAbove: ETH_RANGE,
                    twapWindow: TWAP_WINDOW,
                    maxSlippageBps: ETH_MAX_SLIPPAGE_BPS
                })
            );
            added[i].setSwapVenue(UniswapV4NativeEthAdapter.SwapVenue.V4_POOL);
            vault.addAdapter(IPositionAdapter(address(added[i])));
            console2.log("added native adapter :", address(added[i]));
            console2.log("  vault.adapterCount :", vault.adapterCount());
        }
        vm.stopBroadcast();

        for (uint256 i; i < count; ++i) {
            UniswapV4NativeEthAdapter a = added[i];
            require(vault.isAdapter(address(a)), "AddEthNativeV4Adapters: NOT registered");
            require(a.owner() == owner, "AddEthNativeV4Adapters: owner mismatch");
            require(a.HOOKS() == FABLES_RAMP_ETH, "AddEthNativeV4Adapters: hook mismatch");
            require(a.poolId() == keccak256(abi.encode(key)), "AddEthNativeV4Adapters: poolId mismatch");
            require(a.supportsInterface(type(IAdapterFees).interfaceId), "AddEthNativeV4Adapters: missing IAdapterFees");
            console2.log("verify OK            :", address(a), "| tokenId:", a.tokenId());
        }
        console2.log("final vault.adapterCount:", vault.adapterCount());
    }
}