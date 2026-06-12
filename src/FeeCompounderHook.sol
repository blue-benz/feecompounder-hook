// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "v4-hooks-public/src/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20Minimal} from "./interfaces/IERC20Minimal.sol";
import {IYieldRoute} from "./interfaces/IYieldRoute.sol";

interface IReactivePayable {
    function debt(address contract_) external view returns (uint256);
}

contract FeeCompounderHook is BaseHook {
    using BalanceDeltaLibrary for BalanceDelta;

    error OnlyOwner();
    error OnlyRSC();
    error OnlyFeeReporter();
    error InvalidAddress();
    error InvalidBps();
    error AdapterNotWhitelisted();
    error TransferFailed();
    error Reentrancy();
    error NoShares();
    error InsufficientShares();
    error ZeroAmount();

    uint256 public constant BPS = 10_000;
    uint256 public constant DEAD_SHARES = 1_000;

    struct PoolAccounting {
        uint256 totalShares;
        uint256 totalAssets0;
        uint256 totalAssets1;
        uint256 pendingFees0;
        uint256 pendingFees1;
        uint256 routeShares0;
        uint256 routeShares1;
        uint256 lastCompoundBlock;
        address activeYieldRoute;
        bool initialized;
    }

    mapping(bytes32 => PoolAccounting) public pools;
    mapping(bytes32 => mapping(address => uint256)) public lpShares;
    mapping(bytes32 => mapping(address => uint256)) public lpEntryBlock;
    mapping(address => bool) public whitelistedAdapters;

    address public owner;
    address public callbackProxy;
    address public reactiveSender;
    address public directCompoundCaller;
    address public feeReporter;
    address public defaultRoute;

    uint256 public minCompoundThreshold = 1 ether;
    uint256 public gasPriceCeiling = 30 gwei;
    uint256 public cooldownBlocks = 300;
    uint256 public maxHoldBlocks = 7_200;
    uint256 public compoundFeeBps = 1_000;

    bool internal locked;

    event FeesAccrued(
        bytes32 indexed poolId,
        uint256 amount0,
        uint256 amount1,
        uint256 totalPending0,
        uint256 totalPending1,
        uint256 gasPrice,
        uint256 blockNumber
    );
    event CompoundExecuted(
        bytes32 indexed poolId,
        address indexed route,
        uint256 amount0Compounded,
        uint256 amount1Compounded,
        uint256 newTotalAssets0,
        uint256 newTotalAssets1,
        uint256 blockNumber
    );
    event SharesMinted(
        bytes32 indexed poolId, address indexed lp, uint256 sharesIssued, uint256 assets0, uint256 assets1
    );
    event SharesBurned(
        bytes32 indexed poolId, address indexed lp, uint256 sharesBurned, uint256 assets0, uint256 assets1
    );
    event AdapterWhitelistUpdated(address indexed adapter, bool allowed);
    event ReactiveAuthUpdated(
        address indexed callbackProxy, address indexed reactiveSender, address indexed directCaller
    );
    event FeeReporterUpdated(address indexed feeReporter);
    event ConfigUpdated(string key, uint256 value);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    modifier onlyFeeReporter() {
        if (msg.sender != feeReporter) revert OnlyFeeReporter();
        _;
    }

    modifier nonReentrant() {
        _enterNonReentrant();
        _;
        locked = false;
    }

    constructor(
        IPoolManager poolManager,
        address owner_,
        address callbackProxy_,
        address reactiveSender_,
        address directCompoundCaller_
    ) BaseHook(poolManager) {
        if (owner_ == address(0)) revert InvalidAddress();
        owner = owner_;
        feeReporter = owner_;
        callbackProxy = callbackProxy_;
        reactiveSender = reactiveSender_;
        directCompoundCaller = directCompoundCaller_;
        emit OwnershipTransferred(address(0), owner_);
        emit FeeReporterUpdated(owner_);
        emit ReactiveAuthUpdated(callbackProxy_, reactiveSender_, directCompoundCaller_);
    }

    receive() external payable {}

    function _enterNonReentrant() internal {
        if (locked) revert Reentrancy();
        locked = true;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function poolId(PoolKey memory key) public pure returns (bytes32) {
        return keccak256(abi.encode(key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks));
    }

    function pendingFeesFor(bytes32 id) external view returns (uint256 pending0, uint256 pending1) {
        PoolAccounting storage p = pools[id];
        return (p.pendingFees0, p.pendingFees1);
    }

    function lpBalance(bytes32 id, address lp) external view returns (uint256 assets0, uint256 assets1) {
        uint256 shares = lpShares[id][lp];
        return sharesToAssets(id, shares);
    }

    function sharesToAssets(bytes32 id, uint256 shares) public view returns (uint256 assets0, uint256 assets1) {
        PoolAccounting storage p = pools[id];
        if (p.totalShares == 0 || shares == 0) return (0, 0);
        assets0 = (shares * (p.totalAssets0 + p.pendingFees0)) / p.totalShares;
        assets1 = (shares * (p.totalAssets1 + p.pendingFees1)) / p.totalShares;
    }

    function assetsToShares(bytes32 id, uint256 assets0, uint256 assets1) public view returns (uint256 shares) {
        PoolAccounting storage p = pools[id];
        uint256 assets = assets0 + assets1;
        if (assets == 0) return 0;
        uint256 totalAssets = p.totalAssets0 + p.totalAssets1 + p.pendingFees0 + p.pendingFees1;
        if (p.totalShares == 0 || totalAssets == 0) return assets;
        return (assets * p.totalShares) / totalAssets;
    }

    function reportFees(PoolKey calldata key, uint256 rawFee0, uint256 rawFee1) external onlyFeeReporter {
        bytes32 id = poolId(key);
        uint256 fee0 = (rawFee0 * compoundFeeBps) / BPS;
        uint256 fee1 = (rawFee1 * compoundFeeBps) / BPS;
        if (fee0 != 0) _pullToken(Currency.unwrap(key.currency0), msg.sender, fee0);
        if (fee1 != 0) _pullToken(Currency.unwrap(key.currency1), msg.sender, fee1);
        _accrueFees(id, fee0, fee1);
    }

    function depositForDemo(PoolKey calldata key, uint256 amount0, uint256 amount1, address receiver)
        external
        nonReentrant
        returns (uint256 shares)
    {
        if (receiver == address(0)) revert InvalidAddress();
        if (amount0 == 0 && amount1 == 0) revert ZeroAmount();
        if (amount0 != 0) _pullToken(Currency.unwrap(key.currency0), msg.sender, amount0);
        if (amount1 != 0) _pullToken(Currency.unwrap(key.currency1), msg.sender, amount1);
        return _mintShares(poolId(key), receiver, amount0, amount1);
    }

    function withdrawShares(PoolKey calldata key, uint256 shares, address receiver)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        if (receiver == address(0)) revert InvalidAddress();
        bytes32 id = poolId(key);
        if (shares == 0) revert ZeroAmount();
        if (lpShares[id][msg.sender] < shares) revert InsufficientShares();

        PoolAccounting storage p = pools[id];
        amount0 = (shares * (p.totalAssets0 + p.pendingFees0)) / p.totalShares;
        amount1 = (shares * (p.totalAssets1 + p.pendingFees1)) / p.totalShares;
        uint256 route0 = (shares * p.routeShares0) / p.totalShares;
        uint256 route1 = (shares * p.routeShares1) / p.totalShares;

        lpShares[id][msg.sender] -= shares;
        p.totalShares -= shares;
        p.totalAssets0 = p.totalAssets0 + p.pendingFees0 - amount0;
        p.totalAssets1 = p.totalAssets1 + p.pendingFees1 - amount1;
        p.pendingFees0 = 0;
        p.pendingFees1 = 0;

        if (p.activeYieldRoute != address(0)) {
            if (route0 != 0) {
                p.routeShares0 -= route0;
                IYieldRoute(p.activeYieldRoute).withdraw(Currency.unwrap(key.currency0), route0);
            }
            if (route1 != 0) {
                p.routeShares1 -= route1;
                IYieldRoute(p.activeYieldRoute).withdraw(Currency.unwrap(key.currency1), route1);
            }
        }

        if (amount0 != 0) _pushToken(Currency.unwrap(key.currency0), receiver, amount0);
        if (amount1 != 0) _pushToken(Currency.unwrap(key.currency1), receiver, amount1);
        emit SharesBurned(id, msg.sender, shares, amount0, amount1);
    }

    function triggerCompound(PoolKey calldata key, address route) external nonReentrant {
        if (msg.sender != directCompoundCaller) revert OnlyRSC();
        _compound(key, route);
    }

    function triggerCompoundFromReactive(address sender, PoolKey calldata key, address route) external nonReentrant {
        if (msg.sender != callbackProxy || sender != reactiveSender) revert OnlyRSC();
        _compound(key, route);
    }

    function pay(uint256 amount) external {
        if (msg.sender != callbackProxy) revert OnlyRSC();
        _pay(payable(msg.sender), amount);
    }

    function coverCallbackDebt() external {
        _pay(payable(callbackProxy), IReactivePayable(callbackProxy).debt(address(this)));
    }

    function callbackDebt() external view returns (uint256) {
        if (callbackProxy == address(0)) return 0;
        return IReactivePayable(callbackProxy).debt(address(this));
    }

    function _afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata hookData
    ) internal override returns (bytes4, BalanceDelta) {
        address lp = hookData.length == 32 ? abi.decode(hookData, (address)) : sender;
        uint256 amount0 = _abs(delta.amount0());
        uint256 amount1 = _abs(delta.amount1());
        if (amount0 != 0 || amount1 != 0) _mintShares(poolId(key), lp, amount0, amount1);
        return (BaseHook.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function _beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) internal override returns (bytes4) {
        bytes32 id = poolId(key);
        if (lpShares[id][sender] == 0) revert NoShares();
        return BaseHook.beforeRemoveLiquidity.selector;
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        bytes32 id = poolId(key);
        PoolAccounting storage p = pools[id];
        emit FeesAccrued(id, 0, 0, p.pendingFees0, p.pendingFees1, block.basefee, block.number);
        if (p.pendingFees0 + p.pendingFees1 != 0 && block.number > p.lastCompoundBlock + maxHoldBlocks) {
            _compound(key, defaultRoute);
        }
        return (BaseHook.afterSwap.selector, 0);
    }

    function _mintShares(bytes32 id, address lp, uint256 amount0, uint256 amount1) internal returns (uint256 shares) {
        shares = assetsToShares(id, amount0, amount1);
        if (shares == 0) revert ZeroAmount();
        PoolAccounting storage p = pools[id];
        if (p.totalShares == 0 && shares > DEAD_SHARES) {
            p.totalShares = DEAD_SHARES;
            lpShares[id][address(0)] = DEAD_SHARES;
            shares -= DEAD_SHARES;
        }
        p.initialized = true;
        p.totalShares += shares;
        p.totalAssets0 += amount0;
        p.totalAssets1 += amount1;
        lpShares[id][lp] += shares;
        lpEntryBlock[id][lp] = block.number;
        emit SharesMinted(id, lp, shares, amount0, amount1);
    }

    function _accrueFees(bytes32 id, uint256 fee0, uint256 fee1) internal {
        PoolAccounting storage p = pools[id];
        p.pendingFees0 += fee0;
        p.pendingFees1 += fee1;
        emit FeesAccrued(id, fee0, fee1, p.pendingFees0, p.pendingFees1, block.basefee, block.number);
    }

    function _compound(PoolKey calldata key, address route) internal {
        if (!whitelistedAdapters[route]) revert AdapterNotWhitelisted();
        bytes32 id = poolId(key);
        PoolAccounting storage p = pools[id];
        uint256 amount0 = p.pendingFees0;
        uint256 amount1 = p.pendingFees1;
        if (amount0 == 0 && amount1 == 0) revert ZeroAmount();
        p.pendingFees0 = 0;
        p.pendingFees1 = 0;
        p.lastCompoundBlock = block.number;

        if (amount0 != 0) {
            _approveToken(Currency.unwrap(key.currency0), route, amount0);
            p.routeShares0 += IYieldRoute(route).deposit(Currency.unwrap(key.currency0), amount0);
            p.totalAssets0 += amount0;
        }
        if (amount1 != 0) {
            _approveToken(Currency.unwrap(key.currency1), route, amount1);
            p.routeShares1 += IYieldRoute(route).deposit(Currency.unwrap(key.currency1), amount1);
            p.totalAssets1 += amount1;
        }
        p.activeYieldRoute = route;
        emit CompoundExecuted(id, route, amount0, amount1, p.totalAssets0, p.totalAssets1, block.number);
    }

    function setReactiveAuth(address callbackProxy_, address reactiveSender_, address directCompoundCaller_)
        external
        onlyOwner
    {
        callbackProxy = callbackProxy_;
        reactiveSender = reactiveSender_;
        directCompoundCaller = directCompoundCaller_;
        emit ReactiveAuthUpdated(callbackProxy_, reactiveSender_, directCompoundCaller_);
    }

    function setFeeReporter(address feeReporter_) external onlyOwner {
        if (feeReporter_ == address(0)) revert InvalidAddress();
        feeReporter = feeReporter_;
        emit FeeReporterUpdated(feeReporter_);
    }

    function setAdapterWhitelisted(address adapter, bool allowed) external onlyOwner {
        if (adapter == address(0)) revert InvalidAddress();
        whitelistedAdapters[adapter] = allowed;
        if (defaultRoute == address(0) && allowed) defaultRoute = adapter;
        emit AdapterWhitelistUpdated(adapter, allowed);
    }

    function setDefaultRoute(address route) external onlyOwner {
        if (!whitelistedAdapters[route]) revert AdapterNotWhitelisted();
        defaultRoute = route;
    }

    function setMinThreshold(uint256 value) external onlyOwner {
        minCompoundThreshold = value;
        emit ConfigUpdated("minCompoundThreshold", value);
    }

    function setGasCeiling(uint256 value) external onlyOwner {
        gasPriceCeiling = value;
        emit ConfigUpdated("gasPriceCeiling", value);
    }

    function setCooldownBlocks(uint256 value) external onlyOwner {
        cooldownBlocks = value;
        emit ConfigUpdated("cooldownBlocks", value);
    }

    function setMaxHoldBlocks(uint256 value) external onlyOwner {
        maxHoldBlocks = value;
        emit ConfigUpdated("maxHoldBlocks", value);
    }

    function setCompoundFeeBps(uint256 value) external onlyOwner {
        if (value > BPS) revert InvalidBps();
        compoundFeeBps = value;
        emit ConfigUpdated("compoundFeeBps", value);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert InvalidAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function _abs(int128 value) internal pure returns (uint256) {
        return uint256(uint128(value < 0 ? -value : value));
    }

    function _pullToken(address token, address from, uint256 amount) internal {
        if (!IERC20Minimal(token).transferFrom(from, address(this), amount)) revert TransferFailed();
    }

    function _pushToken(address token, address to, uint256 amount) internal {
        if (!IERC20Minimal(token).transfer(to, amount)) revert TransferFailed();
    }

    function _approveToken(address token, address spender, uint256 amount) internal {
        if (!IERC20Minimal(token).approve(spender, 0)) revert TransferFailed();
        if (!IERC20Minimal(token).approve(spender, amount)) revert TransferFailed();
    }

    function _pay(address payable recipient, uint256 amount) internal {
        if (amount == 0) return;
        (bool success,) = recipient.call{value: amount}("");
        if (!success) revert TransferFailed();
    }
}
