// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title Blackjack
 * @notice A feature-complete implementation of a Blackjack game for sepolia blockchain.
 * @dev Educational demo; randomness is NOT secure. For production, use VRF and consider FHE for privacy.
 */
contract Blackjack {
    // ========= Enums & Structs =========
    enum TableStatus { Waiting, Active, Closed }
    enum GamePhase { WaitingForPlayers, Dealing, PlayerTurns, DealerTurn, Showdown, Completed }
    enum Outcome { Lose, Win, Push, Blackjack }

    struct Card { uint8 rank; /* 2-14 (11=J,12=Q,13=K,14=A) */ uint8 suit; /* 0..3 hearts,diamonds,clubs,spades */ }

    struct Player {
        address addr;
        uint chips;
        uint bet;
        Card[] cards;
        bool isActive;  // in current hand
        bool hasActed;  // this turn
    }

    struct Dealer { Card[] cards; bool hasFinished; }

    struct PlayerResult {
        address addr;
        uint bet;
        uint total;
        Outcome outcome;
        uint payout;
        Card[] cards;
    }

    struct HandResult {
        Card[] dealerCards;
        uint dealerTotal;
        bool dealerBusted;
        PlayerResult[] results;
        uint pot;
        uint timestamp;
    }

    struct Table {
        uint id;
        TableStatus status;
        uint minBuyIn;
        uint maxBuyIn;
        uint8[52] deck;   // 1..52
        uint8 deckIndex;  // next to deal
        GamePhase phase;
        Player[] players;
        Dealer dealer;
        uint lastActivityTimestamp;

        HandResult lastHandResult;  // persisted snapshot for UI
    }

    // ========= State =========
    Table[] public tables;
    uint public constant MAX_TABLES  = 10;
    uint public constant MAX_PLAYERS = 4;
    uint public constant TURN_TIMEOUT = 30 seconds;

    // Blackjack payout: 3:2 (total returned = 2.5x bet)
    uint public constant BLACKJACK_PAYOUT_NUM = 3; // numerator
    uint public constant BLACKJACK_PAYOUT_DEN = 2; // denominator

    // Economy & bank
    uint public constant CHIPS_PER_ETH = 100_000_000;          // 1 ETH = 100,000,000 chips
    uint public constant WEI_PER_CHIP  = 1e18 / CHIPS_PER_ETH; // 10,000,000,000 wei
    uint public constant INITIAL_BANK_CHIPS = 1_000_000_000;   // 1B chips (~10 ETH equivalent)

    mapping(address => uint) public playerTableId; // player -> tableId (0 if none)
    mapping(address => bool) public hasClaimedFreeChips;
    mapping(address => uint) public playerChips;   // wallet chips (not at table)

    uint public bankChips; // dealer bank in chips (backing payouts)

    // Reentrancy guard
    bool private _locked;

    // Admin
    address public owner;
    bool    public paused;

    // ========= Events =========
    event TableCreated(uint indexed tableId, address indexed creator);
    event PlayerJoined(uint indexed tableId, address indexed player, uint amount);
    event PlayerLeft(uint indexed tableId, address indexed player);
    event GameStarted(uint indexed tableId);
    event HandStarted(uint indexed tableId);
    event PlayerAction(uint indexed tableId, address indexed player, string action, uint amount);
    event DealerAction(uint indexed tableId, string action);
    event DealerHoleCardRevealed(uint indexed tableId, Card card);
    event WinnerDetermined(uint indexed tableId, address[] winners, uint[] amounts);
    event PayoutSent(uint indexed tableId, address indexed player, uint amount);
    event PhaseChanged(uint indexed tableId, GamePhase newPhase);
    event CardDealt(uint indexed tableId, address indexed player, Card card);
    event PlayerBusted(uint indexed tableId, address indexed player);
    event PlayerStood(uint indexed tableId, address indexed player);
    event BetPlaced(uint indexed tableId, address indexed player, uint amount);
    event ChipsConverted(address indexed player, uint weiAmount, uint chipAmount);
    event FreeChipsClaimed(address indexed player, uint amount);
    event ChipsPurchased(address indexed player, uint weiAmount, uint chipAmount);
    event ChipsWithdrawn(address indexed player, uint chipAmount, uint weiAmount);
    event TurnAutoAdvanced(uint indexed tableId, address indexed playerTimedOut, string reason);
    event TableChipsToppedUp(uint indexed tableId, address indexed player, uint amount);
    event BankFunded(uint weiAmount, uint chipsAdded);
    event BankDefunded(uint chipsWithdrawn, uint weiAmount);
    event HandResultStored(uint indexed tableId, uint timestamp);
    event BankInitialized(uint chips); // NEW: prefund-at-deploy (no ETH)

    // ========= Modifiers =========
    modifier nonReentrant() { require(!_locked, "ReentrancyGuard"); _locked = true; _; _locked = false; }
    modifier whenNotPaused() { require(!paused, "Paused"); _; }
    modifier onlyOwner()     { require(msg.sender == owner, "Only owner"); _; }

    modifier atActiveTable(uint tableId) {
        require(tableId > 0 && tableId <= tables.length, "Table DNE");
        require(playerTableId[msg.sender] == tableId, "Not at this table");
        _;
    }
    modifier isMyTurn(uint tableId) {
        Table storage t = _getTable(tableId);
        require(t.status == TableStatus.Active, "Inactive");
        require(t.phase  == GamePhase.PlayerTurns, "Not player phase");
        require(_isMyTurnInternal(tableId, msg.sender), "Not your turn");
        _;
    }

    // ========= Constructor =========
    constructor() {
        owner = msg.sender;
        bankChips = INITIAL_BANK_CHIPS;         // << Prefund in chips only
        emit BankInitialized(INITIAL_BANK_CHIPS);
    }

    // ========= Views for frontend =========
    function getTableState(uint tableId) external view returns (Table memory) {
        require(tableId > 0 && tableId <= tables.length, "Table DNE");
        return tables[tableId - 1];
    }
    function getAllTables() external view returns (Table[] memory) { return tables; }
    function getTablesCount() external view returns (uint) { return tables.length; }
    function getPlayerTableId(address player) external view returns (uint) { return playerTableId[player]; }

    function isPlayerTurn(uint tableId, address player) external view returns (bool) {
        if (tableId == 0 || tableId > tables.length) return false;
        if (playerTableId[player] != tableId) return false;
        Table storage t = tables[tableId - 1];
        if (t.status != TableStatus.Active || t.phase != GamePhase.PlayerTurns) return false;
        return _isMyTurnInternal(tableId, player);
    }

    function getConversionRates() external pure returns (uint chipsPerEth, uint weiPerChip) {
        return (CHIPS_PER_ETH, WEI_PER_CHIP);
    }
    function ethToChips(uint weiAmount) public pure returns (uint) { // wei -> chips
        return weiAmount / WEI_PER_CHIP;
    }
    function chipsToWei(uint chipAmount) public pure returns (uint) { // chips -> wei
        return chipAmount * WEI_PER_CHIP;
    }

    function getNextPlayer(uint tableId) external view returns (address) {
        return _nextPlayerAddr(tableId);
    }

    // Provide last hand snapshot for UI
    function getLastHandResult(uint tableId)
        external
        view
        returns (
            Card[] memory dealerCards,
            uint dealerTotal,
            bool dealerBusted,
            PlayerResult[] memory results,
            uint pot,
            uint timestamp
        )
    {
        Table storage t = _getTable(tableId);
        HandResult storage hr = t.lastHandResult;
        return (hr.dealerCards, hr.dealerTotal, hr.dealerBusted, hr.results, hr.pot, hr.timestamp);
    }

    // ========= Internals (shared) =========
    function _getTable(uint tableId) private view returns (Table storage) {
        require(tableId > 0 && tableId <= tables.length, "Table DNE");
        return tables[tableId - 1];
    }
    function _getPlayerIndex(uint tableId, address playerAddr) private view returns (uint) {
        Table storage t = _getTable(tableId);
        for (uint i=0;i<t.players.length;i++) if (t.players[i].addr == playerAddr) return i;
        revert("Player not found");
    }
    function _getPlayerAtTable(uint tableId, address playerAddr) private view returns (Player storage) {
        Table storage t = _getTable(tableId);
        return t.players[_getPlayerIndex(tableId, playerAddr)];
    }

    function _isMyTurnInternal(uint tableId, address who) private view returns (bool) {
        Table storage t = _getTable(tableId);
        if (t.phase != GamePhase.PlayerTurns) return false;
        for (uint i=0;i<t.players.length;i++) {
            if (t.players[i].isActive && !t.players[i].hasActed) {
                if (t.players[i].addr == who) {
                    for (uint j=0;j<i;j++) if (t.players[j].isActive && !t.players[j].hasActed) return false;
                    return true;
                }
                return false;
            }
        }
        return false;
    }

    function _nextPlayerAddr(uint tableId) private view returns (address) {
        if (tableId == 0 || tableId > tables.length) return address(0);
        Table storage t = tables[tableId - 1];
        if (t.phase != GamePhase.PlayerTurns) return address(0);
        for (uint i=0;i<t.players.length;i++)
            if (t.players[i].isActive && !t.players[i].hasActed) return t.players[i].addr;
        return address(0);
    }

    // ========= Economy =========
    function claimFreeChips() external whenNotPaused {
        require(!hasClaimedFreeChips[msg.sender], "Already claimed");
        require(playerTableId[msg.sender] == 0, "Leave table first");
        uint freeChipAmount = 10_000;
        hasClaimedFreeChips[msg.sender] = true;
        playerChips[msg.sender] += freeChipAmount;
        emit FreeChipsClaimed(msg.sender, freeChipAmount);
    }

    function buyChips() external payable whenNotPaused {
        require(msg.value > 0, "Send ETH");
        require(playerTableId[msg.sender] == 0, "Leave table first");
        uint chips = ethToChips(msg.value);
        playerChips[msg.sender] += chips;
        emit ChipsPurchased(msg.sender, msg.value, chips);
        emit ChipsConverted(msg.sender, msg.value, chips);
    }

    function withdrawChips(uint chipAmount) external whenNotPaused nonReentrant {
        require(chipAmount > 0, "Zero");
        require(playerChips[msg.sender] >= chipAmount, "Insufficient chips");
        require(playerTableId[msg.sender] == 0, "Leave table first");
        uint weiAmount = chipsToWei(chipAmount);
        require(address(this).balance >= weiAmount, "Contract lacks ETH");
        playerChips[msg.sender] -= chipAmount;
        (bool ok,) = payable(msg.sender).call{value: weiAmount}("");
        require(ok, "ETH transfer failed");
        emit ChipsWithdrawn(msg.sender, chipAmount, weiAmount);
    }

    function getPlayerChips(address player) external view returns (uint) { return playerChips[player]; }

    /// @notice Top up chips at a table from your wallet balance (only between hands)
    function topUpTableChips(uint tableId, uint amount) external whenNotPaused atActiveTable(tableId) {
        require(amount > 0, "Amount=0");
        Table storage t = _getTable(tableId);
        require(t.phase == GamePhase.WaitingForPlayers, "Only between hands");
        require(playerChips[msg.sender] >= amount, "Insufficient wallet chips");

        uint idx = _getPlayerIndex(tableId, msg.sender);
        playerChips[msg.sender] -= amount;
        t.players[idx].chips += amount;

        t.lastActivityTimestamp = block.timestamp;
        emit TableChipsToppedUp(tableId, msg.sender, amount);
    }

    // Owner funds/withdraws bank (optional ETH backing for withdrawals)
    function fundBank() external payable onlyOwner {
        require(msg.value > 0, "No ETH sent");
        uint chips = ethToChips(msg.value);
        bankChips += chips;
        emit BankFunded(msg.value, chips);
    }

    function defundBank(uint chipAmount) external onlyOwner nonReentrant {
        require(chipAmount > 0 && chipAmount <= bankChips, "Invalid amount");
        uint weiAmount = chipsToWei(chipAmount);
        require(address(this).balance >= weiAmount, "Contract lacks ETH");
        bankChips -= chipAmount;
        (bool ok,) = payable(msg.sender).call{value: weiAmount}("");
        require(ok, "ETH transfer failed");
        emit BankDefunded(chipAmount, weiAmount);
    }

    // ========= Table lifecycle =========
    function createTable(uint _minBuyIn, uint _maxBuyIn) external whenNotPaused {
        require(tables.length < MAX_TABLES, "Max tables");
        require(_minBuyIn > 0 && _maxBuyIn >= _minBuyIn, "Invalid stakes");

        tables.push();
        uint tableId = tables.length;
        Table storage t = tables[tableId - 1];

        t.id = tableId;
        t.status = TableStatus.Waiting;
        t.minBuyIn = _minBuyIn;
        t.maxBuyIn = _maxBuyIn;
        t.deckIndex = 0;
        t.phase = GamePhase.WaitingForPlayers;
        t.lastActivityTimestamp = block.timestamp;

        emit TableCreated(tableId, msg.sender);
    }

    function joinTable(uint tableId, uint buyInAmount) external whenNotPaused {
        Table storage t = _getTable(tableId);
        require(t.players.length < MAX_PLAYERS, "Table full");
        require(playerTableId[msg.sender] == 0, "Already at table");
        require(buyInAmount >= t.minBuyIn && buyInAmount <= t.maxBuyIn, "Invalid buy-in");
        require(playerChips[msg.sender] >= buyInAmount, "Insufficient chips");

        playerChips[msg.sender] -= buyInAmount;

        t.players.push();
        Player storage p = t.players[t.players.length - 1];
        p.addr = msg.sender;
        p.chips = buyInAmount;
        p.bet = 0;
        p.isActive = false;
        p.hasActed = true;
        // p.cards is empty by default

        playerTableId[msg.sender] = tableId;
        t.lastActivityTimestamp = block.timestamp;
        emit PlayerJoined(tableId, msg.sender, buyInAmount);

        if (t.players.length >= 2 && t.status == TableStatus.Waiting) {
            t.status = TableStatus.Active;
            emit GameStarted(tableId);
        }
    }

    function leaveTable(uint tableId) external atActiveTable(tableId) {
        Table storage t = _getTable(tableId);
        uint idx = _getPlayerIndex(tableId, msg.sender);
        Player storage p = t.players[idx];

        if (t.phase != GamePhase.WaitingForPlayers) {
            // Leaving mid-hand: forfeits bet; return remaining chips, remove player
            uint remaining = p.chips;
            p.chips = 0;
            p.isActive = false;

            playerChips[msg.sender] += remaining;
            playerTableId[msg.sender] = 0;

            for (uint i = idx; i < t.players.length - 1; i++) {
                t.players[i] = t.players[i + 1];
            }
            t.players.pop();

            emit PlayerLeft(tableId, msg.sender);
            t.lastActivityTimestamp = block.timestamp;
            return;
        }

        // Normal leave
        playerChips[msg.sender] += p.chips;
        for (uint i=idx; i<t.players.length-1; i++) t.players[i] = t.players[i+1];
        t.players.pop();
        playerTableId[msg.sender] = 0;
        emit PlayerLeft(tableId, msg.sender);

        if (t.players.length < 2) {
            t.status = TableStatus.Waiting;
            t.phase = GamePhase.WaitingForPlayers;
            emit PhaseChanged(tableId, GamePhase.WaitingForPlayers);
        }
        t.lastActivityTimestamp = block.timestamp;
    }

    function cashOut(uint tableId) external atActiveTable(tableId) nonReentrant {
        Table storage t = _getTable(tableId);
        require(t.phase == GamePhase.WaitingForPlayers, "Active hand");
        uint idx = _getPlayerIndex(tableId, msg.sender);
        Player storage p = t.players[idx];
        uint amount = p.chips; require(amount > 0, "No chips");
        playerChips[msg.sender] += amount;
        for (uint i=idx; i<t.players.length-1; i++) t.players[i] = t.players[i+1];
        t.players.pop();
        playerTableId[msg.sender] = 0;
        emit PlayerLeft(tableId, msg.sender);
        if (t.players.length < 2) { t.status = TableStatus.Waiting; t.phase = GamePhase.WaitingForPlayers; emit PhaseChanged(tableId, GamePhase.WaitingForPlayers); }
        t.lastActivityTimestamp = block.timestamp;
    }

    // ========= Player actions =========
    function placeBet(uint tableId, uint betAmount) external atActiveTable(tableId) {
        Table storage t = _getTable(tableId);
        require(t.phase == GamePhase.WaitingForPlayers, "Betting closed");
        Player storage p = _getPlayerAtTable(tableId, msg.sender);
        require(betAmount >= t.minBuyIn && betAmount <= p.chips, "Invalid bet");

        p.bet = betAmount;
        p.chips -= betAmount;
        p.isActive = true;
        p.hasActed = true;
        emit PlayerAction(tableId, msg.sender, "Bet", betAmount);
        emit BetPlaced(tableId, msg.sender, betAmount);

        // see if we can start dealing
        uint activeBettors; uint playersEligibleNoBet;
        for (uint i=0;i<t.players.length;i++) {
            if (t.players[i].isActive && t.players[i].bet > 0) activeBettors++;
            else if (t.players[i].chips >= t.minBuyIn && t.players[i].bet == 0) playersEligibleNoBet++;
        }

        if (activeBettors > 0 && (playersEligibleNoBet == 0 || t.players.length == 1)) {
            _startNewHand(tableId);
        }
        t.lastActivityTimestamp = block.timestamp;
    }

    function hit(uint tableId) external atActiveTable(tableId) isMyTurn(tableId) {
        Table storage t = _getTable(tableId);
        require(t.phase == GamePhase.PlayerTurns, "Not player phase");
        Player storage p = _getPlayerAtTable(tableId, msg.sender);

        _dealCardToPlayer(tableId, msg.sender);
        emit PlayerAction(tableId, msg.sender, "Hit", 0);

        if (_isBusted(p.cards)) {
            p.isActive = false;
            p.hasActed = true;
            emit PlayerBusted(tableId, msg.sender);
            _advanceToNextPlayer(tableId);
        }
        t.lastActivityTimestamp = block.timestamp;
    }

    function stand(uint tableId) external atActiveTable(tableId) isMyTurn(tableId) {
        Table storage t = _getTable(tableId);
        require(t.phase == GamePhase.PlayerTurns, "Not player phase");
        Player storage p = _getPlayerAtTable(tableId, msg.sender);
        p.hasActed = true;
        emit PlayerAction(tableId, msg.sender, "Stand", 0);
        emit PlayerStood(tableId, msg.sender);
        _advanceToNextPlayer(tableId);
        t.lastActivityTimestamp = block.timestamp;
    }

    function doubleDown(uint tableId) external atActiveTable(tableId) isMyTurn(tableId) {
        Table storage t = _getTable(tableId);
        require(t.phase == GamePhase.PlayerTurns, "Not player phase");
        Player storage p = _getPlayerAtTable(tableId, msg.sender);
        require(p.cards.length == 2, "Only on first two cards");
        require(p.chips >= p.bet, "Insufficient chips");

        p.chips -= p.bet;
        p.bet   *= 2;
        p.hasActed = true;

        _dealCardToPlayer(tableId, msg.sender);
        emit PlayerAction(tableId, msg.sender, "DoubleDown", p.bet);
        if (_isBusted(p.cards)) p.isActive = false;

        _advanceToNextPlayer(tableId);
        t.lastActivityTimestamp = block.timestamp;
    }

    function forceAdvanceOnTimeout(uint tableId) external {
        Table storage t = _getTable(tableId);
        require(t.phase == GamePhase.PlayerTurns, "Not player phase");
        require(block.timestamp >= t.lastActivityTimestamp + TURN_TIMEOUT, "Not timed out");

        for (uint i=0;i<t.players.length;i++) {
            Player storage p = t.players[i];
            if (p.isActive && !p.hasActed) {
                p.hasActed = true;
                emit TurnAutoAdvanced(tableId, p.addr, "timeout-stand");
                _advanceToNextPlayer(tableId);
                t.lastActivityTimestamp = block.timestamp;
                return;
            }
        }
        _startDealerTurn(tableId);
        t.lastActivityTimestamp = block.timestamp;
    }

    // ========= Internal game flow =========

    // Bank coverage pre-check (fail fast before starting a hand)
    function _requireBankCoverage(uint tableId) internal view {
        Table storage t = tables[tableId - 1];
        uint totalBets;
        for (uint i = 0; i < t.players.length; i++) {
            if (t.players[i].isActive && t.players[i].bet > 0) {
                totalBets += t.players[i].bet;
            }
        }
        // Worst-case extra liability if everyone has blackjack = 1.5x total bets
        uint maxExtra = (totalBets * BLACKJACK_PAYOUT_NUM) / BLACKJACK_PAYOUT_DEN; // 1.5x
        require(bankChips >= maxExtra, "Bank needs funding");
    }

    function _startNewHand(uint tableId) internal {
        Table storage t = _getTable(tableId);

        // Ensure bankroll can cover worst-case before we deal
        _requireBankCoverage(tableId);

        t.status = TableStatus.Active;
        t.phase  = GamePhase.Dealing;
        t.deckIndex = 0;

        _shuffleDeck(tableId);

        // players: reset and deal two
        for (uint i = 0; i < t.players.length; i++) {
            if (t.players[i].bet > 0 && t.players[i].isActive) {
                delete t.players[i].cards; // clear previous hand
                t.players[i].hasActed = false;
                _dealCardToPlayer(tableId, t.players[i].addr);
                _dealCardToPlayer(tableId, t.players[i].addr);
            } else {
                t.players[i].isActive = false;
                t.players[i].hasActed = true;
                delete t.players[i].cards;
            }
        }

        // dealer: two cards (first is the face-down hole)
        delete t.dealer.cards;
        _dealCardToDealer(tableId);
        _dealCardToDealer(tableId);

        _checkForNaturalBlackjacks(tableId);

        if (t.phase == GamePhase.Dealing) {
            t.phase = GamePhase.PlayerTurns;
            emit PhaseChanged(tableId, GamePhase.PlayerTurns);
        }
        emit HandStarted(tableId);
        t.lastActivityTimestamp = block.timestamp;
    }

    function _checkForNaturalBlackjacks(uint tableId) internal {
        Table storage t = _getTable(tableId);
        bool dealerBJ = _isBlackjack(t.dealer.cards);

        bool anyPlayerBJ; bool anyPlayerNeedsAct;
        for (uint i=0;i<t.players.length;i++) if (t.players[i].isActive) {
            bool pBJ = _isBlackjack(t.players[i].cards);
            if (pBJ) { anyPlayerBJ = true; t.players[i].hasActed = true; }
            else { anyPlayerNeedsAct = true; }
        }

        if (dealerBJ || (anyPlayerBJ && !anyPlayerNeedsAct)) {
            _startDealerTurn(tableId);
        }
    }

    function _shuffleDeck(uint tableId) internal {
        Table storage t = _getTable(tableId);
        for (uint8 i=0;i<52;i++) t.deck[i] = i + 1;
        // INSECURE shuffle (demo only)
        uint seed = uint(keccak256(abi.encodePacked(block.timestamp, block.prevrandao, msg.sender)));
        for (uint i=0;i<51;i++) {
            uint j = i + ((seed + i) % (52 - i));
            (t.deck[i], t.deck[j]) = (t.deck[j], t.deck[i]);
        }
    }

    // Reshuffle-on-low to avoid mid-hand reverts (simple safety)
    function _ensureCardsAvailable(Table storage t, uint need, uint tableId) private {
        if (52 - t.deckIndex < need) {
            t.deckIndex = 0;
            _shuffleDeck(tableId);
        }
    }

    function _dealCardToPlayer(uint tableId, address playerAddr) private {
        Table storage t = _getTable(tableId);
        _ensureCardsAvailable(t, 1, tableId);
        Card memory c = _cardFromIndex(t.deck[t.deckIndex]); t.deckIndex++;
        for (uint i=0;i<t.players.length;i++) if (t.players[i].addr == playerAddr) {
            t.players[i].cards.push(c);
            break;
        }
        emit CardDealt(tableId, playerAddr, c);
    }

    function _dealCardToDealer(uint tableId) private {
        Table storage t = _getTable(tableId);
        _ensureCardsAvailable(t, 1, tableId);
        Card memory c = _cardFromIndex(t.deck[t.deckIndex]); t.deckIndex++;
        t.dealer.cards.push(c);
        emit CardDealt(tableId, address(this), c);
    }

    function _cardFromIndex(uint8 index) internal pure returns (Card memory) {
        uint8 suit = (index - 1) / 13;
        uint8 rank = ((index - 1) % 13) + 2;
        return Card(rank, suit);
    }

    function _advanceToNextPlayer(uint tableId) internal {
        Table storage t = _getTable(tableId);
        for (uint i=0;i<t.players.length;i++) if (t.players[i].isActive && !t.players[i].hasActed) return;
        _startDealerTurn(tableId);
    }

    function _startDealerTurn(uint tableId) internal {
        Table storage t = _getTable(tableId);
        t.phase = GamePhase.DealerTurn;
        emit PhaseChanged(tableId, GamePhase.DealerTurn);

        // Reveal hole card (index 0 is the face-down hole)
        if (t.dealer.cards.length > 0) emit DealerHoleCardRevealed(tableId, t.dealer.cards[0]);

        // If no active players remain, skip draws and settle
        bool anyActive;
        for (uint i=0;i<t.players.length;i++) if (t.players[i].isActive) { anyActive = true; break; }
        if (!anyActive) {
            t.dealer.hasFinished = true;
            _storeAndSettle(tableId);
            return;
        }

        // Dealer hits until hard 17+; hits on soft 17
        while (true) {
            (uint dv, bool soft) = _handValueWithSoftFlag(t.dealer.cards);
            if (dv > 21) break;
            if (dv > 17) break;            // 18..21 stands
            if (dv == 17 && !soft) break;  // hard 17 stands
            _dealCardToDealer(tableId); emit DealerAction(tableId, "Hit");
        }

        t.dealer.hasFinished = true;
        _storeAndSettle(tableId);
    }

    // Store snapshot & perform chip settlement via bank
    function _storeAndSettle(uint tableId) internal {
        Table storage t = _getTable(tableId);

        uint dealerValue = _calculateHandValue(t.dealer.cards);
        bool dealerBusted = dealerValue > 21;

        // Count active players & collect bets into bank
        uint activeCount;
        uint collected;
        for (uint i=0;i<t.players.length;i++) {
            if (t.players[i].isActive) {
                activeCount++;
                collected += t.players[i].bet;
            }
        }
        bankChips += collected;

        // Compute winner count for event arrays
        uint winCount;
        for (uint i=0;i<t.players.length;i++) {
            Player storage p = t.players[i];
            if (!p.isActive) continue;
            uint pv = _calculateHandValue(p.cards);
            if (pv <= 21 && (dealerBusted || pv > dealerValue)) winCount++;
        }
        address[] memory winnersAddrs = new address[](winCount);
        uint[] memory winnersPayouts  = new uint[](winCount);

        // Build PlayerResult array in memory
        PlayerResult[] memory resultsTmp = new PlayerResult[](activeCount);
        uint k; uint w;

        for (uint i=0;i<t.players.length;i++) {
            Player storage p = t.players[i];
            if (!p.isActive) continue;

            uint pv = _calculateHandValue(p.cards);
            bool bj = _isBlackjack(p.cards);

            // copy player's cards to memory
            Card[] memory pcards = new Card[](p.cards.length);
            for (uint c=0; c<p.cards.length; c++) pcards[c] = p.cards[c];

            PlayerResult memory pr;
            pr.addr = p.addr;
            pr.bet = p.bet;
            pr.total = pv;
            pr.cards = pcards;

            if (pv > 21) {
                pr.outcome = Outcome.Lose;
                pr.payout = 0;
            } else if (dealerBusted || pv > dealerValue) {
                pr.outcome = bj ? Outcome.Blackjack : Outcome.Win;
                pr.payout = bj
                    ? p.bet + (p.bet * BLACKJACK_PAYOUT_NUM / BLACKJACK_PAYOUT_DEN) // 2.5x
                    : p.bet * 2; // 2x
                require(bankChips >= pr.payout, "Bank underfunded");
                bankChips -= pr.payout;
                p.chips += pr.payout;

                winnersAddrs[w] = p.addr;
                winnersPayouts[w] = pr.payout;
                w++;

                emit PayoutSent(tableId, p.addr, pr.payout);
            } else if (pv == dealerValue) {
                pr.outcome = Outcome.Push;
                pr.payout = p.bet; // return bet
                require(bankChips >= p.bet, "Bank underfunded");
                bankChips -= p.bet;
                p.chips += p.bet;
            } else {
                pr.outcome = Outcome.Lose;
                pr.payout = 0;
            }

            resultsTmp[k++] = pr;
        }

        if (winCount > 0) emit WinnerDetermined(tableId, winnersAddrs, winnersPayouts);

        // Persist HandResult to storage (deep copies)
        delete t.lastHandResult.dealerCards;
        for (uint dc=0; dc<t.dealer.cards.length; dc++) {
            t.lastHandResult.dealerCards.push(t.dealer.cards[dc]);
        }
        t.lastHandResult.dealerTotal = dealerValue;
        t.lastHandResult.dealerBusted = dealerBusted;

        delete t.lastHandResult.results;
        for (uint r=0; r<resultsTmp.length; r++) {
            t.lastHandResult.results.push();
            PlayerResult storage dst = t.lastHandResult.results[t.lastHandResult.results.length - 1];
            dst.addr = resultsTmp[r].addr;
            dst.bet = resultsTmp[r].bet;
            dst.total = resultsTmp[r].total;
            dst.outcome = resultsTmp[r].outcome;
            dst.payout = resultsTmp[r].payout;
            for (uint rc=0; rc<resultsTmp[r].cards.length; rc++) {
                dst.cards.push(resultsTmp[r].cards[rc]);
            }
        }

        t.lastHandResult.pot = collected;
        t.lastHandResult.timestamp = block.timestamp;

        // Move to Showdown (snapshot persisted), then clear table state for next hand
        t.phase = GamePhase.Showdown;
        emit PhaseChanged(tableId, GamePhase.Showdown);
        emit HandResultStored(tableId, block.timestamp);

        _resetHand(tableId);
    }

    // ========= Hand value helpers =========
    function _isBusted(Card[] memory cards) private pure returns (bool) { return _calculateHandValue(cards) > 21; }

    function _calculateHandValue(Card[] memory cards) private pure returns (uint) {
        (uint total,) = _handValueWithSoftFlag(cards);
        return total;
    }

    // returns (value, softFlag)
    function _handValueWithSoftFlag(Card[] memory cards) private pure returns (uint total, bool soft) {
        uint aces;
        for (uint i=0;i<cards.length;i++) {
            uint8 r = cards[i].rank;
            if (r == 14) { total += 1; aces++; }           // count aces as 1 first
            else if (r > 10) total += 10;
            else total += r;
        }
        if (aces > 0 && total + 10 <= 21) { total += 10; soft = true; } // one ace as 11
    }

    function _isBlackjack(Card[] memory cards) private pure returns (bool) {
        if (cards.length != 2) return false;
        uint total = _calculateHandValue(cards);
        if (total != 21) return false;
        bool hasAce; bool hasTenVal;
        for (uint i=0;i<2;i++) {
            if (cards[i].rank == 14) hasAce = true;
            if (cards[i].rank >= 10 && cards[i].rank <= 13) hasTenVal = true; // 10,J,Q,K
        }
        return hasAce && hasTenVal;
    }

    function _resetHand(uint tableId) internal {
        Table storage t = _getTable(tableId);
        // Keep lastHandResult for UI until next hand overwrites it
        for (uint i=0;i<t.players.length;i++) {
            delete t.players[i].cards;
            t.players[i].isActive = false;
            t.players[i].hasActed = false;
            t.players[i].bet = 0;
        }
        delete t.dealer.cards;
        t.dealer.hasFinished = false;

        t.phase = GamePhase.WaitingForPlayers;
        emit PhaseChanged(tableId, GamePhase.WaitingForPlayers);
        t.lastActivityTimestamp = block.timestamp;
    }

    // ========= Admin =========
    function pause() external onlyOwner { paused = true; }
    function unpause() external onlyOwner { paused = false; }
    function transferOwnership(address newOwner) external onlyOwner { require(newOwner != address(0), "Zero addr"); owner = newOwner; }
}
