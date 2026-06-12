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

contract LocalE2E is Script {
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    address internal actor;
    TestERC20 internal token0;
    TestERC20 internal token1;
    FeeCompounderHook internal hook;
    MorphoAdapter internal morpho;
    PoolKey internal key;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        actor = vm.addr(pk);

        vm.startBroadcast(pk);
        _deploySystem();
        _prepareActorBalances();

        console2.log("Phase 1: Deploy demo token pair and FeeCompounder system");
        console2.log("Hook", address(hook));
        console2.log("Morpho route APY bps", morpho.apyBps());

        console2.log("Phase 2: LP deposits demo-backed inventory and receives shares");
        uint256 shares = hook.depositForDemo(key, 100 ether, 100 ether, actor);
        console2.log("Shares", shares);

        console2.log("Phase 3: Swaps produce fees; fee reporter transfers the compounding slice");
        hook.reportFees(key, 20 ether, 10 ether);
        _logPending();

        console2.log("Phase 4: Reactive decision selects best route; local script calls direct RSC path");
        hook.triggerCompound(key, address(morpho));
        console2.log("Morpho managed token0", morpho.managedAssets(address(token0)));
        console2.log("Morpho managed token1", morpho.managedAssets(address(token1)));

        console2.log("Phase 5: LP withdraws principal plus compounded fee reserve");
        hook.withdrawShares(key, shares, actor);
        console2.log("Final token0 balance", token0.balanceOf(actor));
        console2.log("Final token1 balance", token1.balanceOf(actor));
        vm.stopBroadcast();
    }

    function _deploySystem() internal {
        token0 = new TestERC20("Demo ETH", "dETH");
        token1 = new TestERC20("Demo USDC", "dUSDC");
        uint160 flags =
            uint160(Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG);
        bytes memory args = abi.encode(IPoolManager(address(0xCAFE)), actor, address(0xCA11BAC), actor, actor);
        (, bytes32 salt) = HookMiner.find(CREATE2_DEPLOYER, flags, type(FeeCompounderHook).creationCode, args);
        hook = new FeeCompounderHook{salt: salt}(IPoolManager(address(0xCAFE)), actor, address(0xCA11BAC), actor, actor);
        AaveAdapter aave = new AaveAdapter(address(hook), 550);
        morpho = new MorphoAdapter(address(hook), 900);
        PoolReinvestAdapter poolRoute = new PoolReinvestAdapter(address(hook), 400);
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
    }

    function _prepareActorBalances() internal {
        token0.mint(actor, 1_000 ether);
        token1.mint(actor, 1_000 ether);
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
    }

    function _logPending() internal view {
        (uint256 pending0, uint256 pending1) = hook.pendingFeesFor(hook.poolId(key));
        console2.log("Pending token0", pending0);
        console2.log("Pending token1", pending1);
    }
}
