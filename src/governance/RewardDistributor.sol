// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "../interfaces/IGovernanceTarget.sol";
import "../core/ReputationToken.sol";
import "../core/GovernancePredictionMarket.sol";
import "../interfaces/ITreasuryManager.sol";
/**
 * @title RewardDistributor
 * @notice Automated reward distribution for governance participants
 * @dev Implements multiple reward mechanisms with vesting and cliffs
 */
contract RewardDistributor is
    IGovernanceTarget,
    AccessControl,
    ReentrancyGuard,
    Pausable
{
    using SafeERC20 for IERC20;

    // Roles
    bytes32 public constant DISTRIBUTOR_ROLE = keccak256("DISTRIBUTOR_ROLE");
    bytes32 public constant UPDATER_ROLE = keccak256("UPDATER_ROLE");

    // Reward types
    enum RewardType {
        PREDICTION_ACCURACY,
        LEGISLATOR_PERFORMANCE,
        MARKET_MAKING,
        GOVERNANCE_PARTICIPATION,
        BUG_BOUNTY,
        RETROACTIVE
    }

    // Reward configuration
    struct RewardConfig {
        uint256 totalAllocation;
        uint256 distributed;
        uint256 periodDuration;
        uint256 vestingDuration;
        uint256 cliffDuration;
        bool isActive;
        address rewardToken;
    }

    // User reward info
    struct UserReward {
        uint256 earned;
        uint256 claimed;
        uint256 vesting;
        uint256 originalVesting; //  NEW
        uint256 vestingStart;
        uint256 lastClaim;
        uint256 claimable;
    }

    // Epoch info for periodic distributions
    struct Epoch {
        uint256 startTime;
        uint256 endTime;
        uint256 totalRewards;
        uint256 totalParticipants;
        bytes32 merkleRoot;
        mapping(address => uint256) rewards;
        mapping(address => bool) claimed;
    }

    // State variables
    // State variables
    mapping(RewardType => RewardConfig) public rewardConfigs;
    mapping(address => mapping(RewardType => UserReward)) public userRewards;
    mapping(uint256 => Epoch) public epochs;
    mapping(RewardType => uint256) public rewardTokenBalance; //  Track token custody
    mapping(RewardType => uint256) public lastDistributionEpoch;

    uint256 public currentEpoch;
    uint256 public epochDuration = 7 days;
    uint256 public nextEpochStart;

    // External contracts
    ReputationToken public immutable reputationToken;
    GovernancePredictionMarket public immutable predictionMarket;
    address public immutable proposalManager;
    address public treasuryManager;

    // Constants
    uint256 public constant PRECISION = 10000;
    uint256 public constant MAX_REWARD_RATE = 1000; // 10% per epoch
    uint256 public constant MIN_REPUTATION_FOR_REWARDS = 100 * 10 ** 18;

    // Governance
    bool private _governanceExecutionEnabled = true;

    // Events
    event RewardConfigured(
        RewardType rewardType,
        uint256 allocation,
        uint256 duration
    );
    event RewardEarned(
        address indexed user,
        RewardType rewardType,
        uint256 amount
    );
    event RewardClaimed(
        address indexed user,
        RewardType rewardType,
        uint256 amount
    );
    event EpochAdvanced(uint256 indexed epoch, uint256 totalRewards);
    event MerkleRootSet(uint256 indexed epoch, bytes32 merkleRoot);
    event EmergencyWithdrawal(address indexed token, uint256 amount);
    event RewardTypeFunded(
        RewardType indexed rewardType,
        uint256 amount,
        address indexed funder
    );
    constructor(
        address _reputationToken,
        address _predictionMarket,
        address _proposalManager,
        address _treasuryManager
    ) {
        require(_reputationToken != address(0), "Invalid reputation token");
        require(_predictionMarket != address(0), "Invalid prediction market");
        require(_proposalManager != address(0), "Invalid proposal manager");
        require(_treasuryManager != address(0), "Invalid treasury");

        reputationToken = ReputationToken(_reputationToken);
        predictionMarket = GovernancePredictionMarket(_predictionMarket);
        proposalManager = _proposalManager;
        treasuryManager = _treasuryManager;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(DISTRIBUTOR_ROLE, msg.sender);

        nextEpochStart = block.timestamp + epochDuration;
    }

    /**
     * @notice Configure reward type
     */
    function configureReward(
        RewardType rewardType,
        uint256 totalAllocation,
        uint256 periodDuration,
        uint256 vestingDuration,
        uint256 cliffDuration,
        address rewardToken
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(rewardToken != address(0), "Invalid token");
        require(periodDuration > 0, "Invalid period");
        require(cliffDuration <= vestingDuration, "Cliff exceeds vesting");

        rewardConfigs[rewardType] = RewardConfig({
            totalAllocation: totalAllocation,
            distributed: 0,
            periodDuration: periodDuration,
            vestingDuration: vestingDuration,
            cliffDuration: cliffDuration,
            isActive: true,
            rewardToken: rewardToken
        });

        emit RewardConfigured(rewardType, totalAllocation, periodDuration);
    }
    /**
     * @notice Fund reward type with tokens
     * @dev Transfers tokens from sender to contract and updates balance tracking
     */
    function fundRewardType(
        RewardType rewardType,
        uint256 amount
    ) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        require(amount > 0, "Invalid amount");

        RewardConfig storage config = rewardConfigs[rewardType];
        require(config.isActive, "Reward type not active");
        require(config.rewardToken != address(0), "No reward token set");

        // Transfer tokens from sender
        IERC20(config.rewardToken).safeTransferFrom(
            msg.sender,
            address(this),
            amount
        );

        // Update balance tracking
        rewardTokenBalance[rewardType] += amount;

        emit RewardTypeFunded(rewardType, amount, msg.sender);
    }
    /**
     * @notice Distribute prediction accuracy rewards
     */
    function distributePredictionRewards(
        address[] calldata users,
        uint256[] calldata accuracies,
        uint256[] calldata volumes
    ) external onlyRole(DISTRIBUTOR_ROLE) nonReentrant {
        require(users.length == accuracies.length, "Length mismatch");
        require(users.length == volumes.length, "Length mismatch");

        RewardConfig storage config = rewardConfigs[
            RewardType.PREDICTION_ACCURACY
        ];
        require(config.isActive, "Reward type not active");

        //  FIX: Prevent double distribution in same epoch
        require(
            lastDistributionEpoch[RewardType.PREDICTION_ACCURACY] <
                currentEpoch,
            "Already distributed this epoch"
        );

        uint256 epochRewards = _calculateEpochRewards(
            RewardType.PREDICTION_ACCURACY
        );

        //  FIX: Verify sufficient token balance
        require(
            rewardTokenBalance[RewardType.PREDICTION_ACCURACY] >= epochRewards,
            "Insufficient reward token balance"
        );

        uint256 totalScore = 0;

        // Calculate total score
        for (uint256 i = 0; i < users.length; i++) {
            if (
                reputationToken.balanceOf(users[i]) >=
                MIN_REPUTATION_FOR_REWARDS
            ) {
                totalScore += _calculatePredictionScore(
                    accuracies[i],
                    volumes[i]
                );
            }
        }

        require(totalScore > 0, "No eligible users");

        // Distribute rewards proportionally
        for (uint256 i = 0; i < users.length; i++) {
            address user = users[i];
            if (reputationToken.balanceOf(user) >= MIN_REPUTATION_FOR_REWARDS) {
                uint256 userScore = _calculatePredictionScore(
                    accuracies[i],
                    volumes[i]
                );
                uint256 reward = (epochRewards * userScore) / totalScore;

                if (reward > 0) {
                    _addReward(user, RewardType.PREDICTION_ACCURACY, reward);
                }
            }
        }

        config.distributed += epochRewards;

        //  FIX: Update balance tracking
        rewardTokenBalance[RewardType.PREDICTION_ACCURACY] -= epochRewards;

        //  FIX: Mark epoch as distributed
        lastDistributionEpoch[RewardType.PREDICTION_ACCURACY] = currentEpoch;
    }

    function _calculatePredictionScore(
        uint256 accuracy,
        uint256 volume
    ) private pure returns (uint256) {
        //  FIX: Require minimum volume
        if (volume < 0.1 ether) {
            return 0;
        }

        uint256 accuracyBase = Math.sqrt(accuracy * PRECISION);
        uint256 accuracyScore = (accuracyBase * accuracy) / PRECISION;

        uint256 volumeScore = _log2WithSmoothing(volume) / 1e16;

        return (accuracyScore * 7 + volumeScore * 3) / 10;
    }
    /**
     * @notice Improved log2 with better smoothing for small values
     */
    function _log2WithSmoothing(uint256 x) private pure returns (uint256) {
        if (x <= 1e18) return 0;

        uint256 result = 0;
        uint256 n = x;

        if (n >= 2 ** 128) {
            n >>= 128;
            result += 128 * 1e18;
        }
        if (n >= 2 ** 64) {
            n >>= 64;
            result += 64 * 1e18;
        }
        if (n >= 2 ** 32) {
            n >>= 32;
            result += 32 * 1e18;
        }
        if (n >= 2 ** 16) {
            n >>= 16;
            result += 16 * 1e18;
        }
        if (n >= 2 ** 8) {
            n >>= 8;
            result += 8 * 1e18;
        }
        if (n >= 2 ** 4) {
            n >>= 4;
            result += 4 * 1e18;
        }
        if (n >= 2 ** 2) {
            n >>= 2;
            result += 2 * 1e18;
        }
        if (n >= 2 ** 1) {
            result += 1 * 1e18;
        }

        return result;
    }

    /**
     * @notice Distribute legislator performance rewards
     */
    function distributeLegislatorRewards(
        address[] calldata legislators,
        uint256[] calldata performanceScores
    ) external onlyRole(DISTRIBUTOR_ROLE) nonReentrant {
        require(
            legislators.length == performanceScores.length,
            "Length mismatch"
        );

        RewardConfig storage config = rewardConfigs[
            RewardType.LEGISLATOR_PERFORMANCE
        ];
        require(config.isActive, "Reward type not active");

        //  FIX: Prevent double distribution in same epoch
        require(
            lastDistributionEpoch[RewardType.LEGISLATOR_PERFORMANCE] <
                currentEpoch,
            "Already distributed this epoch"
        );

        uint256 epochRewards = _calculateEpochRewards(
            RewardType.LEGISLATOR_PERFORMANCE
        );

        //  FIX: Verify sufficient token balance
        require(
            rewardTokenBalance[RewardType.LEGISLATOR_PERFORMANCE] >=
                epochRewards,
            "Insufficient reward token balance"
        );

        uint256 totalScore = 0;

        // Calculate total score
        for (uint256 i = 0; i < performanceScores.length; i++) {
            totalScore += performanceScores[i];
        }

        require(totalScore > 0, "No performance");

        // Distribute rewards
        for (uint256 i = 0; i < legislators.length; i++) {
            uint256 reward = (epochRewards * performanceScores[i]) / totalScore;
            if (reward > 0) {
                _addReward(
                    legislators[i],
                    RewardType.LEGISLATOR_PERFORMANCE,
                    reward
                );
            }
        }

        config.distributed += epochRewards;

        //  FIX: Update balance tracking
        rewardTokenBalance[RewardType.LEGISLATOR_PERFORMANCE] -= epochRewards;

        //  FIX: Mark epoch as distributed
        lastDistributionEpoch[RewardType.LEGISLATOR_PERFORMANCE] = currentEpoch;
    }

    /**
     * @notice Set merkle root for retroactive rewards
     */
    function setMerkleRoot(
        uint256 epoch,
        bytes32 merkleRoot,
        uint256 totalRewards
    ) external onlyRole(UPDATER_ROLE) {
        require(epoch <= currentEpoch, "Future epoch");
        require(merkleRoot != bytes32(0), "Invalid root");

        Epoch storage epochData = epochs[epoch];
        epochData.merkleRoot = merkleRoot;
        epochData.totalRewards = totalRewards;

        emit MerkleRootSet(epoch, merkleRoot);
    }

    /**
     * @notice Claim merkle-based rewards
     */
    function claimMerkleReward(
        uint256 epoch,
        uint256 amount,
        bytes32[] calldata merkleProof
    ) external nonReentrant {
        Epoch storage epochData = epochs[epoch];
        require(epochData.merkleRoot != bytes32(0), "No merkle root");
        require(!epochData.claimed[msg.sender], "Already claimed");

        // Verify merkle proof
        bytes32 leaf = keccak256(abi.encodePacked(msg.sender, amount));
        require(
            MerkleProof.verify(merkleProof, epochData.merkleRoot, leaf),
            "Invalid proof"
        );

        epochData.claimed[msg.sender] = true;
        epochData.rewards[msg.sender] = amount;

        _addReward(msg.sender, RewardType.RETROACTIVE, amount);
    }

    function _addReward(
        address user,
        RewardType rewardType,
        uint256 amount
    ) private {
        UserReward storage userReward = userRewards[user][rewardType];
        RewardConfig storage config = rewardConfigs[rewardType];

        userReward.earned += amount;

        if (config.vestingDuration > 0) {
            userReward.vesting += amount;
            userReward.originalVesting += amount; //  NEW
            if (userReward.vestingStart == 0) {
                userReward.vestingStart = block.timestamp;
            }
        } else {
            userReward.claimable += amount;
        }

        emit RewardEarned(user, rewardType, amount);
    }

    /**
     * @notice Calculate epoch rewards for a reward type
     */
    function _calculateEpochRewards(
        RewardType rewardType
    ) private view returns (uint256) {
        RewardConfig storage config = rewardConfigs[rewardType];
        uint256 remaining = config.totalAllocation - config.distributed;
        uint256 epochReward = (remaining * MAX_REWARD_RATE) / PRECISION;

        return Math.min(epochReward, remaining);
    }

    /**
     * @notice Claim available rewards
     */
    function claimRewards(
        RewardType rewardType
    ) external nonReentrant whenNotPaused {
        _updateClaimable(msg.sender, rewardType);

        UserReward storage userReward = userRewards[msg.sender][rewardType];
        uint256 claimable = userReward.claimable;

        require(claimable > 0, "Nothing to claim");

        //  FIX: Verify contract has sufficient balance
        RewardConfig storage config = rewardConfigs[rewardType];
        uint256 contractBalance = IERC20(config.rewardToken).balanceOf(
            address(this)
        );
        require(contractBalance >= claimable, "Insufficient contract balance");

        //  FIX: Update balance tracking before transfer (CEI pattern)
        rewardTokenBalance[rewardType] -= claimable;

        userReward.claimable = 0;
        userReward.claimed += claimable;
        userReward.lastClaim = block.timestamp;

        IERC20(config.rewardToken).safeTransfer(msg.sender, claimable);

        emit RewardClaimed(msg.sender, rewardType, claimable);
    }
    function _updateClaimable(address user, RewardType rewardType) private {
        UserReward storage userReward = userRewards[user][rewardType];
        RewardConfig storage config = rewardConfigs[rewardType];

        if (userReward.vesting == 0) return;

        uint256 elapsed = block.timestamp - userReward.vestingStart;

        if (elapsed < config.cliffDuration) return;

        uint256 shouldBeVested;
        if (elapsed >= config.vestingDuration) {
            shouldBeVested = userReward.originalVesting;
        } else {
            shouldBeVested =
                (userReward.originalVesting * elapsed) /
                config.vestingDuration;
        }

        uint256 alreadyMoved = userReward.originalVesting - userReward.vesting;
        uint256 newlyVested = shouldBeVested > alreadyMoved
            ? shouldBeVested - alreadyMoved
            : 0;

        if (newlyVested > userReward.vesting) {
            newlyVested = userReward.vesting;
        }

        userReward.claimable += newlyVested;
        userReward.vesting -= newlyVested;
    }
    /**
     * @notice Advance to next epoch
     */
    function advanceEpoch() external {
        require(block.timestamp >= nextEpochStart, "Too early");

        currentEpoch++;
        epochs[currentEpoch].startTime = block.timestamp;
        epochs[currentEpoch].endTime = block.timestamp + epochDuration;
        nextEpochStart = block.timestamp + epochDuration;

        // Calculate total rewards for new epoch
        uint256 totalRewards = 0;
        for (uint256 i = 0; i < uint256(RewardType.RETROACTIVE) + 1; i++) {
            RewardConfig storage config = rewardConfigs[RewardType(i)];
            if (config.isActive) {
                totalRewards += _calculateEpochRewards(RewardType(i));
            }
        }

        epochs[currentEpoch].totalRewards = totalRewards;
        emit EpochAdvanced(currentEpoch, totalRewards);
    }

    /**
     * @notice Get user's claimable rewards
     */
    function getClaimableRewards(
        address user,
        RewardType rewardType
    ) external view returns (uint256) {
        UserReward memory userReward = userRewards[user][rewardType];
        RewardConfig memory config = rewardConfigs[rewardType];

        uint256 claimable = userReward.claimable;

        if (userReward.vesting > 0) {
            uint256 elapsed = block.timestamp - userReward.vestingStart;

            if (elapsed >= config.cliffDuration) {
                uint256 vested;
                if (elapsed >= config.vestingDuration) {
                    vested = userReward.vesting;
                } else {
                    vested =
                        (userReward.vesting * elapsed) /
                        config.vestingDuration;
                }

                claimable +=
                    vested -
                    (userReward.earned -
                        userReward.vesting -
                        userReward.claimable -
                        userReward.claimed);
            }
        }

        return claimable;
    }

    /**
     * @notice Get user reward details
     */
    function getUserRewardInfo(
        address user,
        RewardType rewardType
    )
        external
        view
        returns (
            uint256 earned,
            uint256 claimed,
            uint256 vesting,
            uint256 claimable,
            uint256 vestingEnd
        )
    {
        UserReward memory userReward = userRewards[user][rewardType];
        RewardConfig memory config = rewardConfigs[rewardType];

        earned = userReward.earned;
        claimed = userReward.claimed;
        vesting = userReward.vesting;
        claimable = this.getClaimableRewards(user, rewardType);

        if (userReward.vestingStart > 0) {
            vestingEnd = userReward.vestingStart + config.vestingDuration;
        }
    }

    // IGovernanceTarget Implementation - FIXED TO MATCH INTERFACE

    /**
     * @notice Execute governance action
     */
    function executeGovernanceAction(
        bytes32 actionId,
        bytes calldata data
    ) external payable returns (bool success, bytes memory returnData) {
        require(msg.sender == proposalManager, "Not proposal manager");
        require(_governanceExecutionEnabled, "Governance disabled");

        (success, returnData) = address(this).call{value: msg.value}(data);

        emit GovernanceActionExecuted(
            actionId,
            msg.sender,
            block.timestamp,
            data,
            success
        );
    }

    /**
     * @notice Validate governance action
     */
    function validateGovernanceAction(
        bytes32 actionId,
        bytes calldata data
    ) external view returns (bool valid, string memory reason) {
        bytes4 selector = bytes4(data[:4]);
        bytes4[] memory allowed = governanceAllowedSelectors();

        for (uint256 i = 0; i < allowed.length; i++) {
            if (allowed[i] == selector) {
                return (true, "");
            }
        }

        return (false, "Selector not allowed");
    }

    /**
     * @notice Check if authorized governance
     */
    function isAuthorizedGovernance(
        address executor
    ) external view returns (bool) {
        return executor == proposalManager;
    }

    /**
     * @notice Emergency pause
     */
    function emergencyPause() external {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "Not admin");
        _pause();
    }

    /**
     * @notice Emergency unpause
     */
    function emergencyUnpause() external {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "Not admin");
        _unpause();
    }

    /**
     * @notice Get governance parameters
     */
    function getGovernanceParameters() external view returns (bytes memory) {
        return
            abi.encode(
                _governanceExecutionEnabled,
                epochDuration,
                currentEpoch,
                nextEpochStart
            );
    }

    /**
     * @notice Update governance parameters
     */
    function updateGovernanceParameters(bytes calldata params) external {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "Not admin");

        (bool enabled, uint256 duration, , ) = abi.decode(
            params,
            (bool, uint256, uint256, uint256)
        );

        _governanceExecutionEnabled = enabled;
        if (duration >= 1 days && duration <= 30 days) {
            epochDuration = duration;
        }
    }

    /**
     * @notice Get allowed governance selectors
     */
    function governanceAllowedSelectors()
        public
        pure
        returns (bytes4[] memory)
    {
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = this.configureReward.selector;
        selectors[1] = this.setEpochDuration.selector;
        selectors[2] = this.updateTreasuryManager.selector;
        return selectors;
    }

    /**
     * @notice Emergency token recovery
     */
    function emergencyTokenRecovery(
        address token,
        address to,
        uint256 amount
    ) external {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "Not admin");

        if (token == address(0)) {
            (bool success, ) = payable(to).call{value: amount}("");
            require(success, "ETH transfer failed");
        } else {
            IERC20(token).safeTransfer(to, amount);
        }

        emit EmergencyWithdrawal(token, amount);
    }

    /**
     * @notice Set epoch duration
     */
    function setEpochDuration(
        uint256 duration
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(duration >= 1 days && duration <= 30 days, "Invalid duration");
        epochDuration = duration;
    }

    /**
     * @notice Update treasury manager
     */
    function updateTreasuryManager(
        address newTreasury
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newTreasury != address(0), "Invalid treasury");
        treasuryManager = newTreasury;
    }

    function pullRewardsFromTreasury(
        address token,
        uint256 amount,
        RewardType rewardType //  ADD parameter
    ) external onlyRole(DISTRIBUTOR_ROLE) nonReentrant {
        require(treasuryManager != address(0), "No treasury set");
        require(token != address(0), "Invalid token");
        require(amount > 0, "Invalid amount");

        RewardConfig storage config = rewardConfigs[rewardType];
        require(config.isActive, "Reward type not active");
        require(config.rewardToken == token, "Token mismatch");
        require(treasuryManager.code.length > 0, "Treasury must be contract");

        uint256 initialBalance = IERC20(token).balanceOf(address(this));

        try
            ITreasuryManager(treasuryManager).transferTo(
                token,
                address(this),
                amount
            )
        returns (bool success) {
            require(success, "Treasury transfer returned false");
        } catch Error(string memory reason) {
            revert(
                string(abi.encodePacked("Treasury transfer failed: ", reason))
            );
        } catch {
            revert("Treasury transfer failed with unknown error");
        }

        uint256 finalBalance = IERC20(token).balanceOf(address(this));
        uint256 received = finalBalance - initialBalance;
        require(received >= amount, "Insufficient tokens received");

        //  FIX: Update balance tracking
        rewardTokenBalance[rewardType] += received;
    }
}
