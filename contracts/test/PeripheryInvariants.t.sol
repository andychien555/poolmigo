// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.34;

import {Test, console2} from "forge-std/Test.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {StdAssertions} from "forge-std/StdAssertions.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {MySunVaultUpgradeable} from "contracts/MySunVaultUpgradeable.sol";
import {IPoolmigoVault} from "contracts/interfaces/IPoolmigoVault.sol";
import {IPositionAdapter} from "contracts/interfaces/IPositionAdapter.sol";
import {ILiquidityAdapter} from "contracts/interfaces/ILiquidityAdapter.sol";
import {ISwapAdapter} from "contracts/interfaces/ISwapAdapter.sol";
import {PlanExecutor} from "contracts/periphery/PlanExecutor.sol";
import {PoolmigoCreate3, Create3Dispatcher} from "contracts/periphery/PoolmigoCreate3.sol";
import {MySunZapIn} from "contracts/periphery/MySunZapIn.sol";
import {MySunZapOut} from "contracts/periphery/MySunZapOut.sol";
import {MockToken} from "test/mocks/MockToken.sol";
import {MockLiquidityAdapter} from "test/mocks/MockLiquidityAdapter.sol";
import {MockPlanVault} from "test/mocks/MockPlanVault.sol";
import {MockPositionAdapter} from "test/mocks/MockPositionAdapter.sol";
import {MockPermit2Router} from "test/mocks/MockPermit2Router.sol";
import {MockV3Factory, MockV3Pool} from "test/mocks/MockV3Pool.sol";
import {VaultImplArgs} from "test/utils/VaultImplArgs.sol";

/*//////////////////////////////////////////////////////////////
                         1. PLAN EXECUTOR
//////////////////////////////////////////////////////////////*/

/**
 * @notice Fuzzed keeper surface of {PlanExecutor} over {MockPlanVault}. `executeValid` builds a plan that must succeed
 *         (or, for a de-whitelisted keeper, must revert `NotKeeper` untouched); `executeFaulty` injects exactly ONE
 *         fault into an otherwise valid plan and asserts its exact error with nonce and vault trail untouched;
 *         `replayLast` re-submits a keeper's last successful plan (must revert `InvalidNonce`). The world moves under
 *         the keepers (supply, positionState pins, time, keeper whitelist). Never reverts (`fail_on_revert`).
 */
