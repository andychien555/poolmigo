// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.34;

import {Script, console2} from "forge-std/Script.sol";
import {IUniversalRouter, UniversalRouterCodec} from "contracts/adapters/uniswap/IUniversalRouter.sol";

/// @notice One-off seed swap for the tri-vault burn (mainnet 4663) — signed by the burner keystore.
///         Single V3_SWAP_EXACT_IN through the canonical fee pool; optional trailing UNWRAP_WETH (0x06)
///         when UNWRAP=1 (the swap's recipient is then the router itself, output unwrapped to the burner).
contract OpsSwapSeed is Script {
    function run() external {
        require(block.chainid == 4663, "not 4663!");
        address sender = vm.envAddress("SENDER");
        IUniversalRouter router = IUniversalRouter(vm.envAddress("UR"));
        uint256 amountIn = vm.envUint("AMOUNT_IN");
        uint256 minOut = vm.envUint("MIN_OUT");
        address tokenIn = vm.envAddress("TOKEN_IN");
        address tokenOut = vm.envAddress("TOKEN_OUT");
        uint24 fee = uint24(vm.envUint("FEE"));
        bool unwrap = vm.envUint("UNWRAP") == 1;

        vm.startBroadcast(sender);
        (bytes memory commands, bytes[] memory inputs) = UniversalRouterCodec.v3ExactInSingle(
            unwrap ? address(router) : sender, amountIn, minOut, tokenIn, fee, tokenOut
        );
        if (unwrap) {
            commands = abi.encodePacked(commands, bytes1(0x06)); // UNWRAP_WETH
            bytes[] memory withUnwrap = new bytes[](2);
            withUnwrap[0] = inputs[0];
            withUnwrap[1] = abi.encode(sender, uint256(1)); // any nonzero min: unwrap transfers the whole balance
            inputs = withUnwrap;
        }
        router.execute(commands, inputs, block.timestamp + 600);
        vm.stopBroadcast();

        console2.log("swapped", amountIn, "->", minOut);
    }
}
