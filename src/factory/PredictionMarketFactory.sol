// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "../core/GovernancePredictionMarket.sol";
import "../core/ReputationToken.sol";
import "../core/LegislatorElection.sol";
import "../oracles/MarketOracle.sol";
import "../oracles/ChainlinkPriceOracle.sol";
import "../governance/ProposalManager.sol";
import "../governance/ReputationLockManager.sol";
/**
 * @title PredictionMarketFactory
 * @notice Factory contract to deploy the complete governance prediction market system
 * @dev Production-ready implementation with complete role renunciation
 */
contract PredictionMarketFactory {
    address public constant ETH_ADDRESS =
        0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    event SystemDeployed(
        address indexed deployer,
        address stakingToken,
        address reputationToken,
        address predictionMarket,
        address legislatorElection,
        address marketOracle,
        address proposalManager,
        address chainlinkOracle,
        uint256 timestamp
    );

    event ContractDeployed(
        string indexed contractType,
        address indexed contractAddress
    );

    event RoleSetupCompleted(
        address indexed contractAddress,
        string contractType
    );

    struct DeployedSystem {
        address stakingToken;
        address reputationToken;
        address lockManager; //  FIX: Add lockManager address
        address predictionMarket;
        address legislatorElection;
        address marketOracle;
        address proposalManager;
        address chainlinkOracle;
        address deployer;
        uint256 deploymentTime;
    }

    mapping(bytes32 => DeployedSystem) public deployedSystems;
    address[] public allDeployments;

    /**
     * @notice Deploy complete governance prediction market system
     * @param _stakingToken Address of the ERC20 token used for staking
     * @param _feeRecipient Address to receive trading fees
     * @param _chainlinkPriceFeed Address of Chainlink ETH/USD price feed
     * @return contracts Array of deployed contract addresses
     */
    function deploySystem(
        address _stakingToken,
        address _feeRecipient,
        address _chainlinkPriceFeed
    ) external returns (address[] memory contracts) {
        require(_stakingToken != address(0), "Invalid staking token");
        require(_feeRecipient != address(0), "Invalid fee recipient");
        require(_chainlinkPriceFeed != address(0), "Invalid Chainlink feed");

        contracts = new address[](8); //  Changed from 7 to 8

        // 1. Deploy ReputationToken
        ReputationToken repToken = new ReputationToken();
        contracts[0] = address(repToken);
        emit ContractDeployed("ReputationToken", address(repToken));

        // 2. Deploy ReputationLockManager (BEFORE market!)
        ReputationLockManager lockManager = new ReputationLockManager(
            address(repToken)
        );
        contracts[7] = address(lockManager);
        emit ContractDeployed("ReputationLockManager", address(lockManager));
        repToken.setLockManager(address(lockManager));

        // 3. Deploy GovernancePredictionMarket WITH lockManager
        GovernancePredictionMarket market = new GovernancePredictionMarket(
            _stakingToken,
            address(repToken),
            _feeRecipient,
            address(lockManager) //  4th parameter
        );
        contracts[1] = address(market);
        emit ContractDeployed("GovernancePredictionMarket", address(market));

        // 4. Deploy LegislatorElection WITH lockManager (4th parameter)
        LegislatorElection election = new LegislatorElection(
            address(market),
            address(repToken),
            _stakingToken,
            address(lockManager) //  FIX: Add 4th parameter
        );
        contracts[2] = address(election);
        emit ContractDeployed("LegislatorElection", address(election));

        // 5. Deploy ChainlinkPriceOracle
        ChainlinkPriceOracleImpl chainlinkOracle = new ChainlinkPriceOracleImpl();
        chainlinkOracle.addPriceFeed(ETH_ADDRESS, _chainlinkPriceFeed);
        contracts[3] = address(chainlinkOracle);
        emit ContractDeployed("ChainlinkPriceOracle", address(chainlinkOracle));

        // 6. Deploy MarketOracle
        MarketOracle oracle = new MarketOracle(
            address(market),
            address(election),
            address(chainlinkOracle)
        );
        contracts[4] = address(oracle);
        emit ContractDeployed("MarketOracle", address(oracle));

        // 7. Deploy ProposalManager
        ProposalManager proposals = new ProposalManager(
            address(market),
            address(election),
            address(oracle)
        );
        contracts[5] = address(proposals);
        emit ContractDeployed("ProposalManager", address(proposals));

        // 8. Store staking token address for completeness
        contracts[6] = _stakingToken;

        // Set up roles and permissions with complete renunciation
        _setupRoles(
            repToken,
            market,
            election,
            oracle,
            proposals,
            chainlinkOracle,
            lockManager //  Add lockManager
        );

        // Store deployment info
        bytes32 systemId = keccak256(
            abi.encodePacked(msg.sender, block.timestamp, _stakingToken)
        );

        deployedSystems[systemId] = DeployedSystem({
            stakingToken: _stakingToken,
            reputationToken: address(repToken),
            lockManager: address(lockManager), //  FIX: Store lockManager
            predictionMarket: address(market),
            legislatorElection: address(election),
            marketOracle: address(oracle),
            proposalManager: address(proposals),
            chainlinkOracle: address(chainlinkOracle),
            deployer: msg.sender,
            deploymentTime: block.timestamp
        });

        allDeployments.push(address(market));

        emit SystemDeployed(
            msg.sender,
            _stakingToken,
            address(repToken),
            address(market),
            address(election),
            address(oracle),
            address(proposals),
            address(chainlinkOracle),
            block.timestamp
        );

        return contracts;
    }
    function _setupRoles(
        ReputationToken repToken,
        GovernancePredictionMarket market,
        LegislatorElection election,
        MarketOracle oracle,
        ProposalManager proposals,
        ChainlinkPriceOracleImpl chainlinkOracle,
        ReputationLockManager lockManager
    ) private {
        // ============================================================
        // 1. ReputationToken roles (FIXED ORDER)
        // ============================================================

        //  FIX: Grant ALL operational roles FIRST (while factory is still admin)
        repToken.grantRole(repToken.MINTER_ROLE(), address(market));
        repToken.grantRole(repToken.SLASHER_ROLE(), address(oracle));
        repToken.grantRole(repToken.SLASHER_ROLE(), address(election));

        //  FIX: Grant INITIALIZER_ROLE using correct constant
        bytes32 INITIALIZER_ROLE = repToken.INITIALIZER_ROLE(); // Use contract's constant
        repToken.grantRole(INITIALIZER_ROLE, address(market));

        //  FIX: Transfer admin to deployer BEFORE renouncing
        repToken.grantRole(repToken.DEFAULT_ADMIN_ROLE(), msg.sender);

        //  FIX: Renounce factory's admin role LAST
        repToken.renounceRole(repToken.DEFAULT_ADMIN_ROLE(), address(this));

        emit RoleSetupCompleted(address(repToken), "ReputationToken");

        // ============================================================
        // 2. ReputationLockManager roles
        // ============================================================
        lockManager.grantRole(lockManager.LOCKER_ROLE(), address(market));
        lockManager.grantRole(lockManager.LOCKER_ROLE(), address(oracle));
        lockManager.grantRole(lockManager.LOCKER_ROLE(), address(election));
        lockManager.grantRole(lockManager.DECAY_MANAGER_ROLE(), msg.sender);
        lockManager.grantRole(lockManager.DEFAULT_ADMIN_ROLE(), msg.sender);
        lockManager.renounceRole(
            lockManager.DEFAULT_ADMIN_ROLE(),
            address(this)
        );
        emit RoleSetupCompleted(address(lockManager), "ReputationLockManager");

        // ============================================================
        // 3. GovernancePredictionMarket roles
        // ============================================================
        market.grantRole(market.RESOLVER_ROLE(), address(oracle));
        market.grantRole(market.MARKET_CREATOR_ROLE(), address(proposals));
        market.grantRole(market.MARKET_CREATOR_ROLE(), msg.sender);
        market.grantRole(market.DEFAULT_ADMIN_ROLE(), msg.sender);
        market.renounceRole(market.DEFAULT_ADMIN_ROLE(), address(this));
        emit RoleSetupCompleted(address(market), "GovernancePredictionMarket");

        // ============================================================
        // 4. LegislatorElection roles
        // ============================================================
        election.grantRole(election.GOVERNANCE_ROLE(), address(proposals));
        election.grantRole(election.GOVERNANCE_ROLE(), msg.sender);
        election.grantRole(election.DEFAULT_ADMIN_ROLE(), msg.sender);
        election.renounceRole(election.DEFAULT_ADMIN_ROLE(), address(this));
        emit RoleSetupCompleted(address(election), "LegislatorElection");

        // ============================================================
        // 5. MarketOracle roles
        // ============================================================
        oracle.grantRole(oracle.ORACLE_MANAGER_ROLE(), msg.sender);
        oracle.grantRole(oracle.DEFAULT_ADMIN_ROLE(), msg.sender);
        oracle.renounceRole(oracle.DEFAULT_ADMIN_ROLE(), address(this));
        emit RoleSetupCompleted(address(oracle), "MarketOracle");

        // ============================================================
        // 6. ProposalManager roles
        // ============================================================
        proposals.grantRole(proposals.DEFAULT_ADMIN_ROLE(), msg.sender);
        proposals.renounceRole(proposals.DEFAULT_ADMIN_ROLE(), address(this));
        emit RoleSetupCompleted(address(proposals), "ProposalManager");

        // ============================================================
        // 7. ChainlinkPriceOracle roles
        // ============================================================
        chainlinkOracle.grantRole(
            chainlinkOracle.PRICE_RECORDER_ROLE(),
            msg.sender
        );
        chainlinkOracle.grantRole(
            chainlinkOracle.PRICE_ADMIN_ROLE(),
            msg.sender
        );
        chainlinkOracle.grantRole(
            chainlinkOracle.DEFAULT_ADMIN_ROLE(),
            msg.sender
        );
        chainlinkOracle.renounceRole(
            chainlinkOracle.DEFAULT_ADMIN_ROLE(),
            address(this)
        );
        emit RoleSetupCompleted(
            address(chainlinkOracle),
            "ChainlinkPriceOracle"
        );
    }
    /**
     * @notice Get deployment count
     */
    function getDeploymentCount() external view returns (uint256) {
        return allDeployments.length;
    }

    /**
     * @notice Get deployed system by system ID
     */
    function getDeployedSystem(
        bytes32 systemId
    ) external view returns (DeployedSystem memory) {
        return deployedSystems[systemId];
    }

    /**
     * @notice Get all deployments
     */
    function getAllDeployments() external view returns (address[] memory) {
        return allDeployments;
    }

    /**
     * @notice Generate system ID for a deployment
     */
    function generateSystemId(
        address deployer,
        uint256 timestamp,
        address stakingToken
    ) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(deployer, timestamp, stakingToken));
    }

    /**
     * @notice Verify factory has renounced all admin roles
     * @dev Use this function to verify complete role renunciation
     * @return hasNoRoles True if factory has successfully renounced all admin roles
     */
    function verifyFactoryRenunciation(
        address repToken,
        address lockManager, //  FIX: Add parameter
        address market,
        address election,
        address oracle,
        address proposals,
        address chainlinkOracle
    ) external view returns (bool hasNoRoles) {
        bytes32 adminRole = 0x00; // DEFAULT_ADMIN_ROLE

        bool noRepTokenRole = !ReputationToken(repToken).hasRole(
            adminRole,
            address(this)
        );
        bool noLockManagerRole = !ReputationLockManager(lockManager).hasRole( //  FIX: Add check
                adminRole,
                address(this)
            );
        bool noMarketRole = !GovernancePredictionMarket(market).hasRole(
            adminRole,
            address(this)
        );
        bool noElectionRole = !LegislatorElection(election).hasRole(
            adminRole,
            address(this)
        );
        bool noOracleRole = !MarketOracle(payable(oracle)).hasRole(
            adminRole,
            address(this)
        );
        bool noProposalsRole = !ProposalManager(payable(proposals)).hasRole(
            adminRole,
            address(this)
        );
        bool noChainlinkRole = !ChainlinkPriceOracleImpl(chainlinkOracle)
            .hasRole(adminRole, address(this));

        return
            noRepTokenRole &&
            noLockManagerRole && //  FIX: Add to return
            noMarketRole &&
            noElectionRole &&
            noOracleRole &&
            noProposalsRole &&
            noChainlinkRole;
    }

    /**
     * @notice Get detailed role status for a deployed system
     * @dev Returns whether factory still has admin role on each contract
     */
    function getSystemRoleStatus(
        bytes32 systemId
    )
        external
        view
        returns (
            bool factoryHasRepTokenAdmin,
            bool factoryHasLockManagerAdmin, //  FIX: Add return value
            bool factoryHasMarketAdmin,
            bool factoryHasElectionAdmin,
            bool factoryHasOracleAdmin,
            bool factoryHasProposalsAdmin,
            bool factoryHasChainlinkAdmin
        )
    {
        DeployedSystem memory system = deployedSystems[systemId];
        require(system.deployer != address(0), "System not found");

        bytes32 adminRole = 0x00; // DEFAULT_ADMIN_ROLE

        factoryHasRepTokenAdmin = ReputationToken(system.reputationToken)
            .hasRole(adminRole, address(this));

        factoryHasLockManagerAdmin = ReputationLockManager(system.lockManager)
            .hasRole(adminRole, address(this));
        factoryHasMarketAdmin = GovernancePredictionMarket(
            system.predictionMarket
        ).hasRole(adminRole, address(this));
        factoryHasElectionAdmin = LegislatorElection(system.legislatorElection)
            .hasRole(adminRole, address(this));
        factoryHasOracleAdmin = MarketOracle(payable(system.marketOracle))
            .hasRole(adminRole, address(this));
        factoryHasProposalsAdmin = ProposalManager(
            payable(system.proposalManager)
        ).hasRole(adminRole, address(this));
        factoryHasChainlinkAdmin = ChainlinkPriceOracleImpl(
            system.chainlinkOracle
        ).hasRole(adminRole, address(this));
    }
}
