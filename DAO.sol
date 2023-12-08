// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import {IDAO} from "./interface/IDAO.sol";

// this contract provides multisig functions that can be implemented when needed
contract Multisig is Ownable {
    struct VoterRequest {
        bool status;
        address candidate;
        bool include;
    }

    // mapping voter id => voter address
    mapping(uint256 => address) private votersIds;
    // mapping is address has vote ability
    mapping(address => bool) private voters;
    // how much voters(approved and deprecated)
    uint256 private votersCounter;
    // how much voters are approved
    uint256 private activeVoters;

    // voter requests should be used when someone wants to add new voter or deprecate active voter
    mapping(uint256 => VoterRequest) private voterRequests;
    // mapping of signs of active voters to some voter request
    mapping(uint256 => mapping(address => bool))
        private voterRequsestsSignatures;
    uint256 private voterRequestCounter;

    event NewVotersRequest(uint256[] id);

    // constructor() {
    //     // owner is the first voter
    //     _setVoter(msg.sender);
    // }

    // is voter active
    modifier onlyVoter() {
        require(voters[msg.sender], "not voter");
        _;
    }

    // get information about one voter by id
    function getVoterById(uint256 id) public view returns (address) {
        return votersIds[id];
    }

    // get voter's status by address
    function getVoterStatusByAddress(
        address someAddress
    ) public view returns (bool) {
        return voters[someAddress];
    }

    // get active voters count
    function getActiveVoters() public view returns (uint256) {
        return activeVoters;
    }

    // get all voters count
    function getVotersCounter() internal view returns (uint256) {
        return votersCounter;
    }

    // create new voter after approval
    function setVoter(address newVoter) internal {
        require(newVoter != address(0), "zero address");
        require(!voters[newVoter], "already voter");
        voters[newVoter] = true;
        activeVoters++;
        votersIds[votersCounter++] = newVoter;
    }

    // deprecate some voter
    function unsetVoter(address oldVoter) internal {
        require(oldVoter != address(0), "zero address");
        require(voters[oldVoter], "not voter");
        voters[oldVoter] = false;
        activeVoters--;
    }

    // create request to add new voter to voters list
    function newVotersRequest(address[] memory newVoters) external onlyVoter {
        uint256[] memory newVotersRequestID = new uint256[](newVoters.length);
        for (uint256 i = 0; i < newVoters.length; i++) {
            require(!voters[newVoters[i]], "already voter");
            voterRequestCounter = voterRequestCounter + 1;
            // create request to some candidate to be a voter
            voterRequests[voterRequestCounter] = VoterRequest({
                status: false,
                candidate: newVoters[i],
                include: true
            });
            // sign request
            voterRequsestsSignatures[voterRequestCounter][msg.sender] = true;
            newVotersRequestID[i] = voterRequestCounter;
        }

        emit NewVotersRequest(newVotersRequestID);
    }

    //request to delete voter
    function deleteVotersRequest(
        address[] memory newVoters
    ) external onlyVoter {
        uint256[] memory newVotersRequestID = new uint256[](newVoters.length);
        for (uint256 i = 0; i < newVoters.length; i++) {
            require(voters[newVoters[i]], "no such voter");
            voterRequestCounter = voterRequestCounter + 1;
            // create request to some candidate to be a voter
            voterRequests[voterRequestCounter] = VoterRequest({
                status: false,
                candidate: newVoters[i],
                include: false
            });
            // sign request
            voterRequsestsSignatures[voterRequestCounter][msg.sender] = true;
            newVotersRequestID[i] = voterRequestCounter;
        }

        emit NewVotersRequest(newVotersRequestID);
    }

    // vote for one of voter requests list
    function voteForVoterRequest(uint256 id) external onlyVoter {
        require(!voterRequests[id].status, "already approved");
        voterRequsestsSignatures[id][msg.sender] = true;
    }

    // create new voter after approval
    function setInitialVoter() external onlyOwner {
        require(activeVoters == 0, "AV not empty");
        voters[msg.sender] = true;
        activeVoters++;
        votersIds[votersCounter++] = msg.sender;
    }

    // check voters request to be completed
    function checkVotersRequest(uint256 id) external {
        require(!voterRequests[id].status, "already approved");
        uint256 consensus = (activeVoters * 100) / 2;
        uint256 trueVotesCount = 0;
        for (uint256 i = 0; i < votersCounter; i++) {
            // signed and he voter now
            if (
                voterRequsestsSignatures[id][votersIds[i]] &&
                voters[votersIds[i]]
            ) {
                trueVotesCount++;
            }
        }
        // check is there is enough votes to complete request
        require(trueVotesCount * 100 > consensus, "not enough");
        if (voterRequests[id].include) {
            // if it's request to add new voter and there is enough votes, let's add such voter
            setVoter(voterRequests[id].candidate);
        } else {
            // if it's request to deprecate some voter and there is enough votes, let's deprecate such voter
            unsetVoter(voterRequests[id].candidate);
        }
        // set voter request as completed
        voterRequests[id].status = true;
    }
}

