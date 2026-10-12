// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {UniswapV3Adapter} from "contracts/adapters/UniswapV3Adapter.sol";
import {UniswapV4Adapter} from "contracts/adapters/UniswapV4Adapter.sol";
import {UniswapV4HookedAdapter} from "contracts/adapters/UniswapV4HookedAdapter.sol";
import {UniswapV4NativeEthAdapter} from "contracts/adapters/UniswapV4NativeEthAdapter.sol";
import {IAdapterFees} from "contracts/interfaces/IAdapterFees.sol";
import {IPositionAdapter} from "contracts/interfaces/IPositionAdapter.sol";
import {ILiquidityAdapter} from "contracts/interfaces/ILiquidityAdapter.sol";
import {ISwapAdapter} from "contracts/interfaces/ISwapAdapter.sol";
import {IPoolmigoVault} from "contracts/interfaces/IPoolmigoVault.sol";
import {IUniversalRouter} from "contracts/adapters/uniswap/IUniversalRouter.sol";
import {INonfungiblePositionManager} from "contracts/adapters/uniswap/INonfungiblePositionManager.sol";
import {IUniswapV3PoolMinimal} from "contracts/adapters/uniswap/IUniswapV3PoolMinimal.sol";
import {TickMath} from "contracts/adapters/uniswap/TickMath.sol";
import {LiquidityAmounts} from "contracts/adapters/uniswap/LiquidityAmounts.sol";
import {PoolKey} from "contracts/adapters/uniswap/v4/IPoolManagerMinimal.sol";
import {V4StateReader} from "contracts/adapters/uniswap/v4/V4StateReader.sol";
import {UniversalRouterSwapExecutor} from "contracts/swap/UniversalRouterSwapExecutor.sol";
import {UniversalRouterNativeSwapExecutor} from "contracts/swap/UniversalRouterNativeSwapExecutor.sol";
import {MockToken} from "test/mocks/MockToken.sol";
import {MockV3Factory, MockV3Pool} from "test/mocks/MockV3Pool.sol";
import {MockPermit2Router} from "test/mocks/MockPermit2Router.sol";

/// @dev Fee-aware v4 venue: it is its own PoolManager (`poolManager()` = this) AND PositionManager. `extsload` serves a
///      storage map the test writes in v4-core's layout (the one {V4StateReader} reads), `getPositionLiquidity` a
///      per-token map, and `WETH9()` the native adapter's wrapper. `modifyLiquidities` stands in for the fee-only
///      settle (`DECREASE_LIQUIDITY` 0 + take): it pays the ARMED fee amounts to the caller and moves the position's
///      feeGrowthInsideLast to the armed values (accrual → 0), exactly what the real PositionManager does on a poke.
contract MockV4FeeVenue {
    address public immutable permit2;
    address public WETH9;
    mapping(bytes32 => bytes32) internal _slots;
    mapping(uint256 => uint128) internal _liquidity;
    uint256 public modifyCalls;

    MockToken internal _pay0Token;
    MockToken internal _pay1Token;
    uint256 internal _pay0;
    uint256 internal _pay1;
    bytes32 internal _settleSlot;
    uint256 internal _settleLast0;
    uint256 internal _settleLast1;

    constructor(address permit2_) {
        permit2 = permit2_;
    }

    function setWeth9(address weth) external {
        WETH9 = weth;
    }

    function setSlot(bytes32 slot, uint256 value) external {
        _slots[slot] = bytes32(value);
    }

    function setPositionLiquidity(uint256 id, uint128 liquidity) external {
        _liquidity[id] = liquidity;
    }

    function armSettle(
        MockToken token0,
        MockToken token1,
        uint256 pay0,
        uint256 pay1,
        bytes32 positionSlot,
        uint256 last0,
        uint256 last1
    ) external {
        (_pay0Token, _pay1Token, _pay0, _pay1) = (token0, token1, pay0, pay1);
        (_settleSlot, _settleLast0, _settleLast1) = (positionSlot, last0, last1);
    }

    function poolManager() external view returns (address) {
        return address(this);
    }

    function extsload(bytes32 slot) external view returns (bytes32) {
        return _slots[slot];
    }

    function extsload(bytes32 startSlot, uint256 nSlots) external view returns (bytes32[] memory values) {
        values = new bytes32[](nSlots);
        for (uint256 i; i < nSlots; ++i) {
            values[i] = _slots[bytes32(uint256(startSlot) + i)];
        }
    }

    function getPositionLiquidity(uint256 id) external view returns (uint128) {
        return _liquidity[id];
    }

    function modifyLiquidities(bytes calldata, uint256) external payable {
        ++modifyCalls;
        if (_pay0 != 0) {
            _pay0Token.mint(msg.sender, _pay0);
        }
        if (_pay1 != 0) {
            _pay1Token.mint(msg.sender, _pay1);
        }
        _slots[bytes32(uint256(_settleSlot) + 1)] = bytes32(_settleLast0);
        _slots[bytes32(uint256(_settleSlot) + 2)] = bytes32(_settleLast1);
        (_pay0, _pay1) = (0, 0);
    }
}

