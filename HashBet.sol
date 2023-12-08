// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IBankroll} from "./interface/IBankroll.sol";
import {IDAO} from "./interface/IDAO.sol";
import "./Utils/ChainSpecificUtil.sol";

contract HashBet is Ownable, ReentrancyGuard {
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

    // croupiers
    mapping(address => bool) public whitelistedCroupier;

    // address for DAO management operations
    address public dao;

    // address for bankroll
    address public bankroll;

    // Info of each bet.
    struct Bet {
        uint betID;
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
        // Keccak256 hash of some secret "reveal" random number.
        uint256[] commits;
        // Comparison method.
        bool isLarger;
        uint256 stopGain;
        uint256 stopLoss;
        address tokenAddress;
    }

    // Each bet is deducted dynamic
    uint public defaultHouseEdgePercent = 2;

    // Mapping from commits to all currently active & processed bets.
    mapping(uint => Bet) public bets;

    mapping(uint32 => uint32) public houseEdgePercents;

    // stable token that we use to deposit/withdrawal
    mapping(address => bool) public whitelistedERC20;

    // Events
    event BetPlaced(
        address indexed gambler,
        uint256 wager,
        uint8 indexed modulo,
        uint8 rollEdge,
        uint40 mask,
        uint256[] commits,
        bool isLarger,
        uint256 betID
    );
    event BetSettled(
        address indexed gambler,
        uint256 wager,
        uint8 indexed modulo,
        uint8 rollEdge,
        uint40 mask,
        uint256[] outcomes,
        uint256[] payouts,
        uint256 payout,
        uint32 numGames,
        uint256 betID
    );
    event BetRefunded(address indexed gambler, uint256 betID, uint256 amount);

    constructor() Ownable() {
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

    // Set default house edge percent
    function setDefaultHouseEdgePercent(
        uint _houseEdgePercent
    ) external onlyOwner {
        require(
            _houseEdgePercent >= 1 && _houseEdgePercent <= 100,
            "houseEdgePercent must be a sane number"
        );
        defaultHouseEdgePercent = _houseEdgePercent;
    }

    // Set modulo house edge percent
    function setModuloHouseEdgePercent(
        uint32 _houseEdgePercent,
        uint32 modulo
    ) external onlyOwner {
        require(
            _houseEdgePercent >= 1 && _houseEdgePercent <= 100,
            "houseEdgePercent must be a sane number"
        );
        houseEdgePercents[modulo] = _houseEdgePercent;
    }

    // Set min bet amount. minBetAmount should be large enough such that its house edge fee can cover the Chainlink oracle fee.
    function setMinBetAmount(uint _minBetAmount) external onlyOwner {
        minBetAmount = _minBetAmount * 1 gwei;
    }

    // Set max bet amount.
    function setMaxBetAmount(uint _maxBetAmount) external onlyOwner {
        require(
            _maxBetAmount < 5000000 ether,
            "maxBetAmount must be a sane number"
        );
        maxBetAmount = _maxBetAmount;
    }

    // Set max bet reward. Setting this to zero effectively disables betting.
    function setMaxProfit(uint _maxProfit) external onlyOwner {
        require(_maxProfit < 50000000 ether, "maxProfit must be a sane number");
        maxProfit = _maxProfit;
    }

    // Set wealth tax percentage to be added to house edge percent. Setting this to zero effectively disables wealth tax.
    function setWealthTaxIncrementPercent(
        uint _wealthTaxIncrementPercent
    ) external onlyOwner {
        wealthTaxIncrementPercent = _wealthTaxIncrementPercent;
    }

    // Set threshold to trigger wealth tax.
    function setWealthTaxIncrementThreshold(
        uint _wealthTaxIncrementThreshold
    ) external onlyOwner {
        wealthTaxIncrementThreshold = _wealthTaxIncrementThreshold;
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
        uint256 betID,
        uint256 wager,
        uint betMask,
        uint modulo,
        uint commitLastBlock,
        bool isLarger,
        uint256[] calldata commits,
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
        Bet storage bet = bets[betID];
        require(bet.gambler == address(0), "Bet should be in a 'clean' state.");

        bet.betID = betID;

        validateArguments(
            betID,
            wager,
            betMask,
            modulo,
            commitLastBlock,
            isLarger,
            commits,
            stopGain,
            stopLoss
        );

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
        IBankroll(bankroll).lockFunds(
            tokenAddress,
            bet.winAmount * commits.length
        );
        bet.tokenAddress = tokenAddress;

        // Store bet
        bet.modulo = uint8(modulo);
        bet.placeBlockNumber = ChainSpecificUtil.getBlockNumber();
        bet.gambler = payable(msg.sender);
        bet.isSettled = false;
        bet.commits = commits;
        bet.isLarger = isLarger;
        bet.stopGain = stopGain;
        bet.stopLoss = stopLoss;

        // Record bet in event logs
        emit BetPlaced(
            msg.sender,
            bet.wager,
            bet.modulo,
            bet.rollEdge,
            bet.mask,
            bet.commits,
            bet.isLarger,
            bet.betID
        );
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

    // This is the method used to settle 99% of bets. To process a bet with a specific
    // "commit", settleBet should supply a "reveal" number that would Keccak256-hash to
    // "commit". "blockHash" is the block hash of placeBet block as seen by croupier; it
    // is additionally asserted to prevent changing the bet outcomes on Ethereum reorgs.
    function settleBet(
        uint256 betID,
        uint256[] calldata reveal,
        bytes32 blockHash
    ) external onlyCroupier(_msgSender()) {
        Bet storage bet = bets[betID];
        require(bet.gambler != address(0), "Bet should be in a 'bet' state.");
        // Fetch bet parameters into local variables (to save gas).
        uint wager = bet.wager;
        // Validation check
        require(wager > 0, "Bet does not exist."); // Check that bet exists
        require(bet.isSettled == false, "Bet is settled already"); // Check that bet is not settled yet
        require(
            bet.commits.length == reveal.length,
            "Settlement data mismatch"
        ); // wrong settlement data

        uint placeBlockNumber = bet.placeBlockNumber;
        // Check that bet has not expired yet (see comment to BET_EXPIRATION_BLOCKS).
        require(
            ChainSpecificUtil.getBlockNumber() > placeBlockNumber,
            "settleBet before placeBet"
        );

        uint256 numBets = bet.commits.length;
        uint32 i = 0;
        int256 totalValue = 0;
        uint256 payout = 0;

        uint256[] memory outcomes = new uint256[](numBets);
        uint256[] memory payouts = new uint256[](numBets);

        for (i = 0; i < numBets; i++) {
            if (bet.stopGain > 0 && totalValue >= int256(bet.stopGain)) {
                break;
            }
            if (bet.stopLoss > 0 && totalValue <= -int256(bet.stopLoss)) {
                break;
            }
            uint curReval = reveal[i];
            bytes32 curBlockHash = blockHash;
            uint commit = uint256(keccak256(abi.encodePacked(curReval)));
            require(bet.commits[i] == commit, "Reveal data mismatch");

            // Settle bet using reveal and blockHash as entropy sources.
            (uint256 winAmount, uint256 outcome) = settleBetCommon(
                bet,
                curReval,
                curBlockHash
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

        payout += (numBets - i) * bet.wager;

        // Win amount if gambler wins this bet
        uint possibleWinAmount = bet.winAmount;
        // Unlock possibleWinAmount from lockedInBets, regardless of the outcome.
        IBankroll(bankroll).unlockFunds(
            bet.tokenAddress,
            possibleWinAmount * bet.commits.length
        );

        // Update bet records
        bet.isSettled = true;
        uint curBetID = bet.betID;

        emit BetSettled(
            bet.gambler,
            bet.wager,
            uint8(bet.modulo),
            uint8(bet.rollEdge),
            bet.mask,
            outcomes,
            payouts,
            payout,
            i,
            curBetID
        );
    }

    // Common settlement code for settleBet & settleBetUncleMerkleProof.
    function settleBetCommon(
        Bet storage bet,
        uint reveal,
        bytes32 entropyBlockHash
    ) private view returns (uint256 winAmount, uint256 outcome) {
        // Fetch bet parameters into local variables (to save gas).
        uint modulo = bet.modulo;
        uint rollEdge = bet.rollEdge;
        bool isLarger = bet.isLarger;

        // The RNG - combine "reveal" and blockhash of placeBet using Keccak256. Miners
        // are not aware of "reveal" and cannot deduce it from "commit" (as Keccak256
        // preimage is intractable), and house is unable to alter the "reveal" after
        // placeBet have been mined (as Keccak256 collision finding is also intractable).
        bytes32 entropy = keccak256(abi.encodePacked(reveal, entropyBlockHash));

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
        uint amount = bet.wager * bet.commits.length;

        // Validation check
        require(amount > 0, "Bet does not exist."); // Check that bet exists
        require(bet.isSettled == false, "Bet is settled already."); // Check that bet is still open
        require(
            block.number > bet.placeBlockNumber + BET_EXPIRATION_BLOCKS,
            "Wait after placing bet before requesting refund."
        );

        uint possibleWinAmount = bet.winAmount;

        // Unlock possibleWinAmount from lockedInBets, regardless of the outcome.
        IBankroll(bankroll).unlockFunds(
            bet.tokenAddress,
            possibleWinAmount * bet.commits.length
        );

        // Update bet records
        bet.isSettled = true;
        bet.winAmount = 0;

        // Record refund in event logs
        emit BetRefunded(bet.gambler, betID, amount);
    }

    // Check arguments
    function validateArguments(
        uint256,
        uint wager,
        uint betMask,
        uint modulo,
        uint commitLastBlock,
        bool,
        uint256[] calldata commits,
        uint256,
        uint256
    ) private view {
        // Validate input data.
        require(
            modulo == 2 ||
                modulo == 6 ||
                modulo == 36 ||
                modulo == 37 ||
                modulo == 100,
            "Modulo should be valid value."
        );
        require(
            wager >= minBetAmount && wager <= maxBetAmount,
            "Bet amount should be within range."
        );
        require(
            betMask > 0 && betMask < MAX_BET_MASK,
            "Mask should be within range."
        );

        require(
            commits.length >= 1 && commits.length <= 100,
            "Invalid commits length"
        );

        // Check that commit is valid - it has not expired and its signature is valid.
        require(
            ChainSpecificUtil.getBlockNumber() <= commitLastBlock,
            "Commit has expired."
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

    function getModuloHouseEdgePercent(
        uint32 modulo
    ) internal view returns (uint32 houseEdgePercent) {
        houseEdgePercent = houseEdgePercents[modulo];
        if (houseEdgePercent == 0) {
            houseEdgePercent = uint32(defaultHouseEdgePercent);
        }
    }
}
