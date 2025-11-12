// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "./ReputationToken.sol";
import "../governance/ReputationLockManager.sol";
/**
 * @title GovernancePredictionMarket
 * @notice Production-ready prediction market with reputation-weighted governance
 * @dev Optimized for stack depth and gas efficiency
 */
contract GovernancePredictionMarket is
    ReentrancyGuard,
    AccessControl,
    Pausable
{
    using Math for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;
    ReputationLockManager public immutable lockManager;
    // ============ TYPE DECLARATIONS ============
    struct TakePositionParams {
        uint256 marketId;
        uint8 outcome;
        uint256 stakeAmount;
        uint256 reputationPercentage;
        address user;
    }

    struct Market {
        uint256 id;
        string question;
        string detailedDescription;
        bytes32 proposalHash;
        uint256 createdAt;
        uint256 tradingEndTime;
        uint256 resolutionTime;
        uint256 totalStake;
        uint256 totalReputationStake;
        uint8 outcomeCount;
        bool resolved;
        uint8 winningOutcome;
        uint256 resolutionBlockNumber;
        MarketCategory category;
        uint256 liquidityParameter;
        uint256 maxLiquidityParameter;
        address priceAsset; // Asset address for price-based markets (address(0) if not price-based)
        bytes32 chainlinkPriceId; // Unique identifier for price recording (bytes32(0) if not price-based)
    }

    struct Outcome {
        string description;
        uint256 totalStake;
        uint256 totalReputationStake;
        uint256 impliedProbability;
    }

    struct Position {
        uint256 stake;
        uint256 reputationStake;
        uint256 entryTimestamp;
        uint256 entryPrice;
        bool claimed;
    }

    struct UserPosition {
        uint8[] outcomes;
        uint256 totalStake;
        uint256 totalReputationStake;
    }

    struct UserStats {
        uint256 totalPredictions;
        uint256 correctPredictions;
        uint256 totalStaked;
        uint256 totalReturned;
        uint256 lastPredictionTime;
        uint256 consecutiveCorrect;
        uint256 maxConsecutiveCorrect;
    }

    struct LegislatorInfo {
        uint256 accuracyScore;
        uint256 predictionCount;
        uint256 promotionTime;
        uint256 lastActivityTime;
    }

    enum MarketCategory {
        PROTOCOL_UPGRADE,
        TREASURY_ALLOCATION,
        PARAMETER_CHANGE,
        STRATEGIC_DECISION,
        EMERGENCY_ACTION
    }

    enum ResolutionState {
        TRADING,
        SETTLEMENT,
        RESOLUTION_PROPOSED,
        LEGISLATOR_VOTING,
        DISPUTE_PERIOD,
        FINALIZATION_COOLDOWN,
        RESOLVED
    }

    // ============ CONSTANTS ============

    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
    bytes32 public constant RESOLVER_ROLE = keccak256("RESOLVER_ROLE");
    bytes32 public constant MARKET_CREATOR_ROLE =
        keccak256("MARKET_CREATOR_ROLE");
    bytes32 public constant LEGISLATOR_ROLE = keccak256("LEGISLATOR_ROLE");

    uint256 public constant MIN_MARKET_DURATION = 3 days;
    uint256 public constant MAX_MARKET_DURATION = 90 days;
    uint256 public constant FEE_PERCENTAGE = 200; // 2%
    uint256 public constant LOSS_INSURANCE_PERCENTAGE = 50; // 0.5% of stake returned on loss
    uint256 public constant MIN_REPUTATION_STAKE_RATIO = 100; // 1%
    uint256 public constant MAX_POSITION_SIZE = 1000; // 10%
    uint256 public constant MIN_LIQUIDITY = 1000 * 10 ** 18;
    uint256 public constant MAX_OUTCOMES = 10;
    uint256 public constant PRECISION = 10 ** 18;
    uint256 public constant SETTLEMENT_PERIOD = 6 hours;
    uint256 public constant FINALIZATION_COOLDOWN = 24 hours;
    uint256 public constant MAX_USER_POSITION_BASE = 100; // 1%
    uint256 public constant MAX_USER_POSITION_HIGH_REP = 500; // 5%
    uint256 public constant MIN_PAYOUT_RATIO = 9500; // 95%
    uint256 public constant MAX_REPUTATION_MULTIPLIER = 100;
    uint256 public constant MAX_TIMING_BONUS = 5000; // 50%
    uint256 public constant MEV_PROTECTION_DELAY = 2; // Increased to 2 blocks for better protection
    uint256 public constant MAX_PRICE_IMPACT = 1000; // 10% max price impact
    uint256 public constant LEGISLATOR_MIN_ACCURACY = 7500; // 75%
    uint256 public constant LEGISLATOR_MIN_PREDICTIONS = 10;
    uint256 public constant LEGISLATOR_MIN_CONSECUTIVE = 5;
    uint256 public constant LEGISLATOR_INACTIVITY_PERIOD = 90 days;
    uint256 public constant LEGISLATOR_DECAY_PENALTY = 1000; // 10%

    // ============ STATE VARIABLES ============

    IERC20 public immutable stakingToken;
    ReputationToken public immutable reputationToken;

    uint256 public marketCount;
    uint256 public totalFeesCollected;
    address public feeRecipient;

    // Core storage mappings
    mapping(uint256 => Market) public markets;
    mapping(uint256 => mapping(uint8 => Outcome)) public outcomes;
    mapping(uint256 => mapping(address => mapping(uint8 => Position)))
        public positions;
    mapping(uint256 => mapping(address => UserPosition)) public userPositions;
    mapping(uint256 => ResolutionState) public marketResolutionState;

    // User tracking
    mapping(address => uint256) public userInvestmentTotal;
    mapping(address => uint256) public userReputationLocked;
    mapping(address => UserStats) public userStats;
    mapping(address => uint256[]) public userMarkets;
    mapping(uint256 => mapping(address => uint256)) public userMarketStake;

    // Security and MEV protection
    mapping(uint256 => uint256) public totalMarketStakeSnapshot;

    // Legislator tracking with EnumerableSet for efficient enumeration
    EnumerableSet.AddressSet private legislators;
    mapping(address => LegislatorInfo) public legislatorInfo;

    // Category configuration
    mapping(MarketCategory => uint256) public categoryMinDuration;
    mapping(MarketCategory => uint256) public categoryMaxDuration;

    // State transitions
    mapping(ResolutionState => ResolutionState[]) private validTransitions;
    // State variables for genesis block protection
    mapping(uint256 => mapping(address => uint256)) public userInitialStake; // Tracks per-user initial stake per market
    mapping(uint256 => uint256) public marketCreationBlock; // Tracks the block number when each market was created
    uint256 public constant INITIAL_LIQUIDITY_PHASE = 100; // blocks
    uint256 public constant MAX_USER_INITIAL_PERCENTAGE = 2000; // 20%
    // State transition timing
    mapping(uint256 => mapping(ResolutionState => uint256))
        public stateTransitionTime;

    // ============ MEV PROTECTION (FIXED) ============

    // TIER 1: Per-user rate limiting (timestamp-based, NOT block-based)
    mapping(uint256 => mapping(address => uint256)) public userLastTradeTime;
    uint256 public constant MIN_TRADE_INTERVAL = 1 minutes;

    // TIER 2: Global volume limits per block
    mapping(uint256 => uint256) public marketBlockVolume;
    mapping(uint256 => uint256) public marketBlockVolumeBlock; // Track which block
    uint256 public constant MAX_BLOCK_VOLUME_RATIO = 2000; // 20% of market per block

    // TIER 3: Dynamic fee calculation (moved to separate function)
    mapping(uint256 => uint256) public lastPriceUpdateTime; // For TWAP oracle
    // ============ EVENTS ============

    event MarketCreated(
        uint256 indexed marketId,
        string question,
        uint256 tradingEndTime,
        uint8 outcomeCount,
        MarketCategory category,
        uint256 liquidityParameter
    );

    event PositionTaken(
        uint256 indexed marketId,
        address indexed user,
        uint8 outcome,
        uint256 stake,
        uint256 reputationStake,
        uint256 newImpliedProbability
    );

    event MarketResolved(
        uint256 indexed marketId,
        uint8 winningOutcome,
        uint256 totalPayout
    );

    event RewardsClaimed(
        uint256 indexed marketId,
        address indexed user,
        uint256 payout,
        uint256 reputationReward
    );

    event FeeRecipientUpdated(
        address indexed oldRecipient,
        address indexed newRecipient
    );
    event UserInitialized(address indexed user, uint256 initialReputation);
    event LegislatorPromoted(address indexed user, uint256 accuracy);
    event LegislatorDemoted(address indexed user, string reason);
    event StateTransition(
        uint256 indexed marketId,
        ResolutionState oldState,
        ResolutionState newState
    );

    // ============ MODIFIERS ============

    modifier marketExists(uint256 marketId) {
        require(marketId < marketCount, "Market does not exist");
        _;
    }

    modifier marketActive(uint256 marketId) {
        Market storage market = markets[marketId];
        require(block.timestamp < market.tradingEndTime, "Trading ended");
        require(!market.resolved, "Market resolved");
        _;
    }

    /**
     * @notice Multi-tier MEV protection with industry-standard approach
     * @dev Tier 1: User rate limiting, Tier 2: Global volume caps, Tier 3: Dynamic fees
     */
    modifier mevProtection(uint256 marketId, uint256 stakeAmount) {
        // TIER 1: Per-user cooldown (1 minute minimum between trades)
        require(
            block.timestamp >=
                userLastTradeTime[marketId][msg.sender] + MIN_TRADE_INTERVAL,
            "MEV: trade cooldown active"
        );

        // TIER 2: Global block volume limit (prevents flash loan attacks)
        // Reset counter if new block
        if (block.number != marketBlockVolumeBlock[marketId]) {
            marketBlockVolume[marketId] = 0;
            marketBlockVolumeBlock[marketId] = block.number;
        }

        //  CRITICAL FIX: Calculate max volume with proper base
        Market storage market = markets[marketId];
        uint256 maxBlockVolume;

        if (market.totalStake > 0) {
            // Use the LARGER of: 10% of market OR MIN_LIQUIDITY
            uint256 marketBasedLimit = (market.totalStake *
                MAX_BLOCK_VOLUME_RATIO) / 10000;
            uint256 minimumLimit = (MIN_LIQUIDITY * MAX_BLOCK_VOLUME_RATIO) /
                10000;
            maxBlockVolume = Math.max(marketBasedLimit, minimumLimit);
        } else {
            // For new markets, use MIN_LIQUIDITY as base
            maxBlockVolume = (MIN_LIQUIDITY * MAX_BLOCK_VOLUME_RATIO) / 10000;
        }

        // Check if adding this trade would exceed block volume
        require(
            marketBlockVolume[marketId] + stakeAmount <= maxBlockVolume,
            "MEV: block volume limit exceeded"
        );

        _;

        // Update tracking AFTER successful execution
        userLastTradeTime[marketId][msg.sender] = block.timestamp;
        marketBlockVolume[marketId] += stakeAmount;
        lastPriceUpdateTime[marketId] = block.timestamp;
    }

    // ============ CONSTRUCTOR ============

    constructor(
        address _stakingToken,
        address _reputationToken,
        address _feeRecipient,
        address _lockManager
    ) {
        require(_stakingToken != address(0), "Invalid staking token");
        require(_reputationToken != address(0), "Invalid reputation token");
        require(_feeRecipient != address(0), "Invalid fee recipient");
        require(_lockManager != address(0), "Invalid lock manager");

        stakingToken = IERC20(_stakingToken);
        reputationToken = ReputationToken(_reputationToken);
        feeRecipient = _feeRecipient;
        lockManager = ReputationLockManager(_lockManager);

        _initializeCategoryDurations();
        _initializeStateTransitions();
        _setupInitialRoles();
    }

    // ============ INITIALIZATION FUNCTIONS ============

    function _initializeCategoryDurations() private {
        categoryMinDuration[MarketCategory.EMERGENCY_ACTION] = 1 days;
        categoryMinDuration[MarketCategory.PARAMETER_CHANGE] = 3 days;
        categoryMinDuration[MarketCategory.PROTOCOL_UPGRADE] = 7 days;
        categoryMinDuration[MarketCategory.TREASURY_ALLOCATION] = 7 days;
        categoryMinDuration[MarketCategory.STRATEGIC_DECISION] = 14 days;

        categoryMaxDuration[MarketCategory.EMERGENCY_ACTION] = 3 days;
        categoryMaxDuration[MarketCategory.PARAMETER_CHANGE] = 30 days;
        categoryMaxDuration[MarketCategory.PROTOCOL_UPGRADE] = 90 days;
        categoryMaxDuration[MarketCategory.TREASURY_ALLOCATION] = 60 days;
        categoryMaxDuration[MarketCategory.STRATEGIC_DECISION] = 90 days;
    }

    function _initializeStateTransitions() private {
        validTransitions[ResolutionState.TRADING].push(
            ResolutionState.SETTLEMENT
        );
        validTransitions[ResolutionState.SETTLEMENT].push(
            ResolutionState.RESOLUTION_PROPOSED
        );

        ResolutionState[] storage proposedTransitions = validTransitions[
            ResolutionState.RESOLUTION_PROPOSED
        ];
        proposedTransitions.push(ResolutionState.LEGISLATOR_VOTING);
        proposedTransitions.push(ResolutionState.DISPUTE_PERIOD);

        ResolutionState[] storage votingTransitions = validTransitions[
            ResolutionState.LEGISLATOR_VOTING
        ];
        votingTransitions.push(ResolutionState.DISPUTE_PERIOD);
        votingTransitions.push(ResolutionState.FINALIZATION_COOLDOWN);

        ResolutionState[] storage disputeTransitions = validTransitions[
            ResolutionState.DISPUTE_PERIOD
        ];
        disputeTransitions.push(ResolutionState.FINALIZATION_COOLDOWN);
        disputeTransitions.push(ResolutionState.RESOLUTION_PROPOSED);

        validTransitions[ResolutionState.FINALIZATION_COOLDOWN].push(
            ResolutionState.RESOLVED
        );
    }

    function _setupInitialRoles() private {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MARKET_CREATOR_ROLE, msg.sender);
        _grantRole(RESOLVER_ROLE, msg.sender);
        _grantRole(ORACLE_ROLE, msg.sender);
    }

    // ============ USER INITIALIZATION ============

    function initializeUser(address user) external {
        require(user != address(0), "Invalid address");
        require(
            reputationToken.balanceOf(user) == 0,
            "User already initialized"
        );

        reputationToken.grantInitialReputation(user);
        emit UserInitialized(user, reputationToken.balanceOf(user));
    }

    function _autoInitializeUser(address user) internal {
        if (reputationToken.balanceOf(user) == 0) {
            reputationToken.grantInitialReputation(user);
            emit UserInitialized(user, reputationToken.balanceOf(user));
        }
    }

    // ============ MARKET CREATION ============

    function createMarket(
        string calldata question,
        string calldata detailedDescription,
        bytes32 proposalHash,
        uint256 tradingEndTime,
        string[] calldata outcomeDescriptions,
        MarketCategory category,
        uint256 initialLiquidity
    ) external whenNotPaused returns (uint256) {
        require(
            userStats[msg.sender].lastPredictionTime + 1 hours <
                block.timestamp,
            "Market creation cooldown"
        );
        _validateMarketCreation(
            question,
            outcomeDescriptions,
            tradingEndTime,
            category,
            initialLiquidity
        );

        uint256 marketId = marketCount++;

        _initializeMarket(
            marketId,
            question,
            detailedDescription,
            proposalHash,
            tradingEndTime,
            outcomeDescriptions,
            category,
            initialLiquidity
        );

        emit MarketCreated(
            marketId,
            question,
            tradingEndTime,
            uint8(outcomeDescriptions.length),
            category,
            initialLiquidity
        );

        return marketId;
    }

    function _validateMarketCreation(
        string calldata question,
        string[] calldata outcomeDescriptions,
        uint256 tradingEndTime,
        MarketCategory category,
        uint256 initialLiquidity
    ) private view {
        require(
            bytes(question).length > 0 && bytes(question).length <= 256,
            "Invalid question length"
        );
        require(
            outcomeDescriptions.length >= 2 &&
                outcomeDescriptions.length <= MAX_OUTCOMES,
            "Invalid outcome count"
        );

        uint256 minDuration = categoryMinDuration[category];
        uint256 maxDuration = categoryMaxDuration[category];

        require(
            tradingEndTime >= block.timestamp + minDuration,
            "Trading period too short"
        );
        require(
            tradingEndTime <= block.timestamp + maxDuration,
            "Trading period too long"
        );
        require(
            initialLiquidity >= MIN_LIQUIDITY,
            "Insufficient initial liquidity"
        );
    }
    /**
     * @notice Initialize market WITHOUT asset tracking (backwards compatible)
     * @dev Used by the old createMarket function (without Chainlink parameters)
     */
    function _initializeMarket(
        uint256 marketId,
        string calldata question,
        string calldata detailedDescription,
        bytes32 proposalHash,
        uint256 tradingEndTime,
        string[] calldata outcomeDescriptions,
        MarketCategory category,
        uint256 initialLiquidity
    ) private {
        markets[marketId] = Market({
            id: marketId,
            question: question,
            detailedDescription: detailedDescription,
            proposalHash: proposalHash,
            createdAt: block.timestamp,
            tradingEndTime: tradingEndTime,
            resolutionTime: tradingEndTime + 7 days,
            totalStake: 0,
            totalReputationStake: 0,
            outcomeCount: uint8(outcomeDescriptions.length),
            resolved: false,
            winningOutcome: 0,
            resolutionBlockNumber: 0,
            category: category,
            liquidityParameter: initialLiquidity,
            maxLiquidityParameter: initialLiquidity * 100,
            priceAsset: address(0), // ✅ FIX: Add default value for non-price markets
            chainlinkPriceId: bytes32(0) // ✅ FIX: Add default value for non-price markets
        });

        // Track market creation block
        marketCreationBlock[marketId] = block.number;

        uint256 equalProbability = 10000 / outcomeDescriptions.length;

        // Initialize with zero stake - let the market discover prices naturally
        for (uint8 i = 0; i < outcomeDescriptions.length; i++) {
            outcomes[marketId][i] = Outcome({
                description: outcomeDescriptions[i],
                totalStake: 0,
                totalReputationStake: 0,
                impliedProbability: equalProbability
            });
        }

        markets[marketId].totalStake = 0;
        marketResolutionState[marketId] = ResolutionState.TRADING;
    }
    /**
     * @notice Create market WITH Chainlink price tracking (new version)
     * @dev Overloaded function for price-based markets
     * @param question Market question
     * @param detailedDescription Detailed market description
     * @param proposalHash Hash of associated proposal
     * @param tradingEndTime Timestamp when trading ends
     * @param outcomeDescriptions Array of outcome descriptions
     * @param category Market category
     * @param initialLiquidity Initial liquidity parameter
     * @param priceAsset Asset address for Chainlink (address(0) for non-price markets)
     * @param chainlinkPriceId Unique price recording ID (bytes32(0) for non-price markets)
     * @return marketId The created market ID
     */
    function createMarket(
        string calldata question,
        string calldata detailedDescription,
        bytes32 proposalHash,
        uint256 tradingEndTime,
        string[] calldata outcomeDescriptions,
        MarketCategory category,
        uint256 initialLiquidity,
        address priceAsset,
        bytes32 chainlinkPriceId
    ) external whenNotPaused returns (uint256) {
        require(
            userStats[msg.sender].lastPredictionTime + 1 hours <
                block.timestamp,
            "Market creation cooldown"
        );

        _validateMarketCreation(
            question,
            outcomeDescriptions,
            tradingEndTime,
            category,
            initialLiquidity
        );

        uint256 marketId = marketCount++;

        _initializeMarketWithAsset(
            marketId,
            question,
            detailedDescription,
            proposalHash,
            tradingEndTime,
            outcomeDescriptions,
            category,
            initialLiquidity,
            priceAsset,
            chainlinkPriceId
        );

        emit MarketCreated(
            marketId,
            question,
            tradingEndTime,
            uint8(outcomeDescriptions.length),
            category,
            initialLiquidity
        );

        return marketId;
    }
    /**
     * @notice Initialize market with asset tracking (internal helper)
     * @dev Used by the new overloaded createMarket function
     */
    function _initializeMarketWithAsset(
        uint256 marketId,
        string calldata question,
        string calldata detailedDescription,
        bytes32 proposalHash,
        uint256 tradingEndTime,
        string[] calldata outcomeDescriptions,
        MarketCategory category,
        uint256 initialLiquidity,
        address priceAsset,
        bytes32 chainlinkPriceId
    ) private {
        markets[marketId] = Market({
            id: marketId,
            question: question,
            detailedDescription: detailedDescription,
            proposalHash: proposalHash,
            createdAt: block.timestamp,
            tradingEndTime: tradingEndTime,
            resolutionTime: tradingEndTime + 7 days,
            totalStake: 0,
            totalReputationStake: 0,
            outcomeCount: uint8(outcomeDescriptions.length),
            resolved: false,
            winningOutcome: 0,
            resolutionBlockNumber: 0,
            category: category,
            liquidityParameter: initialLiquidity,
            maxLiquidityParameter: initialLiquidity * 100,
            priceAsset: priceAsset, // ✅ Store asset
            chainlinkPriceId: chainlinkPriceId // ✅ Store price ID
        });

        // Track market creation block
        marketCreationBlock[marketId] = block.number;

        uint256 equalProbability = 10000 / outcomeDescriptions.length;

        // Initialize outcomes
        for (uint8 i = 0; i < outcomeDescriptions.length; i++) {
            outcomes[marketId][i] = Outcome({
                description: outcomeDescriptions[i],
                totalStake: 0,
                totalReputationStake: 0,
                impliedProbability: equalProbability
            });
        }

        markets[marketId].totalStake = 0;
        marketResolutionState[marketId] = ResolutionState.TRADING;
    }
    // ============ POSITION TAKING ============

    function takePosition(
        uint256 marketId,
        uint8 outcome,
        uint256 stakeAmount,
        uint256 reputationPercentage
    )
        external
        nonReentrant
        whenNotPaused
        marketExists(marketId)
        marketActive(marketId)
        mevProtection(marketId, stakeAmount) //  FIXED: Now passes stakeAmount
    {
        _validatePosition(marketId, outcome, stakeAmount, reputationPercentage);
        _autoInitializeUser(msg.sender);

        TakePositionParams memory params = TakePositionParams({
            marketId: marketId,
            outcome: outcome,
            stakeAmount: stakeAmount,
            reputationPercentage: reputationPercentage,
            user: msg.sender
        });

        //  Calculate price impact BEFORE trade
        uint256 initialPrice = outcomes[marketId][outcome].impliedProbability;

        _executePosition(params);

        //  Calculate actual price impact AFTER trade
        uint256 finalPrice = outcomes[marketId][outcome].impliedProbability;
        uint256 priceImpact = _calculatePriceImpact(initialPrice, finalPrice);

        //  Enforce max impact
        require(priceImpact <= MAX_PRICE_IMPACT, "Price impact too high");

        //  Store dynamic fee for this trade (used during claim)
        // NOTE: We don't take dynamic fee on entry, only on exit (claim)
        // This is fairer and prevents griefing
    }

    /**
     * @notice Calculate dynamic fee based on price impact (Tier 3 MEV protection)
     * @dev Higher impact = higher fees (protocol captures MEV profit)
     */
    function calculateDynamicFee(
        uint256 marketId,
        uint256 priceImpact
    ) public pure returns (uint256) {
        uint256 baseFee = FEE_PERCENTAGE; // 200 = 2%

        // Quadratic fee increase: fee = baseFee * (1 + impact²)
        // Examples:
        // - 0% impact → 2% fee
        // - 5% impact → 2.05% fee
        // - 10% impact → 3% fee
        // - 20% impact → 6% fee
        uint256 impactSquared = (priceImpact * priceImpact) / 10000;
        uint256 additionalFee = (baseFee * impactSquared) / 10000;
        uint256 totalFee = baseFee + additionalFee;

        // Cap at 10% maximum fee
        return Math.min(totalFee, 1000);
    }
    function _validatePosition(
        uint256 marketId,
        uint8 outcome,
        uint256 stakeAmount,
        uint256 reputationPercentage
    ) private view {
        Market storage market = markets[marketId];
        require(outcome < market.outcomeCount, "Invalid outcome");
        require(stakeAmount > 0, "Invalid stake amount");
        require(
            reputationPercentage >= MIN_REPUTATION_STAKE_RATIO &&
                reputationPercentage <= 10000,
            "Invalid reputation percentage"
        );
    }

    function _executePosition(TakePositionParams memory params) private {
        Market storage market = markets[params.marketId];

        // Calculate position limits
        PositionLimits memory limits = _calculatePositionLimits(params);

        // Validate position limits
        _validatePositionLimits(params, limits);

        // Execute transfers and updates
        _transferStake(params);
        _updatePositionState(params, limits);
        _updateMarketState(params);
        _updateUserTracking(params);

        // Update probabilities
        _updateImpliedProbabilities(params.marketId);

        emit PositionTaken(
            params.marketId,
            params.user,
            params.outcome,
            params.stakeAmount,
            limits.reputationStake,
            outcomes[params.marketId][params.outcome].impliedProbability
        );
    }

    struct PositionLimits {
        uint256 newOutcomeStake;
        uint256 newTotalStake;
        uint256 currentUserStake;
        uint256 newUserStake;
        uint256 userLimit;
        uint256 investmentLimit;
        uint256 userReputation;
        uint256 reputationStake;
    }

    function _calculatePositionLimits(
        TakePositionParams memory params
    ) private view returns (PositionLimits memory) {
        Market storage market = markets[params.marketId];

        uint256 currentSnapshot = totalMarketStakeSnapshot[params.marketId];
        if (currentSnapshot == 0) {
            currentSnapshot = market.totalStake;
        }

        PositionLimits memory limits;
        limits.newOutcomeStake =
            outcomes[params.marketId][params.outcome].totalStake +
            params.stakeAmount;
        limits.newTotalStake = market.totalStake + params.stakeAmount;
        limits.currentUserStake = userMarketStake[params.marketId][params.user];
        limits.newUserStake = limits.currentUserStake + params.stakeAmount;
        limits.userLimit = calculateUserPositionLimit(
            params.user,
            Math.max(currentSnapshot, limits.newTotalStake)
        );
        limits.investmentLimit = calculateInvestmentLimit(params.user);
        limits.userReputation = reputationToken.balanceOf(params.user);
        limits.reputationStake = Math.mulDiv(
            limits.userReputation,
            params.reputationPercentage,
            10000
        );

        return limits;
    }

    /**
     * @notice Validate position limits with FIXED genesis protection
     * @dev  CRITICAL FIXES:
     *      - Reputation-based limits in genesis (prevents Sybil)
     *      - Gradual phase transitions (no cliff)
     *      - Initial seeding bypass (allows admin to seed)
     */
    function _validatePositionLimits(
        TakePositionParams memory params,
        PositionLimits memory limits
    ) private {
        uint256 blocksSinceCreation = block.number -
            marketCreationBlock[params.marketId];
        Market storage market = markets[params.marketId];

        //  FIX: Define "initial seeding" as < 10% of MIN_LIQUIDITY
        bool isInitialSeeding = market.totalStake < (MIN_LIQUIDITY / 10);

        // PHASE 1: Genesis Phase (0-100 blocks) - Reputation-based limits
        if (
            blocksSinceCreation < INITIAL_LIQUIDITY_PHASE && !isInitialSeeding
        ) {
            uint256 userReputation = reputationToken.balanceOf(params.user);

            //  FIX: Require minimum reputation to participate in genesis
            require(
                userReputation >= 1000 * 10 ** 18,
                "Insufficient reputation for genesis phase"
            );

            //  FIX: Reputation-scaled limits (higher rep = higher limit)
            // Example: 1000 REP → 1x, 10000 REP → 10x, 100000 REP → 100x (capped at 10x)
            uint256 reputationFactor = Math.min(
                userReputation / (1000 * 10 ** 18),
                10 // Cap at 10x multiplier
            );

            // Base limit: 20% of MIN_LIQUIDITY, scaled by reputation
            uint256 maxUserGenesis = (((MIN_LIQUIDITY *
                MAX_USER_INITIAL_PERCENTAGE) / 10000) * reputationFactor) / 10;

            uint256 userTotal = userInitialStake[params.marketId][params.user] +
                params.stakeAmount;

            require(
                userTotal <= maxUserGenesis,
                "Exceeds reputation-based genesis limit"
            );

            userInitialStake[params.marketId][params.user] = userTotal;
        }
        // PHASE 2: Early Growth Phase (100-500 blocks) - Gradual expansion
        else if (blocksSinceCreation < 500 && !isInitialSeeding) {
            //  FIX: Gradual increase from 30% to 50% based on block progress
            uint256 blockProgress = blocksSinceCreation -
                INITIAL_LIQUIDITY_PHASE;
            uint256 phaseLength = 400; // 500 - 100

            // Linear interpolation: 30% → 50%
            uint256 percentageLimit = 3000 +
                ((blockProgress * 2000) / phaseLength);

            uint256 maxUserEarly = Math.max(
                (MIN_LIQUIDITY * percentageLimit) / 10000,
                (market.totalStake * percentageLimit) / 10000
            );

            uint256 userTotal = userMarketStake[params.marketId][params.user] +
                params.stakeAmount;

            require(userTotal <= maxUserEarly, "Exceeds early phase limit");
        }
        // PHASE 3: Standard Market Phase (500+ blocks)
        else if (!isInitialSeeding) {
            uint256 newUserStake = userMarketStake[params.marketId][
                params.user
            ] + params.stakeAmount;

            require(
                newUserStake <= limits.userLimit,
                "Exceeds user position limit"
            );

            //  FIX: Absolute maximum (20% of market, regardless of reputation)
            uint256 absoluteMaxPosition = (market.totalStake * 2000) / 10000;
            require(
                newUserStake <= absoluteMaxPosition,
                "Exceeds absolute max position"
            );
        }

        //  UNIVERSAL CHECKS (apply in all phases except initial seeding)
        if (!isInitialSeeding) {
            //  FIX: Only check concentration if market has meaningful liquidity
            if (limits.newTotalStake >= MIN_LIQUIDITY / 10) {
                uint256 newOutcomeConcentration = (limits.newOutcomeStake *
                    10000) / limits.newTotalStake;

                require(
                    newOutcomeConcentration <= 8000,
                    "Outcome concentration too high"
                );
            }

            // Investment limit check
            require(
                userInvestmentTotal[params.user] + params.stakeAmount <=
                    limits.investmentLimit,
                "Exceeds investment limit"
            );

            //  CRITICAL FIX: Use lock manager for decay-aware reputation check
            uint256 availableReputation = lockManager.getAvailableReputation(
                params.user
            );

            require(
                limits.reputationStake <= availableReputation,
                "Insufficient available reputation"
            );
        }
    }

    function _updatePositionState(
        TakePositionParams memory params,
        PositionLimits memory limits
    ) private {
        Position storage position = positions[params.marketId][params.user][
            params.outcome
        ];
        position.stake += params.stakeAmount;
        position.reputationStake += limits.reputationStake;
        position.entryTimestamp = block.timestamp;
        position.entryPrice = outcomes[params.marketId][params.outcome]
            .impliedProbability;

        outcomes[params.marketId][params.outcome].totalStake = limits
            .newOutcomeStake;
        outcomes[params.marketId][params.outcome].totalReputationStake += limits
            .reputationStake;
        // Track user's entry price for MEV detection
        //userLastPrice[params.marketId][params.user] = position.entryPrice;
    }

    function _updateMarketState(TakePositionParams memory params) private {
        Market storage market = markets[params.marketId];
        market.totalStake += params.stakeAmount;
        market.totalReputationStake += _calculateReputationStake(
            params.user,
            params.reputationPercentage
        );
        totalMarketStakeSnapshot[params.marketId] = market.totalStake;
    }

    function _updateUserTracking(TakePositionParams memory params) private {
        uint256 reputationStake = _calculateReputationStake(
            params.user,
            params.reputationPercentage
        );

        userInvestmentTotal[params.user] += params.stakeAmount;
        userMarketStake[params.marketId][params.user] += params.stakeAmount;

        //  SURGICAL FIX: Lock reputation through centralized manager
        (bool lockSuccess, ) = lockManager.lockReputation(
            params.user,
            reputationStake,
            params.marketId
        );
        require(lockSuccess, "Failed to lock reputation");

        // Keep local tracking for backward compatibility
        userReputationLocked[params.user] += reputationStake;

        UserPosition storage userPos = userPositions[params.marketId][
            params.user
        ];
        if (userPos.totalStake == 0) {
            userPos.outcomes.push(params.outcome);
            userMarkets[params.user].push(params.marketId);
            // FIXED: Increment totalPredictions when user first participates in a market
            userStats[params.user].totalPredictions++;
            userStats[params.user].totalStaked += params.stakeAmount;
        } else {
            _addOutcomeIfNotExists(userPos, params.outcome);
            // Still track additional stakes
            userStats[params.user].totalStaked += params.stakeAmount;
        }

        userPos.totalStake += params.stakeAmount;
        userPos.totalReputationStake += reputationStake;

        userStats[params.user].lastPredictionTime = block.timestamp;
    }

    function _calculateReputationStake(
        address user,
        uint256 percentage
    ) private view returns (uint256) {
        uint256 userReputation = reputationToken.balanceOf(user);
        return Math.mulDiv(userReputation, percentage, 10000);
    }

    /**
     * @notice Add outcome to user position array with gas protection
     * @dev Limits maximum outcomes per user to prevent DoS
     */
    function _addOutcomeIfNotExists(
        UserPosition storage userPos,
        uint8 outcome
    ) private {
        //  FIX: Gas protection - max 10 outcomes per user
        require(userPos.outcomes.length < MAX_OUTCOMES, "Too many positions");

        bool found = false;
        uint256 length = userPos.outcomes.length; // Cache length to save gas

        for (uint256 i = 0; i < length; ) {
            if (userPos.outcomes[i] == outcome) {
                found = true;
                break;
            }
            unchecked {
                ++i;
            } // Gas optimization
        }

        if (!found) {
            userPos.outcomes.push(outcome);
        }
    }

    function _calculatePriceImpact(
        uint256 before,
        uint256 afterValue
    ) private pure returns (uint256) {
        if (before == 0) return 0;
        uint256 diff = before > afterValue
            ? before - afterValue
            : afterValue - before;
        return (diff * 10000) / before;
    }

    // ============ LMSR PROBABILITY CALCULATION ============

    /**
     * @notice Update implied probabilities with FIXED zero-stake handling
     * @dev  CRITICAL FIX: Handles zero-stake markets gracefully
     */
    function _updateImpliedProbabilities(uint256 marketId) internal {
        Market storage market = markets[marketId];

        //  FIX: If no stakes yet, maintain equal probabilities
        if (market.totalStake == 0) {
            uint256 equalProbability = 10000 / market.outcomeCount;
            for (uint8 i = 0; i < market.outcomeCount; i++) {
                outcomes[marketId][i].impliedProbability = equalProbability;
            }
            return;
        }

        //  FIX: If stakes exist but very small, use simple proportional
        if (market.totalStake < MIN_LIQUIDITY / 100) {
            _updateProportionalProbabilities(marketId);
            return;
        }

        // Standard LMSR for normal markets
        uint256 b = _validateLiquidityParameter(marketId);
        uint256[] memory expValues = _calculateExponentials(marketId, b);
        uint256 sumExp = _sumExponentials(expValues);

        require(sumExp > 0, "Sum of exponentials must be positive");
        _setProbabilities(marketId, expValues, sumExp);
    }

    /**
     * @notice Simple proportional probability update for small markets
     * @dev Used when market.totalStake < MIN_LIQUIDITY / 100
     */
    function _updateProportionalProbabilities(uint256 marketId) private {
        Market storage market = markets[marketId];
        uint256 totalStake = market.totalStake;

        for (uint8 i = 0; i < market.outcomeCount; i++) {
            uint256 outcomeStake = outcomes[marketId][i].totalStake;

            if (totalStake > 0) {
                outcomes[marketId][i].impliedProbability = Math.mulDiv(
                    outcomeStake,
                    10000,
                    totalStake
                );
            } else {
                outcomes[marketId][i].impliedProbability =
                    10000 /
                    market.outcomeCount;
            }
        }
    }

    /**
     * @notice Validate and adjust liquidity parameter with manipulation protection
     * @dev Implements smoothed adjustment with rate limiting
     */
    function _validateLiquidityParameter(
        uint256 marketId
    ) private returns (uint256) {
        Market storage market = markets[marketId];
        uint256 currentB = market.liquidityParameter;

        //  FIX: Use time-weighted average stake (TWAS) instead of instant totalStake
        uint256 timeWeightedStake = _calculateTimeWeightedStake(marketId);

        //  FIX: Conservative target based on TWAS
        uint256 targetB = Math.max(
            MIN_LIQUIDITY / 1000,
            timeWeightedStake / 1000 // 0.1% of TWAS instead of 0.2% of instant
        );

        //  FIX: Stricter bounds
        uint256 minB = Math.max(currentB / 2, MIN_LIQUIDITY / 1000);
        uint256 maxB = Math.min(
            market.maxLiquidityParameter,
            Math.max(currentB * 2, timeWeightedStake / 100)
        );

        //  FIX: Rate-limited adjustment (max 5% per update, down from 10%)
        uint256 maxAdjustment = currentB / 20; // 5%
        uint256 newB;

        if (targetB > currentB) {
            uint256 increase = Math.min(targetB - currentB, maxAdjustment);
            newB = Math.min(currentB + increase, maxB);
        } else if (targetB < currentB) {
            uint256 decrease = Math.min(currentB - targetB, maxAdjustment);
            newB = Math.max(currentB - decrease, minB);
        } else {
            newB = currentB;
        }

        //  FIX: Validate stability
        require(
            newB >= minB && newB <= maxB,
            "Liquidity parameter out of bounds"
        );
        require(newB > 0, "Liquidity parameter must be positive");

        market.liquidityParameter = newB;
        return newB;
    }

    /**
     * @notice Calculate time-weighted average stake to prevent instant manipulation
     * @dev Uses exponential moving average
     */
    function _calculateTimeWeightedStake(
        uint256 marketId
    ) private view returns (uint256) {
        Market storage market = markets[marketId];
        uint256 currentStake = market.totalStake;
        uint256 snapshotStake = totalMarketStakeSnapshot[marketId];

        if (snapshotStake == 0) return currentStake;

        // Exponential moving average: 70% weight on snapshot, 30% on current
        return (snapshotStake * 70 + currentStake * 30) / 100;
    }

    function _calculateExponentials(
        uint256 marketId,
        uint256 b
    ) private view returns (uint256[] memory) {
        Market storage market = markets[marketId];
        uint256[] memory expValues = new uint256[](market.outcomeCount);

        for (uint8 i = 0; i < market.outcomeCount; i++) {
            uint256 q = outcomes[marketId][i].totalStake;
            expValues[i] = _expApproximation(q, b);
        }

        return expValues;
    }

    function _sumExponentials(
        uint256[] memory expValues
    ) private pure returns (uint256) {
        uint256 sumExp = 0;
        for (uint i = 0; i < expValues.length; i++) {
            require(
                sumExp + expValues[i] >= sumExp,
                "Overflow in probability calculation"
            );
            sumExp += expValues[i];
        }
        return sumExp;
    }

    function _setProbabilities(
        uint256 marketId,
        uint256[] memory expValues,
        uint256 sumExp
    ) private {
        if (sumExp > 0) {
            Market storage market = markets[marketId];
            for (uint8 i = 0; i < market.outcomeCount; i++) {
                outcomes[marketId][i].impliedProbability = Math.mulDiv(
                    expValues[i],
                    10000,
                    sumExp
                );
            }
        }
    }

    function _expApproximation(
        uint256 q,
        uint256 b
    ) internal pure returns (uint256) {
        if (b == 0) return PRECISION;

        uint256 x = Math.mulDiv(q, PRECISION, b);
        if (x > 10 * PRECISION) x = 10 * PRECISION;

        uint256 x2 = Math.mulDiv(x, x, PRECISION);
        uint256 x3 = Math.mulDiv(x2, x, PRECISION);
        uint256 x4 = Math.mulDiv(x3, x, PRECISION);

        uint256 result = PRECISION + x + x2 / 2 + x3 / 6 + x4 / 24;

        require(
            result >= PRECISION && result <= 100 * PRECISION,
            "Exponential out of bounds"
        );

        return result;
    }

    // ============ INVESTMENT LIMITS ============

    function calculateInvestmentLimit(
        address user
    ) public view returns (uint256) {
        uint256 reputation = reputationToken.balanceOf(user);
        uint256 accuracy = getUserAccuracy(user);

        if (reputation == 0) return 0;

        uint256 baseLimit = 1000 * PRECISION;

        // Ensure proper capping and scaling
        uint256 reputationFactor = Math.min(
            reputation / (100 * PRECISION),
            MAX_REPUTATION_MULTIPLIER
        );
        uint256 accuracyMultiplier = accuracy > 5000
            ? (accuracy * 2) / 10000
            : 1;

        return
            Math.mulDiv(baseLimit, reputationFactor * accuracyMultiplier, 100);
    }

    function calculateUserPositionLimit(
        address user,
        uint256 totalMarketStake
    ) public view returns (uint256) {
        if (totalMarketStake == 0) return 0;

        uint256 reputation = reputationToken.balanceOf(user);
        uint256 accuracy = getUserAccuracy(user);
        uint256 baseLimit = MAX_USER_POSITION_BASE;

        if (reputation > 10000 * PRECISION && accuracy > 7000) {
            baseLimit = MAX_USER_POSITION_HIGH_REP;
        } else if (reputation > 5000 * PRECISION && accuracy > 6500) {
            baseLimit = 400;
        } else if (reputation > 1000 * PRECISION && accuracy > 6000) {
            baseLimit = 300;
        } else if (reputation > 500 * PRECISION && accuracy > 5500) {
            baseLimit = 200;
        }

        return Math.mulDiv(totalMarketStake, baseLimit, 10000);
    }

    // ============ MARKET RESOLUTION ============

    /**
     * @notice Update resolution state with time-lock enforcement
     * @dev Prevents rapid state transitions that bypass cooldown periods
     */
    function updateResolutionState(
        uint256 marketId,
        ResolutionState newState
    ) external onlyRole(RESOLVER_ROLE) {
        require(marketId < marketCount, "Market does not exist");

        ResolutionState currentState = marketResolutionState[marketId];
        require(
            _isValidTransition(currentState, newState),
            "Invalid state transition"
        );

        //  FIX: Enforce minimum time in each state
        uint256 lastTransitionTime = stateTransitionTime[marketId][
            currentState
        ];
        if (lastTransitionTime == 0) {
            lastTransitionTime = markets[marketId].tradingEndTime; // Use trading end for first transition
        }

        uint256 minimumTime = _getMinimumStateTime(currentState);
        require(
            block.timestamp >= lastTransitionTime + minimumTime,
            "Minimum state time not elapsed"
        );

        //  Record transition time
        stateTransitionTime[marketId][newState] = block.timestamp;
        marketResolutionState[marketId] = newState;

        emit StateTransition(marketId, currentState, newState);
    }

    /**
     * @notice Get minimum time required in each resolution state
     * @dev Prevents admin from rushing through resolution process
     */
    function _getMinimumStateTime(
        ResolutionState state
    ) private pure returns (uint256) {
        if (state == ResolutionState.TRADING) return 0; // No minimum for trading
        if (state == ResolutionState.SETTLEMENT) return SETTLEMENT_PERIOD; // 6 hours
        if (state == ResolutionState.RESOLUTION_PROPOSED) return 12 hours;
        if (state == ResolutionState.LEGISLATOR_VOTING) return 24 hours;
        if (state == ResolutionState.DISPUTE_PERIOD) return 48 hours;
        if (state == ResolutionState.FINALIZATION_COOLDOWN)
            return FINALIZATION_COOLDOWN; // 24 hours
        return 0;
    }
    function _isValidTransition(
        ResolutionState from,
        ResolutionState to
    ) internal view returns (bool) {
        ResolutionState[] memory validStates = validTransitions[from];
        for (uint i = 0; i < validStates.length; i++) {
            if (validStates[i] == to) return true;
        }
        return false;
    }

    function resolveMarket(
        uint256 marketId,
        uint8 winningOutcome
    ) external onlyRole(RESOLVER_ROLE) marketExists(marketId) {
        Market storage market = markets[marketId];
        require(block.timestamp >= market.tradingEndTime, "Trading not ended");
        require(!market.resolved, "Already resolved");
        require(winningOutcome < market.outcomeCount, "Invalid outcome");

        // Ensure market resolution only occurs from the FINALIZATION_COOLDOWN state
        ResolutionState currentState = marketResolutionState[marketId]; // Add this line
        require(
            currentState == ResolutionState.FINALIZATION_COOLDOWN,
            "Must complete full resolution process"
        );

        market.resolved = true;
        market.winningOutcome = winningOutcome;
        market.resolutionBlockNumber = block.number;
        marketResolutionState[marketId] = ResolutionState.RESOLVED;

        emit MarketResolved(marketId, winningOutcome, market.totalStake);
        emit StateTransition(marketId, currentState, ResolutionState.RESOLVED);
    }
    // ============ REWARDS CLAIMING ============

    /**
     * @notice Claim rewards for winning position OR insurance for losing positions
     * @dev  FIXED: Allows users with only losing positions to claim insurance
     */
    function claimRewards(
        uint256 marketId
    ) external nonReentrant marketExists(marketId) {
        Market storage market = markets[marketId];
        require(market.resolved, "Market not resolved");

        ResolutionState currentState = marketResolutionState[marketId];
        require(
            currentState == ResolutionState.RESOLVED,
            "Market must be in RESOLVED state"
        );

        Position storage winningPosition = positions[marketId][msg.sender][
            market.winningOutcome
        ];

        //  FIX: Check if user has ANY position (winning or losing)
        bool hasAnyPosition = false;
        for (uint8 i = 0; i < market.outcomeCount; i++) {
            if (
                positions[marketId][msg.sender][i].stake > 0 &&
                !positions[marketId][msg.sender][i].claimed
            ) {
                hasAnyPosition = true;
                break;
            }
        }
        require(hasAnyPosition, "No positions to claim");

        //  NEW: Handle winning position if exists
        if (winningPosition.stake > 0 && !winningPosition.claimed) {
            winningPosition.claimed = true;

            RewardCalculation memory rewards = _calculateRewards(
                marketId,
                msg.sender,
                market.winningOutcome
            );

            // FIXED: Update stats BEFORE processing payment so accuracy check sees correct values
            _updateUserStatsForClaim(msg.sender, winningPosition, rewards);
            _processRewardPayment(rewards);

            emit RewardsClaimed(
                marketId,
                msg.sender,
                rewards.netPayout,
                rewards.totalRepReward
            );
        }

        //  ALWAYS process losing positions (if any)
        _processLosingPositions(marketId, msg.sender, market.winningOutcome);
    }

    struct RewardCalculation {
        uint256 marketId; //  ADD THIS
        uint256 grossPayout;
        uint256 fee;
        uint256 netPayout;
        uint256 baseRepReward;
        uint256 timingBonus;
        uint256 totalRepReward;
    }
    function _calculateRewards(
        uint256 marketId,
        address user,
        uint8 winningOutcome
    ) private view returns (RewardCalculation memory) {
        Market storage market = markets[marketId];
        Position storage position = positions[marketId][user][winningOutcome];

        uint256 totalWinningStake = outcomes[marketId][winningOutcome]
            .totalStake;
        require(totalWinningStake > 0, "No winning stakes");

        RewardCalculation memory rewards;
        rewards.marketId = marketId; //  ADD THIS LINE

        rewards.grossPayout = Math.mulDiv(
            position.stake,
            market.totalStake,
            totalWinningStake
        );

        // Calculate profit-based fee model
        uint256 profit = rewards.grossPayout > position.stake
            ? rewards.grossPayout - position.stake
            : 0;
        rewards.fee = Math.mulDiv(profit, FEE_PERCENTAGE, 10000); // Fee only on profit
        rewards.netPayout = rewards.grossPayout - rewards.fee;

        // Minimum payout guarantee
        uint256 minPayout = Math.mulDiv(
            position.stake,
            MIN_PAYOUT_RATIO,
            10000
        );
        require(
            rewards.netPayout >= minPayout,
            "Payout below minimum threshold"
        );

        rewards.baseRepReward = position.reputationStake * 2;
        require(
            rewards.baseRepReward >= position.reputationStake,
            "Overflow in base reward"
        );

        rewards.timingBonus = _calculateTimingBonus(
            position,
            market,
            rewards.baseRepReward
        );
        rewards.totalRepReward = rewards.baseRepReward + rewards.timingBonus;

        return rewards;
    }

    /**
     * @notice Calculate timing bonus for early predictors
     * @dev Bonus is calculated on base reward to properly amplify early entry advantage
     * @param position User's position data
     * @param market Market data
     * @param baseRepReward The base reputation reward before timing bonus
     * @return Timing bonus amount in reputation (can be up to 50% of base reward)
     */
    function _calculateTimingBonus(
        Position storage position,
        Market storage market,
        uint256 baseRepReward //  ADD THIS PARAMETER
    ) private view returns (uint256) {
        // User entered AFTER trading ended = no bonus
        if (position.entryTimestamp >= market.tradingEndTime) return 0;

        // Calculate how much time was LEFT when user entered
        // Earlier entry = more time left = higher bonus
        uint256 timeRemaining = market.tradingEndTime - position.entryTimestamp;
        uint256 totalTime = market.tradingEndTime - market.createdAt;

        // Edge case: market created and ended at same time (shouldn't happen but safety)
        if (totalTime == 0) return 0;

        //  CORRECT LOGIC: More time remaining = higher bonus
        // If user entered at creation: timeRemaining = totalTime → 100% of MAX_TIMING_BONUS
        // If user entered just before end: timeRemaining ≈ 0 → 0% bonus
        uint256 earlyFactor = Math.mulDiv(
            timeRemaining,
            MAX_TIMING_BONUS, // 5000 = 50% max bonus
            totalTime
        );

        //  CRITICAL FIX: Calculate bonus on baseRepReward, NOT position.reputationStake
        // This properly amplifies the reward for early predictors
        return Math.mulDiv(baseRepReward, earlyFactor, 10000);
    }

    function _transferStake(TakePositionParams memory params) private {
        require(
            stakingToken.transferFrom(
                params.user,
                address(this),
                params.stakeAmount
            ),
            "Transfer failed"
        );
    }
    /**
     * @notice Update user stats after claim with FORCED lock manager sync
     * @dev  CRITICAL FIX: Always syncs to lock manager as single source of truth
     */
    function _updateUserStatsForClaim(
        address user,
        Position storage winningPosition,
        RewardCalculation memory rewards
    ) private {
        //  FIX: Decrease market-specific stake tracking
        if (userMarketStake[rewards.marketId][user] >= winningPosition.stake) {
            userMarketStake[rewards.marketId][user] -= winningPosition.stake;
        } else {
            userMarketStake[rewards.marketId][user] = 0;
        }

        // Decrease global investment total
        if (userInvestmentTotal[user] >= winningPosition.stake) {
            userInvestmentTotal[user] -= winningPosition.stake;
        } else {
            userInvestmentTotal[user] = 0;
        }

        //  CRITICAL FIX: Unlock through lock manager (single source of truth)
        (bool unlockSuccess, uint256 actualUnlocked) = lockManager
            .unlockReputation(user, rewards.marketId);

        //  FORCED SYNC: Query lock manager for accurate state (applies decay internally)
        try lockManager.getLockedReputation(user) returns (
            uint256 totalLocked
        ) {
            // Sync local tracking to match lock manager's state
            userReputationLocked[user] = totalLocked;
        } catch {
            // If query fails, use view function as fallback
            uint256 totalLocked = lockManager.getAvailableReputationView(user);
            uint256 currentBalance = reputationToken.balanceOf(user);
            userReputationLocked[user] = currentBalance > totalLocked
                ? currentBalance - totalLocked
                : 0;
        }

        // Update user statistics
        UserStats storage stats = userStats[user];
        // FIXED: Don't increment totalPredictions here - already done in takePosition
        stats.correctPredictions++;
        // FIXED: Don't increment totalStaked here - already done in takePosition
        stats.totalReturned += rewards.netPayout;
        stats.consecutiveCorrect++;

        if (stats.consecutiveCorrect > stats.maxConsecutiveCorrect) {
            stats.maxConsecutiveCorrect = stats.consecutiveCorrect;
        }
    }

    /**
     * @notice Process losing positions with FORCED lock manager sync
     * @dev  CRITICAL FIX: Locks are unlocked once per market, not per outcome
     */
    function _processLosingPositions(
        uint256 marketId,
        address user,
        uint8 winningOutcome
    ) internal {
        Market storage market = markets[marketId];
        uint256 totalLosingStake = 0;
        bool hasLosingPositions = false;

        // First pass: calculate totals and pay insurance
        for (uint8 i = 0; i < market.outcomeCount; i++) {
            if (i != winningOutcome) {
                Position storage losingPosition = positions[marketId][user][i];
                if (losingPosition.stake > 0 && !losingPosition.claimed) {
                    losingPosition.claimed = true;
                    hasLosingPositions = true;
                    totalLosingStake += losingPosition.stake;

                    // Insurance payout (0.5% of losing stake)
                    uint256 insurancePayout = Math.mulDiv(
                        losingPosition.stake,
                        LOSS_INSURANCE_PERCENTAGE,
                        10000
                    );

                    if (insurancePayout > 0) {
                        require(
                            stakingToken.transfer(user, insurancePayout),
                            "Insurance payout failed"
                        );
                    }

                    // Update user stats for this losing position
                    UserStats storage stats = userStats[user];
                    // FIXED: Don't increment totalPredictions - already done in takePosition
                    // FIXED: Don't increment totalStaked - already done in takePosition
                    stats.totalReturned += insurancePayout;
                    stats.consecutiveCorrect = 0; // Reset streak on loss
                }
            }
        }

        //  FIX: Only process stake cleanup and unlock if user had losing positions
        if (hasLosingPositions) {
            // Cleanup market stake tracking
            if (userMarketStake[marketId][user] >= totalLosingStake) {
                userMarketStake[marketId][user] -= totalLosingStake;
            } else {
                userMarketStake[marketId][user] = 0;
            }

            // Decrease global investment total
            if (userInvestmentTotal[user] >= totalLosingStake) {
                userInvestmentTotal[user] -= totalLosingStake;
            } else {
                userInvestmentTotal[user] = 0;
            }

            //  CRITICAL FIX: Unlock reputation ONCE per market (not per outcome)
            // Lock manager handles decay internally
            (bool unlockSuccess, uint256 actualUnlocked) = lockManager
                .unlockReputation(user, marketId);

            //  FORCED SYNC: Always sync to lock manager's state
            try lockManager.getLockedReputation(user) returns (
                uint256 totalLocked
            ) {
                userReputationLocked[user] = totalLocked;
            } catch {
                uint256 available = lockManager.getAvailableReputationView(
                    user
                );
                uint256 currentBalance = reputationToken.balanceOf(user);
                userReputationLocked[user] = currentBalance > available
                    ? currentBalance - available
                    : 0;
            }
        }
    }
    /**
     * @notice Proactively sync local reputation tracking with lock manager
     * @dev  NEW: Call this periodically to prevent drift
     */
    function syncReputationTracking(address user) external {
        try lockManager.getLockedReputation(user) returns (
            uint256 totalLocked
        ) {
            userReputationLocked[user] = totalLocked;
        } catch {
            uint256 available = lockManager.getAvailableReputationView(user);
            uint256 currentBalance = reputationToken.balanceOf(user);
            userReputationLocked[user] = currentBalance > available
                ? currentBalance - available
                : 0;
        }
    }
    /**
     * @notice Process reward payment with proper validation
     * @dev  FIXED: Validates accuracy before minting reputation
     */
    function _processRewardPayment(RewardCalculation memory rewards) private {
        // Transfer net payout to user
        require(
            stakingToken.transfer(msg.sender, rewards.netPayout),
            "Payout failed"
        );

        // Transfer fee to fee recipient
        if (rewards.fee > 0) {
            totalFeesCollected += rewards.fee;
            require(
                stakingToken.transfer(feeRecipient, rewards.fee),
                "Fee transfer failed"
            );
        }

        //  FIX: Validate accuracy before minting
        uint256 accuracy = getUserAccuracy(msg.sender);

        // Ensure accuracy is in valid range (0-10000)
        require(accuracy <= 10000, "Invalid accuracy");

        // Ensure accuracy meets minimum threshold for reputation minting
        require(accuracy >= 2000, "Accuracy too low for reputation reward");

        // Ensure reward amount is reasonable (prevent overflow in ReputationToken)
        require(
            rewards.totalRepReward <=
                reputationToken.balanceOf(msg.sender) * 10, // Max 10x current balance per claim
            "Reputation reward too large"
        );

        // Mint reputation rewards
        reputationToken.mintReputation(
            msg.sender,
            rewards.totalRepReward,
            accuracy
        );
    }

    // ============ LEGISLATOR MANAGEMENT ============

    function promoteToLegislator(
        address user
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(!legislators.contains(user), "Already a legislator");

        uint256 accuracy = getUserAccuracy(user);
        uint256 predictions = userStats[user].totalPredictions;
        uint256 consecutiveCorrect = userStats[user].maxConsecutiveCorrect;

        require(accuracy >= LEGISLATOR_MIN_ACCURACY, "Accuracy too low");
        require(
            predictions >= LEGISLATOR_MIN_PREDICTIONS,
            "Insufficient predictions"
        );
        require(
            consecutiveCorrect >= LEGISLATOR_MIN_CONSECUTIVE,
            "Inconsistent performance"
        );

        legislators.add(user);
        _grantRole(LEGISLATOR_ROLE, user);

        legislatorInfo[user] = LegislatorInfo({
            accuracyScore: accuracy,
            predictionCount: predictions,
            promotionTime: block.timestamp,
            lastActivityTime: block.timestamp
        });

        emit LegislatorPromoted(user, accuracy);
    }

    function demoteFromLegislator(
        address legislator
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(legislators.contains(legislator), "Not a legislator");

        legislators.remove(legislator);
        _revokeRole(LEGISLATOR_ROLE, legislator);
        delete legislatorInfo[legislator];

        emit LegislatorDemoted(legislator, "Admin action");
    }

    function applyLegislatorDecay(
        address legislator
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(legislators.contains(legislator), "Not a legislator");

        uint256 lastActivity = userStats[legislator].lastPredictionTime;
        if (block.timestamp <= lastActivity + LEGISLATOR_INACTIVITY_PERIOD)
            return;

        legislators.remove(legislator);
        _revokeRole(LEGISLATOR_ROLE, legislator);
        delete legislatorInfo[legislator];

        uint256 currentRep = reputationToken.balanceOf(legislator);
        uint256 penalty = Math.mulDiv(
            currentRep,
            LEGISLATOR_DECAY_PENALTY,
            10000
        );

        reputationToken.slashReputation(
            legislator,
            penalty,
            "Legislator inactivity"
        );

        emit LegislatorDemoted(legislator, "Inactivity");
    }

    // ============ VIEW FUNCTIONS ============

    function getUserAccuracy(address user) public view returns (uint256) {
        if (userStats[user].totalPredictions == 0) return 5000;
        return
            Math.mulDiv(
                userStats[user].correctPredictions,
                10000,
                userStats[user].totalPredictions
            );
    }

    function getMarket(
        uint256 marketId
    )
        external
        view
        returns (
            string memory question,
            uint256 tradingEndTime,
            uint256 totalStake,
            bool resolved,
            uint8 winningOutcome
        )
    {
        Market storage market = markets[marketId];
        return (
            market.question,
            market.tradingEndTime,
            market.totalStake,
            market.resolved,
            market.winningOutcome
        );
    }

    function getOutcomeProbabilities(
        uint256 marketId
    ) external view returns (uint256[] memory probabilities) {
        Market storage market = markets[marketId];
        probabilities = new uint256[](market.outcomeCount);

        for (uint8 i = 0; i < market.outcomeCount; i++) {
            probabilities[i] = outcomes[marketId][i].impliedProbability;
        }
    }

    function getUserPosition(
        uint256 marketId,
        address user,
        uint8 outcome
    )
        external
        view
        returns (
            uint256 stake,
            uint256 reputationStake,
            uint256 entryPrice,
            bool claimed
        )
    {
        Position storage position = positions[marketId][user][outcome];
        return (
            position.stake,
            position.reputationStake,
            position.entryPrice,
            position.claimed
        );
    }

    function hasUnclaimedPositions(address user) external view returns (bool) {
        uint256[] memory userMarketList = userMarkets[user];

        for (uint256 i = 0; i < userMarketList.length; i++) {
            uint256 marketId = userMarketList[i];
            if (markets[marketId].resolved) {
                for (uint8 j = 0; j < markets[marketId].outcomeCount; j++) {
                    Position storage position = positions[marketId][user][j];
                    if (position.stake > 0 && !position.claimed) {
                        return true;
                    }
                }
            }
        }
        return false;
    }

    function getUserLockedReputationBreakdown(
        address user
    )
        external
        view
        returns (uint256[] memory marketIds, uint256[] memory lockedAmounts)
    {
        uint256[] memory userMarketList = userMarkets[user];
        uint256 count = 0;

        for (uint256 i = 0; i < userMarketList.length; i++) {
            uint256 marketId = userMarketList[i];
            if (!markets[marketId].resolved) {
                UserPosition storage userPos = userPositions[marketId][user];
                if (userPos.totalReputationStake > 0) {
                    count++;
                }
            }
        }

        marketIds = new uint256[](count);
        lockedAmounts = new uint256[](count);

        uint256 index = 0;
        for (uint256 i = 0; i < userMarketList.length; i++) {
            uint256 marketId = userMarketList[i];
            if (!markets[marketId].resolved) {
                UserPosition storage userPos = userPositions[marketId][user];
                if (userPos.totalReputationStake > 0) {
                    marketIds[index] = marketId;
                    lockedAmounts[index] = userPos.totalReputationStake;
                    index++;
                }
            }
        }
    }

    function getMarketHealth(
        uint256 marketId
    )
        external
        view
        returns (
            bool isHealthy,
            uint256 concentrationRisk,
            uint256 liquidityRatio,
            ResolutionState currentState
        )
    {
        Market storage market = markets[marketId];

        uint256 maxOutcomeStake = 0;
        for (uint8 i = 0; i < market.outcomeCount; i++) {
            if (outcomes[marketId][i].totalStake > maxOutcomeStake) {
                maxOutcomeStake = outcomes[marketId][i].totalStake;
            }
        }

        concentrationRisk = market.totalStake > 0
            ? Math.mulDiv(maxOutcomeStake, 10000, market.totalStake)
            : 0;

        liquidityRatio = market.liquidityParameter > 0
            ? Math.mulDiv(market.totalStake, 10000, market.liquidityParameter)
            : 0;

        currentState = marketResolutionState[marketId];

        isHealthy =
            concentrationRisk <= MAX_POSITION_SIZE &&
            liquidityRatio >= 100 &&
            market.totalStake >= MIN_LIQUIDITY / 10;
    }
    /**
     * @notice Get user's available reputation from lock manager
     * @dev Public view function for UI integration
     */
    function getUserAvailableReputation(
        address user
    ) external view returns (uint256 available) {
        return lockManager.getAvailableReputationView(user);
    }
    /**
     * @notice Get the current resolution state of a market
     * @param marketId The market ID to query
     * @return The current resolution state
     */
    function getMarketState(
        uint256 marketId
    ) external view returns (ResolutionState) {
        require(marketId < marketCount, "Market does not exist");
        return marketResolutionState[marketId];
    }
    // ============ ADMIN FUNCTIONS ============

    function updateFeeRecipient(
        address newRecipient
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newRecipient != address(0), "Invalid recipient");
        require(newRecipient != feeRecipient, "Same recipient");

        address oldRecipient = feeRecipient;
        feeRecipient = newRecipient;
        emit FeeRecipientUpdated(oldRecipient, newRecipient);
    }
    /**
     * @notice Get market's price asset address
     * @dev Returns address(0) if market doesn't use Chainlink prices
     * @param marketId The market ID
     * @return Asset address (address(0) for non-price markets)
     */
    function getMarketAsset(uint256 marketId) external view returns (address) {
        require(marketId < marketCount, "Market does not exist");
        return markets[marketId].priceAsset;
    }
    /**
     * @notice Check if a market is resolved
     * @param marketId The market ID to check
     * @return True if market is resolved, false otherwise
     */
    function isResolved(uint256 marketId) external view returns (bool) {
        require(marketId < marketCount, "Market does not exist");
        return markets[marketId].resolved;
    }

    /**
     * @notice Get market's Chainlink price ID
     * @dev Returns bytes32(0) if market doesn't use Chainlink prices
     * @param marketId The market ID
     * @return Price recording ID (bytes32(0) for non-price markets)
     */
    function getMarketPriceId(
        uint256 marketId
    ) external view returns (bytes32) {
        require(marketId < marketCount, "Market does not exist");
        return markets[marketId].chainlinkPriceId;
    }

    /**
     * @notice Check if market uses Chainlink price tracking
     * @param marketId The market ID
     * @return True if market has Chainlink integration
     */
    function isChainlinkMarket(uint256 marketId) external view returns (bool) {
        require(marketId < marketCount, "Market does not exist");
        return
            markets[marketId].priceAsset != address(0) &&
            markets[marketId].chainlinkPriceId != bytes32(0);
    }
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }
}
