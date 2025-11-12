// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/**
 * @title IGovernanceTarget
 * @notice Interface that governance-controlled contracts must implement
 * @dev Ensures safe proposal execution with validation and emergency controls
 */
interface IGovernanceTarget {
    /**
     * @notice Emitted when governance executes an action
     */
    event GovernanceActionExecuted(
        bytes32 indexed actionId,
        address indexed executor,
        uint256 timestamp,
        bytes data,
        bool success
    );

    /**
     * @notice Emitted when emergency action is taken
     */
    event EmergencyActionExecuted(
        address indexed executor,
        string action,
        uint256 timestamp
    );

    /**
     * @notice Execute a governance action
     * @param actionId Unique identifier for the action
     * @param data Encoded function call data
     * @return success Whether execution succeeded
     * @return returnData Return data from the call
     */
    function executeGovernanceAction(
        bytes32 actionId,
        bytes calldata data
    ) external payable returns (bool success, bytes memory returnData);

    /**
     * @notice Validate if an action can be executed
     * @param actionId The action identifier
     * @param data The calldata to validate
     * @return valid Whether the action is valid
     * @return reason Reason if invalid
     */
    function validateGovernanceAction(
        bytes32 actionId,
        bytes calldata data
    ) external view returns (bool valid, string memory reason);

    /**
     * @notice Check if an address is authorized to execute governance actions
     * @param executor The address to check
     * @return Whether the address is authorized
     */
    function isAuthorizedGovernance(
        address executor
    ) external view returns (bool);

    /**
     * @notice Emergency pause functionality
     * @dev Only callable by emergency multisig
     */
    function emergencyPause() external;

    /**
     * @notice Emergency unpause functionality
     * @dev Only callable by emergency multisig
     */
    function emergencyUnpause() external;

    /**
     * @notice Get the current governance parameters
     * @return params Encoded governance parameters
     */
    function getGovernanceParameters()
        external
        view
        returns (bytes memory params);

    /**
     * @notice Update governance parameters
     * @param params Encoded parameters to update
     */
    function updateGovernanceParameters(bytes calldata params) external;
}
