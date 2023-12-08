// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IDAO {
    function isTransferAvailable(
        uint256 id
    ) external view returns (uint256, address, address);

    function confirmTransfer(uint256 id) external returns (bool);

    function isOwnerChangeAvailable(uint256 id) external view returns (address);

    function confirmOwnerChange(uint256 id) external returns (bool);

    function isDAOChangeAvailable(uint256 id) external view returns (address);

    function confirmDAOChange(uint256 id) external returns (bool);
}
