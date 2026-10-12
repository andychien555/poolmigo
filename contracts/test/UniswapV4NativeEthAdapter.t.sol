// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {UniswapV4NativeEthAdapter} from "contracts/adapters/UniswapV4NativeEthAdapter.sol";
import {UniversalRouterNativeSwapExecutor} from "contracts/swap/UniversalRouterNativeSwapExecutor.sol";
import {UniversalRouterSwapExecutor} from "contracts/swap/UniversalRouterSwapExecutor.sol";
import {INativeSwapExecutor} from "contracts/interfaces/INativeSwapExecutor.sol";
import {ISwapExecutor} from "contracts/interfaces/ISwapExecutor.sol";
import {IPositionAdapter} from "contracts/interfaces/IPositionAdapter.sol";
import {ILiquidityAdapter} from "contracts/interfaces/ILiquidityAdapter.sol";
import {ISwapAdapter} from "contracts/interfaces/ISwapAdapter.sol";
import {IUniversalRouter} from "contracts/adapters/uniswap/IUniversalRouter.sol";
import {INativeWrapperMinimal} from "contracts/adapters/uniswap/IWETH9Minimal.sol";
import {PoolKey} from "contracts/adapters/uniswap/v4/IPoolManagerMinimal.sol";
import {MockToken} from "test/mocks/MockToken.sol";
import {MockV3Factory, MockV3Pool} from "test/mocks/MockV3Pool.sol";
import {MockPermit2Router} from "test/mocks/MockPermit2Router.sol";
import {MockV4Venue} from "test/DeployAdapters.t.sol";

/**
 * @notice Constructor policy (native-only + the sibling's hook policy), vault gating and the no-ETH surface of
 *         {UniswapV4NativeEthAdapter}, plus the gating / revert paths of {UniversalRouterNativeSwapExecutor}, on the local
 *         mock venue ({MockV4Venue} — every pool reads as initialized — + MockV3Pool reference + MockPermit2Router as UR
 *         and Permit2). The PositionManager's `WETH9()` is mocked to a MockToken standing in for WETH (constructor checks
 *         need no wrap). Position / swap flows run on the REAL native pool in `test/fork/FablesRampEthUsdg.fork.t.sol`.
 *         Hook addresses are crafted (the v4 permission bits are the address's low 14 bits) and given code by etch.
 */
