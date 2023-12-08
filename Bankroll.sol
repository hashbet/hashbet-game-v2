// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IBankroll} from "./interface/IBankroll.sol";
import {IDAO} from "./interface/IDAO.sol";

contract Bankroll is Ownable, ReentrancyGuard, IBankroll {
    // Funds that are locked in potentially winning bets. Prevents contract from committing to new bets that it cannot pay out.
    mapping(address => uint256) public lockedInBets;

    // bets contract may it interact with Bankroll
    mapping(address => bool) public whitelistedBC;

    // address for DAO management operations
    address public dao;

    /**
     * @dev Emitted when `value` tokens are moved from one account (`from`) to
     * another (`to`).
     *
     * Note that `value` may be zero.
     */
    event Transfer(address indexed from, address indexed to, uint256 value);

    event TransferFunds(
        uint256 indexed id,
        address indexed to,
        address indexed token,
        uint256 amount
    );

    modifier onlyWhitelistBC() {
        require(whitelistedBC[msg.sender], "not bets SC");
        _;
    }

    // any admin can whitelist new bets contract
    function whitelistBC(address contractAddress) external onlyOwner {
        whitelistedBC[contractAddress] = true;
    }

    // any admin can unwhitelist bets contract
    function unwhitelistBC(address contractAddress) external onlyOwner {
        require(whitelistedBC[contractAddress], "W");
        delete whitelistedBC[contractAddress];
    }

    function setInitialDao(address initialDaoAddress) external onlyOwner {
        require(dao == address(0), "dao not empty");
        require(initialDaoAddress != address(0), "0"); //0x0 addr
        dao = initialDaoAddress;
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Can only be called by the current owner.
     */
    function transferOwnership(address) public virtual override onlyOwner {
        revert("Unimplemented");
    }

    // request to change DAO address
    function daoChange(uint256 id) external {
        address currentDAO = dao;
        dao = IDAO(currentDAO).isDAOChangeAvailable(id);
        require(dao != address(0), "New dao is the zero address");
        require(IDAO(currentDAO).confirmDAOChange(id), "N"); // not confirmed
    }

    // request to DAO for change owner
    function ownerChange(uint256 id) external {
        address newOwner = IDAO(dao).isOwnerChangeAvailable(id);
        require(
            newOwner != address(0),
            "Ownable: new owner is the zero address"
        );
        _transferOwnership(newOwner);
        require(IDAO(dao).confirmOwnerChange(id), "C"); //not confirmed
    }

    // request to DAO for transfer funds
    function transferFunds(uint256 id) external {
        address token;
        uint256 amount;
        address recepient;
        (amount, recepient, token) = IDAO(dao).isTransferAvailable(id);
        require(amount <= this.getBalance(token) - lockedInBets[token], "R"); // not enough reserve

        doTransfer(recepient, token, amount);

        require(IDAO(dao).confirmTransfer(id), "N"); // not confirmed
        emit TransferFunds(id, recepient, token, amount);
    }

    // lock funds
    function lockFunds(
        address token,
        uint256 amount
    ) external override onlyWhitelistBC {
        // Check whether contract has enough funds to accept this bet.
        require(
            this.getFreeFunds(token) >= amount,
            "Unable to accept bet due to insufficient funds"
        );
        lockedInBets[token] += amount;
    }

    // Unlock funds.
    function unlockFunds(
        address token,
        uint256 amount
    ) external override onlyWhitelistBC {
        lockedInBets[token] -= amount;
    }

    // getter for free funds of some token
    function getFreeFunds(address token) external view returns (uint256) {
        return this.getBalance(token) - lockedInBets[token];
    }

    // Fallback payable function used to top up the bank roll.
    fallback() external payable {}

    receive() external payable {
        emit Transfer(msg.sender, address(this), msg.value);
    }

    // getter for IERC20 of some token
    function getIERC(address token) internal pure returns (IERC20) {
        // allow only whitelisted tokens
        return IERC20(token);
    }

    // getter for total lockedInBets funds for some token
    function getLockedInBets(address token) external view returns (uint256) {
        return lockedInBets[token];
    }

    function getBalance(address token) external view returns (uint256) {
        if (token != address(0)) {
            return getIERC(token).balanceOf(address(this));
        } else {
            return address(this).balance;
        }
    }

    function doTransfer(
        address recepient,
        address token,
        uint256 amount
    ) internal {
        if (token != address(0)) {
            require(getIERC(token).transfer(recepient, amount), "C"); // not transfered
        } else {
            (bool sent, ) = recepient.call{value: amount}("");
            require(sent, "F"); // not transfered
        }
    }
}
