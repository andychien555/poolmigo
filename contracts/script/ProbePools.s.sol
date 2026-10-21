// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.34;

import {Script, console2} from "forge-std/Script.sol";
import {PoolKey} from "contracts/adapters/uniswap/v4/IPoolManagerMinimal.sol";
import {UniswapV4NativeEthAdapter} from "contracts/adapters/UniswapV4NativeEthAdapter.sol";
import {UniswapV4HookedAdapter} from "contracts/adapters/UniswapV4HookedAdapter.sol";

/// @notice ZERO-BROADCAST probe (for the 3-pool vault research): simulate-construct adapters over
///         candidate pool keys. The constructors read the pool's slot0 (revert if absent) and
///         validate hook bits / router / executor wiring — a passing constructor PROVES the pool
///         exists on-chain. `forge script script/ProbePools.s.sol --rpc-url rhc` (no --broadcast).
contract ProbePools is Script {
    address internal constant VAULT = address(0xdead); // any non-zero; never called
    address internal constant OWNER = address(0xdead);
    address internal constant POSM = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address internal constant EXEC_ERC20 = 0x413a67ca4E83A4782F7745858979fE059ccbB431;
    address internal constant EXEC_NATIVE = 0x58452CF80a0819A75a3b94347F706280CCC03D04;
    address internal constant UR = 0x204FAca1764B154221e35c0d20aBb3c525710498;
    address internal constant FABLES_ETH = 0x06a889870C8f83640D6816319f72e2aA579b6080;
    address internal constant FABLES_PONS = 0x08E52564Bad99E05a694b4809F397edcA417A080;
    address internal constant Z = address(0);
    address internal constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant PONS = 0x39dBED3a2bd333467115dE45665cC57F813C4571;
    mapping(address => address) internal refOf; // pair address -> v3 twap ref

    function poolId(PoolKey memory k) internal pure returns (bytes32) {
        return keccak256(abi.encode(k));
    }

    function tryNative(string memory label, PoolKey memory k, address ref) internal {
        try new UniswapV4NativeEthAdapter(
            UniswapV4NativeEthAdapter.Config({
                vault: VAULT,
                positionManager: POSM,
                poolKey: k,
                refPool: ref,
                swapRouter: UR,
                swapExecutor: EXEC_NATIVE,
                owner: OWNER,
                rangeTicksBelow: 600,
                rangeTicksAbove: 600,
                twapWindow: 1800,
                maxSlippageBps: 200
            })
        ) {
            console2.log("[OK]  native ", label, "pool", vm.toString(poolId(k)));
        } catch {
            console2.log("[NO]  native ", label, "pool", vm.toString(poolId(k)));
        }
    }

    function tryHooked(string memory label, PoolKey memory k, address ref) internal {
        try new UniswapV4HookedAdapter(
            UniswapV4HookedAdapter.Config({
                vault: VAULT,
                positionManager: POSM,
                poolKey: k,
                refPool: ref,
                swapRouter: UR,
                swapExecutor: EXEC_ERC20,
                owner: OWNER,
                rangeTicksBelow: 600,
                rangeTicksAbove: 600,
                twapWindow: 1800,
                maxSlippageBps: 200
            })
        ) {
            console2.log("[OK]  hooked", label, "pool", vm.toString(poolId(k)));
        } catch {
            console2.log("[NO]  hooked", label, "pool", vm.toString(poolId(k)));
        }
    }

    function run() external {
        console2.log("== sanity (must be OK) ==");
        tryNative(
            "ETH/USDG dyn sp10", PoolKey(Z, USDG, 0x800000, 10, FABLES_ETH), 0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca
        );
        tryHooked(
            "PONS/USDG dyn sp60",
            PoolKey(PONS, USDG, 0x800000, 60, FABLES_PONS),
            0x7A192E71564ec66eE0763e328a3Ac274942dE4e1
        );

        console2.log("== PONS/ETH candidates ==");
        tryNative(
            "0/PONS dyn sp10 ETH-hk",
            PoolKey(Z, PONS, 0x800000, 10, FABLES_ETH),
            0x0f5F5bCC08cAe61d19c9a2d2594C252f1Baddae6
        );
        tryNative(
            "0/PONS dyn sp60 ETH-hk",
            PoolKey(Z, PONS, 0x800000, 60, FABLES_ETH),
            0x0f5F5bCC08cAe61d19c9a2d2594C252f1Baddae6
        );
        tryNative(
            "0/PONS dyn sp60 PONS-hk",
            PoolKey(Z, PONS, 0x800000, 60, FABLES_PONS),
            0x0f5F5bCC08cAe61d19c9a2d2594C252f1Baddae6
        );
        tryHooked(
            "WETH/PONS dyn sp60 ETH-hk",
            PoolKey(WETH, PONS, 0x800000, 60, FABLES_ETH),
            0x0f5F5bCC08cAe61d19c9a2d2594C252f1Baddae6
        );
        tryHooked(
            "WETH/PONS dyn sp60 PONS-hk",
            PoolKey(WETH, PONS, 0x800000, 60, FABLES_PONS),
            0x0f5F5bCC08cAe61d19c9a2d2594C252f1Baddae6
        );
        tryHooked(
            "WETH/PONS 3000 sp60 no-hook", PoolKey(WETH, PONS, 3000, 60, Z), 0x0f5F5bCC08cAe61d19c9a2d2594C252f1Baddae6
        );
        tryHooked(
            "WETH/PONS 10000 sp60 no-hook",
            PoolKey(WETH, PONS, 10000, 60, Z),
            0x10CC6BD38112cAc182db90B6a71d8Bb5939526bA
        );
        console2.log("== spare v3 refs ==");
        console2.log("v3 PONS/WETH 100  =", 0x0f5F5bCC08cAe61d19c9a2d2594C252f1Baddae6);
        console2.log("v3 PONS/WETH 500  =", 0x6693CF7e87a7039E36FA5F3c0D7E06818d259468);
        console2.log("v3 PONS/WETH 3000 =", 0xEd50bDeeA8aDC232f159486192a4157281D722ff);
        console2.log("v3 PONS/WETH 10000=", 0x10CC6BD38112cAc182db90B6a71d8Bb5939526bA);
    }
}