contract PlanHandler is CommonBase, StdCheats, StdUtils, StdAssertions {
    PlanExecutor public immutable exec;
    MockPlanVault public immutable mv;
    MockLiquidityAdapter public immutable la;
    MockLiquidityAdapter public immutable lb;
    address public immutable owner;
    address public immutable stranger;
    address[2] internal _keepers;
    address public immutable tA;
    address public immutable tB;

    mapping(address keeper => uint256) public ghostNonce;
    uint256 public ghostCalls; // expected mv.callCount(): Σ components of successful plans
    mapping(address keeper => bytes) internal _lastPlan;
    uint256 public ghostReplaySucceeded;
    mapping(uint256 fault => uint256) public faultHits;
    uint256 public successes;

    constructor(
        PlanExecutor exec_,
        MockPlanVault mv_,
        MockLiquidityAdapter la_,
        MockLiquidityAdapter lb_,
        address owner_,
        address k1,
        address k2,
        address stranger_,
        address tA_,
        address tB_
    ) {
        exec = exec_;
        mv = mv_;
        la = la_;
        lb = lb_;
        owner = owner_;
        _keepers = [k1, k2];
        stranger = stranger_;
        tA = tA_;
        tB = tB_;
    }

    function keepers() external view returns (address[2] memory) {
        return _keepers;
    }

    function executeValid(uint256 keeperSeed, uint256 planSeed) external {
        address k = _keepers[keeperSeed % 2];
        PlanExecutor.Plan memory plan = _validPlan(k, planSeed);
        if (!exec.isKeeper(k)) {
            _expectRejected(k, plan, abi.encodeWithSelector(PlanExecutor.PlanExecutor__NotKeeper.selector, k));
            return;
        }
        uint256 callsBefore = mv.callCount();
        vm.prank(k);
        exec.executePlan(plan);
        assertEq(exec.nonces(k), plan.nonce + 1, "P-1 nonce +1 on success");
        assertEq(mv.callCount(), callsBefore + plan.components.length, "P-2 every component dispatched");
        for (uint256 i; i < plan.components.length; ++i) {
            MockPlanVault.Call memory c = mv.callAt(callsBefore + i);
            assertEq(c.kind, plan.components[i].kind, "P-2 array order = execution order");
            assertEq(c.caller, address(exec), "P-2 the vault sees the executor");
            if (c.kind != 0) assertEq(c.adapter, plan.components[i].adapter, "P-2 adapter verbatim");
        }
        ghostNonce[k] = plan.nonce + 1;
        ghostCalls += plan.components.length;
        _lastPlan[k] = abi.encode(plan);
        ++successes;
    }

    /// @notice One fault per plan; checks run in the executor's order, so each fault has exactly one expected error.
    function executeFaulty(uint256 keeperSeed, uint256 planSeed, uint256 faultSeed) external {
        address k = _keepers[keeperSeed % 2];
        if (!exec.isKeeper(k)) return; // NotKeeper is exercised by executeValid / fault 0
        PlanExecutor.Plan memory plan = _validPlan(k, planSeed);
        uint256 fault = faultSeed % 10;
        address caller = k;
        bytes memory expected;
        if (fault == 0) {
            caller = stranger;
            expected = abi.encodeWithSelector(PlanExecutor.PlanExecutor__NotKeeper.selector, stranger);
        } else if (fault == 1) {
            plan.deadline = uint64(block.timestamp - 1 - bound(faultSeed, 0, 1 days));
            expected =
                abi.encodeWithSelector(PlanExecutor.PlanExecutor__Expired.selector, plan.deadline, block.timestamp);
        } else if (fault == 2 || fault == 3) {
            uint256 live = plan.nonce;
            // 2: replay of an already-consumed nonce (or, before any, a skip); 3: any future nonce
            plan.nonce = fault == 2 && live != 0 ? bound(faultSeed, 0, live - 1) : live + bound(faultSeed, 1, 1e6);
            expected = abi.encodeWithSelector(PlanExecutor.PlanExecutor__InvalidNonce.selector, live, plan.nonce);
        } else if (fault == 4) {
            uint256 live = plan.expectedTotalSupply;
            plan.expectedTotalSupply = live ^ (1 + bound(faultSeed, 0, 255)); // any different value
            expected = abi.encodeWithSelector(
                PlanExecutor.PlanExecutor__SupplyMismatch.selector, plan.expectedTotalSupply, live
            );
        } else if (fault == 5) {
            uint256 j = faultSeed % plan.pins.length;
            PlanExecutor.Pin memory p = plan.pins[j];
            uint256 field = (faultSeed / 7) % 5;
            if (field == 0) p.tokenId += 1;
            else if (field == 1) p.tickLower = p.tickLower == type(int24).min ? int24(0) : p.tickLower - 1;
            else if (field == 2) p.tickUpper = p.tickUpper == type(int24).max ? int24(0) : p.tickUpper + 1;
            else if (field == 3) p.liquidity = p.liquidity ^ 1;
            else p.configVersion = p.configVersion ^ 1;
            expected = abi.encodeWithSelector(PlanExecutor.PlanExecutor__PinMismatch.selector, j, p.adapter);
        } else if (fault == 6) {
            // Pin only `la`; the first component names `lb`.
            PlanExecutor.Pin[] memory pins = new PlanExecutor.Pin[](1);
            pins[0] = _pinOf(la);
            plan.pins = pins;
            PlanExecutor.Component[] memory comps = new PlanExecutor.Component[](1);
            comps[0] = PlanExecutor.Component(exec.KIND_CLOSE_POSITION(), address(lb), "");
            plan.components = comps;
            expected = abi.encodeWithSelector(PlanExecutor.PlanExecutor__UnpinnedAdapter.selector, 0, address(lb));
        } else if (fault == 7) {
            PlanExecutor.Component[] memory comps = _withOne(plan.components, plan.pins, faultSeed);
            uint256 j = comps.length - 1;
            bytes memory bad = abi.encodePacked(comps[j].payload, bytes1(0x00)); // one byte too long
            if (faultSeed % 2 == 0 && comps[j].payload.length != 0) bad = _trim(comps[j].payload); // one byte short
            comps[j].payload = bad;
            plan.components = comps;
            expected = abi.encodeWithSelector(PlanExecutor.PlanExecutor__InvalidPayload.selector, j, bad.length);
        } else if (fault == 8) {
            PlanExecutor.Component[] memory comps = _withOne(plan.components, plan.pins, faultSeed);
            uint256 j = comps.length - 1;
            uint8 kind = uint8(bound(faultSeed, 5, 255));
            comps[j] = PlanExecutor.Component(kind, address(la), "");
            plan.components = comps;
            expected = abi.encodeWithSelector(PlanExecutor.PlanExecutor__UnsupportedComponent.selector, j, kind);
        } else {
            // A later component fails inside the vault: everything before it rolls back (all-or-nothing).
            plan.components = _withOne(plan.components, plan.pins, faultSeed);
            uint256 failIdx = faultSeed % plan.components.length;
            uint256 failCall = mv.callCount() + failIdx + 1;
            mv.setFailAt(failCall);
            expected = abi.encodeWithSelector(MockPlanVault.MockPlanVault__Fail.selector, failCall);
        }
        _expectRejected(caller, plan, expected);
        mv.setFailAt(0);
        ++faultHits[fault];
    }

    /// @notice A consumed (keeper, nonce) can never run again.
    function replayLast(uint256 keeperSeed) external {
        address k = _keepers[keeperSeed % 2];
        if (_lastPlan[k].length == 0 || !exec.isKeeper(k)) return;
        PlanExecutor.Plan memory plan = abi.decode(_lastPlan[k], (PlanExecutor.Plan));
        // Refresh the volatile pins so the ONLY stale thing is the nonce.
        plan.deadline = uint64(block.timestamp);
        plan.expectedTotalSupply = mv.totalSupply();
        for (uint256 i; i < plan.pins.length; ++i) {
            plan.pins[i] = _pinOf(MockLiquidityAdapter(plan.pins[i].adapter));
        }
        uint256 callsBefore = mv.callCount();
        vm.prank(k);
        try exec.executePlan(plan) {
            ++ghostReplaySucceeded;
        } catch (bytes memory err) {
            assertEq(
                err,
                abi.encodeWithSelector(PlanExecutor.PlanExecutor__InvalidNonce.selector, exec.nonces(k), plan.nonce),
                "P-3 replay rejected by nonce"
            );
        }
        assertEq(mv.callCount(), callsBefore, "P-3 replay dispatches nothing");
        ++faultHits[100];
    }

    /* the world moves */

    function moveSupply(uint256 supply) external {
        mv.setTotalSupply(bound(supply, 0, 1e30));
    }

    function movePin(uint256 adapterSeed, int24 lower, int24 upper, uint128 liquidity, uint32 version) external {
        (adapterSeed % 2 == 0 ? la : lb).setPositionState(lower, upper, liquidity, version);
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 0, 7 days));
    }

    function toggleKeeper(uint256 keeperSeed) external {
        address k = _keepers[keeperSeed % 2];
        bool allowed = !exec.isKeeper(k); // read BEFORE the prank (an argument call would consume it)
        vm.prank(owner);
        exec.setKeeper(k, allowed);
    }

    /* internals */

    function _expectRejected(address caller, PlanExecutor.Plan memory plan, bytes memory expected) internal {
        uint256 callsBefore = mv.callCount();
        uint256 nonceBefore = exec.nonces(caller);
        vm.prank(caller);
        try exec.executePlan(plan) {
            fail("P-4 faulty plan executed");
        } catch (bytes memory err) {
            assertEq(err, expected, "P-4 exact rejection");
        }
        assertEq(exec.nonces(caller), nonceBefore, "P-1 nonce untouched on revert");
        assertEq(mv.callCount(), callsBefore, "P-4 vault trail untouched on revert");
    }

    function _validPlan(address k, uint256 seed) internal view returns (PlanExecutor.Plan memory plan) {
        plan.nonce = exec.nonces(k);
        plan.deadline = uint64(block.timestamp + bound(seed, 0, 1 hours));
        plan.expectedTotalSupply = mv.totalSupply();
        uint256 pinSet = seed % 3; // 0: la, 1: lb, 2: both
        plan.pins = new PlanExecutor.Pin[](pinSet == 2 ? 2 : 1);
        plan.pins[0] = _pinOf(pinSet == 1 ? lb : la);
        if (pinSet == 2) plan.pins[1] = _pinOf(lb);
        uint256 n = (seed >> 8) % 5; // 0 … 4 components (an empty plan still consumes a nonce)
        plan.components = new PlanExecutor.Component[](n);
        for (uint256 i; i < n; ++i) {
            uint256 h = uint256(keccak256(abi.encode(seed, i)));
            address ad = plan.pins[h % plan.pins.length].adapter;
            plan.components[i] = _component(uint8(h % 5), ad, h);
        }
    }

    function _component(uint8 kind, address ad, uint256 h) internal view returns (PlanExecutor.Component memory) {
        bytes memory payload;
        if (kind == 1) {
            payload = abi.encode(ISwapAdapter.SwapParams(tA, tB, h % 1e24, (h >> 80) % 1e24));
        } else if (kind == 2) {
            payload = abi.encode(
                ILiquidityAdapter.AddLiquidityParams(
                    -int24(int256(h % 1000)),
                    int24(int256(h % 777)) + 1,
                    uint128(h),
                    uint128(h >> 128),
                    h % 1e24,
                    h % 1e20,
                    h % 7
                )
            );
        } else if (kind == 3) {
            payload = abi.encode(ILiquidityAdapter.RemoveLiquidityParams(uint128(h >> 64), h % 1e18, h % 1e17));
        }
        // kind 0 (harvest) names an arbitrary, unpinned address: the executor must ignore it
        return PlanExecutor.Component(kind, kind == 0 ? address(uint160(h)) : ad, payload);
    }

    function _pinOf(MockLiquidityAdapter a) internal view returns (PlanExecutor.Pin memory p) {
        (uint256 id, int24 lo, int24 up, uint128 liq, uint32 ver) = a.positionState();
        p = PlanExecutor.Pin(address(a), id, lo, up, liq, ver);
    }

    /// @dev `comps` + one more VALID component of a random kind on the plan's first pinned adapter (a slot for the
    ///      fault to land in; on its own it would run).
    function _withOne(PlanExecutor.Component[] memory comps, PlanExecutor.Pin[] memory pins, uint256 seed)
        internal
        view
        returns (PlanExecutor.Component[] memory out)
    {
        out = new PlanExecutor.Component[](comps.length + 1);
        for (uint256 i; i < comps.length; ++i) {
            out[i] = comps[i];
        }
        uint256 h = uint256(keccak256(abi.encode(seed, "slot")));
        out[comps.length] = _component(uint8(h % 5), pins[0].adapter, h);
    }

    function _trim(bytes memory b) internal pure returns (bytes memory t) {
        t = new bytes(b.length - 1);
        for (uint256 i; i < t.length; ++i) {
            t[i] = b[i];
        }
    }
}

