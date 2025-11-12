// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "../interfaces/IGovernanceTarget.sol";

/**
 * @title EmergencyMultisig
 * @notice Time-locked multisig for emergency actions with optimized gas usage
 * @dev Implements threshold signatures with automatic expiry and rotation
 */
contract EmergencyMultisig {
    using ECDSA for bytes32;
    using EnumerableSet for EnumerableSet.AddressSet;

    struct EmergencyAction {
        address target;
        bytes data;
        uint256 value;
        uint256 proposedAt;
        uint256 executionTime;
        uint256 expiryTime;
        bytes32 descriptionHash;
        bool executed;
        uint256 confirmations;
        mapping(address => bool) isConfirmed;
    }

    struct SignerInfo {
        bool isActive;
        uint256 addedAt;
        uint256 lastActionAt;
        uint256 actionsCount;
    }

    // State variables
    EnumerableSet.AddressSet private signers;
    mapping(address => SignerInfo) public signerInfo;
    mapping(uint256 => EmergencyAction) public emergencyActions;
    mapping(address => bool) public governanceTargets;

    uint256 public threshold;
    uint256 public actionCount;
    uint256 public constant MIN_THRESHOLD = 3;
    uint256 public constant MAX_SIGNERS = 9;
    uint256 public constant EMERGENCY_TIMELOCK = 6 hours;
    uint256 public constant ACTION_EXPIRY = 48 hours;
    uint256 public constant SIGNER_INACTIVITY_PERIOD = 30 days;

    // Events
    event SignerAdded(address indexed signer, uint256 newThreshold);
    event SignerRemoved(address indexed signer, uint256 newThreshold);
    event EmergencyActionProposed(
        uint256 indexed actionId,
        address indexed target,
        uint256 executionTime,
        bytes32 descriptionHash
    );
    event EmergencyActionConfirmed(
        uint256 indexed actionId,
        address indexed signer
    );
    event EmergencyActionExecuted(uint256 indexed actionId, bool success);
    event EmergencyActionCancelled(uint256 indexed actionId);
    event ThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);
    event GovernanceTargetUpdated(address indexed target, bool authorized);

    modifier onlySigner() {
        require(signerInfo[msg.sender].isActive, "Not an active signer");
        _;
    }

    modifier onlyMultisig() {
        require(msg.sender == address(this), "Only multisig");
        _;
    }

    modifier actionExists(uint256 actionId) {
        require(
            emergencyActions[actionId].proposedAt > 0,
            "Action doesn't exist"
        );
        _;
    }

    /**
     * @notice Initialize emergency multisig
     * @param _signers Initial set of signers
     * @param _threshold Initial confirmation threshold
     */
    constructor(address[] memory _signers, uint256 _threshold) {
        require(_signers.length >= MIN_THRESHOLD, "Not enough signers");
        require(_signers.length <= MAX_SIGNERS, "Too many signers");
        require(
            _threshold >= MIN_THRESHOLD && _threshold <= _signers.length,
            "Invalid threshold"
        );

        for (uint256 i = 0; i < _signers.length; i++) {
            require(_signers[i] != address(0), "Invalid signer");
            require(signers.add(_signers[i]), "Duplicate signer");

            signerInfo[_signers[i]] = SignerInfo({
                isActive: true,
                addedAt: block.timestamp,
                lastActionAt: block.timestamp,
                actionsCount: 0
            });
        }

        threshold = _threshold;
    }

    /**
     * @notice Propose an emergency action
     * @param target Target contract address
     * @param data Encoded function call
     * @param value ETH value to send
     * @param descriptionHash Hash of action description
     */
    function proposeEmergencyAction(
        address target,
        bytes calldata data,
        uint256 value,
        bytes32 descriptionHash
    ) external onlySigner returns (uint256) {
        require(governanceTargets[target], "Target not authorized");
        require(data.length > 0, "Empty data");

        uint256 actionId = actionCount++;
        EmergencyAction storage action = emergencyActions[actionId];

        action.target = target;
        action.data = data;
        action.value = value;
        action.proposedAt = block.timestamp;
        action.executionTime = block.timestamp + EMERGENCY_TIMELOCK;
        action.expiryTime = block.timestamp + ACTION_EXPIRY;
        action.descriptionHash = descriptionHash;
        action.confirmations = 1;
        action.isConfirmed[msg.sender] = true;

        signerInfo[msg.sender].lastActionAt = block.timestamp;
        signerInfo[msg.sender].actionsCount++;

        emit EmergencyActionProposed(
            actionId,
            target,
            action.executionTime,
            descriptionHash
        );
        emit EmergencyActionConfirmed(actionId, msg.sender);

        return actionId;
    }

    /**
     * @notice Confirm an emergency action
     * @param actionId The action to confirm
     */
    function confirmAction(
        uint256 actionId
    ) external onlySigner actionExists(actionId) {
        EmergencyAction storage action = emergencyActions[actionId];
        require(!action.executed, "Already executed");
        require(block.timestamp < action.expiryTime, "Action expired");
        require(!action.isConfirmed[msg.sender], "Already confirmed");

        action.isConfirmed[msg.sender] = true;
        action.confirmations++;

        signerInfo[msg.sender].lastActionAt = block.timestamp;

        emit EmergencyActionConfirmed(actionId, msg.sender);

        // Auto-execute if threshold reached and timelock passed
        if (
            action.confirmations >= threshold &&
            block.timestamp >= action.executionTime
        ) {
            _executeEmergencyAction(actionId);
        }
    }

    /**
     * @notice Execute a confirmed emergency action
     * @param actionId The action to execute
     */
    function executeEmergencyAction(
        uint256 actionId
    ) external onlySigner actionExists(actionId) {
        EmergencyAction storage action = emergencyActions[actionId];
        require(!action.executed, "Already executed");
        require(
            action.confirmations >= threshold,
            "Insufficient confirmations"
        );
        require(block.timestamp >= action.executionTime, "Timelock not passed");
        require(block.timestamp < action.expiryTime, "Action expired");

        _executeEmergencyAction(actionId);
    }

    /**
     * @notice Internal execution logic
     */
    function _executeEmergencyAction(uint256 actionId) private {
        EmergencyAction storage action = emergencyActions[actionId];
        action.executed = true;

        // Execute with gas limit to prevent griefing
        (bool success, bytes memory returnData) = action.target.call{
            value: action.value,
            gas: gasleft() - 50000
        }(action.data); // Reserve gas for post-execution

        if (success && action.target.code.length > 0) {
            // Log successful governance action
            try
                IGovernanceTarget(action.target).getGovernanceParameters()
            returns (bytes memory) {
                // Target is a valid governance target
            } catch {
                // Not a governance target, but call succeeded
            }
        }

        emit EmergencyActionExecuted(actionId, success);

        // Cleanup expired confirmations to save gas
        _cleanupAction(actionId);
    }

    /**
     * @notice Cancel an emergency action
     * @param actionId The action to cancel
     */
    function cancelAction(
        uint256 actionId
    ) external onlySigner actionExists(actionId) {
        EmergencyAction storage action = emergencyActions[actionId];
        require(!action.executed, "Already executed");
        require(
            action.isConfirmed[msg.sender] ||
                block.timestamp >= action.expiryTime,
            "Cannot cancel"
        );

        action.executed = true; // Prevent future execution
        emit EmergencyActionCancelled(actionId);

        _cleanupAction(actionId);
    }

    /**
     * @notice Add a new signer
     * @param signer Address to add
     */
    function addSigner(address signer) external onlyMultisig {
        require(signer != address(0), "Invalid signer");
        require(!signerInfo[signer].isActive, "Already a signer");
        require(signers.length() < MAX_SIGNERS, "Max signers reached");

        signers.add(signer);
        signerInfo[signer] = SignerInfo({
            isActive: true,
            addedAt: block.timestamp,
            lastActionAt: block.timestamp,
            actionsCount: 0
        });

        // Adjust threshold if needed
        if (threshold < MIN_THRESHOLD) {
            threshold = MIN_THRESHOLD;
        }

        emit SignerAdded(signer, threshold);
    }

    /**
     * @notice Remove a signer
     * @param signer Address to remove
     */
    function removeSigner(address signer) external onlyMultisig {
        require(signerInfo[signer].isActive, "Not a signer");
        require(signers.length() > MIN_THRESHOLD, "Too few signers");

        signers.remove(signer);
        signerInfo[signer].isActive = false;

        // Adjust threshold if needed
        if (threshold > signers.length()) {
            threshold = signers.length();
        }

        emit SignerRemoved(signer, threshold);
    }

    /**
     * @notice Update confirmation threshold
     * @param newThreshold New threshold value
     */
    function updateThreshold(uint256 newThreshold) external onlyMultisig {
        require(
            newThreshold >= MIN_THRESHOLD && newThreshold <= signers.length(),
            "Invalid threshold"
        );

        uint256 oldThreshold = threshold;
        threshold = newThreshold;

        emit ThresholdUpdated(oldThreshold, newThreshold);
    }

    /**
     * @notice Authorize a governance target
     * @param target Contract address to authorize
     * @param authorized Whether to authorize or revoke
     */
    function updateGovernanceTarget(
        address target,
        bool authorized
    ) external onlyMultisig {
        require(target != address(0), "Invalid target");
        governanceTargets[target] = authorized;
        emit GovernanceTargetUpdated(target, authorized);
    }

    /**
     * @notice Remove inactive signers
     * @param signer Inactive signer to remove
     */
    function removeInactiveSigner(address signer) external onlySigner {
        require(signerInfo[signer].isActive, "Not a signer");
        require(
            block.timestamp >
                signerInfo[signer].lastActionAt + SIGNER_INACTIVITY_PERIOD,
            "Signer still active"
        );

        // Use multisig logic to remove
        this.removeSigner(signer);
    }

    /**
     * @notice Cleanup storage for executed/expired actions
     */
    function _cleanupAction(uint256 actionId) private {
        EmergencyAction storage action = emergencyActions[actionId];

        // Clear confirmation mappings for gas refund
        address[] memory signerList = signers.values();
        for (uint256 i = 0; i < signerList.length; i++) {
            delete action.isConfirmed[signerList[i]];
        }
    }

    /**
     * @notice Get current signers
     */
    function getSigners() external view returns (address[] memory) {
        return signers.values();
    }

    /**
     * @notice Get action confirmation status
     */
    function getConfirmationStatus(
        uint256 actionId
    ) external view returns (uint256 confirmations, bool[] memory confirmed) {
        EmergencyAction storage action = emergencyActions[actionId];
        address[] memory signerList = signers.values();

        confirmed = new bool[](signerList.length);
        for (uint256 i = 0; i < signerList.length; i++) {
            confirmed[i] = action.isConfirmed[signerList[i]];
        }

        return (action.confirmations, confirmed);
    }

    /**
     * @notice Check if action can be executed
     */
    function canExecuteAction(uint256 actionId) external view returns (bool) {
        EmergencyAction storage action = emergencyActions[actionId];

        return
            !action.executed &&
            action.confirmations >= threshold &&
            block.timestamp >= action.executionTime &&
            block.timestamp < action.expiryTime;
    }

    /**
     * @notice Receive ETH for emergency actions
     */
    receive() external payable {}
}
