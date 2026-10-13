// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.34;

import {Script, console2} from "forge-std/Script.sol";
import {MySunVaultUpgradeable} from "contracts/MySunVaultUpgradeable.sol";
import {IPositionAdapter} from "contracts/interfaces/IPositionAdapter.sol";
import {ISwapExecutor} from "contracts/interfaces/ISwapExecutor.sol";
import {UniswapV3Adapter} from "contracts/adapters/UniswapV3Adapter.sol";

/**
 * @notice OPS (4663 rehearsal vault): register COUNT more Uniswap v3 adapters on the SAME pool as an existing
 *         (mirror) v3 adapter of the vault — the interim to the deferred P5 multi-position work.
 *
 *         Each adapter owns exactly ONE live LP position (one range), so N adapters on one pool = N concurrent
 *         ranges there. Everything is mirrored from the existing adapter AT RUNTIME (the DemoAddRangeBand
 *         pattern): pool / NFPM / swap executor (+ its UniversalRouter and Permit2), owner, fresh-range offsets,
 *         TWAP window and max slippage. Range constraints are NOT set: the constructor default box (the widest
 *         legal box for the pool's tick spacing) is the mirror's box — verified and logged, never written.
 *         The keeper opens each position afterwards via `vault.addLiquidity(adapter, params)`.
 *
 *   cd contracts
 *   # simulate (nothing broadcast):
 *   forge script script/AddSamePoolV3Adapters.s.sol --rpc-url rhc --sender <vault owner>
 *   # broadcast:
 *   forge script script/AddSamePoolV3Adapters.s.sol --rpc-url rhc --sender <vault owner> \
 *     --account mysun-rehearsal --password-file <path> --broadcast
 *
 * Env: VAULT (vault proxy, default the 4663 rehearsal vault), MIRROR (existing v3 adapter to mirror, default its
 *      v3 adapter), COUNT (adapters to add, default 7 — this pool already has one → 8 total), OWNER (default the
 *      broadcasting account). The broadcasting
 *      account must be OWNER, the vault owner AND the mirror's owner — any mismatch reverts before broadcast.
 */
