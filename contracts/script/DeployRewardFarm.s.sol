// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.34;

import {Script, console2} from "forge-std/Script.sol";
import {RewardFarm} from "contracts/rewards/RewardFarm.sol";

/**
 * @notice Deploys the {RewardFarm} (multi-pool, per-pool reward streams — `TASK_REWARDFARM.md`). Plain, immutable
 *         contract: no proxy, no initializer, no OZ-plugin validation. The script only deploys; pools, reward streams
 *         and funding are owner calls made afterwards FROM the owner account (`createPool` / `addReward` / `fund`);
 *         optionally `setRewardSupplier(poolId, token, supplier)` lets one designated address (e.g. a partner streaming
 *         its own token) fund that stream with its own tokens.
 *
 * Always `forge clean && forge build` first (keeps deploy scripts deterministic).
 *
 * LOCAL anvil (throwaway dev key is acceptable):
 *   forge script script/DeployRewardFarm.s.sol --rpc-url local --broadcast --private-key $ANVIL_DEV_KEY
 *
 * Real network (key stays in an encrypted keystore, never plaintext):
 *   export OWNER=0x...   # treasury / ops multisig
 *   forge script script/DeployRewardFarm.s.sol --rpc-url rhc --account <keystore> --sender <addr> --broadcast
 *
 * Env params:
 *   OWNER — farm owner (Ownable2Step): creates pools, registers + funds reward streams, designates per-stream
 *           suppliers, pauses staking, recovers stray tokens. Default: the broadcasting sender. Ownership can later move with
 *           `transferOwnership` + `acceptOwnership` (two-step).
 */
contract DeployRewardFarm is Script {
    function run() external returns (address farm) {
        address owner = vm.envOr("OWNER", msg.sender);
        require(owner != address(0), "OWNER required");

        vm.startBroadcast();
        farm = address(new RewardFarm(owner));
        vm.stopBroadcast();

        console2.log("== MySun RewardFarm ==");
        console2.log("chainId :", block.chainid);
        console2.log("farm    :", farm);
        console2.log("owner   :", owner);
        console2.log("next (FROM the owner): createPool(<receipt token>) -> addReward(poolId, <token>) ->");
        console2.log("      approve + fund(poolId, <token>, amount, duration); add the farm to shared/deployments.json");
        console2.log(
            "optional (owner): setRewardSupplier(poolId, <token>, <supplier>) -> the supplier approves + funds"
        );
        console2.log("      that stream itself (address(0) = owner-only)");
    }
}