/**
 * @notice {PlanExecutor} stateful invariants against {MockPlanVault} (two whitelisted keepers, one stranger, two
 *         {MockLiquidityAdapter} pin sources moving under the keepers).
 *
 *         P-1 (INV-33) per-keeper nonce == the handler's count of that keeper's successful plans: it moves by exactly 1
 *             on every success and never on a revert (also asserted per op); the stranger's nonce stays 0.
 *         P-2 (INV-33) the vault's call trail == Σ components of successful plans, every entry dispatched by the
 *             executor (failed plans leave no trace — all-or-nothing).
 *         P-3 (INV-33) no (keeper, nonce) replay ever succeeds.
 *         P-4 (INV-33) every single-fault plan (caller, deadline, past/future nonce, supply pin, each pin field,
 *             unpinned adapter, payload ±1 byte, unknown kind, mid-plan vault failure) reverts with its exact error and
 *             leaves state untouched — asserted per op.
 *         P-5 (INV-33) the executor holds nothing and approves nothing: zero token balances, zero allowances to the
 *             vault / adapters, zero ETH.
 *
 * forge-config: default.invariant.runs = 256
 * forge-config: default.invariant.depth = 64
 * forge-config: default.invariant.fail-on-revert = true
 */
contract PlanExecutorInvariantsTest is Test {
    PlanExecutor internal exec;
    MockPlanVault internal mv;
    MockLiquidityAdapter internal la;
    MockLiquidityAdapter internal lb;
    MockToken internal tA;
    MockToken internal tB;
    PlanHandler internal handler;

    address internal owner = makeAddr("owner");
    address internal k1 = makeAddr("keeper1");
    address internal k2 = makeAddr("keeper2");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        vm.warp(1_700_000_000);
        tA = new MockToken("Token A", "TKA", 18);
        tB = new MockToken("Token B", "TKB", 6);
        address[] memory basket = new address[](2);
        (basket[0], basket[1]) = (address(tA), address(tB));
        mv = new MockPlanVault();
        mv.setTotalSupply(1_000e18);
        exec = new PlanExecutor(IPoolmigoVault(address(mv)), owner);
        la = new MockLiquidityAdapter(basket, address(mv), "LA", bytes32(uint256(1)));
        lb = new MockLiquidityAdapter(basket, address(mv), "LB", bytes32(uint256(2)));
        lb.setPositionState(-600, 600, 5e17, 7);
        vm.startPrank(owner);
        exec.setKeeper(k1, true);
        exec.setKeeper(k2, true);
        vm.stopPrank();

        handler = new PlanHandler(exec, mv, la, lb, owner, k1, k2, stranger, address(tA), address(tB));
        handler.executeValid(0, 0x1234_02);
        handler.executeValid(1, 0x0300);
        // Deterministic sweep: every single-fault branch (and its exact-error assertion) runs at least once.
        for (uint256 f; f < 10; ++f) {
            handler.executeFaulty(f, 0x0402 + f * 0x100, f + 70);
        }
        handler.replayLast(0);

        targetContract(address(handler));
        bytes4[] memory s = new bytes4[](11);
        s[0] = PlanHandler.executeValid.selector;
        s[1] = PlanHandler.executeValid.selector;
        s[2] = PlanHandler.executeValid.selector;
        s[3] = PlanHandler.executeFaulty.selector;
        s[4] = PlanHandler.executeFaulty.selector;
        s[5] = PlanHandler.executeFaulty.selector;
        s[6] = PlanHandler.replayLast.selector;
        s[7] = PlanHandler.moveSupply.selector;
        s[8] = PlanHandler.movePin.selector;
        s[9] = PlanHandler.warp.selector;
        s[10] = PlanHandler.toggleKeeper.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: s}));
    }

    function invariant_P1_noncesTrackSuccesses() public view {
        address[2] memory ks = handler.keepers();
        for (uint256 i; i < 2; ++i) {
            assertEq(exec.nonces(ks[i]), handler.ghostNonce(ks[i]), "P-1 nonce == successful plans");
        }
        assertEq(exec.nonces(stranger), 0, "P-1 stranger never consumes a nonce");
    }

    function invariant_P2_trailIsSuccessfulComponentsOnly() public view {
        uint256 n = mv.callCount();
        assertEq(n, handler.ghostCalls(), "P-2 trail == components of successful plans");
        for (uint256 i; i < n; ++i) {
            assertEq(mv.callAt(i).caller, address(exec), "P-2 dispatched by the executor");
        }
    }

    function invariant_P3_noReplay() public view {
        assertEq(handler.ghostReplaySucceeded(), 0, "P-3 replay succeeded");
    }

    function afterInvariant() public view {
        console2.log("successes", handler.successes());
        for (uint256 f; f < 10; ++f) {
            console2.log("fault", f, handler.faultHits(f));
        }
        console2.log("replays", handler.faultHits(100));
    }

    function invariant_P5_holdsAndApprovesNothing() public view {
        address[4] memory spenders = [address(mv), address(la), address(lb), address(handler)];
        MockToken[2] memory toks = [tA, tB];
        for (uint256 t; t < 2; ++t) {
            assertEq(toks[t].balanceOf(address(exec)), 0, "P-5 holds no tokens");
            for (uint256 s; s < spenders.length; ++s) {
                assertEq(toks[t].allowance(address(exec), spenders[s]), 0, "P-5 approves nothing");
            }
        }
        assertEq(address(exec).balance, 0, "P-5 holds no ETH");
    }
}

