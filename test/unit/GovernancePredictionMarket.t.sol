// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import "../../src/core/GovernancePredictionMarket.sol";
import "../../src/core/ReputationToken.sol";
import "../../src/governance/ReputationLockManager.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "forge-std/console.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock USD", "mUSD") {
        _mint(msg.sender, 1_000_000 * 10 ** 18);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract GovernancePredictionMarketTest is Test {
    GovernancePredictionMarket public market;
    ReputationToken public repToken;
    ReputationLockManager public lockManager;
    MockERC20 public stakingToken;

    address public admin = address(1);
    address public oracle = address(2);
    address public alice = address(100);
    address public bob = address(101);
    address public carol = address(102);

    // ============ CONSTANTS ============
    uint256 constant INITIAL_REP = 100 * 10 ** 18;
    uint256 constant STRATEGIC_DECISION_MIN = 14 days;
    uint256 constant MARKET_CREATION_COOLDOWN = 1 hours;
    uint256 constant INITIAL_LIQUIDITY_PHASE = 100; // blocks
    uint256 constant MIN_LIQUIDITY = 1000 * 10 ** 18;
    uint256 constant MIN_TRADE_INTERVAL = 1 minutes;
    uint256 constant SETTLEMENT_DELAY = 6 hours;
    uint256 constant PROPOSAL_DELAY = 12 hours;
    uint256 constant VOTING_DELAY = 24 hours;
    uint256 constant DISPUTE_DELAY = 48 hours;
    uint256 constant FINALIZATION_DELAY = 24 hours;
    uint256 constant GRANT_COOLDOWN = 10 minutes;

    // ============ EVENTS ============
    event MarketCreated(
        uint256 indexed marketId,
        string question,
        uint256 tradingEndTime,
        uint8 outcomeCount,
        GovernancePredictionMarket.MarketCategory category,
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

    modifier marketExists(uint256 marketId) {
        require(marketId < market.marketCount(), "Market does not exist");
        _;
    }

    function setUp() public {
        console.log("Starting test setup...");

        // Start with clean state
        uint256 startTime = 365 days;
        vm.warp(startTime);
        vm.roll(1000);

        // Deploy contracts
        console.log("Deploying contracts...");
        stakingToken = new MockERC20();
        repToken = new ReputationToken();
        lockManager = new ReputationLockManager(address(repToken));
        market = new GovernancePredictionMarket(
            address(stakingToken),
            address(repToken),
            admin,
            address(lockManager)
        );

        // Set up roles and permissions
        console.log("Setting up roles...");
        repToken.grantRole(repToken.DEFAULT_ADMIN_ROLE(), admin);
        lockManager.grantRole(lockManager.DEFAULT_ADMIN_ROLE(), admin);
        market.grantRole(market.DEFAULT_ADMIN_ROLE(), admin);

        vm.startPrank(admin);
        repToken.grantRole(repToken.MINTER_ROLE(), address(market));
        repToken.grantRole(repToken.MINTER_ROLE(), admin);
        repToken.grantRole(repToken.SLASHER_ROLE(), address(lockManager));
        repToken.grantRole(repToken.INITIALIZER_ROLE(), admin); // ✅ FIX: Grant INITIALIZER_ROLE
        repToken.setLockManager(address(lockManager));
        lockManager.grantRole(lockManager.LOCKER_ROLE(), address(market));
        market.grantRole(market.MARKET_CREATOR_ROLE(), admin);
        market.grantRole(market.RESOLVER_ROLE(), admin);

        // Initialize users with proper reputation
        console.log("Initializing users...");

        uint256 currentTime = startTime + GRANT_COOLDOWN + 1 minutes;
        vm.roll(block.number + 1); // ✅ FIX: Advance block
        vm.warp(currentTime);
        repToken.grantInitialReputation(alice);
        console.log("Alice initial reputation:", repToken.balanceOf(alice));

        currentTime += GRANT_COOLDOWN + 1 minutes;
        vm.roll(block.number + 1); // ✅ FIX: Advance block
        vm.warp(currentTime);
        repToken.grantInitialReputation(bob);
        console.log("Bob initial reputation:", repToken.balanceOf(bob));

        // Mint additional reputation
        console.log("Minting additional reputation...");

        currentTime += GRANT_COOLDOWN + 1 minutes;
        vm.roll(block.number + 1); // ✅ FIX: Advance block
        vm.warp(currentTime);
        repToken.mintReputation(alice, 50000 * 10 ** 18, 10000);
        console.log("Alice final reputation:", repToken.balanceOf(alice));

        currentTime += GRANT_COOLDOWN + 1 minutes;
        vm.roll(block.number + 1); // ✅ FIX: Advance block
        vm.warp(currentTime);
        repToken.mintReputation(bob, 50000 * 10 ** 18, 10000);
        console.log("Bob final reputation:", repToken.balanceOf(bob));

        // Setup admin reputation
        currentTime += GRANT_COOLDOWN + 1 minutes;
        vm.roll(block.number + 1); // ✅ FIX: Advance block
        vm.warp(currentTime);
        repToken.grantInitialReputation(admin);

        currentTime += GRANT_COOLDOWN + 1 minutes;
        vm.roll(block.number + 1); // ✅ FIX: Advance block
        vm.warp(currentTime);
        repToken.mintReputation(admin, 200000 * 10 ** 18, 10000);
        console.log("Admin final reputation:", repToken.balanceOf(admin));

        vm.stopPrank();

        // Fund users with tokens
        console.log("Funding users...");
        stakingToken.mint(alice, 100000 * 10 ** 18);
        stakingToken.mint(bob, 100000 * 10 ** 18);
        stakingToken.mint(admin, 1000000 * 10 ** 18);

        // Set approvals
        console.log("Setting approvals...");
        vm.prank(alice);
        stakingToken.approve(address(market), type(uint256).max);
        vm.prank(bob);
        stakingToken.approve(address(market), type(uint256).max);
        vm.prank(admin);
        stakingToken.approve(address(market), type(uint256).max);

        // Final cooldown for market creation
        vm.warp(block.timestamp + MARKET_CREATION_COOLDOWN + 1 minutes);
        vm.roll(block.number + 10);

        console.log("Setup complete!");
        console.log("Final timestamp:", block.timestamp);
        console.log("Final block:", block.number);
    }

    // ============ MARKET CREATION TESTS ============

    function test_CreateMarket_Basic() public {
        string[] memory outcomes = new string[](2);
        outcomes[0] = "Yes";
        outcomes[1] = "No";

        uint256 tradingEnd = block.timestamp + STRATEGIC_DECISION_MIN;

        vm.expectEmit(true, false, false, true);
        emit MarketCreated(
            0,
            "Will BTC hit $100k?",
            tradingEnd,
            2,
            GovernancePredictionMarket.MarketCategory.STRATEGIC_DECISION,
            MIN_LIQUIDITY
        );

        vm.prank(admin);
        uint256 marketId = market.createMarket(
            "Will BTC hit $100k?",
            "Detailed description",
            bytes32(0),
            tradingEnd,
            outcomes,
            GovernancePredictionMarket.MarketCategory.STRATEGIC_DECISION,
            MIN_LIQUIDITY
        );

        assertEq(marketId, 0);
        assertEq(market.marketCount(), 1);
    }

    function test_CreateMarket_RevertWhen_TooShortDuration() public {
        string[] memory outcomes = new string[](2);
        outcomes[0] = "Yes";
        outcomes[1] = "No";

        vm.prank(admin);
        vm.expectRevert("Trading period too short");
        market.createMarket(
            "Question",
            "Description",
            bytes32(0),
            block.timestamp + 7 days,
            outcomes,
            GovernancePredictionMarket.MarketCategory.STRATEGIC_DECISION,
            MIN_LIQUIDITY
        );
    }

    function test_CreateMarket_RevertWhen_TooLongDuration() public {
        string[] memory outcomes = new string[](2);
        outcomes[0] = "Yes";
        outcomes[1] = "No";

        vm.prank(admin);
        vm.expectRevert("Trading period too long");
        market.createMarket(
            "Question",
            "Description",
            bytes32(0),
            block.timestamp + 100 days,
            outcomes,
            GovernancePredictionMarket.MarketCategory.STRATEGIC_DECISION,
            MIN_LIQUIDITY
        );
    }

    function test_CreateMarket_RevertWhen_TooFewOutcomes() public {
        string[] memory outcomes = new string[](1);
        outcomes[0] = "Only one";

        vm.prank(admin);
        vm.expectRevert("Invalid outcome count");
        market.createMarket(
            "Question",
            "Description",
            bytes32(0),
            block.timestamp + STRATEGIC_DECISION_MIN,
            outcomes,
            GovernancePredictionMarket.MarketCategory.STRATEGIC_DECISION,
            MIN_LIQUIDITY
        );
    }

    // ============ POSITION TAKING TESTS ============

    function test_TakePosition_Basic() public {
        uint256 marketId = _createAndSeedMarket();

        uint256 aliceBalBefore = stakingToken.balanceOf(alice);

        vm.prank(alice);
        market.takePosition(marketId, 0, 10 * 10 ** 18, 2000);

        uint256 aliceBalAfter = stakingToken.balanceOf(alice);
        assertEq(aliceBalBefore - aliceBalAfter, 10 * 10 ** 18);

        (uint256 stake, uint256 repStake, , ) = market.getUserPosition(
            marketId,
            alice,
            0
        );
        assertEq(stake, 10 * 10 ** 18);
        assertGt(repStake, 0);
    }

    function test_TakePosition_MEVProtection() public {
        uint256 marketId = _createAndSeedMarket();

        vm.prank(alice);
        market.takePosition(marketId, 0, 10 * 10 ** 18, 2000);

        // Try to take position too soon (same timestamp)
        vm.prank(alice);
        vm.expectRevert("MEV: trade cooldown active"); // FIXED: Use correct error message
        market.takePosition(marketId, 0, 10 * 10 ** 18, 2000);

        // Should work after proper time advancement
        vm.warp(block.timestamp + MIN_TRADE_INTERVAL + 1);
        vm.roll(block.number + 1);

        vm.prank(alice);
        market.takePosition(marketId, 1, 10 * 10 ** 18, 2000);
    }

    function test_TakePosition_RevertWhen_TradingEnded() public {
        uint256 marketId = _createAndSeedMarket();

        // Move past trading end time
        vm.warp(block.timestamp + STRATEGIC_DECISION_MIN + 1 days);

        vm.prank(alice);
        vm.expectRevert("Trading ended");
        market.takePosition(marketId, 0, 10 * 10 ** 18, 2000);
    }

    function test_TakePosition_GenesisPhaseProtection() public {
        uint256 marketId = _createMarketOnly();

        // Stay within genesis phase but advance enough to avoid immediate MEV protection
        vm.roll(block.number + 10);
        vm.warp(block.timestamp + 2 minutes);

        vm.prank(alice);
        vm.expectRevert("MEV: block volume limit exceeded");
        market.takePosition(marketId, 0, 5000 * 10 ** 18, 5000);
    }

    // ============ RESOLUTION TESTS ============

    function test_ResolveMarket_FullFlow() public {
        uint256 marketId = _createAndSeedMarket();
        _takeUserPositions(marketId);
        _resolveMarketProperly(marketId, 0);

        (, , , bool resolved, uint8 winningOutcome) = market.getMarket(
            marketId
        );
        assertTrue(resolved);
        assertEq(winningOutcome, 0);
    }

    function test_ResolveMarket_RevertWhen_WrongState() public {
        uint256 marketId = _createAndSeedMarket();

        // Try to resolve without going through proper states
        vm.warp(block.timestamp + STRATEGIC_DECISION_MIN + 1 days);

        vm.prank(admin);
        vm.expectRevert("Must complete full resolution process");
        market.resolveMarket(marketId, 0);
    }

    // ============ REWARD CLAIMING TESTS ============

    function test_ClaimRewards_WinningPosition() public {
        uint256 marketId = _createAndSeedMarket();
        _takeUserPositions(marketId);
        _resolveMarketProperly(marketId, 0); // Alice wins

        uint256 aliceBalBefore = stakingToken.balanceOf(alice);

        vm.prank(alice);
        market.claimRewards(marketId);

        uint256 aliceBalAfter = stakingToken.balanceOf(alice);
        assertGt(aliceBalAfter, aliceBalBefore, "Alice should receive payout");
    }

    function test_ClaimRewards_LosingPosition_Insurance() public {
        uint256 marketId = _createAndSeedMarket();
        _takeUserPositions(marketId);
        _resolveMarketProperly(marketId, 0); // Alice wins, Bob loses

        // Alice claims winning position first
        vm.prank(alice);
        market.claimRewards(marketId);

        uint256 bobBalBefore = stakingToken.balanceOf(bob);

        vm.prank(bob);
        market.claimRewards(marketId);

        uint256 bobBalAfter = stakingToken.balanceOf(bob);
        assertGt(
            bobBalAfter,
            bobBalBefore,
            "Bob should receive insurance payout"
        );
    }

    // ============ HELPER FUNCTIONS ============

    function _createAndSeedMarket() internal returns (uint256) {
        uint256 marketId = _createMarketOnly();

        console.log("Creating pre-seeded market with external liquidity...");

        // Position 1: Admin takes small position on outcome 0
        vm.prank(admin);
        market.takePosition(marketId, 0, 50 * 10 ** 18, 1000); // 50 ETH, 10% reputation
        console.log("Admin position 1: 50 ETH on outcome 0");

        // Advance time and block to reset MEV protection
        vm.warp(block.timestamp + MIN_TRADE_INTERVAL + 10);
        vm.roll(block.number + 1);

        // Position 2: Admin takes small position on outcome 1
        vm.prank(admin);
        market.takePosition(marketId, 1, 50 * 10 ** 18, 1000); // 50 ETH, 10% reputation
        console.log("Admin position 2: 50 ETH on outcome 1");

        // Advance time for user interactions
        vm.warp(block.timestamp + MIN_TRADE_INTERVAL + 30);
        vm.roll(block.number + 2);

        console.log("Market seeded with balanced liquidity (50/50 ETH)");
        return marketId;
    }

    function _createMarketOnly() internal returns (uint256) {
        console.log("Creating new market...");

        string[] memory outcomes = new string[](2);
        outcomes[0] = "Yes";
        outcomes[1] = "No";

        vm.prank(admin);
        uint256 marketId = market.createMarket(
            "Test prediction market",
            "Will this test pass?",
            bytes32(0),
            block.timestamp + STRATEGIC_DECISION_MIN,
            outcomes,
            GovernancePredictionMarket.MarketCategory.STRATEGIC_DECISION,
            MIN_LIQUIDITY
        );

        console.log("Market created with ID:", marketId);
        return marketId;
    }

    function _takeUserPositions(uint256 marketId) internal {
        console.log("Users taking positions...");

        // Alice takes position on outcome 0
        vm.prank(alice);
        market.takePosition(marketId, 0, 15 * 10 ** 18, 2000);
        console.log("Alice: 15 ETH on outcome 0");

        // Advance time for MEV protection
        vm.warp(block.timestamp + MIN_TRADE_INTERVAL + 10);
        vm.roll(block.number + 1);

        // Bob takes position on outcome 1
        vm.prank(bob);
        market.takePosition(marketId, 1, 15 * 10 ** 18, 2000);
        console.log("Bob: 15 ETH on outcome 1");

        // Advance for next operations
        vm.warp(block.timestamp + MIN_TRADE_INTERVAL + 10);
        vm.roll(block.number + 1);

        console.log("User positions taken successfully");
    }

    /**
     * @notice FIXED: Proper state transition flow following contract's _initializeStateTransitions()
     * @dev The contract defines these valid transitions:
     *      TRADING → SETTLEMENT
     *      SETTLEMENT → RESOLUTION_PROPOSED
     *      RESOLUTION_PROPOSED → DISPUTE_PERIOD (we'll use this path)
     *      DISPUTE_PERIOD → FINALIZATION_COOLDOWN
     *      FINALIZATION_COOLDOWN → RESOLVED
     */
    function _resolveMarketProperly(
        uint256 marketId,
        uint8 winningOutcome
    ) internal {
        console.log("Starting market resolution process...");

        // Wait until trading ends
        vm.warp(block.timestamp + STRATEGIC_DECISION_MIN + 1 days);
        console.log("Trading period ended");

        // STATE 1: TRADING → SETTLEMENT
        vm.prank(admin);
        market.updateResolutionState(
            marketId,
            GovernancePredictionMarket.ResolutionState.SETTLEMENT
        );
        console.log("State: SETTLEMENT");
        vm.warp(block.timestamp + SETTLEMENT_DELAY + 1 hours);

        // STATE 2: SETTLEMENT → RESOLUTION_PROPOSED
        vm.prank(admin);
        market.updateResolutionState(
            marketId,
            GovernancePredictionMarket.ResolutionState.RESOLUTION_PROPOSED
        );
        console.log("State: RESOLUTION_PROPOSED");
        vm.warp(block.timestamp + PROPOSAL_DELAY + 1 hours);

        // STATE 3: RESOLUTION_PROPOSED → DISPUTE_PERIOD
        // FIXED: Use DISPUTE_PERIOD instead of direct to FINALIZATION_COOLDOWN
        vm.prank(admin);
        market.updateResolutionState(
            marketId,
            GovernancePredictionMarket.ResolutionState.DISPUTE_PERIOD
        );
        console.log("State: DISPUTE_PERIOD");
        vm.warp(block.timestamp + DISPUTE_DELAY + 1 hours);

        // STATE 4: DISPUTE_PERIOD → FINALIZATION_COOLDOWN
        vm.prank(admin);
        market.updateResolutionState(
            marketId,
            GovernancePredictionMarket.ResolutionState.FINALIZATION_COOLDOWN
        );
        console.log("State: FINALIZATION_COOLDOWN");
        vm.warp(block.timestamp + FINALIZATION_DELAY + 1 hours);

        // STATE 5: FINALIZATION_COOLDOWN → RESOLVED (via resolveMarket)
        vm.prank(admin);
        market.resolveMarket(marketId, winningOutcome);
        console.log("Market RESOLVED with winning outcome:", winningOutcome);
    }
}
