// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title TexasHoldem
 * @author Gemini
 * @notice A feature-complete implementation of a Texas Hold'em poker game.
 * @dev WARNING: This contract is for educational purposes only and is NOT SECURE for real money.
 * It suffers from two major vulnerabilities:
 * 1. Public Card Information: All card data is stored on-chain and is publicly readable.
 * This means a malicious actor can read the deck and players' cards.
 * 2. Insecure Randomness: The card shuffling mechanism is predictable and exploitable.
 * A determined attacker can manipulate the outcome of the shuffle.
 *
 * This contract is designed to be deployed on Base or other EVM-compatible chains.
 */
contract TexasHoldem {
    // ## Enums and Structs ##

    enum TableStatus {
        Waiting,
        Active,
        Closed
    }
    enum GamePhase {
        PreDeal,
        PreFlop,
        Flop,
        Turn,
        River,
        Showdown
    }

    struct Player {
        address addr;
        uint chips;
        uint bet; // Total bet in the current hand
        uint8[2] holeCards;
        bool inHand;
        bool hasActed;
        uint lastActionTimestamp;
    }

    struct Pot {
        uint size;
        address[] eligiblePlayers;
    }

    struct Table {
        uint id;
        TableStatus status;
        uint minBuyIn;
        uint maxBuyIn;
        uint smallBlind;
        uint bigBlind;
        uint8 dealerIndex;
        uint8 actionIndex; // The index of the player whose turn it is
        Player[] players;
        uint8[52] deck;
        uint8 deckIndex;
        uint8[5] communityCards;
        GamePhase phase;
        uint currentBet; // The highest bet amount players must call
        uint minRaise;
        Pot[] pots;
        uint lastActivityTimestamp;
    }

    // Hand ranking types. A higher number means a better hand.
    enum HandType {
        HighCard,
        Pair,
        TwoPair,
        ThreeOfAKind,
        Straight,
        Flush,
        FullHouse,
        FourOfAKind,
        StraightFlush,
        RoyalFlush
    }

    struct HandEvaluation {
        HandType handType;
        uint[] rankCards;
    }

    // ## State Variables ##

    Table[] public tables;
    uint public constant MAX_TABLES = 10;
    uint public constant TURN_TIMEOUT = 60 seconds;
    uint public constant MAX_PLAYERS = 9;

    mapping(address => uint) public playerTableId; // Tracks which table a player is at

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
    event PhaseChanged(uint indexed tableId, GamePhase newPhase);
    event CommunityCardsDealt(uint indexed tableId, uint8[5] communityCards);
    event WinnerDetermined(
        uint indexed tableId,
        address[] winners,
        uint amount
    );

    // ## Modifiers ##

    modifier atActiveTable(uint tableId) {
        require(tableId < tables.length, "Table does not exist");
        require(
            playerTableId[msg.sender] == tableId,
            "You are not at this table"
        );
        _;
    }

    modifier isMyTurn(uint tableId) {
        Table storage table = tables[tableId];
        require(table.status == TableStatus.Active, "Game is not active");
        require(
            table.players.length > table.actionIndex &&
                table.players[table.actionIndex].addr == msg.sender,
            "Not your turn"
        );
        _;
    }

    // ## Public View Functions for Frontend ##

    /**
     * @notice Retrieves the full state of a specific table.
     * @param tableId The ID of the table.
     * @return A tuple containing all table state variables.
     */
    function getTableState(uint tableId) external view returns (Table memory) {
        require(tableId < tables.length, "Table does not exist");
        return tables[tableId];
    }

    /**
     * @notice Retrieves a player's state at a specific table.
     * @param tableId The ID of the table.
     * @param playerAddr The address of the player.
     * @return A tuple containing all player state variables.
     */
    function getPlayerState(
        uint tableId,
        address playerAddr
    ) external view returns (Player memory) {
        require(tableId < tables.length, "Table does not exist");
        for (uint i = 0; i < tables[tableId].players.length; i++) {
            if (tables[tableId].players[i].addr == playerAddr) {
                return tables[tableId].players[i];
            }
        }
        revert("Player not found at this table");
    }

    // ## Table Management Functions ##

    /**
     * @notice Creates a new poker table.
     * @param _minBuyIn The minimum chips required to join.
     * @param _maxBuyIn The maximum chips a player can have at the table.
     * @param _smallBlind The small blind amount.
     * @param _bigBlind The big blind amount.
     */
    function createTable(
        uint _minBuyIn,
        uint _maxBuyIn,
        uint _smallBlind,
        uint _bigBlind
    ) external {
        require(tables.length < MAX_TABLES, "Maximum tables reached");
        require(
            _minBuyIn > 0 && _smallBlind > 0 && _bigBlind > _smallBlind,
            "Invalid stakes"
        );
        require(_maxBuyIn >= _minBuyIn, "Invalid buy-in range");

        uint tableId = tables.length;
        uint8[52] memory emptyDeck; // Initialize an empty deck
        tables.push(
            Table({
                id: tableId,
                status: TableStatus.Waiting,
                minBuyIn: _minBuyIn,
                maxBuyIn: _maxBuyIn,
                smallBlind: _smallBlind,
                bigBlind: _bigBlind,
                dealerIndex: 0,
                actionIndex: 0,
                players: new Player[](0),
                deck: emptyDeck,
                deckIndex: 0,
                communityCards: [uint8(0), 0, 0, 0, 0],
                phase: GamePhase.PreDeal,
                currentBet: 0,
                minRaise: _bigBlind,
                pots: new Pot[](0),
                lastActivityTimestamp: block.timestamp
            })
        );
        emit TableCreated(tableId, msg.sender);
    }

    /**
     * @notice Joins an existing table with a specified buy-in amount.
     * @param tableId The ID of the table to join.
     * @param buyInAmount The amount of chips to bring to the table.
     */
    function joinTable(uint tableId, uint buyInAmount) external {
        require(tableId < tables.length, "Table does not exist");
        Table storage table = tables[tableId];
        require(table.players.length < MAX_PLAYERS, "Table is full");
        require(playerTableId[msg.sender] == 0, "Player already at a table");
        require(
            buyInAmount >= table.minBuyIn && buyInAmount <= table.maxBuyIn,
            "Invalid buy-in amount"
        );

        table.players.push(
            Player({
                addr: msg.sender,
                chips: buyInAmount,
                bet: 0,
                holeCards: [0, 0],
                inHand: false,
                hasActed: true,
                lastActionTimestamp: block.timestamp
            })
        );
        playerTableId[msg.sender] = tableId;
        table.lastActivityTimestamp = block.timestamp;

        emit PlayerJoined(tableId, msg.sender, buyInAmount);

        if (table.players.length >= 2 && table.status == TableStatus.Waiting) {
            table.status = TableStatus.Active;
            _startNewHand(tableId);
            emit GameStarted(tableId);
        }
    }

    /**
     * @notice Leaves a poker table.
     * @param tableId The ID of the table to leave.
     */
    function leaveTable(uint tableId) external atActiveTable(tableId) {
        Table storage table = tables[tableId];
        uint playerIndex = 0;
        for (uint i = 0; i < table.players.length; i++) {
            if (table.players[i].addr == msg.sender) {
                playerIndex = i;
                break;
            }
        }

        // Remove player from the array
        for (uint i = playerIndex; i < table.players.length - 1; i++) {
            table.players[i] = table.players[i + 1];
        }
        table.players.pop();

        playerTableId[msg.sender] = 0;
        emit PlayerLeft(tableId, msg.sender);

        if (table.players.length < 2) {
            table.status = TableStatus.Waiting;
            table.phase = GamePhase.PreDeal;
        }
    }

    // ## Player Action Functions ##

    function fold(
        uint tableId
    ) external atActiveTable(tableId) isMyTurn(tableId) {
        Table storage table = tables[tableId];
        table.players[table.actionIndex].inHand = false;

        emit PlayerAction(tableId, msg.sender, "Fold", 0);
        _advanceAction(tableId);
    }

    function check(
        uint tableId
    ) external atActiveTable(tableId) isMyTurn(tableId) {
        Table storage table = tables[tableId];
        Player storage player = table.players[table.actionIndex];
        require(
            player.bet == table.currentBet,
            "Cannot check, must call or raise"
        );

        emit PlayerAction(tableId, msg.sender, "Check", 0);
        _advanceAction(tableId);
    }

    function call(
        uint tableId
    ) external atActiveTable(tableId) isMyTurn(tableId) {
        Table storage table = tables[tableId];
        Player storage player = table.players[table.actionIndex];
        uint callAmount = table.currentBet - player.bet;
        require(callAmount > 0, "Nothing to call");
        require(player.chips >= callAmount, "Insufficient chips to call");

        player.chips -= callAmount;
        player.bet += callAmount;

        emit PlayerAction(tableId, msg.sender, "Call", callAmount);

        _advanceAction(tableId);
    }

    function raise(
        uint tableId,
        uint raiseAmount
    ) external atActiveTable(tableId) isMyTurn(tableId) {
        Table storage table = tables[tableId];
        Player storage player = table.players[table.actionIndex];

        uint callAmount = table.currentBet - player.bet;
        uint totalBet = callAmount + raiseAmount;

        require(player.chips >= totalBet, "Insufficient chips to raise");
        require(raiseAmount >= table.minRaise, "Raise amount too small");

        player.chips -= totalBet;
        player.bet += totalBet;

        table.currentBet = player.bet;
        table.minRaise = raiseAmount;

        emit PlayerAction(tableId, msg.sender, "Raise", raiseAmount);

        for (uint i = 0; i < table.players.length; i++) {
            if (table.players[i].inHand) {
                table.players[i].hasActed = false;
            }
        }
        player.hasActed = true;

        _advanceAction(tableId);
    }

    function allIn(
        uint tableId
    ) external atActiveTable(tableId) isMyTurn(tableId) {
        Table storage table = tables[tableId];
        Player storage player = table.players[table.actionIndex];

        uint totalBet = player.chips;

        player.chips = 0;
        player.bet += totalBet;

        if (player.bet > table.currentBet) {
            table.currentBet = player.bet;
            table.minRaise = totalBet - (table.currentBet - player.bet); // A bit complex, but captures raise logic
        }

        emit PlayerAction(tableId, msg.sender, "All-in", totalBet);

        for (uint i = 0; i < table.players.length; i++) {
            if (table.players[i].inHand) {
                table.players[i].hasActed = false;
            }
        }
        player.hasActed = true;

        _advanceAction(tableId);
    }

    // ## Internal Game Logic Functions ##

    function _startNewHand(uint tableId) internal {
        Table storage table = tables[tableId];

        for (uint i = 0; i < table.players.length; i++) {
            if (table.players[i].chips > 0) {
                table.players[i].inHand = true;
                table.players[i].hasActed = false;
                table.players[i].bet = 0;
                table.players[i].holeCards = [0, 0];
            } else {
                table.players[i].inHand = false;
            }
        }

        // Clean up pots from previous hand
        delete table.pots;

        table.dealerIndex = uint8(
            (table.dealerIndex + 1) % table.players.length
        );

        _shuffleDeck(tableId);
        _postBlinds(tableId);
        _dealHoleCards(tableId);

        table.phase = GamePhase.PreFlop;
        emit HandStarted(tableId);
        emit PhaseChanged(tableId, GamePhase.PreFlop);
    }

    function _shuffleDeck(uint tableId) internal {
        // WARNING: INSECURE PSEUDO-RANDOMNESS. FOR DEMONSTRATION ONLY.
        Table storage table = tables[tableId];
        for (uint8 i = 0; i < 52; i++) {
            table.deck[i] = i + 1; // 1-52 represents cards
        }

        uint seed = uint(
            keccak256(
                abi.encodePacked(
                    block.timestamp,
                    block.prevrandao, // <-- REPLACED block.difficulty
                    msg.sender
                )
            )
        );
        for (uint i = 0; i < 52; i++) {
            uint j = (seed + i) % (52 - i);
            (table.deck[i], table.deck[j]) = (table.deck[j], table.deck[i]);
        }
        table.deckIndex = 0;
    }

    function _postBlinds(uint tableId) internal {
        Table storage table = tables[tableId];

        // Small Blind
        uint8 smallBlindIndex = uint8(
            (table.dealerIndex + 1) % table.players.length
        );
        table.players[smallBlindIndex].bet = table.smallBlind;
        table.players[smallBlindIndex].chips -= table.smallBlind;
        table.players[smallBlindIndex].hasActed = false; // They must act again if there's a raise

        // Big Blind
        uint8 bigBlindIndex = uint8(
            (smallBlindIndex + 1) % table.players.length
        );
        table.players[bigBlindIndex].bet = table.bigBlind;
        table.players[bigBlindIndex].chips -= table.bigBlind;
        table.players[bigBlindIndex].hasActed = false;

        table.currentBet = table.bigBlind;
        table.actionIndex = uint8((bigBlindIndex + 1) % table.players.length);
    }

    function _dealHoleCards(uint tableId) internal {
        Table storage table = tables[tableId];
        for (uint i = 0; i < table.players.length; i++) {
            if (table.players[i].inHand) {
                table.players[i].holeCards[0] = table.deck[table.deckIndex++];
                table.players[i].holeCards[1] = table.deck[table.deckIndex++];
            }
        }
    }

    function _dealCommunityCards(uint tableId) internal {
        Table storage table = tables[tableId];
        if (table.phase == GamePhase.Flop) {
            table.communityCards[0] = table.deck[table.deckIndex++];
            table.communityCards[1] = table.deck[table.deckIndex++];
            table.communityCards[2] = table.deck[table.deckIndex++];
        } else if (table.phase == GamePhase.Turn) {
            table.communityCards[3] = table.deck[table.deckIndex++];
        } else if (table.phase == GamePhase.River) {
            table.communityCards[4] = table.deck[table.deckIndex++];
        }
        emit CommunityCardsDealt(tableId, table.communityCards);
    }

    function _advanceAction(uint tableId) internal {
        Table storage table = tables[tableId];
        table.players[table.actionIndex].hasActed = true;
        table.players[table.actionIndex].lastActionTimestamp = block.timestamp;

        if (_isBettingRoundOver(tableId)) {
            _endBettingRound(tableId);
        } else {
            uint8 nextIndex = table.actionIndex;
            do {
                nextIndex = (nextIndex + 1) % uint8(table.players.length);
            } while (
                !table.players[nextIndex].inHand ||
                    table.players[nextIndex].hasActed
            );
            table.actionIndex = nextIndex;
        }
    }

    function _isBettingRoundOver(uint tableId) internal view returns (bool) {
        Table storage table = tables[tableId];
        for (uint i = 0; i < table.players.length; i++) {
            if (table.players[i].inHand && !table.players[i].hasActed) {
                return false;
            }
            if (
                table.players[i].inHand &&
                table.players[i].bet < table.currentBet &&
                table.players[i].chips > 0
            ) {
                return false;
            }
        }
        return true;
    }

    function _endBettingRound(uint tableId) internal {
        _managePots(tableId);

        Table storage table = tables[tableId];

        for (uint i = 0; i < table.players.length; i++) {
            table.players[i].bet = 0;
            table.players[i].hasActed = false;
        }
        table.currentBet = 0;
        table.minRaise = table.bigBlind;

        if (table.phase == GamePhase.PreFlop) {
            table.phase = GamePhase.Flop;
            _dealCommunityCards(tableId);
        } else if (table.phase == GamePhase.Flop) {
            table.phase = GamePhase.Turn;
            _dealCommunityCards(tableId);
        } else if (table.phase == GamePhase.Turn) {
            table.phase = GamePhase.River;
            _dealCommunityCards(tableId);
        } else if (table.phase == GamePhase.River) {
            table.phase = GamePhase.Showdown;
            _determineWinner(tableId);
        }

        emit PhaseChanged(tableId, table.phase);
    }

    function _managePots(uint tableId) internal {
        // Simplified pot logic: all chips go into a single main pot.
        // This does NOT handle side pots for all-in players.
        Table storage table = tables[tableId];

        uint totalPot = 0;
        for (uint i = 0; i < table.players.length; i++) {
            totalPot += table.players[i].bet;
        }

        table.pots.push(
            Pot({size: totalPot, eligiblePlayers: new address[](0)})
        );

        for (uint i = 0; i < table.players.length; i++) {
            if (table.players[i].inHand) {
                table.pots[0].eligiblePlayers.push(table.players[i].addr);
            }
        }
    }

    function _determineWinner(uint tableId) internal {
        Table storage table = tables[tableId];
        address[] memory winningPlayers = new address[](MAX_PLAYERS); // Preallocate
        uint winningCount = 0;
        HandEvaluation memory winningHand;

        for (uint i = 0; i < table.players.length; i++) {
            if (table.players[i].inHand) {
                uint8[] memory allCards = new uint8[](7);
                allCards[0] = table.players[i].holeCards[0];
                allCards[1] = table.players[i].holeCards[1];
                for (uint j = 0; j < 5; j++) {
                    allCards[j + 2] = table.communityCards[j];
                }

                HandEvaluation memory currentHand = _evaluateBestHand(allCards);

                if (winningCount == 0) {
                    winningPlayers[winningCount] = table.players[i].addr;
                    winningCount++;
                    winningHand = currentHand;
                } else {
                    int comparison = _compareHands(currentHand, winningHand);
                    if (comparison > 0) {
                        winningCount = 0; // Reset
                        winningPlayers[winningCount] = table.players[i].addr;
                        winningCount++;
                        winningHand = currentHand;
                    } else if (comparison == 0) {
                        winningPlayers[winningCount] = table.players[i].addr;
                        winningCount++;
                    }
                }
            }
        }

        // Trim unused slots (optional, but cleaner)
        address[] memory finalWinners = new address[](winningCount);
        for (uint i = 0; i < winningCount; i++) {
            finalWinners[i] = winningPlayers[i];
        }

        uint potSize = table.pots[0].size;
        uint winningShare = potSize / winningCount;

        for (uint i = 0; i < winningCount; i++) {
            for (uint j = 0; j < table.players.length; j++) {
                if (table.players[j].addr == finalWinners[i]) {
                    table.players[j].chips += winningShare;
                    break;
                }
            }
        }

        emit WinnerDetermined(tableId, finalWinners, winningShare);
        _startNewHand(tableId);
    }

    // ## Hand Evaluation Helper Functions (Gas-Intensive, for demonstration) ##

    function _evaluateBestHand(
        uint8[] memory cards
    ) internal pure returns (HandEvaluation memory) {
        uint[] memory ranks = new uint[](cards.length);
        uint[] memory suits = new uint[](cards.length);
        for (uint i = 0; i < cards.length; i++) {
            ranks[i] = (cards[i] - 1) % 13;
            suits[i] = (cards[i] - 1) / 13;
        }

        HandEvaluation memory bestHand;

        // Find all 5-card combinations
        for (uint i = 0; i < 7; i++) {
            for (uint j = i + 1; j < 7; j++) {
                for (uint k = j + 1; k < 7; k++) {
                    for (uint l = k + 1; l < 7; l++) {
                        for (uint m = l + 1; m < 7; m++) {
                            uint8[] memory combo = new uint8[](5);
                            combo[0] = cards[i];
                            combo[1] = cards[j];
                            combo[2] = cards[k];
                            combo[3] = cards[l];
                            combo[4] = cards[m];
                            HandEvaluation
                                memory currentHand = _evaluate5CardHand(combo);
                            if (_compareHands(currentHand, bestHand) > 0) {
                                bestHand = currentHand;
                            }
                        }
                    }
                }
            }
        }
        return bestHand;
    }

    function _evaluate5CardHand(
        uint8[] memory cards
    ) internal pure returns (HandEvaluation memory) {
        // Sort cards for easier evaluation
        for (uint i = 0; i < 4; i++) {
            for (uint j = i + 1; j < 5; j++) {
                if (cards[i] > cards[j]) {
                    (cards[i], cards[j]) = (cards[j], cards[i]);
                }
            }
        }

        uint[] memory ranks = new uint[](5);
        uint[] memory suits = new uint[](5);
        for (uint i = 0; i < 5; i++) {
            ranks[i] = (cards[i] - 1) % 13;
            suits[i] = (cards[i] - 1) / 13;
        }

        uint[] memory rankCounts = new uint[](13);
        for (uint i = 0; i < 5; i++) {
            rankCounts[ranks[i]]++;
        }

        bool isFlush = (suits[0] == suits[1] &&
            suits[1] == suits[2] &&
            suits[2] == suits[3] &&
            suits[3] == suits[4]);
        bool isStraight = (ranks[0] + 1 == ranks[1] &&
            ranks[1] + 1 == ranks[2] &&
            ranks[2] + 1 == ranks[3] &&
            ranks[3] + 1 == ranks[4]);

        if (isStraight && isFlush) {
            if (ranks[4] == 12) {
                // Ace high
                return HandEvaluation(HandType.RoyalFlush, _sortedRanks(ranks));
            }
            return HandEvaluation(HandType.StraightFlush, _sortedRanks(ranks));
        }

        uint numPairs = 0;
        uint numTrips = 0;
        uint numQuads = 0;
        uint[] memory pairRanks;
        uint[] memory tripRanks;
        uint[] memory quadRanks;

        for (uint i = 0; i < 13; i++) {
            if (rankCounts[i] == 2) numPairs++;
            if (rankCounts[i] == 3) numTrips++;
            if (rankCounts[i] == 4) numQuads++;
        }

        if (numQuads == 1)
            return HandEvaluation(HandType.FourOfAKind, _sortedRanks(ranks));
        if (numTrips == 1 && numPairs == 1)
            return HandEvaluation(HandType.FullHouse, _sortedRanks(ranks));
        if (isFlush) return HandEvaluation(HandType.Flush, _sortedRanks(ranks));
        if (isStraight)
            return HandEvaluation(HandType.Straight, _sortedRanks(ranks));
        if (numTrips == 1)
            return HandEvaluation(HandType.ThreeOfAKind, _sortedRanks(ranks));
        if (numPairs == 2)
            return HandEvaluation(HandType.TwoPair, _sortedRanks(ranks));
        if (numPairs == 1)
            return HandEvaluation(HandType.Pair, _sortedRanks(ranks));

        return HandEvaluation(HandType.HighCard, _sortedRanks(ranks));
    }

    function _sortedRanks(
        uint[] memory ranks
    ) internal pure returns (uint[] memory sorted) {
        for (uint i = 0; i < ranks.length; i++) {
            for (uint j = i + 1; j < ranks.length; j++) {
                if (ranks[i] < ranks[j]) {
                    (ranks[i], ranks[j]) = (ranks[j], ranks[i]);
                }
            }
        }
        return ranks;
    }

    function _compareHands(
        HandEvaluation memory hand1,
        HandEvaluation memory hand2
    ) internal pure returns (int) {
        if (uint(hand1.handType) > uint(hand2.handType)) return 1;
        if (uint(hand1.handType) < uint(hand2.handType)) return -1;

        for (uint i = 0; i < hand1.rankCards.length; i++) {
            if (hand1.rankCards[i] > hand2.rankCards[i]) return 1;
            if (hand1.rankCards[i] < hand2.rankCards[i]) return -1;
        }

        return 0; // Tie
    }
}
