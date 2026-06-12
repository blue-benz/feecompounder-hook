// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AbstractReactive} from "reactive-lib/abstract-base/AbstractReactive.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

struct RSCBootstrapConfig {
    uint256 destinationChainId;
    address hookAddress;
    uint64 callbackGasLimit;
    bytes32 poolId;
    PoolKey key;
    address aave;
    address morpho;
    address poolRoute;
    uint256 aaveApyBps;
    uint256 morphoApyBps;
    uint256 poolApyBps;
    uint256 threshold;
    uint256 ceiling;
    uint256 cooldown;
}

contract FeeCompounderRSC is IReactive, AbstractReactive {
    error OnlyAdmin();
    error SubscriptionFailed();
    error InvalidRoute();

    uint256 public constant FEES_ACCRUED_TOPIC =
        uint256(keccak256("FeesAccrued(bytes32,uint256,uint256,uint256,uint256,uint256,uint256)"));

    uint256 public immutable DESTINATION_CHAIN_ID;
    address public immutable HOOK_ADDRESS;
    uint64 public immutable CALLBACK_GAS_LIMIT;
    address public immutable SUBSCRIPTION_ADMIN;
    address public immutable CALLBACK_SENDER;

    uint256 public minThreshold = 1 ether;
    uint256 public gasCeiling = 30 gwei;
    uint256 public cooldownBlocks = 300;
    uint256 public economicGasEstimate = 200_000;
    uint256 public profitFactorBps = 1_000;

    address public aaveAdapter;
    address public morphoAdapter;
    address public poolReinvestAdapter;
    uint256 public cachedAaveAPY;
    uint256 public cachedMorphoAPY;
    uint256 public cachedPoolAPY;
    bool public subscriptionConfigured;

    struct PoolConfig {
        PoolKey key;
        bool exists;
    }

    mapping(bytes32 => uint256) public pendingFees;
    mapping(bytes32 => uint256) public lastGasPrice;
    mapping(bytes32 => uint256) public lastCompoundBlock;
    mapping(bytes32 => PoolConfig) internal poolConfigs;

    event SubscriptionConfigured(uint256 indexed chainId, address indexed hook, uint256 topic0);
    event SubscriptionUnavailable();
    event PoolConfigured(bytes32 indexed poolId);
    event RouteAPYUpdated(address indexed route, uint256 apyBps);
    event CompoundSkipped(bytes32 indexed poolId, string reason);
    event CompoundCallbackQueued(bytes32 indexed poolId, address indexed route, uint256 pending, uint256 gasPrice);

    modifier onlyAdmin() {
        if (msg.sender != SUBSCRIPTION_ADMIN) revert OnlyAdmin();
        _;
    }

    constructor(uint256 destinationChainId, address hookAddress, uint64 callbackGasLimit) payable {
        DESTINATION_CHAIN_ID = destinationChainId;
        HOOK_ADDRESS = hookAddress;
        CALLBACK_GAS_LIMIT = callbackGasLimit;
        SUBSCRIPTION_ADMIN = msg.sender;
        CALLBACK_SENDER = msg.sender;
        _configureSubscription(false);
    }

    function configureSubscription() external onlyAdmin {
        _configureSubscription(true);
    }

    function configurePool(bytes32 poolId, PoolKey calldata key) external onlyAdmin {
        poolConfigs[poolId] = PoolConfig({key: key, exists: true});
        emit PoolConfigured(poolId);
    }

    function configureRoutes(address aave, address morpho, address poolRoute) external onlyAdmin {
        aaveAdapter = aave;
        morphoAdapter = morpho;
        poolReinvestAdapter = poolRoute;
    }

    function updateAPYs(uint256 aaveApyBps, uint256 morphoApyBps, uint256 poolApyBps) external onlyAdmin {
        cachedAaveAPY = aaveApyBps;
        cachedMorphoAPY = morphoApyBps;
        cachedPoolAPY = poolApyBps;
        emit RouteAPYUpdated(aaveAdapter, aaveApyBps);
        emit RouteAPYUpdated(morphoAdapter, morphoApyBps);
        emit RouteAPYUpdated(poolReinvestAdapter, poolApyBps);
    }

    function setDecisionConfig(uint256 threshold, uint256 ceiling, uint256 cooldown) external onlyAdmin {
        minThreshold = threshold;
        gasCeiling = ceiling;
        cooldownBlocks = cooldown;
    }

    function react(LogRecord calldata log) external vmOnly {
        if (log.chain_id != DESTINATION_CHAIN_ID || log._contract != HOOK_ADDRESS || log.topic_0 != FEES_ACCRUED_TOPIC)
        {
            return;
        }

        bytes32 id = bytes32(log.topic_1);
        (,, uint256 totalPending0, uint256 totalPending1, uint256 gasPrice, uint256 emittedBlock) =
            abi.decode(log.data, (uint256, uint256, uint256, uint256, uint256, uint256));

        uint256 totalPending = totalPending0 + totalPending1;
        pendingFees[id] = totalPending;
        lastGasPrice[id] = gasPrice;

        if (!poolConfigs[id].exists) {
            emit CompoundSkipped(id, "pool-not-configured");
            return;
        }
        if (totalPending < minThreshold) {
            emit CompoundSkipped(id, "below-threshold");
            return;
        }
        if (gasPrice > gasCeiling) {
            emit CompoundSkipped(id, "gas-too-high");
            return;
        }
        if (emittedBlock < lastCompoundBlock[id] + cooldownBlocks) {
            emit CompoundSkipped(id, "cooldown");
            return;
        }

        address route = _selectOptimalRoute();
        if (route == address(0)) {
            emit CompoundSkipped(id, "route-not-set");
            return;
        }

        lastCompoundBlock[id] = emittedBlock;
        pendingFees[id] = 0;

        bytes memory payload = abi.encodeWithSignature(
            "triggerCompoundFromReactive(address,(address,address,uint24,int24,address),address)",
            CALLBACK_SENDER,
            poolConfigs[id].key,
            route
        );
        emit CompoundCallbackQueued(id, route, totalPending, gasPrice);
        emit Callback(DESTINATION_CHAIN_ID, HOOK_ADDRESS, CALLBACK_GAS_LIMIT, payload);
    }

    function _configureSubscription(bool revertOnFailure) internal {
        if (vm) {
            emit SubscriptionUnavailable();
            return;
        }
        try service.subscribe(
            DESTINATION_CHAIN_ID, HOOK_ADDRESS, FEES_ACCRUED_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
        ) {
            subscriptionConfigured = true;
            emit SubscriptionConfigured(DESTINATION_CHAIN_ID, HOOK_ADDRESS, FEES_ACCRUED_TOPIC);
        } catch {
            if (revertOnFailure) revert SubscriptionFailed();
            emit SubscriptionUnavailable();
        }
    }

    function _selectOptimalRoute() internal view returns (address) {
        if (cachedAaveAPY >= cachedMorphoAPY && cachedAaveAPY >= cachedPoolAPY) return aaveAdapter;
        if (cachedMorphoAPY >= cachedAaveAPY && cachedMorphoAPY >= cachedPoolAPY) return morphoAdapter;
        return poolReinvestAdapter;
    }
}

contract BootstrappedFeeCompounderRSC is FeeCompounderRSC {
    constructor(RSCBootstrapConfig memory config)
        FeeCompounderRSC(config.destinationChainId, config.hookAddress, config.callbackGasLimit)
    {
        poolConfigs[config.poolId] = PoolConfig({key: config.key, exists: true});
        aaveAdapter = config.aave;
        morphoAdapter = config.morpho;
        poolReinvestAdapter = config.poolRoute;
        cachedAaveAPY = config.aaveApyBps;
        cachedMorphoAPY = config.morphoApyBps;
        cachedPoolAPY = config.poolApyBps;
        minThreshold = config.threshold;
        gasCeiling = config.ceiling;
        cooldownBlocks = config.cooldown;

        emit PoolConfigured(config.poolId);
        emit RouteAPYUpdated(config.aave, config.aaveApyBps);
        emit RouteAPYUpdated(config.morpho, config.morphoApyBps);
        emit RouteAPYUpdated(config.poolRoute, config.poolApyBps);
    }
}
