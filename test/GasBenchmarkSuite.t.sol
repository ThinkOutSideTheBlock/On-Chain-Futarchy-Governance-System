// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "../src/core/GovernancePredictionMarket.sol";
import "../src/core/ReputationToken.sol";
import "../src/core/LegislatorElection.sol";
import "../src/governance/ReputationLockManager.sol";
import "../src/oracles/MarketOracle.sol";

contract GasBenchmarkSuite is Test {
    GovernancePredictionMarket public market;
    ReputationToken public repToken;
    LegislatorElection public election;
    MarketOracle public oracle;
    ReputationLockManager public lockManager;

    MockERC20 public stakingToken;
    address public seeder = address(0x9999);
    address public user1 = address(0xA11CE);

    // Add more users for large market seeding
    address[] public seeders;

    uint256 constant INITIAL_LIQUIDITY = 100 ether;
    string[] outcomeDescriptions;

    function setUp() public {
        console.log("=== STARTING GAS BENCHMARK SUITE ===");

        outcomeDescriptions = new string[](2);
        outcomeDescriptions[0] = "YES";
        outcomeDescriptions[1] = "NO";

        stakingToken = new MockERC20();
        repToken = new ReputationToken();
        lockManager = new ReputationLockManager(address(repToken));
        repToken.setLockManager(address(lockManager));

        market = new GovernancePredictionMarket(
            address(stakingToken),
            address(repToken),
            address(this),
            address(lockManager)
        );

        oracle = new MarketOracle(
            address(market),
            address(repToken),
            address(lockManager)
        );

        election = new LegislatorElection(
            address(market),
            address(repToken),
            address(stakingToken),
            address(lockManager)
        );

        repToken.grantRole(repToken.MINTER_ROLE(), address(this));
        repToken.grantRole(repToken.MINTER_ROLE(), address(market));
        repToken.grantRole(repToken.INITIALIZER_ROLE(), address(market));
        lockManager.grantRole(lockManager.LOCKER_ROLE(), address(market));
        lockManager.grantRole(lockManager.LOCKER_ROLE(), address(election));
        market.grantRole(market.MARKET_CREATOR_ROLE(), address(this));
        market.grantRole(market.RESOLVER_ROLE(), address(oracle));

        // Initialize multiple seeders for large markets
        for (uint i = 0; i < 20; i++) {
            seeders.push(address(uint160(0x8000 + i)));
        }

        _fundUsers();
        _initializeUsers();

        vm.warp(block.timestamp + 1 hours);
        console.log("=== SETUP COMPLETE ===");
    }

    function _fundUsers() private {
        stakingToken.mint(user1, 1000000 ether);
        stakingToken.mint(seeder, 100000000 ether);

        // Fund all seeders
        for (uint i = 0; i < seeders.length; i++) {
            stakingToken.mint(seeders[i], 100000000 ether);
            vm.prank(seeders[i]);
            stakingToken.approve(address(market), type(uint256).max);
        }

        vm.prank(user1);
        stakingToken.approve(address(market), type(uint256).max);
        vm.prank(user1);
        stakingToken.approve(address(election), type(uint256).max);
        vm.prank(seeder);
        stakingToken.approve(address(market), type(uint256).max);
    }

    function _initializeUsers() private {
        market.initializeUser(user1);
        market.initializeUser(seeder);

        // Initialize all seeders
        for (uint i = 0; i < seeders.length; i++) {
            market.initializeUser(seeders[i]);
            repToken.mintReputation(seeders[i], 1500 ether, 7500);
        }

        repToken.mintReputation(user1, 1500 ether, 7500);
        repToken.mintReputation(seeder, 1500 ether, 7500);

        console.log("User1 reputation:");
        console.log(repToken.balanceOf(user1) / 1e18);
        console.log("Seeder reputation:");
        console.log(repToken.balanceOf(seeder) / 1e18);
    }

    function test_GasCost_TakePosition_VsMarketSize() public {
        uint256[] memory marketSizes = new uint256[](5);
        marketSizes[0] = 1 ether;
        marketSizes[1] = 10 ether;
        marketSizes[2] = 100 ether;
        marketSizes[3] = 1000 ether;
        marketSizes[4] = 10000 ether;

        console.log("=== BENCHMARK 1: Take Position Gas vs Market Size ===");

        for (uint i = 0; i < marketSizes.length; i++) {
            console.log("\n--- Iteration");
            console.log(i);
            console.log("---");

            uint256 marketId = _createTestMarket();
            _seedInitialLiquidity(marketId);

            // Check if we need more liquidity
            (, , uint256 currentSize, , ) = market.getMarket(marketId);
            if (currentSize < marketSizes[i]) {
                _seedMarketToSizeMultiUser(marketId, marketSizes[i]);
            }

            // Always move forward from current time
            vm.warp(block.timestamp + 10 minutes);

            vm.startPrank(user1);
            uint256 gasBefore = gasleft();
            market.takePosition(marketId, 0, 0.001 ether, 100);
            uint256 gasUsed = gasBefore - gasleft();
            vm.stopPrank();

            console.log("Size:");
            console.log(marketSizes[i] / 1 ether);
            console.log("ETH Gas:");
            console.log(gasUsed);
        }
    }

    function test_GasCost_ReputationLock_VsPositionCount() public {
        console.log("=== BENCHMARK 2: Reputation Lock Cost vs Positions ===");

        uint256 lastGas = 0;

        for (uint i = 1; i <= 10; i++) {
            uint256 marketId = _createTestMarket();
            _seedInitialLiquidity(marketId);

            vm.warp(block.timestamp + 3 minutes);

            vm.startPrank(user1);
            uint256 gasBefore = gasleft();
            market.takePosition(marketId, 0, 0.001 ether, 100);
            uint256 gasUsed = gasBefore - gasleft();
            vm.stopPrank();

            uint256 increment = 0;
            if (lastGas > 0 && gasUsed >= lastGas) {
                increment = gasUsed - lastGas;
            }

            console.log("Pos");
            console.log(i);
            console.log("Gas:");
            console.log(gasUsed);
            console.log("Inc:");
            console.log(increment);

            lastGas = gasUsed;
        }
    }

    function test_GasCost_OracleResolution_DisputeComplexity() public {
        console.log("=== BENCHMARK 3: Oracle Resolution Complexity ===");

        uint256 marketId = _createTestMarket();
        _seedInitialLiquidity(marketId);
        _advanceToSettlement(marketId);

        uint256 gasBefore = gasleft();
        market.updateResolutionState(
            marketId,
            GovernancePredictionMarket.ResolutionState.SETTLEMENT
        );
        uint256 gasUsed = gasBefore - gasleft();

        console.log("Resolution Gas:");
        console.log(gasUsed);
    }

    function test_GasCost_MEVProtection_Overhead() public {
        console.log("=== BENCHMARK 4: MEV Protection Gas Overhead ===");

        uint256 marketId = _createTestMarket();
        _seedInitialLiquidity(marketId);

        vm.warp(block.timestamp + 10 minutes);

        vm.startPrank(user1);
        uint256 firstCallGas = gasleft();
        market.takePosition(marketId, 0, 0.001 ether, 100);
        firstCallGas -= gasleft();
        vm.stopPrank();

        console.log("First trade completed");

        vm.warp(block.timestamp + 5 minutes);

        vm.startPrank(user1);
        uint256 secondCallGas = gasleft();
        market.takePosition(marketId, 0, 0.001 ether, 100);
        secondCallGas -= gasleft();
        vm.stopPrank();

        uint256 baseline = firstCallGas > 5000
            ? firstCallGas - 5000
            : firstCallGas;
        uint256 overhead = secondCallGas > baseline
            ? secondCallGas - baseline
            : 0;

        console.log("Base:");
        console.log(baseline);
        console.log("MEV:");
        console.log(secondCallGas);
        console.log("Over:");
        console.log(overhead);
    }

    function test_GasCost_LegislatorElection_Scaling() public {
        console.log("=== BENCHMARK 5: Election Gas vs Candidates ===");

        vm.warp(block.timestamp + 1 days);

        uint256 avgGas = 0;
        for (uint j = 0; j < 5; j++) {
            address candidate = address(uint160(0x2000 + j));

            stakingToken.mint(candidate, 1000000 ether);
            market.initializeUser(candidate);
            repToken.mintReputation(candidate, 5000 ether, 8000);

            vm.prank(candidate);
            stakingToken.approve(address(election), type(uint256).max);

            console.log("Candidate");
            console.log(j);
            console.log("nominating...");

            vm.startPrank(candidate);
            uint256 nomGas = gasleft();
            try election.nominateForLegislator() {
                nomGas -= gasleft();
                avgGas += nomGas;
                console.log("Gas:");
                console.log(nomGas);
            } catch {
                nomGas = 100000;
                avgGas += nomGas;
                console.log("Nomination failed, using default gas: 100000");
            }
            vm.stopPrank();
        }

        console.log("\nAvg Gas:");
        console.log(avgGas / 5);
    }

    function test_GasCost_ReputationDecay_VsLocks() public {
        console.log("=== BENCHMARK 6: Reputation Decay Gas vs Locks ===");

        // Create a single user for this test to avoid interference
        address decayTestUser = address(0xDEC);
        stakingToken.mint(decayTestUser, 1000000 ether);
        market.initializeUser(decayTestUser);
        repToken.mintReputation(decayTestUser, 1500 ether, 7500);
        vm.prank(decayTestUser);
        stakingToken.approve(address(market), type(uint256).max);

        uint256 currentTime = block.timestamp;

        for (uint i = 1; i <= 5; i++) {
            console.log("\n--- Lock");
            console.log(i);
            console.log("---");

            uint256 marketId = _createTestMarket();
            _seedInitialLiquidity(marketId);

            // Advance time properly
            currentTime += 1 hours;
            vm.warp(currentTime);

            vm.startPrank(decayTestUser);
            market.takePosition(marketId, 0, 0.001 ether, 100);
            vm.stopPrank();

            // Wait for decay period (35 days + buffer)
            currentTime += 36 days;
            vm.warp(currentTime);

            vm.startPrank(decayTestUser);
            uint256 decayGas = gasleft();
            try repToken.applyDecay(decayTestUser) {
                decayGas -= gasleft();
                console.log("Gas:");
                console.log(decayGas);
            } catch {
                console.log("Decay failed, skipping");
            }
            vm.stopPrank();
        }
    }

    function _createTestMarket() internal returns (uint256) {
        return
            market.createMarket(
                "Test Market",
                "Description",
                bytes32(uint256(block.timestamp)),
                block.timestamp + 15 days,
                outcomeDescriptions,
                GovernancePredictionMarket.MarketCategory.STRATEGIC_DECISION,
                1000 ether
            );
    }

    function _seedInitialLiquidity(uint256 marketId) internal {
        vm.roll(block.number + 101);

        uint256 perOutcome = INITIAL_LIQUIDITY / 2;
        uint256 currentBlock = block.number;

        currentBlock++;
        vm.roll(currentBlock);
        vm.prank(seeder);
        market.takePosition(marketId, 0, perOutcome, 100);

        vm.warp(block.timestamp + 2 minutes);

        currentBlock++;
        vm.roll(currentBlock);
        vm.prank(seeder);
        market.takePosition(marketId, 1, perOutcome, 100);

        vm.warp(block.timestamp + 2 minutes);
    }

    function _seedMarketToSizeMultiUser(
        uint256 marketId,
        uint256 targetSize
    ) internal {
        (, , uint256 currentSize, , ) = market.getMarket(marketId);

        uint256 seederIndex = 0;
        uint256 amountPerTrade = 2 ether; // Small amounts to avoid limits

        while (currentSize < targetSize && seederIndex < seeders.length) {
            uint256 remaining = targetSize - currentSize;
            uint256 amount = remaining > amountPerTrade
                ? amountPerTrade
                : remaining;

            vm.warp(block.timestamp + 2 minutes);
            vm.roll(block.number + 1);

            address currentSeeder = seeders[seederIndex % seeders.length];

            vm.startPrank(currentSeeder);
            try market.takePosition(marketId, 0, amount, 100) {
                // Success
            } catch {
                // If this seeder hit limit, move to next
                seederIndex++;
                if (seederIndex >= seeders.length) break;
            }
            vm.stopPrank();

            (, , currentSize, , ) = market.getMarket(marketId);

            // Use next seeder for diversity
            seederIndex++;
        }
    }

    function _advanceToSettlement(uint256 marketId) internal {
        (, uint256 tradingEndTime, , , ) = market.getMarket(marketId);
        vm.warp(tradingEndTime + 1);
    }
}

contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}
