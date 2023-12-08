// SPDX-License-Identifier: MIT

pragma solidity ^0.8.10;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IBankroll} from "./interface/IBankroll.sol";
import {IDAO} from "./interface/IDAO.sol";
import "./Utils/ChainSpecificUtil.sol";

interface IVRFCoordinatorV2 is VRFCoordinatorV2Interface {
    function getFeeConfig()
        external
        view
        returns (
            uint32 fulfillmentFlatFeeLinkPPMTier1,
            uint32 fulfillmentFlatFeeLinkPPMTier2,
            uint32 fulfillmentFlatFeeLinkPPMTier3,
            uint32 fulfillmentFlatFeeLinkPPMTier4,
            uint32 fulfillmentFlatFeeLinkPPMTier5,
            uint24 reqsForTier2,
            uint24 reqsForTier3,
            uint24 reqsForTier4,
            uint24 reqsForTier5
        );
}

contract HashBetChainlink is Ownable, ReentrancyGuard {
    // Modulo is the number of equiprobable outcomes in a game:
    //  2 for coin flip
    //  6 for dice roll
    //  6*6 = 36 for double dice
    //  37 for roulette
    //  100 for hashroll
    uint constant MAX_MODULO = 100;

    // Modulos below MAX_MASK_MODULO are checked against a bit mask, allowing betting on specific outcomes.
    // For example in a dice roll (modolo = 6),
    // 000001 mask means betting on 1. 000001 converted from binary to decimal becomes 1.
    // 101000 mask means betting on 4 and 6. 101000 converted from binary to decimal becomes 40.
    // The specific value is dictated by the fact that 256-bit intermediate
    // multiplication result allows implementing population count efficiently
    // for numbers that are up to 42 bits, and 40 is the highest multiple of
    // eight below 42.
    uint constant MAX_MASK_MODULO = 40;

    // EVM BLOCKHASH opcode can query no further than 256 blocks into the
    // past. Given that settleBet uses block hash of placeBet as one of
    // complementary entropy sources, we cannot process bets older than this
    // threshold. On rare occasions dice2.win croupier may fail to invoke
    // settleBet in this timespan due to technical issues or extreme Ethereum
    // congestion; such bets can be refunded via invoking refundBet.
    uint constant BET_EXPIRATION_BLOCKS = 250;

    // This is a check on bet mask overflow. Maximum mask is equivalent to number of possible binary outcomes for maximum modulo.
    uint constant MAX_BET_MASK = 2 ** MAX_MASK_MODULO;

    // These are constants taht make O(1) population count in placeBet possible.
    uint constant POPCNT_MULT =
        0x0000000000002000000000100000000008000000000400000000020000000001;
    uint constant POPCNT_MASK =
        0x0001041041041041041041041041041041041041041041041041041041041041;
    uint constant POPCNT_MODULO = 0x3F;

    uint256 private constant GRACE_PERIOD_TIME = 3600;

    // In addition to house edge, wealth tax is added every time the bet amount exceeds a multiple of a threshold.
    // For example, if wealthTaxIncrementThreshold = 3000 ether,
    // A bet amount of 3000 ether will have a wealth tax of 1% in addition to house edge.
    // A bet amount of 6000 ether will have a wealth tax of 2% in addition to house edge.
    uint public wealthTaxIncrementThreshold = 3000 ether;
    uint public wealthTaxIncrementPercent = 1;

    // The minimum and maximum bets.
    uint public minBetAmount = 0.01 ether;
    uint public maxBetAmount = 10000 ether;

    // max bet profit. Used to cap bets against dynamic odds.
    uint public maxProfit = 300000 ether;

    // The minimum larger comparison value.
    uint public minOverValue = 1;

    // The maximum smaller comparison value.
    uint public maxUnderValue = 98;

    uint32 constant maxGasLimit = 2500000;

    // The default is 3, but you can set this higher.
    uint16 constant requestConfirmations = 3;

    // croupiers
    mapping(address => bool) public whitelistedCroupier;

    // address for DAO management operations
    address public dao;

    // address for bankroll
    address public bankroll;

    address public ChainLinkVRF;
    bytes32 public ChainLinkKeyHash;
    uint64 public ChainLinkSubID;

    // Info of each bet.
    struct Bet {
        // Wager amount in wei.
        uint wager;
        // Modulo of a game.
        uint8 modulo;
        // Number of winning outcomes, used to compute winning payment (* modulo/rollEdge),
        // and used instead of mask for games with modulo > MAX_MASK_MODULO.
        uint8 rollEdge;
        // Bit mask representing winning bet outcomes (see MAX_MASK_MODULO comment).
        uint40 mask;
        // Block number of placeBet tx.
        uint placeBlockNumber;
        // Address of a gambler, used to pay out winning bets.
        address payable gambler;
        // Status of bet settlement.
        bool isSettled;
        // Win amount.
        uint winAmount;
        // Comparison method.
        bool isLarger;
        // VRF request id
        uint256 requestID;
        uint32 numBets;
        uint256 stopGain;
        uint256 stopLoss;
        address tokenAddress;
    }

    // Each bet is deducted
    uint public defaultHouseEdgePercent = 2;

    uint256 public requestCounter;
    mapping(uint256 => uint256) s_requestIDToRequestIndex;
    // bet place time
    mapping(uint256 => uint256) betPlaceTime;
    // bet data
    mapping(uint256 => Bet) public bets;

    mapping(uint32 => uint32) public houseEdgePercents;

    // stable token that we use to deposit/withdrawal
    mapping(address => bool) public whitelistedERC20;

    // Events
    event BetPlaced(
        address indexed gambler,
        uint amount,
        uint indexed betID,
        uint8 indexed modulo,
        uint8 rollEdge,
        uint40 mask,
        bool isLarger
    );
    event BetSettled(
        address indexed gambler,
        uint256 wager,
        uint8 indexed modulo,
        uint8 rollEdge,
        uint40 mask,
        uint256[] randomWords,
        uint256[] outcomes,
        uint256[] payouts,
        uint256 payout,
        uint32 numGames,
        uint256 betID
    );
    event BetRefunded(address indexed gambler, uint256 betID, uint amount);

    event TransferFunds(
        uint256 indexed id,
        address indexed to,
        address indexed token,
        uint256 amount
    );

    /**
     * @dev Emitted when `value` tokens are moved from one account (`from`) to
     * another (`to`).
     *
     * Note that `value` may be zero.
     */
    event Transfer(address indexed from, address indexed to, uint256 value);

    error OnlyCoordinatorCanFulfill(address have, address want);
    error NotAwaitingVRF();
    error AwaitingVRF(uint256 requestID);
    error RefundFailed();
    error InvalidValue(uint256 required, uint256 sent);
    error TransferFailed();
    error SequencerDown();
    error GracePeriodNotOver();

    constructor(address _vrfCoordinator, bytes32 keyHash, uint64 subID) {
        ChainLinkVRF = _vrfCoordinator;
        ChainLinkKeyHash = keyHash;
        ChainLinkSubID = subID;
        houseEdgePercents[2] = 1;
        houseEdgePercents[6] = 1;
        houseEdgePercents[36] = 1;
        houseEdgePercents[37] = 1;
        houseEdgePercents[100] = 1;
    }

    modifier onlyWhitelist(address token) {
        require(whitelistedERC20[token], "OW");
        _;
    }

    // Standard modifier on methods invokable only by croupier.
    modifier onlyCroupier(address croupier) {
        require(whitelistedCroupier[croupier], "OC");
        _;
    }

    // any admin can whitelist new erc20 token to use
    function whitelistERC20(address token) external onlyOwner {
        whitelistedERC20[token] = true;
    }

    // any admin can unwhitelist erc20 token to use
    function unwhitelistERC20(address token) external onlyOwner {
        require(whitelistedERC20[token], "W");
        delete whitelistedERC20[token];
    }

    // any admin can whitelist croupier
    function whitelistCroupier(address croupier) external onlyOwner {
        whitelistedCroupier[croupier] = true;
    }

    // any admin can unwhitelist croupier
    function unwhitelistCroupier(address croupier) external onlyOwner {
        require(whitelistedCroupier[croupier], "C");
        delete whitelistedCroupier[croupier];
    }

    //set bankroll
    function setBankroll(address newBankroll) external onlyOwner {
        bankroll = newBankroll;
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

    // Place bet
    function placeBet(
        uint wager,
        uint betMask,
        uint modulo,
        bool isLarger,
        uint32 numBets,
        uint256 stopGain,
        uint256 stopLoss,
        address tokenAddress
    )
        external
        payable
        onlyCroupier(_msgSender())
        onlyWhitelist(tokenAddress)
        nonReentrant
    {
        address msgSender = _msgSender();
        Bet memory bet;

        validateArguments(wager, numBets, betMask, modulo);

        if (modulo <= MAX_MASK_MODULO) {
            // Small modulo games can specify exact bet outcomes via bit mask.
            // rollEdge is a number of 1 bits in this mask (population count).
            // This magic looking formula is an efficient way to compute population
            // count on EVM for numbers below 2**40.
            bet.rollEdge = uint8(
                ((betMask * POPCNT_MULT) & POPCNT_MASK) % POPCNT_MODULO
            );
            bet.mask = uint40(betMask);
        } else {
            // Larger modulos games specify the right edge of half-open interval of winning bet outcomes.
            bet.rollEdge = uint8(betMask);
        }

        bet.wager = wager;
        // Winning amount.
        bet.winAmount = getDiceWinAmount(
            bet.wager,
            modulo,
            bet.rollEdge,
            isLarger
        );

        // Update lock funds,lock single winning amount multipy number of bets
        IBankroll(bankroll).lockFunds(tokenAddress, bet.winAmount * numBets);
        bet.tokenAddress = tokenAddress;

        uint256 requestID = _requestRandomWords(numBets);

        s_requestIDToRequestIndex[requestID] = requestCounter;
        betPlaceTime[requestCounter] = block.timestamp;

        // Store bet
        bet.modulo = uint8(modulo);
        bet.placeBlockNumber = ChainSpecificUtil.getBlockNumber();
        bet.gambler = payable(msg.sender);
        bet.isSettled = false;
        bet.requestID = requestID;
        bet.isLarger = isLarger;
        bet.numBets = numBets;
        bet.stopGain = stopGain;
        bet.stopLoss = stopLoss;

        bets[requestCounter] = bet;

        // Record bet in event logs
        emit BetPlaced(
            msgSender,
            bet.wager,
            requestCounter,
            bet.modulo,
            bet.rollEdge,
            bet.mask,
            bet.isLarger
        );

        requestCounter += 1;
    }

    // Get the expected win amount after house edge is subtracted.
    function getDiceWinAmount(
        uint amount,
        uint modulo,
        uint rollEdge,
        bool isLarger
    ) private view returns (uint winAmount) {
        require(
            0 < rollEdge && rollEdge <= modulo,
            "Win probability out of range."
        );
        uint houseEdge = (amount *
            (getModuloHouseEdgePercent(uint32(modulo)) +
                getWealthTax(amount))) / 100;
        uint realRollEdge = rollEdge;
        if (modulo == MAX_MODULO && isLarger) {
            realRollEdge = MAX_MODULO - rollEdge - 1;
        }
        winAmount = ((amount - houseEdge) * modulo) / realRollEdge;

        // round down to multiple 1000Gweis
        winAmount = (winAmount / 1e12) * 1e12;

        uint maxWinAmount = amount + maxProfit;

        if (winAmount > maxWinAmount) {
            winAmount = maxWinAmount;
        }
    }

    // Get wealth tax
    function getWealthTax(uint amount) private view returns (uint wealthTax) {
        wealthTax =
            (amount / wealthTaxIncrementThreshold) *
            wealthTaxIncrementPercent;
    }

    // Common settlement code for settleBet.
    function settleBetCommon(
        Bet storage bet,
        uint reveal
    ) private view returns (uint256 winAmount, uint256 outcome) {
        // Fetch bet parameters into local variables (to save gas).
        uint modulo = bet.modulo;
        uint rollEdge = bet.rollEdge;
        bool isLarger = bet.isLarger;

        // The RNG - combine "reveal" and blockhash of placeBet using Keccak256. Miners
        // are not aware of "reveal" and cannot deduce it from "commit" (as Keccak256
        // preimage is intractable), and house is unable to alter the "reveal" after
        // placeBet have been mined (as Keccak256 collision finding is also intractable).
        bytes32 entropy = keccak256(abi.encodePacked(reveal));

        // Do a roll by taking a modulo of entropy. Compute winning amount.
        outcome = uint(entropy) % modulo;

        // Win amount if gambler wins this bet
        uint possibleWinAmount = bet.winAmount;

        // Actual win amount by gambler
        winAmount = 0;

        // Determine dice outcome.
        if (modulo <= MAX_MASK_MODULO) {
            // For small modulo games, check the outcome against a bit mask.
            if ((2 ** outcome) & bet.mask != 0) {
                winAmount = possibleWinAmount;
            }
        } else {
            // For larger modulos, check inclusion into half-open interval.
            if (isLarger) {
                if (outcome > rollEdge) {
                    winAmount = possibleWinAmount;
                }
            } else {
                if (outcome < rollEdge) {
                    winAmount = possibleWinAmount;
                }
            }
        }
    }

    // Return the bet in extremely unlikely scenario it was not settled by Chainlink VRF.
    // In case you ever find yourself in a situation like this, just contact hashbet support.
    // However, nothing precludes you from calling this method yourself.
    function refundBet(uint256 betID) external payable nonReentrant {
        Bet storage bet = bets[betID];
        uint amount = bet.wager * bet.numBets;
        uint betTime = betPlaceTime[betID];

        // Validation check
        require(amount > 0, "Bet does not exist."); // Check that bet exists
        require(bet.isSettled == false, "Bet is settled already."); // Check that bet is still open
        require(
            block.timestamp >= (betTime + 1 hours),
            "Wait after placing bet before requesting refund."
        );

        // Unlock possibleWinAmount from lockedInBets, regardless of the outcome.
        IBankroll(bankroll).unlockFunds(
            bet.tokenAddress,
            bet.winAmount * bet.numBets
        );

        // Update bet records
        bet.isSettled = true;
        bet.winAmount = 0;

        // Record refund in event logs
        emit BetRefunded(bet.gambler, betID, amount);

        delete (s_requestIDToRequestIndex[bet.requestID]);
        delete (betPlaceTime[betID]);
    }

    // Check arguments
    function validateArguments(
        uint amount,
        uint32 numBets,
        uint betMask,
        uint modulo
    ) private view {
        // Validate input data.
        require(numBets >= 1 && numBets <= 100, "Invalid number of bets");
        require(
            modulo == 2 ||
                modulo == 6 ||
                modulo == 36 ||
                modulo == 37 ||
                modulo == 100,
            "Modulo should be valid value."
        );
        require(
            amount >= minBetAmount && amount <= maxBetAmount,
            "Bet amount should be within range."
        );

        if (modulo <= MAX_MASK_MODULO) {
            require(
                betMask > 0 && betMask < MAX_BET_MASK,
                "Mask should be within range."
            );
        }

        if (modulo == MAX_MODULO) {
            require(
                betMask >= minOverValue && betMask <= maxUnderValue,
                "High modulo range, Mask should be within range."
            );
        }
    }

    /**
     * @dev function to send the request for randomness to chainlink
     * @param numWords number of random numbers required
     */
    function _requestRandomWords(
        uint32 numWords
    ) internal returns (uint256 s_requestID) {
        s_requestID = VRFCoordinatorV2Interface(ChainLinkVRF)
            .requestRandomWords(
                ChainLinkKeyHash,
                ChainLinkSubID,
                requestConfirmations,
                maxGasLimit,
                numWords
            );
    }

    /**
     * @dev function called by Chainlink VRF with random numbers
     * @param requestID id provided when the request was made
     * @param randomWords array of random numbers
     */
    function rawFulfillRandomWords(
        uint256 requestID,
        uint256[] memory randomWords
    ) external {
        if (msg.sender != ChainLinkVRF) {
            revert OnlyCoordinatorCanFulfill(msg.sender, ChainLinkVRF);
        }
        fulfillRandomWords(requestID, randomWords);
    }

    function fulfillRandomWords(
        uint256 requestID,
        uint256[] memory randomWords
    ) internal {
        uint256 betID = s_requestIDToRequestIndex[requestID];
        Bet storage bet = bets[betID];
        if (bet.gambler == address(0)) revert();

        // Validation check
        require(bet.wager > 0, "Bet does not exist."); // Check that bet exists
        require(bet.isSettled == false, "Bet is settled already"); // Check that bet is not settled yet

        // Settle bet must be within one hour
        require(
            block.timestamp < (betPlaceTime[betID] + 1 hours),
            "settleBet has expired."
        );

        // Check that bet has not expired yet (see comment to BET_EXPIRATION_BLOCKS).
        require(
            ChainSpecificUtil.getBlockNumber() > bet.placeBlockNumber,
            "settleBet before placeBet"
        );

        uint32 i = 0;
        int256 totalValue = 0;
        uint256 payout = 0;

        uint256[] memory outcomes = new uint256[](bet.numBets);
        uint256[] memory payouts = new uint256[](bet.numBets);

        for (i = 0; i < bet.numBets; i++) {
            if (bet.stopGain > 0 && totalValue >= int256(bet.stopGain)) {
                break;
            }
            if (bet.stopLoss > 0 && totalValue <= -int256(bet.stopLoss)) {
                break;
            }
            uint curReval = randomWords[i];
            // Settle bet using reveal as entropy sources.
            (uint256 winAmount, uint256 outcome) = settleBetCommon(
                bet,
                curReval
            );
            outcomes[i] = outcome;

            if (winAmount > 0) {
                totalValue += int256(winAmount - bet.wager);
                payout += winAmount;
                payouts[i] = winAmount;
                continue;
            }

            totalValue -= int256(bet.wager);
        }

        payout += (bet.numBets - i) * bet.wager;

        // Unlock possibleWinAmount from lockedInBets, regardless of the outcome.
        IBankroll(bankroll).unlockFunds(
            bet.tokenAddress,
            bet.winAmount * bet.numBets
        );

        // Update bet records
        bet.isSettled = true;
        uint256[] memory curRandomWords = randomWords;
        uint32 curIdx = i;
        uint256 curBetID = betID;

        emit BetSettled(
            bet.gambler,
            bet.wager,
            uint8(bet.modulo),
            uint8(bet.rollEdge),
            bet.mask,
            curRandomWords,
            outcomes,
            payouts,
            payout,
            curIdx,
            curBetID
        );

        delete (s_requestIDToRequestIndex[requestID]);
        delete (betPlaceTime[betID]);
    }

    function getModuloHouseEdgePercent(
        uint32 modulo
    ) internal view returns (uint32 houseEdgePercent) {
        houseEdgePercent = houseEdgePercents[modulo];
        if (houseEdgePercent == 0) {
            houseEdgePercent = uint32(defaultHouseEdgePercent);
        }
    }
}
