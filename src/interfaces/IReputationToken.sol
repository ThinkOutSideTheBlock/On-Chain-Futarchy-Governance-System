// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IReputationToken
 * @notice Interface for the non-transferable reputation token system
 */
interface IReputationToken is IERC20 {
    // Structs
    struct ReputationData {
        uint256 baseReputation;
        uint256 earnedReputation;
        uint256 lastActivityTime;
        uint256 totalMinted;
        uint256 totalSlashed;
        uint256 activityScore;
    }

    struct SlashingEvent {
        uint256 amount;
        string reason;
        uint256 timestamp;
        address slasher;
    }

    // Events
    event ReputationMinted(
        address indexed user,
        uint256 amount,
        uint256 accuracy,
        uint256 newBalance
    );

    event ReputationSlashed(
        address indexed user,
        uint256 amount,
        string reason,
        address indexed slasher
    );

    event ReputationDecayed(
        address indexed user,
        uint256 decayAmount,
        uint256 newBalance
    );

    event UserBlacklisted(address indexed user, string reason);
    event UserWhitelisted(address indexed user);
    event InitialReputationGranted(address indexed user, uint256 amount);

    // Core Functions
    function grantInitialReputation(address to) external;

    function mintReputation(
        address to,
        uint256 amount,
        uint256 accuracy
    ) external;

    function slashReputation(
        address account,
        uint256 amount,
        string calldata reason
    ) external;

    function applyDecay(address account) external;

    // Admin Functions
    function blacklistUser(address user, string calldata reason) external;
    function whitelistUser(address user) external;
    function pause() external;
    function unpause() external;

    // View Functions
    function reputationData(
        address user
    )
        external
        view
        returns (
            uint256 baseReputation,
            uint256 earnedReputation,
            uint256 lastActivityTime,
            uint256 totalMinted,
            uint256 totalSlashed,
            uint256 activityScore
        );

    function blacklisted(address user) external view returns (bool);

    function getReputationData(
        address user
    )
        external
        view
        returns (
            uint256 balance,
            uint256 baseReputation,
            uint256 earnedReputation,
            uint256 lastActivityTime,
            uint256 totalMinted,
            uint256 totalSlashed,
            bool isBlacklisted
        );

    function getSlashingHistory(
        address user
    ) external view returns (SlashingEvent[] memory);
    function calculateDecay(address user) external view returns (uint256);

    // Constants
    function DECAY_PERIOD() external view returns (uint256);
    function DECAY_RATE() external view returns (uint256);
    function MIN_ACTIVITY_THRESHOLD() external view returns (uint256);
    function MAX_DECAY_RATE() external view returns (uint256);
    function INITIAL_REPUTATION() external view returns (uint256);
    function MAX_REPUTATION_CAP() external view returns (uint256);
    function ACCURACY_THRESHOLD() external view returns (uint256);
    function PRECISION() external view returns (uint256);

    // Global Stats
    function totalReputationMinted() external view returns (uint256);
    function totalReputationSlashed() external view returns (uint256);
    function totalActiveUsers() external view returns (uint256);

    // Roles
    function MINTER_ROLE() external view returns (bytes32);
    function SLASHER_ROLE() external view returns (bytes32);
}
