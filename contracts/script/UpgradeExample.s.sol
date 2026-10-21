// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.34;

import {console2} from "forge-std/Script.sol";
import {Upgrades, Options} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {MySunVaultUpgradeExample} from "contracts/MySunVaultUpgradeExample.sol";
import {DepositSplitEnv} from "./DeployDepositSplit.s.sol";

/// @notice Upgrades a live MySun vault proxy to the upgrade-example implementation (an upgrade-path
/// fixture, not a released version). PROXY env = proxy address; owner key signs. DEPOSIT_SPLIT env (optional) = the
/// splitter the new implementation pins (pass the live one; unset = deploy a fresh one).
/// TEST-ONLY: the fixture's runtime exceeds EIP-170 since deposit-deploy (exempt from the CI sizes gate), so this
/// only runs on a node with the code-size limit lifted (e.g. `anvil --code-size-limit`).
contract UpgradeExample is DepositSplitEnv {
    function run() external {
        address proxy = vm.envAddress("PROXY");
        Options memory opts;
        opts.unsafeAllow = "missing-initializer,missing-initializer-call";
        vm.startBroadcast();
        opts.constructorData = abi.encode(_depositSplit());
        Upgrades.upgradeProxy(
            proxy,
            "MySunVaultUpgradeExample.sol",
            abi.encodeCall(MySunVaultUpgradeExample.initializeExample, (3600)),
            opts
        );
        vm.stopBroadcast();
        console2.log("Upgraded proxy to the upgrade example:", proxy);
        console2.log("  new implementation:", Upgrades.getImplementationAddress(proxy));
    }
}