contract AddSamePoolV3Adapters is Script {
    address internal constant DEFAULT_VAULT = 0x6767257AAFfCE82f6ba4B6E96EDBa80e9e1112FC; // 4663 rehearsal sunEthLP
    address internal constant DEFAULT_MIRROR = 0x8962bcC3E13a6C038Fdb5B23f54Ff41F327fb51b; // its v3 adapter
    /// @dev This pool already has 1 adapter; +7 → 8 total (the owner's target).
    uint256 internal constant DEFAULT_COUNT = 7;

    function run() external returns (address[] memory added) {
        address vaultAddr = vm.envOr("VAULT", DEFAULT_VAULT);
        address mirrorAddr = vm.envOr("MIRROR", DEFAULT_MIRROR);
        uint256 count = vm.envOr("COUNT", DEFAULT_COUNT);
        address owner = vm.envOr("OWNER", msg.sender);

        MySunVaultUpgradeable vault = MySunVaultUpgradeable(vaultAddr);
        UniswapV3Adapter mirror = UniswapV3Adapter(mirrorAddr);
        require(msg.sender == owner, "AddSamePoolV3Adapters: OWNER must be the broadcasting account");
        require(vault.owner() == owner, "AddSamePoolV3Adapters: broadcasting account is not the vault owner");
        require(mirror.owner() == owner, "AddSamePoolV3Adapters: broadcasting account is not the mirror owner");
        require(mirror.VAULT() == vaultAddr, "AddSamePoolV3Adapters: MIRROR serves another vault");
        require(vault.isAdapter(mirrorAddr), "AddSamePoolV3Adapters: MIRROR is not registered on VAULT");
        require(count > 0, "AddSamePoolV3Adapters: COUNT is zero");
        require(
            vault.adapterCount() + count <= vault.MAX_ADAPTERS(), "AddSamePoolV3Adapters: COUNT exceeds MAX_ADAPTERS"
        );

        ISwapExecutor exec = mirror.SWAP_EXECUTOR();
        UniswapV3Adapter.Config memory cfg = UniswapV3Adapter.Config({
            vault: vaultAddr,
            pool: address(mirror.POOL()),
            positionManager: address(mirror.POSITION_MANAGER()),
            swapRouter: exec.UNIVERSAL_ROUTER(),
            permit2: exec.PERMIT2(),
            swapExecutor: address(exec),
            owner: mirror.owner(),
            rangeTicksBelow: mirror.rangeTicksBelow(),
            rangeTicksAbove: mirror.rangeTicksAbove(),
            twapWindow: mirror.twapWindow(),
            maxSlippageBps: mirror.maxSlippageBps()
        });

        console2.log("chainId              :", block.chainid);
        console2.log("vault                :", vaultAddr);
        console2.log("mirror               :", mirrorAddr);
        console2.log("vault.adapterCount   :", vault.adapterCount());
        console2.log("adding               :", count);

        added = new address[](count);
        vm.startBroadcast();
        for (uint256 i; i < count; ++i) {
            added[i] = address(new UniswapV3Adapter(cfg));
            vault.addAdapter(IPositionAdapter(added[i]));
            console2.log("added adapter        :", added[i]);
            console2.log("  vault.adapterCount :", vault.adapterCount());
        }
        vm.stopBroadcast();

        _logMirror(mirror, exec);
        for (uint256 i; i < count; ++i) {
            _verify(vault, mirror, UniswapV3Adapter(added[i]));
        }
        console2.log("final vault.adapterCount:", vault.adapterCount());
        console2.log("next (keeper): vault.addLiquidity(adapter, {range}) per new adapter");
    }

    function _logMirror(UniswapV3Adapter mirror, ISwapExecutor exec) internal view {
        (int24 minTick, int24 maxTick, int24 minRange, int24 maxRange) = mirror.rangeConstraints();
        console2.log("--- mirror (reference) ---");
        console2.log("pool                 :", address(mirror.POOL()));
        console2.log("positionManager      :", address(mirror.POSITION_MANAGER()));
        console2.log("swapExecutor         :", address(exec));
        console2.log("  UNIVERSAL_ROUTER   :", exec.UNIVERSAL_ROUTER());
        console2.log("  PERMIT2            :", exec.PERMIT2());
        console2.log("owner                :", mirror.owner());
        console2.log("rangeTicksBelow      :", int256(mirror.rangeTicksBelow()));
        console2.log("rangeTicksAbove      :", int256(mirror.rangeTicksAbove()));
        console2.log("twapWindow           :", uint256(mirror.twapWindow()));
        console2.log("maxSlippageBps       :", uint256(mirror.maxSlippageBps()));
        console2.log("rangeConstraints minTick      :", int256(minTick));
        console2.log("rangeConstraints maxTick      :", int256(maxTick));
        console2.log("rangeConstraints minRangeTicks:", int256(minRange));
        console2.log("rangeConstraints maxRangeTicks:", int256(maxRange));
    }

    /// @dev One verification row per new adapter; any mismatch vs the mirror reverts (fail loudly).
    function _verify(MySunVaultUpgradeable vault, UniswapV3Adapter mirror, UniswapV3Adapter a) internal view {
        bool venue = a.POOL() == mirror.POOL() && a.POSITION_MANAGER() == mirror.POSITION_MANAGER()
            && a.SWAP_EXECUTOR() == mirror.SWAP_EXECUTOR() && a.VAULT() == address(vault);
        bool owner = a.owner() == vault.owner() && a.owner() == mirror.owner();
        bool box = _sameBox(a, mirror);
        bool params = a.twapWindow() == mirror.twapWindow() && a.maxSlippageBps() == mirror.maxSlippageBps()
            && a.rangeTicksBelow() == mirror.rangeTicksBelow() && a.rangeTicksAbove() == mirror.rangeTicksAbove();
        bool registered = vault.isAdapter(address(a));
        uint8 caps = vault.adapterCapabilities(IPositionAdapter(address(a)));
        bool sameCaps = caps == vault.adapterCapabilities(IPositionAdapter(address(mirror)));

        console2.log("--- verify adapter ---", address(a));
        console2.log("  pool/nfpm/executor/vault == mirror:", venue);
        console2.log("  owner == vault owner == mirror owner:", owner);
        console2.log("  rangeConstraints == mirror:", box);
        console2.log("  twap/slippage/rangeTicks == mirror:", params);
        console2.log("  registered:", registered);
        console2.log("  capabilities (== mirror):", uint256(caps), sameCaps);
        console2.log("  tokenId (no live position):", a.tokenId());
        require(venue && owner && box && params && registered && sameCaps, "AddSamePoolV3Adapters: verify failed");
        require(a.tokenId() == 0, "AddSamePoolV3Adapters: unexpected live position");
    }

    function _sameBox(UniswapV3Adapter a, UniswapV3Adapter b) internal view returns (bool) {
        (int24 aMin, int24 aMax, int24 aMinR, int24 aMaxR) = a.rangeConstraints();
        (int24 bMin, int24 bMax, int24 bMinR, int24 bMaxR) = b.rangeConstraints();
        return aMin == bMin && aMax == bMax && aMinR == bMinR && aMaxR == bMaxR;
    }
}
