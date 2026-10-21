// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.34;

import {Script, console2} from "forge-std/Script.sol";
import {PoolKey} from "contracts/adapters/uniswap/v4/IPoolManagerMinimal.sol";
import {UniswapV4NativeEthAdapter} from "contracts/adapters/UniswapV4NativeEthAdapter.sol";

/// @notice Zero-broadcast probe: the Fables ETH/PONS market (per-market hook 0x594e8e62…).
///         Pass = pool live on RHC with the market's own hook; then the correct mainnet
///         adapter class is the NATIVE-ETH variant on (0x0, PONS, 0x800000, 60, hook).
contract ProbeFablesEthPons is Script {
    address internal constant VAULT = address(0xdead);
    address internal constant OWNER = address(0xdead);
    address internal constant POSM = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address internal constant EXEC_NATIVE = 0x58452CF80a0819A75a3b94347F706280CCC03D04;
    address internal constant UR = 0x204FAca1764B154221e35c0d20aBb3c525710498;
    address internal constant FABLES_ETH_PONS = 0x594e8e6281eDf2d363a0293a50004Cf868E7a080;
    address internal constant PONS = 0x39dBED3a2bd333467115dE45665cC57F813C4571;
    address internal constant PONS_WETH_F10000 = 0x10CC6BD38112cAc182db90B6a71d8Bb5939526bA;

    function poolId(PoolKey memory k) internal pure returns (bytes32) {
        return keccak256(abi.encode(k));
    }

    function run() external {
        PoolKey memory key =
            PoolKey({currency0: address(0), currency1: PONS, fee: 0x800000, tickSpacing: 60, hooks: FABLES_ETH_PONS});
        console2.log("probing pool", vm.toString(poolId(key)));
        console2.log("expected poolId 0xb59001413cb070e28433826f927b7265a0813213 (fables eth-pons)");
        try new UniswapV4NativeEthAdapter(
            UniswapV4NativeEthAdapter.Config({
                vault: VAULT,
                positionManager: POSM,
                poolKey: key,
                refPool: PONS_WETH_F10000,
                swapRouter: UR,
                swapExecutor: EXEC_NATIVE,
                owner: OWNER,
                rangeTicksBelow: 600,
                rangeTicksAbove: 600,
                twapWindow: 1800,
                maxSlippageBps: 200
            })
        ) {
            console2.log("[OK]  Fables ETH/PONS pool LIVE (native-ETH adapter class)");
        } catch {
            console2.log("[NO]  pool absent or hook/ref mismatch");
        }
    }
}
