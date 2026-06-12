// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookMiner} from "v4-hooks-public/src/utils/HookMiner.sol";
import {FeeCompounderHook} from "../src/FeeCompounderHook.sol";
import {AaveAdapter} from "../src/adapters/AaveAdapter.sol";
import {MorphoAdapter} from "../src/adapters/MorphoAdapter.sol";
import {PoolReinvestAdapter} from "../src/adapters/PoolReinvestAdapter.sol";
import {TestERC20} from "../test/utils/TestERC20.sol";

contract DeployDemoFeeCompounderSystem is Script {
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    address internal deployer;
    address internal poolManager;
    address internal callbackProxy;
    address internal reactiveSender;
    TestERC20 internal token0;
    TestERC20 internal token1;
    FeeCompounderHook internal hook;
    AaveAdapter internal aave;
    MorphoAdapter internal morpho;
    PoolReinvestAdapter internal poolRoute;
    PoolKey internal key;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        deployer = vm.addr(pk);
        poolManager = vm.envAddress(_poolManagerKey());
        callbackProxy = _nonZero(vm.envOr(_callbackProxyKey(), address(0)), vm.envOr("CALLBACK_PROXY", address(0)));
        reactiveSender = _nonZero(vm.envOr("RVM_ID", address(0)), vm.envOr("REACTIVE_SENDER", deployer));

        vm.startBroadcast(pk);
        _deployTokens();
        _deployHookAndRoutes();
        _prepareDemoBalances();
        vm.stopBroadcast();

        _logDeployment();
    }

    function _deployTokens() internal {
        token0 = new TestERC20("FeeCompounder Demo Token 0", "FCD0");
        token1 = new TestERC20("FeeCompounder Demo Token 1", "FCD1");
    }

    function _deployHookAndRoutes() internal {
        uint160 flags =
            uint160(Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG);
        bytes memory args = abi.encode(IPoolManager(poolManager), deployer, callbackProxy, reactiveSender, deployer);
        (, bytes32 salt) = HookMiner.find(CREATE2_DEPLOYER, flags, type(FeeCompounderHook).creationCode, args);

        hook = new FeeCompounderHook{salt: salt}(
            IPoolManager(poolManager), deployer, callbackProxy, reactiveSender, deployer
        );
        aave = new AaveAdapter(address(hook), vm.envOr("AAVE_APY_BPS", uint256(550)));
        morpho = new MorphoAdapter(address(hook), vm.envOr("MORPHO_APY_BPS", uint256(900)));
        poolRoute = new PoolReinvestAdapter(address(hook), vm.envOr("POOL_APY_BPS", uint256(400)));

        hook.setAdapterWhitelisted(address(aave), true);
        hook.setAdapterWhitelisted(address(morpho), true);
        hook.setAdapterWhitelisted(address(poolRoute), true);
        hook.setDefaultRoute(address(poolRoute));

        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: uint24(vm.envOr("POOL_FEE", uint256(3000))),
            tickSpacing: int24(int256(vm.envOr("TICK_SPACING", uint256(60)))),
            hooks: IHooks(address(hook))
        });
    }

    function _prepareDemoBalances() internal {
        uint256 amount = vm.envOr("DEMO_MINT_AMOUNT", uint256(1_000 ether));
        token0.mint(deployer, amount);
        token1.mint(deployer, amount);
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
    }

    function _logDeployment() internal view {
        console2.log("network chain id", block.chainid);
        console2.log("deployer", deployer);
        console2.log("pool manager", poolManager);
        console2.log("callback proxy", callbackProxy);
        console2.log("reactive sender", reactiveSender);
        console2.log("TOKEN0", address(token0));
        console2.log("TOKEN1", address(token1));
        console2.log("HOOK_ADDRESS", address(hook));
        console2.log("AAVE_ADAPTER", address(aave));
        console2.log("MORPHO_ADAPTER", address(morpho));
        console2.log("POOL_REINVEST_ADAPTER", address(poolRoute));
        console2.log("POOL_FEE", key.fee);
        console2.log("TICK_SPACING", key.tickSpacing);
        console2.logBytes32(hook.poolId(key));
    }

    function _poolManagerKey() internal view returns (string memory) {
        if (block.chainid == 11155111) return "SEPOLIA_POOL_MANAGER";
        if (block.chainid == 84532) return "BASE_SEPOLIA_POOL_MANAGER";
        if (block.chainid == 1301) return "UNICHAIN_SEPOLIA_POOL_MANAGER";
        return "SEPOLIA_POOL_MANAGER";
    }

    function _callbackProxyKey() internal view returns (string memory) {
        if (block.chainid == 11155111) return "SEPOLIA_CALLBACK_PROXY";
        if (block.chainid == 84532) return "BASE_SEPOLIA_CALLBACK_PROXY";
        if (block.chainid == 1301) return "UNICHAIN_SEPOLIA_CALLBACK_PROXY";
        return "CALLBACK_PROXY";
    }

    function _nonZero(address preferred, address fallbackValue) internal pure returns (address) {
        return preferred == address(0) ? fallbackValue : preferred;
    }
}
