// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20Minimal} from "../interfaces/IERC20Minimal.sol";
import {IYieldRoute} from "../interfaces/IYieldRoute.sol";

contract ManagedYieldRoute is IYieldRoute {
    error OnlyHook();
    error Paused();
    error TransferFailed();

    address public immutable hook;
    string internal _routeName;
    uint256 public apyBps;
    bool public paused;
    mapping(address => uint256) public managedAssets;

    modifier onlyHook() {
        if (msg.sender != hook) revert OnlyHook();
        _;
    }

    constructor(address hook_, string memory routeName_, uint256 apyBps_) {
        hook = hook_;
        _routeName = routeName_;
        apyBps = apyBps_;
    }

    function setAPY(uint256 apyBps_) external onlyHook {
        apyBps = apyBps_;
    }

    function setPaused(bool paused_) external onlyHook {
        paused = paused_;
    }

    function deposit(address token, uint256 amount) external onlyHook returns (uint256 shares) {
        if (paused) revert Paused();
        if (amount == 0) return 0;
        if (!IERC20Minimal(token).transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        managedAssets[token] += amount;
        shares = amount;
    }

    function withdraw(address token, uint256 shares) external onlyHook returns (uint256 amount) {
        if (shares == 0) return 0;
        amount = shares;
        managedAssets[token] -= amount;
        if (!IERC20Minimal(token).transfer(msg.sender, amount)) revert TransferFailed();
    }

    function currentAPY(address) external view returns (uint256) {
        return apyBps;
    }

    function name() external view returns (string memory) {
        return _routeName;
    }
}