/*
DAO for Bets:
- new voter request
- vote for some new voter request
- delete voter
- vote for some delete voter request
- new transfer(withdrawal) request
- vote for some transfer(withdrawal) request
- new owner transfer request
- vote for some owner transfer request
*/
contract DAO is Multisig, IDAO {
    // if one of voters wants to make some transfer, he adds new transfer request and waits for signs from other voters
    struct TransferRequest {
        address recepient;
        address token;
        uint256 value;
        bool status;
    }
    // if one of voters wants to change owner, he adds new OwnerChangeRequest and waits for signs from other voters
    struct OwnerChangeRequest {
        address newOwner;
        bool status;
    }

    struct DAOChangeRequest {
        address newDAO;
        bool status;
    }
    // mapping of transfer requests
    mapping(uint256 => TransferRequest) private transferRequests;
    // mapping of signs of transfer requests
    mapping(uint256 => mapping(address => bool))
        private transferRequestsSignatures;
    // id for new transfer request
    uint256 private transferRequestCounter;

    // mapping of owner change requests
    mapping(uint256 => OwnerChangeRequest) private ownerChangeRequests;
    // mapping of signs of transfer requests
    mapping(uint256 => mapping(address => bool))
        private ownerChangeRequestsSignatures;
    // id for new transfer request
    uint256 private ownerChangeRequestCounter;

    // mapping of DAO change requests
    mapping(uint256 => DAOChangeRequest) private daoChangeRequests;
    // mapping of signs of DAO change requests
    mapping(uint256 => mapping(address => bool))
        private daoChangeRequestsSignatures;
    // id for new DAO change request
    uint256 private daoChangeRequestCounter;

    // bets contract may it interact with DAO results
    mapping(address => bool) public whitelistedBC;

    event NewTransferRequest(uint256 id);
    event NewOwnerChangeRequest(uint256 id);
    event NewDAOChangeRequest(uint256 id);

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

    /*
    TRANSFER REQUESTS
    */

    // if votes count for some request is enough to provide request, let's do it
    function isTransferAvailable(
        uint256 id
    ) external view override returns (uint256, address, address) {
        require(transferRequests[id].recepient != address(0), "no such");
        require(!transferRequests[id].status, "already approved");
        uint256 consensus = (getActiveVoters() * 100) / 2;
        uint256 trueVotesCount = 0;
        for (uint256 i = 0; i <= getVotersCounter(); i++) {
            // signed and he voter now
            if (
                transferRequestsSignatures[id][getVoterById(i)] &&
                getVoterStatusByAddress(getVoterById(i))
            ) {
                trueVotesCount++;
            }
        }
        require(trueVotesCount * 100 > consensus, "not enough");
        return (
            transferRequests[id].value,
            transferRequests[id].recepient,
            transferRequests[id].token
        );
    }

    // bets contract approve that request finished
    function confirmTransfer(
        uint256 id
    ) external override onlyWhitelistBC returns (bool) {
        require(!transferRequests[id].status, "already approved");
        transferRequests[id].status = true;
        return true;
    }

    // vote for one of transfer requests
    function voteForTransferRequest(uint256 id) external onlyVoter {
        require(!transferRequests[id].status, "already approved");
        transferRequestsSignatures[id][msg.sender] = true;
    }

    // any approved active voter can create request to transfer some amount of tokens from contract to any recepient
    function newTransferRequest(
        address recipient,
        address token,
        uint256 amount
    ) external onlyVoter returns (uint256) {
        require(recipient != address(0), "0x0 addr");
        transferRequestCounter = transferRequestCounter + 1;
        transferRequests[transferRequestCounter] = TransferRequest({
            recepient: recipient,
            value: amount,
            status: false,
            token: token
        });
        // sign request
        transferRequestsSignatures[transferRequestCounter][msg.sender] = true;
        emit NewTransferRequest(transferRequestCounter);
        return transferRequestCounter;
    }

    /*
    OWNER CHANGE
    */
    // if votes count for some request is enough to provide request, let's do it
    function isOwnerChangeAvailable(
        uint256 id
    ) external view override returns (address) {
        require(ownerChangeRequests[id].newOwner != address(0), "no such");
        require(!ownerChangeRequests[id].status, "already approved");
        uint256 consensus = (getActiveVoters() * 100) / 2;
        uint256 trueVotesCount = 0;
        for (uint256 i = 0; i <= getVotersCounter(); i++) {
            // signed and he voter now
            if (
                ownerChangeRequestsSignatures[id][getVoterById(i)] &&
                getVoterStatusByAddress(getVoterById(i))
            ) {
                trueVotesCount++;
            }
        }
        require(trueVotesCount * 100 > consensus, "not enough");
        return ownerChangeRequests[id].newOwner;
    }

    // bets contract approve that request finished
    function confirmOwnerChange(
        uint256 id
    ) external override onlyWhitelistBC returns (bool) {
        require(!ownerChangeRequests[id].status, "already approved");
        ownerChangeRequests[id].status = true;
        return true;
    }

    // vote for one of voter requests list
    function voteForOwnerChangeRequest(uint256 id) external onlyVoter {
        require(!ownerChangeRequests[id].status, "already approved");
        ownerChangeRequestsSignatures[id][msg.sender] = true;
    }

    // any approved active voter can create request to change owner
    function newOwnerChangeRequest(
        address newOwner
    ) external onlyVoter returns (uint256) {
        require(newOwner != address(0), "0x0 addr");
        ownerChangeRequestCounter = ownerChangeRequestCounter + 1;
        ownerChangeRequests[ownerChangeRequestCounter] = OwnerChangeRequest({
            newOwner: newOwner,
            status: false
        });
        // sign request
        ownerChangeRequestsSignatures[ownerChangeRequestCounter][
            msg.sender
        ] = true;
        emit NewOwnerChangeRequest(ownerChangeRequestCounter);
        return ownerChangeRequestCounter;
    }

    /*
    DAO CHANGE
    */
    // if votes count for some request is enough to provide request, let's do it
    function isDAOChangeAvailable(
        uint256 id
    ) external view override returns (address) {
        require(daoChangeRequests[id].newDAO != address(0), "no such");
        require(!daoChangeRequests[id].status, "already approved");
        uint256 consensus = (getActiveVoters() * 100) / 2;
        uint256 trueVotesCount = 0;
        for (uint256 i = 0; i <= getVotersCounter(); i++) {
            // signed and he voter now
            if (
                daoChangeRequestsSignatures[id][getVoterById(i)] &&
                getVoterStatusByAddress(getVoterById(i))
            ) {
                trueVotesCount++;
            }
        }
        require(trueVotesCount * 100 > consensus, "not enough");
        return daoChangeRequests[id].newDAO;
    }

    // bets contract approve that request finished
    function confirmDAOChange(
        uint256 id
    ) external override onlyWhitelistBC returns (bool) {
        require(!daoChangeRequests[id].status, "already approved");
        daoChangeRequests[id].status = true;
        return true;
    }

    // vote for one of voter requests list
    function voteForDAOChangeRequest(uint256 id) external onlyVoter {
        require(!daoChangeRequests[id].status, "already approved");
        daoChangeRequestsSignatures[id][msg.sender] = true;
    }

    // any approved active voter can create request to change owner
    function newDAOChangeRequest(
        address newDAO
    ) external onlyVoter returns (uint256) {
        require(newDAO != address(0), "0x0 addr");
        daoChangeRequestCounter = daoChangeRequestCounter + 1;
        daoChangeRequests[daoChangeRequestCounter] = DAOChangeRequest({
            newDAO: newDAO,
            status: false
        });
        // sign request
        daoChangeRequestsSignatures[daoChangeRequestCounter][msg.sender] = true;
        emit NewDAOChangeRequest(daoChangeRequestCounter);
        return daoChangeRequestCounter;
    }
}
