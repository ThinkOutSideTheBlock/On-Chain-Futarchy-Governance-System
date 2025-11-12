// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "../../src/core/ReputationToken.sol";

/**
 * @title ReputationLockManager
 * @notice Centralized reputation lock management with decay synchronization
 * @dev Prevents phantom reputation by applying decay to all locks atomically
 */
contract ReputationLockManager is AccessControl, ReentrancyGuard {
    using Math for uint256;

    // ============ CONSTANTS ============
    bytes32 public constant LOCKER_ROLE = keccak256("LOCKER_ROLE");
    bytes32 public constant DECAY_MANAGER_ROLE =
        keccak256("DECAY_MANAGER_ROLE");

    uint256 private constant PRECISION = 10000;
    uint256 private constant DECAY_RATE = 100; // 1% per period (was 50)
    uint256 private constant DECAY_PERIOD = 30 days; // 30 days (was 7 days)

    uint256 private constant MAX_DECAY_PERIODS = 52; // ~1 year max
    uint256 private constant MAX_LOCKS_PER_USER = 50; // Gas protection
    uint256 private constant MAX_LOCKS_PER_CALL = 10; // Process max 10 locks per call
    uint256 private constant BATCH_DECAY_INTERVAL = 1 days; // Minimum time between full decay applications
    // ============ STATE VARIABLES ============
    ReputationToken public immutable reputationToken;

    struct Lock {
        uint256 amount;
        uint256 lockTime;
        uint256 lastDecayApplication;
        address locker;
        uint256 marketId;
        bool active;
    }

    mapping(address => Lock[]) private userLocks;
    mapping(address => uint256) public totalLocked;
    mapping(address => uint256) public lastGlobalDecay;
    mapping(address => uint256) public lastBatchDecay;

    uint256 public totalLocksCreated;
    uint256 public totalLocksReleased;
    uint256 public totalDecayApplied;

    //  NEW: Slash synchronization tracking
    uint256 public totalSlashSynchronized;
    // ============ EVENTS ============
    event SlashSynchronized(
        address indexed user,
        uint256 slashedAmount,
        uint256 locksAffected
    );
    event DecaySkipped(address indexed user, string reason);
    event ReputationLocked(
        address indexed user,
        address indexed locker,
        uint256 marketId,
        uint256 amount,
        uint256 lockIndex
    );
    event ReputationUnlocked(
        address indexed user,
        address indexed locker,
        uint256 marketId,
        uint256 amount,
        uint256 lockIndex
    );
    event DecayApplied(
        address indexed user,
        uint256 totalDecayAmount,
        uint256 locksAffected
    );
    event EmergencyUnlock(address indexed user, uint256 amount, string reason);

    // ============ ERRORS ============
    error InsufficientAvailableReputation(uint256 available, uint256 requested);
    error InvalidLockAmount();
    error LockNotFound();
    error TooManyLocks();
    error ZeroAddress();

    // ============ CONSTRUCTOR ============
    constructor(address _reputationToken) {
        if (_reputationToken == address(0)) revert ZeroAddress();
        reputationToken = ReputationToken(_reputationToken);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(DECAY_MANAGER_ROLE, msg.sender);
    }

    // ============ CORE FUNCTIONS ============

    function getAvailableReputation(
        address user
    ) public returns (uint256 available) {
        uint256 currentBalance = reputationToken.balanceOf(user);
        _applyDecayToAllLocks(user); // ✅ Updates totalLocked internally
        uint256 locked = totalLocked[user]; // ✅ Read from cache
        available = currentBalance > locked ? currentBalance - locked : 0;
        return available;
    }

    function getAvailableReputationView(
        address user
    ) external view returns (uint256 available) {
        uint256 currentBalance = reputationToken.balanceOf(user);

        // Use cached value if recently updated
        if (block.timestamp < lastBatchDecay[user] + BATCH_DECAY_INTERVAL) {
            uint256 locked = totalLocked[user];
            return currentBalance > locked ? currentBalance - locked : 0;
        }

        // Otherwise estimate
        uint256 estimatedLocked = _estimateDecayedLocksImproved(user);
        return
            currentBalance > estimatedLocked
                ? currentBalance - estimatedLocked
                : 0;
    }

    /**
     * @notice Lock reputation for a user
     */
    function lockReputation(
        address user,
        uint256 amount,
        uint256 marketId
    )
        external
        onlyRole(LOCKER_ROLE)
        nonReentrant
        returns (bool success, uint256 lockIndex)
    {
        if (amount == 0) revert InvalidLockAmount();
        if (user == address(0)) revert ZeroAddress();
        if (userLocks[user].length >= MAX_LOCKS_PER_USER) revert TooManyLocks();

        uint256 available = getAvailableReputation(user);
        if (available < amount) {
            revert InsufficientAvailableReputation(available, amount);
        }

        lockIndex = userLocks[user].length;
        userLocks[user].push(
            Lock({
                amount: amount,
                lockTime: block.timestamp,
                lastDecayApplication: block.timestamp,
                locker: msg.sender,
                marketId: marketId,
                active: true
            })
        );

        totalLocked[user] += amount;
        totalLocksCreated++;

        emit ReputationLocked(user, msg.sender, marketId, amount, lockIndex);
        return (true, lockIndex);
    }

    /**
     * @notice Unlock reputation for a user
     */
    function unlockReputation(
        address user,
        uint256 marketId
    )
        external
        onlyRole(LOCKER_ROLE)
        nonReentrant
        returns (bool success, uint256 unlockedAmount)
    {
        if (user == address(0)) revert ZeroAddress();

        (bool found, uint256 lockIndex) = _findLock(user, marketId, msg.sender);
        if (!found) revert LockNotFound();

        Lock storage lock = userLocks[user][lockIndex];

        // Apply decay before unlocking
        _applyDecayToLock(user, lockIndex);
        unlockedAmount = lock.amount;

        // Update total locked
        if (totalLocked[user] >= unlockedAmount) {
            totalLocked[user] -= unlockedAmount;
        } else {
            totalLocked[user] = 0;
        }

        lock.active = false;
        totalLocksReleased++;

        emit ReputationUnlocked(
            user,
            msg.sender,
            marketId,
            unlockedAmount,
            lockIndex
        );
        return (true, unlockedAmount);
    }

    function getLockedReputation(
        address user
    ) external returns (uint256 locked) {
        _applyDecayToAllLocks(user); // ✅ Updates cache
        return totalLocked[user]; // ✅ Return cache
    }

    /**
     * @notice Get lock details for a user
     */
    function getUserLocks(
        address user
    ) external view returns (Lock[] memory locks) {
        return userLocks[user];
    }

    /**
     * @notice Get active lock count
     */
    function getActiveLockCount(
        address user
    ) external view returns (uint256 count) {
        Lock[] storage locks = userLocks[user];
        for (uint256 i = 0; i < locks.length; i++) {
            if (locks[i].active) count++;
        }
        return count;
    }

    // ============ INTERNAL FUNCTIONS ============

    function _applyDecayToAllLocks(address user) internal returns (uint256) {
        Lock[] storage locks = userLocks[user];

        // DoS PROTECTION: Skip if decayed recently
        if (block.timestamp < lastBatchDecay[user] + BATCH_DECAY_INTERVAL) {
            emit DecaySkipped(user, "Decay cooldown active");
            return totalLocked[user]; // ✅ Return cached value
        }

        uint256 totalDecay = 0;
        uint256 locksAffected = 0;
        uint256 processed = 0;

        // Apply decay to locks
        for (
            uint256 i = 0;
            i < locks.length && processed < MAX_LOCKS_PER_CALL;
            i++
        ) {
            if (locks[i].active && locks[i].amount > 0) {
                uint256 decayAmount = _applyDecayToLock(user, i);
                if (decayAmount > 0) {
                    totalDecay += decayAmount;
                    locksAffected++;
                }
                processed++;
            }
        }

        // Update cache by reducing decay
        if (totalDecay > 0) {
            if (totalLocked[user] >= totalDecay) {
                totalLocked[user] -= totalDecay;
            } else {
                totalLocked[user] = 0;
            }
            totalDecayApplied += totalDecay;
            emit DecayApplied(user, totalDecay, locksAffected);
        }

        lastBatchDecay[user] = block.timestamp;
        lastGlobalDecay[user] = block.timestamp;

        return totalLocked[user]; // ✅ Always return the CACHE
    }

    /**
     * @notice Apply decay to a specific lock
     */
    function _applyDecayToLock(
        address user,
        uint256 lockIndex
    ) internal returns (uint256 decayAmount) {
        Lock storage lock = userLocks[user][lockIndex];

        if (!lock.active || lock.amount == 0) return 0;

        uint256 timeElapsed = block.timestamp - lock.lastDecayApplication;
        uint256 periodsPassed = timeElapsed / DECAY_PERIOD;

        if (periodsPassed > MAX_DECAY_PERIODS) {
            periodsPassed = MAX_DECAY_PERIODS;
        }

        if (periodsPassed > 0) {
            decayAmount = Math.mulDiv(
                lock.amount,
                DECAY_RATE * periodsPassed,
                PRECISION
            );

            if (decayAmount > lock.amount) {
                decayAmount = lock.amount;
            }

            lock.amount -= decayAmount;
            lock.lastDecayApplication = block.timestamp;

            if (lock.amount == 0) {
                lock.active = false;
            }
        }

        return decayAmount;
    }

    /**
     * @notice Estimate decayed locks (view-only)
     */
    function _estimateDecayedLocks(
        address user
    ) internal view returns (uint256 estimatedLocked) {
        Lock[] storage locks = userLocks[user];

        for (uint256 i = 0; i < locks.length; i++) {
            if (locks[i].active && locks[i].amount > 0) {
                uint256 timeElapsed = block.timestamp -
                    locks[i].lastDecayApplication;
                uint256 periodsPassed = timeElapsed / DECAY_PERIOD;

                if (periodsPassed > MAX_DECAY_PERIODS) {
                    periodsPassed = MAX_DECAY_PERIODS;
                }

                uint256 decayAmount = Math.mulDiv(
                    locks[i].amount,
                    DECAY_RATE * periodsPassed,
                    PRECISION
                );

                uint256 remainingAmount = locks[i].amount > decayAmount
                    ? locks[i].amount - decayAmount
                    : 0;

                estimatedLocked += remainingAmount;
            }
        }

        return estimatedLocked;
    }

    /**
     * @notice Improved lock decay estimation (view-only)
     * @dev Uses same logic as state-changing version but doesn't modify state
     */
    function _estimateDecayedLocksImproved(
        address user
    ) internal view returns (uint256 estimatedLocked) {
        Lock[] storage locks = userLocks[user];

        // If recently decayed, use cached value for better accuracy
        if (block.timestamp < lastBatchDecay[user] + BATCH_DECAY_INTERVAL) {
            return totalLocked[user];
        }

        for (uint256 i = 0; i < locks.length; i++) {
            if (locks[i].active && locks[i].amount > 0) {
                uint256 timeElapsed = block.timestamp -
                    locks[i].lastDecayApplication;
                uint256 periodsPassed = timeElapsed / DECAY_PERIOD;

                if (periodsPassed > MAX_DECAY_PERIODS) {
                    periodsPassed = MAX_DECAY_PERIODS;
                }

                if (periodsPassed > 0) {
                    uint256 decayAmount = Math.mulDiv(
                        locks[i].amount,
                        DECAY_RATE * periodsPassed,
                        PRECISION
                    );

                    uint256 remainingAmount = locks[i].amount > decayAmount
                        ? locks[i].amount - decayAmount
                        : 0;

                    estimatedLocked += remainingAmount;
                } else {
                    // No decay periods passed, use full amount
                    estimatedLocked += locks[i].amount;
                }
            }
        }

        return estimatedLocked;
    }

    /**
     * @notice Find lock by marketId and locker
     */
    function _findLock(
        address user,
        uint256 marketId,
        address locker
    ) internal view returns (bool found, uint256 index) {
        Lock[] storage locks = userLocks[user];

        for (uint256 i = 0; i < locks.length; i++) {
            if (
                locks[i].active &&
                locks[i].marketId == marketId &&
                locks[i].locker == locker
            ) {
                return (true, i);
            }
        }

        return (false, 0);
    }

    // ============ ADMIN FUNCTIONS ============

    /**
     * @notice Emergency unlock all locks for a user
     */
    function emergencyUnlockAll(
        address user,
        string calldata reason
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        Lock[] storage locks = userLocks[user];
        uint256 totalUnlocked = 0;

        for (uint256 i = 0; i < locks.length; i++) {
            if (locks[i].active) {
                totalUnlocked += locks[i].amount;
                locks[i].active = false;
            }
        }

        totalLocked[user] = 0;
        emit EmergencyUnlock(user, totalUnlocked, reason);
    }

    /**
     * @notice Batch apply decay (for maintenance)
     */
    function batchApplyDecay(
        address[] calldata users
    ) external onlyRole(DECAY_MANAGER_ROLE) {
        require(users.length <= 50, "Batch too large");

        for (uint256 i = 0; i < users.length; i++) {
            if (users[i] != address(0)) {
                _applyDecayToAllLocks(users[i]);
            }
        }
    }
    // ============ SLASH SYNCHRONIZATION ============

    /**
     * @notice Handle reputation slashing notification from ReputationToken
     * @dev  CRITICAL FIX: Synchronizes locks when reputation is slashed
     */
    function onReputationSlashed(
        address user,
        uint256 slashedAmount
    ) external nonReentrant {
        require(
            msg.sender == address(reputationToken),
            "Only reputation token can call"
        );
        require(user != address(0), "Invalid user address");
        require(slashedAmount > 0, "Invalid slash amount");

        uint256 currentTotalLocked = totalLocked[user];
        if (currentTotalLocked == 0) {
            // No locks to adjust
            return;
        }

        // Calculate proportional reduction needed
        uint256 reductionAmount = Math.min(slashedAmount, currentTotalLocked);

        Lock[] storage locks = userLocks[user];
        uint256 locksAffected = 0;
        uint256 totalReduced = 0;

        // Apply reduction proportionally to all active locks
        for (uint256 i = 0; i < locks.length; i++) {
            if (locks[i].active && locks[i].amount > 0) {
                // Calculate this lock's proportional share of the reduction
                uint256 lockReduction = Math.mulDiv(
                    locks[i].amount,
                    reductionAmount,
                    currentTotalLocked
                );

                if (lockReduction > 0) {
                    if (lockReduction >= locks[i].amount) {
                        // Lock fully consumed by slash
                        totalReduced += locks[i].amount;
                        locks[i].amount = 0;
                        locks[i].active = false;
                    } else {
                        // Partial reduction
                        locks[i].amount -= lockReduction;
                        totalReduced += lockReduction;
                    }
                    locksAffected++;
                }

                // Stop if we've reduced enough
                if (totalReduced >= reductionAmount) {
                    break;
                }
            }
        }

        // Update total locked
        if (totalLocked[user] >= totalReduced) {
            totalLocked[user] -= totalReduced;
        } else {
            totalLocked[user] = 0;
        }

        totalSlashSynchronized += totalReduced;

        emit SlashSynchronized(user, totalReduced, locksAffected);
    }

    /**
     * @notice Force decay application for specific user (admin emergency)
     */
    function forceDecayApplication(
        address user
    ) external onlyRole(DECAY_MANAGER_ROLE) {
        require(user != address(0), "Invalid user address");

        // Reset cooldown to allow immediate decay
        lastBatchDecay[user] = 0;

        // Apply decay
        uint256 newLocked = _applyDecayToAllLocks(user);
        totalLocked[user] = newLocked;
    }
}
