// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {DepositSplit} from "contracts/periphery/DepositSplit.sol";

/// @notice Deploy the DepositSplit on mainnet 4663 as a REAL broadcasted create
///          (the pons vault's old impl embeds a ghost `new DepositSplit()` address).
contract DeployPonsDepositSplit is Script {
    function run() external {
        console2.log("chainId:", block.chainid);
        vm.startBroadcast();
        DepositSplit ds = new DepositSplit();
        vm.stopBroadcast();
        console2.log("DepositSplit:", address(ds));
    }
}