/*//////////////////////////////////////////////////////////////
                            2. CREATE3
//////////////////////////////////////////////////////////////*/

/// @dev Constructor that always reverts — a failed deploy must not burn the salt.
contract RevertingInit {
    error RevertingInit__No();

    constructor() {
        revert RevertingInit__No();
    }
}

/// @dev Payable constructor — the value lands in the deployed contract, never in the factory or dispatcher.
contract PayableInit {
    constructor() payable {}
}

/**
 * @notice Fuzzed deployers × a small salt space (collisions are frequent) × varied creation code (two token shapes, a
 *         reverting constructor, a payable one with value). Never reverts (`fail_on_revert`): every expected revert is
 *         asserted through try/catch.
 */
contract Create3Handler is CommonBase, StdCheats, StdUtils, StdAssertions {
    uint256 public constant N_SALTS = 6;
    PoolmigoCreate3 public immutable factory;
    address[3] internal _deployers;

    mapping(address deployer => mapping(bytes32 salt => bool)) public used;
    address[] internal _deployed;
    address[] internal _deployedBy;
    bytes32[] internal _deployedSalt;
    uint256 public reverted;
    uint256 public collisions;

    constructor(PoolmigoCreate3 factory_, address d0, address d1, address d2) {
        factory = factory_;
        _deployers = [d0, d1, d2];
    }

    function deployers() external view returns (address[3] memory) {
        return _deployers;
    }

    function salt(uint256 i) public pure returns (bytes32) {
        return keccak256(abi.encode("mysun.salt", i % N_SALTS));
    }

    function deployments() external view returns (address[] memory, address[] memory, bytes32[] memory) {
        return (_deployed, _deployedBy, _deployedSalt);
    }

    function deploy(uint256 deployerSeed, uint256 saltSeed, uint256 codeSeed, uint256 value) external {
        address d = _deployers[deployerSeed % 3];
        bytes32 s = salt(saltSeed);
        address predicted = factory.create3Address(d, s);
        assertEq(predicted, _derive(d, s), "C-1 prediction == independent CREATE3 derivation");

        uint256 kind = codeSeed % 4;
        bytes memory code;
        if (kind == 0) code = abi.encodePacked(type(MockToken).creationCode, abi.encode("A", "A", uint8(18)));
        else if (kind == 1) code = abi.encodePacked(type(MockToken).creationCode, abi.encode("B", "B", uint8(6)));
        else if (kind == 2) code = type(RevertingInit).creationCode;
        else code = type(PayableInit).creationCode;
        value = kind == 3 ? bound(value, 0, 1 ether) : 0;
        vm.deal(d, d.balance + value);

        vm.prank(d);
        try factory.deploy{value: value}(s, code) returns (address deployed) {
            assertFalse(used[d][s], "C-2 occupied salt redeployed");
            assertTrue(kind != 2, "C-3 reverting constructor deployed");
            assertEq(deployed, predicted, "C-1 lands at the prediction");
            assertGt(deployed.code.length, 0, "C-1 code present");
            assertEq(deployed.balance, value, "C-4 value lands in the deployed contract");
            used[d][s] = true;
            _deployed.push(deployed);
            _deployedBy.push(d);
            _deployedSalt.push(s);
        } catch (bytes memory err) {
            if (used[d][s]) {
                assertEq(
                    err,
                    abi.encodeWithSelector(
                        PoolmigoCreate3.Create3__SaltAlreadyUsed.selector, factory.dispatcherAddress(d, s)
                    ),
                    "C-2 occupied salt reverts SaltAlreadyUsed"
                );
                ++collisions;
            } else {
                assertEq(kind, 2, "C-3 only the reverting constructor fails on a free salt");
                assertEq(err, abi.encodeWithSelector(RevertingInit.RevertingInit__No.selector), "C-3 bubbled");
                assertEq(factory.dispatcherAddress(d, s).code.length, 0, "C-3 failed deploy burns no salt");
                assertEq(predicted.code.length, 0, "C-3 nothing at the target");
                ++reverted;
            }
        }
    }

    /// @dev effective = keccak256(salt ‖ deployer); dispatcher = CREATE2(factory, effective, dispatcher initcode);
    ///      target = keccak256(0xd6 0x94 ‖ dispatcher ‖ 0x01)[12:].
    function _derive(address d, bytes32 s) internal view returns (address) {
        address dispatcher = vm.computeCreate2Address(
            keccak256(abi.encodePacked(s, d)), keccak256(type(Create3Dispatcher).creationCode), address(factory)
        );
        return
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xd6), bytes1(0x94), dispatcher, bytes1(0x01))))));
    }
}

