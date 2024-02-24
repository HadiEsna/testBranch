// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.20;

import "@openzeppelin/contracts-5.0/access/Ownable.sol";
import "../../interface/valueOracle/INoyaValueOracle.sol";
import { NoyaGovernanceBase, PositionRegistry } from "../../governance/NoyaGovernanceBase.sol";

/// @title NoyaValueOracle
/// @notice This contract is used to get the value of an asset in terms of a base Token
contract NoyaValueOracle is NoyaGovernanceBase, INoyaValueOracle {
    /// @notice Default price sources for base currencies
    mapping(address => INoyaValueOracle[]) public baseTokenDefaultPriceSource;
    /// @notice Price sources for assets
    mapping(address => mapping(address => INoyaValueOracle[])) public assetPriceSource;
    /// @notice Default max price deviation
    uint256 public defaultMaxPriceDeviation = 50;
    /// @notice Max price deviation for specific assets and base currencies
    mapping(address => mapping(address => uint256)) public maxPriceDeviation;

    error NoyaOracle_PriceOracleUnavailable(address asset, address baseToken);
    error NoyaOracle_PriceDeviationLimitReached(
        address asset, address baseToken, uint256 amount, uint256 priceDeviation
    );
    error NoyaOracle_NoPriceAvailable(uint256 totalValue, uint256 totalWeight);

    constructor(PositionRegistry _registry, uint256 _vaultId) NoyaGovernanceBase(_registry, _vaultId) { }

    /// @notice Adds a default price source for a base Token
    /// @param baseCurrencies The address of the base Token
    /// @param oracles The array of oracle connectors
    function addBaseTokenDefaultPriceSource(address[] calldata baseCurrencies, INoyaValueOracle[][] calldata oracles)
        public
        onlyMaintainer
    {
        for (uint256 i = 0; i < baseCurrencies.length; i++) {
            for (uint256 j = 0; j < oracles[i].length; j++) {
                baseTokenDefaultPriceSource[baseCurrencies[i]].push(oracles[i][j]);
            }
        }
    }

    /// @notice Adds a price source for an asset
    /// @param asset The address of the asset
    /// @param baseToken The address of the base Token
    /// @param oracles The array of oracle connectors
    function addAssetPriceSource(address asset, address baseToken, INoyaValueOracle[] calldata oracles)
        external
        onlyMaintainer
    {
        for (uint256 i = 0; i < oracles.length; i++) {
            assetPriceSource[asset][baseToken].push(oracles[i]);
        }
    }

    /// @notice Sets the default max price deviation
    /// @param _defaultMaxPriceDeviation The new default max price deviation
    function setDefaultMaxPriceDeviation(uint256 _defaultMaxPriceDeviation) external onlyMaintainer {
        defaultMaxPriceDeviation = _defaultMaxPriceDeviation;
    }

    /// @notice Sets the max price deviation for a specific asset and base Token
    /// @param asset The address of the asset
    /// @param baseToken The address of the base Token
    /// @param _maxPriceDeviation The new max price deviation
    function setMaxPriceDeviation(address asset, address baseToken, uint256 _maxPriceDeviation)
        external
        onlyMaintainer
    {
        maxPriceDeviation[asset][baseToken] = _maxPriceDeviation;
    }

    /// @notice Gets the value of an asset in terms of a base Token
    /// @param asset The address of the asset
    /// @param baseToken The address of the base Token
    /// @param amount The amount of the asset
    /// @return The value of the asset in terms of the base Token
    function getValue(address asset, address baseToken, uint256 amount) public view returns (uint256) {
        return getValue(asset, baseToken, amount, 1);
    }

    error Test(address asset, address baseToken, uint256 amount, address value);

    /// @notice Gets the value of an asset in terms of a base Token, considering a specific number of sources
    /// @param asset The address of the asset
    /// @param baseToken The address of the base Token
    /// @param amount The amount of the asset
    /// @param neededSourcesCount The number of sources to consider for the price
    /// @return The value of the asset in terms of the base Token
    function getValue(address asset, address baseToken, uint256 amount, uint256 neededSourcesCount)
        public
        view
        returns (uint256)
    {
        if (asset == baseToken) {
            return amount;
        }

        if (amount == 0) {
            return 0;
        }

        INoyaValueOracle[] memory priceSources = assetPriceSource[asset][baseToken];
        if (priceSources.length < neededSourcesCount) {
            priceSources = baseTokenDefaultPriceSource[baseToken];
        }

        // revert Test(asset, baseToken, neededSourcesCount, address(baseTokenDefaultPriceSource[baseToken][0]));
        if (priceSources.length < neededSourcesCount) {
            revert NoyaOracle_PriceOracleUnavailable(address(0), baseToken);
        }

        return getAverageValue(asset, baseToken, amount, priceSources);
    }

    /// @notice Gets the average value of an asset in terms of a base Token
    /// @param asset The address of the asset
    /// @param baseToken The address of the base Token
    /// @param amount The amount of the asset
    /// @param oracles The array of oracle connectors
    /// @return The average value of the asset in terms of the base Token
    function getAverageValue(address asset, address baseToken, uint256 amount, INoyaValueOracle[] memory oracles)
        public
        view
        returns (uint256)
    {
        if (asset == baseToken) {
            return amount;
        }

        if (oracles.length == 0) {
            revert NoyaOracle_PriceOracleUnavailable(asset, baseToken);
        }

        if (oracles.length == 1) {
            return oracles[0].getValue(asset, baseToken, amount);
        }

        uint256 minPrice = 0;
        uint256 maxPrice = 0;

        uint256 totalValue = 0;
        uint256 totalWeight = 0;

        // Iterate over all oracles to calculate the average value
        for (uint256 i = 0; i < oracles.length; i++) {
            uint256 value = oracles[i].getValue(asset, baseToken, amount);
            totalValue += value;
            totalWeight += 1;
            if (minPrice == 0 || value < minPrice) {
                minPrice = value;
            }
            if (maxPrice == 0 || value > maxPrice) {
                maxPrice = value;
            }
        }

        if (totalValue / totalWeight == 0) {
            revert NoyaOracle_NoPriceAvailable(totalValue, totalWeight);
        }

        uint256 currentMaxPriceDeviation = maxPriceDeviation[asset][baseToken];
        if (currentMaxPriceDeviation == 0) {
            currentMaxPriceDeviation = defaultMaxPriceDeviation;
        }

        // Check if the price deviation is within the acceptable limit
        if ((maxPrice * 10_000) / minPrice - 10_000 > currentMaxPriceDeviation) {
            revert NoyaOracle_PriceDeviationLimitReached(
                asset, baseToken, amount, (maxPrice * 10_000) / minPrice - 10_000
            );
        }

        return totalValue / totalWeight;
    }
}
