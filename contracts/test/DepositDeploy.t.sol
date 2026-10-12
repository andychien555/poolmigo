// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {MySunVaultUpgradeable} from "contracts/MySunVaultUpgradeable.sol";
import {IPoolmigoVault} from "contracts/interfaces/IPoolmigoVault.sol";
import {IPositionAdapter} from "contracts/interfaces/IPositionAdapter.sol";
import {MockToken} from "test/mocks/MockToken.sol";
import {MockPositionAdapter} from "test/mocks/MockPositionAdapter.sol";
import {VaultImplArgs} from "test/utils/VaultImplArgs.sol";

/// @dev Holds what it is deployed (position = balances) and models a venue guard (e.g. spot-vs-TWAP): while tripped,
///      `deploy` reverts typed. Withdrawals deliver pro-rata balances (no fees).
contract GuardedPositionAdapter is IPositionAdapter {
    using SafeERC20 for IERC20;

    address public immutable vault;
    address[] internal _tokens;
    bool public tripped;

    error Guarded__SpotTwapDeviation();

    constructor(address[] memory tokens_, address vault_) {
        _tokens = tokens_;
        vault = vault_;
    }

    function trip(bool on) external {
        tripped = on;
    }

    function dex() external pure returns (bytes32) {
        return "guarded";
    }

    function poolId() external pure returns (bytes32) {
        return "guarded";
    }

    function position() public view returns (address[] memory tokens, uint256[] memory amounts) {
        tokens = _tokens;
        amounts = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            amounts[i] = IERC20(tokens[i]).balanceOf(address(this));
        }
    }

    function deploy(uint256[] calldata amounts) external returns (address[] memory tokens, uint256[] memory deployed) {
        if (tripped) revert Guarded__SpotTwapDeviation();
        tokens = _tokens;
        deployed = amounts;
        for (uint256 i; i < tokens.length; ++i) {
            if (amounts[i] != 0) IERC20(tokens[i]).safeTransferFrom(vault, address(this), amounts[i]);
        }
    }

    function withdrawProportional(uint256 sharesWad, address to)
        external
        returns (address[] memory tokens, uint256[] memory amounts, uint256[] memory fees)
    {
        (tokens, amounts) = position();
        fees = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            amounts[i] = (amounts[i] * sharesWad) / 1e18;
            if (amounts[i] != 0) IERC20(tokens[i]).safeTransfer(to, amounts[i]);
        }
    }

    function harvest() external view returns (address[] memory tokens, uint256[] memory amounts) {
        tokens = _tokens;
        amounts = new uint256[](tokens.length);
    }

    function unwindAll(address to)
        external
        returns (address[] memory tokens, uint256[] memory amounts, uint256[] memory fees)
    {
        (tokens, amounts) = position();
        fees = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            if (amounts[i] != 0) IERC20(tokens[i]).safeTransfer(to, amounts[i]);
        }
    }
}

/**
 * @notice Deposit-deploy (T2d) through the real vault: after the mint, {deposit} deploys the pulled amounts across the
 *         adapters per token in proportion to their reported holdings (floor; dust and unheld tokens stay idle) via
 *         the stateless {DepositSplit}; any deploy failure reverts the whole deposit. Edges: bootstrap (no holder),
 *         zero slices / all-zero adapters skipped (incl. partial holders), exact multi-adapter split + dust, strict
 *         revert propagation (atomic rollback), approvals zeroed, `Deployed` per deployed adapter.
 */