/**
 * @notice {PoolmigoCreate3} stateful invariants.
 *
 *         C-1 (INV-23 deploy path, K-17) for any (deployer, salt) the deployed address equals `create3Address` and the
 *             independent CREATE3 derivation, independent of the creation code (per op); recorded deployments stay
 *             where predicted (the prediction never drifts).
 *         C-2 re-deploying an occupied (deployer, salt) reverts `SaltAlreadyUsed` (per op); occupied ⇔ the dispatcher
 *             exists, for every deployer × salt.
 *         C-3 a reverting constructor bubbles its error and burns no salt (per op).
 *         C-4 the factory and every dispatcher hold no ETH (value forwarded to the target); distinct (deployer, salt)
 *             pairs never share an address.
 *
 * forge-config: default.invariant.runs = 256
 * forge-config: default.invariant.depth = 32
 * forge-config: default.invariant.fail-on-revert = true
 */
contract Create3InvariantsTest is Test {
    PoolmigoCreate3 internal factory;
    Create3Handler internal handler;

    function setUp() public {
        factory = new PoolmigoCreate3();
        handler = new Create3Handler(factory, makeAddr("deployerA"), makeAddr("deployerB"), makeAddr("deployerC"));
        targetContract(address(handler));
    }

    function invariant_C1_deploymentsStayPredicted() public view {
        (address[] memory dep, address[] memory by, bytes32[] memory s) = handler.deployments();
        for (uint256 i; i < dep.length; ++i) {
            assertEq(factory.create3Address(by[i], s[i]), dep[i], "C-1 prediction stable");
            assertGt(dep[i].code.length, 0, "C-1 code still there");
            for (uint256 j; j < i; ++j) {
                assertTrue(dep[i] != dep[j], "C-4 distinct pairs, distinct addresses");
            }
        }
    }

    function invariant_C2_occupiedIffDispatcher() public view {
        address[3] memory ds = handler.deployers();
        for (uint256 d; d < 3; ++d) {
            for (uint256 i; i < handler.N_SALTS(); ++i) {
                bytes32 s = handler.salt(i);
                address dispatcher = factory.dispatcherAddress(ds[d], s);
                assertEq(handler.used(ds[d], s), dispatcher.code.length != 0, "C-2 occupied <=> dispatcher exists");
                assertEq(dispatcher.balance, 0, "C-4 dispatcher holds no ETH");
            }
        }
    }

    function invariant_C4_factoryHoldsNothing() public view {
        assertEq(address(factory).balance, 0, "C-4 factory holds no ETH");
    }

    function afterInvariant() public view {
        (address[] memory dep,,) = handler.deployments();
        console2.log("deployed", dep.length);
        console2.log("collisions", handler.collisions());
        console2.log("revertingCtor", handler.reverted());
    }
}