/// @dev Fee-aware v3 NFPM: `positions()` from a per-token record; `collect(max, max)` pays tokensOwed + the ARMED
///      pending fees to the recipient and leaves the position poked (tokensOwed 0, feeGrowthInsideLast = armed),
///      exactly what the real NFPM does. `factory()` anchors the adapter's venue check.
contract MockV3FeeNfpm {
    struct Pos {
        int24 lower;
        int24 upper;
        uint128 liquidity;
        uint256 last0;
        uint256 last1;
        uint128 owed0;
        uint128 owed1;
    }

    address public immutable factory;
    MockToken internal immutable TOKEN0;
    MockToken internal immutable TOKEN1;
    mapping(uint256 => Pos) internal _pos;
    uint256 internal _pending0;
    uint256 internal _pending1;
    uint256 internal _settleLast0;
    uint256 internal _settleLast1;

    constructor(address factory_, MockToken token0, MockToken token1) {
        (factory, TOKEN0, TOKEN1) = (factory_, token0, token1);
    }

    function setPosition(uint256 id, Pos calldata p) external {
        _pos[id] = p;
    }

    function armCollect(uint256 pending0, uint256 pending1, uint256 last0, uint256 last1) external {
        (_pending0, _pending1, _settleLast0, _settleLast1) = (pending0, pending1, last0, last1);
    }

    function positions(uint256 id)
        external
        view
        returns (uint96, address, address, address, uint24, int24, int24, uint128, uint256, uint256, uint128, uint128)
    {
        Pos memory p = _pos[id];
        return (
            0,
            address(0),
            address(TOKEN0),
            address(TOKEN1),
            0,
            p.lower,
            p.upper,
            p.liquidity,
            p.last0,
            p.last1,
            p.owed0,
            p.owed1
        );
    }

    function collect(INonfungiblePositionManager.CollectParams calldata c)
        external
        payable
        returns (uint256 amount0, uint256 amount1)
    {
        Pos storage p = _pos[c.tokenId];
        amount0 = p.owed0 + _pending0;
        amount1 = p.owed1 + _pending1;
        (p.owed0, p.owed1, p.last0, p.last1) = (0, 0, _settleLast0, _settleLast1);
        (_pending0, _pending1) = (0, 0);
        TOKEN0.mint(c.recipient, amount0);
        TOKEN1.mint(c.recipient, amount1);
    }
}

/**
 * @notice {IAdapterFees} on every adapter class (v3, hookless v4, hooked v4, native-ETH v4) on fee-aware local mock
 *         venues — one scenario set, run per adapter:
 *         - ERC-165 advertises {IAdapterFees} (next to the unchanged capability interfaces);
 *         - `fees()` token order = `position()`'s;
 *         - `fees()` = settled (v4 bank / v3 tokensOwed) + venue accrual, GROSS — exactly the fee part `position()`
 *           nets the perf fee out of (position at 0 bps − fees = idle + principal; position at 0 bps − position at
 *           `bps` = floor(fees·bps/10_000) per token);
 *         - harvest settles the accrual (v4: into the bank, `FeesBanked`) and delivers exactly the pre-harvest
 *           `fees()`; afterwards `fees()` reports the (emptied) settled part — no residual accrual;
 *         - empty-position rule: `tokenId == 0` → settled part only; a zero-liquidity position ignores fee growth and
 *           is never poked (harvest makes no venue call on v4).
 *         Adapter state (tokenId, ticks, bank) is written with `vm.store` — the position-flow paths themselves are
 *         covered on the real venues by the fork suites.
 */
