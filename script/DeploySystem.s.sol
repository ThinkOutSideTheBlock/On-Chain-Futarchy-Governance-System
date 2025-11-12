// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import "forge-std/console.sol";

// Core contracts
import "../src/core/GovernancePredictionMarket.sol";
import "../src/core/ReputationToken.sol";
import "../src/core/LegislatorElection.sol";

// Governance modules
import "../src/governance/ReputationLockManager.sol";
import "../src/governance/ProposalManager.sol";

// Oracles
import {ChainlinkPriceOracleImpl} from "../src/oracles/ChainlinkPriceOracle.sol";
import "../src/oracles/MarketOracle.sol";

// OpenZeppelin ERC20 for DummyStakingToken
import "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

/**
 * @title DummyStakingToken
 * @notice Mock ERC20 token for testing/local deployment
 */
contract DummyStakingToken is ERC20 {
    constructor() ERC20("Staking Token", "STK") {
        _mint(msg.sender, 1000000 ether);
    }
}

/**
 * @title MockChainlinkFeed
 * @notice Mock Chainlink price feed for testing/local deployment
 */
contract MockChainlinkFeed {
    uint8 public decimals;
    int256 public price;
    uint80 public latestRound;

    constructor(uint8 _decimals, int256 _price) {
        decimals = _decimals;
        price = _price;
        latestRound = 1;
    }

    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        return (
            latestRound,
            price,
            block.timestamp,
            block.timestamp,
            latestRound
        );
    }

    function updatePrice(int256 newPrice) external {
        price = newPrice;
        latestRound++;
    }
}

/**
 * @title DeploySystem
 * @notice Foundry deployment script that replaces the oversized factory contract
 * @dev This script deploys all contracts individually and sets up roles/permissions
 */
