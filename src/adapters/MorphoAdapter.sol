// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ManagedYieldRoute} from "./ManagedYieldRoute.sol";

contract MorphoAdapter is ManagedYieldRoute {
    constructor(address hook, uint256 apyBps) ManagedYieldRoute(hook, "Morpho", apyBps) {}
}
