// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {BootstrappedFeeCompounderRSC, FeeCompounderRSC, RSCBootstrapConfig} from "../src/rsc/FeeCompounderRSC.sol";

contract SubscriptionServiceMock {
    event Subscribe(uint256 chainId, address contractAddress, uint256 topic0);

    function subscribe(uint256 chainId, address contractAddress, uint256 topic0, uint256, uint256, uint256) external {
        emit Subscribe(chainId, contractAddress, topic0);
    }
}

contract RevertingSubscriptionServiceMock {
    function subscribe(uint256, address, uint256, uint256, uint256, uint256) external pure {
        revert("subscription-failed");
    }
}

contract FeeCompounderRSCTest is Test {
    FeeCompounderRSC rsc;
    PoolKey key;
    bytes32 id;

    address hook = address(0xBEEF);
    address aave = address(0xA0A0);
    address morpho = address(0xB0B0);
    address poolRoute = address(0x9001);

    function setUp() public {
        rsc = new FeeCompounderRSC(11155111, hook, 350_000);
        key = PoolKey({
            currency0: Currency.wrap(address(0x1000)),
            currency1: Currency.wrap(address(0x2000)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hook)
        });
        id = keccak256(abi.encode(key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks));
        rsc.configurePool(id, key);
        rsc.configureRoutes(aave, morpho, poolRoute);
        rsc.updateAPYs(500, 800, 300);
    }

    function test_belowThreshold_noCallback() public {
        vm.recordLogs();
        rsc.react(_log(0.1 ether, 0, 10 gwei, 400));
        assertEq(_callbackCount(vm.getRecordedLogs()), 0);
    }

    function test_aboveGasCeiling_noCallback() public {
        vm.recordLogs();
        rsc.react(_log(2 ether, 0, 40 gwei, 400));
        assertEq(_callbackCount(vm.getRecordedLogs()), 0);
    }

    function test_withinCooldown_noCallback() public {
        vm.recordLogs();
        rsc.react(_log(2 ether, 0, 10 gwei, 1));
        assertEq(_callbackCount(vm.getRecordedLogs()), 0);
    }

    function test_allGatesPass_callbackSelectsHighestAPYRoute() public {
        vm.recordLogs();
        rsc.react(_log(2 ether, 1 ether, 10 gwei, 400));
        assertEq(_callbackCount(vm.getRecordedLogs()), 1);
        assertEq(rsc.lastCompoundBlock(id), 400);
        assertEq(rsc.pendingFees(id), 0);
    }

    function test_routeSelection_tiebreakerPrefersAave() public {
        rsc.updateAPYs(900, 900, 100);
        vm.recordLogs();
        rsc.react(_log(2 ether, 0, 10 gwei, 400));
        assertEq(_callbackCount(vm.getRecordedLogs()), 1);
    }

    function test_unconfiguredPool_skips() public {
        IReactive.LogRecord memory log = _log(2 ether, 0, 10 gwei, 400);
        log.topic_1 = uint256(keccak256("other"));
        vm.recordLogs();
        rsc.react(log);
        assertEq(_callbackCount(vm.getRecordedLogs()), 0);
    }

    function test_wrongOriginLog_isIgnored() public {
        IReactive.LogRecord memory log = _log(2 ether, 0, 10 gwei, 400);
        log.chain_id = 1;
        vm.recordLogs();
        rsc.react(log);
        assertEq(_callbackCount(vm.getRecordedLogs()), 0);

        log = _log(2 ether, 0, 10 gwei, 400);
        log._contract = address(0xBAD);
        vm.recordLogs();
        rsc.react(log);
        assertEq(_callbackCount(vm.getRecordedLogs()), 0);
    }

    function test_routeNotSet_skips() public {
        FeeCompounderRSC noRoutes = new FeeCompounderRSC(11155111, hook, 350_000);
        noRoutes.configurePool(id, key);
        noRoutes.updateAPYs(0, 0, 0);

        vm.recordLogs();
        noRoutes.react(_logFor(noRoutes, 2 ether, 0, 10 gwei, 400));
        assertEq(_callbackCount(vm.getRecordedLogs()), 0);
    }

    function test_setDecisionConfig_changesGates() public {
        rsc.setDecisionConfig(5 ether, 1 gwei, 900);
        assertEq(rsc.minThreshold(), 5 ether);
        assertEq(rsc.gasCeiling(), 1 gwei);
        assertEq(rsc.cooldownBlocks(), 900);
    }

    function test_configureSubscription_vmModeEmitsUnavailable() public {
        vm.recordLogs();
        rsc.configureSubscription();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 unavailableSig = keccak256("SubscriptionUnavailable()");
        bool found;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == unavailableSig) found = true;
        }
        assertTrue(found);
    }

    function test_subscriptionSuccessPath_whenSystemContractExists() public {
        address service = 0x0000000000000000000000000000000000fffFfF;
        SubscriptionServiceMock mock = new SubscriptionServiceMock();
        vm.etch(service, address(mock).code);

        FeeCompounderRSC rnRsc = new FeeCompounderRSC(11155111, hook, 350_000);
        assertTrue(rnRsc.subscriptionConfigured());
    }

    function test_configureSubscription_revertsOnServiceFailure() public {
        address service = 0x0000000000000000000000000000000000fffFfF;
        RevertingSubscriptionServiceMock mock = new RevertingSubscriptionServiceMock();
        vm.etch(service, address(mock).code);

        FeeCompounderRSC rnRsc = new FeeCompounderRSC(11155111, hook, 350_000);
        vm.expectRevert(FeeCompounderRSC.SubscriptionFailed.selector);
        rnRsc.configureSubscription();
    }

    function test_bootstrappedRSC_constructorSeedsPoolRoutesAndGates() public {
        RSCBootstrapConfig memory config = RSCBootstrapConfig({
            destinationChainId: 11155111,
            hookAddress: hook,
            callbackGasLimit: 500_000,
            poolId: id,
            key: key,
            aave: aave,
            morpho: morpho,
            poolRoute: poolRoute,
            aaveApyBps: 100,
            morphoApyBps: 200,
            poolApyBps: 300,
            threshold: 7,
            ceiling: 8,
            cooldown: 9
        });
        BootstrappedFeeCompounderRSC bootstrapped = new BootstrappedFeeCompounderRSC(config);

        assertEq(bootstrapped.DESTINATION_CHAIN_ID(), 11155111);
        assertEq(bootstrapped.HOOK_ADDRESS(), hook);
        assertEq(bootstrapped.CALLBACK_GAS_LIMIT(), 500_000);
        assertEq(bootstrapped.aaveAdapter(), aave);
        assertEq(bootstrapped.morphoAdapter(), morpho);
        assertEq(bootstrapped.poolReinvestAdapter(), poolRoute);
        assertEq(bootstrapped.cachedPoolAPY(), 300);
        assertEq(bootstrapped.minThreshold(), 7);
        assertEq(bootstrapped.gasCeiling(), 8);
        assertEq(bootstrapped.cooldownBlocks(), 9);

        vm.recordLogs();
        bootstrapped.react(_logFor(bootstrapped, 10, 0, 1, 20));
        assertEq(_callbackCount(vm.getRecordedLogs()), 1);
    }

    function _log(uint256 total0, uint256 total1, uint256 gasPrice, uint256 emittedBlock)
        internal
        view
        returns (IReactive.LogRecord memory)
    {
        return _logFor(rsc, total0, total1, gasPrice, emittedBlock);
    }

    function _logFor(FeeCompounderRSC target, uint256 total0, uint256 total1, uint256 gasPrice, uint256 emittedBlock)
        internal
        view
        returns (IReactive.LogRecord memory)
    {
        return IReactive.LogRecord({
            chain_id: 11155111,
            _contract: hook,
            topic_0: target.FEES_ACCRUED_TOPIC(),
            topic_1: uint256(id),
            topic_2: 0,
            topic_3: 0,
            data: abi.encode(uint256(0), uint256(0), total0, total1, gasPrice, emittedBlock),
            block_number: emittedBlock,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });
    }

    function _callbackCount(Vm.Log[] memory logs) internal pure returns (uint256 count) {
        bytes32 callbackSig = keccak256("Callback(uint256,address,uint64,bytes)");
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == callbackSig) count++;
        }
    }
}
