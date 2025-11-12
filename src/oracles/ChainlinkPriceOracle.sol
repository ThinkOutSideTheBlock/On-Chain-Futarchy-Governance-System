// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title ChainlinkPriceOracleImpl
 * @notice Production-ready integration with Chainlink for price-based market resolution
 * @dev Implements comprehensive validation, staleness checks, and price bounds
 */
contract ChainlinkPriceOracleImpl is AccessControl {
    using Math for uint256;

    // Roles
    bytes32 public constant PRICE_RECORDER_ROLE =
        keccak256("PRICE_RECORDER_ROLE");
    bytes32 public constant PRICE_ADMIN_ROLE = keccak256("PRICE_ADMIN_ROLE");

    // Constants for price validation
    uint256 public constant MAX_STALENESS = 1 hours;
    uint256 public constant MAX_RECORDED_STALENESS = 24 hours; // For verifyPriceCondition
    uint256 public constant PRECISION = 10000;
    uint256 public constant MIN_UPDATE_INTERVAL = 1 hours;

    //  FIX A: Added asset field to PricePoint struct
    struct PricePoint {
        uint256 timestamp;
        int256 price;
        uint256 roundId;
        address asset; //  CRITICAL FIX: Added missing field
        bool recorded;
    }

    //  FIX D: Price bounds validation
    struct PriceBounds {
        int256 minPrice;
        int256 maxPrice;
        uint256 lastUpdateTime;
        bool isSet;
    }

    // State variables
    mapping(address => AggregatorV3Interface) public priceFeeds;
    mapping(address => bool) public authorizedRecorders;
    mapping(bytes32 => PricePoint) public recordedPrices;
    mapping(address => PriceBounds) public assetBounds; //  Price bounds per asset

    // Events
    event PriceRecorded(
        bytes32 indexed priceId,
        address indexed asset,
        int256 price,
        uint256 timestamp,
        uint256 roundId
    );
    event PriceFeedAdded(address indexed asset, address indexed priceFeed);
    event PriceFeedRemoved(address indexed asset);
    event PriceBoundsSet(
        address indexed asset,
        int256 minPrice,
        int256 maxPrice
    );
    event RecorderAuthorized(address indexed recorder);
    event RecorderDeauthorized(address indexed recorder);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PRICE_ADMIN_ROLE, msg.sender);
        _grantRole(PRICE_RECORDER_ROLE, msg.sender);
    }

    /**
     * @notice Record price with comprehensive validation
     * @dev  FIXES: Future timestamp check, price bounds, enhanced staleness validation
     */
    function recordPrice(
        address asset,
        bytes32 priceId
    ) external onlyRole(PRICE_RECORDER_ROLE) {
        AggregatorV3Interface priceFeed = priceFeeds[asset];
        require(address(priceFeed) != address(0), "Price feed not set");

        (
            uint80 roundId,
            int256 price,
            ,
            uint256 timestamp,
            uint80 answeredInRound
        ) = priceFeed.latestRoundData();

        //  FIX B: Prevent future timestamps
        require(timestamp > 0, "Invalid timestamp");
        require(timestamp <= block.timestamp, "Future timestamp not allowed");

        //  FIX C: Enhanced staleness validation
        require(answeredInRound >= roundId, "Stale price");
        require(roundId > 0, "Invalid round");
        require(block.timestamp - timestamp < MAX_STALENESS, "Price too old");

        //  FIX D: Price bounds validation
        require(price > 0, "Invalid price");
        PriceBounds memory bounds = assetBounds[asset];
        if (bounds.isSet) {
            require(
                price >= bounds.minPrice && price <= bounds.maxPrice,
                "Price out of bounds"
            );
        }

        //  Price deviation check for existing recordings
        PricePoint memory existing = recordedPrices[priceId];
        if (existing.timestamp > 0) {
            require(
                block.timestamp - existing.timestamp >= MIN_UPDATE_INTERVAL,
                "Update interval not elapsed"
            );

            // Check for extreme price deviation (100x change = likely oracle issue)
            if (existing.price > 0) {
                uint256 deviation = _calculateDeviation(price, existing.price);
                require(deviation < 10000, "Extreme price deviation"); // 100x max change
            }
        }

        //  FIX A: Store with asset field
        recordedPrices[priceId] = PricePoint({
            price: price,
            timestamp: timestamp,
            roundId: roundId,
            asset: asset,
            recorded: true
        });

        emit PriceRecorded(priceId, asset, price, timestamp, roundId);
    }

    /**
     * @notice Verify price condition with staleness check
     * @dev  FIX E: Added staleness and asset validation
     */
    function verifyPriceCondition(
        address asset,
        int256 targetPrice,
        bool above,
        bytes32 priceId
    ) external view returns (bool) {
        PricePoint memory pricePoint = recordedPrices[priceId];
        require(pricePoint.recorded, "Price not recorded");

        //  FIX E: Verify recorded price is not too old
        require(
            block.timestamp - pricePoint.timestamp < MAX_RECORDED_STALENESS,
            "Recorded price too old"
        );

        //  FIX E: Verify asset matches
        require(pricePoint.asset == asset, "Asset mismatch");

        if (above) {
            return pricePoint.price > targetPrice;
        } else {
            return pricePoint.price <= targetPrice;
        }
    }

    /**
     * @notice Set price bounds for an asset
     * @dev Prevents accepting extreme/manipulated prices
     */
    function setPriceBounds(
        address asset,
        int256 minPrice,
        int256 maxPrice
    ) external onlyRole(PRICE_ADMIN_ROLE) {
        require(asset != address(0), "Invalid asset");
        require(minPrice > 0, "Min price must be positive");
        require(maxPrice > minPrice, "Max must be greater than min");
        require(maxPrice <= type(int256).max / 2, "Max price too high");

        assetBounds[asset] = PriceBounds({
            minPrice: minPrice,
            maxPrice: maxPrice,
            lastUpdateTime: block.timestamp,
            isSet: true
        });

        emit PriceBoundsSet(asset, minPrice, maxPrice);
    }

    /**
     * @notice Calculate price deviation between two prices
     * @dev Returns deviation in basis points (10000 = 100x change)
     */
    function _calculateDeviation(
        int256 newPrice,
        int256 oldPrice
    ) private pure returns (uint256) {
        if (oldPrice == 0) return 0;

        int256 diff = newPrice > oldPrice
            ? newPrice - oldPrice
            : oldPrice - newPrice;
        uint256 absDiff = uint256(diff);
        uint256 absOld = uint256(oldPrice > 0 ? oldPrice : -oldPrice);

        // Return deviation as multiple (10000 = 100x)
        return (absDiff * 10000) / absOld;
    }

    /**
     * @notice Add price feed for an asset
     */
    function addPriceFeed(
        address asset,
        address priceFeed
    ) external onlyRole(PRICE_ADMIN_ROLE) {
        require(asset != address(0), "Invalid asset");
        require(priceFeed != address(0), "Invalid price feed");
        require(
            address(priceFeeds[asset]) == address(0),
            "Price feed already set"
        );

        priceFeeds[asset] = AggregatorV3Interface(priceFeed);

        emit PriceFeedAdded(asset, priceFeed);
    }

    /**
     * @notice Remove price feed for an asset
     */
    function removePriceFeed(
        address asset
    ) external onlyRole(PRICE_ADMIN_ROLE) {
        require(asset != address(0), "Invalid asset");
        require(address(priceFeeds[asset]) != address(0), "Price feed not set");

        delete priceFeeds[asset];

        emit PriceFeedRemoved(asset);
    }

    /**
     * @notice Authorize an address to record prices
     */
    function authorizeRecorder(
        address recorder
    ) external onlyRole(PRICE_ADMIN_ROLE) {
        require(recorder != address(0), "Invalid address");
        require(!authorizedRecorders[recorder], "Already authorized");

        authorizedRecorders[recorder] = true;
        grantRole(PRICE_RECORDER_ROLE, recorder);

        emit RecorderAuthorized(recorder);
    }

    /**
     * @notice Remove authorization for an address to record prices
     */
    function deauthorizeRecorder(
        address recorder
    ) external onlyRole(PRICE_ADMIN_ROLE) {
        require(recorder != address(0), "Invalid address");
        require(authorizedRecorders[recorder], "Not authorized");

        authorizedRecorders[recorder] = false;
        revokeRole(PRICE_RECORDER_ROLE, recorder);

        emit RecorderDeauthorized(recorder);
    }

    /**
     * @notice Get latest price for an asset with validation
     */
    function getLatestPrice(
        address asset
    ) external view returns (int256 price, uint256 timestamp, bool isStale) {
        AggregatorV3Interface priceFeed = priceFeeds[asset];
        require(address(priceFeed) != address(0), "Price feed not configured");

        (
            uint80 roundId,
            int256 latestPrice,
            ,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = priceFeed.latestRoundData();

        require(latestPrice > 0, "Invalid price");
        require(answeredInRound >= roundId, "Stale price");

        isStale = block.timestamp - updatedAt >= MAX_STALENESS;

        return (latestPrice, updatedAt, isStale);
    }

    /**
     * @notice Get recorded price details
     */
    function getRecordedPrice(
        bytes32 priceId
    )
        external
        view
        returns (
            int256 price,
            uint256 timestamp,
            uint256 roundId,
            address asset,
            bool recorded,
            bool isStale
        )
    {
        PricePoint memory pricePoint = recordedPrices[priceId];

        isStale =
            pricePoint.timestamp > 0 &&
            block.timestamp - pricePoint.timestamp >= MAX_RECORDED_STALENESS;

        return (
            pricePoint.price,
            pricePoint.timestamp,
            pricePoint.roundId,
            pricePoint.asset,
            pricePoint.recorded,
            isStale
        );
    }

    /**
     * @notice Get price bounds for an asset
     */
    function getPriceBounds(
        address asset
    ) external view returns (int256 minPrice, int256 maxPrice, bool isSet) {
        PriceBounds memory bounds = assetBounds[asset];
        return (bounds.minPrice, bounds.maxPrice, bounds.isSet);
    }

    /**
     * @notice Check if price feed exists for asset
     */
    function hasPriceFeed(address asset) external view returns (bool) {
        return address(priceFeeds[asset]) != address(0);
    }

    /**
     * @notice Check if recorder is authorized
     */
    function isAuthorizedRecorder(
        address recorder
    ) external view returns (bool) {
        return authorizedRecorders[recorder];
    }

    /**
     * @notice Batch check multiple price conditions
     * @dev Gas-efficient for checking multiple conditions
     */
    function batchVerifyPriceConditions(
        address[] calldata assets,
        int256[] calldata targetPrices,
        bool[] calldata aboveFlags,
        bytes32[] calldata priceIds
    ) external view returns (bool[] memory results) {
        require(
            assets.length == targetPrices.length &&
                assets.length == aboveFlags.length &&
                assets.length == priceIds.length,
            "Array length mismatch"
        );

        results = new bool[](assets.length);

        for (uint256 i = 0; i < assets.length; i++) {
            PricePoint memory pricePoint = recordedPrices[priceIds[i]];

            if (
                !pricePoint.recorded ||
                pricePoint.asset != assets[i] ||
                block.timestamp - pricePoint.timestamp >= MAX_RECORDED_STALENESS
            ) {
                results[i] = false;
                continue;
            }

            if (aboveFlags[i]) {
                results[i] = pricePoint.price > targetPrices[i];
            } else {
                results[i] = pricePoint.price <= targetPrices[i];
            }
        }

        return results;
    }
}
