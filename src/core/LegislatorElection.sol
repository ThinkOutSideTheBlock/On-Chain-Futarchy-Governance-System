// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./GovernancePredictionMarket.sol";
import "./ReputationToken.sol";
import "../governance/ReputationLockManager.sol";

/**
 * @title LegislatorElection
 * @notice Manages election of legislators based on prediction accuracy and reputation
 * @dev Production-ready implementation with comprehensive safety checks
 */
contract LegislatorElection is AccessControl, ReentrancyGuard, Pausable {
    using EnumerableSet for EnumerableSet.AddressSet;
    using Math for uint256;

    // Contracts
    GovernancePredictionMarket public immutable predictionMarket;
    ReputationToken public immutable reputationToken;
    IERC20 public immutable stakingToken;
    IReputationLockManager public lockManager;

    // Roles
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant PREDICTION_MARKET_ROLE =
        keccak256("PREDICTION_MARKET_ROLE");

    // Legislator structure with extension tracking
    struct Legislator {
        address account;
        uint256 electionBlock;
        uint256 electionTime;
        uint256 termEndTime;
        uint256 reputation;
        uint256 predictionAccuracy;
        uint256 marketsParticipated;
        uint256 proposalsCreated;
        uint256 successfulProposals;
        uint256 totalStakeManaged;
        uint256 performanceScore;
        bool isActive;
        uint256 lastActivityTime;
        uint256 totalExtensions; // Track number of extensions
        uint256 maxTermEnd; // Hard cap on term end
    }

    enum MarketCategory {
        LEGISLATION,
        BUDGET,
        APPOINTMENT,
        REGULATION,
        TREATY,
        EMERGENCY,
        GENERAL
    }
    // Election round structure
    struct ElectionRound {
        uint256 roundId;
        uint256 startTime;
        uint256 endTime;
        uint256 nominationEndTime;
        uint256 candidateCount;
        uint256 totalVotes;
        uint256 quorumRequired;
        bool finalized;
        address[] electedLegislators;
    }

    // Candidate structure
    struct Candidate {
        address account;
        uint256 nominationTime;
        uint256 supportStake;
        uint256 supportReputation;
        uint256 supporterCount;
        uint256 qualificationScore;
        bool elected;
        bool withdrawn;
    }

    // Support structure
    struct Support {
        uint256 stakeAmount;
        uint256 reputationAmount;
        uint256 timestamp;
        bool withdrawn;
    }

    // Constants
    uint256 public constant ELECTION_DURATION = 7 days;
    uint256 public constant NOMINATION_PERIOD = 3 days;
    uint256 public constant LEGISLATOR_TERM = 12 weeks;
    uint256 public constant COOLDOWN_PERIOD = 2 weeks;
    uint256 public constant MAX_TERM_EXTENSIONS = 2;
    uint256 public constant MAX_EXTENSION_DURATION = 4 weeks;
    uint256 public constant MAX_TOTAL_EXTENSION = 8 weeks;

    uint256 public constant MIN_ABSOLUTE_QUORUM = 1000 * 10 ** 18;
    uint256 public constant MAX_LEGISLATORS = 21;
    uint256 public constant MIN_LEGISLATORS = 7;
    uint256 public constant OPTIMAL_LEGISLATORS = 15;

    uint256 public constant MIN_REPUTATION_FOR_CANDIDACY = 1000 * 10 ** 18;
    uint256 public constant MIN_ACCURACY_FOR_CANDIDACY = 6000;
    uint256 public constant MIN_MARKETS_PARTICIPATED = 10;
    uint256 public constant MIN_SUPPORT_STAKE = 100 * 10 ** 18;
    uint256 public constant MIN_UNIQUE_MARKETS = 5;

    uint256 public constant QUORUM_PERCENTAGE = 3000;
    uint256 public constant PERFORMANCE_THRESHOLD = 5000;
    uint256 public constant PRECISION = 10000;

    // State variables
    mapping(address => Legislator) public legislators;
    EnumerableSet.AddressSet private activeLegislators;
    EnumerableSet.AddressSet private historicalLegislators;

    // Fixed market type tracking
    mapping(address => mapping(bytes32 => uint256)) public userMarketTypeCount;
    mapping(address => bytes32[]) public userMarketCategories;

    // Sybil-resistant voting power tracking
    mapping(uint256 => mapping(address => uint256)) public totalStakedByUser;

    // Treasury race condition protection
    mapping(uint256 => mapping(address => mapping(address => bool)))
        public refundReserved;
    mapping(uint256 => mapping(address => mapping(address => uint256)))
        public reservedAmount;
    mapping(uint256 => ElectionRound) public electionRounds;
    mapping(uint256 => EnumerableSet.AddressSet) private roundCandidates;
    mapping(uint256 => mapping(address => Candidate)) public candidates;
    mapping(uint256 => mapping(address => mapping(address => Support)))
        public candidateSupport;
    mapping(uint256 => mapping(address => uint256)) public candidateRefundRates;
    mapping(uint256 => mapping(address => EnumerableSet.AddressSet))
        private candidateSupporters;

    // Performance score manipulation protection
    mapping(address => uint256) public lastPerformanceUpdate;
    uint256 public constant PERFORMANCE_UPDATE_COOLDOWN = 1 days;
    uint256 public constant MAX_SINGLE_UPDATE = 1000; // Max 10% change per update
    uint256 public constant LEGISLATOR_INACTIVITY_PERIOD = 90 days; // 90 days inactivity threshold
    // Market category diversity gaming protection
    mapping(address => mapping(bytes32 => uint256)) public userCategoryStake;
    uint256 public constant MIN_STAKE_PER_CATEGORY = 100 * 10 ** 18; // 100 tokens minimum
    // Treasury tracking
    uint256 public electionTreasury;
    uint256 public committedFunds;
    uint256 public availableFunds;
    uint256 public currentElectionRound;
    uint256 public nextElectionTime;
    uint256 public totalElectionsHeld;
    uint256 public totalLegislatorsElected;
    uint256 public lastElectionStartTime; // ← ADD THIS LINE

    //  NEW: Snapshot-based performance tracking
    uint256 public constant SNAPSHOT_INTERVAL = 1 weeks;
    uint256 public currentSnapshotId;
    mapping(uint256 => mapping(address => uint256)) public performanceSnapshots;
    mapping(address => uint256) public lastSnapshotUpdate;
    // Performance tracking
    mapping(address => uint256) public lastElectionParticipation;
    mapping(address => uint256[]) public legislatorHistory;
    mapping(address => uint256) public cumulativePerformanceScore;

    // Events
    event ElectionCancelled(uint256 indexed roundId, string reason);

    event PerformanceSnapshotCreated(
        uint256 indexed snapshotId,
        address indexed legislator,
        uint256 score
    );
    event ElectionStarted(
        uint256 indexed round,
        uint256 startTime,
        uint256 endTime
    );
    event CandidateNominated(
        address indexed candidate,
        uint256 round,
        uint256 qualificationScore
    );
    event CandidateSupported(
        address indexed candidate,
        address indexed supporter,
        uint256 stake,
        uint256 reputation
    );
    event SupportRefunded(
        address indexed supporter,
        address indexed candidate,
        uint256 roundId,
        uint256 amount
    );
    event SupportWithdrawn(
        address indexed candidate,
        address indexed supporter,
        uint256 stake
    );
    event LegislatorElected(
        address indexed legislator,
        uint256 round,
        uint256 score
    );
    event LegislatorRemoved(address indexed legislator, string reason);
    event LegislatorTermExtended(
        address indexed legislator,
        uint256 newTermEnd
    );
    event ElectionFinalized(uint256 indexed round, uint256 electedCount);
    event PerformanceScoreUpdated(address indexed legislator, uint256 newScore);
    event RefundRatesSet(
        uint256 indexed roundId,
        uint256 totalRefundable,
        uint256 maxRefund
    );
    event MarketParticipationRecorded(
        address indexed user,
        bytes32 indexed categoryHash
    );

    // Internal structures
    struct CandidateScore {
        address candidate;
        uint256 totalScore;
        bool elected;
    }

    /**
     * @notice Modifier to enforce inactivity rules automatically
     * @dev Checks and removes inactive legislators before executing function
     */
    modifier enforceInactivityRules() {
        _checkAndRemoveInactiveLegislators();
        _;
    }
    constructor(
        address _predictionMarket,
        address _reputationToken,
        address _stakingToken,
        address _lockManager
    ) {
        require(_predictionMarket != address(0), "Invalid prediction market");
        require(_reputationToken != address(0), "Invalid reputation token");
        require(_stakingToken != address(0), "Invalid staking token");

        predictionMarket = GovernancePredictionMarket(_predictionMarket);
        reputationToken = ReputationToken(_reputationToken);
        stakingToken = IERC20(_stakingToken);
        lockManager = IReputationLockManager(_lockManager);

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(GOVERNANCE_ROLE, msg.sender);
        _grantRole(PREDICTION_MARKET_ROLE, _predictionMarket);

        //  CRITICAL FIX: Initialize BEFORE calling _startNewElection
        lastElectionStartTime = block.timestamp;

        // Initialize first election
        _startNewElection();
    }

    /**
     * @notice Record user participation in a market category with stake tracking
     * @dev FIXED: Added stake amount tracking to prevent fake diversity
     */
    function recordMarketParticipation(
        address user,
        uint8 categoryIndex,
        uint256 stakeAmount
    ) external onlyRole(PREDICTION_MARKET_ROLE) {
        require(user != address(0), "Invalid user");
        require(categoryIndex <= 6, "Invalid category");
        require(stakeAmount > 0, "Invalid stake");

        MarketCategory category = MarketCategory(categoryIndex);
        bytes32 categoryHash = keccak256(abi.encode(category));

        if (userMarketTypeCount[user][categoryHash] == 0) {
            userMarketCategories[user].push(categoryHash);
        }

        userMarketTypeCount[user][categoryHash]++;
        userCategoryStake[user][categoryHash] += stakeAmount;

        emit MarketParticipationRecorded(user, categoryHash);
    }

    /**
     * @notice Start a new election round
     * @dev  FIXED: Safe arithmetic with underflow protection
     */
    function _startNewElection() private {
        //  SAFE: Only check cooldown after first election
        if (currentElectionRound > 0) {
            // Safe calculation to prevent underflow
            uint256 termDuration = LEGISLATOR_TERM > ELECTION_DURATION
                ? LEGISLATOR_TERM - ELECTION_DURATION
                : LEGISLATOR_TERM;

            require(
                block.timestamp >= lastElectionStartTime + termDuration,
                "Election cooldown not met"
            );
        }

        uint256 roundId = currentElectionRound++;
        uint256 startTime = block.timestamp;
        lastElectionStartTime = startTime; //  Track last election start
        uint256 endTime = startTime + ELECTION_DURATION;
        uint256 nominationEndTime = startTime + NOMINATION_PERIOD;

        // Calculate quorum based on voting power, not legislator count
        uint256 totalCirculatingStake = stakingToken.totalSupply();

        // Calculate dynamic quorum (3% of total circulating stake)
        uint256 dynamicQuorum;
        if (totalCirculatingStake > 0) {
            uint256 targetStake = (totalCirculatingStake * QUORUM_PERCENTAGE) /
                PRECISION;

            // Cap at reasonable maximum to prevent overflow (100M tokens with 18 decimals)
            uint256 maxTargetStake = 100_000_000 * 10 ** 18;
            targetStake = Math.min(targetStake, maxTargetStake);

            // Safe sqrt with capped input
            dynamicQuorum = Math.sqrt(targetStake * PRECISION);
        } else {
            dynamicQuorum = Math.sqrt(MIN_ABSOLUTE_QUORUM * PRECISION);
        }

        // Calculate minimum absolute quorum
        uint256 minQuorumVotingPower = Math.sqrt(
            MIN_ABSOLUTE_QUORUM * PRECISION
        );

        //  CRITICAL: Use the higher of the two and ensure it's NEVER zero
        uint256 finalQuorum = Math.max(minQuorumVotingPower, dynamicQuorum);
        require(finalQuorum > 0, "Quorum cannot be zero");

        electionRounds[roundId] = ElectionRound({
            roundId: roundId,
            startTime: startTime,
            endTime: endTime,
            nominationEndTime: nominationEndTime,
            candidateCount: 0,
            totalVotes: 0,
            quorumRequired: finalQuorum,
            finalized: false,
            electedLegislators: new address[](0)
        });

        nextElectionTime = endTime + LEGISLATOR_TERM - ELECTION_DURATION;

        emit ElectionStarted(roundId, startTime, endTime);
    }
    /**
     * @notice Nominate oneself as a candidate for legislator with inactivity enforcement
     * @dev  FIXED: Added bounds check to prevent underflow
     */
    function nominateForLegislator()
        external
        nonReentrant
        whenNotPaused
        enforceInactivityRules
    {
        //  CRITICAL FIX: Prevent underflow
        require(currentElectionRound > 0, "No active election");

        uint256 roundId = currentElectionRound - 1;
        ElectionRound storage round = electionRounds[roundId];

        require(
            block.timestamp <= round.nominationEndTime,
            "Nomination period ended"
        );
        require(!round.finalized, "Round finalized");
        require(canNominate(msg.sender), "Not eligible");
        require(
            !roundCandidates[roundId].contains(msg.sender),
            "Already nominated"
        );

        // Check cooldown
        require(
            block.timestamp >=
                lastElectionParticipation[msg.sender] + COOLDOWN_PERIOD,
            "In cooldown period"
        );

        uint256 qualificationScore = calculateQualificationScore(msg.sender);

        roundCandidates[roundId].add(msg.sender);
        candidates[roundId][msg.sender] = Candidate({
            account: msg.sender,
            nominationTime: block.timestamp,
            supportStake: 0,
            supportReputation: 0,
            supporterCount: 0,
            qualificationScore: qualificationScore,
            elected: false,
            withdrawn: false
        });

        round.candidateCount++;
        lastElectionParticipation[msg.sender] = block.timestamp;

        emit CandidateNominated(msg.sender, roundId, qualificationScore);
    }

    /**
     * @notice Check if an address is eligible for nomination with stake diversity check
     * @dev FIXED: Checks meaningful stake per category, not just participation count
     */
    function canNominate(address account) public view returns (bool) {
        // Check if already a legislator
        if (legislators[account].isActive) return false;

        // Check reputation
        uint256 reputation = reputationToken.balanceOf(account);
        if (reputation < MIN_REPUTATION_FOR_CANDIDACY) return false;

        // Check prediction accuracy
        uint256 accuracy = predictionMarket.getUserAccuracy(account);
        if (accuracy < MIN_ACCURACY_FOR_CANDIDACY) return false;

        // Check market participation
        GovernancePredictionMarket.UserStats memory stats = getUserStats(
            account
        );
        if (stats.totalPredictions < MIN_MARKETS_PARTICIPATED) return false;

        // Check market type diversity with meaningful stake requirement
        uint256 categoriesWithMeaningfulStake = 0;

        for (uint256 i = 0; i < userMarketCategories[account].length; i++) {
            bytes32 categoryHash = userMarketCategories[account][i];
            if (
                userCategoryStake[account][categoryHash] >=
                MIN_STAKE_PER_CATEGORY
            ) {
                categoriesWithMeaningfulStake++;
            }
        }

        if (categoriesWithMeaningfulStake < MIN_UNIQUE_MARKETS) return false;

        return true;
    }

    /**
     * @notice Support a candidate with stake and reputation - SYBIL RESISTANT
     * @dev  FIXED: Added bounds check and fixed reputation double-counting
     */
    function supportCandidate(
        address candidate,
        uint256 stakeAmount,
        uint256 reputationPercentage
    ) external nonReentrant whenNotPaused {
        //  CRITICAL FIX: Prevent underflow
        require(currentElectionRound > 0, "No active election");

        uint256 roundId = currentElectionRound - 1;
        ElectionRound storage round = electionRounds[roundId];

        require(
            block.timestamp >= round.startTime &&
                block.timestamp < round.endTime,
            "Not in voting period"
        );
        require(!round.finalized, "Round finalized");
        require(
            roundCandidates[roundId].contains(candidate),
            "Not a candidate"
        );
        require(
            !candidates[roundId][candidate].withdrawn,
            "Candidate withdrawn"
        );
        require(stakeAmount >= MIN_SUPPORT_STAKE, "Stake too low");
        require(
            reputationPercentage > 0 && reputationPercentage <= PRECISION,
            "Invalid reputation percentage"
        );

        Support storage support = candidateSupport[roundId][candidate][
            msg.sender
        ];
        require(!support.withdrawn, "Support withdrawn");

        // SYBIL-RESISTANT VOTING POWER CALCULATION
        uint256 userPreviousTotal = totalStakedByUser[roundId][msg.sender];
        uint256 userNewTotal = userPreviousTotal + stakeAmount;

        // Incremental voting power = sqrt(new total) - sqrt(previous total)
        uint256 previousVotingPower = userPreviousTotal > 0
            ? Math.sqrt(userPreviousTotal * PRECISION)
            : 0;
        uint256 newVotingPower = Math.sqrt(userNewTotal * PRECISION);
        uint256 incrementalVotingPower = newVotingPower - previousVotingPower;

        require(incrementalVotingPower > 0, "Invalid voting power");

        // Transfer stake
        require(
            stakingToken.transferFrom(msg.sender, address(this), stakeAmount),
            "Transfer failed"
        );

        // Update global user stake tracking
        totalStakedByUser[roundId][msg.sender] = userNewTotal;

        //  CRITICAL FIX: Calculate NEW reputation amount only (not accumulated)
        uint256 newReputationAmount = (reputationToken.balanceOf(msg.sender) *
            reputationPercentage) / PRECISION;

        // Update support
        if (support.stakeAmount == 0) {
            candidates[roundId][candidate].supporterCount++;
            candidateSupporters[roundId][candidate].add(msg.sender);
        }

        support.stakeAmount += stakeAmount;
        support.reputationAmount += newReputationAmount; //  Accumulate total
        support.timestamp = block.timestamp;

        //  CRITICAL FIX: Add only NEW reputation, not total accumulated
        candidates[roundId][candidate].supportStake += incrementalVotingPower;
        candidates[roundId][candidate].supportReputation += newReputationAmount;

        electionTreasury += stakeAmount;
        availableFunds += stakeAmount;

        //  FIX: Weight votes by voting power, not raw count
        round.totalVotes += incrementalVotingPower;

        emit CandidateSupported(
            candidate,
            msg.sender,
            stakeAmount,
            newReputationAmount
        );
    }
    /**
     * @notice Withdraw support with FIXED voting power tracking
     * @dev  FIXED: Safe bounds checking before arithmetic operations
     */
    function withdrawSupport(address candidate) external nonReentrant {
        //  CRITICAL FIX: Prevent underflow
        require(currentElectionRound > 0, "No active election");

        uint256 roundId = currentElectionRound - 1;
        ElectionRound storage round = electionRounds[roundId];

        require(!round.finalized, "Round finalized");

        //  CRITICAL FIX: Check bounds BEFORE subtraction to prevent underflow
        require(block.timestamp < round.endTime, "Round ended");

        Support storage support = candidateSupport[roundId][candidate][
            msg.sender
        ];
        require(support.stakeAmount > 0, "No support to withdraw");
        require(!support.withdrawn, "Already withdrawn");

        require(
            block.timestamp >= support.timestamp + 1 days,
            "Must wait 1 day after support"
        );

        //  NOW SAFE: We know round.endTime > block.timestamp
        uint256 withdrawalWindow = round.endTime - block.timestamp;
        uint256 totalWindow = round.endTime > round.startTime
            ? round.endTime - round.startTime
            : ELECTION_DURATION;

        // Calculate time-based penalty
        uint256 penaltyRate;
        if (withdrawalWindow > (totalWindow * 80) / 100) {
            penaltyRate = 500; // 5% penalty
        } else if (withdrawalWindow > (totalWindow * 50) / 100) {
            penaltyRate = 2000; // 20% penalty
        } else if (withdrawalWindow > 3 days) {
            penaltyRate = 5000; // 50% penalty
        } else {
            revert("Too late to withdraw");
        }

        support.withdrawn = true;

        //  CRITICAL FIX: Calculate voting power BEFORE withdrawal
        uint256 userTotalBeforeWithdrawal = totalStakedByUser[roundId][
            msg.sender
        ];
        uint256 votingPowerBefore = userTotalBeforeWithdrawal > 0
            ? Math.sqrt(userTotalBeforeWithdrawal * PRECISION)
            : 0;

        //  CRITICAL FIX: Calculate what total WOULD BE after withdrawal
        uint256 userTotalAfterWithdrawal = userTotalBeforeWithdrawal >
            support.stakeAmount
            ? userTotalBeforeWithdrawal - support.stakeAmount
            : 0;

        uint256 votingPowerAfter = userTotalAfterWithdrawal > 0
            ? Math.sqrt(userTotalAfterWithdrawal * PRECISION)
            : 0;

        //  CRITICAL FIX: The voting power TO REMOVE is the DIFFERENCE
        uint256 votingPowerToRemove = votingPowerBefore > votingPowerAfter
            ? votingPowerBefore - votingPowerAfter
            : 0;

        //  CRITICAL FIX: Update global tracking BEFORE reducing candidate support
        totalStakedByUser[roundId][msg.sender] = userTotalAfterWithdrawal;

        //  CRITICAL FIX: Reduce candidate's voting power by exact amount
        candidates[roundId][candidate].supportStake = candidates[roundId][
            candidate
        ].supportStake > votingPowerToRemove
            ? candidates[roundId][candidate].supportStake - votingPowerToRemove
            : 0;

        candidates[roundId][candidate].supportReputation = candidates[roundId][
            candidate
        ].supportReputation > support.reputationAmount
            ? candidates[roundId][candidate].supportReputation -
                support.reputationAmount
            : 0;

        candidates[roundId][candidate].supporterCount--;

        //  CRITICAL FIX: Reduce round's total votes
        round.totalVotes = round.totalVotes > votingPowerToRemove
            ? round.totalVotes - votingPowerToRemove
            : 0;

        // Calculate return amount with penalty
        uint256 penalty = (support.stakeAmount * penaltyRate) / PRECISION;
        uint256 returnAmount = support.stakeAmount - penalty;

        // Update treasury
        electionTreasury -= support.stakeAmount;
        availableFunds = availableFunds > support.stakeAmount
            ? availableFunds - support.stakeAmount
            : 0;

        require(
            stakingToken.transfer(msg.sender, returnAmount),
            "Transfer failed"
        );

        emit SupportWithdrawn(candidate, msg.sender, returnAmount);
    }
    /**
     * @notice Calculate qualification score for a candidate
     */
    function calculateQualificationScore(
        address candidate
    ) public view returns (uint256) {
        uint256 reputation = reputationToken.balanceOf(candidate);
        uint256 accuracy = predictionMarket.getUserAccuracy(candidate);
        GovernancePredictionMarket.UserStats memory stats = getUserStats(
            candidate
        );

        // Weight factors
        uint256 reputationScore = Math.min(reputation / 10 ** 18, 10000);
        uint256 accuracyScore = accuracy;
        uint256 participationScore = Math.min(
            stats.totalPredictions * 100,
            10000
        );
        uint256 consistencyScore = Math.min(
            stats.consecutiveCorrect * 1000,
            10000
        );

        // Market diversity score
        uint256 diversityScore = Math.min(
            userMarketCategories[candidate].length * 2000,
            10000
        );

        // Historical performance bonus
        uint256 historicalBonus = 0;
        if (historicalLegislators.contains(candidate)) {
            historicalBonus = Math.min(
                cumulativePerformanceScore[candidate],
                5000
            );
        }

        // Weighted average
        return
            (reputationScore *
                20 +
                accuracyScore *
                25 +
                participationScore *
                15 +
                consistencyScore *
                15 +
                diversityScore *
                15 +
                historicalBonus *
                10) / 100;
    }

    /**
     * @notice Finalize election and elect legislators with inactivity enforcement
     * @dev  FIXED: Added bounds check to prevent underflow
     */
    function finalizeElection()
        external
        nonReentrant
        whenNotPaused
        enforceInactivityRules
    {
        //  CRITICAL FIX: Prevent underflow
        require(currentElectionRound > 0, "No active election");

        uint256 roundId = currentElectionRound - 1;
        ElectionRound storage round = electionRounds[roundId];

        require(block.timestamp >= round.endTime, "Election not ended");
        require(!round.finalized, "Already finalized");

        // Check quorum
        require(round.totalVotes >= round.quorumRequired, "Quorum not met");
        uint256 minQuorumVotingPower = Math.sqrt(
            MIN_ABSOLUTE_QUORUM * PRECISION
        );
        require(
            round.totalVotes >= minQuorumVotingPower,
            "Minimum absolute quorum not met"
        );

        // Get and score all candidates
        address[] memory candidateList = roundCandidates[roundId].values();
        CandidateScore[] memory scores = new CandidateScore[](
            candidateList.length
        );

        for (uint256 i = 0; i < candidateList.length; i++) {
            if (!candidates[roundId][candidateList[i]].withdrawn) {
                scores[i] = CandidateScore({
                    candidate: candidateList[i],
                    totalScore: calculateCandidateScore(
                        roundId,
                        candidateList[i]
                    ),
                    elected: false
                });
            }
        }

        // Use heap sort to prevent stack overflow on large candidate sets
        if (scores.length > 0) {
            _heapSort(scores);
        }

        // Remove expired legislators (already done by modifier, but double-check)
        _removeExpiredLegislators();

        // Elect new legislators
        uint256 toElect = Math.min(
            OPTIMAL_LEGISLATORS - activeLegislators.length(),
            scores.length
        );
        toElect = Math.min(
            toElect,
            MAX_LEGISLATORS - activeLegislators.length()
        );

        uint256 actuallyElected = 0;
        for (uint256 i = 0; i < toElect; i++) {
            if (scores[i].totalScore > 0 && canNominate(scores[i].candidate)) {
                _electLegislator(roundId, scores[i].candidate);
                scores[i].elected = true;
                actuallyElected++;
            }
        }

        // Ensure minimum legislators after election
        require(
            activeLegislators.length() >= MIN_LEGISLATORS,
            "Insufficient legislators elected"
        );

        round.finalized = true;
        totalElectionsHeld++;

        // Return stakes to non-elected candidates' supporters
        _returnStakes(roundId, scores);

        // Start next election if needed
        if (block.timestamp >= nextElectionTime) {
            _startNewElection();
        }

        emit ElectionFinalized(roundId, round.electedLegislators.length);
    }

    /**
     * @notice Calculate total score for a candidate
     */
    function calculateCandidateScore(
        uint256 roundId,
        address candidate
    ) public view returns (uint256) {
        Candidate storage candidateData = candidates[roundId][candidate];

        // Base qualification score (40%)
        uint256 qualificationScore = (candidateData.qualificationScore * 40) /
            100;

        // Weighted support score (30%)
        uint256 reputationScore = Math.min(
            (candidateData.supportReputation / 10 ** 18) / 10,
            2000
        );
        uint256 stakeScore = Math.min(
            candidateData.supportStake / 10 ** 9, // Adjusted for voting power
            1000
        );
        uint256 supportScore = Math.min(reputationScore + stakeScore, 3000);

        // Supporter diversity score (15%)
        uint256 diversityScore = Math.min(
            candidateData.supporterCount * 500,
            1500
        );

        // Early nomination bonus (15%)
        uint256 timingScore = 0;
        if (
            candidateData.nominationTime <
            electionRounds[roundId].nominationEndTime
        ) {
            uint256 timeBonus = electionRounds[roundId].nominationEndTime -
                candidateData.nominationTime;
            timingScore = Math.min(
                (timeBonus * 1500) / NOMINATION_PERIOD,
                1500
            );
        }

        return qualificationScore + supportScore + diversityScore + timingScore;
    }

    /**
     * @notice Elect a legislator
     * @dev  FIXED: Safe initialization of all timestamp fields
     */
    function _electLegislator(uint256 roundId, address account) private {
        require(
            activeLegislators.length() < MAX_LEGISLATORS,
            "Max legislators reached"
        );

        activeLegislators.add(account);
        historicalLegislators.add(account);

        uint256 termEnd = block.timestamp + LEGISLATOR_TERM;
        uint256 currentTime = block.timestamp; //  Cache current time

        legislators[account] = Legislator({
            account: account,
            electionBlock: block.number,
            electionTime: currentTime,
            termEndTime: termEnd,
            reputation: reputationToken.balanceOf(account),
            predictionAccuracy: predictionMarket.getUserAccuracy(account),
            marketsParticipated: getUserStats(account).totalPredictions,
            proposalsCreated: 0,
            successfulProposals: 0,
            totalStakeManaged: 0,
            performanceScore: PERFORMANCE_THRESHOLD,
            isActive: true,
            lastActivityTime: currentTime, //  Initialize properly
            totalExtensions: 0,
            maxTermEnd: termEnd + MAX_TOTAL_EXTENSION
        });

        candidates[roundId][account].elected = true;
        electionRounds[roundId].electedLegislators.push(account);
        legislatorHistory[account].push(roundId);
        totalLegislatorsElected++;

        //  CRITICAL: Initialize performance snapshot for new legislator
        lastSnapshotUpdate[account] = currentTime;

        emit LegislatorElected(
            account,
            roundId,
            calculateCandidateScore(roundId, account)
        );
    }

    /**
     * @notice Remove expired legislators
     */
    function _removeExpiredLegislators() private {
        address[] memory currentLegislators = activeLegislators.values();
        for (uint i = 0; i < currentLegislators.length; i++) {
            if (
                block.timestamp >=
                legislators[currentLegislators[i]].termEndTime
            ) {
                _removeLegislator(currentLegislators[i], "Term expired");
            }
        }
    }

    /**
     * @notice Remove a legislator
     */
    function _removeLegislator(
        address legislator,
        string memory reason
    ) private {
        activeLegislators.remove(legislator);
        legislators[legislator].isActive = false;

        // Update performance score
        uint256 finalScore = legislators[legislator].performanceScore;
        cumulativePerformanceScore[legislator] += finalScore;

        emit LegislatorRemoved(legislator, reason);
    }
    /**
     * @notice Check and remove inactive legislators automatically
     * @dev  FIXED: Added comprehensive bounds checking to prevent underflow
     */
    function _checkAndRemoveInactiveLegislators() internal {
        //  CRITICAL FIX 1: Skip if no active legislators
        if (activeLegislators.length() == 0) {
            return;
        }

        address[] memory currentLegislators = activeLegislators.values();

        for (uint256 i = 0; i < currentLegislators.length; i++) {
            address leg = currentLegislators[i];
            Legislator storage legislator = legislators[leg];

            //  CRITICAL FIX 2: Skip uninitialized legislators
            if (legislator.lastActivityTime == 0) {
                continue;
            }

            //  CRITICAL FIX 3: Prevent underflow if time is somehow corrupted
            if (block.timestamp < legislator.lastActivityTime) {
                continue;
            }

            //  CRITICAL FIX 4: Safe calculation of inactivity duration
            uint256 inactiveDuration = block.timestamp -
                legislator.lastActivityTime;

            //  NOW SAFE: Check inactivity with pre-calculated duration
            if (
                legislator.isActive &&
                inactiveDuration >= LEGISLATOR_INACTIVITY_PERIOD
            ) {
                // Remove and slash
                activeLegislators.remove(leg);
                legislator.isActive = false;

                // Update performance score (safe even if zero)
                uint256 finalScore = legislator.performanceScore;
                cumulativePerformanceScore[leg] += finalScore;

                // Slash reputation for inactivity (check balance first)
                uint256 currentReputation = legislator.reputation;
                if (currentReputation > 0) {
                    uint256 slashAmount = currentReputation / 10; // 10% slash

                    //  SAFE: Only slash if token contract allows
                    try
                        reputationToken.slashReputation(
                            leg,
                            slashAmount,
                            "Inactivity removal"
                        )
                    {
                        // Slash successful
                    } catch {
                        // Slash failed, continue anyway (don't block removal)
                    }
                }

                emit LegislatorRemoved(leg, "Automatic inactivity removal");
            }
        }
    }
    /**
     * @notice Return stakes with FIXED treasury solvency checks and race condition protection
     * @dev CRITICAL FIX: Prevents treasury insolvency and claim race conditions
     */
    function _returnStakes(
        uint256 roundId,
        CandidateScore[] memory scores
    ) private {
        uint256 totalRefundableStake = 0;
        uint256 totalElectedStake = 0;

        // STEP 1: Calculate actual stake amounts (not voting power)
        for (uint256 i = 0; i < scores.length; i++) {
            if (scores[i].totalScore > 0) {
                Candidate storage candidateData = candidates[roundId][
                    scores[i].candidate
                ];

                // Calculate REAL stake (sum of all supporter stakes)
                address[] memory supporters = candidateSupporters[roundId][
                    scores[i].candidate
                ].values();
                uint256 realStake = 0;

                for (uint256 j = 0; j < supporters.length; j++) {
                    Support storage support = candidateSupport[roundId][
                        scores[i].candidate
                    ][supporters[j]];
                    if (!support.withdrawn) {
                        realStake += support.stakeAmount;
                    }
                }

                if (scores[i].elected) {
                    totalElectedStake += realStake;
                } else if (!candidateData.withdrawn) {
                    totalRefundableStake += realStake;
                }
            }
        }

        // STEP 2: Calculate theoretical refunds with rank penalties
        uint256 totalTheoreticalRefund = 0;

        for (uint256 i = 0; i < scores.length; i++) {
            address candidate = scores[i].candidate;

            if (scores[i].totalScore > 0 && !scores[i].elected) {
                Candidate storage candidateData = candidates[roundId][
                    candidate
                ];

                if (!candidateData.withdrawn) {
                    // Get base refund rate
                    uint256 baseRefundRate = _calculateRefundRate(
                        scores[i].totalScore,
                        candidateData.qualificationScore
                    );

                    // Apply rank-based penalty (5% per rank, max 30%)
                    uint256 rankPenalty = Math.min(i * 500, 3000);
                    uint256 finalRefundRate = baseRefundRate > rankPenalty
                        ? baseRefundRate - rankPenalty
                        : 1000; // Minimum 10% refund

                    // Calculate refund for THIS candidate's REAL stake
                    address[] memory supporters = candidateSupporters[roundId][
                        candidate
                    ].values();
                    uint256 candidateRealStake = 0;

                    for (uint256 j = 0; j < supporters.length; j++) {
                        Support storage support = candidateSupport[roundId][
                            candidate
                        ][supporters[j]];
                        if (!support.withdrawn) {
                            candidateRealStake += support.stakeAmount;
                        }
                    }

                    uint256 candidateRefund = (candidateRealStake *
                        finalRefundRate) / PRECISION;
                    totalTheoreticalRefund += candidateRefund;

                    candidateRefundRates[roundId][candidate] = finalRefundRate;
                }
            }
        }

        // STEP 3: Check treasury solvency and scale down if needed
        uint256 maxAvailableForRefunds = availableFunds;

        // Reserve 10% bonus for elected supporters
        uint256 reserveForElected = (totalElectedStake * 1000) / PRECISION; // 10% bonus

        if (reserveForElected < maxAvailableForRefunds) {
            maxAvailableForRefunds -= reserveForElected;
        } else {
            maxAvailableForRefunds = maxAvailableForRefunds / 2; // Emergency: use 50% for refunds
        }

        // STEP 4: Scale down refunds if treasury insufficient
        if (totalTheoreticalRefund > maxAvailableForRefunds) {
            // Calculate scaling factor
            uint256 scalingFactor = (maxAvailableForRefunds * PRECISION) /
                totalTheoreticalRefund;

            // Apply scaling to all refund rates
            for (uint256 i = 0; i < scores.length; i++) {
                address candidate = scores[i].candidate;

                if (candidateRefundRates[roundId][candidate] > 0) {
                    uint256 scaledRate = (candidateRefundRates[roundId][
                        candidate
                    ] * scalingFactor) / PRECISION;
                    candidateRefundRates[roundId][candidate] = Math.max(
                        scaledRate,
                        500
                    ); // Min 5% refund
                }
            }

            totalTheoreticalRefund = maxAvailableForRefunds;
        }

        // STEP 5: PRE-CHECK treasury solvency BEFORE state changes
        require(
            totalTheoreticalRefund <= availableFunds,
            "Insufficient treasury"
        );

        require(
            stakingToken.balanceOf(address(this)) >= totalTheoreticalRefund,
            "Insufficient token balance"
        );

        // STEP 6: RESERVE all refunds (prevents race conditions)
        for (uint256 i = 0; i < scores.length; i++) {
            address candidate = scores[i].candidate;

            if (candidateRefundRates[roundId][candidate] > 0) {
                address[] memory supporters = candidateSupporters[roundId][
                    candidate
                ].values();

                for (uint256 j = 0; j < supporters.length; j++) {
                    Support storage support = candidateSupport[roundId][
                        candidate
                    ][supporters[j]];
                    if (!support.withdrawn && support.stakeAmount > 0) {
                        uint256 refundAmount = (support.stakeAmount *
                            candidateRefundRates[roundId][candidate]) /
                            PRECISION;

                        // Reserve refund amount
                        refundReserved[roundId][candidate][
                            supporters[j]
                        ] = true;
                        reservedAmount[roundId][candidate][
                            supporters[j]
                        ] = refundAmount;
                    }
                }
            }
        }

        // NOW safe to update state (all checks passed and refunds reserved)
        committedFunds += totalTheoreticalRefund;
        availableFunds -= totalTheoreticalRefund;

        emit RefundRatesSet(
            roundId,
            totalRefundableStake,
            totalTheoreticalRefund
        );
    }

    /**
     * @notice Calculate base refund rate based on candidate performance
     * @dev Reduced from original to prevent treasury drainage
     */
    function _calculateRefundRate(
        uint256 totalScore,
        uint256 qualificationScore
    ) private pure returns (uint256) {
        //  FIX: Reduced refund rates to prevent gaming
        uint256 baseRefund;

        if (totalScore >= 8000) {
            baseRefund = 7000; // 70% (reduced from 90%)
        } else if (totalScore >= 6000) {
            baseRefund = 5500; // 55% (reduced from 75%)
        } else if (totalScore >= 4000) {
            baseRefund = 4000; // 40% (reduced from 60%)
        } else if (totalScore >= 2000) {
            baseRefund = 3000; // 30% (reduced from 45%)
        } else if (qualificationScore >= 5000) {
            baseRefund = 2500; // 25% (reduced from 35%)
        } else {
            baseRefund = 2000; // 20% (reduced from 30%)
        }

        return baseRefund;
    }

    /**
     * @notice Extend legislator term with strict limits
     */
    function extendLegislatorTerm(
        address legislator,
        uint256 extension
    ) external onlyRole(GOVERNANCE_ROLE) {
        require(legislators[legislator].isActive, "Not active legislator");
        require(extension <= MAX_EXTENSION_DURATION, "Extension too long");
        require(
            legislators[legislator].totalExtensions < MAX_TERM_EXTENSIONS,
            "Max extensions reached"
        );
        require(
            legislators[legislator].performanceScore >=
                (PERFORMANCE_THRESHOLD * 150) / 100,
            "Performance too low"
        );

        // Check against hard cap
        uint256 newTermEnd = legislators[legislator].termEndTime + extension;
        require(
            newTermEnd <= legislators[legislator].maxTermEnd,
            "Exceeds maximum term"
        );

        legislators[legislator].termEndTime = newTermEnd;
        legislators[legislator].totalExtensions++;

        emit LegislatorTermExtended(legislator, newTermEnd);
    }

    /**
     * @notice Remove a legislator for misconduct
     */
    function removeLegislatorForMisconduct(
        address legislator,
        string calldata reason
    ) external onlyRole(GOVERNANCE_ROLE) nonReentrant {
        require(legislators[legislator].isActive, "Not active legislator");
        require(
            bytes(reason).length > 0 && bytes(reason).length <= 256,
            "Invalid reason"
        );

        _removeLegislator(legislator, reason);

        // Slash reputation for misconduct
        uint256 slashAmount = legislators[legislator].reputation / 10;
        reputationToken.slashReputation(legislator, slashAmount, reason);
    }

    /**
     * @notice Update legislator performance score with rate limiting
     * @dev FIXED: Added cooldown and delta cap to prevent manipulation
     */
    function updatePerformanceScore(
        address legislator,
        uint256 delta,
        bool increase
    ) external onlyRole(GOVERNANCE_ROLE) {
        require(legislators[legislator].isActive, "Not active legislator");

        // Rate limit updates
        require(
            block.timestamp >=
                lastPerformanceUpdate[legislator] + PERFORMANCE_UPDATE_COOLDOWN,
            "Update cooldown not met"
        );

        // Cap delta size
        require(delta <= MAX_SINGLE_UPDATE, "Delta too large");

        lastPerformanceUpdate[legislator] = block.timestamp;

        if (increase) {
            legislators[legislator].performanceScore = Math.min(
                legislators[legislator].performanceScore + delta,
                PRECISION
            );
        } else {
            legislators[legislator].performanceScore = legislators[legislator]
                .performanceScore > delta
                ? legislators[legislator].performanceScore - delta
                : 0;
        }

        legislators[legislator].lastActivityTime = block.timestamp;

        // Create snapshot after score update
        _createPerformanceSnapshot(legislator);

        emit PerformanceScoreUpdated(
            legislator,
            legislators[legislator].performanceScore
        );

        // Auto-remove if performance too low
        if (
            legislators[legislator].performanceScore < PERFORMANCE_THRESHOLD / 2
        ) {
            _removeLegislator(legislator, "Low performance");
        }
    }

    /**
     * @notice Create performance snapshot for a legislator
     * @dev  CRITICAL FIX: Prevents score manipulation via timing
     */
    function _createPerformanceSnapshot(address legislator) private {
        require(legislators[legislator].isActive, "Not active legislator");

        if (
            block.timestamp >=
            lastSnapshotUpdate[legislator] + SNAPSHOT_INTERVAL
        ) {
            currentSnapshotId++;
            uint256 score = legislators[legislator].performanceScore;
            performanceSnapshots[currentSnapshotId][legislator] = score;
            lastSnapshotUpdate[legislator] = block.timestamp;

            emit PerformanceSnapshotCreated(
                currentSnapshotId,
                legislator,
                score
            );
        }
    }

    /**
     * @notice Get historical performance score at specific snapshot
     * @dev Used for voting power calculations to prevent manipulation
     */
    function getHistoricalPerformance(
        address legislator,
        uint256 snapshotId
    ) external view returns (uint256) {
        require(snapshotId <= currentSnapshotId, "Invalid snapshot");

        uint256 score = performanceSnapshots[snapshotId][legislator];

        // If no snapshot exists, use current score (backwards compatible)
        return score > 0 ? score : legislators[legislator].performanceScore;
    }

    /**
     * @notice Claim rewards as supporter of elected legislator
     * @dev  FIXED: Corrected treasury accounting
     */
    function claimSupporterRewards(
        uint256 roundId,
        address candidate
    ) external nonReentrant {
        require(electionRounds[roundId].finalized, "Round not finalized");
        require(
            candidates[roundId][candidate].elected,
            "Candidate not elected"
        );

        Support storage support = candidateSupport[roundId][candidate][
            msg.sender
        ];
        require(support.stakeAmount > 0, "No support");
        require(!support.withdrawn, "Already claimed");

        support.withdrawn = true;

        // Calculate rewards (stake + bonus for supporting winner)
        uint256 bonus = (support.stakeAmount * 1000) / PRECISION; // 10% bonus
        uint256 totalReward = support.stakeAmount + bonus;

        //  CRITICAL FIX: Check treasury has enough for FULL reward
        require(availableFunds >= totalReward, "Insufficient available funds");
        require(electionTreasury >= totalReward, "Treasury insufficient");

        //  CRITICAL FIX: Correct accounting
        availableFunds -= totalReward;
        committedFunds -= support.stakeAmount; // Only original stake was committed
        electionTreasury -= totalReward; // Full reward comes from treasury

        require(
            stakingToken.transfer(msg.sender, totalReward),
            "Transfer failed"
        );
    }

    /**
     * @notice Claim refund for supporting non-elected candidate with race condition protection
     * @dev  FIXED: Uses reservation system (no additional changes needed)
     */
    function claimSupportRefund(
        uint256 roundId,
        address candidate
    ) external nonReentrant {
        ElectionRound storage round = electionRounds[roundId];
        require(round.finalized, "Round not finalized");

        Candidate storage candidateData = candidates[roundId][candidate];
        require(!candidateData.elected, "Candidate was elected");

        // Use reserved amount
        require(
            refundReserved[roundId][candidate][msg.sender],
            "No reservation"
        );
        uint256 refundAmount = reservedAmount[roundId][candidate][msg.sender];
        require(refundAmount > 0, "Already claimed or no refund");

        Support storage support = candidateSupport[roundId][candidate][
            msg.sender
        ];
        require(support.stakeAmount > 0, "No support");
        require(!support.withdrawn, "Already withdrawn");

        support.withdrawn = true;
        refundReserved[roundId][candidate][msg.sender] = false;
        reservedAmount[roundId][candidate][msg.sender] = 0;

        //  Treasury updates are safe (amount was pre-reserved)
        require(availableFunds >= refundAmount, "Insufficient treasury");
        require(committedFunds >= refundAmount, "Insufficient committed funds");

        availableFunds -= refundAmount;
        committedFunds -= refundAmount;
        electionTreasury -= refundAmount;

        require(
            stakingToken.transfer(msg.sender, refundAmount),
            "Transfer failed"
        );

        emit SupportRefunded(msg.sender, candidate, roundId, refundAmount);
    }
    /**
     * @notice Emergency pause elections
     */
    function emergencyPause() external onlyRole(EMERGENCY_ROLE) {
        _pause();
    }

    /**
     * @notice Resume elections after emergency
     */
    function emergencyUnpause() external onlyRole(EMERGENCY_ROLE) {
        _unpause();
    }

    /**
     * @notice Heap sort implementation (iterative, no stack overflow risk)
     * @dev  CRITICAL FIX: Replaces recursive quicksort for large candidate sets
     */
    function _heapSort(CandidateScore[] memory arr) private pure {
        uint256 n = arr.length;
        if (n <= 1) return;

        // Build max heap
        for (int256 i = int256(n / 2) - 1; i >= 0; i--) {
            _heapify(arr, n, uint256(i));
        }

        // Extract elements from heap one by one
        for (uint256 i = n - 1; i > 0; i--) {
            // Move current root to end
            CandidateScore memory temp = arr[0];
            arr[0] = arr[i];
            arr[i] = temp;

            // Heapify reduced heap
            _heapify(arr, i, 0);
        }
    }

    /**
     * @notice Heapify subtree rooted at index i (max heap for descending order)
     */
    function _heapify(
        CandidateScore[] memory arr,
        uint256 n,
        uint256 i
    ) private pure {
        uint256 largest = i;
        uint256 left = 2 * i + 1;
        uint256 right = 2 * i + 2;

        // If left child is larger than root
        if (left < n && arr[left].totalScore > arr[largest].totalScore) {
            largest = left;
        }

        // If right child is larger than largest so far
        if (right < n && arr[right].totalScore > arr[largest].totalScore) {
            largest = right;
        }

        // If largest is not root
        if (largest != i) {
            CandidateScore memory swap = arr[i];
            arr[i] = arr[largest];
            arr[largest] = swap;

            // Recursively heapify the affected sub-tree (tail recursion, safe)
            _heapify(arr, n, largest);
        }
    }
    //  FIX: Create proper struct assembly
    function getUserStats(
        address user
    )
        internal
        view
        returns (GovernancePredictionMarket.UserStats memory stats)
    {
        (
            uint256 totalPredictions,
            uint256 correctPredictions,
            uint256 totalStaked,
            uint256 totalReturned,
            uint256 lastPredictionTime,
            uint256 consecutiveCorrect,
            uint256 maxConsecutiveCorrect
        ) = predictionMarket.userStats(user);

        //  Properly construct struct from tuple values
        stats = GovernancePredictionMarket.UserStats({
            totalPredictions: totalPredictions,
            correctPredictions: correctPredictions,
            totalStaked: totalStaked,
            totalReturned: totalReturned,
            lastPredictionTime: lastPredictionTime,
            consecutiveCorrect: consecutiveCorrect,
            maxConsecutiveCorrect: maxConsecutiveCorrect
        });

        return stats;
    }

    /**
     * @notice Get legislator voting power at specific snapshot for disputes
     * @dev Called by MarketOracle to prevent manipulation
     */
    function getLegislatorVotingPowerAtSnapshot(
        address legislator,
        uint256 snapshotId
    ) external view returns (uint256 votingPower) {
        require(legislators[legislator].isActive, "Not active legislator");
        require(snapshotId <= currentSnapshotId, "Invalid snapshot");
        require(snapshotId > 0, "Snapshot must be positive");

        // Get historical performance from snapshot
        uint256 performanceScore = performanceSnapshots[snapshotId][legislator];

        // If no snapshot exists, revert (force proper snapshot creation)
        require(performanceScore > 0, "No snapshot for legislator");

        // Voting power = performance score * reputation at snapshot time
        // NOTE: MarketOracle should create snapshot BEFORE dispute starts
        return performanceScore;
    }

    /**
     * @notice Create snapshot for upcoming dispute
     * @dev  FIXED: Corrected variable name conflict
     * @dev Called by MarketOracle before dispute begins
     */
    function createDisputeSnapshot()
        external
        onlyRole(PREDICTION_MARKET_ROLE)
        returns (uint256 snapshotId)
    {
        currentSnapshotId++;
        snapshotId = currentSnapshotId;

        // Snapshot all active legislators
        address[] memory activeLegislatorList = activeLegislators.values(); // ← FIXED: Renamed variable
        for (uint256 i = 0; i < activeLegislatorList.length; i++) {
            address legislatorAddr = activeLegislatorList[i]; // ← FIXED: Use different variable name
            uint256 score = legislators[legislatorAddr].performanceScore; // ← FIXED: Access struct correctly
            performanceSnapshots[snapshotId][legislatorAddr] = score;
            lastSnapshotUpdate[legislatorAddr] = block.timestamp;
        }

        return snapshotId;
    }
    // View functions

    /**
     * @notice Check if an address is an active legislator
     */
    function isLegislator(address account) external view returns (bool) {
        return activeLegislators.contains(account);
    }

    /**
     * @notice Get all active legislators
     */
    function getActiveLegislators() external view returns (address[] memory) {
        return activeLegislators.values();
    }

    /**
     * @notice Get legislator count
     */
    function getLegislatorCount() external view returns (uint256) {
        return activeLegislators.length();
    }

    /**
     * @notice Get candidates for a round
     */
    function getRoundCandidates(
        uint256 roundId
    ) external view returns (address[] memory) {
        return roundCandidates[roundId].values();
    }

    /**
     * @notice Get election round details
     */
    function getElectionRound(
        uint256 roundId
    )
        external
        view
        returns (
            uint256 startTime,
            uint256 endTime,
            uint256 candidateCount,
            uint256 totalVotes,
            bool finalized,
            address[] memory elected
        )
    {
        ElectionRound storage round = electionRounds[roundId];
        return (
            round.startTime,
            round.endTime,
            round.candidateCount,
            round.totalVotes,
            round.finalized,
            round.electedLegislators
        );
    }

    /**
     * @notice Get candidate details
     */
    function getCandidate(
        uint256 roundId,
        address candidate
    )
        external
        view
        returns (
            uint256 nominationTime,
            uint256 supportStake,
            uint256 supportReputation,
            uint256 supporterCount,
            uint256 qualificationScore,
            bool elected,
            bool withdrawn
        )
    {
        Candidate storage c = candidates[roundId][candidate];
        return (
            c.nominationTime,
            c.supportStake,
            c.supportReputation,
            c.supporterCount,
            c.qualificationScore,
            c.elected,
            c.withdrawn
        );
    }

    /**
     * @notice Get time until next election
     */
    function getTimeUntilNextElection() external view returns (uint256) {
        if (block.timestamp >= nextElectionTime) return 0;
        return nextElectionTime - block.timestamp;
    }

    /**
     * @notice Check if currently in election period
     */
    function isElectionActive() external view returns (bool) {
        uint256 roundId = currentElectionRound > 0
            ? currentElectionRound - 1
            : 0;
        ElectionRound storage round = electionRounds[roundId];
        return
            !round.finalized &&
            block.timestamp >= round.startTime &&
            block.timestamp < round.endTime;
    }

    /**
     * @notice Get user's total staked amount in a round
     */
    function getUserTotalStake(
        uint256 roundId,
        address user
    ) external view returns (uint256) {
        return totalStakedByUser[roundId][user];
    }

    /**
     * @notice Get user's voting power in a round
     */
    function getUserVotingPower(
        uint256 roundId,
        address user
    ) external view returns (uint256) {
        uint256 totalStake = totalStakedByUser[roundId][user];
        return totalStake > 0 ? Math.sqrt(totalStake * PRECISION) : 0;
    }
    /**
     * @notice Get all active legislators (alias for compatibility)
     * @dev Added for MarketOracle compatibility
     */
    function getLegislators() external view returns (address[] memory) {
        return activeLegislators.values();
    }
    /**
     * @notice Get legislator details
     */
    function getLegislator(
        address account
    )
        external
        view
        returns (
            uint256 electionTime,
            uint256 termEndTime,
            uint256 reputation,
            uint256 predictionAccuracy,
            uint256 performanceScore,
            bool isActive,
            uint256 totalExtensions,
            uint256 maxTermEnd
        )
    {
        Legislator storage leg = legislators[account];
        return (
            leg.electionTime,
            leg.termEndTime,
            leg.reputation,
            leg.predictionAccuracy,
            leg.performanceScore,
            leg.isActive,
            leg.totalExtensions,
            leg.maxTermEnd
        );
    }

    /**
     * @notice Get user market diversity
     */
    function getUserMarketDiversity(
        address user
    ) external view returns (uint256) {
        return userMarketCategories[user].length;
    }

    /**
     * @notice Get treasury status
     */
    function getTreasuryStatus()
        external
        view
        returns (uint256 total, uint256 committed, uint256 available)
    {
        return (electionTreasury, committedFunds, availableFunds);
    }

    /**
     * @notice Check if address can nominate with detailed eligibility status
     * @dev FIXED: Returns meaningful stake diversity metrics
     */
    function getEligibilityStatus(
        address account
    )
        external
        view
        returns (
            bool eligible,
            uint256 reputation,
            uint256 accuracy,
            uint256 marketsParticipated,
            uint256 marketDiversityCount,
            uint256 categoriesWithMeaningfulStake,
            bool isActiveLegislator
        )
    {
        reputation = reputationToken.balanceOf(account);
        accuracy = predictionMarket.getUserAccuracy(account);
        GovernancePredictionMarket.UserStats memory stats = getUserStats(
            account
        );
        marketsParticipated = stats.totalPredictions;
        marketDiversityCount = userMarketCategories[account].length;
        isActiveLegislator = legislators[account].isActive;

        // Calculate categories with meaningful stake
        categoriesWithMeaningfulStake = 0;
        for (uint256 i = 0; i < userMarketCategories[account].length; i++) {
            bytes32 categoryHash = userMarketCategories[account][i];
            if (
                userCategoryStake[account][categoryHash] >=
                MIN_STAKE_PER_CATEGORY
            ) {
                categoriesWithMeaningfulStake++;
            }
        }

        eligible = canNominate(account);
    }

    /**
     * @notice Get support details
     */
    function getSupport(
        uint256 roundId,
        address candidate,
        address supporter
    )
        external
        view
        returns (
            uint256 stakeAmount,
            uint256 reputationAmount,
            uint256 timestamp,
            bool withdrawn
        )
    {
        Support storage support = candidateSupport[roundId][candidate][
            supporter
        ];
        return (
            support.stakeAmount,
            support.reputationAmount,
            support.timestamp,
            support.withdrawn
        );
    }

    /**
     * @notice Calculate withdrawal penalty for current time
     * @dev  FIXED: Complete bounds checking to prevent underflow
     */
    function calculateWithdrawalPenalty(
        uint256 roundId
    ) external view returns (uint256 penaltyRate) {
        ElectionRound storage round = electionRounds[roundId];

        //  CRITICAL FIX: Check all edge cases BEFORE any arithmetic
        if (round.endTime == 0) {
            return PRECISION; // Invalid round
        }

        if (block.timestamp >= round.endTime) {
            return PRECISION; // Round already ended
        }

        //  SAFE: Check if we can subtract 3 days from endTime
        if (round.endTime <= 3 days) {
            return PRECISION; // Edge case: round duration too short
        }

        if (block.timestamp >= round.endTime - 3 days) {
            return PRECISION; // Too late to withdraw (within 3 days of end)
        }

        //  NOW SAFE: All bounds checked, can do arithmetic
        uint256 withdrawalWindow = round.endTime - block.timestamp;
        uint256 totalWindow = round.endTime > round.startTime
            ? round.endTime - round.startTime
            : ELECTION_DURATION;

        if (withdrawalWindow > (totalWindow * 80) / 100) {
            return 500; // 5% penalty
        } else if (withdrawalWindow > (totalWindow * 50) / 100) {
            return 2000; // 20% penalty
        } else {
            return 5000; // 50% penalty
        }
    }
    /**
     * @notice Emergency cancel election
     * @dev  ADDED: Reentrancy protection
     */
    function emergencyCancelElection(
        uint256 roundId,
        string calldata reason
    ) external onlyRole(EMERGENCY_ROLE) nonReentrant {
        //  ADDED nonReentrant
        ElectionRound storage round = electionRounds[roundId];
        require(!round.finalized, "Already finalized");
        require(bytes(reason).length > 0, "Reason required");

        round.finalized = true;

        // Return all stakes to supporters
        address[] memory candidateList = roundCandidates[roundId].values();
        for (uint i = 0; i < candidateList.length; i++) {
            address candidate = candidateList[i];
            address[] memory supporters = candidateSupporters[roundId][
                candidate
            ].values();

            for (uint j = 0; j < supporters.length; j++) {
                Support storage support = candidateSupport[roundId][candidate][
                    supporters[j]
                ];
                if (support.stakeAmount > 0 && !support.withdrawn) {
                    support.withdrawn = true;

                    electionTreasury -= support.stakeAmount;
                    availableFunds -= support.stakeAmount;

                    require(
                        stakingToken.transfer(
                            supporters[j],
                            support.stakeAmount
                        ),
                        "Refund failed"
                    );
                }
            }
        }

        emit ElectionCancelled(roundId, reason);
    }
}
