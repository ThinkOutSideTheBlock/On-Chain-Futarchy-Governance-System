// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface IReputationLockManager {
    function onReputationSlashed(address user, uint256 amount) external;
    function getLockedReputation(
        address user
    ) external returns (uint256 locked);
}

/**
 * @title ReputationToken
 * @notice Non-transferable reputation token that tracks prediction accuracy
 * @dev Production-ready implementation with comprehensive vulnerability fixes
 * @custom:security-contact security@example.com
 */
contract ReputationToken is ERC20, AccessControl, Pausable, ReentrancyGuard {
    using Math for uint256;

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant SLASHER_ROLE = keccak256("SLASHER_ROLE");
    bytes32 public constant INITIALIZER_ROLE = keccak256("INITIALIZER_ROLE");

    uint256 public constant DECAY_PERIOD = 30 days;
    uint256 public constant DECAY_RATE = 100;
    uint256 public constant MIN_ACTIVITY_THRESHOLD = 90 days;
    uint256 public constant MAX_DECAY_RATE = 5000;

    uint256 public constant INITIAL_REPUTATION = 100 * 10 ** 18;
    uint256 public constant MAX_REPUTATION_CAP = 1000000 * 10 ** 18;
    uint256 public constant ACCURACY_THRESHOLD = 2000;
    uint256 public constant PRECISION = 10000;

    uint256 public constant MIN_PROTECTION_RATE = 2500;
    uint256 public constant MAX_SLASHING_RATE = 7500;

    struct ReputationData {
        uint256 baseReputation;
        uint256 earnedReputation;
        uint256 lastActivityTime;
        uint256 lastDecayTime;
        uint256 totalMinted;
        uint256 totalSlashed;
        uint256 decayCheckpoint;
    }

    struct SlashingEvent {
        uint256 amount;
        string reason;
        uint256 timestamp;
        address slasher;
    }

    struct BlacklistData {
        bool isBlacklisted;
        uint256 blacklistedBalance;
        uint256 blacklistTimestamp;
        string reason;
    }

    mapping(address => ReputationData) public reputationData;
    mapping(address => SlashingEvent[]) public slashingHistory;
    mapping(address => BlacklistData) public blacklistData;

    uint256 public totalReputationMinted;
    uint256 public totalReputationSlashed;
    uint256 public totalActiveUsers;
    uint256 public globalDecayCheckpoint;

    IReputationLockManager public lockManager;
    bool public lockManagerEnabled;

    mapping(address => uint256) private _lastGrantTime;
    uint256 private _lastGlobalGrantTime; // Global cooldown for sybil protection
    uint256 private _grantsInCurrentBlock; // Track grants per block for rate limiting

    event ReputationMinted(
        address indexed user,
        uint256 amount,
        uint256 accuracy,
        uint256 newBalance
    );
    event LockManagerSet(address indexed lockManager);
    event LockManagerDisabled();
    event SlashNotificationFailed(
        address indexed user,
        uint256 amount,
        string reason
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
    event UserBlacklisted(address indexed user, string reason, uint256 balance);
    event UserWhitelisted(address indexed user, uint256 restoredBalance);
    event InitialReputationGranted(address indexed user, uint256 amount);

    constructor() ERC20("Governance Reputation", "gREP") {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);
        globalDecayCheckpoint = block.timestamp;
    }

    function setLockManager(
        address _lockManager
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_lockManager != address(0), "Invalid lock manager address");
        lockManager = IReputationLockManager(_lockManager);
        lockManagerEnabled = true;
        emit LockManagerSet(_lockManager);
    }

    function disableLockManager() external onlyRole(DEFAULT_ADMIN_ROLE) {
        lockManagerEnabled = false;
        emit LockManagerDisabled();
    }

    function balanceOf(address account) public view override returns (uint256) {
        BlacklistData memory blacklist = blacklistData[account];
        if (blacklist.isBlacklisted) return 0;

        ReputationData memory data = reputationData[account];
        uint256 totalRep = data.baseReputation + data.earnedReputation;

        if (totalRep == 0) return 0;

        if (block.timestamp <= data.lastActivityTime + MIN_ACTIVITY_THRESHOLD) {
            return totalRep;
        }

        uint256 decayStartTime = Math.max(
            data.lastDecayTime,
            data.lastActivityTime + MIN_ACTIVITY_THRESHOLD
        );

        if (block.timestamp <= decayStartTime) {
            return totalRep;
        }

        uint256 timeSinceDecayStart = block.timestamp - decayStartTime;
        uint256 decayPeriods = (timeSinceDecayStart * PRECISION) / DECAY_PERIOD;

        if (decayPeriods == 0) return totalRep;

        uint256 effectiveDecayRate = Math.min(
            (DECAY_RATE * decayPeriods) / PRECISION,
            MAX_DECAY_RATE
        );

        uint256 decayAmount = Math.mulDiv(
            totalRep,
            effectiveDecayRate,
            PRECISION
        );

        uint256 minReputation = Math.max(
            data.baseReputation / 4,
            (totalRep * MIN_PROTECTION_RATE) / PRECISION
        );

        uint256 finalReputation = totalRep > decayAmount
            ? totalRep - decayAmount
            : minReputation;

        return Math.max(finalReputation, minReputation);
    }

    function totalSupply() public view override returns (uint256) {
        return super.totalSupply();
    }

    function grantInitialReputation(
        address to
    ) external onlyRole(INITIALIZER_ROLE) nonReentrant {
        require(to != address(0), "Invalid address");
        require(!blacklistData[to].isBlacklisted, "User blacklisted");
        require(reputationData[to].baseReputation == 0, "Already initialized");

        // FIXED: Block-based rate limiting instead of time-based
        // Allow multiple grants in same block (for batch setup), but limit rate across blocks
        if (block.number > _lastGlobalGrantTime) {
            // New block - reset counter
            _grantsInCurrentBlock = 0;
            _lastGlobalGrantTime = block.number;
        }

        // Limit to reasonable number of grants per block (prevents spam, allows legitimate batch)
        require(_grantsInCurrentBlock < 50, "Grant rate limit exceeded");
        _grantsInCurrentBlock++;

        // Per-user cooldown check (prevents re-initialization attempts)
        if (_lastGrantTime[to] > 0) {
            require(
                block.timestamp >= _lastGrantTime[to] + 10 minutes,
                "Grant cooldown active"
            );
        }

        _lastGrantTime[to] = block.timestamp; // Store timestamp for this user

        reputationData[to] = ReputationData({
            baseReputation: INITIAL_REPUTATION,
            earnedReputation: 0,
            lastActivityTime: block.timestamp,
            lastDecayTime: block.timestamp,
            totalMinted: INITIAL_REPUTATION,
            totalSlashed: 0,
            decayCheckpoint: INITIAL_REPUTATION
        });

        _mint(to, INITIAL_REPUTATION);

        totalActiveUsers++;
        totalReputationMinted += INITIAL_REPUTATION;

        emit InitialReputationGranted(to, INITIAL_REPUTATION);
    }
    function mintReputation(
        address to,
        uint256 amount,
        uint256 accuracy
    ) external onlyRole(MINTER_ROLE) whenNotPaused nonReentrant {
        require(to != address(0), "Invalid address");
        require(!blacklistData[to].isBlacklisted, "User blacklisted");
        require(accuracy <= PRECISION, "Invalid accuracy");
        require(accuracy >= ACCURACY_THRESHOLD, "Accuracy too low");
        require(amount > 0, "Amount must be positive");
        require(reputationData[to].baseReputation > 0, "User not initialized");

        _applyDecayInternalForMint(to);

        uint256 currentTokenBalance = super.balanceOf(to);

        uint256 finalAmount = _calculateBondingCurveSafe(amount, accuracy);

        require(
            currentTokenBalance + finalAmount <= MAX_REPUTATION_CAP,
            "Exceeds reputation cap"
        );

        ReputationData storage data = reputationData[to];
        data.earnedReputation += finalAmount;
        data.lastActivityTime = block.timestamp;
        data.totalMinted += finalAmount;

        data.decayCheckpoint = currentTokenBalance + finalAmount;

        _mint(to, finalAmount);

        totalReputationMinted += finalAmount;

        emit ReputationMinted(to, finalAmount, accuracy, super.balanceOf(to));
    }

    function applyDecay(address account) external nonReentrant {
        require(account != address(0), "Invalid address");
        require(
            !blacklistData[account].isBlacklisted,
            "Cannot decay blacklisted user"
        );

        ReputationData storage data = reputationData[account];

        require(
            block.timestamp >= data.lastDecayTime + 1 hours,
            "Decay cooldown active"
        );

        _applyDecayInternalLogic(account);
    }

    function _applyDecayInternalForMint(address account) private {
        uint256 currentCalculatedBalance = balanceOf(account);
        uint256 currentTokenBalance = super.balanceOf(account);

        if (currentCalculatedBalance < currentTokenBalance) {
            uint256 decayAmount = currentTokenBalance -
                currentCalculatedBalance;

            ReputationData storage data = reputationData[account];

            if (data.earnedReputation >= decayAmount) {
                data.earnedReputation -= decayAmount;
            } else {
                uint256 remainingDecay = decayAmount - data.earnedReputation;
                data.earnedReputation = 0;

                uint256 minBaseProtection = data.baseReputation / 4;
                uint256 newBaseRep = data.baseReputation > remainingDecay
                    ? data.baseReputation - remainingDecay
                    : minBaseProtection;

                data.baseReputation = Math.max(newBaseRep, minBaseProtection);
            }

            data.lastDecayTime = block.timestamp;
            data.decayCheckpoint = currentCalculatedBalance;

            _burn(account, decayAmount);

            emit ReputationDecayed(
                account,
                decayAmount,
                currentCalculatedBalance
            );
        } else {
            ReputationData storage data = reputationData[account];
            data.lastDecayTime = block.timestamp;
        }
    }

    function _applyDecayInternalLogic(address account) private {
        uint256 currentCalculatedBalance = balanceOf(account);
        uint256 currentTokenBalance = super.balanceOf(account);

        if (currentCalculatedBalance < currentTokenBalance) {
            uint256 decayAmount = currentTokenBalance -
                currentCalculatedBalance;

            ReputationData storage data = reputationData[account];

            if (data.earnedReputation >= decayAmount) {
                data.earnedReputation -= decayAmount;
            } else {
                uint256 remainingDecay = decayAmount - data.earnedReputation;
                data.earnedReputation = 0;

                uint256 minBaseProtection = data.baseReputation / 4;
                uint256 newBaseRep = data.baseReputation > remainingDecay
                    ? data.baseReputation - remainingDecay
                    : minBaseProtection;

                data.baseReputation = Math.max(newBaseRep, minBaseProtection);
            }

            data.lastDecayTime = block.timestamp;
            data.decayCheckpoint = currentCalculatedBalance;
            data.lastActivityTime = block.timestamp;

            _burn(account, decayAmount);

            emit ReputationDecayed(
                account,
                decayAmount,
                currentCalculatedBalance
            );
        } else {
            ReputationData storage data = reputationData[account];
            data.lastDecayTime = block.timestamp;
            data.lastActivityTime = block.timestamp;
        }
    }

    function getActualAvailableReputation(
        address account
    ) external nonReentrant returns (uint256 available) {
        if (
            block.timestamp >= reputationData[account].lastDecayTime + 1 hours
        ) {
            _applyDecayInternalLogic(account);
        }

        uint256 currentBalance = super.balanceOf(account);

        if (lockManagerEnabled && address(lockManager) != address(0)) {
            try
                IReputationLockManager(lockManager).getLockedReputation(account)
            returns (uint256 locked) {
                available = currentBalance > locked
                    ? currentBalance - locked
                    : 0;
            } catch {
                available = currentBalance;
            }
        } else {
            available = currentBalance;
        }

        return available;
    }

    function slashReputation(
        address account,
        uint256 amount,
        string calldata reason
    ) external onlyRole(SLASHER_ROLE) nonReentrant {
        require(account != address(0), "Invalid address");
        require(
            bytes(reason).length > 0 && bytes(reason).length <= 256,
            "Invalid reason"
        );
        require(amount > 0, "Amount must be positive");
        require(
            !blacklistData[account].isBlacklisted,
            "Cannot slash blacklisted user"
        );

        uint256 currentBalance = super.balanceOf(account);
        require(currentBalance > 0, "No reputation to slash");

        // Calculate protected amount (25% of current balance)
        uint256 protectedAmount = (currentBalance * MIN_PROTECTION_RATE) /
            PRECISION;

        // Calculate buffer (5% of protected amount)
        uint256 buffer = protectedAmount / 20;
        uint256 minimumThreshold = protectedAmount + buffer;

        // Calculate slashable balance
        uint256 slashableBalance = currentBalance - protectedAmount;

        // Calculate maximum single slash (75% of slashable balance)
        uint256 maxSingleSlash = (slashableBalance * MAX_SLASHING_RATE) /
            PRECISION;

        // Calculate minimum slash threshold (1% of slashable balance)
        uint256 minSlashAmount = slashableBalance / 100;

        //  FIX: Check if there's enough room to slash even the minimum amount
        // After slashing minSlashAmount, balance should still be >= minimumThreshold
        uint256 balanceAfterMinSlash = currentBalance - minSlashAmount;
        if (balanceAfterMinSlash < minimumThreshold) {
            revert("Insufficient slashable balance");
        }

        //  FIX: Check if maxSingleSlash meets minimum threshold
        if (maxSingleSlash < minSlashAmount) {
            revert("Insufficient slashable balance");
        }

        // Determine actual slash amount
        uint256 actualSlashAmount;

        if (amount >= maxSingleSlash) {
            actualSlashAmount = maxSingleSlash;
        } else if (amount >= minSlashAmount) {
            actualSlashAmount = amount;
        } else {
            // Amount is below minimum, but check if we even have enough slashable balance
            revert("Insufficient slashable balance");
        }

        require(actualSlashAmount > 0, "Calculated slash amount is zero");

        // Final balance check
        uint256 finalBalance = currentBalance - actualSlashAmount;
        require(
            finalBalance >= minimumThreshold,
            "Insufficient slashable balance"
        );

        // Update reputation data
        ReputationData storage data = reputationData[account];

        if (data.earnedReputation >= actualSlashAmount) {
            data.earnedReputation -= actualSlashAmount;
        } else {
            uint256 remainingSlash = actualSlashAmount - data.earnedReputation;
            data.earnedReputation = 0;

            uint256 minBaseProtection = data.baseReputation / 4;
            uint256 newBaseRep = data.baseReputation > remainingSlash
                ? data.baseReputation - remainingSlash
                : minBaseProtection;

            data.baseReputation = Math.max(newBaseRep, minBaseProtection);
        }

        data.decayCheckpoint = currentBalance - actualSlashAmount;

        // Record slashing event (with size limit)
        if (slashingHistory[account].length < 1000) {
            slashingHistory[account].push(
                SlashingEvent({
                    amount: actualSlashAmount,
                    reason: reason,
                    timestamp: block.timestamp,
                    slasher: msg.sender
                })
            );
        }

        data.totalSlashed += actualSlashAmount;
        totalReputationSlashed += actualSlashAmount;

        // Burn the reputation
        _burn(account, actualSlashAmount);

        // Notify lock manager
        if (lockManagerEnabled && address(lockManager) != address(0)) {
            try
                lockManager.onReputationSlashed(account, actualSlashAmount)
            {} catch Error(string memory errorReason) {
                emit SlashNotificationFailed(
                    account,
                    actualSlashAmount,
                    errorReason
                );
            } catch {
                emit SlashNotificationFailed(
                    account,
                    actualSlashAmount,
                    "Unknown error"
                );
            }
        }

        emit ReputationSlashed(account, actualSlashAmount, reason, msg.sender);
    }

    function _calculateBondingCurveSafe(
        uint256 amount,
        uint256 accuracy
    ) internal pure returns (uint256) {
        require(amount > 0, "Amount must be positive");
        require(
            accuracy >= ACCURACY_THRESHOLD && accuracy <= PRECISION,
            "Invalid accuracy"
        );

        if (amount > type(uint256).max / PRECISION) {
            revert("Amount too large for safe calculation");
        }

        uint256 accuracyNormalized = accuracy > PRECISION
            ? PRECISION
            : accuracy;

        uint256 accuracySquared = Math.mulDiv(
            accuracyNormalized,
            accuracyNormalized,
            PRECISION
        );

        if (accuracySquared == 0) {
            accuracySquared = 1;
        }

        uint256 scaledAmount = Math.mulDiv(amount, accuracySquared, PRECISION);

        uint256 minReward = amount / 100;
        if (scaledAmount < minReward) {
            scaledAmount = minReward;
        }

        uint256 bonusRate = 0;
        if (accuracyNormalized >= 10000) {
            bonusRate = 5000;
        } else if (accuracyNormalized >= 9000) {
            bonusRate = 5000;
        } else if (accuracyNormalized >= 8000) {
            bonusRate = 3000;
        } else if (accuracyNormalized >= 7000) {
            bonusRate = 2000;
        } else if (accuracyNormalized >= 6000) {
            bonusRate = 1000;
        }

        uint256 bonus = 0;
        if (bonusRate > 0) {
            bonus = Math.mulDiv(scaledAmount, bonusRate, PRECISION);

            uint256 maxBonus = scaledAmount * 2;
            if (bonus > maxBonus) {
                bonus = maxBonus;
            }
        }

        uint256 finalAmount = scaledAmount + bonus;

        if (finalAmount == 0) {
            finalAmount = 1;
        }

        if (finalAmount > MAX_REPUTATION_CAP) {
            finalAmount = MAX_REPUTATION_CAP;
        }

        return finalAmount;
    }

    function blacklistUser(
        address user,
        string calldata reason
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(user != address(0), "Invalid address");
        require(!blacklistData[user].isBlacklisted, "Already blacklisted");
        require(bytes(reason).length > 0, "Reason required");

        uint256 currentBalance = super.balanceOf(user);

        blacklistData[user] = BlacklistData({
            isBlacklisted: true,
            blacklistedBalance: currentBalance,
            blacklistTimestamp: block.timestamp,
            reason: reason
        });

        if (currentBalance > 0) {
            _burn(user, currentBalance);
        }

        emit UserBlacklisted(user, reason, currentBalance);
    }

    function whitelistUser(address user) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(user != address(0), "Invalid address");
        require(blacklistData[user].isBlacklisted, "Not blacklisted");

        BlacklistData storage blacklist = blacklistData[user];
        ReputationData storage data = reputationData[user];

        uint256 timeBlacklisted = block.timestamp -
            blacklist.blacklistTimestamp;
        uint256 restoredBalance = blacklist.blacklistedBalance;

        if (timeBlacklisted > MIN_ACTIVITY_THRESHOLD) {
            uint256 decayTime = timeBlacklisted - MIN_ACTIVITY_THRESHOLD;
            uint256 decayPeriods = (decayTime * PRECISION) / DECAY_PERIOD;

            if (decayPeriods > 0) {
                uint256 effectiveDecayRate = Math.min(
                    (DECAY_RATE * decayPeriods) / PRECISION,
                    MAX_DECAY_RATE
                );

                uint256 decayAmount = Math.mulDiv(
                    restoredBalance,
                    effectiveDecayRate,
                    PRECISION
                );

                uint256 minProtection = (restoredBalance *
                    MIN_PROTECTION_RATE) / PRECISION;
                restoredBalance = restoredBalance > decayAmount
                    ? restoredBalance - decayAmount
                    : minProtection;
                restoredBalance = Math.max(restoredBalance, minProtection);
            }
        }

        uint256 baseRep = data.baseReputation;
        if (restoredBalance > baseRep) {
            data.earnedReputation = restoredBalance - baseRep;
        } else {
            data.baseReputation = restoredBalance;
            data.earnedReputation = 0;
        }

        data.lastActivityTime = block.timestamp;
        data.lastDecayTime = block.timestamp;
        data.decayCheckpoint = restoredBalance;

        blacklist.isBlacklisted = false;

        if (restoredBalance > 0) {
            _mint(user, restoredBalance);
        }

        emit UserWhitelisted(user, restoredBalance);
    }

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
            bool isBlacklisted,
            uint256 decayAmount
        )
    {
        ReputationData memory data = reputationData[user];
        BlacklistData memory blacklist = blacklistData[user];

        uint256 currentBalance = balanceOf(user);
        uint256 storedBalance = data.baseReputation + data.earnedReputation;

        return (
            currentBalance,
            data.baseReputation,
            data.earnedReputation,
            data.lastActivityTime,
            data.totalMinted,
            data.totalSlashed,
            blacklist.isBlacklisted,
            storedBalance > currentBalance ? storedBalance - currentBalance : 0
        );
    }

    function getSlashingHistory(
        address user,
        uint256 offset,
        uint256 limit
    ) external view returns (SlashingEvent[] memory events, uint256 total) {
        SlashingEvent[] storage userHistory = slashingHistory[user];
        total = userHistory.length;

        if (offset >= total) {
            return (new SlashingEvent[](0), total);
        }

        uint256 end = Math.min(offset + limit, total);
        uint256 length = end - offset;

        events = new SlashingEvent[](length);
        for (uint256 i = 0; i < length; i++) {
            events[i] = userHistory[offset + i];
        }

        return (events, total);
    }

    function calculateDecay(address user) external view returns (uint256) {
        if (blacklistData[user].isBlacklisted) return 0;

        ReputationData memory data = reputationData[user];
        uint256 storedBalance = data.baseReputation + data.earnedReputation;
        uint256 currentBalance = balanceOf(user);

        return
            storedBalance > currentBalance ? storedBalance - currentBalance : 0;
    }

    function getBlacklistData(
        address user
    )
        external
        view
        returns (
            bool isBlacklisted,
            uint256 blacklistedBalance,
            uint256 blacklistTimestamp,
            string memory reason
        )
    {
        BlacklistData memory data = blacklistData[user];
        return (
            data.isBlacklisted,
            data.blacklistedBalance,
            data.blacklistTimestamp,
            data.reason
        );
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function transfer(address, uint256) public pure override returns (bool) {
        revert("Reputation is non-transferable");
    }

    function transferFrom(
        address,
        address,
        uint256
    ) public pure override returns (bool) {
        revert("Reputation is non-transferable");
    }

    function approve(address, uint256) public pure override returns (bool) {
        revert("Reputation is non-transferable");
    }

    function increaseAllowance(address, uint256) public pure returns (bool) {
        revert("Reputation is non-transferable");
    }

    function decreaseAllowance(address, uint256) public pure returns (bool) {
        revert("Reputation is non-transferable");
    }
}
