// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, BalanceDeltaLibrary, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {FeeCompounderHook} from "../src/FeeCompounderHook.sol";
import {AaveAdapter} from "../src/adapters/AaveAdapter.sol";
import {MorphoAdapter} from "../src/adapters/MorphoAdapter.sol";
import {PoolReinvestAdapter} from "../src/adapters/PoolReinvestAdapter.sol";
import {FeeCompounderHookHarness} from "./utils/FeeCompounderHookHarness.sol";
import {TestERC20} from "./utils/TestERC20.sol";

contract CallbackProxyMock {
    uint256 public debtValue;

    receive() external payable {}

    function debt(address) external view returns (uint256) {
        return debtValue;
    }

    function setDebt(uint256 value) external {
        debtValue = value;
    }

    function callPay(FeeCompounderHook hook, uint256 amount) external {
        hook.pay(amount);
    }
}

contract RejectingCallbackProxyMock {
    uint256 public debtValue = 1 wei;

    receive() external payable {
        revert("reject");
    }

    function debt(address) external view returns (uint256) {
        return debtValue;
    }
}

contract FeeCompounderHookTest is Test {
    using BalanceDeltaLibrary for BalanceDelta;

    FeeCompounderHookHarness hook;
    AaveAdapter aave;
    MorphoAdapter morpho;
    PoolReinvestAdapter poolRoute;
    TestERC20 token0;
    TestERC20 token1;
    PoolKey key;
    bytes32 id;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address callbackProxy = address(0xCA11BAC);
    address reactiveSender = address(0xBEEF);
    address directRsc = address(0x1234);

    function setUp() public {
        token0 = new TestERC20("Token 0", "TK0");
        token1 = new TestERC20("Token 1", "TK1");
        hook = new FeeCompounderHookHarness(
            IPoolManager(address(0xCAFE)), address(this), callbackProxy, reactiveSender, directRsc
        );
        aave = new AaveAdapter(address(hook), 550);
        morpho = new MorphoAdapter(address(hook), 720);
        poolRoute = new PoolReinvestAdapter(address(hook), 400);
        hook.setAdapterWhitelisted(address(aave), true);
        hook.setAdapterWhitelisted(address(morpho), true);
        hook.setAdapterWhitelisted(address(poolRoute), true);
        hook.setDefaultRoute(address(poolRoute));
        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        id = hook.poolId(key);
        _mintAndApprove(alice, 10_000 ether, 10_000 ether);
        _mintAndApprove(bob, 10_000 ether, 10_000 ether);
        _mintAndApprove(address(this), 10_000 ether, 10_000 ether);
    }

    function test_hookPermissions_areConservative() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.afterAddLiquidity);
        assertTrue(p.beforeRemoveLiquidity);
        assertTrue(p.afterSwap);
        assertFalse(p.beforeSwap);
        assertFalse(p.afterSwapReturnDelta);
        assertFalse(p.beforeSwapReturnDelta);
    }

    function test_firstDeposit_usesDeadShares() public {
        vm.prank(alice);
        uint256 shares = hook.depositForDemo(key, 10 ether, 10 ether, alice);
        assertEq(shares, 20 ether - hook.DEAD_SHARES());
        assertEq(hook.lpShares(id, address(0)), hook.DEAD_SHARES());
        assertEq(hook.lpShares(id, alice), shares);
    }

    function test_secondDeposit_afterCompound_isDiluted() public {
        vm.prank(alice);
        uint256 aliceShares = hook.depositForDemo(key, 100 ether, 100 ether, alice);
        hook.reportFees(key, 20 ether, 20 ether);
        vm.prank(directRsc);
        hook.triggerCompound(key, address(morpho));

        vm.prank(bob);
        uint256 bobShares = hook.depositForDemo(key, 100 ether, 100 ether, bob);
        assertLt(bobShares, aliceShares);
    }

    function test_reportFees_transfersBackingAndAppliesCompoundBps() public {
        uint256 before0 = token0.balanceOf(address(hook));
        hook.reportFees(key, 10 ether, 6 ether);
        assertEq(token0.balanceOf(address(hook)) - before0, 1 ether);
        (uint256 pending0, uint256 pending1) = hook.pendingFeesFor(id);
        assertEq(pending0, 1 ether);
        assertEq(pending1, 0.6 ether);
    }

    function test_reportFees_requiresFeeReporter() public {
        vm.prank(alice);
        vm.expectRevert(FeeCompounderHook.OnlyFeeReporter.selector);
        hook.reportFees(key, 1 ether, 1 ether);
    }

    function test_afterSwap_emitsCurrentPendingAndBasefee() public {
        hook.reportFees(key, 10 ether, 0);
        vm.recordLogs();
        hook.exposedAfterSwap(
            address(this),
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0}),
            BalanceDeltaLibrary.ZERO_DELTA,
            ""
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("FeesAccrued(bytes32,uint256,uint256,uint256,uint256,uint256,uint256)");
        bool found;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == sig && logs[i].topics[1] == id) found = true;
        }
        assertTrue(found);
    }

    function test_triggerCompound_requiresDirectRsc() public {
        hook.reportFees(key, 10 ether, 10 ether);
        vm.expectRevert(FeeCompounderHook.OnlyRSC.selector);
        hook.triggerCompound(key, address(aave));
    }

    function test_triggerCompound_routesFeesAndResetsPending() public {
        hook.reportFees(key, 20 ether, 10 ether);
        vm.prank(directRsc);
        hook.triggerCompound(key, address(morpho));
        (uint256 pending0, uint256 pending1) = hook.pendingFeesFor(id);
        assertEq(pending0, 0);
        assertEq(pending1, 0);
        assertEq(morpho.managedAssets(address(token0)), 2 ether);
        assertEq(morpho.managedAssets(address(token1)), 1 ether);
    }

    function test_triggerCompoundFromReactive_checksProxyAndSender() public {
        hook.reportFees(key, 20 ether, 0);
        vm.prank(callbackProxy);
        vm.expectRevert(FeeCompounderHook.OnlyRSC.selector);
        hook.triggerCompoundFromReactive(address(0xBAD), key, address(aave));

        vm.prank(callbackProxy);
        hook.triggerCompoundFromReactive(reactiveSender, key, address(aave));
        assertEq(aave.managedAssets(address(token0)), 2 ether);
    }

    function test_unwhitelistedAdapter_reverts() public {
        AaveAdapter rogue = new AaveAdapter(address(hook), 1_000);
        hook.reportFees(key, 20 ether, 0);
        vm.prank(directRsc);
        vm.expectRevert(FeeCompounderHook.AdapterNotWhitelisted.selector);
        hook.triggerCompound(key, address(rogue));
    }

    function test_forceCompound_afterMaxHoldBlocks() public {
        hook.setMaxHoldBlocks(5);
        vm.prank(alice);
        hook.depositForDemo(key, 100 ether, 100 ether, alice);
        hook.reportFees(key, 20 ether, 0);
        vm.roll(block.number + 6);
        hook.exposedAfterSwap(
            address(this),
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0}),
            BalanceDeltaLibrary.ZERO_DELTA,
            ""
        );
        assertEq(poolRoute.managedAssets(address(token0)), 2 ether);
    }

    function test_withdrawShares_returnsPrincipalPendingAndRouteAssets() public {
        vm.prank(alice);
        uint256 shares = hook.depositForDemo(key, 100 ether, 100 ether, alice);
        hook.reportFees(key, 20 ether, 0);
        vm.prank(directRsc);
        hook.triggerCompound(key, address(aave));

        uint256 before0 = token0.balanceOf(alice);
        vm.prank(alice);
        hook.withdrawShares(key, shares, alice);
        assertGt(token0.balanceOf(alice) - before0, 100 ether);
    }

    function test_withdrawShares_withTwoSidedRouteWithdrawsBothAssets() public {
        vm.prank(alice);
        uint256 shares = hook.depositForDemo(key, 100 ether, 100 ether, alice);
        hook.reportFees(key, 20 ether, 10 ether);
        vm.prank(directRsc);
        hook.triggerCompound(key, address(aave));

        vm.prank(alice);
        hook.withdrawShares(key, shares, alice);
        assertLt(aave.managedAssets(address(token0)), 2 ether);
        assertLt(aave.managedAssets(address(token1)), 1 ether);
    }

    function test_lpBalance_returnsShareAssets() public {
        vm.prank(alice);
        uint256 shares = hook.depositForDemo(key, 10 ether, 12 ether, alice);
        (uint256 assets0, uint256 assets1) = hook.lpBalance(id, alice);
        assertEq(shares, hook.lpShares(id, alice));
        assertGt(assets0, 0);
        assertGt(assets1, 0);
    }

    function test_assetsToShares_viewHelperCoversEmptyAndLivePools() public {
        assertEq(hook.assetsToShares(id, 0, 0), 0);
        assertEq(hook.assetsToShares(id, 2 ether, 3 ether), 5 ether);

        vm.prank(alice);
        hook.depositForDemo(key, 10 ether, 10 ether, alice);

        assertGt(hook.assetsToShares(id, 1 ether, 1 ether), 0);
    }

    function test_exposedAfterAddLiquidity_mintsForHookDataLp() public {
        (bytes4 selector,) = hook.exposedAfterAddLiquidity(
            alice,
            key,
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1, salt: bytes32(0)}),
            toBalanceDelta(-3 ether, -4 ether),
            BalanceDeltaLibrary.ZERO_DELTA,
            abi.encode(bob)
        );
        assertEq(selector, hook.afterAddLiquidity.selector);
        assertGt(hook.lpShares(id, bob), 0);
    }

    function test_exposedBeforeRemoveLiquidity_checksShares() public {
        vm.expectRevert(FeeCompounderHook.NoShares.selector);
        hook.exposedBeforeRemoveLiquidity(
            alice, key, ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: -1, salt: bytes32(0)}), ""
        );

        vm.prank(alice);
        hook.depositForDemo(key, 1 ether, 1 ether, alice);
        bytes4 selector = hook.exposedBeforeRemoveLiquidity(
            alice, key, ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: -1, salt: bytes32(0)}), ""
        );
        assertEq(selector, hook.beforeRemoveLiquidity.selector);
    }

    function test_adminSettersAndOwnerGuards() public {
        vm.prank(alice);
        vm.expectRevert(FeeCompounderHook.OnlyOwner.selector);
        hook.setGasCeiling(1);

        hook.setReactiveAuth(address(0x1), address(0x2), address(0x3));
        assertEq(hook.callbackProxy(), address(0x1));
        assertEq(hook.reactiveSender(), address(0x2));
        assertEq(hook.directCompoundCaller(), address(0x3));

        hook.setFeeReporter(alice);
        assertEq(hook.feeReporter(), alice);
        vm.expectRevert(FeeCompounderHook.InvalidAddress.selector);
        hook.setFeeReporter(address(0));

        hook.setMinThreshold(2);
        hook.setGasCeiling(3);
        hook.setCooldownBlocks(4);
        hook.setCompoundFeeBps(500);
        assertEq(hook.minCompoundThreshold(), 2);
        assertEq(hook.gasPriceCeiling(), 3);
        assertEq(hook.cooldownBlocks(), 4);
        assertEq(hook.compoundFeeBps(), 500);

        vm.expectRevert(FeeCompounderHook.InvalidBps.selector);
        hook.setCompoundFeeBps(10_001);

        hook.transferOwnership(bob);
        assertEq(hook.owner(), bob);
        vm.prank(bob);
        vm.expectRevert(FeeCompounderHook.InvalidAddress.selector);
        hook.transferOwnership(address(0));
    }

    function test_paymentHelpers_coverDebtPayAndFailures() public {
        CallbackProxyMock proxy = new CallbackProxyMock();
        hook.setReactiveAuth(address(proxy), reactiveSender, directRsc);
        vm.deal(address(hook), 1 ether);

        proxy.callPay(hook, 0.1 ether);
        assertEq(address(proxy).balance, 0.1 ether);

        vm.expectRevert(FeeCompounderHook.OnlyRSC.selector);
        hook.pay(1 wei);

        proxy.setDebt(0.2 ether);
        assertEq(hook.callbackDebt(), 0.2 ether);
        hook.coverCallbackDebt();
        assertEq(address(proxy).balance, 0.3 ether);

        hook.setReactiveAuth(address(0), reactiveSender, directRsc);
        assertEq(hook.callbackDebt(), 0);
    }

    function test_coverCallbackDebt_revertsWhenProxyRejectsPayment() public {
        RejectingCallbackProxyMock proxy = new RejectingCallbackProxyMock();
        hook.setReactiveAuth(address(proxy), reactiveSender, directRsc);
        vm.deal(address(hook), 1 ether);

        vm.expectRevert(FeeCompounderHook.TransferFailed.selector);
        hook.coverCallbackDebt();
    }

    function test_adapterViewsSettersPauseAndAccessControl() public {
        assertEq(aave.name(), "Aave v3");
        assertEq(aave.currentAPY(address(token0)), 550);

        vm.expectRevert();
        aave.setAPY(999);
        vm.expectRevert();
        aave.setPaused(true);

        vm.prank(address(hook));
        aave.setAPY(999);
        assertEq(aave.currentAPY(address(token0)), 999);

        vm.prank(address(hook));
        aave.setPaused(true);

        hook.reportFees(key, 20 ether, 0);
        vm.prank(directRsc);
        vm.expectRevert();
        hook.triggerCompound(key, address(aave));
    }

    function test_reentrancyGuard_revertsWhenLocked() public {
        hook.setLockedForTest(true);

        vm.prank(alice);
        vm.expectRevert(FeeCompounderHook.Reentrancy.selector);
        hook.depositForDemo(key, 1 ether, 1 ether, alice);

        hook.setLockedForTest(false);
    }

    function test_managedRouteDeposit_returnsShares() public {
        token0.mint(address(hook), 1 ether);

        vm.prank(address(hook));
        token0.approve(address(aave), 1 ether);

        vm.prank(address(hook));
        uint256 shares = aave.deposit(address(token0), 1 ether);

        assertEq(shares, 1 ether);
        assertEq(aave.managedAssets(address(token0)), 1 ether);
    }

    function testFuzz_feeShareAccounting(uint96 depositRaw, uint96 feeRaw) public {
        uint256 deposit = bound(uint256(depositRaw), 1 ether, 1_000 ether);
        uint256 fee = bound(uint256(feeRaw), 1 ether, 100 ether);
        vm.prank(alice);
        uint256 shares = hook.depositForDemo(key, deposit, deposit, alice);
        hook.reportFees(key, fee, fee);
        (uint256 assets0, uint256 assets1) = hook.sharesToAssets(id, shares);
        assertGe(assets0, deposit - 1);
        assertGe(assets1, deposit - 1);
    }

    function _mintAndApprove(address who, uint256 amount0, uint256 amount1) internal {
        token0.mint(who, amount0);
        token1.mint(who, amount1);
        vm.startPrank(who);
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        vm.stopPrank();
    }
}
