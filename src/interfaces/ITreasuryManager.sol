// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/**
 * @title ITreasuryManager
 * @notice Interface for TreasuryManager contract
 * @dev Used by RewardDistributor to pull rewards from treasury
 */
interface ITreasuryManager {
    /**
     * @notice Transfer tokens to another address
     * @param token The token to transfer
     * @param to The recipient address
     * @param amount The amount to transfer
     * @return success Whether the transfer was successful
     */
    function transferTo(
        address token,
        address to,
        uint256 amount
    ) external returns (bool success);

    /**
     * @notice Get asset allocation details
     * @param token The token to query
     * @return balance Current balance
     * @return targetPercentage Target allocation percentage
     * @return currentPercentage Current allocation percentage
     * @return needsRebalancing Whether rebalancing is needed
     */
    function getAssetAllocation(
        address token
    )
        external
        view
        returns (
            uint256 balance,
            uint256 targetPercentage,
            uint256 currentPercentage,
            bool needsRebalancing
        );

    /**
     * @notice Get treasury statistics
     * @return totalValue Total value locked
     * @return numAssets Number of supported assets
     * @return numStrategies Number of active strategies
     * @return numBudgets Number of active budgets
     * @return inEmergencyMode Whether emergency mode is active
     */
    function getTreasuryStats()
        external
        view
        returns (
            uint256 totalValue,
            uint256 numAssets,
            uint256 numStrategies,
            uint256 numBudgets,
            bool inEmergencyMode
        );

    function assetAllocations(
        address token
    )
        external
        view
        returns (
            address assetToken,
            uint256 targetPercentage,
            uint256 minPercentage,
            uint256 maxPercentage,
            uint256 currentBalance,
            bool isActive,
            uint256 lastRebalance
        );
}
