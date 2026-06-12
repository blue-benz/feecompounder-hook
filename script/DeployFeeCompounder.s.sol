// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "v4-hooks-public/src/utils/HookMiner.sol";
import {FeeCompounderHook} from "../src/FeeCompounderHook.sol";
import {AaveAdapter} from "../src/adapters/AaveAdapter.sol";
import {MorphoAdapter} from "../src/adapters/MorphoAdapter.sol";
import {PoolReinvestAdapter} from "../src/adapters/PoolReinvestAdapter.sol";

contract DeployFeeCompounder is Script {
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address poolManager = vm.envAddress(_poolManagerKey());
        address callbackProxy =
            _nonZero(vm.envOr(_callbackProxyKey(), address(0)), vm.envOr("CALLBACK_PROXY", address(0)));
        address reactiveSender = _nonZero(vm.envOr("RVM_ID", address(0)), vm.envOr("REACTIVE_SENDER", deployer));
        address directCaller = deployer;

        vm.startBroadcast(pk);
        uint160 flags =
            uint160(Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG);
        bytes memory args = abi.encode(IPoolManager(poolManager), deployer, callbackProxy, reactiveSender, directCaller);
        (address minedHook, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(FeeCompounderHook).creationCode, args);

        FeeCompounderHook hook = new FeeCompounderHook{salt: salt}(
            IPoolManager(poolManager), deployer, callbackProxy, reactiveSender, directCaller
        );
        require(address(hook) == minedHook, "hook address mismatch");
        AaveAdapter aave = new AaveAdapter(address(hook), 550);
        MorphoAdapter morpho = new MorphoAdapter(address(hook), 720);
        PoolReinvestAdapter poolRoute = new PoolReinvestAdapter(address(hook), 400);
        hook.setAdapterWhitelisted(address(aave), true);
        hook.setAdapterWhitelisted(address(morpho), true);
        hook.setAdapterWhitelisted(address(poolRoute), true);
        hook.setDefaultRoute(address(poolRoute));
        vm.stopBroadcast();

        console2.log("Deployer", deployer);
        console2.log("FeeCompounderHook", address(hook));
        console2.log("AaveAdapter", address(aave));
        console2.log("MorphoAdapter", address(morpho));
        console2.log("PoolReinvestAdapter", address(poolRoute));
        console2.log("PoolManager", poolManager);
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