contract DeploySystem is Script {
    address public constant ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    // Deployed contract addresses
    ReputationToken public reputationToken;
    ReputationLockManager public lockManager;
    GovernancePredictionMarket public predictionMarket;
    LegislatorElection public legislatorElection;
    ChainlinkPriceOracleImpl public chainlinkOracle;
    MarketOracle public marketOracle;
    ProposalManager public proposalManager;

    // Test/mock contracts
    DummyStakingToken public stakingToken;
    MockChainlinkFeed public mockPriceFeed;

    /**
     * @notice Main deployment function
     * @dev Set environment variables before running:
     *      - STAKING_TOKEN: Address of existing staking token (optional, will deploy mock if not set)
     *      - FEE_RECIPIENT: Address to receive trading fees (defaults to deployer)
     *      - CHAINLINK_FEED: Address of Chainlink ETH/USD price feed (optional, will deploy mock if not set)
     */
    function run() external {
        address deployer = msg.sender;
        console.log("Deployer address:", deployer);
        console.log("---");

        vm.startBroadcast();

        // Get deployment parameters from environment or use defaults
        address stakingTokenAddr = vm.envOr("STAKING_TOKEN", address(0));
        address feeRecipient = vm.envOr("FEE_RECIPIENT", deployer);
        address chainlinkFeedAddr = vm.envOr("CHAINLINK_FEED", address(0));

        // Deploy or use existing staking token
        if (stakingTokenAddr == address(0)) {
            console.log("Deploying DummyStakingToken...");
            stakingToken = new DummyStakingToken();
            stakingTokenAddr = address(stakingToken);
            console.log("  DummyStakingToken:", stakingTokenAddr);
        } else {
            console.log("Using existing staking token:", stakingTokenAddr);
        }

        // Deploy or use existing Chainlink price feed
        if (chainlinkFeedAddr == address(0)) {
            console.log("Deploying MockChainlinkFeed...");
            mockPriceFeed = new MockChainlinkFeed(8, 2000e8); // $2000 ETH
            chainlinkFeedAddr = address(mockPriceFeed);
            console.log("  MockChainlinkFeed:", chainlinkFeedAddr);
        } else {
            console.log("Using existing Chainlink feed:", chainlinkFeedAddr);
        }

        console.log("---");
        console.log("Deployment Parameters:");
        console.log("  Staking Token:", stakingTokenAddr);
        console.log("  Fee Recipient:", feeRecipient);
        console.log("  Chainlink Feed:", chainlinkFeedAddr);
        console.log("---");

        // Deploy all contracts
        _deployContracts(stakingTokenAddr, feeRecipient, chainlinkFeedAddr);

        // Setup roles and permissions
        _setupRoles(deployer);

        // Verify deployment
        _verifyDeployment(deployer);

        // Output deployment info
        _outputDeploymentInfo();

        vm.stopBroadcast();

        console.log("---");
        console.log("Deployment completed successfully!");
    }

    /**
     * @notice Deploy all system contracts
     */
    function _deployContracts(
        address _stakingToken,
        address _feeRecipient,
        address _chainlinkFeed
    ) private {
        console.log("Deploying contracts...");

        // 1. Deploy ReputationToken
        console.log("  [1/7] Deploying ReputationToken...");
        reputationToken = new ReputationToken();
        console.log("    ReputationToken:", address(reputationToken));

        // 2. Deploy ReputationLockManager
        console.log("  [2/7] Deploying ReputationLockManager...");
        lockManager = new ReputationLockManager(address(reputationToken));
        console.log("    ReputationLockManager:", address(lockManager));

        // Set lock manager on reputation token
        reputationToken.setLockManager(address(lockManager));

        // 3. Deploy GovernancePredictionMarket
        console.log("  [3/7] Deploying GovernancePredictionMarket...");
        predictionMarket = new GovernancePredictionMarket(
            _stakingToken,
            address(reputationToken),
            _feeRecipient,
            address(lockManager)
        );
        console.log("    GovernancePredictionMarket:", address(predictionMarket));

        // 4. Deploy LegislatorElection
        console.log("  [4/7] Deploying LegislatorElection...");
        legislatorElection = new LegislatorElection(
            address(predictionMarket),
            address(reputationToken),
            _stakingToken,
            address(lockManager)
        );
        console.log("    LegislatorElection:", address(legislatorElection));

        // 5. Deploy ChainlinkPriceOracle
        console.log("  [5/7] Deploying ChainlinkPriceOracle...");
        chainlinkOracle = new ChainlinkPriceOracleImpl();
        chainlinkOracle.addPriceFeed(ETH_ADDRESS, _chainlinkFeed);
        console.log("    ChainlinkPriceOracle:", address(chainlinkOracle));

        // 6. Deploy MarketOracle
        console.log("  [6/7] Deploying MarketOracle...");
        marketOracle = new MarketOracle(
            address(predictionMarket),
            address(legislatorElection),
            address(chainlinkOracle)
        );
        console.log("    MarketOracle:", address(marketOracle));

        // 7. Deploy ProposalManager
        console.log("  [7/7] Deploying ProposalManager...");
        proposalManager = new ProposalManager(
            address(predictionMarket),
            address(legislatorElection),
            address(marketOracle)
        );
        console.log("    ProposalManager:", address(proposalManager));

        console.log("---");
    }

    /**
     * @notice Setup roles and permissions for all contracts
     */
    function _setupRoles(address deployer) private {
        console.log("Setting up roles and permissions...");

        // ============================================================
        // 1. ReputationToken roles
        // ============================================================
        console.log("  [1/7] ReputationToken roles...");

        // Grant operational roles
        reputationToken.grantRole(reputationToken.MINTER_ROLE(), address(predictionMarket));
        reputationToken.grantRole(reputationToken.SLASHER_ROLE(), address(marketOracle));
        reputationToken.grantRole(reputationToken.SLASHER_ROLE(), address(legislatorElection));

        // Grant INITIALIZER_ROLE
        bytes32 INITIALIZER_ROLE = reputationToken.INITIALIZER_ROLE();
        reputationToken.grantRole(INITIALIZER_ROLE, address(predictionMarket));

        // Transfer admin to deployer (deployer is already admin from broadcast context)
        // No need to renounce - deployer keeps admin role

        // ============================================================
        // 2. ReputationLockManager roles
        // ============================================================
        console.log("  [2/7] ReputationLockManager roles...");

        lockManager.grantRole(lockManager.LOCKER_ROLE(), address(predictionMarket));
        lockManager.grantRole(lockManager.LOCKER_ROLE(), address(marketOracle));
        lockManager.grantRole(lockManager.LOCKER_ROLE(), address(legislatorElection));
        lockManager.grantRole(lockManager.DECAY_MANAGER_ROLE(), deployer);

        // ============================================================
        // 3. GovernancePredictionMarket roles
        // ============================================================
        console.log("  [3/7] GovernancePredictionMarket roles...");

        predictionMarket.grantRole(predictionMarket.RESOLVER_ROLE(), address(marketOracle));
        predictionMarket.grantRole(predictionMarket.MARKET_CREATOR_ROLE(), address(proposalManager));
        predictionMarket.grantRole(predictionMarket.MARKET_CREATOR_ROLE(), deployer);

        // ============================================================
        // 4. LegislatorElection roles
        // ============================================================
        console.log("  [4/7] LegislatorElection roles...");

        legislatorElection.grantRole(legislatorElection.GOVERNANCE_ROLE(), address(proposalManager));
        legislatorElection.grantRole(legislatorElection.GOVERNANCE_ROLE(), deployer);

        // ============================================================
        // 5. MarketOracle roles
        // ============================================================
        console.log("  [5/7] MarketOracle roles...");

        marketOracle.grantRole(marketOracle.ORACLE_MANAGER_ROLE(), deployer);

        // ============================================================
        // 6. ProposalManager roles
        // ============================================================
        console.log("  [6/7] ProposalManager roles...");

        // Deployer already has admin role from constructor

        // ============================================================
        // 7. ChainlinkPriceOracle roles
        // ============================================================
        console.log("  [7/7] ChainlinkPriceOracle roles...");

        chainlinkOracle.grantRole(chainlinkOracle.PRICE_RECORDER_ROLE(), deployer);
        chainlinkOracle.grantRole(chainlinkOracle.PRICE_ADMIN_ROLE(), deployer);

        console.log("---");
    }

    /**
     * @notice Verify deployment and role configuration
     */
    function _verifyDeployment(address deployer) private view {
        console.log("Verifying deployment...");

        bytes32 adminRole = 0x00; // DEFAULT_ADMIN_ROLE

        // Verify deployer has admin roles on all contracts
        require(
            reputationToken.hasRole(adminRole, deployer),
            "Deployer missing ReputationToken admin"
        );
        require(
            lockManager.hasRole(adminRole, deployer),
            "Deployer missing LockManager admin"
        );
        require(
            predictionMarket.hasRole(adminRole, deployer),
            "Deployer missing PredictionMarket admin"
        );
        require(
            legislatorElection.hasRole(adminRole, deployer),
            "Deployer missing LegislatorElection admin"
        );
        require(
            marketOracle.hasRole(adminRole, deployer),
            "Deployer missing MarketOracle admin"
        );
        require(
            proposalManager.hasRole(adminRole, deployer),
            "Deployer missing ProposalManager admin"
        );
        require(
            chainlinkOracle.hasRole(adminRole, deployer),
            "Deployer missing ChainlinkOracle admin"
        );

        console.log("  Deployer has all admin roles: OK");

        // Verify operational roles are granted
        require(
            reputationToken.hasRole(reputationToken.MINTER_ROLE(), address(predictionMarket)),
            "PredictionMarket missing MINTER_ROLE"
        );
        require(
            reputationToken.hasRole(reputationToken.SLASHER_ROLE(), address(marketOracle)),
            "MarketOracle missing SLASHER_ROLE"
        );
        require(
            predictionMarket.hasRole(predictionMarket.RESOLVER_ROLE(), address(marketOracle)),
            "MarketOracle missing RESOLVER_ROLE"
        );
        require(
            lockManager.hasRole(lockManager.LOCKER_ROLE(), address(predictionMarket)),
            "PredictionMarket missing LOCKER_ROLE"
        );

        console.log("  All operational roles granted: OK");
        console.log("---");
    }

    /**
     * @notice Output deployment information in JSON format
     */
    function _outputDeploymentInfo() private view {
        console.log("CONTRACT_ADDRESSES_JSON_START");
        console.log("{");
        console.log('  "ReputationToken": "', address(reputationToken), '",');
        console.log('  "ReputationLockManager": "', address(lockManager), '",');
        console.log('  "GovernancePredictionMarket": "', address(predictionMarket), '",');
        console.log('  "LegislatorElection": "', address(legislatorElection), '",');
        console.log('  "ChainlinkPriceOracle": "', address(chainlinkOracle), '",');
        console.log('  "MarketOracle": "', address(marketOracle), '",');
        console.log('  "ProposalManager": "', address(proposalManager), '"');
        console.log("}");
        console.log("CONTRACT_ADDRESSES_JSON_END");
    }
}