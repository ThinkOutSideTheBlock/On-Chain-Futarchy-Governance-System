// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;
/**
 * @title ILegislatorElection
 * @notice Interface for the legislator election system
 */
interface ILegislatorElection {
    // Structs
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
    }

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

    struct Support {
        uint256 stakeAmount;
        uint256 reputationAmount;
        uint256 timestamp;
        bool withdrawn;
    }

    // Events
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
    event SupportRefunded(
        address indexed supporter,
        address indexed candidate,
        uint256 roundId,
        uint256 amount
    );

    // Core Functions
    function nominateForLegislator() external;
    function supportCandidate(
        address candidate,
        uint256 stakeAmount,
        uint256 reputationPercentage
    ) external;
    function withdrawSupport(address candidate) external;
    function finalizeElection() external;

    // Admin Functions
    function removeLegislatorForMisconduct(
        address legislator,
        string calldata reason
    ) external;
    function updatePerformanceScore(
        address legislator,
        uint256 delta,
        bool increase
    ) external;
    function extendLegislatorTerm(
        address legislator,
        uint256 extension
    ) external;
    function emergencyPause() external;
    function emergencyUnpause() external;

    // Claim Functions
    function claimSupporterRewards(uint256 roundId, address candidate) external;
    function claimSupportRefund(uint256 roundId, address candidate) external;

    // View Functions
    function isLegislator(address account) external view returns (bool);
    function canNominate(address account) external view returns (bool);
    function calculateQualificationScore(
        address candidate
    ) external view returns (uint256);
    function calculateCandidateScore(
        uint256 roundId,
        address candidate
    ) external view returns (uint256);

    function getActiveLegislators() external view returns (address[] memory);
    function getLegislatorCount() external view returns (uint256);
    function getRoundCandidates(
        uint256 roundId
    ) external view returns (address[] memory);

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
        );

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
        );

    function getLegislatorDetails(
        address legislator
    )
        external
        view
        returns (
            bool isActive,
            uint256 electionTime,
            uint256 termEndTime,
            uint256 reputation,
            uint256 accuracy,
            uint256 performanceScore,
            uint256 proposalsCreated,
            uint256 successfulProposals
        );

    function getTimeUntilNextElection() external view returns (uint256);
    function isElectionActive() external view returns (bool);

    // State Variables
    function legislators(
        address
    )
        external
        view
        returns (
            address account,
            uint256 electionBlock,
            uint256 electionTime,
            uint256 termEndTime,
            uint256 reputation,
            uint256 predictionAccuracy,
            uint256 marketsParticipated,
            uint256 proposalsCreated,
            uint256 successfulProposals,
            uint256 totalStakeManaged,
            uint256 performanceScore,
            bool isActive,
            uint256 lastActivityTime
        );

    function electionRounds(
        uint256
    )
        external
        view
        returns (
            uint256 roundId,
            uint256 startTime,
            uint256 endTime,
            uint256 nominationEndTime,
            uint256 candidateCount,
            uint256 totalVotes,
            uint256 quorumRequired,
            bool finalized
        );

    function candidates(
        uint256,
        address
    )
        external
        view
        returns (
            address account,
            uint256 nominationTime,
            uint256 supportStake,
            uint256 supportReputation,
            uint256 supporterCount,
            uint256 qualificationScore,
            bool elected,
            bool withdrawn
        );

    function candidateSupport(
        uint256,
        address,
        address
    )
        external
        view
        returns (
            uint256 stakeAmount,
            uint256 reputationAmount,
            uint256 timestamp,
            bool withdrawn
        );

    function candidateRefundRates(
        uint256,
        address
    ) external view returns (uint256);

    // Constants
    function ELECTION_DURATION() external view returns (uint256);
    function NOMINATION_PERIOD() external view returns (uint256);
    function LEGISLATOR_TERM() external view returns (uint256);
    function COOLDOWN_PERIOD() external view returns (uint256);
    function MAX_LEGISLATORS() external view returns (uint256);
    function MIN_LEGISLATORS() external view returns (uint256);
    function OPTIMAL_LEGISLATORS() external view returns (uint256);
    function MIN_REPUTATION_FOR_CANDIDACY() external view returns (uint256);
    function MIN_ACCURACY_FOR_CANDIDACY() external view returns (uint256);
    function MIN_MARKETS_PARTICIPATED() external view returns (uint256);
    function MIN_SUPPORT_STAKE() external view returns (uint256);
    function QUORUM_PERCENTAGE() external view returns (uint256);
    function PERFORMANCE_THRESHOLD() external view returns (uint256);
    function PRECISION() external view returns (uint256);

    // Current State
    function currentElectionRound() external view returns (uint256);
    function nextElectionTime() external view returns (uint256);
    function totalElectionsHeld() external view returns (uint256);
    function totalLegislatorsElected() external view returns (uint256);
    function electionTreasury() external view returns (uint256);

    // Roles
    function GOVERNANCE_ROLE() external view returns (bytes32);
    function EMERGENCY_ROLE() external view returns (bytes32);
}