/*//////////////////////////////////////////////////////////////
                         3. ZAPS (light)
//////////////////////////////////////////////////////////////*/

/**
 * @notice Fuzzed USDG-only zap-in / zap-out traffic on the ZapIn/ZapOut unit-suite world (real vault behind an ERC1967
 *         proxy, dual-role {MockPermit2Router}, constant-liquidity {MockV3Pool} at the live RHC fee-100 depth), plus a
 *         WETH-output zap-out (`doZapOutWeth`): a USDG exit sells the whole WETH slice, so the sweep would only ever
 *         see a nonzero balance at registry index 0 — the WETH exit leaves WETH (index 1, the output) and USDG (no
 *         route, passed through) at sweep time, keeping the sweep's per-token branch live. After every swap the pool's
 *         TWAP is synced to spot (a quiet period) so the one-sided deviation guard never trips on the harness's own
 *         flow. Every action is clamped revert-free (`fail_on_revert`).
 */
contract ZapHandler is CommonBase, StdCheats, StdUtils, StdAssertions {
    MySunVaultUpgradeable public immutable vault;
    MySunZapIn public immutable zapIn;
    MySunZapOut public immutable zapOut;
    MockPermit2Router public immutable router;
    MockV3Pool public immutable pool;
    MockToken public immutable usdg;
    MockToken public immutable weth;
    MockPositionAdapter public immutable adapter;
    address[] internal _actors;

    uint256 public zapsIn;
    uint256 public zapsOut;
    uint256 public zapsOutWeth;
    uint256 public roundTrips;

    constructor(
        MySunVaultUpgradeable vault_,
        MySunZapIn zapIn_,
        MySunZapOut zapOut_,
        MockPermit2Router router_,
        MockV3Pool pool_,
        MockToken usdg_,
        MockToken weth_,
        MockPositionAdapter adapter_
    ) {
        vault = vault_;
        zapIn = zapIn_;
        zapOut = zapOut_;
        router = router_;
        pool = pool_;
        usdg = usdg_;
        weth = weth_;
        adapter = adapter_;
    }

    function addActor(address a) external {
        _actors.push(a);
        vm.startPrank(a);
        usdg.approve(address(zapIn), type(uint256).max);
        vault.approve(address(zapOut), type(uint256).max);
        vm.stopPrank();
    }

    function doZapIn(uint256 actorSeed, uint256 receiverSeed, uint256 amount) external {
        address a = _actor(actorSeed);
        _zapIn(a, _actor(receiverSeed), bound(amount, 10e6, 250_000e6));
    }

    function doZapOut(uint256 actorSeed, uint256 receiverSeed, uint256 sharesSeed) external {
        address a = _actor(actorSeed);
        uint256 bal = vault.balanceOf(a);
        if (bal < 1e16) return;
        _zapOut(a, _actor(receiverSeed), bound(sharesSeed, 1e16, bal), usdg);
    }

    /// @notice Zap out into WETH (registry index 1): its slice IS the output (never sold) and USDG has no route
    ///         (passes through), so both registry tokens carry a nonzero balance at sweep time — keeps the sweep's
    ///         per-token branch for index ≥ 1 live in the harness (Z-1 catches a sweep that skips it).
    function doZapOutWeth(uint256 actorSeed, uint256 receiverSeed, uint256 sharesSeed) external {
        address a = _actor(actorSeed);
        uint256 bal = vault.balanceOf(a);
        if (bal < 1e16) return;
        _zapOut(a, _actor(receiverSeed), bound(sharesSeed, 1e16, bal), weth);
        ++zapsOutWeth;
    }

    /// @notice Zap in, then zap the minted shares straight back out: the zaps keep nothing, and the USDG returned
    ///         never exceeds the USDG put in (pool fee + impact + vault rounding all go against the round-tripper).
    function roundTrip(uint256 actorSeed, uint256 amount) external {
        address a = _actor(actorSeed);
        amount = bound(amount, 10e6, 250_000e6);
        uint256 shares = _zapIn(a, a, amount);
        uint256 out = _zapOut(a, a, shares, usdg);
        assertLe(out, amount, "Z-2 zap round trip never gains USDG");
        ++roundTrips;
    }

    /// @notice The vault's own venue earns fees (in-kind basket growth between zaps).
    function accrueFees(uint256 u, uint256 w) external {
        uint256[] memory f = new uint256[](2);
        (f[0], f[1]) = (bound(u, 0, 1_000e6), bound(w, 0, 0.5e18));
        adapter.simulateFees(f);
    }

    function _zapIn(address a, address r, uint256 amount) internal returns (uint256 shares) {
        usdg.mint(a, amount);
        uint256 before = vault.balanceOf(r);
        vm.prank(a);
        (shares,) = zapIn.zapDeposit(address(vault), address(usdg), amount, 1, 0, r);
        assertEq(vault.balanceOf(r) - before, shares, "shares to receiver");
        pool.syncTwapToSpot();
        ++zapsIn;
    }

    /// @dev Registry order is [USDG, WETH] (setUp's basket): the receiver's delta per token == the sweep's
    ///      `delivered`, and the output token's delivery == `amountOut`.
    function _zapOut(address a, address r, uint256 shares, MockToken out) internal returns (uint256 amountOut) {
        MockToken[2] memory toks = [usdg, weth];
        uint256[2] memory before = [usdg.balanceOf(r), weth.balanceOf(r)];
        uint256[] memory delivered;
        vm.prank(a);
        (amountOut, delivered) = zapOut.zapRedeem(address(vault), address(out), shares, 1, 0, r);
        for (uint256 j; j < 2; ++j) {
            assertEq(toks[j].balanceOf(r) - before[j], delivered[j], "sweep delivery to receiver");
            if (toks[j] == out) assertEq(delivered[j], amountOut, "tokenOut to receiver");
        }
        pool.syncTwapToSpot();
        ++zapsOut;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return _actors[seed % _actors.length];
    }
}

