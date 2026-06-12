// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BootstrappedFeeCompounderRSC, RSCBootstrapConfig} from "../src/rsc/FeeCompounderRSC.sol";

contract DeployBootstrappedFeeCompounderRSC is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        RSCBootstrapConfig memory config = _config();

        vm.startBroadcast(pk);
        BootstrappedFeeCompounderRSC rsc = new BootstrappedFeeCompounderRSC(config);
        vm.stopBroadcast();

        console2.log("BootstrappedFeeCompounderRSC", address(rsc));
        console2.log("Destination chain", config.destinationChainId);
        console2.log("Hook", config.hookAddress);
        console2.logBytes32(config.poolId);
        console2.log("Callback sender/RVM identity", rsc.CALLBACK_SENDER());
        console2.log("Morpho route", config.morpho);
    }

    function _config() internal view returns (RSCBootstrapConfig memory) {
        return RSCBootstrapConfig({
            destinationChainId: vm.envUint("DESTINATION_CHAIN_ID"),
            hookAddress: vm.envAddress("HOOK_ADDRESS"),
            callbackGasLimit: uint64(vm.envOr("CALLBACK_GAS_LIMIT", uint256(1_500_000))),
            poolId: vm.envBytes32("POOL_ID"),
            key: _poolKey(),
            aave: vm.envAddress("AAVE_ADAPTER"),
            morpho: vm.envAddress("MORPHO_ADAPTER"),
            poolRoute: vm.envAddress("POOL_REINVEST_ADAPTER"),
            aaveApyBps: vm.envOr("AAVE_APY_BPS", uint256(550)),
            morphoApyBps: vm.envOr("MORPHO_APY_BPS", uint256(900)),
            poolApyBps: vm.envOr("POOL_APY_BPS", uint256(400)),
            threshold: vm.envOr("MIN_THRESHOLD", uint256(1)),
            ceiling: vm.envOr("GAS_CEILING", uint256(1_000_000_000_000_000)),
            cooldown: vm.envOr("COOLDOWN_BLOCKS", uint256(0))
        });
    }

    function _poolKey() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(vm.envAddress("TOKEN0")),
            currency1: Currency.wrap(vm.envAddress("TOKEN1")),
            fee: uint24(vm.envOr("POOL_FEE", uint256(3000))),
            tickSpacing: int24(int256(vm.envOr("TICK_SPACING", uint256(60)))),
            hooks: IHooks(vm.envAddress("HOOK_ADDRESS"))
        });
    }
}