abstract contract AdapterFeesTestBase is Test {
    using stdStorage for StdStorage;

    int24 internal constant LOWER = -600;
    int24 internal constant UPPER = 600;
    uint128 internal constant LIQ = uint128(1 << 64);
    uint256 internal constant TOKEN_ID = 7;
    /// @dev Adapter storage slot packing `tickLower` (offset 0) | `tickUpper` (offset 3) — identical on all four
    ///      adapters (`forge inspect <adapter> storageLayout`); every write is read back through the getters.
    uint256 internal constant TICKS_SLOT = 3;

    address internal vault = makeAddr("vault");
    address internal owner = makeAddr("owner");
    MockToken internal token0;
    MockToken internal token1;
    MockV3Factory internal factory;
    MockV3Pool internal refPool;
    MockPermit2Router internal router;
    address internal adapter;

    /*//////////////////////////////////////////////////////////////
                         PER-ADAPTER VENUE HOOKS
    //////////////////////////////////////////////////////////////*/

    /// @dev Live position `TOKEN_ID` over [LOWER, UPPER] at `liquidity`, last-poke fee growth 0, fee growth now
    ///      (global; ticks' outside = 0, spot tick 0 → inside = global) `global0/1`, settled-but-undelivered fees
    ///      `settled0/1` (v4: bank, held by the adapter; v3: NFPM tokensOwed).
    function _setPosition(uint128 liquidity, uint256 global0, uint256 global1, uint256 settled0, uint256 settled1)
        internal
        virtual;

    /// @dev No position (tokenId 0); settled fees `settled0/1` where the adapter class can hold them without one
    ///      (v4 bank; v3 has none → ignored).
    function _setNoPosition(uint256 settled0, uint256 settled1) internal virtual;

    /// @dev Arm the venue so harvest's settle pays `pay0/1` (accrual, + v3 tokensOwed) and pokes the position to
    ///      feeGrowthInsideLast = `global0/1`.
    function _armHarvest(uint256 pay0, uint256 pay1, uint256 global0, uint256 global1) internal virtual;

    /// @dev Expect the settle-into-bank event (v4 only).
    function _expectBanked(uint256 accrued0, uint256 accrued1) internal virtual;

    /// @dev Settled-but-undelivered part the class keeps after a harvest (v4: bank; v3: tokensOwed).
    function _settledAfterHarvest() internal view virtual returns (uint256, uint256);

    /// @dev Venue liquidity-modification calls so far (v4: PositionManager; v3: n/a → 0).
    function _venueModifyCalls() internal view virtual returns (uint256);

    /// @dev Whether settled fees survive without a position (v4 bank: yes; v3: tokensOwed lives on the NFT → no).
    function _settledWithoutPosition() internal pure virtual returns (bool);

    /*//////////////////////////////////////////////////////////////
                                 TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Erc165_AdvertisesAdapterFees() public view {
        assertEq(type(IAdapterFees).interfaceId, IAdapterFees.fees.selector, "interfaceId = the fees() selector");
        IERC165 a = IERC165(adapter);
        assertTrue(a.supportsInterface(type(IAdapterFees).interfaceId), "IAdapterFees");
        assertTrue(a.supportsInterface(type(ILiquidityAdapter).interfaceId), "ILiquidityAdapter unchanged");
        assertTrue(a.supportsInterface(type(ISwapAdapter).interfaceId), "ISwapAdapter unchanged");
        assertTrue(a.supportsInterface(type(IERC165).interfaceId), "IERC165");
        assertFalse(a.supportsInterface(0xffffffff), "ERC-165 invalid id");
        assertFalse(a.supportsInterface(type(IPositionAdapter).interfaceId), "IPositionAdapter never advertised");
    }

    function test_Fees_TokenOrderMatchesPosition() public {
        _setPosition(LIQ, 5e15 << 64, 7e6 << 64, 11, 13);
        (address[] memory feeTokens, uint256[] memory amounts) = IAdapterFees(adapter).fees();
        (address[] memory posTokens, uint256[] memory posAmounts) = IPositionAdapter(adapter).position();
        assertEq(feeTokens.length, 2);
        assertEq(amounts.length, 2);
        assertEq(posAmounts.length, 2);
        assertEq(feeTokens[0], posTokens[0], "token0 aligned");
        assertEq(feeTokens[1], posTokens[1], "token1 aligned");
        assertEq(feeTokens[0], address(token0), "POOL order: token0");
        assertEq(feeTokens[1], address(token1), "POOL order: token1");
    }

    /// @dev fees() = settled + accrued (gross); position() = idle + principal + fees − floor(fees·bps/10_000).
    function testFuzz_Fees_EqualsFeePartPositionNetsOut(
        uint96 accrued0,
        uint96 accrued1,
        uint64 settled0,
        uint64 settled1,
        uint64 idle0,
        uint64 idle1,
        uint16 bps
    ) public {
        bps = uint16(bound(bps, 0, 3000)); // MAX_PERFORMANCE_FEE_BPS
        // LIQ = 2^64 and growth = accrued << 64 → accrual = growth·LIQ / 2^128 = accrued, exactly.
        _setPosition(LIQ, uint256(accrued0) << 64, uint256(accrued1) << 64, settled0, settled1);
        token0.mint(adapter, idle0);
        token1.mint(adapter, idle1);

        (, uint256[] memory f) = IAdapterFees(adapter).fees();
        assertEq(f[0], uint256(settled0) + accrued0, "fees0 = settled + accrued");
        assertEq(f[1], uint256(settled1) + accrued1, "fees1 = settled + accrued");

        (uint256 principal0, uint256 principal1) = LiquidityAmounts.getAmountsForLiquidity(
            uint160(1 << 96), TickMath.getSqrtRatioAtTick(LOWER), TickMath.getSqrtRatioAtTick(UPPER), LIQ
        );
        _mockBps(0);
        (, uint256[] memory gross) = IPositionAdapter(adapter).position();
        assertEq(gross[0] - f[0], uint256(idle0) + principal0, "position - fees = free idle + principal (0)");
        assertEq(gross[1] - f[1], uint256(idle1) + principal1, "position - fees = free idle + principal (1)");

        _mockBps(bps);
        (, uint256[] memory net) = IPositionAdapter(adapter).position();
        assertEq(gross[0] - net[0], Math.mulDiv(f[0], bps, 10_000), "position nets exactly fees0's cut");
        assertEq(gross[1] - net[1], Math.mulDiv(f[1], bps, 10_000), "position nets exactly fees1's cut");
    }

    /// @dev Harvest settles the accrual (v4: into the bank) and delivers exactly the pre-harvest fees(); afterwards
    ///      fees() reports the settled part the adapter still holds (emptied) and no residual accrual.
    function test_Fees_HarvestSettlesAccrualThenReportsSettled() public {
        uint256 g0 = 5e15 << 64;
        uint256 g1 = 7e6 << 64;
        _setPosition(LIQ, g0, g1, 11, 13);
        (, uint256[] memory before) = IAdapterFees(adapter).fees();
        assertEq(before[0], 5e15 + 11);
        assertEq(before[1], 7e6 + 13);

        _armHarvest(5e15, 7e6, g0, g1);
        _expectBanked(5e15, 7e6);
        vm.prank(vault);
        (, uint256[] memory harvested) = IPositionAdapter(adapter).harvest();
        assertEq(harvested[0], before[0], "harvest delivers fees0");
        assertEq(harvested[1], before[1], "harvest delivers fees1");
        assertEq(token0.balanceOf(vault), before[0], "vault received fees0");
        assertEq(token1.balanceOf(vault), before[1], "vault received fees1");

        (, uint256[] memory afterHarvest) = IAdapterFees(adapter).fees();
        (uint256 s0, uint256 s1) = _settledAfterHarvest();
        assertEq(afterHarvest[0], s0, "fees0 = settled part after harvest");
        assertEq(afterHarvest[1], s1, "fees1 = settled part after harvest");
        assertEq(afterHarvest[0], 0, "no residual fees0");
        assertEq(afterHarvest[1], 0, "no residual fees1");
    }

    function test_Fees_NoPosition_SettledOnly() public {
        _setNoPosition(17, 19);
        (address[] memory tokens, uint256[] memory f) = IAdapterFees(adapter).fees();
        assertEq(tokens[0], address(token0));
        assertEq(tokens[1], address(token1));
        bool kept = _settledWithoutPosition();
        assertEq(f[0], kept ? 17 : 0, "tokenId 0: settled only (0)");
        assertEq(f[1], kept ? 19 : 0, "tokenId 0: settled only (1)");
    }

    /// @dev Zero liquidity (a full removeLiquidity keeps the NFT): fee growth is ignored, the position never poked.
    function test_Fees_ZeroLiquidity_SettledOnly_NeverPoked() public {
        _setPosition(0, 5e15 << 64, 7e6 << 64, 23, 29);
        (, uint256[] memory f) = IAdapterFees(adapter).fees();
        assertEq(f[0], 23, "zero liquidity: settled only (0)");
        assertEq(f[1], 29, "zero liquidity: settled only (1)");
        _mockBps(0);
        (, uint256[] memory gross) = IPositionAdapter(adapter).position();
        assertEq(gross[0], 23, "position agrees (0)");
        assertEq(gross[1], 29, "position agrees (1)");

        uint256 calls = _venueModifyCalls();
        _armHarvest(0, 0, 5e15 << 64, 7e6 << 64);
        vm.prank(vault);
        IPositionAdapter(adapter).harvest();
        assertEq(_venueModifyCalls(), calls, "harvest never pokes an empty position");
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _setUpTokensAndRouter() internal {
        MockToken a = new MockToken("Token A", "TKA", 18);
        MockToken b = new MockToken("Token B", "TKB", 6);
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);
        factory = new MockV3Factory();
        router = new MockPermit2Router(factory);
        refPool = new MockV3Pool(address(factory), address(token0), address(token1), 100, uint160(1 << 96), 1e24);
        factory.register(refPool);
        _mockBps(1000);
    }

    function _mockBps(uint16 bps) internal {
        vm.mockCall(vault, abi.encodeCall(IPoolmigoVault.performanceFeeBps, ()), abi.encode(bps));
    }

    function _storeTokenIdAndTicks(uint256 id) internal {
        stdstore.target(adapter).sig("tokenId()").checked_write(id);
        bytes32 packed = vm.load(adapter, bytes32(TICKS_SLOT));
        uint256 cleared = uint256(packed) & ~uint256(type(uint48).max);
        uint256 ticks = uint256(uint24(LOWER)) | (uint256(uint24(UPPER)) << 24);
        vm.store(adapter, bytes32(TICKS_SLOT), bytes32(cleared | ticks));
        (bool ok, bytes memory ret) = adapter.staticcall(abi.encodeWithSignature("tickLower()"));
        assertTrue(ok);
        assertEq(abi.decode(ret, (int24)), LOWER, "tickLower written");
        (ok, ret) = adapter.staticcall(abi.encodeWithSignature("tickUpper()"));
        assertTrue(ok);
        assertEq(abi.decode(ret, (int24)), UPPER, "tickUpper written");
    }
}

/*//////////////////////////////////////////////////////////////
                              V4 FAMILY
//////////////////////////////////////////////////////////////*/

/// @dev Shared v4 venue wiring (hookless / hooked / native-ETH): pool state at spot price 1 (tick 0) in the
///      PoolManager layout {V4StateReader} reads; the adapter's bank in its storage + the matching token balance.
abstract contract V4AdapterFeesTestBase is AdapterFeesTestBase {
    using stdStorage for StdStorage;

    event FeesBanked(uint256 amount0, uint256 amount1);

    uint24 internal constant DYNAMIC_FEE_FLAG = 0x800000;
    /// @dev A FablesRamp-class hook address: beforeInitialize | beforeSwap (0x2080), outside HOOK_FORBIDDEN_FLAGS.
    address internal constant FEE_OVERRIDE_HOOK = address(uint160(0xF0AB5) << 140 | 0x2080);

    MockV4FeeVenue internal venue;
    bytes32 internal poolId;

    function _setUpV4Venue() internal {
        _setUpTokensAndRouter();
        venue = new MockV4FeeVenue(address(router)); // Permit2 = the mock router
        vm.mockCall(address(router), abi.encodeCall(IUniversalRouter.poolManager, ()), abi.encode(address(venue)));
        vm.etch(FEE_OVERRIDE_HOOK, hex"00");
    }

    /// @dev Initialize the pool keyed `key` at sqrtPriceX96 = 2^96 (tick 0) before the adapter is built.
    function _initPool(PoolKey memory key) internal {
        poolId = keccak256(abi.encode(key));
        venue.setSlot(_stateSlot(), 1 << 96);
    }

    function _setPosition(uint128 liquidity, uint256 global0, uint256 global1, uint256 settled0, uint256 settled1)
        internal
        override
    {
        _storeTokenIdAndTicks(TOKEN_ID);
        venue.setPositionLiquidity(TOKEN_ID, liquidity);
        venue.setSlot(bytes32(uint256(_stateSlot()) + 1), global0);
        venue.setSlot(bytes32(uint256(_stateSlot()) + 2), global1);
        venue.setSlot(_positionSlot(), liquidity);
        _storeBank(settled0, settled1);
    }

    function _setNoPosition(uint256 settled0, uint256 settled1) internal override {
        _storeBank(settled0, settled1);
    }

    function _armHarvest(uint256 pay0, uint256 pay1, uint256 global0, uint256 global1) internal override {
        venue.armSettle(token0, token1, pay0, pay1, _positionSlot(), global0, global1);
    }

    function _expectBanked(uint256 accrued0, uint256 accrued1) internal override {
        vm.expectEmit(adapter);
        emit FeesBanked(accrued0, accrued1);
    }

    function _settledAfterHarvest() internal view override returns (uint256, uint256) {
        return (_bank("bankedFees0()"), _bank("bankedFees1()"));
    }

    function _venueModifyCalls() internal view override returns (uint256) {
        return venue.modifyCalls();
    }

    function _settledWithoutPosition() internal pure override returns (bool) {
        return true;
    }

    function _storeBank(uint256 bank0, uint256 bank1) internal {
        stdstore.target(adapter).sig("bankedFees0()").checked_write(bank0);
        stdstore.target(adapter).sig("bankedFees1()").checked_write(bank1);
        token0.mint(adapter, bank0); // the bank is held as tokens
        token1.mint(adapter, bank1);
    }

    function _bank(string memory sig) internal view returns (uint256) {
        (bool ok, bytes memory ret) = adapter.staticcall(abi.encodeWithSignature(sig));
        require(ok, "bank getter");
        return abi.decode(ret, (uint256));
    }

    function _stateSlot() internal view returns (bytes32) {
        return keccak256(abi.encodePacked(poolId, V4StateReader.POOLS_SLOT));
    }

    /// @dev The PositionManager-owned position (owner = the POSM = `venue`, salt = tokenId).
    function _positionSlot() internal view returns (bytes32) {
        bytes32 key = V4StateReader.positionKey(address(venue), LOWER, UPPER, bytes32(TOKEN_ID));
        bytes32 positionsMapping = bytes32(uint256(_stateSlot()) + V4StateReader.POSITIONS_OFFSET);
        return keccak256(abi.encodePacked(key, positionsMapping));
    }
}

contract UniswapV4AdapterFeesTest is V4AdapterFeesTestBase {
    function setUp() public {
        _setUpV4Venue();
        PoolKey memory key = PoolKey({
            currency0: address(token0), currency1: address(token1), fee: 500, tickSpacing: 60, hooks: address(0)
        });
        _initPool(key);
        adapter = address(
            new UniswapV4Adapter(
                UniswapV4Adapter.Config({
                    vault: vault,
                    positionManager: address(venue),
                    poolKey: key,
                    refPool: address(refPool),
                    swapRouter: address(router),
                    swapExecutor: address(new UniversalRouterSwapExecutor(address(router), address(router))),
                    owner: owner,
                    rangeTicksBelow: 600,
                    rangeTicksAbove: 600,
                    twapWindow: 1800,
                    maxSlippageBps: 200
                })
            )
        );
    }
}

contract UniswapV4HookedAdapterFeesTest is V4AdapterFeesTestBase {
    function setUp() public {
        _setUpV4Venue();
        PoolKey memory key = PoolKey({
            currency0: address(token0),
            currency1: address(token1),
            fee: DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: FEE_OVERRIDE_HOOK
        });
        _initPool(key);
        adapter = address(
            new UniswapV4HookedAdapter(
                UniswapV4HookedAdapter.Config({
                    vault: vault,
                    positionManager: address(venue),
                    poolKey: key,
                    refPool: address(refPool),
                    swapRouter: address(router),
                    swapExecutor: address(new UniversalRouterSwapExecutor(address(router), address(router))),
                    owner: owner,
                    rangeTicksBelow: 600,
                    rangeTicksAbove: 600,
                    twapWindow: 1800,
                    maxSlippageBps: 200
                })
            )
        );
    }
}

/// @dev token0 = a MockToken standing in for the PositionManager's WETH9 (the vault-facing leg of native currency0);
///      the venue pays the settle in it, as the real take tail wraps + sweeps the native credit back as WETH.
contract UniswapV4NativeEthAdapterFeesTest is V4AdapterFeesTestBase {
    function setUp() public {
        _setUpV4Venue();
        venue.setWeth9(address(token0));
        PoolKey memory key = PoolKey({
            currency0: address(0),
            currency1: address(token1),
            fee: DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: FEE_OVERRIDE_HOOK
        });
        _initPool(key);
        adapter = address(
            new UniswapV4NativeEthAdapter(
                UniswapV4NativeEthAdapter.Config({
                    vault: vault,
                    positionManager: address(venue),
                    poolKey: key,
                    refPool: address(refPool),
                    swapRouter: address(router),
                    swapExecutor: address(
                        new UniversalRouterNativeSwapExecutor(address(router), address(router), address(token0))
                    ),
                    owner: owner,
                    rangeTicksBelow: 600,
                    rangeTicksAbove: 600,
                    twapWindow: 1800,
                    maxSlippageBps: 200
                })
            )
        );
    }
}

/*//////////////////////////////////////////////////////////////
                                 V3
//////////////////////////////////////////////////////////////*/

/// @dev v3 has no bank: the settled part is the NFPM's tokensOwed (fees only — principal is collected in full on
///      every decrease), the accrual the pool's feeGrowthInside since the last poke (ticks' outside = 0 → inside =
///      global at spot tick 0). Pool fee-growth reads are mocked on the MockV3Pool.
contract UniswapV3AdapterFeesTest is AdapterFeesTestBase {
    MockV3FeeNfpm internal nfpm;

    function setUp() public {
        _setUpTokensAndRouter();
        nfpm = new MockV3FeeNfpm(address(factory), token0, token1);
        vm.mockCall(
            address(refPool),
            abi.encodeWithSelector(IUniswapV3PoolMinimal.ticks.selector),
            abi.encode(uint128(0), int128(0), uint256(0), uint256(0), int56(0), uint160(0), uint32(0), true)
        );
        _mockGlobals(0, 0);
        adapter = address(
            new UniswapV3Adapter(
                UniswapV3Adapter.Config({
                    vault: vault,
                    pool: address(refPool),
                    positionManager: address(nfpm),
                    swapRouter: address(router),
                    permit2: address(router),
                    swapExecutor: address(new UniversalRouterSwapExecutor(address(router), address(router))),
                    owner: owner,
                    rangeTicksBelow: 600,
                    rangeTicksAbove: 600,
                    twapWindow: 1800,
                    maxSlippageBps: 200
                })
            )
        );
    }

    function _setPosition(uint128 liquidity, uint256 global0, uint256 global1, uint256 settled0, uint256 settled1)
        internal
        override
    {
        _storeTokenIdAndTicks(TOKEN_ID);
        nfpm.setPosition(
            TOKEN_ID,
            MockV3FeeNfpm.Pos({
                lower: LOWER,
                upper: UPPER,
                liquidity: liquidity,
                last0: 0,
                last1: 0,
                owed0: uint128(settled0),
                owed1: uint128(settled1)
            })
        );
        _mockGlobals(global0, global1);
    }

    function _setNoPosition(uint256, uint256) internal override {}

    function _armHarvest(uint256 pay0, uint256 pay1, uint256 global0, uint256 global1) internal override {
        nfpm.armCollect(pay0, pay1, global0, global1);
    }

    function _expectBanked(uint256, uint256) internal override {}

    function _settledAfterHarvest() internal view override returns (uint256 owed0, uint256 owed1) {
        (,,,,,,,,,, uint128 o0, uint128 o1) = nfpm.positions(TOKEN_ID);
        return (o0, o1);
    }

    function _venueModifyCalls() internal pure override returns (uint256) {
        return 0;
    }

    function _settledWithoutPosition() internal pure override returns (bool) {
        return false;
    }

    function _mockGlobals(uint256 global0, uint256 global1) internal {
        vm.mockCall(
            address(refPool), abi.encodeCall(IUniswapV3PoolMinimal.feeGrowthGlobal0X128, ()), abi.encode(global0)
        );
        vm.mockCall(
            address(refPool), abi.encodeCall(IUniswapV3PoolMinimal.feeGrowthGlobal1X128, ()), abi.encode(global1)
        );
    }
}
