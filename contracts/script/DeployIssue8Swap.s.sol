// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.34;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MySunVaultUpgradeable} from "contracts/MySunVaultUpgradeable.sol";
import {IPositionAdapter} from "contracts/interfaces/IPositionAdapter.sol";
import {ISwapExecutor} from "contracts/interfaces/ISwapExecutor.sol";
import {ILiquidityAdapter} from "contracts/interfaces/ILiquidityAdapter.sol";
import {IUniswapV3PoolMinimal} from "contracts/adapters/uniswap/IUniswapV3PoolMinimal.sol";
import {TickMath} from "contracts/adapters/uniswap/TickMath.sol";
import {LiquidityAmounts} from "contracts/adapters/uniswap/LiquidityAmounts.sol";
import {PoolKey} from "contracts/adapters/uniswap/v4/IPoolManagerMinimal.sol";
import {UniswapV3Adapter} from "contracts/adapters/UniswapV3Adapter.sol";
import {UniswapV4Adapter} from "contracts/adapters/UniswapV4Adapter.sol";
import {UniswapV4HookedAdapter} from "contracts/adapters/UniswapV4HookedAdapter.sol";
import {UniswapV4NativeEthAdapter} from "contracts/adapters/UniswapV4NativeEthAdapter.sol";

/// @notice Issue #8 rollout: replace every LEGACY adapter of one vault (bytecode from before the event expansion) with
///         a fresh deployment of the SAME adapter family from the merged tree — same vault, pool key / v3 pool, fee,
///         hook, reference pool, swap executor + router, owner, range ticks, TWAP window, slippage, swap venue and
///         range constraints — and move its liquidity across. Per legacy adapter: keeper `pullFrom(old, 10_000)` →
///         owner `removeAdapter(old)` → deploy `new` → owner setters → owner `addAdapter(new)` (capability mask
///         re-derived by ERC-165; narrowed to the old mask if the owner had narrowed it) → keeper `deployTo(new, …)`.
///
///         "Legacy" = the adapter's runtime size differs from the merged-tree artifact of its family (the event
///         expansion changed every family's size; immutables do not change the size). Already-swapped adapters are
///         skipped, so every phase is re-runnable.
///
///   Env:  VAULT (required)            the vault to swap.
///         PHASE (required)            plan | pull | swap | deploy | verify | all
///           plan    read-only: the vault, every adapter (kind, legacy?, owner, caps, position, config). No tx.
///           pull    KEEPER: pullFrom(old, 10_000) for every legacy adapter holding anything; records its bounds, the
///                   gross pull and the vault-idle delta it left (net of the perf-fee cut) in the state file.
///           swap    OWNER: per recorded legacy adapter — guard (position() all zero, else revert: re-run pull) →
///                   removeAdapter (asserts adapterCount − 1) → deploy clone → setters → addAdapter (asserts the
///                   count is back, caps == the old mask, config identical). State saved after EVERY adapter.
///           deploy  KEEPER: re-fund each swapped adapter with its predecessor's net pull (scaled down per token if the
///                   vault idle no longer covers the recorded sum, e.g. redemptions in between). ISSUE8_DEPLOY_MODE:
///                   `replicate` (default) = `addLiquidity` at the legacy position's EXACT bounds, sized at spot,
///                   no swap (position-neutral); `deployTo` = the adapter's own deploy (re-ranges around the TWAP and
///                   ratio-swaps — NOT position-neutral: on a range-exited position it trades ~half the value).
///           verify  read-only: count, supply, totalTokens vs the pre-pull snapshot, no legacy left, live positions.
///           all     pull + swap + deploy + verify in ONE run — the signer must be owner AND keeper (the burner).
///         ISSUE8_LABEL (default "mainnet")  state-file label: broadcast/issue8/<label>-<chainid>-<vault>.json.
///         ISSUE8_OVERWRITE (default false)   `pull` starts a FRESH state file instead of merging the existing one
///                                            (discards the recorded pre-swap snapshot and nets — do not use mid-rollout).
///   Every phase is re-runnable and resumes from ON-CHAIN state (registered? funded?), not from the file alone.
///         ISSUE8_ALLOW_SUPPLY_DRIFT (default false)  `verify` accepts a supply change (deposits/redeems in between).
///   A run WITHOUT --broadcast (forge's dry run) reads the real state file but writes `<label>-dryrun-…` instead.
///
///   Accounts: --sender <signer> --account <keystore> (real network) or --unlocked --sender <addr> (anvil fork).
///   forge clean && forge build -q
///   VAULT=0x… PHASE=plan forge script script/DeployIssue8Swap.s.sol --rpc-url <rpc>
///   VAULT=0x… PHASE=pull forge script script/DeployIssue8Swap.s.sol --rpc-url <rpc> --sender <keeper> \
///     --account <keystore> --password-file <pw> --broadcast        (then PHASE=swap as owner, PHASE=deploy as keeper)
contract DeployIssue8Swap is Script {
    enum Kind {
        V3,
        V4,
        V4_HOOKED,
        V4_NATIVE
    }

    /// @dev Everything a clone must reproduce, read from the live adapter (both families share the setter surface).
    struct Cfg {
        Kind kind;
        address vault;
        address owner;
        address pool; // v3: POOL; v4 family: REF_POOL
        address positionManager;
        address swapExecutor;
        address swapRouter;
        address permit2; // v3 Config field (the v4 family reads Permit2 from the PositionManager)
        PoolKey key; // v4 family
        bytes32 poolId;
        int24 rangeBelow;
        int24 rangeAbove;
        uint32 twapWindow;
        uint16 maxSlippageBps;
        uint8 venue; // v4 family SwapVenue (0 = V3_REF_POOL default)
        int24[4] constraints; // minTick, maxTick, minRangeTicks, maxRangeTicks
    }

    /// @dev Parallel arrays = the state file layout (flat JSON arrays, one index per legacy adapter).
    struct State {
        address vault;
        uint256 preSupply;
        address[] tokens;
        uint256[] preTotals;
        address[] old;
        address[] next; // 0 until swapped
        uint256[] kind;
        uint256[] caps; // old adapter's vault capability mask
        address[] token0;
        address[] token1;
        uint256[] pulled0; // gross, adapter order
        uint256[] pulled1;
        uint256[] net0; // vault-idle delta of the pull (= gross − perf-fee cut), adapter order
        uint256[] net1;
        int256[] lower; // the legacy position's bounds at pull time (0/0 = it had no position)
        int256[] upper;
        uint256[] liq; // its liquidity at pull time (informational)
        bool[] deployed;
    }

    uint256 internal constant FULL_BPS = 10_000;
    string internal constant OBJ = "issue8";

    MySunVaultUpgradeable internal vault;

    function run() external {
        vault = MySunVaultUpgradeable(vm.envAddress("VAULT"));
        bytes32 phase = keccak256(bytes(vm.envString("PHASE")));
        console2.log("chainId      :", block.chainid);
        console2.log("vault        :", address(vault));
        console2.log("signer       :", msg.sender);
        if (phase == keccak256("plan")) {
            _plan();
        } else if (phase == keccak256("pull")) {
            _pull();
        } else if (phase == keccak256("swap")) {
            _swap();
        } else if (phase == keccak256("deploy")) {
            _deployNew();
        } else if (phase == keccak256("verify")) {
            _verify();
        } else if (phase == keccak256("all")) {
            _pull();
            _swap();
            _deployNew();
            _verify();
        } else {
            revert("DeployIssue8Swap: PHASE must be plan | pull | swap | deploy | verify | all");
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 PHASES
    //////////////////////////////////////////////////////////////*/

    function _plan() internal {
        IPositionAdapter[] memory all = vault.adapters();
        (address[] memory t, uint256[] memory totals) = vault.totalTokens();
        console2.log("symbol       :", vault.symbol());
        console2.log("owner        :", vault.owner());
        console2.log("paused       :", vault.paused());
        console2.log("supply       :", vault.totalSupply());
        console2.log("perf fee bps :", vault.performanceFeeBps());
        console2.log("signer owner?:", vault.owner() == msg.sender);
        console2.log("signer keeper:", vault.isKeeper(msg.sender));
        for (uint256 j; j < t.length; ++j) {
            console2.log(
                string.concat(
                    "token ",
                    vm.toString(t[j]),
                    " total ",
                    vm.toString(totals[j]),
                    " idle ",
                    vm.toString(IERC20(t[j]).balanceOf(address(vault)))
                )
            );
        }
        uint256 legacy;
        console2.log("adapters     :", all.length);
        for (uint256 i; i < all.length; ++i) {
            if (_planAdapter(i, address(all[i]))) ++legacy;
        }
        console2.log("legacy adapters to swap:", legacy);
    }

    /// @dev One adapter's plan lines; returns whether it is legacy.
    function _planAdapter(uint256 i, address a) internal view returns (bool isLegacy) {
        Cfg memory c = _read(a);
        isLegacy = _isLegacy(a, c.kind);
        console2.log(
            string.concat(
                "[",
                vm.toString(i),
                "] ",
                _kindName(c.kind),
                " ",
                vm.toString(a),
                isLegacy ? " LEGACY" : " new",
                " size ",
                vm.toString(a.code.length),
                " caps ",
                vm.toString(vault.adapterCapabilities(IPositionAdapter(a))),
                " owner ",
                vm.toString(c.owner)
            )
        );
        _planPosition(a);
        console2.log(
            string.concat(
                "     pool ",
                vm.toString(c.pool),
                " range -",
                vm.toString(int256(c.rangeBelow)),
                "/+",
                vm.toString(int256(c.rangeAbove)),
                " twap ",
                vm.toString(uint256(c.twapWindow)),
                " slip ",
                vm.toString(uint256(c.maxSlippageBps)),
                " venue ",
                vm.toString(uint256(c.venue))
            )
        );
    }

    function _planPosition(address a) internal view {
        (address[] memory pt, uint256[] memory pa) = IPositionAdapter(a).position();
        (, int24 lower, int24 upper, uint128 liquidity,) = UniswapV4Adapter(a).positionState();
        console2.log(
            string.concat(
                "     tokenId ",
                vm.toString(_tokenId(a)),
                " ticks ",
                vm.toString(int256(lower)),
                "..",
                vm.toString(int256(upper)),
                " L ",
                vm.toString(uint256(liquidity)),
                " pos ",
                vm.toString(pa[0]),
                " ",
                vm.toString(pt[0]),
                " / ",
                vm.toString(pa[1]),
                " ",
                vm.toString(pt[1])
            )
        );
    }

    /// @dev Resumable: an existing state file is MERGED (its pre-swap snapshot and every recorded entry kept); each
    ///      registered legacy adapter that still holds value is pulled (again) and its record refreshed — so a pull
    ///      broadcast that died half-way is finished by simply re-running the phase.
    function _pull() internal {
        require(vault.isKeeper(msg.sender), "DeployIssue8Swap: pull needs a vault keeper signer");
        require(!vault.paused(), "DeployIssue8Swap: vault paused");
        IPositionAdapter[] memory all = vault.adapters();
        bool merge = _stateExists() && !vm.envOr("ISSUE8_OVERWRITE", false);
        State memory prev;
        if (merge) prev = _load();
        State memory st = _newState(all.length + prev.old.length);
        uint256 n;
        if (merge) {
            st.preSupply = prev.preSupply;
            st.tokens = prev.tokens;
            st.preTotals = prev.preTotals;
            for (; n < prev.old.length; ++n) {
                _copyEntry(st, n, prev, n);
            }
        }
        uint256 gasTotal;
        for (uint256 i; i < all.length; ++i) {
            Kind kind = _kind(address(all[i]));
            if (!_isLegacy(address(all[i]), kind)) continue;
            uint256 k = _find(st.old, n, address(all[i]));
            if (k == n) {
                _recordEntry(st, n++, all[i], kind);
            }
            gasTotal += _pullOne(st, k, all[i]);
        }
        require(n != 0, "DeployIssue8Swap: no legacy adapter on this vault");
        _shrink(st, n);
        _save(st);
        console2.log("pull done - legacy adapters:", n);
        console2.log("pull gas (simulated)      :", gasTotal);
    }

    /// @dev A fresh legacy entry: identity, capability mask, tokens, the live bounds (0/0 = no position).
    function _recordEntry(State memory st, uint256 n, IPositionAdapter a, Kind kind) internal view {
        (address[] memory pt,) = a.position();
        st.old[n] = address(a);
        st.kind[n] = uint256(kind);
        st.caps[n] = vault.adapterCapabilities(a);
        st.token0[n] = pt[0];
        st.token1[n] = pt[1];
        _recordBounds(st, n, address(a));
    }

    /// @dev Pull entry `k`'s adapter to zero if it holds anything (keeper broadcast) and record what the pull left in
    ///      the vault; an already-empty adapter keeps its earlier record untouched.
    function _pullOne(State memory st, uint256 k, IPositionAdapter a) internal returns (uint256 gasUsed) {
        (address[] memory pt, uint256[] memory pa) = a.position();
        if (pa[0] != 0 || pa[1] != 0) {
            _recordBounds(st, k, address(a)); // bounds as of THIS pull (the position is about to close)
            uint256 idle0 = IERC20(pt[0]).balanceOf(address(vault));
            uint256 idle1 = IERC20(pt[1]).balanceOf(address(vault));
            uint256 g = gasleft();
            vm.broadcast();
            (, uint256[] memory pulled) = vault.pullFrom(a, FULL_BPS);
            gasUsed = g - gasleft();
            st.pulled0[k] = pulled[0];
            st.pulled1[k] = pulled[1];
            st.net0[k] = IERC20(pt[0]).balanceOf(address(vault)) - idle0;
            st.net1[k] = IERC20(pt[1]).balanceOf(address(vault)) - idle1;
        }
        console2.log(
            string.concat(
                "pull [",
                vm.toString(k),
                "] ",
                _kindName(Kind(st.kind[k])),
                " ",
                vm.toString(address(a)),
                " gross ",
                vm.toString(st.pulled0[k]),
                "/",
                vm.toString(st.pulled1[k]),
                " net ",
                vm.toString(st.net0[k]),
                "/",
                vm.toString(st.net1[k]),
                " gas ",
                vm.toString(gasUsed)
            )
        );
    }

    function _recordBounds(State memory st, uint256 n, address a) internal view {
        (, int24 lower, int24 upper, uint128 liquidity,) = ILiquidityAdapter(a).positionState();
        st.lower[n] = lower;
        st.upper[n] = upper;
        st.liq[n] = liquidity;
    }

    /// @dev Resumable from ON-CHAIN state (the state file is written during forge's local simulation, i.e. BEFORE the
    ///      broadcast, so it may run ahead of the chain after a failed broadcast): an entry is done iff its replacement
    ///      is registered; otherwise each missing step (remove / deploy / setters / add) is performed.
    function _swap() internal {
        require(vault.owner() == msg.sender, "DeployIssue8Swap: swap needs the vault owner signer");
        State memory st = _load();
        uint256 gasTotal;
        for (uint256 i; i < st.old.length; ++i) {
            if (st.next[i] != address(0) && vault.isAdapter(st.next[i])) continue; // swapped on-chain
            gasTotal += _swapOne(st, i);
            _save(st); // after EVERY adapter
        }
        console2.log("swap done - adapterCount:", vault.adapterCount());
        console2.log("swap gas (simulated)    :", gasTotal);
    }

    /// @dev Guard → removeAdapter → clone → setters → addAdapter (+ caps narrowing) for legacy entry `i` (owner); each
    ///      step only if the chain still needs it.
    function _swapOne(State memory st, uint256 i) internal returns (uint256 gasUsed) {
        address old = st.old[i];
        Cfg memory c = _read(old); // readable whether registered or not
        require(c.vault == address(vault), "DeployIssue8Swap: adapter wired to another vault");
        bool registered = vault.isAdapter(old);
        if (registered) {
            (, uint256[] memory pa) = IPositionAdapter(old).position();
            require(
                pa[0] == 0 && pa[1] == 0,
                string.concat(
                    "DeployIssue8Swap: ", vm.toString(old), " still holds value (pull it to 0 first: PHASE=pull)"
                )
            );
        }
        uint256 count = vault.adapterCount();
        address nu = st.next[i];
        bool reuse = nu != address(0) && nu.code.length != 0;

        uint256 g = gasleft();
        vm.startBroadcast();
        if (registered) {
            vault.removeAdapter(IPositionAdapter(old));
            require(vault.adapterCount() == count - 1, "DeployIssue8Swap: adapterCount did not decrement");
        }
        if (!reuse) {
            nu = _clone(c);
        }
        _configure(nu, c);
        vault.addAdapter(IPositionAdapter(nu));
        _narrowCaps(nu, uint8(st.caps[i]));
        vm.stopBroadcast();
        gasUsed = g - gasleft();

        require(vault.adapterCount() == (registered ? count : count + 1), "DeployIssue8Swap: adapterCount not restored");
        require(vault.isAdapter(nu) && !vault.isAdapter(old), "DeployIssue8Swap: registry mismatch");
        require(vault.adapterCapabilities(IPositionAdapter(nu)) == st.caps[i], "DeployIssue8Swap: capability mismatch");
        require(!_isLegacy(nu, c.kind), "DeployIssue8Swap: clone is not the merged-tree bytecode");
        _assertSameConfig(c, _read(nu));
        st.next[i] = nu;
        _logSwap(st, i, c.kind, reuse, gasUsed);
    }

    function _logSwap(State memory st, uint256 i, Kind kind, bool reuse, uint256 gasUsed) internal pure {
        console2.log(
            string.concat(
                "swap [",
                vm.toString(i),
                "] ",
                _kindName(kind),
                " ",
                vm.toString(st.old[i]),
                " -> ",
                vm.toString(st.next[i]),
                reuse ? " (resumed)" : "",
                " caps ",
                vm.toString(st.caps[i]),
                " gas ",
                vm.toString(gasUsed)
            )
        );
    }

    function _deployNew() internal {
        require(vault.isKeeper(msg.sender), "DeployIssue8Swap: deploy needs a vault keeper signer");
        State memory st = _load();
        // Per-token scale: if the idle no longer covers the recorded sum (redemptions in between), deploy pro rata.
        uint256[] memory sum = new uint256[](st.tokens.length);
        for (uint256 i; i < st.old.length; ++i) {
            if (!_needsFunding(st, i)) continue;
            sum[_ix(st, st.token0[i])] += st.net0[i];
            sum[_ix(st, st.token1[i])] += st.net1[i];
        }
        uint256[] memory idle = new uint256[](st.tokens.length);
        for (uint256 j; j < st.tokens.length; ++j) {
            idle[j] = IERC20(st.tokens[j]).balanceOf(address(vault));
        }
        bool replicate = _replicateMode();
        console2.log(
            "deploy mode  :", replicate ? "replicate (addLiquidity at the legacy bounds, no swap)" : "deployTo"
        );
        uint256 gasTotal;
        for (uint256 i; i < st.old.length; ++i) {
            if (!_needsFunding(st, i)) continue;
            uint256[] memory amounts = new uint256[](2);
            amounts[0] = _scaled(st.net0[i], idle[_ix(st, st.token0[i])], sum[_ix(st, st.token0[i])]);
            amounts[1] = _scaled(st.net1[i], idle[_ix(st, st.token1[i])], sum[_ix(st, st.token1[i])]);
            uint256 gasUsed;
            if (amounts[0] != 0 || amounts[1] != 0) {
                gasUsed = replicate ? _replicateOne(st, i, amounts) : _deployToOne(st.next[i], amounts);
            }
            gasTotal += gasUsed;
            st.deployed[i] = true;
            _save(st);
            _logDeploy(i, st.next[i], amounts, gasUsed);
        }
        console2.log("deploy gas (simulated):", gasTotal);
    }

    /// @dev On-chain: the replacement must be registered (else run PHASE=swap); it is funded iff it has no live
    ///      position yet (a re-run after a half-failed deploy broadcast funds exactly the missing ones).
    function _needsFunding(State memory st, uint256 i) internal view returns (bool) {
        address nu = st.next[i];
        require(
            nu != address(0) && vault.isAdapter(nu), "DeployIssue8Swap: replacement not registered - run PHASE=swap"
        );
        return _tokenId(nu) == 0;
    }

    /// @dev ISSUE8_DEPLOY_MODE: `replicate` (default) | `deployTo`.
    function _replicateMode() internal view returns (bool) {
        bytes32 mode = keccak256(bytes(vm.envOr("ISSUE8_DEPLOY_MODE", string("replicate"))));
        require(
            mode == keccak256("replicate") || mode == keccak256("deployTo"), "ISSUE8_DEPLOY_MODE: replicate | deployTo"
        );
        return mode == keccak256("replicate");
    }

    /// @dev `deployTo` mode: the adapter re-ranges around the TWAP and ratio-swaps (NOT position-neutral).
    function _deployToOne(address nu, uint256[] memory amounts) internal returns (uint256 gasUsed) {
        uint256 g = gasleft();
        vm.broadcast();
        vault.deployTo(IPositionAdapter(nu), amounts);
        gasUsed = g - gasleft();
        require(_tokenId(nu) != 0, "DeployIssue8Swap: no live position after deployTo");
    }

    /// @dev `replicate` mode: keeper `addLiquidity` at EXACTLY the legacy position's bounds, the liquidity the net
    ///      pulled amounts buy at the venue spot (2 wei headroom per side for the adapter's +1 sizing), caps = those
    ///      amounts, `minSwapOut` = 0 — the adapter reverts rather than swap, so this can never trade. A legacy
    ///      adapter that had no position (bounds 0/0) or whose amounts buy no liquidity leaves its pull idle.
    function _replicateOne(State memory st, uint256 i, uint256[] memory amounts) internal returns (uint256 gasUsed) {
        address nu = st.next[i];
        if (st.lower[i] == 0 && st.upper[i] == 0) {
            console2.log("  no legacy position - pull left idle in the vault:", nu);
            return 0;
        }
        ILiquidityAdapter.AddLiquidityParams memory p;
        p.tickLower = int24(st.lower[i]);
        p.tickUpper = int24(st.upper[i]);
        p.liquidity = _liquidityFor(nu, Kind(st.kind[i]), p.tickLower, p.tickUpper, amounts);
        if (p.liquidity == 0) {
            console2.log("  amounts buy no liquidity at spot - left idle in the vault:", nu);
            return 0;
        }
        p.minLiquidity = p.liquidity - p.liquidity / 10_000; // 1 bp slack (fork add-test knife edge)
        p.maxAmount0 = amounts[0];
        p.maxAmount1 = amounts[1];
        (,,, uint256 swapIn,) = UniswapV4Adapter(nu).previewAddLiquidity(p);
        require(swapIn == 0, "DeployIssue8Swap: replicate would need a ratio swap");
        uint256 g = gasleft();
        vm.broadcast();
        vault.addLiquidity(IPositionAdapter(nu), p);
        gasUsed = g - gasleft();
        _checkReplicated(nu, p, st.liq[i]);
    }

    function _checkReplicated(address nu, ILiquidityAdapter.AddLiquidityParams memory p, uint256 legacyLiq)
        internal
        view
    {
        (uint256 id, int24 lower, int24 upper, uint128 liquidity,) = ILiquidityAdapter(nu).positionState();
        require(id != 0 && lower == p.tickLower && upper == p.tickUpper, "DeployIssue8Swap: bounds not replicated");
        require(liquidity >= p.minLiquidity, "DeployIssue8Swap: liquidity below floor");
        console2.log(
            string.concat(
                "  replicated ticks ",
                vm.toString(int256(lower)),
                "..",
                vm.toString(int256(upper)),
                " L ",
                vm.toString(uint256(liquidity)),
                " (legacy L ",
                vm.toString(legacyLiq),
                ")"
            )
        );
    }

    /// @dev Liquidity `amounts` (2 wei headroom per side) buy in [lower, upper] at the venue spot the adapter mints at.
    function _liquidityFor(address nu, Kind kind, int24 lower, int24 upper, uint256[] memory amounts)
        internal
        view
        returns (uint128)
    {
        uint160 sqrtP;
        if (kind == Kind.V3) {
            (sqrtP,,,,,,) = IUniswapV3PoolMinimal(address(UniswapV3Adapter(nu).POOL())).slot0();
        } else {
            (sqrtP,) = UniswapV4Adapter(nu).spot();
        }
        return LiquidityAmounts.getLiquidityForAmounts(
            sqrtP,
            TickMath.getSqrtRatioAtTick(lower),
            TickMath.getSqrtRatioAtTick(upper),
            amounts[0] > 2 ? amounts[0] - 2 : 0,
            amounts[1] > 2 ? amounts[1] - 2 : 0
        );
    }

    function _logDeploy(uint256 i, address nu, uint256[] memory amounts, uint256 gasUsed) internal view {
        (, uint256[] memory pos) = IPositionAdapter(nu).position();
        console2.log(
            string.concat(
                "deploy [",
                vm.toString(i),
                "] ",
                vm.toString(nu),
                " in ",
                vm.toString(amounts[0]),
                "/",
                vm.toString(amounts[1]),
                " pos ",
                vm.toString(pos[0]),
                "/",
                vm.toString(pos[1]),
                " tokenId ",
                vm.toString(_tokenId(nu)),
                " gas ",
                vm.toString(gasUsed)
            )
        );
    }

    function _verify() internal {
        State memory st = _load();
        IPositionAdapter[] memory all = vault.adapters();
        uint256 legacy;
        for (uint256 i; i < all.length; ++i) {
            if (_isLegacy(address(all[i]), _kind(address(all[i])))) ++legacy;
        }
        uint256 live;
        for (uint256 i; i < st.old.length; ++i) {
            address nu = st.next[i];
            require(!vault.isAdapter(st.old[i]), "verify: a legacy adapter is still registered");
            require(nu != address(0) && vault.isAdapter(nu), "verify: replacement not registered");
            if (_tokenId(nu) != 0) ++live;
            (address[] memory pt, uint256[] memory pos) = IPositionAdapter(nu).position();
            console2.log(
                string.concat(
                    "verify [",
                    vm.toString(i),
                    "] ",
                    vm.toString(nu),
                    " tokenId ",
                    vm.toString(_tokenId(nu)),
                    " pos ",
                    vm.toString(pos[0]),
                    "/",
                    vm.toString(pos[1]),
                    " adapter idle ",
                    vm.toString(IERC20(pt[0]).balanceOf(nu)),
                    "/",
                    vm.toString(IERC20(pt[1]).balanceOf(nu))
                )
            );
        }
        console2.log("verify adapterCount     :", all.length);
        console2.log("verify legacy remaining :", legacy);
        console2.log("verify replaced         :", st.old.length);
        console2.log("verify live positions   :", live);
        console2.log("verify supply pre/post  :", st.preSupply, vault.totalSupply());
        (address[] memory t, uint256[] memory totals) = vault.totalTokens();
        for (uint256 j; j < t.length; ++j) {
            uint256 pre = j < st.preTotals.length ? st.preTotals[j] : 0;
            uint256 idle = IERC20(t[j]).balanceOf(address(vault));
            console2.log(
                string.concat(
                    "verify ",
                    vm.toString(t[j]),
                    " total pre ",
                    vm.toString(pre),
                    " post ",
                    vm.toString(totals[j]),
                    " (",
                    _signedBps(pre, totals[j]),
                    " bps) idle ",
                    vm.toString(idle),
                    " (",
                    vm.toString(totals[j] == 0 ? 0 : Math.mulDiv(idle, FULL_BPS, totals[j])),
                    " bps of total)"
                )
            );
        }
        require(legacy == 0, "verify: legacy adapters remain");
        require(
            vault.totalSupply() == st.preSupply || vm.envOr("ISSUE8_ALLOW_SUPPLY_DRIFT", false),
            "verify: supply changed during the swap (user flow in between? ISSUE8_ALLOW_SUPPLY_DRIFT=true to accept)"
        );
    }

    /*//////////////////////////////////////////////////////////////
                          ADAPTER INTROSPECTION
    //////////////////////////////////////////////////////////////*/

    function _kind(address a) internal view returns (Kind) {
        if (IPositionAdapter(a).dex() == keccak256("UNISWAP_V3")) {
            return Kind.V3;
        }
        UniswapV4HookedAdapter h = UniswapV4HookedAdapter(a);
        try h.HOOKS() returns (address hooks) {
            PoolKey memory k = PoolKey({
                currency0: address(0),
                currency1: address(h.TOKEN1()),
                fee: h.POOL_FEE(),
                tickSpacing: h.TICK_SPACING(),
                hooks: hooks
            });
            return keccak256(abi.encode(k)) == h.POOL_ID() ? Kind.V4_NATIVE : Kind.V4_HOOKED;
        } catch {
            return Kind.V4; // the hookless adapter has no HOOKS()
        }
    }

    /// @dev Legacy = runtime size differs from the merged-tree artifact of the same family.
    function _isLegacy(address a, Kind kind) internal view returns (bool) {
        return a.code.length != vm.getDeployedCode(_artifact(kind)).length;
    }

    function _read(address a) internal view returns (Cfg memory c) {
        c.kind = _kind(a);
        // Shared surface (same selectors in all four families); read through the v4 hookless ABI.
        UniswapV4Adapter v = UniswapV4Adapter(a);
        c.vault = v.VAULT();
        c.owner = v.owner();
        c.rangeBelow = v.rangeTicksBelow();
        c.rangeAbove = v.rangeTicksAbove();
        c.twapWindow = v.twapWindow();
        c.maxSlippageBps = v.maxSlippageBps();
        c.constraints = [v.minTick(), v.maxTick(), v.minRangeTicks(), v.maxRangeTicks()];
        c.poolId = v.poolId();
        if (c.kind == Kind.V3) {
            UniswapV3Adapter v3 = UniswapV3Adapter(a);
            c.pool = address(v3.POOL());
            c.positionManager = address(v3.POSITION_MANAGER());
            c.swapExecutor = address(v3.SWAP_EXECUTOR());
            c.swapRouter = ISwapExecutor(c.swapExecutor).UNIVERSAL_ROUTER();
            c.permit2 = ISwapExecutor(c.swapExecutor).PERMIT2();
            return c;
        }
        c.pool = address(v.REF_POOL());
        c.positionManager = address(v.POSITION_MANAGER());
        c.swapExecutor = address(v.SWAP_EXECUTOR());
        c.swapRouter = ISwapExecutor(c.swapExecutor).UNIVERSAL_ROUTER();
        c.venue = uint8(v.swapVenue());
        c.key = PoolKey({
            currency0: c.kind == Kind.V4_NATIVE ? address(0) : address(v.TOKEN0()),
            currency1: address(v.TOKEN1()),
            fee: v.POOL_FEE(),
            tickSpacing: v.TICK_SPACING(),
            hooks: c.kind == Kind.V4 ? address(0) : UniswapV4HookedAdapter(a).HOOKS()
        });
        require(keccak256(abi.encode(c.key)) == c.poolId, "DeployIssue8Swap: pool key does not hash to POOL_ID");
    }

    function _clone(Cfg memory c) internal returns (address) {
        if (c.kind == Kind.V3) {
            return address(
                new UniswapV3Adapter(
                    UniswapV3Adapter.Config({
                        vault: c.vault,
                        pool: c.pool,
                        positionManager: c.positionManager,
                        swapRouter: c.swapRouter,
                        permit2: c.permit2,
                        swapExecutor: c.swapExecutor,
                        owner: c.owner,
                        rangeTicksBelow: c.rangeBelow,
                        rangeTicksAbove: c.rangeAbove,
                        twapWindow: c.twapWindow,
                        maxSlippageBps: c.maxSlippageBps
                    })
                )
            );
        }
        if (c.kind == Kind.V4) {
            return address(
                new UniswapV4Adapter(
                    UniswapV4Adapter.Config({
                        vault: c.vault,
                        positionManager: c.positionManager,
                        poolKey: c.key,
                        refPool: c.pool,
                        swapRouter: c.swapRouter,
                        swapExecutor: c.swapExecutor,
                        owner: c.owner,
                        rangeTicksBelow: c.rangeBelow,
                        rangeTicksAbove: c.rangeAbove,
                        twapWindow: c.twapWindow,
                        maxSlippageBps: c.maxSlippageBps
                    })
                )
            );
        }
        if (c.kind == Kind.V4_HOOKED) {
            return address(
                new UniswapV4HookedAdapter(
                    UniswapV4HookedAdapter.Config({
                        vault: c.vault,
                        positionManager: c.positionManager,
                        poolKey: c.key,
                        refPool: c.pool,
                        swapRouter: c.swapRouter,
                        swapExecutor: c.swapExecutor,
                        owner: c.owner,
                        rangeTicksBelow: c.rangeBelow,
                        rangeTicksAbove: c.rangeAbove,
                        twapWindow: c.twapWindow,
                        maxSlippageBps: c.maxSlippageBps
                    })
                )
            );
        }
        return address(
            new UniswapV4NativeEthAdapter(
                UniswapV4NativeEthAdapter.Config({
                    vault: c.vault,
                    positionManager: c.positionManager,
                    poolKey: c.key,
                    refPool: c.pool,
                    swapRouter: c.swapRouter,
                    swapExecutor: c.swapExecutor,
                    owner: c.owner,
                    rangeTicksBelow: c.rangeBelow,
                    rangeTicksAbove: c.rangeAbove,
                    twapWindow: c.twapWindow,
                    maxSlippageBps: c.maxSlippageBps
                })
            )
        );
    }

    /// @dev Owner setters a constructor cannot take: swap venue (v4 family) and range constraints (when narrowed).
    ///      Both are adapter-owner calls, so the signer must be the adapter owner when one is needed.
    function _configure(address nu, Cfg memory c) internal {
        UniswapV4Adapter v = UniswapV4Adapter(nu); // shared selectors
        if (c.kind != Kind.V3 && c.venue != uint8(v.swapVenue())) {
            require(msg.sender == c.owner, "DeployIssue8Swap: setSwapVenue needs the adapter owner signer");
            // SwapVenue is the same 2-value enum (V3_REF_POOL, V4_POOL) in all three v4 families.
            v.setSwapVenue(UniswapV4Adapter.SwapVenue(c.venue));
        }
        int24[4] memory d = [v.minTick(), v.maxTick(), v.minRangeTicks(), v.maxRangeTicks()];
        if (
            d[0] != c.constraints[0] || d[1] != c.constraints[1] || d[2] != c.constraints[2] || d[3] != c.constraints[3]
        ) {
            require(msg.sender == c.owner, "DeployIssue8Swap: setRangeConstraints needs the adapter owner signer");
            v.setRangeConstraints(c.constraints[0], c.constraints[1], c.constraints[2], c.constraints[3]);
        }
    }

    /// @dev addAdapter derives the mask from ERC-165; re-apply an owner narrowing (bits can only be cleared).
    function _narrowCaps(address nu, uint8 oldCaps) internal {
        uint8 caps = vault.adapterCapabilities(IPositionAdapter(nu));
        require(caps & oldCaps == oldCaps, "DeployIssue8Swap: clone lacks a capability the old adapter had");
        for (uint8 bit = 1; bit <= 2; bit <<= 1) {
            if (caps & bit != 0 && oldCaps & bit == 0) {
                vault.setAdapterCapability(IPositionAdapter(nu), bit, false);
            }
        }
    }

    function _assertSameConfig(Cfg memory a, Cfg memory b) internal pure {
        require(a.kind == b.kind, "config: kind");
        require(a.vault == b.vault && a.owner == b.owner, "config: vault/owner");
        require(a.pool == b.pool && a.positionManager == b.positionManager, "config: pool/posm");
        require(a.swapExecutor == b.swapExecutor && a.swapRouter == b.swapRouter, "config: executor/router");
        require(a.poolId == b.poolId, "config: poolId");
        require(a.rangeBelow == b.rangeBelow && a.rangeAbove == b.rangeAbove, "config: range ticks");
        require(a.twapWindow == b.twapWindow && a.maxSlippageBps == b.maxSlippageBps, "config: twap/slippage");
        require(a.venue == b.venue, "config: swap venue");
        for (uint256 k; k < 4; ++k) {
            require(a.constraints[k] == b.constraints[k], "config: range constraints");
        }
    }

    function _tokenId(address a) internal view returns (uint256) {
        return UniswapV4Adapter(a).tokenId(); // same selector in all four families
    }

    function _artifact(Kind kind) internal pure returns (string memory) {
        if (kind == Kind.V3) return "UniswapV3Adapter.sol:UniswapV3Adapter";
        if (kind == Kind.V4) return "UniswapV4Adapter.sol:UniswapV4Adapter";
        if (kind == Kind.V4_HOOKED) return "UniswapV4HookedAdapter.sol:UniswapV4HookedAdapter";
        return "UniswapV4NativeEthAdapter.sol:UniswapV4NativeEthAdapter";
    }

    function _kindName(Kind kind) internal pure returns (string memory) {
        if (kind == Kind.V3) return "v3";
        if (kind == Kind.V4) return "v4";
        if (kind == Kind.V4_HOOKED) return "v4-hooked";
        return "v4-native";
    }

    /*//////////////////////////////////////////////////////////////
                               STATE FILE
    //////////////////////////////////////////////////////////////*/

    function _statePath(bool dry) internal view returns (string memory) {
        string memory label = vm.envOr("ISSUE8_LABEL", string("mainnet"));
        if (dry) label = string.concat(label, "-dryrun");
        return string.concat(
            vm.projectRoot(),
            "/broadcast/issue8/",
            label,
            "-",
            vm.toString(block.chainid),
            "-",
            vm.toString(address(vault)),
            ".json"
        );
    }

    function _stateExists() internal view returns (bool) {
        return vm.exists(_statePath(false)) || (_isDryRun() && vm.exists(_statePath(true)));
    }

    function _find(address[] memory arr, uint256 n, address a) internal pure returns (uint256 k) {
        for (; k < n; ++k) {
            if (arr[k] == a) return k;
        }
    }

    function _copyEntry(State memory dst, uint256 j, State memory src, uint256 k) internal pure {
        dst.old[j] = src.old[k];
        dst.next[j] = src.next[k];
        dst.kind[j] = src.kind[k];
        dst.caps[j] = src.caps[k];
        dst.token0[j] = src.token0[k];
        dst.token1[j] = src.token1[k];
        dst.pulled0[j] = src.pulled0[k];
        dst.pulled1[j] = src.pulled1[k];
        dst.net0[j] = src.net0[k];
        dst.net1[j] = src.net1[k];
        dst.lower[j] = src.lower[k];
        dst.upper[j] = src.upper[k];
        dst.liq[j] = src.liq[k];
        dst.deployed[j] = src.deployed[k];
    }

    function _isDryRun() internal view returns (bool) {
        return vm.isContext(VmSafe.ForgeContext.ScriptDryRun);
    }

    function _newState(uint256 cap) internal view returns (State memory st) {
        st.vault = address(vault);
        st.preSupply = vault.totalSupply();
        (st.tokens, st.preTotals) = vault.totalTokens();
        st.old = new address[](cap);
        st.next = new address[](cap);
        st.kind = new uint256[](cap);
        st.caps = new uint256[](cap);
        st.token0 = new address[](cap);
        st.token1 = new address[](cap);
        st.pulled0 = new uint256[](cap);
        st.pulled1 = new uint256[](cap);
        st.net0 = new uint256[](cap);
        st.net1 = new uint256[](cap);
        st.lower = new int256[](cap);
        st.upper = new int256[](cap);
        st.liq = new uint256[](cap);
        st.deployed = new bool[](cap);
    }

    function _shrink(State memory st, uint256 n) internal pure {
        address[] memory a0 = st.old;
        address[] memory a1 = st.next;
        uint256[] memory u0 = st.kind;
        uint256[] memory u1 = st.caps;
        address[] memory a2 = st.token0;
        address[] memory a3 = st.token1;
        uint256[] memory u2 = st.pulled0;
        uint256[] memory u3 = st.pulled1;
        uint256[] memory u4 = st.net0;
        uint256[] memory u5 = st.net1;
        bool[] memory b0 = st.deployed;
        int256[] memory i0 = st.lower;
        int256[] memory i1 = st.upper;
        uint256[] memory u6 = st.liq;
        assembly ("memory-safe") {
            mstore(i0, n)
            mstore(i1, n)
            mstore(u6, n)
            mstore(a0, n)
            mstore(a1, n)
            mstore(u0, n)
            mstore(u1, n)
            mstore(a2, n)
            mstore(a3, n)
            mstore(u2, n)
            mstore(u3, n)
            mstore(u4, n)
            mstore(u5, n)
            mstore(b0, n)
        }
    }

    function _save(State memory st) internal {
        string memory path = _statePath(_isDryRun());
        vm.createDir(string.concat(vm.projectRoot(), "/broadcast/issue8"), true);
        vm.serializeAddress(OBJ, "vault", st.vault);
        vm.serializeUint(OBJ, "chainId", block.chainid);
        vm.serializeUint(OBJ, "preSupply", st.preSupply);
        vm.serializeAddress(OBJ, "tokens", st.tokens);
        vm.serializeUint(OBJ, "preTotals", st.preTotals);
        vm.serializeAddress(OBJ, "old", st.old);
        vm.serializeAddress(OBJ, "next", st.next);
        vm.serializeUint(OBJ, "kind", st.kind);
        vm.serializeUint(OBJ, "caps", st.caps);
        vm.serializeAddress(OBJ, "token0", st.token0);
        vm.serializeAddress(OBJ, "token1", st.token1);
        vm.serializeUint(OBJ, "pulled0", st.pulled0);
        vm.serializeUint(OBJ, "pulled1", st.pulled1);
        vm.serializeUint(OBJ, "net0", st.net0);
        vm.serializeUint(OBJ, "net1", st.net1);
        vm.serializeInt(OBJ, "lower", st.lower);
        vm.serializeInt(OBJ, "upper", st.upper);
        vm.serializeUint(OBJ, "liq", st.liq);
        string memory json = vm.serializeBool(OBJ, "deployed", st.deployed);
        vm.writeJson(json, path);
        console2.log("state saved  :", path);
    }

    /// @dev A dry run prefers its own `-dryrun` file (written by an earlier dry phase) and falls back to the real one.
    function _load() internal view returns (State memory st) {
        string memory path = _statePath(false);
        if (_isDryRun() && vm.exists(_statePath(true))) {
            path = _statePath(true);
        }
        require(vm.exists(path), string.concat("DeployIssue8Swap: no state file ", path, " - run PHASE=pull first"));
        string memory json = vm.readFile(path);
        st.vault = vm.parseJsonAddress(json, ".vault");
        require(st.vault == address(vault), "DeployIssue8Swap: state file is for another vault");
        require(vm.parseJsonUint(json, ".chainId") == block.chainid, "DeployIssue8Swap: state file chainId");
        st.preSupply = vm.parseJsonUint(json, ".preSupply");
        st.tokens = vm.parseJsonAddressArray(json, ".tokens");
        st.preTotals = vm.parseJsonUintArray(json, ".preTotals");
        st.old = vm.parseJsonAddressArray(json, ".old");
        st.next = vm.parseJsonAddressArray(json, ".next");
        st.kind = vm.parseJsonUintArray(json, ".kind");
        st.caps = vm.parseJsonUintArray(json, ".caps");
        st.token0 = vm.parseJsonAddressArray(json, ".token0");
        st.token1 = vm.parseJsonAddressArray(json, ".token1");
        st.pulled0 = vm.parseJsonUintArray(json, ".pulled0");
        st.pulled1 = vm.parseJsonUintArray(json, ".pulled1");
        st.net0 = vm.parseJsonUintArray(json, ".net0");
        st.net1 = vm.parseJsonUintArray(json, ".net1");
        st.lower = vm.parseJsonIntArray(json, ".lower");
        st.upper = vm.parseJsonIntArray(json, ".upper");
        st.liq = vm.parseJsonUintArray(json, ".liq");
        st.deployed = vm.parseJsonBoolArray(json, ".deployed");
        console2.log("state loaded :", path);
    }

    function _ix(State memory st, address token) internal pure returns (uint256) {
        for (uint256 j; j < st.tokens.length; ++j) {
            if (st.tokens[j] == token) return j;
        }
        revert("DeployIssue8Swap: adapter token not in the vault registry");
    }

    function _scaled(uint256 amount, uint256 idle, uint256 sum) internal pure returns (uint256) {
        return idle >= sum ? amount : Math.mulDiv(amount, idle, sum);
    }

    function _signedBps(uint256 pre, uint256 post) internal pure returns (string memory) {
        if (pre == 0) return "n/a";
        if (post >= pre) return string.concat("+", vm.toString(Math.mulDiv(post - pre, FULL_BPS * 100, pre)), "/100");
        return string.concat("-", vm.toString(Math.mulDiv(pre - post, FULL_BPS * 100, pre)), "/100");
    }
}
