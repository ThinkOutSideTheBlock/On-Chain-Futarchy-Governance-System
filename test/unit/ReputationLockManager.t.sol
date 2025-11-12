// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import "../../src/governance/ReputationLockManager.sol";
import "../../src/core/ReputationToken.sol";

contract ReputationLockManagerTest is Test {
    ReputationLockManager public lockManager;
    ReputationToken public repToken;

    address public admin = address(1);
    address public locker = address(2);
    address public alice = address(100);
    address public bob = address(101);

    uint256 constant INITIAL_REP = 100 * 10 ** 18;

    event DecaySkipped(address indexed user, string reason);
    event DecayApplied(
        address indexed user,
        uint256 totalDecayAmount,
        uint256 locksAffected
    );
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
    event SlashSynchronized(
        address indexed user,
        uint256 slashedAmount,
        uint256 locksAffected
    );
    event EmergencyUnlock(address indexed user, uint256 amount, string reason);
    function setUp() public {
        vm.warp(1000);

        repToken = new ReputationToken();
        lockManager = new ReputationLockManager(address(repToken));

        // ✅ FIX: Setup roles correctly
        // Test contract is deployer, so it has DEFAULT_ADMIN_ROLE
        // Grant admin role to admin address
        repToken.grantRole(repToken.DEFAULT_ADMIN_ROLE(), admin);
        lockManager.grantRole(lockManager.DEFAULT_ADMIN_ROLE(), admin);

        // Now setup other roles
        vm.startPrank(admin);
        lockManager.grantRole(lockManager.LOCKER_ROLE(), locker);
        lockManager.grantRole(lockManager.DECAY_MANAGER_ROLE(), admin);

        repToken.grantRole(repToken.MINTER_ROLE(), admin);
        repToken.grantRole(repToken.SLASHER_ROLE(), address(lockManager));
        repToken.grantRole(repToken.INITIALIZER_ROLE(), admin); // ✅ FIX: Grant INITIALIZER_ROLE
        repToken.setLockManager(address(lockManager));
        vm.stopPrank();

        // Initialize users
        vm.prank(admin);
        repToken.grantInitialReputation(alice);

        vm.warp(block.timestamp + 601);

        vm.prank(admin);
        repToken.grantInitialReputation(bob);
    }

    // ============ LOCK TESTS ============

    function test_LockReputation_Basic() public {
        vm.prank(locker);
        vm.expectEmit(true, true, false, true);
        emit ReputationLocked(alice, locker, 1, 10 * 10 ** 18, 0);

        (bool success, uint256 lockIndex) = lockManager.lockReputation(
            alice,
            10 * 10 ** 18,
            1
        );

        assertTrue(success);
        assertEq(lockIndex, 0);
        assertEq(lockManager.totalLocked(alice), 10 * 10 ** 18);
    }

    function test_LockReputation_MultipleMarkets() public {
        vm.startPrank(locker);
        lockManager.lockReputation(alice, 10 * 10 ** 18, 1);
        lockManager.lockReputation(alice, 20 * 10 ** 18, 2);
        vm.stopPrank();

        assertEq(lockManager.totalLocked(alice), 30 * 10 ** 18);
    }

    function test_LockReputation_RevertWhen_InsufficientAvailable() public {
        vm.prank(locker);
        vm.expectRevert();
        lockManager.lockReputation(alice, 150 * 10 ** 18, 1);
    }

    function test_LockReputation_RevertWhen_TooManyLocks() public {
        vm.startPrank(locker);

        for (uint256 i = 0; i < 50; i++) {
            lockManager.lockReputation(alice, 1 * 10 ** 18, i);
        }

        vm.expectRevert();
        lockManager.lockReputation(alice, 1 * 10 ** 18, 51);

        vm.stopPrank();
    }

    // ============ UNLOCK TESTS ============

    function test_UnlockReputation_Basic() public {
        vm.prank(locker);
        lockManager.lockReputation(alice, 10 * 10 ** 18, 1);

        vm.prank(locker);
        vm.expectEmit(true, true, false, true);
        emit ReputationUnlocked(alice, locker, 1, 10 * 10 ** 18, 0);

        (bool success, uint256 unlocked) = lockManager.unlockReputation(
            alice,
            1
        );

        assertTrue(success);
        assertEq(unlocked, 10 * 10 ** 18);
        assertEq(lockManager.totalLocked(alice), 0);
    }

    function test_UnlockReputation_RevertWhen_LockNotFound() public {
        vm.prank(locker);
        vm.expectRevert();
        lockManager.unlockReputation(alice, 999);
    }

    // ============ DECAY TESTS ============

    function test_Decay_AppliedOverTime() public {
        vm.prank(locker);
        lockManager.lockReputation(alice, 100 * 10 ** 18, 1);

        // Fast forward 30 days (1 decay period)
        vm.warp(block.timestamp + 30 days + 1 days + 1);

        uint256 available = lockManager.getAvailableReputation(alice);

        // After 1 period, 1% decay applied to locked amount
        // Locked was 100, decay = 1, so locked becomes 99
        // Available = 100 (total) - 99 (locked) = 1
        assertGt(available, 0);
    }

    function test_Decay_MultiplePeriodsGradual() public {
        vm.prank(locker);
        lockManager.lockReputation(alice, 50 * 10 ** 18, 1);

        uint256 initialLocked = lockManager.totalLocked(alice);

        // Fast forward 60 days (2 decay periods)
        vm.warp(block.timestamp + 60 days + 1 days + 1);

        lockManager.getAvailableReputation(alice);
        uint256 afterDecay = lockManager.totalLocked(alice);

        // After 2 periods: 50 - (50 * 0.01 * 2) = 49
        assertLt(afterDecay, initialLocked);
    }

    function test_Decay_SkippedDuringCooldown() public {
        vm.prank(locker);
        lockManager.lockReputation(alice, 50e18, 1);

        uint256 availableBefore = lockManager.getAvailableReputation(alice);

        // 🔧 FIX: Expect the DecaySkipped event
        vm.expectEmit(true, false, false, false);
        emit DecaySkipped(alice, "Decay cooldown active");

        uint256 availableAfter = lockManager.getAvailableReputation(alice);

        assertEq(
            availableBefore,
            availableAfter,
            "Available should not change"
        );
    }

    // ============ SLASH SYNCHRONIZATION TESTS ============

    function test_SlashSynchronization_ProportionalReduction() public {
        vm.prank(locker);
        lockManager.lockReputation(alice, 50 * 10 ** 18, 1);

        // Slash 10% of Alice's reputation
        vm.prank(address(repToken));
        vm.expectEmit(true, false, false, false);
        emit SlashSynchronized(alice, 0, 0); // Amount will be calculated

        lockManager.onReputationSlashed(alice, 10 * 10 ** 18);

        // Lock should be reduced proportionally
        uint256 newLocked = lockManager.totalLocked(alice);
        assertLt(newLocked, 50 * 10 ** 18);
    }

    function test_SlashSynchronization_MultipleLocksAffected() public {
        vm.startPrank(locker);
        lockManager.lockReputation(alice, 25 * 10 ** 18, 1);
        lockManager.lockReputation(alice, 25 * 10 ** 18, 2);
        vm.stopPrank();

        uint256 totalBefore = lockManager.totalLocked(alice);

        vm.prank(address(repToken));
        lockManager.onReputationSlashed(alice, 20 * 10 ** 18);

        uint256 totalAfter = lockManager.totalLocked(alice);
        assertEq(totalBefore - totalAfter, 20 * 10 ** 18);
    }

    function test_SlashSynchronization_RevertWhen_NotRepToken() public {
        vm.prank(locker);
        lockManager.lockReputation(alice, 50 * 10 ** 18, 1);

        vm.prank(alice);
        vm.expectRevert("Only reputation token can call");
        lockManager.onReputationSlashed(alice, 10 * 10 ** 18);
    }

    // ============ VIEW FUNCTION TESTS ============

    function test_GetAvailableReputationView_Estimate() public {
        vm.prank(locker);
        lockManager.lockReputation(alice, 50 * 10 ** 18, 1);

        uint256 available = lockManager.getAvailableReputationView(alice);
        assertEq(available, 50 * 10 ** 18);
    }

    function test_GetUserLocks_ReturnsAllLocks() public {
        vm.startPrank(locker);
        lockManager.lockReputation(alice, 10 * 10 ** 18, 1);
        lockManager.lockReputation(alice, 20 * 10 ** 18, 2);
        vm.stopPrank();

        ReputationLockManager.Lock[] memory locks = lockManager.getUserLocks(
            alice
        );
        assertEq(locks.length, 2);
        assertEq(locks[0].amount, 10 * 10 ** 18);
        assertEq(locks[1].amount, 20 * 10 ** 18);
    }

    function test_GetActiveLockCount() public {
        vm.startPrank(locker);
        lockManager.lockReputation(alice, 10 * 10 ** 18, 1);
        lockManager.lockReputation(alice, 20 * 10 ** 18, 2);
        lockManager.unlockReputation(alice, 1);
        vm.stopPrank();

        uint256 activeCount = lockManager.getActiveLockCount(alice);
        assertEq(activeCount, 1);
    }

    // ============ ADMIN FUNCTION TESTS ============

    function test_EmergencyUnlockAll() public {
        vm.startPrank(locker);
        lockManager.lockReputation(alice, 10 * 10 ** 18, 1);
        lockManager.lockReputation(alice, 20 * 10 ** 18, 2);
        vm.stopPrank();

        vm.prank(admin);
        lockManager.emergencyUnlockAll(alice, "Emergency situation");

        assertEq(lockManager.totalLocked(alice), 0);
    }

    function test_BatchApplyDecay() public {
        vm.startPrank(locker);
        lockManager.lockReputation(alice, 50 * 10 ** 18, 1);
        lockManager.lockReputation(bob, 50 * 10 ** 18, 1);
        vm.stopPrank();

        vm.warp(block.timestamp + 30 days + 1 days + 1);

        address[] memory users = new address[](2);
        users[0] = alice;
        users[1] = bob;

        vm.prank(admin);
        lockManager.batchApplyDecay(users);

        assertLt(lockManager.totalLocked(alice), 50 * 10 ** 18);
        assertLt(lockManager.totalLocked(bob), 50 * 10 ** 18);
    }

    function test_ForceDecayApplication() public {
        vm.prank(locker);
        lockManager.lockReputation(alice, 50 * 10 ** 18, 1);

        // Apply decay normally
        lockManager.getAvailableReputation(alice);

        // Force decay (bypasses cooldown)
        vm.warp(block.timestamp + 30 days + 1);
        vm.prank(admin);
        lockManager.forceDecayApplication(alice);

        assertLt(lockManager.totalLocked(alice), 50 * 10 ** 18);
    }

    // ============ INTEGRATION TESTS ============

    function test_Integration_LockUnlockWithDecay() public {
        vm.prank(locker);
        lockManager.lockReputation(alice, 50 * 10 ** 18, 1);

        vm.warp(block.timestamp + 30 days + 1 days + 1);

        uint256 available = lockManager.getAvailableReputation(alice);
        assertGt(available, 0);

        vm.prank(locker);
        (bool success, uint256 unlocked) = lockManager.unlockReputation(
            alice,
            1
        );

        assertTrue(success);
        assertLt(unlocked, 50 * 10 ** 18); // Decay applied
    }

    function test_Integration_SlashThenUnlock() public {
        vm.prank(locker);
        lockManager.lockReputation(alice, 50 * 10 ** 18, 1);

        // Slash
        vm.prank(address(repToken));
        lockManager.onReputationSlashed(alice, 10 * 10 ** 18);

        // Unlock
        vm.prank(locker);
        (bool success, uint256 unlocked) = lockManager.unlockReputation(
            alice,
            1
        );

        assertTrue(success);
        assertEq(unlocked, 40 * 10 ** 18); // 50 - 10 = 40
    }
}
