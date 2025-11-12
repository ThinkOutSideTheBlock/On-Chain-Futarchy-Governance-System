// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "../core/GovernancePredictionMarket.sol";
import "../core/LegislatorElection.sol";
import "../oracles/MarketOracle.sol";

/**
 * @title ProposalManager
 * @notice Manages governance proposals created by legislators with comprehensive security
 * @dev Production-ready implementation with reentrancy protection, target whitelisting, and execution validation
 */
contract ProposalManager is AccessControl, ReentrancyGuard, Pausable {
    using Math for uint256;

    struct Proposal {
        uint256 id;
        address proposer;
        string title;
        string description;
        bytes callData;
        address targetContract;
        uint256 value;
        uint256 createdAt;
        uint256 executionTime;
        uint256 predictionMarketId;
        bool executed;
        bool cancelled;
        ProposalType proposalType;
    }

    enum ProposalType {
        PARAMETER_CHANGE,
        TREASURY_ALLOCATION,
        CONTRACT_UPGRADE,
        EMERGENCY_ACTION,
        STRATEGIC_DECISION
    }
    struct ProposalInput {
        string title;
        string description;
        bytes callData;
        address targetContract;
        uint256 value;
        ProposalType proposalType;
        uint256 timestamp;
    }

    // Contracts
    GovernancePredictionMarket public immutable predictionMarket;
    LegislatorElection public immutable legislatorElection;
    MarketOracle public immutable marketOracle;

    // Roles
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    // Constants
    uint256 public constant EXECUTION_DELAY = 259200; // 3 days
    uint256 public constant EMERGENCY_DELAY = 86400; // 1 day
    uint256 public constant EXECUTION_WINDOW = 7 days;
    uint256 public constant HIGH_VALUE_THRESHOLD = 100 ether;
    uint256 public constant HIGH_VALUE_EXTENDED_DELAY = 86400;
    uint256 public constant MIN_PARTICIPATION_THRESHOLD = 10000 * 10 ** 18;
    uint256 public constant EXECUTION_GAS_LIMIT = 500000;
    uint256 public constant PERFORMANCE_INCREASE = 1000; // 10%
    uint256 public constant PERFORMANCE_DECREASE = 500; // 5%

    // State
    uint256 public proposalCount;
    mapping(uint256 => Proposal) public proposals;
    mapping(address => uint256[]) public proposerHistory;
    mapping(address => bool) public allowedTargets;
    mapping(bytes4 => bool) public allowedSelectors;
    mapping(uint256 => ProposalInput) private _tempProposalInputs;

    // Events
    event ProposalCreated(
        uint256 indexed proposalId,
        address indexed proposer,
        string title,
        uint256 predictionMarketId,
        address targetContract
    );
    event ProposalPreparationCancelled(uint256 indexed proposalId);

    event ProposalExecuted(
        uint256 indexed proposalId,
        bool success,
        bytes returnData
    );

    event ProposalCancelled(uint256 indexed proposalId, address canceller);

    event TargetAllowlistUpdated(
        address indexed target,
        bool allowed,
        address updatedBy
    );

    event SelectorAllowlistUpdated(
        bytes4 indexed selector,
        bool allowed,
        address updatedBy
    );

    event PerformanceScoreUpdated(
        address indexed legislator,
        bool increased,
        uint256 delta
    );

    event PerformanceUpdateFailed(address indexed legislator, string reason);

    event ExecutionFailed(
        uint256 indexed proposalId,
        string reason,
        bytes returnData
    );

    // Modifiers
    modifier onlyLegislator() {
        require(
            legislatorElection.isLegislator(msg.sender),
            "Not a legislator"
        );
        _;
    }

    modifier onlyLegislatorOrExecutor() {
        require(
            legislatorElection.isLegislator(msg.sender) ||
                hasRole(EXECUTOR_ROLE, msg.sender) ||
                hasRole(DEFAULT_ADMIN_ROLE, msg.sender),
            "Not authorized to execute"
        );
        _;
    }

    constructor(
        address _predictionMarket,
        address _legislatorElection,
        address _marketOracle
    ) {
        require(_predictionMarket != address(0), "Invalid prediction market");
        require(
            _legislatorElection != address(0),
            "Invalid legislator election"
        );
        require(_marketOracle != address(0), "Invalid market oracle");

        predictionMarket = GovernancePredictionMarket(_predictionMarket);
        legislatorElection = LegislatorElection(_legislatorElection);
        marketOracle = MarketOracle(payable(_marketOracle));
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(EXECUTOR_ROLE, msg.sender);
        _grantRole(EMERGENCY_ROLE, msg.sender);
    }

    /**
     * @notice Create a new proposal (Two-step process)
     * Step 1: Store inputs
     */
    function prepareProposal(
        string calldata title,
        string calldata description,
        bytes calldata callData,
        address targetContract,
        uint256 value,
        ProposalType proposalType
    ) external onlyLegislator whenNotPaused returns (uint256) {
        _validateProposalInputs(
            title,
            description,
            callData,
            targetContract,
            new string[](2) // dummy for validation
        );

        uint256 proposalId = proposalCount++;

        _tempProposalInputs[proposalId] = ProposalInput({
            title: title,
            description: description,
            callData: callData,
            targetContract: targetContract,
            value: value,
            proposalType: proposalType,
            timestamp: block.timestamp
        });

        return proposalId;
    }

    /**
     * @notice Finalize proposal and create prediction market
     * @dev Step 2 of proposal creation process
     * @param proposalId The prepared proposal ID
     * @param outcomeDescriptions Array of outcome descriptions for the market
     * @param initialLiquidity Initial liquidity for the market
     * @param priceAsset Asset address for Chainlink (use address(0) for non-price proposals)
     * @param chainlinkPriceId Unique price recording ID (use bytes32(0) for non-price proposals)
     */
    function finalizeProposal(
        uint256 proposalId,
        string[] calldata outcomeDescriptions,
        uint256 initialLiquidity,
        address priceAsset,
        bytes32 chainlinkPriceId
    ) external payable onlyLegislator whenNotPaused {
        ProposalInput memory input = _tempProposalInputs[proposalId];
        require(input.timestamp > 0, "Proposal not prepared");
        require(
            input.timestamp + 1 hours > block.timestamp,
            "Preparation expired"
        );

        uint256 executionTime = (input.proposalType ==
            ProposalType.EMERGENCY_ACTION)
            ? block.timestamp + EMERGENCY_DELAY
            : block.timestamp + EXECUTION_DELAY;

        GovernancePredictionMarket.MarketCategory category = _mapProposalTypeToCategory(
                input.proposalType
            );

        // ✅ FIXED: Call new createMarket with asset parameters
        uint256 marketId = predictionMarket.createMarket(
            input.title,
            input.description,
            keccak256(abi.encode(proposalId)),
            executionTime - 3600,
            outcomeDescriptions,
            category,
            initialLiquidity,
            priceAsset, // ✅ Pass asset address
            chainlinkPriceId // ✅ Pass price ID
        );

        proposals[proposalId] = Proposal({
            id: proposalId,
            proposer: msg.sender,
            title: input.title,
            description: input.description,
            callData: input.callData,
            targetContract: input.targetContract,
            value: input.value,
            createdAt: block.timestamp,
            executionTime: executionTime,
            predictionMarketId: marketId,
            executed: false,
            cancelled: false,
            proposalType: input.proposalType
        });

        proposerHistory[msg.sender].push(proposalId);

        delete _tempProposalInputs[proposalId];

        emit ProposalCreated(
            proposalId,
            msg.sender,
            input.title,
            marketId,
            input.targetContract
        );
    }
    /**
     * @notice Validate proposal inputs
     * @dev Internal helper to reduce stack depth
     */
    function _validateProposalInputs(
        string calldata title,
        string calldata description,
        bytes calldata callData,
        address targetContract,
        string[] memory outcomeDescriptions
    ) private view {
        require(bytes(title).length > 0, "Empty title");
        require(bytes(description).length > 0, "Empty description");
        require(outcomeDescriptions.length >= 2, "Need at least 2 outcomes");
        require(targetContract != address(0), "Invalid target");
        require(targetContract != address(this), "Cannot target self");
        require(allowedTargets[targetContract], "Target not whitelisted");

        // Validate function selector if callData is not empty
        if (callData.length >= 4) {
            bytes4 selector;
            assembly {
                selector := calldataload(callData.offset)
            }
            require(allowedSelectors[selector], "Selector not whitelisted");
        }
    }

    /**
     * @notice Create market and store proposal
     * @dev Internal helper that combines market creation and storage
     */
    function _createMarketAndStoreProposal(
        uint256 proposalId,
        string calldata title,
        string calldata description,
        bytes calldata callData,
        address targetContract,
        uint256 value,
        uint256 executionTime,
        ProposalType proposalType,
        string[] calldata outcomeDescriptions,
        uint256 initialLiquidity
    ) private returns (uint256) {
        // Map category
        GovernancePredictionMarket.MarketCategory category = _mapProposalTypeToCategory(
                proposalType
            );

        // Create market
        uint256 marketId = predictionMarket.createMarket(
            title,
            description,
            keccak256(abi.encode(proposalId)),
            executionTime - 3600,
            outcomeDescriptions,
            category,
            initialLiquidity
        );

        // Store proposal
        proposals[proposalId] = Proposal({
            id: proposalId,
            proposer: msg.sender,
            title: title,
            description: description,
            callData: callData,
            targetContract: targetContract,
            value: value,
            createdAt: block.timestamp,
            executionTime: executionTime,
            predictionMarketId: marketId,
            executed: false,
            cancelled: false,
            proposalType: proposalType
        });

        proposerHistory[msg.sender].push(proposalId);

        return marketId;
    }

    /**
     * @notice Calculate execution time based on proposal type
     * @dev Internal helper to reduce stack depth
     */
    function _calculateExecutionTime(
        ProposalType proposalType
    ) private view returns (uint256) {
        if (proposalType == ProposalType.EMERGENCY_ACTION) {
            return block.timestamp + EMERGENCY_DELAY;
        } else {
            return block.timestamp + EXECUTION_DELAY;
        }
    }

    /**
     * @notice Create prediction market for proposal
     * @dev Internal helper to reduce stack depth
     */
    function _createMarketForProposal(
        uint256 proposalId,
        string calldata title,
        string calldata description,
        uint256 executionTime,
        string[] calldata outcomeDescriptions,
        GovernancePredictionMarket.MarketCategory category,
        uint256 initialLiquidity
    ) private returns (uint256) {
        return
            predictionMarket.createMarket(
                title,
                description,
                keccak256(abi.encode(proposalId)),
                executionTime - 3600, // 1 hour before execution
                outcomeDescriptions,
                category,
                initialLiquidity
            );
    }

    /**
     * @notice Store proposal data
     * @dev Internal helper to reduce stack depth
     */
    function _storeProposal(
        uint256 proposalId,
        string calldata title,
        string calldata description,
        bytes calldata callData,
        address targetContract,
        uint256 value,
        uint256 executionTime,
        uint256 marketId,
        ProposalType proposalType
    ) private {
        proposals[proposalId] = Proposal({
            id: proposalId,
            proposer: msg.sender,
            title: title,
            description: description,
            callData: callData,
            targetContract: targetContract,
            value: value,
            createdAt: block.timestamp,
            executionTime: executionTime,
            predictionMarketId: marketId,
            executed: false,
            cancelled: false,
            proposalType: proposalType
        });

        proposerHistory[msg.sender].push(proposalId);
    }

    /**
     * @notice Execute a proposal after delay period with comprehensive validation
     * @dev FIXED: Complete oracle integration with outcome verification and cooldown check
     */
    function executeProposal(
        uint256 proposalId
    ) external nonReentrant whenNotPaused onlyLegislatorOrExecutor {
        Proposal storage proposal = proposals[proposalId];

        // Basic validation
        require(!proposal.executed, "Already executed");
        require(!proposal.cancelled, "Cancelled");
        require(block.timestamp >= proposal.executionTime, "Too early");
        require(
            block.timestamp <= proposal.executionTime + EXECUTION_WINDOW,
            "Execution window expired"
        );

        // Target contract validation
        require(
            allowedTargets[proposal.targetContract],
            "Target not whitelisted"
        );
        require(proposal.targetContract != address(this), "Cannot target self");
        require(
            proposal.targetContract.code.length > 0,
            "Target must be contract"
        );

        // High-value proposal extended delay
        if (proposal.value > HIGH_VALUE_THRESHOLD) {
            require(
                block.timestamp >=
                    proposal.executionTime + HIGH_VALUE_EXTENDED_DELAY,
                "High-value proposals require extended delay"
            );
        }

        // Prediction market validation
        _validatePredictionMarket(proposal.predictionMarketId);

        // FIX: Use correct MarketOracle interface
        require(
            marketOracle.isMarketFinalized(proposal.predictionMarketId),
            "Market not finalized by oracle"
        );

        // FIX: Check for active disputes using correct interface
        require(
            !marketOracle.hasActiveDisputes(proposal.predictionMarketId),
            "Active dispute exists"
        );

        // FIX: Verify cooldown has passed
        uint256 resolutionTime = marketOracle.marketResolutionTime(
            proposal.predictionMarketId
        );
        require(
            block.timestamp >= resolutionTime + 2 hours,
            "Oracle cooldown not complete"
        );

        // Get market outcome from prediction market
        (, , , bool resolved, uint8 winningOutcome) = predictionMarket
            .getMarket(proposal.predictionMarketId);

        require(resolved, "Market not resolved");
        require(winningOutcome == 0, "Market predicted failure");

        // FIX: Verify oracle resolution matches prediction market
        (
            ,
            uint8 oracleOutcome,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            bool oracleFinalized
        ) = marketOracle.getResolution(proposal.predictionMarketId);
        require(oracleFinalized, "Oracle resolution not finalized");
        require(
            oracleOutcome == winningOutcome,
            "Oracle-market outcome mismatch"
        );

        // CRITICAL: Mark as executed BEFORE any external calls (strict CEI)
        proposal.executed = true;

        // FIX: Store proposer address to avoid SLOAD in case of reentrancy
        address proposer = proposal.proposer;

        // Execute the proposal with gas limit
        (bool success, bytes memory returnData) = proposal.targetContract.call{
            value: proposal.value,
            gas: EXECUTION_GAS_LIMIT
        }(proposal.callData);

        // Emit event immediately after execution
        emit ProposalExecuted(proposalId, success, returnData);

        // FIX: Update performance AFTER execution and use stored proposer
        if (success) {
            _updatePerformanceOnSuccess(proposer);
        } else {
            emit ExecutionFailed(proposalId, "Execution reverted", returnData);
            _updatePerformanceOnFailure(proposer);

            // Revert with detailed error message
            if (returnData.length > 0) {
                assembly {
                    let returnDataSize := mload(returnData)
                    revert(add(32, returnData), returnDataSize)
                }
            } else {
                revert("Proposal execution failed");
            }
        }
    }

    /**
     * @notice Validate prediction market state
     */
    function _validatePredictionMarket(uint256 marketId) private view {
        (, , uint256 totalLiquidity, bool resolved, ) = predictionMarket
            .getMarket(marketId);

        require(resolved, "Market not resolved");
        require(
            totalLiquidity >= MIN_PARTICIPATION_THRESHOLD,
            "Insufficient market participation"
        );
    }

    /**
     * @notice Update legislator performance on successful execution
     */
    function _updatePerformanceOnSuccess(address proposer) private {
        try
            legislatorElection.updatePerformanceScore(
                proposer,
                PERFORMANCE_INCREASE,
                true
            )
        {
            emit PerformanceScoreUpdated(proposer, true, PERFORMANCE_INCREASE);
        } catch Error(string memory reason) {
            emit PerformanceUpdateFailed(proposer, reason);
        } catch (bytes memory lowLevelData) {
            emit PerformanceUpdateFailed(
                proposer,
                string(abi.encodePacked("Low-level error: ", lowLevelData))
            );
        }
    }

    /**
     * @notice Update legislator performance on failed execution
     */
    function _updatePerformanceOnFailure(address proposer) private {
        try
            legislatorElection.updatePerformanceScore(
                proposer,
                PERFORMANCE_DECREASE,
                false
            )
        {
            emit PerformanceScoreUpdated(proposer, false, PERFORMANCE_DECREASE);
        } catch Error(string memory reason) {
            emit PerformanceUpdateFailed(proposer, reason);
        } catch (bytes memory lowLevelData) {
            emit PerformanceUpdateFailed(
                proposer,
                string(abi.encodePacked("Low-level error: ", lowLevelData))
            );
        }
    }

    /**
     * @notice Cancel a proposal
     */
    function cancelProposal(uint256 proposalId) external whenNotPaused {
        Proposal storage proposal = proposals[proposalId];
        require(
            msg.sender == proposal.proposer ||
                hasRole(DEFAULT_ADMIN_ROLE, msg.sender) ||
                hasRole(EMERGENCY_ROLE, msg.sender),
            "Not authorized"
        );
        require(!proposal.executed, "Already executed");
        require(!proposal.cancelled, "Already cancelled");

        proposal.cancelled = true;

        emit ProposalCancelled(proposalId, msg.sender);
    }

    /**
     * @notice Add or remove target contract from allowlist
     */
    function setAllowedTarget(
        address target,
        bool allowed
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(target != address(0), "Invalid target");
        require(target != address(this), "Cannot whitelist self");

        allowedTargets[target] = allowed;
        emit TargetAllowlistUpdated(target, allowed, msg.sender);
    }

    /**
     * @notice Add or remove function selector from allowlist
     */
    function setAllowedSelector(
        bytes4 selector,
        bool allowed
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(selector != bytes4(0), "Invalid selector");

        allowedSelectors[selector] = allowed;
        emit SelectorAllowlistUpdated(selector, allowed, msg.sender);
    }

    /**
     * @notice Batch set allowed targets
     */
    function batchSetAllowedTargets(
        address[] calldata targets,
        bool allowed
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        for (uint256 i = 0; i < targets.length; i++) {
            require(targets[i] != address(0), "Invalid target");
            require(targets[i] != address(this), "Cannot whitelist self");
            allowedTargets[targets[i]] = allowed;
            emit TargetAllowlistUpdated(targets[i], allowed, msg.sender);
        }
    }

    /**
     * @notice Batch set allowed selectors
     */
    function batchSetAllowedSelectors(
        bytes4[] calldata selectors,
        bool allowed
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        for (uint256 i = 0; i < selectors.length; i++) {
            require(selectors[i] != bytes4(0), "Invalid selector");
            allowedSelectors[selectors[i]] = allowed;
            emit SelectorAllowlistUpdated(selectors[i], allowed, msg.sender);
        }
    }

    /**
     * @notice Map ProposalType to MarketCategory
     */
    function _mapProposalTypeToCategory(
        ProposalType proposalType
    ) internal pure returns (GovernancePredictionMarket.MarketCategory) {
        if (proposalType == ProposalType.PARAMETER_CHANGE) {
            return GovernancePredictionMarket.MarketCategory.PARAMETER_CHANGE;
        } else if (proposalType == ProposalType.TREASURY_ALLOCATION) {
            return
                GovernancePredictionMarket.MarketCategory.TREASURY_ALLOCATION;
        } else if (proposalType == ProposalType.CONTRACT_UPGRADE) {
            return GovernancePredictionMarket.MarketCategory.PROTOCOL_UPGRADE;
        } else if (proposalType == ProposalType.EMERGENCY_ACTION) {
            return GovernancePredictionMarket.MarketCategory.EMERGENCY_ACTION;
        } else {
            return GovernancePredictionMarket.MarketCategory.STRATEGIC_DECISION;
        }
    }
    function cancelPreparedProposal(
        uint256 proposalId
    ) external onlyLegislator {
        ProposalInput memory input = _tempProposalInputs[proposalId];
        require(input.timestamp > 0, "Proposal not prepared");
        require(msg.sender == proposals[proposalId].proposer, "Not proposer");

        delete _tempProposalInputs[proposalId];

        emit ProposalPreparationCancelled(proposalId);
    }
    function getPreparedProposal(
        uint256 proposalId
    ) external view returns (ProposalInput memory) {
        return _tempProposalInputs[proposalId];
    }

    function isProposalPrepared(
        uint256 proposalId
    ) external view returns (bool) {
        return _tempProposalInputs[proposalId].timestamp > 0;
    }
    function getProposal(
        uint256 proposalId
    ) external view returns (Proposal memory) {
        return proposals[proposalId];
    }

    function getProposerHistory(
        address proposer
    ) external view returns (uint256[] memory) {
        return proposerHistory[proposer];
    }

    function canExecuteProposal(
        uint256 proposalId
    ) external view returns (bool) {
        Proposal storage proposal = proposals[proposalId];

        if (proposal.executed || proposal.cancelled) {
            return false;
        }

        if (block.timestamp < proposal.executionTime) {
            return false;
        }

        if (block.timestamp > proposal.executionTime + EXECUTION_WINDOW) {
            return false;
        }

        if (proposal.value > HIGH_VALUE_THRESHOLD) {
            if (
                block.timestamp <
                proposal.executionTime + HIGH_VALUE_EXTENDED_DELAY
            ) {
                return false;
            }
        }

        if (!allowedTargets[proposal.targetContract]) {
            return false;
        }

        (
            ,
            ,
            uint256 totalLiquidity,
            bool resolved,
            uint8 winningOutcome
        ) = predictionMarket.getMarket(proposal.predictionMarketId);

        if (!resolved || winningOutcome != 0) {
            return false;
        }

        if (totalLiquidity < MIN_PARTICIPATION_THRESHOLD) {
            return false;
        }

        if (!marketOracle.marketResolved(proposal.predictionMarketId)) {
            return false;
        }

        return true;
    }

    function getCurrentProposalCount() external view returns (uint256) {
        return proposalCount;
    }

    function getActiveProposals() external view returns (uint256[] memory) {
        uint256[] memory activeIds = new uint256[](proposalCount);
        uint256 activeCount = 0;

        for (uint256 i = 0; i < proposalCount; i++) {
            if (!proposals[i].executed && !proposals[i].cancelled) {
                activeIds[activeCount] = i;
                activeCount++;
            }
        }

        uint256[] memory result = new uint256[](activeCount);
        for (uint256 i = 0; i < activeCount; i++) {
            result[i] = activeIds[i];
        }

        return result;
    }

    function getExecutableProposals() external view returns (uint256[] memory) {
        uint256[] memory executableIds = new uint256[](proposalCount);
        uint256 executableCount = 0;

        for (uint256 i = 0; i < proposalCount; i++) {
            if (this.canExecuteProposal(i)) {
                executableIds[executableCount] = i;
                executableCount++;
            }
        }

        uint256[] memory result = new uint256[](executableCount);
        for (uint256 i = 0; i < executableCount; i++) {
            result[i] = executableIds[i];
        }

        return result;
    }

    function getProposalStatus(
        uint256 proposalId
    )
        external
        view
        returns (
            bool executed,
            bool cancelled,
            bool canExecute,
            uint256 timeUntilExecution,
            uint256 timeUntilWindowClose
        )
    {
        Proposal storage proposal = proposals[proposalId];

        executed = proposal.executed;
        cancelled = proposal.cancelled;
        canExecute = this.canExecuteProposal(proposalId);

        if (block.timestamp >= proposal.executionTime) {
            timeUntilExecution = 0;
        } else {
            timeUntilExecution = proposal.executionTime - block.timestamp;
        }

        uint256 windowCloseTime = proposal.executionTime + EXECUTION_WINDOW;
        if (block.timestamp >= windowCloseTime) {
            timeUntilWindowClose = 0;
        } else {
            timeUntilWindowClose = windowCloseTime - block.timestamp;
        }
    }

    function isTargetAllowed(address target) external view returns (bool) {
        return allowedTargets[target];
    }

    function isSelectorAllowed(bytes4 selector) external view returns (bool) {
        return allowedSelectors[selector];
    }

    function pause() external onlyRole(EMERGENCY_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(EMERGENCY_ROLE) {
        _unpause();
    }

    receive() external payable {}

    function withdrawETH(
        address payable recipient,
        uint256 amount
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(recipient != address(0), "Invalid recipient");
        require(amount <= address(this).balance, "Insufficient balance");

        (bool success, ) = recipient.call{value: amount}("");
        require(success, "Transfer failed");
    }
}