contract UniswapV4NativeEthAdapterTest is Test {
    // v4-core Hooks permission flags (address bits).
    uint160 internal constant BEFORE_INITIALIZE = 1 << 13;
    uint160 internal constant BEFORE_ADD_LIQUIDITY = 1 << 11;
    uint160 internal constant BEFORE_REMOVE_LIQUIDITY = 1 << 9;
    uint160 internal constant BEFORE_SWAP = 1 << 7;
    uint160 internal constant AFTER_SWAP = 1 << 6;
    uint160 internal constant BEFORE_SWAP_RETURNS_DELTA = 1 << 3;
    uint160 internal constant AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA = 1 << 0;
    uint24 internal constant DYNAMIC_FEE_FLAG = 0x800000;
    /// @dev High bits of every crafted hook address (anything above the 14 flag bits).
    uint160 internal constant HOOK_BASE = uint160(0xF0AB5) << 140;
    /// @dev The live FablesRampETH hook of the RHC ETH/USDG native pool (bits 0x2080).
    address internal constant FABLES_RAMP_ETH = 0x06a889870C8f83640D6816319f72e2aA579b6080;

    MockToken internal weth; // sorts first: the v3 reference is (WETH, currency1)
    MockToken internal usdg;
    MockV3Factory internal factory;
    MockV3Pool internal refPool;
    MockPermit2Router internal router;
    MockV4Venue internal venue;
    UniversalRouterNativeSwapExecutor internal executor;

    address internal vault = makeAddr("vault");
    address internal owner = makeAddr("owner");

    function setUp() public {
        MockToken a = new MockToken("Token A", "TKA", 18);
        MockToken b = new MockToken("Token B", "TKB", 6);
        (weth, usdg) = address(a) < address(b) ? (a, b) : (b, a);
        factory = new MockV3Factory();
        router = new MockPermit2Router(factory);
        refPool = new MockV3Pool(address(factory), address(weth), address(usdg), 100, uint160(1 << 96), 1e24);
        factory.register(refPool);
        assertEq(refPool.token0(), address(weth));
        venue = new MockV4Venue(address(router)); // Permit2 = the mock router
        vm.mockCall(address(router), abi.encodeCall(IUniversalRouter.poolManager, ()), abi.encode(address(venue)));
        vm.mockCall(address(venue), abi.encodeCall(INativeWrapperMinimal.WETH9, ()), abi.encode(address(weth)));
        executor = new UniversalRouterNativeSwapExecutor(address(router), address(router), address(weth));
    }

    /*//////////////////////////////////////////////////////////////
                               ACCEPTED
    //////////////////////////////////////////////////////////////*/

    /// @dev The live RHC ETH/USDG key shape: native currency0, dynamic fee, spacing 10, the REAL FablesRampETH address.
    function test_AcceptsFablesRampEthHook_NativeDynamicFee() public {
        vm.etch(FABLES_RAMP_ETH, hex"00");
        assertEq(uint160(FABLES_RAMP_ETH) & 0x3FFF, 0x2080, "FablesRampETH permission bits");
        assertEq(uint160(FABLES_RAMP_ETH) & 0x0F0F, 0, "outside the forbidden mask");
        PoolKey memory key = _key(DYNAMIC_FEE_FLAG, FABLES_RAMP_ETH);
        key.tickSpacing = 10;
        UniswapV4NativeEthAdapter a = _newAdapter(key);
        _assertKeyWiring(a, key);
        assertEq(a.POOL_FEE(), DYNAMIC_FEE_FLAG, "POOL_FEE = the dynamic-fee flag, as in the PoolKey");
        assertEq(address(a.SWAP_EXECUTOR()), address(executor));
        assertEq(a.dex(), keccak256("UNISWAP_V4"), "same DEX_ID as the v4 siblings");
    }

    function test_AcceptsNonDeltaSwapCallbacks() public {
        PoolKey memory key = _key(DYNAMIC_FEE_FLAG, _hook(BEFORE_INITIALIZE | BEFORE_SWAP | AFTER_SWAP));
        _assertKeyWiring(_newAdapter(key), key);
    }

    function test_AcceptsStaticFeeWithHook() public {
        PoolKey memory key = _key(3000, _hook(BEFORE_INITIALIZE | BEFORE_SWAP));
        UniswapV4NativeEthAdapter a = _newAdapter(key);
        _assertKeyWiring(a, key);
        assertEq(a.POOL_FEE(), 3000);
    }

    /// @dev A plain (hookless) native pool still works.
    function test_AcceptsZeroHooks() public {
        PoolKey memory key = _key(500, address(0));
        UniswapV4NativeEthAdapter a = _newAdapter(key);
        _assertKeyWiring(a, key);
        assertEq(a.HOOKS(), address(0));
    }

    /// @dev ERC-165: both capabilities, as the sibling (the vault derives its capability mask from these).
    function test_SupportsLiquidityAndSwapInterfaces() public {
        UniswapV4NativeEthAdapter a = _newAdapter(_key(500, address(0)));
        assertTrue(a.supportsInterface(type(ILiquidityAdapter).interfaceId));
        assertTrue(a.supportsInterface(type(ISwapAdapter).interfaceId));
        assertFalse(a.supportsInterface(0xdeadbeef));
    }

    /*//////////////////////////////////////////////////////////////
                         REJECTED — NATIVE POLICY
    //////////////////////////////////////////////////////////////*/

    /// @dev An ERC-20 currency0 is the hooked sibling's case, never this adapter's.
    function test_RejectsErc20Currency0() public {
        PoolKey memory key = _key(500, address(0));
        key.currency0 = address(weth);
        vm.expectRevert(
            abi.encodeWithSelector(
                UniswapV4NativeEthAdapter.UniswapV4NativeEthAdapter__NotNativePool.selector, address(weth)
            )
        );
        _newAdapter(key);
    }

    /// @dev The reference must be the v3 (WETH, currency1) pool: a pool of another pair is a venue mismatch.
    function test_RejectsReferenceOfAnotherPair() public {
        MockToken other = new MockToken("Other", "OTH", 18);
        MockV3Pool wrong = new MockV3Pool(address(factory), address(other), address(usdg), 100, uint160(1 << 96), 1e24);
        factory.register(wrong);
        vm.expectRevert(
            abi.encodeWithSelector(
                UniswapV4NativeEthAdapter.UniswapV4NativeEthAdapter__VenueMismatch.selector, address(wrong)
            )
        );
        _newAdapterWith(_key(500, address(0)), address(wrong), address(executor));
    }

    /// @dev WETH sorting AFTER currency1 would invert the v3 tick against the native pool: rejected (the reference's
    ///      token0 is then currency1, not WETH).
    function test_RejectsWethSortingAfterCurrency1() public {
        MockToken low = new MockToken("Low", "LOW", 6);
        MockToken high = new MockToken("High", "HIGH", 18);
        if (address(low) > address(high)) (low, high) = (high, low);
        MockV3Pool ref = new MockV3Pool(address(factory), address(low), address(high), 100, uint160(1 << 96), 1e24);
        factory.register(ref);
        // The PositionManager's WETH9 is `high`; the pool key's currency1 is `low`.
        vm.mockCall(address(venue), abi.encodeCall(INativeWrapperMinimal.WETH9, ()), abi.encode(address(high)));
        UniversalRouterNativeSwapExecutor exec =
            new UniversalRouterNativeSwapExecutor(address(router), address(router), address(high));
        PoolKey memory key = _key(500, address(0));
        key.currency1 = address(low);
        vm.expectRevert(
            abi.encodeWithSelector(
                UniswapV4NativeEthAdapter.UniswapV4NativeEthAdapter__VenueMismatch.selector, address(ref)
            )
        );
        _newAdapterWith(key, address(ref), address(exec));
    }

    /// @dev The executor must bridge through the PositionManager's own WETH9.
    function test_RejectsExecutorOnAnotherWeth() public {
        MockToken otherWeth = new MockToken("Other WETH", "OWETH", 18);
        UniversalRouterNativeSwapExecutor exec =
            new UniversalRouterNativeSwapExecutor(address(router), address(router), address(otherWeth));
        vm.expectRevert(
            abi.encodeWithSelector(
                UniswapV4NativeEthAdapter.UniswapV4NativeEthAdapter__ExecutorMismatch.selector, address(exec)
            )
        );
        _newAdapterWith(_key(500, address(0)), address(refPool), address(exec));
    }

    /// @dev The shared ERC-20 executor has no `WETH9()` / native path: construction fails (it would brick every v4
    ///      venue swap).
    function test_RejectsSharedErc20Executor() public {
        UniversalRouterSwapExecutor erc20Exec = new UniversalRouterSwapExecutor(address(router), address(router));
        vm.expectRevert();
        _newAdapterWith(_key(500, address(0)), address(refPool), address(erc20Exec));
    }

    /*//////////////////////////////////////////////////////////////
                          REJECTED — HOOK POLICY
    //////////////////////////////////////////////////////////////*/

    function test_RejectsLiquidityCallbackHook() public {
        _expectUnsupported(_hook(BEFORE_INITIALIZE | BEFORE_SWAP | BEFORE_ADD_LIQUIDITY));
        _expectUnsupported(_hook(BEFORE_REMOVE_LIQUIDITY));
    }

    function test_RejectsDeltaHook() public {
        _expectUnsupported(_hook(BEFORE_SWAP | BEFORE_SWAP_RETURNS_DELTA));
        _expectUnsupported(_hook(AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA));
    }

    /// @dev Every one of the 8 forbidden flags alone is rejected; every one of the 6 allowed flags alone is accepted.
    function test_ForbiddenMaskIsExactly0x0F0F() public {
        UniswapV4NativeEthAdapter probe = _newAdapter(_key(500, address(0)));
        assertEq(probe.HOOK_FORBIDDEN_FLAGS(), 0x0F0F);
        for (uint256 bit; bit < 14; ++bit) {
            uint160 flag = uint160(1 << bit);
            address hook = _hook(flag);
            if (flag & 0x0F0F != 0) {
                _expectUnsupported(hook);
            } else {
                assertEq(_newAdapter(_key(DYNAMIC_FEE_FLAG, hook)).HOOKS(), hook);
            }
        }
    }

    function test_RejectsZeroCodeHook() public {
        address hook = address(HOOK_BASE | BEFORE_INITIALIZE | BEFORE_SWAP);
        assertEq(hook.code.length, 0);
        vm.expectRevert(
            abi.encodeWithSelector(UniswapV4NativeEthAdapter.UniswapV4NativeEthAdapter__NoCode.selector, hook)
        );
        _newAdapter(_key(DYNAMIC_FEE_FLAG, hook));
    }

    function test_RejectsDynamicFeeWithoutHook() public {
        vm.expectRevert(UniswapV4NativeEthAdapter.UniswapV4NativeEthAdapter__DynamicFeeWithoutHook.selector);
        _newAdapter(_key(DYNAMIC_FEE_FLAG, address(0)));
    }

    /// @dev Same parameter bounds as the sibling.
    function test_RejectsOutOfBoundsParams() public {
        UniswapV4NativeEthAdapter.Config memory cfg = _cfg(_key(500, address(0)), address(refPool), address(executor));
        cfg.twapWindow = 299;
        vm.expectRevert(
            abi.encodeWithSelector(
                UniswapV4NativeEthAdapter.UniswapV4NativeEthAdapter__TwapWindowOutOfRange.selector, 299, 300, 7 days
            )
        );
        new UniswapV4NativeEthAdapter(cfg);
        cfg.twapWindow = 1800;
        cfg.maxSlippageBps = 1001;
        vm.expectRevert(
            abi.encodeWithSelector(
                UniswapV4NativeEthAdapter.UniswapV4NativeEthAdapter__SlippageOutOfRange.selector, 1001, 1, 1000
            )
        );
        new UniswapV4NativeEthAdapter(cfg);
        cfg.maxSlippageBps = 200;
        cfg.rangeTicksBelow = 0;
        vm.expectRevert(
            abi.encodeWithSelector(UniswapV4NativeEthAdapter.UniswapV4NativeEthAdapter__InvalidRange.selector, 0, 600)
        );
        new UniswapV4NativeEthAdapter(cfg);
        cfg.rangeTicksBelow = 600;
        cfg.vault = address(0);
        vm.expectRevert(UniswapV4NativeEthAdapter.UniswapV4NativeEthAdapter__ZeroAddress.selector);
        new UniswapV4NativeEthAdapter(cfg);
    }

    /*//////////////////////////////////////////////////////////////
                         GATING / NO-ETH SURFACE
    //////////////////////////////////////////////////////////////*/

    /// @dev Every position op is vault-only, as on the sibling.
    function test_VaultOnlyEntrypoints() public {
        UniswapV4NativeEthAdapter a = _newAdapter(_key(500, address(0)));
        bytes4 onlyVault = UniswapV4NativeEthAdapter.UniswapV4NativeEthAdapter__OnlyVault.selector;
        address stranger = makeAddr("stranger");
        vm.startPrank(stranger);
        vm.expectRevert(onlyVault);
        a.deploy(new uint256[](2));
        vm.expectRevert(onlyVault);
        a.withdrawProportional(1e18, stranger);
        vm.expectRevert(onlyVault);
        a.harvest();
        vm.expectRevert(onlyVault);
        a.unwindAll(stranger);
        vm.expectRevert(onlyVault);
        a.addLiquidity(ILiquidityAdapter.AddLiquidityParams(-600, 600, 1, 1, 1, 1, 0));
        vm.expectRevert(onlyVault);
        a.removeLiquidity(ILiquidityAdapter.RemoveLiquidityParams(0, 0, 0));
        vm.expectRevert(onlyVault);
        a.swapExactIn(ISwapAdapter.SwapParams(address(weth), address(usdg), 1, 1));
        vm.stopPrank();
    }

    /// @dev No payable surface: neither a plain ETH send nor value on a vault call is accepted (the adapter's ETH
    ///      balance is 0 by construction; every native step is bridged inside the PositionManager call).
    function test_RejectsNativeEth() public {
        UniswapV4NativeEthAdapter a = _newAdapter(_key(500, address(0)));
        vm.deal(vault, 1 ether);
        vm.startPrank(vault);
        (bool ok,) = address(a).call{value: 1}("");
        assertFalse(ok, "plain ETH send");
        (ok,) = address(a).call{value: 1}(abi.encodeCall(IPositionAdapter.harvest, ()));
        assertFalse(ok, "ETH on a vault call");
        vm.stopPrank();
        assertEq(address(a).balance, 0);
    }

    /*//////////////////////////////////////////////////////////////
                    NATIVE SWAP EXECUTOR — GATING / REVERTS
    //////////////////////////////////////////////////////////////*/

    function test_Executor_Wiring() public view {
        assertEq(executor.WETH9(), address(weth));
        assertEq(executor.POOL_MANAGER(), address(venue), "the router's PoolManager");
        assertEq(executor.UNIVERSAL_ROUTER(), address(router));
        assertEq(executor.PERMIT2(), address(router));
    }

    function test_Executor_ConstructorRejectsBadWeth() public {
        vm.expectRevert(ISwapExecutor.SwapExecutor__ZeroAddress.selector);
        new UniversalRouterNativeSwapExecutor(address(router), address(router), address(0));
        address noCode = makeAddr("noCode");
        vm.expectRevert(abi.encodeWithSelector(ISwapExecutor.SwapExecutor__NoCode.selector, noCode));
        new UniversalRouterNativeSwapExecutor(address(router), address(router), noCode);
    }

    function test_Executor_RejectsNonNativeKeyAndZeroAmounts() public {
        PoolKey memory erc20Key = _key(500, address(0));
        erc20Key.currency0 = address(weth);
        vm.expectRevert(abi.encodeWithSelector(INativeSwapExecutor.SwapExecutor__NotNativePool.selector, address(weth)));
        executor.swapV4NativeExactIn(erc20Key, true, 1, 1);
        vm.expectRevert(ISwapExecutor.SwapExecutor__ZeroAmount.selector);
        executor.swapV4NativeExactIn(_key(500, address(0)), true, 0, 1);
        vm.expectRevert(ISwapExecutor.SwapExecutor__ZeroMinOut.selector);
        executor.swapV4NativeExactIn(_key(500, address(0)), false, 1, 0);
    }

    /// @dev ETH is accepted only from WETH / the PoolManager AND only mid-swap: outside a swap even those two senders
    ///      are refused, and a stranger always is — nothing can be parked in the executor.
    function test_Executor_ReceiveGated() public {
        address[3] memory senders = [address(weth), address(venue), makeAddr("stranger")];
        for (uint256 i; i < senders.length; ++i) {
            vm.deal(senders[i], 1 ether);
            vm.prank(senders[i]);
            (bool ok, bytes memory ret) = address(executor).call{value: 1}("");
            assertFalse(ok, "ETH refused outside a swap");
            assertEq(ret, abi.encodeWithSelector(INativeSwapExecutor.SwapExecutor__UnexpectedEth.selector, senders[i]));
        }
        assertEq(address(executor).balance, 0);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev HOOKS, the native pool key the adapter re-derives (observed through POOL_ID = the key's hash), and the
    ///      vault-facing vector [WETH, currency1].
    function _assertKeyWiring(UniswapV4NativeEthAdapter a, PoolKey memory key) internal view {
        assertEq(key.currency0, address(0));
        assertEq(a.HOOKS(), key.hooks, "HOOKS = key.hooks");
        assertEq(a.poolId(), keccak256(abi.encode(key)), "poolId = keccak256(abi.encode(native key incl. hooks))");
        assertEq(address(a.TOKEN0()), address(weth), "token0 = the PositionManager's WETH9");
        assertEq(address(a.TOKEN1()), key.currency1);
        assertEq(a.TICK_SPACING(), key.tickSpacing);
    }

    function _expectUnsupported(address hook) internal {
        vm.expectRevert(
            abi.encodeWithSelector(UniswapV4NativeEthAdapter.UniswapV4NativeEthAdapter__UnsupportedHook.selector, hook)
        );
        _newAdapter(_key(DYNAMIC_FEE_FLAG, hook));
    }

    function _hook(uint160 flags) internal returns (address hook) {
        hook = address(HOOK_BASE | flags);
        vm.etch(hook, hex"00");
    }

    function _key(uint24 fee, address hooks) internal view returns (PoolKey memory) {
        return PoolKey({currency0: address(0), currency1: address(usdg), fee: fee, tickSpacing: 60, hooks: hooks});
    }

    function _newAdapter(PoolKey memory key) internal returns (UniswapV4NativeEthAdapter) {
        return _newAdapterWith(key, address(refPool), address(executor));
    }

    function _newAdapterWith(PoolKey memory key, address ref, address exec)
        internal
        returns (UniswapV4NativeEthAdapter)
    {
        return new UniswapV4NativeEthAdapter(_cfg(key, ref, exec));
    }

    function _cfg(PoolKey memory key, address ref, address exec)
        internal
        view
        returns (UniswapV4NativeEthAdapter.Config memory)
    {
        return UniswapV4NativeEthAdapter.Config({
            vault: vault,
            positionManager: address(venue),
            poolKey: key,
            refPool: ref,
            swapRouter: address(router),
            swapExecutor: exec,
            owner: owner,
            rangeTicksBelow: 600,
            rangeTicksAbove: 600,
            twapWindow: 1800,
            maxSlippageBps: 200
        });
    }
}
