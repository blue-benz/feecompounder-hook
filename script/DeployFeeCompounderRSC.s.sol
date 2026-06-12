// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {FeeCompounderRSC} from "../src/rsc/FeeCompounderRSC.sol";

contract DeployFeeCompounderRSC is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        uint256 destinationChainId = vm.envOr("DESTINATION_CHAIN_ID", uint256(11155111));
        address hook = vm.envAddress("HOOK_ADDRESS");
        uint64 callbackGasLimit = uint64(vm.envOr("CALLBACK_GAS_LIMIT", uint256(350_000)));

        vm.startBroadcast(pk);
        FeeCompounderRSC rsc = new FeeCompounderRSC(destinationChainId, hook, callbackGasLimit);
        vm.stopBroadcast();

        console2.log("FeeCompounderRSC", address(rsc));
        console2.log("Destination chain", destinationChainId);
        console2.log("Hook", hook);
        console2.log("Callback sender/RVM identity", rsc.CALLBACK_SENDER());
    }
}
