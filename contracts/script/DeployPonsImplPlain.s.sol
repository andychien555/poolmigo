// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {MySunVaultUpgradeable} from "contracts/MySunVaultUpgradeable.sol";

/// @notice Deploy the sunPonsLP implementation with the REAL DepositSplit constructor arg.
///          Plain CREATE (no auth gate): sim-safe, broadcastable.
contract DeployPonsImplPlain is Script {
    function run() external {
        console2.log("chainId:", block.chainid);
        vm.broadcast();
        MySunVaultUpgradeable impl = new MySunVaultUpgradeable(0xe4339d8787296AAf206C1590E4A909cCabE766C1);
        console2.log("impl:", address(impl));
    }
}