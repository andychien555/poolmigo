// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {UniswapV4HookedAdapter} from "contracts/adapters/UniswapV4HookedAdapter.sol";
import {IUniversalRouter} from "contracts/adapters/uniswap/IUniversalRouter.sol";
import {PoolKey} from "contracts/adapters/uniswap/v4/IPoolManagerMinimal.sol";
import {UniversalRouterSwapExecutor} from "contracts/swap/UniversalRouterSwapExecutor.sol";
import {MockToken} from "test/mocks/MockToken.sol";
import {MockV3Factory, MockV3Pool} from "test/mocks/MockV3Pool.sol";
import {MockPermit2Router} from "test/mocks/MockPermit2Router.sol";
import {MockV4Venue} from "test/DeployAdapters.t.sol";

/**
 * @notice Constructor hook policy of {UniswapV4HookedAdapter} on the local mock venue ({MockV4Venue} — every pool
 *         reads as initialized — + MockV3Pool reference + MockPermit2Router as UR and Permit2). Like the plain v4
 *         adapter, the hooked adapter has no unit venue for its position flows: deposit / withdraw / swap behavior is
 *         covered on the REAL hooked pool by `test/fork/FablesRampPons.fork.t.sol`.
 *         Hook addresses are crafted (the v4 permission bits are the address's low 14 bits) and given code by etch.
 */
contract UniswapV4HookedAdapterTest is Test {
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

    MockToken internal tA;
    MockToken internal tB;
    MockV3Pool internal refPool;
    MockPermit2Router internal router;
    MockV4Venue internal venue;
    UniversalRouterSwapExecutor internal executor;
    address internal currency0;
    address internal currency1;

    address internal vault = makeAddr("vault");
    address internal owner = makeAddr("owner");

    function setUp() public {
        tA = new MockToken("Token A", "TKA", 18);
        tB = new MockToken("Token B", "TKB", 18);
        MockV3Factory factory = new MockV3Factory();
        router = new MockPermit2Router(factory);
        refPool = new MockV3Pool(address(factory), address(tA), address(tB), 10_000, uint160(1 << 96), 1e24);
        factory.register(refPool);
        (currency0, currency1) = (refPool.token0(), refPool.token1());
        venue = new MockV4Venue(address(router)); // Permit2 = the mock router
        // The adapter requires its router to serve the PoolManager; the mock router reports none by default.
        vm.mockCall(address(router), abi.encodeCall(IUniversalRouter.poolManager, ()), abi.encode(address(venue)));
        executor = new UniversalRouterSwapExecutor(address(router), address(router));
    }

    /*//////////////////////////////////////////////////////////////
                               ACCEPTED
    //////////////////////////////////////////////////////////////*/

    /// @dev FablesRamp's class: beforeInitialize + beforeSwap (0x2080), dynamic fee.
    function test_AcceptsFeeOverrideHook_DynamicFee() public {
        address hook = _hook(BEFORE_INITIALIZE | BEFORE_SWAP);
        assertEq(uint160(hook) & 0x3FFF, 0x2080, "FablesRamp permission bits");
        PoolKey memory key = _key(DYNAMIC_FEE_FLAG, hook);
        UniswapV4HookedAdapter a = _newAdapter(key);
        _assertKeyWiring(a, key);
        assertEq(a.POOL_FEE(), DYNAMIC_FEE_FLAG, "POOL_FEE = the dynamic-fee flag, as in the PoolKey");
    }

    /// @dev Swap callbacks without delta flags are inside the class (afterSwap included).
    function test_AcceptsNonDeltaSwapCallbacks() public {
        PoolKey memory key = _key(DYNAMIC_FEE_FLAG, _hook(BEFORE_INITIALIZE | BEFORE_SWAP | AFTER_SWAP));
        _assertKeyWiring(_newAdapter(key), key);
    }

    function test_AcceptsStaticFeeWithHook() public {
        PoolKey memory key = _key(3000, _hook(BEFORE_INITIALIZE | BEFORE_SWAP));
        UniswapV4HookedAdapter a = _newAdapter(key);
        _assertKeyWiring(a, key);
        assertEq(a.POOL_FEE(), 3000);
    }

    /// @dev A plain pool still works: HOOKS = 0 and the key is the hookless one.
    function test_AcceptsZeroHooks() public {
        PoolKey memory key = _key(500, address(0));
        UniswapV4HookedAdapter a = _newAdapter(key);
        _assertKeyWiring(a, key);
        assertEq(a.HOOKS(), address(0));
    }

    /*//////////////////////////////////////////////////////////////
                               REJECTED
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
        UniswapV4HookedAdapter probe = _newAdapter(_key(500, address(0)));
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

    /// @dev Right permission bits but nothing deployed there.
    function test_RejectsZeroCodeHook() public {
        address hook = address(HOOK_BASE | BEFORE_INITIALIZE | BEFORE_SWAP);
        assertEq(hook.code.length, 0);
        vm.expectRevert(abi.encodeWithSelector(UniswapV4HookedAdapter.UniswapV4HookedAdapter__NoCode.selector, hook));
        _newAdapter(_key(DYNAMIC_FEE_FLAG, hook));
    }

    /// @dev The mock venue reports every key as initialized, so this is the adapter's own check (v4-core would not
    ///      initialize such a pool either).
    function test_RejectsDynamicFeeWithoutHook() public {
        vm.expectRevert(UniswapV4HookedAdapter.UniswapV4HookedAdapter__DynamicFeeWithoutHook.selector);
        _newAdapter(_key(DYNAMIC_FEE_FLAG, address(0)));
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev HOOKS and the pool key the adapter re-derives (`_poolKey()`, observed through POOL_ID = the key's hash).
    function _assertKeyWiring(UniswapV4HookedAdapter a, PoolKey memory key) internal view {
        assertEq(a.HOOKS(), key.hooks, "HOOKS = key.hooks");
        assertEq(a.poolId(), keccak256(abi.encode(key)), "poolId = keccak256(abi.encode(key incl. hooks))");
        assertEq(address(a.TOKEN0()), key.currency0);
        assertEq(address(a.TOKEN1()), key.currency1);
        assertEq(a.TICK_SPACING(), key.tickSpacing);
    }

    function _expectUnsupported(address hook) internal {
        vm.expectRevert(
            abi.encodeWithSelector(UniswapV4HookedAdapter.UniswapV4HookedAdapter__UnsupportedHook.selector, hook)
        );
        _newAdapter(_key(DYNAMIC_FEE_FLAG, hook));
    }

    /// @dev A code-bearing hook whose address carries exactly `flags` in its low 14 bits.
    function _hook(uint160 flags) internal returns (address hook) {
        hook = address(HOOK_BASE | flags);
        vm.etch(hook, hex"00");
    }

    function _key(uint24 fee, address hooks) internal view returns (PoolKey memory) {
        return PoolKey({currency0: currency0, currency1: currency1, fee: fee, tickSpacing: 60, hooks: hooks});
    }

    function _newAdapter(PoolKey memory key) internal returns (UniswapV4HookedAdapter) {
        return new UniswapV4HookedAdapter(
            UniswapV4HookedAdapter.Config({
                vault: vault,
                positionManager: address(venue),
                poolKey: key,
                refPool: address(refPool),
                swapRouter: address(router),
                swapExecutor: address(executor),
                owner: owner,
                rangeTicksBelow: 600,
                rangeTicksAbove: 600,
                twapWindow: 1800,
                maxSlippageBps: 200
            })
        );
    }
}
