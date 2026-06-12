// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ManagedYieldRoute} from "./ManagedYieldRoute.sol";

contract AaveAdapter is ManagedYieldRoute {
    constructor(address hook, uint256 apyBps) ManagedYieldRoute(hook, "Aave v3", apyBps) {}
}
