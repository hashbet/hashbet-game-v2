// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IBankroll {
    // lock funds
    function lockFunds(address token, uint256 amount) external;

    // Unlock funds.
    function unlockFunds(address token, uint256 amount) external;

    // getter for free funds of some token
    function getFreeFunds(address token) external view returns (uint256);
}
