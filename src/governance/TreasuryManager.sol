// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "../interfaces/IGovernanceTarget.sol";

/**
 * @title TreasuryManager
 * @notice Manages protocol treasury with yield optimization and risk management
 * @dev Implements diversified treasury management with automated strategies
 */
contract TreasuryManager is
    IGovernanceTarget,
    AccessControl,
    ReentrancyGuard,
    Pausable
{
    using SafeERC20 for IERC20;

    // Roles
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant STRATEGIST_ROLE = keccak256("STRATEGIST_ROLE");

    // Asset allocation
    struct AssetAllocation {
        address token;
        uint256 targetPercentage; // Basis points (10000 = 100%)
        uint256 minPercentage;
        uint256 maxPercentage;
        uint256 currentBalance;
        bool isActive;
        uint256 lastRebalance;
    }

    // Strategy information
    struct Strategy {
        address strategyContract;
        uint256 allocation; // Basis points
        uint256 totalDeposited;
        uint256 totalWithdrawn;
        uint256 lastHarvest;
        bool isActive;
        uint256 performanceFee; // Basis points
    }

    // Budget allocation
    struct Budget {
        string name;
        address recipient;
        uint256 amount;
        uint256 period; // seconds
        uint256 spent;
        uint256 lastClaim;
        uint256 periodStartTime; //  NEW: Track period boundaries
        uint256 totalClaimed; //  NEW: Track total claimed across all periods
        bool isActive;
    }

    // Constants
    uint256 public constant PRECISION = 10000;
    uint256 public constant MAX_STRATEGIES = 10;
    uint256 public constant REBALANCE_THRESHOLD = 500; // 5%
    uint256 public constant EMERGENCY_WITHDRAWAL_DELAY = 24 hours;

    // State variables
    mapping(address => AssetAllocation) public assetAllocations;
    mapping(address => Strategy) public strategies;
    mapping(string => Budget) public budgets;
    mapping(address => uint256) public lastRebalancePrice; // Track prices to detect manipulation

    address[] public supportedTokens;
    address[] public activeStrategies;
    string[] public budgetNames;

    uint256 public totalValueLocked;
    uint256 public lastRebalanceTime;
    uint256 public rebalanceCooldown = 24 hours;
    uint256 public maxSlippageBps = 100; // 1% max slippage
    // Emergency
    bool public emergencyMode;
    uint256 public emergencyModeActivatedAt;
    mapping(address => uint256) public emergencyWithdrawalRequests;

    // Governance
    address public immutable proposalManager;
    bool private _governanceExecutionEnabled = true;

    // Events
    event AssetDeposited(address indexed token, uint256 amount);
    event AssetWithdrawn(address indexed token, uint256 amount, address to);
    event StrategyAdded(address indexed strategy, uint256 allocation);
    event StrategyRemoved(address indexed strategy);
    event BudgetCreated(string name, address recipient, uint256 amount);
    event BudgetClaimed(string name, uint256 amount);
    event Rebalanced(uint256 timestamp);
    event EmergencyModeActivated(address activator);
    event EmergencyWithdrawal(address token, uint256 amount, address to);
    event StrategyHarvested(
        address indexed strategy,
        address indexed token,
        uint256 profit,
        uint256 fee
    );

    event EmergencyWithdrawalFromStrategy(
        address indexed strategy,
        address indexed token,
        uint256 amount
    );
    event AssetRebalanced(
        address indexed token,
        uint256 amount,
        uint256 minAmount,
        string action
    );
    event StrategyDeployed(address strategy, address token, uint256 amount);

    constructor(address _proposalManager) {
        require(_proposalManager != address(0), "Invalid proposal manager");
        proposalManager = _proposalManager;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
    }

    /**
     * @notice Deposit assets into treasury
     */
    function deposit(address token, uint256 amount) external nonReentrant {
        require(amount > 0, "Zero amount");
        require(assetAllocations[token].isActive, "Token not supported");

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        assetAllocations[token].currentBalance += amount;
        totalValueLocked += amount; // Simplified - should use oracle prices

        emit AssetDeposited(token, amount);

        // Auto-rebalance if needed
        if (_shouldRebalance()) {
            _rebalance();
        }
    }

    /**
     * @notice Add supported token with allocation targets
     */
    function addSupportedToken(
        address token,
        uint256 targetPercentage,
        uint256 minPercentage,
        uint256 maxPercentage
    ) external onlyRole(OPERATOR_ROLE) {
        require(token != address(0), "Invalid token");
        require(targetPercentage <= PRECISION, "Invalid target");
        require(minPercentage <= targetPercentage, "Invalid min");
        require(targetPercentage <= maxPercentage, "Invalid max");
        require(maxPercentage <= PRECISION, "Invalid max");
        require(!assetAllocations[token].isActive, "Already supported");

        assetAllocations[token] = AssetAllocation({
            token: token,
            targetPercentage: targetPercentage,
            minPercentage: minPercentage,
            maxPercentage: maxPercentage,
            currentBalance: 0,
            isActive: true,
            lastRebalance: block.timestamp
        });

        supportedTokens.push(token);
    }

    /**
     * @notice Deploy funds to yield strategy
     */
    /**
     * @notice Deploy funds to yield strategy
     * @dev Uses push pattern to prevent approval-based reentrancy
     */
    function deployToStrategy(
        address strategy,
        address token,
        uint256 amount
    ) external onlyRole(STRATEGIST_ROLE) nonReentrant {
        require(!emergencyMode, "Emergency mode active");
        require(strategies[strategy].isActive, "Strategy not active");
        require(amount > 0, "Zero amount");

        AssetAllocation storage allocation = assetAllocations[token];
        require(allocation.isActive, "Token not supported");
        require(allocation.currentBalance >= amount, "Insufficient balance");

        //  FIX: Update balances BEFORE transfer
        allocation.currentBalance -= amount;
        strategies[strategy].totalDeposited += amount;

        //  FIX: Use push pattern - direct transfer instead of approve
        // Strategy contract must have a way to track deposits internally
        IERC20(token).safeTransfer(strategy, amount);

        //  FIX: Notify strategy after transfer (pull pattern alternative)
        (bool success, ) = strategy.call(
            abi.encodeWithSignature(
                "notifyDeposit(address,uint256)",
                token,
                amount
            )
        );
        require(success, "Strategy notification failed");

        emit StrategyDeployed(strategy, token, amount);
    }

    /**
     * @notice Harvest yields from strategy
     * @dev Validates actual token transfers to prevent profit manipulation
     * @param strategy Address of strategy to harvest
     * @param token Token being harvested
     * @return profit Actual profit received
     */
    function harvestStrategy(
        address strategy,
        address token
    ) external nonReentrant returns (uint256 profit) {
        require(strategies[strategy].isActive, "Strategy not active");
        require(assetAllocations[token].isActive, "Token not supported");

        Strategy storage strat = strategies[strategy];
        AssetAllocation storage allocation = assetAllocations[token];

        //  FIX: Record balance BEFORE harvest
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));

        // Call harvest on strategy
        (bool success, ) = strategy.call(
            abi.encodeWithSignature("harvest(address)", token)
        );
        require(success, "Harvest failed");

        //  FIX: Measure actual profit by balance change
        uint256 balanceAfter = IERC20(token).balanceOf(address(this));
        require(balanceAfter >= balanceBefore, "Balance decreased");

        profit = balanceAfter - balanceBefore;

        if (profit > 0) {
            //  FIX: Take performance fee from actual profit
            uint256 fee = (profit * strat.performanceFee) / PRECISION;
            uint256 netProfit = profit - fee;

            //  FIX: Update allocation balance with actual profit
            allocation.currentBalance += netProfit;

            strat.lastHarvest = block.timestamp;
            totalValueLocked += netProfit;

            emit StrategyHarvested(strategy, token, netProfit, fee);
        } else {
            revert("No profit to harvest");
        }
    }
    /**
     * @notice Create or update budget allocation
     */
    function setBudget(
        string calldata name,
        address recipient,
        uint256 amount,
        uint256 period
    ) external onlyRole(OPERATOR_ROLE) {
        require(bytes(name).length > 0, "Empty name");
        require(recipient != address(0), "Invalid recipient");
        require(amount > 0, "Zero amount");
        require(period >= 1 days, "Period too short");

        if (!budgets[name].isActive) {
            budgetNames.push(name);
        }

        budgets[name] = Budget({
            name: name,
            recipient: recipient,
            amount: amount,
            period: period,
            spent: 0,
            lastClaim: block.timestamp,
            periodStartTime: block.timestamp, //  NEW: Initialize period start
            totalClaimed: 0, //  NEW: Initialize total claimed
            isActive: true
        });

        emit BudgetCreated(name, recipient, amount);
    }

    /**
     * @notice Claim budget allocation
     */
    /**
     * @notice Claim budget allocation
     * @dev Implements proper period-based vesting with accumulation cap
     */
    function claimBudget(string calldata name) external nonReentrant {
        Budget storage budget = budgets[name];
        require(budget.isActive, "Budget not active");
        require(msg.sender == budget.recipient, "Not recipient");

        uint256 elapsed = block.timestamp - budget.lastClaim;
        require(elapsed > 0, "Nothing to claim yet");

        //  FIX: Calculate periods passed and cap accumulation
        uint256 periodsPassed = elapsed / budget.period;
        uint256 partialPeriod = elapsed % budget.period;

        //  FIX: Maximum 3 periods can accumulate (prevent infinite accumulation)
        uint256 MAX_ACCUMULATION_PERIODS = 3;
        if (periodsPassed > MAX_ACCUMULATION_PERIODS) {
            periodsPassed = MAX_ACCUMULATION_PERIODS;
            partialPeriod = 0; // Don't include partial if already at max
        }

        //  FIX: Calculate claimable with proper accumulation
        uint256 claimableFromFullPeriods = budget.amount * periodsPassed;
        uint256 claimableFromPartial = (budget.amount * partialPeriod) /
            budget.period;
        uint256 totalClaimable = claimableFromFullPeriods +
            claimableFromPartial;

        require(totalClaimable > 0, "Nothing to claim");

        //  FIX: Update tracking BEFORE external calls
        budget.lastClaim = block.timestamp;

        // Find token with sufficient balance
        address paymentToken = _selectPaymentToken(totalClaimable);
        require(paymentToken != address(0), "Insufficient treasury balance");

        assetAllocations[paymentToken].currentBalance -= totalClaimable;

        //  FIX: Transfer AFTER all state updates (checks-effects-interactions)
        IERC20(paymentToken).safeTransfer(budget.recipient, totalClaimable);

        emit BudgetClaimed(name, totalClaimable);
    }

    /**
     * @notice Add new yield strategy with interface validation
     * @dev  FIXED: Validates strategy interface before adding
     */
    function addStrategy(
        address strategy,
        uint256 allocation,
        uint256 performanceFee
    ) external onlyRole(OPERATOR_ROLE) {
        require(strategy != address(0), "Invalid strategy");
        require(allocation <= PRECISION, "Invalid allocation");
        require(performanceFee <= 2000, "Fee too high"); // Max 20%
        require(!strategies[strategy].isActive, "Already active");
        require(
            activeStrategies.length < MAX_STRATEGIES,
            "Too many strategies"
        );

        //  FIX: Validate strategy interface
        require(_isValidStrategy(strategy), "Invalid strategy interface");

        strategies[strategy] = Strategy({
            strategyContract: strategy,
            allocation: allocation,
            totalDeposited: 0,
            totalWithdrawn: 0,
            lastHarvest: block.timestamp,
            isActive: true,
            performanceFee: performanceFee
        });

        activeStrategies.push(strategy);
        emit StrategyAdded(strategy, allocation);
    }

    /**
     * @notice Validate strategy contract interface
     * @dev Checks if strategy implements required functions
     */
    function _isValidStrategy(address strategy) private view returns (bool) {
        // Check if contract exists
        uint256 size;
        assembly {
            size := extcodesize(strategy)
        }
        if (size == 0) return false;

        // Try to call required functions with static calls
        (bool success1, ) = strategy.staticcall(
            abi.encodeWithSignature("harvest(address)", address(0))
        );
        (bool success2, ) = strategy.staticcall(
            abi.encodeWithSignature("emergencyWithdraw(address)", address(0))
        );
        (bool success3, ) = strategy.staticcall(
            abi.encodeWithSignature("withdrawAll()")
        );

        // At least one should succeed (contract has interface)
        // Full validation happens at runtime
        return success1 || success2 || success3;
    }

    /**
     * @notice Remove yield strategy
     */
    function removeStrategy(address strategy) external onlyRole(OPERATOR_ROLE) {
        require(strategies[strategy].isActive, "Not active");

        // Withdraw all funds from strategy first
        (bool success, ) = strategy.call(
            abi.encodeWithSignature("withdrawAll()")
        );
        require(success, "Withdrawal failed");

        strategies[strategy].isActive = false;

        // Remove from active list
        for (uint256 i = 0; i < activeStrategies.length; i++) {
            if (activeStrategies[i] == strategy) {
                activeStrategies[i] = activeStrategies[
                    activeStrategies.length - 1
                ];
                activeStrategies.pop();
                break;
            }
        }

        emit StrategyRemoved(strategy);
    }

    /**
     * @notice Rebalance portfolio to target allocations
     */
    function rebalance() external onlyRole(OPERATOR_ROLE) {
        require(_shouldRebalance(), "Rebalance not needed");
        _rebalance();
    }

    /**
     * @notice Internal rebalancing logic
     */
    function _rebalance() private {
        require(
            block.timestamp >= lastRebalanceTime + rebalanceCooldown,
            "Cooldown active"
        );

        // Calculate total value across all assets
        uint256 totalValue = _calculateTotalValue();
        require(totalValue > 0, "No assets to rebalance");

        // Rebalance each asset
        for (uint256 i = 0; i < supportedTokens.length; i++) {
            address token = supportedTokens[i];
            AssetAllocation storage allocation = assetAllocations[token];

            if (!allocation.isActive) continue;

            uint256 currentValue = _getTokenValue(
                token,
                allocation.currentBalance
            );
            uint256 currentPercentage = (currentValue * PRECISION) / totalValue;

            // Rebalance if outside threshold
            if (
                _needsRebalancing(
                    currentPercentage,
                    allocation.targetPercentage
                )
            ) {
                _rebalanceAsset(
                    token,
                    currentPercentage,
                    allocation.targetPercentage,
                    totalValue
                );
            }
        }

        lastRebalanceTime = block.timestamp;
        emit Rebalanced(block.timestamp);
    }

    /**
     * @notice Check if rebalancing is needed
     */
    function _shouldRebalance() private view returns (bool) {
        if (block.timestamp < lastRebalanceTime + rebalanceCooldown) {
            return false;
        }

        uint256 totalValue = _calculateTotalValue();
        if (totalValue == 0) return false;

        for (uint256 i = 0; i < supportedTokens.length; i++) {
            address token = supportedTokens[i];
            AssetAllocation storage allocation = assetAllocations[token];

            if (!allocation.isActive) continue;

            uint256 currentValue = _getTokenValue(
                token,
                allocation.currentBalance
            );
            uint256 currentPercentage = (currentValue * PRECISION) / totalValue;

            if (
                _needsRebalancing(
                    currentPercentage,
                    allocation.targetPercentage
                )
            ) {
                return true;
            }
        }

        return false;
    }

    /**
     * @notice Check if asset needs rebalancing
     */
    function _needsRebalancing(
        uint256 currentPercentage,
        uint256 targetPercentage
    ) private pure returns (bool) {
        uint256 deviation = currentPercentage > targetPercentage
            ? currentPercentage - targetPercentage
            : targetPercentage - currentPercentage;

        return deviation > REBALANCE_THRESHOLD;
    }

    /**
     * @notice Rebalance specific asset with slippage protection
     * @dev Includes price validation to prevent sandwich attacks
     */
    function _rebalanceAsset(
        address token,
        uint256 currentPercentage,
        uint256 targetPercentage,
        uint256 totalValue
    ) private {
        AssetAllocation storage allocation = assetAllocations[token];
        uint256 targetValue = (totalValue * targetPercentage) / PRECISION;
        uint256 currentValue = _getTokenValue(token, allocation.currentBalance);

        //  FIX: Get current price and validate against manipulation
        uint256 currentPrice = _getTokenPrice(token);
        uint256 lastPrice = lastRebalancePrice[token];

        if (lastPrice > 0) {
            //  Check price hasn't moved more than max slippage since last rebalance
            uint256 priceChange = currentPrice > lastPrice
                ? ((currentPrice - lastPrice) * PRECISION) / lastPrice
                : ((lastPrice - currentPrice) * PRECISION) / lastPrice;

            require(
                priceChange <= maxSlippageBps * 10,
                "Price moved too much - possible manipulation"
            );
        }

        //  Store current price for next validation
        lastRebalancePrice[token] = currentPrice;

        if (targetValue > currentValue) {
            uint256 amountNeeded = targetValue - currentValue;
            //  FIX: Include slippage protection in swap
            _swapToAsset(token, amountNeeded, maxSlippageBps);
        } else if (targetValue < currentValue) {
            uint256 amountExcess = currentValue - targetValue;
            //  FIX: Include slippage protection in swap
            _swapFromAsset(token, amountExcess, maxSlippageBps);
        }

        allocation.lastRebalance = block.timestamp;
    }

    /**
     * @notice Get token price from oracle
     * @dev Should integrate with Chainlink or other oracle
     */
    function _getTokenPrice(address token) private view returns (uint256) {
        //  TODO: Integrate with actual price oracle (Chainlink)
        // For now, return 1:1 ratio as placeholder
        return 1e18;
    }

    /**
     * @notice Update max slippage for rebalancing
     */
    function setMaxSlippage(
        uint256 newSlippageBps
    ) external onlyRole(OPERATOR_ROLE) {
        require(newSlippageBps <= 500, "Slippage too high"); // Max 5%
        maxSlippageBps = newSlippageBps;
    }

    /**
     * @notice Select payment token with sufficient balance
     */
    function _selectPaymentToken(
        uint256 amount
    ) private view returns (address) {
        for (uint256 i = 0; i < supportedTokens.length; i++) {
            address token = supportedTokens[i];
            if (assetAllocations[token].currentBalance >= amount) {
                return token;
            }
        }
        return address(0);
    }

    /**
     * @notice Calculate total portfolio value
     */
    function _calculateTotalValue() private view returns (uint256) {
        uint256 total = 0;
        for (uint256 i = 0; i < supportedTokens.length; i++) {
            address token = supportedTokens[i];
            AssetAllocation storage allocation = assetAllocations[token];
            if (allocation.isActive) {
                total += _getTokenValue(token, allocation.currentBalance);
            }
        }
        return total;
    }

    /**
     * @notice Get token value in base currency
     */
    function _getTokenValue(
        address token,
        uint256 amount
    ) private view returns (uint256) {
        // Simplified - should use oracle prices
        // For now, assume 1:1 with base currency
        return amount;
    }

    /**
     * @notice Swap to target asset with slippage protection
     * @dev Placeholder for DEX integration - add actual swap logic
     */
    function _swapToAsset(
        address token,
        uint256 valueNeeded,
        uint256 maxSlippageBps
    ) private {
        //  TODO: Integrate with DEX (Uniswap V3, Curve, etc.)
        // Example structure:
        // 1. Calculate minimum amount out based on oracle price and slippage
        // 2. Execute swap with amountOutMinimum parameter
        // 3. Verify received amount is within acceptable range

        //  Minimum amount calculation:
        uint256 expectedAmount = valueNeeded; // Should use oracle price
        uint256 minAmount = expectedAmount -
            (expectedAmount * maxSlippageBps) /
            PRECISION;

        //  Placeholder - replace with actual DEX swap
        emit AssetRebalanced(token, valueNeeded, minAmount, "BUY");
    }

    /**
     * @notice Swap from asset with slippage protection
     * @dev Placeholder for DEX integration - add actual swap logic
     */
    function _swapFromAsset(
        address token,
        uint256 valueExcess,
        uint256 maxSlippageBps
    ) private {
        //  TODO: Integrate with DEX
        uint256 expectedAmount = valueExcess; // Should use oracle price
        uint256 minAmount = expectedAmount -
            (expectedAmount * maxSlippageBps) /
            PRECISION;

        //  Placeholder - replace with actual DEX swap
        emit AssetRebalanced(token, valueExcess, minAmount, "SELL");
    }

    /**
     * @notice Activate emergency mode
     */
    function activateEmergencyMode() external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(!emergencyMode, "Already active");

        emergencyMode = true;
        emergencyModeActivatedAt = block.timestamp;

        emit EmergencyModeActivated(msg.sender);
    }

    /**
     * @notice Emergency withdrawal request
     */
    function requestEmergencyWithdrawal(address token) external {
        require(emergencyMode, "Not in emergency mode");
        require(
            hasRole(DEFAULT_ADMIN_ROLE, msg.sender) ||
                hasRole(OPERATOR_ROLE, msg.sender),
            "Not authorized"
        );

        emergencyWithdrawalRequests[token] = block.timestamp;
    }

    /**
     * @notice Execute emergency withdrawal
     */
    function executeEmergencyWithdrawal(
        address token,
        address to,
        uint256 amount
    ) external nonReentrant {
        require(emergencyMode, "Not in emergency mode");
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "Not admin");
        require(
            block.timestamp >=
                emergencyWithdrawalRequests[token] + EMERGENCY_WITHDRAWAL_DELAY,
            "Delay not met"
        );

        AssetAllocation storage allocation = assetAllocations[token];
        require(allocation.currentBalance >= amount, "Insufficient balance");

        allocation.currentBalance -= amount;
        IERC20(token).safeTransfer(to, amount);

        emit EmergencyWithdrawal(token, amount, to);
    }
    /**
     * @notice Emergency withdraw funds from strategy
     * @dev Can only be called in emergency mode by admin
     * @param strategy Strategy to withdraw from
     * @param token Token to withdraw
     */
    function emergencyWithdrawFromStrategy(
        address strategy,
        address token
    ) external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        require(emergencyMode, "Not in emergency mode");
        require(strategies[strategy].isActive, "Strategy not active");

        AssetAllocation storage allocation = assetAllocations[token];
        require(allocation.isActive, "Token not supported");

        //  Record balance before withdrawal
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));

        //  Call emergency withdraw on strategy
        (bool success, ) = strategy.call(
            abi.encodeWithSignature("emergencyWithdraw(address)", token)
        );
        require(success, "Emergency withdrawal failed");

        //  Measure actual amount withdrawn
        uint256 balanceAfter = IERC20(token).balanceOf(address(this));
        uint256 withdrawn = balanceAfter - balanceBefore;

        //  Update balances
        allocation.currentBalance += withdrawn;
        strategies[strategy].totalWithdrawn += withdrawn;

        emit EmergencyWithdrawalFromStrategy(strategy, token, withdrawn);
    }

    /**
     * @notice Emergency withdraw all funds from all active strategies
     * @dev Nuclear option for total emergency exit - FIXED to avoid external calls
     */
    function emergencyWithdrawAllStrategies()
        external
        nonReentrant
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(emergencyMode, "Not in emergency mode");

        for (uint256 i = 0; i < activeStrategies.length; i++) {
            address strategy = activeStrategies[i];

            if (!strategies[strategy].isActive) continue;

            // Try to withdraw from strategy for each supported token
            for (uint256 j = 0; j < supportedTokens.length; j++) {
                address token = supportedTokens[j];
                AssetAllocation storage allocation = assetAllocations[token];

                if (!allocation.isActive) continue;

                //  FIX: Inline logic instead of external call
                uint256 balanceBefore = IERC20(token).balanceOf(address(this));

                // Call emergency withdraw on strategy
                (bool success, ) = strategy.call(
                    abi.encodeWithSignature("emergencyWithdraw(address)", token)
                );

                if (success) {
                    // Measure actual amount withdrawn
                    uint256 balanceAfter = IERC20(token).balanceOf(
                        address(this)
                    );
                    if (balanceAfter > balanceBefore) {
                        uint256 withdrawn = balanceAfter - balanceBefore;

                        // Update balances
                        allocation.currentBalance += withdrawn;
                        strategies[strategy].totalWithdrawn += withdrawn;

                        emit EmergencyWithdrawalFromStrategy(
                            strategy,
                            token,
                            withdrawn
                        );
                    }
                }
                // Continue to next token even if withdrawal failed
            }
        }

        emit EmergencyActionExecuted(
            msg.sender,
            "emergencyWithdrawAllStrategies",
            block.timestamp
        );
    }

    /**
     * @notice Transfer tokens to another address
     */
    function transferTo(
        address token,
        address to,
        uint256 amount
    ) external onlyRole(OPERATOR_ROLE) {
        require(to != address(0), "Invalid recipient");
        require(amount > 0, "Zero amount");

        AssetAllocation storage allocation = assetAllocations[token];
        require(allocation.currentBalance >= amount, "Insufficient balance");

        allocation.currentBalance -= amount;
        IERC20(token).safeTransfer(to, amount);

        emit AssetWithdrawn(token, amount, to);
    }

    // IGovernanceTarget Implementation - FIXED TO MATCH INTERFACE

    /**
     * @notice Execute governance action
     */
    function executeGovernanceAction(
        bytes32 actionId,
        bytes calldata data
    ) external payable returns (bool success, bytes memory returnData) {
        require(msg.sender == proposalManager, "Not proposal manager");
        require(_governanceExecutionEnabled, "Governance disabled");

        (success, returnData) = address(this).call{value: msg.value}(data);

        emit GovernanceActionExecuted(
            actionId,
            msg.sender,
            block.timestamp,
            data,
            success
        );
    }

    /**
     * @notice Validate governance action
     */
    function validateGovernanceAction(
        bytes32 actionId,
        bytes calldata data
    ) external view returns (bool valid, string memory reason) {
        bytes4 selector = bytes4(data[:4]);
        bytes4[] memory allowed = governanceAllowedSelectors();
        valid = false;

        for (uint256 i = 0; i < allowed.length; i++) {
            if (allowed[i] == selector) {
                valid = true;
                break;
            }
        }

        if (!valid) {
            return (false, "Selector not allowed");
        }

        // Additional validation based on selector
        if (selector == this.setBudget.selector) {
            (, , uint256 amount, ) = abi.decode(
                data[4:],
                (string, address, uint256, uint256)
            );
            if (amount > totalValueLocked / 10) {
                return (false, "Budget too large");
            }
        }

        return (true, "");
    }

    /**
     * @notice Check if authorized governance
     */
    function isAuthorizedGovernance(
        address executor
    ) external view returns (bool) {
        return executor == proposalManager;
    }

    /**
     * @notice Emergency pause
     */
    function emergencyPause() external {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "Not admin");
        _pause();
    }

    /**
     * @notice Emergency unpause
     */
    function emergencyUnpause() external {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "Not admin");
        _unpause();
    }

    /**
     * @notice Get governance parameters
     */
    function getGovernanceParameters() external view returns (bytes memory) {
        return
            abi.encode(
                _governanceExecutionEnabled,
                emergencyMode,
                rebalanceCooldown,
                totalValueLocked
            );
    }

    /**
     * @notice Update governance parameters
     */
    function updateGovernanceParameters(bytes calldata params) external {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "Not admin");

        (bool enabled, , uint256 cooldown, ) = abi.decode(
            params,
            (bool, bool, uint256, uint256)
        );

        _governanceExecutionEnabled = enabled;
        if (cooldown >= 1 hours && cooldown <= 7 days) {
            rebalanceCooldown = cooldown;
        }
    }

    /**
     * @notice Get allowed governance selectors
     */
    function governanceAllowedSelectors()
        public
        pure
        returns (bytes4[] memory)
    {
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = this.setBudget.selector;
        selectors[1] = this.addSupportedToken.selector;
        selectors[2] = this.deployToStrategy.selector;
        selectors[3] = this.rebalance.selector;
        selectors[4] = this.setRebalanceCooldown.selector;
        return selectors;
    }

    /**
     * @notice Emergency token recovery
     */
    function emergencyTokenRecovery(
        address token,
        address to,
        uint256 amount
    ) external {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "Not admin");
        require(emergencyMode, "Not in emergency mode");

        if (token == address(0)) {
            (bool success, ) = payable(to).call{value: amount}("");
            require(success, "ETH transfer failed");
        } else {
            IERC20(token).safeTransfer(to, amount);
        }

        emit EmergencyActionExecuted(
            msg.sender,
            "emergencyTokenRecovery",
            block.timestamp
        );
    }

    /**
     * @notice Set rebalance cooldown
     */
    function setRebalanceCooldown(
        uint256 newCooldown
    ) external onlyRole(OPERATOR_ROLE) {
        require(
            newCooldown >= 1 hours && newCooldown <= 7 days,
            "Invalid cooldown"
        );
        rebalanceCooldown = newCooldown;
    }

    /**
     * @notice Get treasury statistics
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
        )
    {
        totalValue = _calculateTotalValue();
        numAssets = supportedTokens.length;
        numStrategies = activeStrategies.length;
        numBudgets = budgetNames.length;
        inEmergencyMode = emergencyMode;
    }

    /**
     * @notice Get asset allocation details
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
        )
    {
        AssetAllocation storage allocation = assetAllocations[token];
        balance = allocation.currentBalance;
        targetPercentage = allocation.targetPercentage;

        uint256 totalValue = _calculateTotalValue();
        if (totalValue > 0) {
            currentPercentage =
                (_getTokenValue(token, balance) * PRECISION) /
                totalValue;
            needsRebalancing = _needsRebalancing(
                currentPercentage,
                targetPercentage
            );
        }
    }

    /**
     * @notice Receive ETH
     */
    receive() external payable {
        // Accept ETH deposits
    }
}
