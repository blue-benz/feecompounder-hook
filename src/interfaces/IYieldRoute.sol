// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IYieldRoute {
    function deposit(address token, uint256 amount) external returns (uint256 shares);
    function withdraw(address token, uint256 shares) external returns (uint256 amount);
    function currentAPY(address token) external view returns (uint256 apyBps);
    function name() external view returns (string memory);
}