/**
 * @notice Zap residue invariants (INV-35's "holds nothing"), light: one USDG/WETH vault, both zaps registered.
 *
 *         Z-1 (INV-35 / INV-19) after any call both zaps hold zero USDG, zero WETH and zero vault shares, and every
 *             allowance layer they control is zero (ERC-20 → Permit2, Permit2 → router, ERC-20 → vault). The
 *             WETH-output zap-out gives the sweep a nonzero residue at every registry index, so a sweep that skips
 *             any token fails here.
 *         Z-2 a zap-in followed by a zap-out leaves no residue in either zap (Z-1 holds after the compound action:
 *             residue tolerance is exactly 0 — both zaps sweep their whole balance) and returns ≤ the USDG put in.
 *
 * forge-config: default.invariant.runs = 64
 * forge-config: default.invariant.depth = 64
 * forge-config: default.invariant.fail-on-revert = true
 */
contract ZapInvariantsTest is Test {
    uint256 internal constant GENESIS = 200_000e18;
    uint128 internal constant LIVE_L = 5_086e15; // live RHC fee-100 USDG/WETH in-range liquidity (zap findings T0)
    uint24 internal constant FEE100 = 100;
    uint256 internal constant ETH_USDG = 2_727e6;

    address internal owner = makeAddr("owner");
    address internal keeper = makeAddr("keeper");
    MockToken internal usdg;
    MockToken internal weth;
    MockV3Factory internal factory;
    MockPermit2Router internal router;
    MockV3Pool internal pool;
    MySunVaultUpgradeable internal vault;
    MySunZapIn internal zapIn;
    MySunZapOut internal zapOut;
    MockPositionAdapter internal adapter;
    ZapHandler internal handler;

    function setUp() public {
        usdg = new MockToken("Mock USDG", "USDG", 6);
        weth = _orderedToken("Mock WETH", 18); // live orientation: WETH is token0 of the USDG/WETH pool
        factory = new MockV3Factory();
        router = new MockPermit2Router(factory);
        zapIn = new MySunZapIn(address(router), address(router), owner);
        zapOut = new MySunZapOut(address(router), address(router), owner);

        uint160 sqrtP = uint160(Math.sqrt(Math.mulDiv(ETH_USDG, 1 << 192, 1e18))); // token0 = WETH: P = USDG per WETH
        pool = new MockV3Pool(address(factory), address(usdg), address(weth), FEE100, sqrtP, LIVE_L);
        factory.register(pool);
        usdg.mint(address(pool), 1e30);
        weth.mint(address(pool), 1e40);

        address[] memory basket = new address[](2);
        (basket[0], basket[1]) = (address(usdg), address(weth));
        vault = MySunVaultUpgradeable(
            address(
                new ERC1967Proxy(
                    address(new MySunVaultUpgradeable(VaultImplArgs.depositSplit())),
                    abi.encodeCall(
                        MySunVaultUpgradeable(address(0)).initialize,
                        (owner, "sunEthLP", "sunEthLP", basket, makeAddr("treasury"), 1500, GENESIS, 0)
                    )
                )
            )
        );
        uint256[] memory seed = new uint256[](2);
        (seed[0], seed[1]) = (100_000e6, Math.mulDiv(100_000e6, 1e18, ETH_USDG));
        adapter = new MockPositionAdapter(basket, address(vault), "MOCK", bytes32(0));
        vm.startPrank(owner);
        usdg.mint(owner, seed[0]);
        weth.mint(owner, seed[1]);
        usdg.approve(address(vault), seed[0]);
        weth.approve(address(vault), seed[1]);
        vault.deposit(basket, seed, GENESIS, owner);
        vault.addAdapter(IPositionAdapter(address(adapter)));
        vault.setKeeper(keeper, true);
        zapIn.registerVault(address(vault));
        zapIn.setRoute(address(usdg), address(weth), FEE100, address(pool), 600, 50, 50);
        zapOut.registerVault(address(vault));
        zapOut.setRoute(address(weth), address(usdg), FEE100, address(pool), 600, 50, 50);
        vm.stopPrank();
        (seed[0], seed[1]) = (seed[0] / 2, seed[1] / 2);
        vm.prank(keeper);
        vault.deployTo(IPositionAdapter(address(adapter)), seed);

        handler = new ZapHandler(vault, zapIn, zapOut, router, pool, usdg, weth, adapter);
        string[3] memory names = ["alice", "bob", "carol"];
        for (uint256 i; i < names.length; ++i) {
            handler.addActor(makeAddr(names[i]));
        }
        handler.doZapIn(0, 0, 5_000e6);
        handler.doZapIn(1, 1, 20_000e6);
        handler.doZapOutWeth(1, 2, 2_000e18); // the index-1 sweep runs before the first invariant check

        targetContract(address(handler));
        bytes4[] memory s = new bytes4[](7);
        s[0] = ZapHandler.doZapIn.selector;
        s[1] = ZapHandler.doZapOut.selector;
        s[2] = ZapHandler.roundTrip.selector;
        s[3] = ZapHandler.accrueFees.selector;
        s[4] = ZapHandler.doZapOut.selector;
        s[5] = ZapHandler.doZapOutWeth.selector;
        s[6] = ZapHandler.doZapOutWeth.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: s}));
    }

    function invariant_Z1_zapsHoldNothing() public view {
        address[2] memory zaps = [address(zapIn), address(zapOut)];
        address[2] memory toks = [address(usdg), address(weth)];
        for (uint256 z; z < 2; ++z) {
            assertEq(vault.balanceOf(zaps[z]), 0, "Z-1 zap holds no shares");
            assertEq(vault.allowance(zaps[z], address(vault)), 0, "Z-1 no share allowance");
            for (uint256 t; t < 2; ++t) {
                assertEq(IERC20(toks[t]).balanceOf(zaps[z]), 0, "Z-1 zap holds no residue");
                assertEq(IERC20(toks[t]).allowance(zaps[z], address(router)), 0, "Z-1 ERC20 -> Permit2 zero");
                (uint160 inner,,) = router.allowance(zaps[z], toks[t], address(router));
                assertEq(inner, 0, "Z-1 Permit2 -> router zero");
                assertEq(IERC20(toks[t]).allowance(zaps[z], address(vault)), 0, "Z-1 ERC20 -> vault zero");
            }
        }
    }

    function afterInvariant() public view {
        console2.log("zapsIn", handler.zapsIn());
        console2.log("zapsOut", handler.zapsOut());
        console2.log("zapsOutWeth", handler.zapsOutWeth());
        console2.log("roundTrips", handler.roundTrips());
    }

    /// @dev A MockToken whose address sorts below USDG (pool orientation control, as in the zap unit suites).
    function _orderedToken(string memory name, uint8 dec) internal returns (MockToken t) {
        for (uint256 salt;; ++salt) {
            t = new MockToken{salt: keccak256(abi.encode(name, salt))}(name, name, dec);
            if (address(t) < address(usdg)) return t;
        }
    }
}
