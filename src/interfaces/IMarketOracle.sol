// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;
/**
 * @title IMarketOracle
 * @notice Interface for the decentralized market oracle system
 */
interface IMarketOracle {
    // Enums
    enum ResolutionStatus {
        PENDING,
        APPROVED,
        REJECTED,
        DISPUTED,
        FINALIZED
    }

    enum DisputeStatus {
        ACTIVE,
        UPHELD,
        OVERTURNED,
        WITHDRAWN
    }

    enum OracleType {
        CHAINLINK_PRICE,
        CHAINLINK_VRF,
        LEGISLATOR_VOTE,
        EXTERNAL_API,
        MANUAL
    }

    // Structs
    struct Resolution {
        uint256 marketId;
        uint8 proposedOutcome;
        address proposer;
        uint256 proposalTime;
        uint256 supportStake;
        uint256 oppositionStake;
        uint256 supporterCount;
        uint256 opposerCount;
        uint256 legislatorSupport;
        uint256 legislatorOpposition;
        bool finalized;
        bool disputed;
        string evidenceURI;
        bytes32 evidenceHash;
        ResolutionStatus status;
    }

    struct Dispute {
        uint256 resolutionId;
        address challenger;
        uint8 challengedOutcome;
        uint256 challengeStake;
        uint256 challengeTime;
        uint256 supportStake;
        uint256 supporterCount;
        DisputeStatus status;
        string evidenceURI;
        bytes32 evidenceHash;
    }

    struct OracleSource {
        OracleType oracleType;
        address dataFeed;
        uint256 lastUpdate;
        uint256 reliability;
        bool isActive;
    }

    struct Stake {
        uint256 amount;
        uint256 timestamp;
        bool withdrawn;
    }

    // Events
    event ResolutionProposed(
        uint256 indexed marketId,
        uint8 outcome,
        address proposer,
        uint256 stake
    );
    event ResolutionSupported(
        uint256 indexed marketId,
        address supporter,
        uint256 amount
    );
    event ResolutionOpposed(
        uint256 indexed marketId,
        address opposer,
        uint256 amount
    );
    event ResolutionDisputed(
        uint256 indexed marketId,
        uint256 disputeId,
        address challenger,
        uint8 outcome
    );
    event ResolutionFinalized(
        uint256 indexed marketId,
        uint8 outcome,
        uint256 totalStake
    );
    event LegislatorVoted(
        uint256 indexed marketId,
        address legislator,
        bool support
    );
    event DisputeResolved(
        uint256 indexed marketId,
        uint256 disputeId,
        DisputeStatus status
    );
    event OracleSourceAdded(
        uint256 indexed marketId,
        OracleType oracleType,
        address dataFeed
    );
    event ResolutionRejected(
        uint256 indexed marketId,
        uint256 slashAmount,
        uint256 rewardPool
    );
    event RewardClaimed(
        address indexed user,
        uint256 indexed marketId,
        uint256 amount
    );
    event OppositionRewardClaimed(
        address indexed user,
        uint256 indexed marketId,
        uint256 amount
    );
    event DisputeRewardClaimed(
        address indexed user,
        uint256 indexed marketId,
        uint256 disputeId,
        uint256 amount
    );

    // Core Functions
    function proposeResolution(
        uint256 marketId,
        uint8 outcome,
        string calldata evidenceURI,
        bytes32 evidenceHash
    ) external payable;

    function supportResolution(uint256 marketId) external payable;
    function opposeResolution(uint256 marketId) external payable;
    function legislatorVote(uint256 marketId, bool support) external;

    function disputeResolution(
        uint256 marketId,
        uint8 alternativeOutcome,
        string calldata evidenceURI,
        bytes32 evidenceHash
    ) external payable;

    function finalizeResolution(uint256 marketId) external;

    // Admin Functions
    function addOracleSource(
        uint256 marketId,
        OracleType oracleType,
        address dataFeed
    ) external;
    function emergencyPause() external;
    function emergencyUnpause() external;

    // Claim Functions
    function claimResolutionReward(uint256 marketId) external;
    function claimOppositionReward(uint256 marketId) external;
    function claimDisputeReward(uint256 marketId, uint256 disputeId) external;

    // View Functions
    function getResolution(
        uint256 marketId
    )
        external
        view
        returns (
            uint8 proposedOutcome,
            address proposer,
            uint256 proposalTime,
            uint256 supportStake,
            uint256 oppositionStake,
            ResolutionStatus status,
            bool finalized
        );

    function getDispute(
        uint256 marketId,
        uint256 disputeId
    )
        external
        view
        returns (
            address challenger,
            uint8 challengedOutcome,
            uint256 challengeStake,
            uint256 supportStake,
            DisputeStatus status
        );

    function getDisputeCount(uint256 marketId) external view returns (uint256);

    // State Variables
    function resolutions(
        uint256
    )
        external
        view
        returns (
            uint256 marketId,
            uint8 proposedOutcome,
            address proposer,
            uint256 proposalTime,
            uint256 supportStake,
            uint256 oppositionStake,
            uint256 supporterCount,
            uint256 opposerCount,
            uint256 legislatorSupport,
            uint256 legislatorOpposition,
            bool finalized,
            bool disputed,
            string memory evidenceURI,
            bytes32 evidenceHash,
            ResolutionStatus status
        );

    function marketResolved(uint256) external view returns (bool);
    function marketResolutionTime(uint256) external view returns (uint256);
    function supporterRewardRates(uint256) external view returns (uint256);
    function oppositionRewardRates(uint256) external view returns (uint256);
    function disputeRewardRates(
        uint256,
        uint256
    ) external view returns (uint256);

    function resolutionSupport(
        uint256,
        address
    ) external view returns (uint256 amount, uint256 timestamp, bool withdrawn);

    function resolutionOpposition(
        uint256,
        address
    ) external view returns (uint256 amount, uint256 timestamp, bool withdrawn);

    function disputeSupport(
        uint256,
        uint256,
        address
    ) external view returns (uint256 amount, uint256 timestamp, bool withdrawn);

    function legislatorVotes(uint256, address) external view returns (bool);
    function hasVoted(uint256, address) external view returns (bool);
    function trustedDataFeeds(address) external view returns (bool);

    // Constants
    function RESOLUTION_PERIOD() external view returns (uint256);
    function DISPUTE_PERIOD() external view returns (uint256);
    function ESCALATION_PERIOD() external view returns (uint256);
    function MIN_STAKE_FOR_RESOLUTION() external view returns (uint256);
    function MIN_STAKE_FOR_DISPUTE() external view returns (uint256);
    function LEGISLATOR_QUORUM() external view returns (uint256);
    function STAKE_QUORUM() external view returns (uint256);
    function DISPUTE_BOND_MULTIPLIER() external view returns (uint256);
    function PRECISION() external view returns (uint256);

    // Treasury and Stats
    function resolutionTreasury() external view returns (uint256);
    function totalStakeSlashed() external view returns (uint256);
    function totalResolutions() external view returns (uint256);
    function totalDisputes() external view returns (uint256);
    function successfulResolutions() external view returns (uint256);
    function overturnedResolutions() external view returns (uint256);
    function protocolFeeAccumulated() external view returns (uint256);

    // Roles
    function ORACLE_OPERATOR_ROLE() external view returns (bytes32);
    function EMERGENCY_ROLE() external view returns (bytes32);
    function CHAINLINK_ROLE() external view returns (bytes32);
}