contract DepositDeployTest is Test {
    MySunVaultUpgradeable internal vault;
    MockToken internal usdg; // 6dp
    MockToken internal weth; // 18dp
    MockPositionAdapter internal a1; // [USDG, WETH]
    MockPositionAdapter internal a2; // [USDG, WETH]
    MockPositionAdapter internal a3; // [WETH] — single-token venue

    address internal owner = makeAddr("owner");
    address internal treasury = makeAddr("treasury");
    address internal keeper = makeAddr("keeper");
    address internal bob = makeAddr("bob");

    uint256 internal constant GENESIS = 1_000e18;
    uint256 internal constant BOOT_USDG = 1_000e6;
    uint256 internal constant BOOT_WETH = 1e18;

    address[] internal basket;

    bytes32 internal constant DEPLOYED_TOPIC = keccak256("Deployed(address,address,address[],uint256[])");

    function setUp() public {
        usdg = new MockToken("Mock USDG", "USDG", 6);
        weth = new MockToken("Mock WETH", "WETH", 18);
        basket.push(address(usdg));
        basket.push(address(weth));

        MySunVaultUpgradeable impl = new MySunVaultUpgradeable(VaultImplArgs.depositSplit());
        vault = MySunVaultUpgradeable(
            address(
                new ERC1967Proxy(
                    address(impl),
                    abi.encodeCall(
                        MySunVaultUpgradeable(address(0)).initialize,
                        (owner, "sunEthLP", "sunEthLP", basket, treasury, uint16(1000), GENESIS, uint256(0))
                    )
                )
            )
        );
        a1 = new MockPositionAdapter(basket, address(vault), "uniswap-v3", bytes32(uint256(1)));
        a2 = new MockPositionAdapter(basket, address(vault), "uniswap-v4", bytes32(uint256(2)));
        address[] memory wethOnly = new address[](1);
        wethOnly[0] = address(weth);
        a3 = new MockPositionAdapter(wethOnly, address(vault), "single", bytes32(uint256(3)));

        vm.prank(owner);
        vault.setKeeper(keeper, true);
        _fund(owner);
        _fund(bob);
    }

    /*//////////////////////////////////////////////////////////////
                                BOOTSTRAP
    //////////////////////////////////////////////////////////////*/

    /// @dev No adapter registered: genesis and a follow-up deposit stay idle (one splitter call, zero frames).
    function test_Bootstrap_NoAdapters_StaysIdle() public {
        _genesis();
        assertEq(_idle()[0], BOOT_USDG);
        assertEq(_idle()[1], BOOT_WETH);
        (, uint256[] memory req) = vault.previewDeposit(basket, _amts(10e6, 0.01e18));
        vm.prank(bob);
        vault.deposit(basket, _amts(10e6, 0.01e18), 1, bob);
        assertEq(_idle()[0], BOOT_USDG + req[0]);
        assertEq(_idle()[1], BOOT_WETH + req[1]);
    }

    /// @dev Registered adapters holding nothing: every frame is a skip word — no deploy call, no `Deployed`, all idle.
    function test_Bootstrap_RegisteredButEmpty_StaysIdle() public {
        _register3();
        vm.recordLogs();
        _genesis();
        vm.prank(bob);
        uint256 shares = vault.deposit(basket, _amts(10e6, 0.01e18), 1, bob);
        assertGt(shares, 0);
        assertEq(_deployedEvents(), 0, "no Deployed");
        assertEq(usdg.balanceOf(address(vault)), BOOT_USDG + 10e6);
        assertEq(usdg.balanceOf(address(a1)) + usdg.balanceOf(address(a2)), 0);
        assertEq(weth.balanceOf(address(a1)) + weth.balanceOf(address(a2)) + weth.balanceOf(address(a3)), 0);
    }

    /*//////////////////////////////////////////////////////////////
                        ZERO SLICES / PARTIAL HOLDERS
    //////////////////////////////////////////////////////////////*/

    /// @dev a1 holds USDG only, a3 holds WETH only, a2 holds nothing: a1 takes the whole USDG pull (its WETH slice is 0
    ///      inside a non-empty frame), a3 the whole WETH pull, a2 is skipped (no call, no event). Sole holders → exact.
    function test_ZeroSlice_PartialHoldersAndSkippedAdapter() public {
        _register3();
        _genesis();
        vm.startPrank(keeper);
        vault.deployTo(IPositionAdapter(address(a1)), _amts(300e6, 0));
        vault.deployTo(IPositionAdapter(address(a3)), _one(0.4e18));
        vm.stopPrank();
        uint256[2] memory idle0 = _idle();

        (, uint256[] memory req) = vault.previewDeposit(basket, _amts(10e6, 1e18));
        vm.recordLogs();
        vm.prank(bob);
        vault.deposit(basket, _amts(10e6, 1e18), 1, bob);

        assertEq(_deployedEvents(), 2, "a1 + a3 only");
        assertEq(a1.deployed(0), 300e6 + req[0]);
        assertEq(a1.deployed(1), 0, "a1 holds no WETH -> zero slice");
        assertEq(a2.deployed(0) + a2.deployed(1), 0, "a2 skipped");
        assertEq(a3.deployed(0), 0.4e18 + req[1]);
        assertEq(_idle()[0], idle0[0], "no USDG dust (sole holder)");
        assertEq(_idle()[1], idle0[1], "no WETH dust (sole holder)");
    }

    /*//////////////////////////////////////////////////////////////
                       MULTI-ADAPTER EXACT SPLIT + DUST
    //////////////////////////////////////////////////////////////*/

    /// @dev Holdings a1 [300e6, 0.3e18], a2 [100e6, 0.2e18], a3 [0.1e18] → D = [400e6, 0.6e18]. Bob offers
    ///      (7e6 + 3, 1e18): USDG binds, shares 7_000_002_992_999_997_007, required [7_000_003, 7_000_002_992_999_998].
    ///      USDG: a1 ⌊req·3/4⌋ = 5_250_002, a2 ⌊req/4⌋ = 1_750_000, dust 1.
    ///      WETH: a1 ⌊req/2⌋ = 3_500_001_496_499_999, a2 ⌊req/3⌋ = 2_333_334_330_999_999, a3 ⌊req/6⌋ = 1_166_667_165_499_999,
    ///      dust 1. Each adapter saw exactly its slice approved; every approval is zero afterwards.
    function test_MultiAdapter_ExactSplit_DustStaysIdle() public {
        _register3();
        _genesis();
        vm.startPrank(keeper);
        vault.deployTo(IPositionAdapter(address(a1)), _amts(300e6, 0.3e18));
        vault.deployTo(IPositionAdapter(address(a2)), _amts(100e6, 0.2e18));
        vault.deployTo(IPositionAdapter(address(a3)), _one(0.1e18));
        vm.stopPrank();
        uint256[2] memory idle0 = _idle();
        (, uint256[] memory totals0) = vault.totalTokens();

        uint256[] memory offer = _amts(7e6 + 3, 1e18);
        (uint256 pShares, uint256[] memory req) = vault.previewDeposit(basket, offer);
        assertEq(pShares, 7_000_002_992_999_997_007);
        assertEq(req[0], 7_000_003);
        assertEq(req[1], 7_000_002_992_999_998);

        vm.expectEmit(true, true, false, true, address(vault));
        emit IPoolmigoVault.Deployed(bob, address(a1), basket, _amts(5_250_002, 3_500_001_496_499_999));
        vm.expectEmit(true, true, false, true, address(vault));
        emit IPoolmigoVault.Deployed(bob, address(a2), basket, _amts(1_750_000, 2_333_334_330_999_999));
        vm.expectEmit(true, true, false, true, address(vault));
        emit IPoolmigoVault.Deployed(bob, address(a3), _tokens1(address(weth)), _one(1_166_667_165_499_999));
        vm.expectEmit(true, true, false, true, address(vault));
        emit IPoolmigoVault.Deposited(bob, bob, basket, req, pShares);
        vm.prank(bob);
        assertEq(vault.deposit(basket, offer, 1, bob), pShares);

        assertEq(a1.deployed(0), 300e6 + 5_250_002);
        assertEq(a1.deployed(1), 0.3e18 + 3_500_001_496_499_999);
        assertEq(a2.deployed(0), 100e6 + 1_750_000);
        assertEq(a2.deployed(1), 0.2e18 + 2_333_334_330_999_999);
        assertEq(a3.deployed(0), 0.1e18 + 1_166_667_165_499_999);
        assertEq(_idle()[0] - idle0[0], 1, "USDG floor dust stays idle");
        assertEq(_idle()[1] - idle0[1], 1, "WETH floor dust stays idle");

        // Exact approvals at deploy time, all revoked afterwards.
        assertEq(a1.allowanceSeenOnDeploy(0), 5_250_002);
        assertEq(a2.allowanceSeenOnDeploy(1), 2_333_334_330_999_999);
        assertEq(a3.allowanceSeenOnDeploy(0), 1_166_667_165_499_999);
        for (uint256 i; i < 3; ++i) {
            address ad = address(i == 0 ? a1 : (i == 1 ? a2 : a3));
            assertEq(usdg.allowance(address(vault), ad), 0);
            assertEq(weth.allowance(address(vault), ad), 0);
        }

        // Accounting: the deploy moves value between idle and positions only.
        (, uint256[] memory totals1) = vault.totalTokens();
        assertEq(totals1[0] - totals0[0], req[0]);
        assertEq(totals1[1] - totals0[1], req[1]);
    }

    /*//////////////////////////////////////////////////////////////
                              STRICT REVERT
    //////////////////////////////////////////////////////////////*/

    /// @dev A holding adapter whose `deploy` reverts (venue guard) reverts the whole deposit with the adapter's error —
    ///      even after an earlier adapter already took its slice: no mint, no pull, every balance as before. No fallback
    ///      to idle. Once the guard clears, the same deposit goes through.
    function test_StrictRevert_AdapterDeployRevertsWholeDeposit() public {
        GuardedPositionAdapter g = new GuardedPositionAdapter(basket, address(vault));
        vm.startPrank(owner);
        vault.addAdapter(IPositionAdapter(address(a1)));
        vault.addAdapter(IPositionAdapter(address(g)));
        vm.stopPrank();
        _genesis();
        vm.startPrank(keeper);
        vault.deployTo(IPositionAdapter(address(a1)), _amts(300e6, 0.3e18)); // a1 is first in registry order
        vault.deployTo(IPositionAdapter(address(g)), _amts(200e6, 0.2e18));
        vm.stopPrank();

        uint256 supply0 = vault.totalSupply();
        uint256[2] memory idle0 = _idle();
        uint256[2] memory bob0 = [usdg.balanceOf(bob), weth.balanceOf(bob)];
        uint256 a1Usdg0 = usdg.balanceOf(address(a1));

        g.trip(true);
        vm.prank(bob);
        vm.expectRevert(GuardedPositionAdapter.Guarded__SpotTwapDeviation.selector);
        vault.deposit(basket, _amts(10e6, 1e18), 1, bob);

        assertEq(vault.totalSupply(), supply0, "mint rolled back");
        assertEq(vault.balanceOf(bob), 0);
        assertEq(usdg.balanceOf(bob), bob0[0], "pull rolled back");
        assertEq(weth.balanceOf(bob), bob0[1]);
        assertEq(_idle()[0], idle0[0]);
        assertEq(_idle()[1], idle0[1]);
        assertEq(usdg.balanceOf(address(a1)), a1Usdg0, "earlier adapter's deploy rolled back");
        assertEq(usdg.balanceOf(address(g)), 200e6);

        g.trip(false);
        vm.prank(bob);
        assertGt(vault.deposit(basket, _amts(10e6, 1e18), 1, bob), 0);
        assertGt(usdg.balanceOf(address(g)), 200e6);
    }

    /// @dev A holding adapter whose `deploy` reverts for any reason (here: it is not the vault's adapter any more —
    ///      `OnlyVault`, via a registered mock bound to another vault) blocks deposits until the owner removes it.
    function test_StrictRevert_AnyDeployFailureBubbles() public {
        MockPositionAdapter foreign = new MockPositionAdapter(basket, address(0xBEEF), "x", bytes32(uint256(9)));
        vm.prank(owner);
        vault.addAdapter(IPositionAdapter(address(foreign)));
        _genesis();
        // Give it a reported holding without a vault deploy (fees accrue in the adapter).
        foreign.simulateFees(_amts(1e6, 0));

        vm.prank(bob);
        vm.expectRevert(MockPositionAdapter.MockAdapter__OnlyVault.selector);
        vault.deposit(basket, _amts(10e6, 1e18), 1, bob);
    }

    /*//////////////////////////////////////////////////////////////
                         KEEPER deployTo UNCHANGED
    //////////////////////////////////////////////////////////////*/

    /// @dev {deployTo} runs through the same helper: same length guard, same event, same approval hygiene.
    function test_DeployTo_BehaviorUnchanged() public {
        _register3();
        _genesis();
        vm.prank(keeper);
        vm.expectRevert(IPoolmigoVault.PoolmigoVault__LengthMismatch.selector);
        vault.deployTo(IPositionAdapter(address(a3)), _amts(1, 1));

        vm.expectEmit(true, true, false, true, address(vault));
        emit IPoolmigoVault.Deployed(keeper, address(a1), basket, _amts(5e6, 0.005e18));
        vm.prank(keeper);
        vault.deployTo(IPositionAdapter(address(a1)), _amts(5e6, 0.005e18));
        assertEq(a1.allowanceSeenOnDeploy(0), 5e6);
        assertEq(usdg.allowance(address(vault), address(a1)), 0);
        assertEq(weth.allowance(address(vault), address(a1)), 0);
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    function _register3() internal {
        vm.startPrank(owner);
        vault.addAdapter(IPositionAdapter(address(a1)));
        vault.addAdapter(IPositionAdapter(address(a2)));
        vault.addAdapter(IPositionAdapter(address(a3)));
        vm.stopPrank();
    }

    function _genesis() internal {
        vm.prank(owner);
        vault.deposit(basket, _amts(BOOT_USDG, BOOT_WETH), GENESIS, owner);
    }

    function _fund(address who) internal {
        usdg.mint(who, 1_000_000e6);
        weth.mint(who, 1_000e18);
        vm.startPrank(who);
        usdg.approve(address(vault), type(uint256).max);
        weth.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    function _idle() internal view returns (uint256[2] memory) {
        return [usdg.balanceOf(address(vault)), weth.balanceOf(address(vault))];
    }

    function _deployedEvents() internal returns (uint256 n) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(vault) && logs[i].topics[0] == DEPLOYED_TOPIC) ++n;
        }
    }

    function _amts(uint256 a, uint256 b) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](2);
        (arr[0], arr[1]) = (a, b);
    }

    function _one(uint256 a) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = a;
    }

    function _tokens1(address t) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = t;
    }
}
