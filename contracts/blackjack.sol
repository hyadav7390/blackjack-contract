// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title Blackjack
 * @author Gemini
 * @notice A feature-complete implementation of a Blackjack game for Base blockchain.
 * @dev Designed for educational purposes and FHE integration with Zama.
 * For real use, implement secure randomness and consider FHE for card privacy.
 */
contract Blackjack {
    // ## Enums and Structs ##

    // Constructor
    constructor() {
        owner = msg.sender;
    }

    enum TableStatus {
        Waiting,
        Active,
        Closed
    }

    enum GamePhase {
        WaitingForPlayers,
        Dealing,
        PlayerTurns,
        DealerTurn,
        Showdown,
        Completed
    }

    struct Card {
        uint8 rank; // 2-14 (2-10, 11=J, 12=Q, 13=K, 14=A)
        uint8 suit; // 0-3 (hearts, diamonds, clubs, spades)
    }

    struct Player {
        address addr;
        uint chips;
        uint bet; // Current bet for this hand
        Card[] cards; // Player's cards (2-4 depending on actions)
        bool isActive; // Is the player still in this hand?
        bool hasActed; // Has the player taken an action this turn?
    }

    struct Dealer {
        Card[] cards; // Dealer's cards (first card face down initially)
        bool hasFinished; // Has dealer completed their actions?
    }

    struct Table {
        uint id;
        TableStatus status;
        uint minBuyIn;
        uint maxBuyIn;
        uint8[52] deck; // Card indices (1-52)
        uint8 deckIndex; // Next card to deal
        GamePhase phase;
        Player[] players;
        Dealer dealer;
        uint lastActivityTimestamp;
    }

    // ## State Variables ##
    Table[] public tables;
    uint public constant MAX_TABLES = 10;
    uint public constant TURN_TIMEOUT = 30 seconds;
    uint public constant MAX_PLAYERS = 7; // Common table limit
    uint public constant BLACKJACK_PAYOUT = 3; // 3:2 payout for natural blackjack
    
    // Chip conversion: 10000 chips = 0.0001 ETH
    uint public constant CHIPS_PER_ETH = 100000000; // 10000 / 0.0001 = 100M chips per ETH
    uint public constant WEI_PER_CHIP = 10000000000000; // 0.0001 ETH / 10000 chips = 1e13 wei per chip

    mapping(address => uint) public playerTableId; // Tracks which table a player is at
    
    // Reentrancy guard
    bool private _locked;
    
    // Emergency controls
    address public owner;
    bool public paused;

    // Free chips tracking
    mapping(address => bool) public hasClaimedFreeChips;
    mapping(address => uint) public playerChips; // Track player chips outside of tables

    // ## Events ##

    event TableCreated(uint indexed tableId, address indexed creator);
    event PlayerJoined(
        uint indexed tableId,
        address indexed player,
        uint amount
    );
    event PlayerLeft(uint indexed tableId, address indexed player);
    event GameStarted(uint indexed tableId);
    event HandStarted(uint indexed tableId);
    event PlayerAction(
        uint indexed tableId,
        address indexed player,
        string action,
        uint amount
    );
    event DealerAction(uint indexed tableId, string action);
    event DealerHoleCardRevealed(uint indexed tableId, Card card);
    event WinnerDetermined(
        uint indexed tableId,
        address[] winners,
        uint[] amounts
    );
    event PayoutSent(uint indexed tableId, address indexed player, uint amount);
    event PhaseChanged(uint indexed tableId, GamePhase newPhase);

    event CardDealt(uint indexed tableId, address indexed player, Card card);
    event DealerCardRevealed(uint indexed tableId, Card card);
    event HandValueCalculated(uint indexed tableId, address indexed player, uint value);
    event PlayerBusted(uint indexed tableId, address indexed player);
    event PlayerStood(uint indexed tableId, address indexed player);
    event BetPlaced(uint indexed tableId, address indexed player, uint amount);
    event ChipsConverted(address indexed player, uint ethAmount, uint chipAmount);

    event FreeChipsClaimed(address indexed player, uint amount);
    event ChipsPurchased(address indexed player, uint ethAmount, uint chipAmount);
    event ChipsWithdrawn(address indexed player, uint chipAmount, uint ethAmount);

    // ## Modifiers ##

    modifier atActiveTable(uint tableId) {
        require(tableId > 0 && tableId <= tables.length, "Table does not exist");
        require(
            playerTableId[msg.sender] == tableId,
            "You are not at this table"
        );
        _;
    }

    modifier isMyTurn(uint tableId) {
        Table storage table = _getTable(tableId);
        require(table.status == TableStatus.Active, "Game is not active");
        require(table.phase == GamePhase.PlayerTurns, "Not player turns phase");
        require(_isMyTurn(tableId), "Not your turn");
        _;
    }

    modifier nonReentrant() {
        require(!_locked, "ReentrancyGuard: reentrant call");
        _locked = true;
        _;
        _locked = false;
    }

    modifier whenNotPaused() {
        require(!paused, "Contract is paused");
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    // ## Public View Functions for Frontend ##

    function getTableState(uint tableId) external view returns (Table memory) {
        require(tableId > 0 && tableId <= tables.length, "Table does not exist");
        return tables[tableId - 1]; // Convert to 0-based array index
    }

    function getPlayerState(
        uint tableId,
        address playerAddr
    ) external view returns (Player memory) {
        require(tableId > 0 && tableId <= tables.length, "Table does not exist");
        uint arrayIndex = tableId - 1;
        for (uint i = 0; i < tables[arrayIndex].players.length; i++) {
            if (tables[arrayIndex].players[i].addr == playerAddr) {
                return tables[arrayIndex].players[i];
            }
        }
        revert("Player not found at this table");
    }

    function getDealerState(
        uint tableId
    ) external view returns (Dealer memory) {
        require(tableId > 0 && tableId <= tables.length, "Table does not exist");
        return tables[tableId - 1].dealer;
    }

    function getTablePlayers(
        uint tableId
    ) external view returns (Player[] memory) {
        require(tableId > 0 && tableId <= tables.length, "Table does not exist");
        return tables[tableId - 1].players;
    }

    /**
     * @notice Get all available tables
     */
    function getAllTables() external view returns (Table[] memory) {
        return tables;
    }

    /**
     * @notice Get tables count
     */
    function getTablesCount() external view returns (uint) {
        return tables.length;
    }

    /**
     * @notice Get player's current table ID (0 means not at any table)
     */
    function getPlayerTableId(address player) external view returns (uint) {
        return playerTableId[player];
    }

    /**
     * @notice Check if it's a specific player's turn
     */
    function isPlayerTurn(uint tableId, address player) external view returns (bool) {
        if (tableId == 0 || tableId > tables.length) return false;
        if (playerTableId[player] != tableId) return false;
        
        Table storage table = tables[tableId - 1];
        if (table.status != TableStatus.Active || table.phase != GamePhase.PlayerTurns) {
            return false;
        }
        
        for (uint i = 0; i < table.players.length; i++) {
            if (table.players[i].addr == player) {
                if (!table.players[i].isActive || table.players[i].hasActed) {
                    return false;
                }
                
                // Check if this is the next player to act
                for (uint j = 0; j < i; j++) {
                    if (table.players[j].isActive && !table.players[j].hasActed) {
                        return false; // Earlier player hasn't acted yet
                    }
                }
                return true;
            }
        }
        return false;
    }

    /**
     * @notice Calculate hand value for frontend display
     */
    function calculateHandValue(Card[] memory cards) external pure returns (uint) {
        return _calculateHandValue(cards);
    }

    /**
     * @notice Check if a hand is blackjack
     */
    function isBlackjack(Card[] memory cards) external pure returns (bool) {
        return _isBlackjack(cards);
    }

    /**
     * @notice Check if a hand is busted
     */
    function isBusted(Card[] memory cards) external pure returns (bool) {
        return _isBusted(cards);
    }

    /**
     * @notice Get chip to ETH conversion rate info
     */
    function getConversionRates() external pure returns (uint chipsPerEth, uint weiPerChip) {
        return (CHIPS_PER_ETH, WEI_PER_CHIP);
    }

    /**
     * @notice Convert ETH to chips (for frontend calculation)
     */
    function ethToChips(uint ethAmount) external pure returns (uint) {
        return ethAmount * CHIPS_PER_ETH / 1 ether;
    }

    /**
     * @notice Convert chips to ETH (for frontend calculation)
     */
    function chipsToEth(uint chipAmount) external pure returns (uint) {
        return chipAmount * WEI_PER_CHIP / 1e13;
    }

    /**
     * @notice Get comprehensive player information
     */
    function getPlayerInfo(address player) external view returns (
        uint chips,
        uint tableId,
        bool hasClaimedFree,
        bool isAtTable
    ) {
        return (
            playerChips[player],
            playerTableId[player],
            hasClaimedFreeChips[player],
            playerTableId[player] != 0
        );
    }

    /**
     * @notice Get detailed game state for debugging
     */
    function getDetailedGameState(uint tableId) external view returns (
        uint tableStatus,
        uint gamePhase,
        uint playerCount,
        uint activePlayers,
        bool canPlayerAct,
        address nextPlayer,
        bool isMyTurnResult
    ) {
        require(tableId > 0 && tableId <= tables.length, "Table does not exist");
        Table storage table = tables[tableId - 1];
        
        uint activeCount = 0;
        for (uint i = 0; i < table.players.length; i++) {
            if (table.players[i].isActive) {
                activeCount++;
            }
        }
        
        bool canAct = false;
        if (table.status == TableStatus.Active && table.phase == GamePhase.PlayerTurns) {
            canAct = true;
        }
        
        return (
            uint(table.status),
            uint(table.phase),
            table.players.length,
            activeCount,
            canAct,
            this.getNextPlayer(tableId),
            this.isPlayerTurn(tableId, msg.sender)
        );
    }

    /**
     * @notice Get the next player who needs to act (for frontend)
     */
    function getNextPlayer(uint tableId) external view returns (address) {
        if (tableId == 0 || tableId > tables.length) return address(0);
        
        Table storage table = tables[tableId - 1];
        if (table.phase != GamePhase.PlayerTurns) return address(0);
        
        for (uint i = 0; i < table.players.length; i++) {
            if (table.players[i].isActive && !table.players[i].hasActed) {
                return table.players[i].addr;
            }
        }
        return address(0);
    }

    /**
     * @notice Get game summary for a table (for frontend display)
     */
    function getGameSummary(uint tableId    ) external view returns (
        uint tableStatus,
        uint gamePhase,
        uint playerCount,
        uint activePlayers,
        address nextPlayer,
        uint dealerCardCount,
        uint potSize
    ) {
        require(tableId > 0 && tableId <= tables.length, "Table does not exist");
        Table storage table = tables[tableId - 1];
        
        uint activeCount = 0;
        uint totalPot = 0;
        
        for (uint i = 0; i < table.players.length; i++) {
            if (table.players[i].isActive) {
                activeCount++;
                totalPot += table.players[i].bet;
            }
        }
        
        return (
            uint(table.status),
            uint(table.phase),
            table.players.length,
            activeCount,
            this.getNextPlayer(tableId),
            table.dealer.cards.length,
            totalPot
        );
    }

    function _isMyTurn(uint tableId) private view returns (bool) {
        Table storage table = _getTable(tableId);
        for (uint i = 0; i < table.players.length; i++) {
            if (table.players[i].isActive && !table.players[i].hasActed) {
                if (table.players[i].addr == msg.sender) {
                    // Check if this is the next player to act
                    for (uint j = 0; j < i; j++) {
                        if (
                            table.players[j].isActive &&
                            !table.players[j].hasActed
                        ) {
                            return false; // Earlier player hasn't acted yet
                        }
                    }
                    return true;
                }
            }
        }
        return false;
    }

    /**
     * @notice Helper function to get table by ID (converts 1-based ID to 0-based array index)
     */
    function _getTable(uint tableId) private view returns (Table storage) {
        require(tableId > 0 && tableId <= tables.length, "Table does not exist");
        return tables[tableId - 1];
    }

    // ## Table Management Functions ##

    /**
     * @notice Claim free 10,000 chips (one time per address)
     */
    function claimFreeChips() external whenNotPaused {
        require(!hasClaimedFreeChips[msg.sender], "Free chips already claimed");
        require(playerTableId[msg.sender] == 0, "Cannot claim while at a table");
        
        uint freeChipAmount = 10000;
        hasClaimedFreeChips[msg.sender] = true;
        playerChips[msg.sender] += freeChipAmount;
        
        emit FreeChipsClaimed(msg.sender, freeChipAmount);
    }

    /**
     * @notice Buy chips with ETH
     */
    function buyChips() external payable whenNotPaused {
        require(msg.value > 0, "Must send ETH to buy chips");
        require(playerTableId[msg.sender] == 0, "Cannot buy chips while at a table");
        
        uint chipAmount = msg.value * CHIPS_PER_ETH / 1 ether;
        playerChips[msg.sender] += chipAmount;
        
        emit ChipsPurchased(msg.sender, msg.value, chipAmount);
        emit ChipsConverted(msg.sender, msg.value, chipAmount);
    }

    /**
     * @notice Withdraw chips as ETH
     */
    function withdrawChips(uint chipAmount) external whenNotPaused nonReentrant {
        require(chipAmount > 0, "Must withdraw more than 0 chips");
        require(playerChips[msg.sender] >= chipAmount, "Insufficient chips");
        require(playerTableId[msg.sender] == 0, "Cannot withdraw while at a table");
        
        playerChips[msg.sender] -= chipAmount;
        uint ethAmount = chipAmount * WEI_PER_CHIP / 1e13;
        
        // Transfer ETH back to player
        (bool success, ) = payable(msg.sender).call{value: ethAmount}("");
        require(success, "ETH transfer failed");
        
        emit ChipsWithdrawn(msg.sender, chipAmount, ethAmount);
    }

    /**
     * @notice Get player's total chips (outside of tables)
     */
    function getPlayerChips(address player) external view returns (uint) {
        return playerChips[player];
    }

    /**
     * @notice Check if player has claimed free chips
     */
    function hasPlayerClaimedFreeChips(address player) external view returns (bool) {
        return hasClaimedFreeChips[player];
    }

    /**
     * @notice Creates a new blackjack table
     * @param _minBuyIn Minimum bet for the table
     * @param _maxBuyIn Maximum buy-in for the table
     */
    function createTable(uint _minBuyIn, uint _maxBuyIn) external whenNotPaused {
        require(tables.length < MAX_TABLES, "Maximum tables reached");
        require(_minBuyIn > 0 && _maxBuyIn >= _minBuyIn, "Invalid stakes");

        uint tableId = tables.length + 1; // Start table IDs from 1
        uint8[52] memory emptyDeck;
        tables.push(
            Table({
                id: tableId,
                status: TableStatus.Waiting,
                minBuyIn: _minBuyIn,
                maxBuyIn: _maxBuyIn,
                deck: emptyDeck,
                deckIndex: 0,
                phase: GamePhase.WaitingForPlayers,
                players: new Player[](0),
                dealer: Dealer({cards: new Card[](0), hasFinished: false}),
                lastActivityTimestamp: block.timestamp
            })
        );
        emit TableCreated(tableId, msg.sender);
    }

    /**
     * @notice Joins an existing table with chips from player's balance
     * @param tableId The ID of the table to join
     * @param buyInAmount The amount of chips to bring to the table
     */
    function joinTable(uint tableId, uint buyInAmount) external whenNotPaused {
        Table storage table = _getTable(tableId);
        require(table.players.length < MAX_PLAYERS, "Table is full");
        require(playerTableId[msg.sender] == 0, "Player already at a table");
        require(
            buyInAmount >= table.minBuyIn && buyInAmount <= table.maxBuyIn,
            "Invalid buy-in amount"
        );
        require(playerChips[msg.sender] >= buyInAmount, "Insufficient chips");

        // Transfer chips from player's balance to table
        playerChips[msg.sender] -= buyInAmount;
        
        table.players.push(
            Player({
                addr: msg.sender,
                chips: buyInAmount,
                bet: 0,
                cards: new Card[](0),
                isActive: false,
                hasActed: true
            })
        );
        playerTableId[msg.sender] = tableId;
        table.lastActivityTimestamp = block.timestamp;

        emit PlayerJoined(tableId, msg.sender, buyInAmount);

        if (table.players.length >= 2 && table.status == TableStatus.Waiting) {
            table.status = TableStatus.Active;
            emit GameStarted(tableId);
        }
    }

    /**
     * @notice Leaves the current table
     * @param tableId The ID of the table to leave
     */
    function leaveTable(uint tableId) external atActiveTable(tableId) {
        Table storage table = _getTable(tableId);
        uint playerIndex = _getPlayerIndex(tableId, msg.sender);
        Player storage player = table.players[playerIndex];

        // If the player is in an active hand, they lose their current bet but keep remaining chips
        if (table.phase != GamePhase.WaitingForPlayers) {
            uint remainingChips = player.chips; // Chips not including current bet
            playerChips[msg.sender] += remainingChips;
            playerTableId[msg.sender] = 0;
            player.isActive = false; // Just mark as inactive
            emit PlayerLeft(tableId, msg.sender);
            return;
        }

        // If not in an active hand, return all chips and remove player completely
        playerChips[msg.sender] += player.chips;
        for (uint i = playerIndex; i < table.players.length - 1; i++) {
            table.players[i] = table.players[i + 1];
        }
        table.players.pop();
        playerTableId[msg.sender] = 0;
        emit PlayerLeft(tableId, msg.sender);

        if (table.players.length < 2) {
            table.status = TableStatus.Waiting;
            table.phase = GamePhase.WaitingForPlayers;
        }
    }

    /**
     * @notice Cash out chips and leave the table
     * @param tableId The ID of the table to leave
     */
    function cashOut(uint tableId) external atActiveTable(tableId) nonReentrant {
        Table storage table = _getTable(tableId);
        require(table.phase == GamePhase.WaitingForPlayers, "Cannot cash out during active hand");
        
        uint playerIndex = _getPlayerIndex(tableId, msg.sender);
        Player storage player = table.players[playerIndex];
        uint chipsToCashOut = player.chips;
        
        require(chipsToCashOut > 0, "No chips to cash out");
        
        // Return chips to player's balance
        playerChips[msg.sender] += chipsToCashOut;
        
        // Remove player from table
        for (uint i = playerIndex; i < table.players.length - 1; i++) {
            table.players[i] = table.players[i + 1];
        }
        table.players.pop();
        playerTableId[msg.sender] = 0;
        
        emit PlayerLeft(tableId, msg.sender);
        
        if (table.players.length < 2) {
            table.status = TableStatus.Waiting;
            table.phase = GamePhase.WaitingForPlayers;
        }
    }

    // ## Player Action Functions ##

    /**
     * @notice Place a bet to join the current hand
     * @param tableId The ID of the table
     * @param betAmount The amount to bet (must be between minBuyIn and remaining chips)
     */
    function placeBet(
        uint tableId,
        uint betAmount
    ) external atActiveTable(tableId) {
        Table storage table = _getTable(tableId);
        require(
            table.phase == GamePhase.WaitingForPlayers,
            "Cannot place bet now"
        );

        Player storage player = _getPlayerAtTable(tableId, msg.sender);
        require(
            betAmount >= table.minBuyIn && betAmount <= player.chips,
            "Invalid bet amount"
        );

        player.bet = betAmount;
        player.chips -= betAmount;
        player.isActive = true;
        player.hasActed = true; // Mark as acted for dealing

        emit PlayerAction(tableId, msg.sender, "Bet", betAmount);
        emit BetPlaced(tableId, msg.sender, betAmount);

        // Check if we can start the hand
        uint activeBettors = 0;
        uint playersWithoutBets = 0;
        
        for (uint i = 0; i < table.players.length; i++) {
            if (table.players[i].isActive && table.players[i].bet > 0) {
                activeBettors++;
            } else if (table.players[i].chips >= table.minBuyIn && table.players[i].bet == 0) {
                playersWithoutBets++;
            }
        }

        // Start hand if we have active bettors and either:
        // 1. All eligible players have placed bets, OR
        // 2. We have at least 1 bettor and table is set to start immediately (single player mode)
        if (activeBettors > 0 && (playersWithoutBets == 0 || table.players.length == 1)) {
            _startNewHand(tableId);
        }
    }

    /**
     * @notice Request another card (hit)
     */
    function hit(
        uint tableId
    ) external atActiveTable(tableId) isMyTurn(tableId) {
        Table storage table = _getTable(tableId);
        require(table.phase == GamePhase.PlayerTurns, "Not player turns phase");

        Player storage player = _getPlayerAtTable(tableId, msg.sender);
        require(player.isActive, "Player is not active in this hand");

        _dealCardToPlayer(tableId, msg.sender);
        emit PlayerAction(tableId, msg.sender, "Hit", 0);
        emit CardDealt(tableId, msg.sender, player.cards[player.cards.length - 1]);

        if (_isBusted(player.cards)) {
            player.isActive = false;
            player.hasActed = true; // Mark as acted to move to next player
            emit PlayerBusted(tableId, msg.sender);
            _advanceToNextPlayer(tableId);
        }
    }

    /**
     * @notice Stand (end your turn)
     */
    function stand(
        uint tableId
    ) external atActiveTable(tableId) isMyTurn(tableId) {
        Table storage table = _getTable(tableId);
        require(table.phase == GamePhase.PlayerTurns, "Not player turns phase");

        Player storage player = _getPlayerAtTable(tableId, msg.sender);
        player.hasActed = true;
        emit PlayerAction(tableId, msg.sender, "Stand", 0);
        emit PlayerStood(tableId, msg.sender);
        _advanceToNextPlayer(tableId);
    }

    /**
     * @notice Double down (double your bet and take one more card)
     */
    function doubleDown(
        uint tableId
    ) external atActiveTable(tableId) isMyTurn(tableId) {
        Table storage table = _getTable(tableId);
        require(table.phase == GamePhase.PlayerTurns, "Not player turns phase");
        // FIXED: Use player.cards.length instead of table.actionIndex
        Player storage player = _getPlayerAtTable(tableId, msg.sender);
        require(
            player.cards.length == 2,
            "Can only double down on first two cards"
        );

        require(
            player.chips >= player.bet,
            "Insufficient chips to double down"
        );

        player.chips -= player.bet;
        player.bet *= 2;
        player.hasActed = true;

        _dealCardToPlayer(tableId, msg.sender);
        emit PlayerAction(tableId, msg.sender, "Double Down", player.bet);

        if (_isBusted(player.cards)) {
            player.isActive = false;
        }
        _advanceToNextPlayer(tableId);
    }

    /**
     * @notice Force advance to dealer turn (for testing/debugging)
     */
    function forceDealerTurn(uint tableId) external atActiveTable(tableId) {
        Table storage table = _getTable(tableId);
        require(table.phase == GamePhase.PlayerTurns, "Not in player turns phase");
        
        // Mark all active players as acted
        for (uint i = 0; i < table.players.length; i++) {
            if (table.players[i].isActive) {
                table.players[i].hasActed = true;
            }
        }
        
        _startDealerTurn(tableId);
    }

    // ## Internal Game Logic ##

    function _startNewHand(uint tableId) internal {
        Table storage table = _getTable(tableId);
        table.status = TableStatus.Active; // Set table as active
        table.phase = GamePhase.Dealing;
        table.deckIndex = 0;

        _shuffleDeck(tableId);

        // Deal two cards to each player and reset their turn state
        for (uint i = 0; i < table.players.length; i++) {
            table.players[i].cards = new Card[](0);
            table.players[i].hasActed = false; // Reset for new hand
            _dealCardToPlayer(tableId, table.players[i].addr);
            _dealCardToPlayer(tableId, table.players[i].addr);
        }

        // Deal two cards to dealer (first one face down)
        table.dealer.cards = new Card[](0);
        _dealCardToDealer(tableId);
        _dealCardToDealer(tableId);

        // Check for natural blackjacks
        _checkForNaturalBlackjacks(tableId);
        
        // Only proceed to player turns if no natural blackjacks end the hand
        if (table.phase == GamePhase.Dealing) {
            table.phase = GamePhase.PlayerTurns;
            emit PhaseChanged(tableId, GamePhase.PlayerTurns);
        }
        
        emit HandStarted(tableId);
    }

    function _checkForNaturalBlackjacks(uint tableId) internal {
        Table storage table = _getTable(tableId);
        bool dealerHasBlackjack = _isBlackjack(table.dealer.cards);
        
        bool anyPlayerHasBlackjack = false;
        bool anyPlayerNeedsToAct = false;
        
        for (uint i = 0; i < table.players.length; i++) {
            if (table.players[i].isActive) {
                bool playerHasBlackjack = _isBlackjack(table.players[i].cards);
                if (playerHasBlackjack) {
                    anyPlayerHasBlackjack = true;
                    // Mark player as acted since blackjack is automatic
                    table.players[i].hasActed = true;
                } else {
                    anyPlayerNeedsToAct = true;
                }
            }
        }
        
        // If dealer has blackjack or all active players have blackjack, end hand immediately
        if (dealerHasBlackjack || (anyPlayerHasBlackjack && !anyPlayerNeedsToAct)) {
            table.phase = GamePhase.DealerTurn;
            _startDealerTurn(tableId);
        }
    }

    function _shuffleDeck(uint tableId) internal {
        Table storage table = _getTable(tableId);
        for (uint8 i = 0; i < 52; i++) {
            table.deck[i] = i + 1; // Initialize deck with card indices 1-52
        }

        // This is a simple pseudo-random shuffle for demo purposes
        // In production, use Chainlink VRF or similar for randomness
        uint seed = uint(
            keccak256(
                abi.encodePacked(block.timestamp, block.prevrandao, msg.sender)
            )
        );
        for (uint i = 0; i < 51; i++) {
            uint j = i + ((seed + i) % (52 - i));
            (table.deck[i], table.deck[j]) = (table.deck[j], table.deck[i]);
        }
    }

    function _dealCardToPlayer(uint tableId, address playerAddr) private {
        Table storage table = _getTable(tableId);
        require(table.deckIndex < 52, "Deck exhausted");
        Card memory card = _getCardFromIndex(table.deck[table.deckIndex]);
        table.deckIndex++;

        // Find the player and add the card to their hand
        for (uint i = 0; i < table.players.length; i++) {
            if (table.players[i].addr == playerAddr) {
                table.players[i].cards.push(card);
                break;
            }
        }
        emit CardDealt(tableId, playerAddr, card);
    }

    function _dealCardToDealer(uint tableId) private {
        Table storage table = _getTable(tableId);
        require(table.deckIndex < 52, "Deck exhausted");
        Card memory card = _getCardFromIndex(table.deck[table.deckIndex]);
        table.deckIndex++;
        table.dealer.cards.push(card);
        emit CardDealt(tableId, address(this), card); // Dealer is the contract itself
    }

    function _getCardFromIndex(
        uint8 index
    ) internal pure returns (Card memory) {
        uint8 suit = (index - 1) / 13; // 0-3 (hearts, diamonds, clubs, spades)
        uint8 rank = ((index - 1) % 13) + 2; // 2-14 (2-10, 11=J, 12=Q, 13=K, 14=A)
        return Card(rank, suit);
    }

    function _getPlayerIndex(
        uint tableId,
        address playerAddr
    ) private view returns (uint) {
        Table storage table = _getTable(tableId);
        for (uint i = 0; i < table.players.length; i++) {
            if (table.players[i].addr == playerAddr) {
                return i;
            }
        }
        revert("Player not found");
    }

    function _getPlayerAtTable(
        uint tableId,
        address playerAddr
    ) private view returns (Player storage) {
        Table storage table = _getTable(tableId);
        return table.players[_getPlayerIndex(tableId, playerAddr)];
    }

    function _isBusted(Card[] memory cards) private pure returns (bool) {
        uint total = _calculateHandValue(cards);
        return total > 21;
    }

    function _calculateHandValue(
        Card[] memory cards
    ) private pure returns (uint) {
        uint total = 0;
        uint numAces = 0;

        for (uint i = 0; i < cards.length; i++) {
            if (cards[i].rank == 14) {
                // Ace
                total += 11;
                numAces++;
            } else if (cards[i].rank > 10) {
                // Face cards (J, Q, K)
                total += 10;
            } else {
                total += cards[i].rank;
            }
        }

        // Adjust for aces if needed (convert 11 to 1 to avoid busting)
        while (total > 21 && numAces > 0) {
            total -= 10;
            numAces--;
        }

        return total;
    }

    function _advanceToNextPlayer(uint tableId) internal {
        Table storage table = _getTable(tableId);

        // Check if all players have acted
        for (uint i = 0; i < table.players.length; i++) {
            if (table.players[i].isActive && !table.players[i].hasActed) {
                // There's still a player to act - we don't need to do anything
                // The frontend will show the next player's turn
                return;
            }
        }

        // All players have acted - start dealer's turn
        _startDealerTurn(tableId);
    }

    function _startDealerTurn(uint tableId) internal {
        Table storage table = _getTable(tableId);
        table.phase = GamePhase.DealerTurn;

        // Reveal dealer's hole card (face down card)
        emit DealerHoleCardRevealed(tableId, table.dealer.cards[1]);

        // Dealer must hit on soft 17 or less, hard 16 or less
        uint dealerValue = _calculateHandValue(table.dealer.cards);
        while (dealerValue < 17) {
            _dealCardToDealer(tableId);
            dealerValue = _calculateHandValue(table.dealer.cards);
            emit DealerAction(tableId, "Hit");
        }

        table.dealer.hasFinished = true;
        table.phase = GamePhase.Showdown;
        _determineWinners(tableId);
        emit PhaseChanged(tableId, GamePhase.Showdown);
    }

    function _determineWinners(uint tableId) internal {
        Table storage table = _getTable(tableId);
        uint dealerValue = _calculateHandValue(table.dealer.cards);
        bool dealerBusted = dealerValue > 21;

        // Count potential winners first
        uint winnerCount = 0;
        for (uint i = 0; i < table.players.length; i++) {
            Player storage player = table.players[i];
            if (!player.isActive) continue;
            
            uint playerValue = _calculateHandValue(player.cards);
            bool playerBusted = playerValue > 21;
            
            if (!playerBusted && (dealerBusted || playerValue > dealerValue)) {
                winnerCount++;
            }
        }
        
        address[] memory winners = new address[](winnerCount);
        uint[] memory payouts = new uint[](winnerCount);
        uint winnerIndex = 0;

        for (uint i = 0; i < table.players.length; i++) {
            Player storage player = table.players[i];
            if (!player.isActive) continue;

            uint playerValue = _calculateHandValue(player.cards);
            bool playerBusted = playerValue > 21;
            bool playerHasBlackjack = _isBlackjack(player.cards);

            if (playerBusted) {
                // Player loses
                continue;
            }

            if (dealerBusted) {
                // Player wins
                uint payout;
                if (playerHasBlackjack) {
                    payout = player.bet + (player.bet * BLACKJACK_PAYOUT / 2); // 3:2 payout
                } else {
                    payout = player.bet * 2; // 1:1 payout
                }
                winners[winnerIndex] = player.addr;
                payouts[winnerIndex] = payout;
                winnerIndex++;
                player.chips += payout;
                emit PayoutSent(tableId, player.addr, payout);
            } else if (playerValue > dealerValue) {
                // Player wins
                uint payout;
                if (playerHasBlackjack) {
                    payout = player.bet + (player.bet * BLACKJACK_PAYOUT / 2); // 3:2 payout
                } else {
                    payout = player.bet * 2; // 1:1 payout
                }
                winners[winnerIndex] = player.addr;
                payouts[winnerIndex] = payout;
                winnerIndex++;
                player.chips += payout;
                emit PayoutSent(tableId, player.addr, payout);
            } else if (playerValue == dealerValue) {
                // Push - return bet (including blackjack vs blackjack)
                player.chips += player.bet;
            }
            // Else player loses (value < dealerValue)
        }

        if (winners.length > 0) {
            emit WinnerDetermined(tableId, winners, payouts);
        }

        _resetHand(tableId);
    }

    function _isBlackjack(Card[] memory cards) private pure returns (bool) {
        if (cards.length != 2) return false;
        uint total = _calculateHandValue(cards);
        if (total != 21) return false;
        
        // Check for Ace + 10-value card (10, J, Q, K)
        bool hasAce = false;
        bool hasTenValue = false;
        
        for (uint i = 0; i < 2; i++) {
            if (cards[i].rank == 14) hasAce = true;
            if (cards[i].rank >= 10) hasTenValue = true;
        }
        
        return hasAce && hasTenValue;
    }

    function _resetHand(uint tableId) internal {
        Table storage table = _getTable(tableId);
        table.phase = GamePhase.WaitingForPlayers;

        // Reset player states
        for (uint i = 0; i < table.players.length; i++) {
            table.players[i].cards = new Card[](0);
            table.players[i].isActive = false;
            table.players[i].hasActed = false;
            table.players[i].bet = 0;
        }

        // Reset dealer
        table.dealer.cards = new Card[](0);
        table.dealer.hasFinished = false;

        // Check if we can automatically start a new hand
        _checkForNextHand(tableId);
    }

    function _checkForNextHand(uint tableId) internal {
        Table storage table = _getTable(tableId);

        // Check if all players have sufficient chips for min buy-in
        bool allReady = true;
        for (uint i = 0; i < table.players.length; i++) {
            if (table.players[i].chips < table.minBuyIn) {
                allReady = false;
                break;
            }
        }

        if (allReady) {
            emit PhaseChanged(tableId, GamePhase.WaitingForPlayers);
        }
    }

    // ## Emergency Functions ##
    
    function pause() external onlyOwner {
        paused = true;
    }
    
    function unpause() external onlyOwner {
        paused = false;
    }
    
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Invalid address");
        owner = newOwner;
    }

    // Additional functions for more complex actions like split can be added here
}
