// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "../../../interface/valueOracle/INoyaValueOracle.sol";
import "../../../interface/valueOracle/AggregatorV3Interface.sol";

import "@openzeppelin/contracts-5.0/access/Ownable.sol";
import "@openzeppelin/contracts-5.0/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts-5.0/access/AccessControl.sol";

contract ChainlinkOracleConnector is INoyaValueOracle, AccessControl {
    /**
     * @notice The address of the Noya maintainer contract
     * @dev The maintainer is responsible for updating the oracle
     * @dev The maintainer is a timelock contract
     */
    bytes32 public constant MAINTAINER_ROLE = keccak256("MAINTAINER_ROLE");

    /// @notice The threshold for the age of the price data
    uint256 public chainlinkPriceAgeThreshold = 5 days;

    /*
    * @notice The address of the source of each pair of assets
    * @dev the tokens should be in the same order as in the chainlink contract
    */
    mapping(address => mapping(address => address)) private assetsSources;

    /*
    * @notice The addresses that represents ETH and USD
    */
    address public constant ETH = address(0);
    address public constant USD = address(840);

    /// -----------------------------------------------------------------------
    /// Events
    /// -----------------------------------------------------------------------
    event AssetSourceUpdated(address indexed asset, address indexed baseToken, address indexed source);

    /// -----------------------------------------------------------------------
    /// Errors
    /// -----------------------------------------------------------------------
    error NoyaChainlinkOracle_DATA_OUT_OF_DATE();
    error NoyaChainlinkOracle_INCONSISTENT_PARAMS_LENGTH();
    error NoyaChainlinkOracle_PRICE_ORACLE_UNAVAILABLE(address asset, address baseToken, address source);
    error NoyaChainlinkOracle_INVALID_INPUT();

    /**
     * @notice Constructor
     * @param assets The addresses of the assets
     * @param baseTokens The addresses of the base tokens
     * @param sources The address of the source of each asset
     */
    constructor(address[] memory assets, address[] memory baseTokens, address[] memory sources) {
        _setAssetsSources(assets, baseTokens, sources);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MAINTAINER_ROLE, msg.sender);
        _setRoleAdmin(MAINTAINER_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(DEFAULT_ADMIN_ROLE, DEFAULT_ADMIN_ROLE);
    }

    /*
    * @notice Updates the threshold for the age of the price data
    * @param _chainlinkPriceAgeThreshold The new threshold
    * @dev The threshold should be between 1 day and 10 days
    */
    function updateChainlinkPriceAgeThreshold(uint256 _chainlinkPriceAgeThreshold) external onlyRole(MAINTAINER_ROLE) {
        if (_chainlinkPriceAgeThreshold <= 1 days || _chainlinkPriceAgeThreshold >= 10 days) {
            revert NoyaChainlinkOracle_INVALID_INPUT();
        }
        chainlinkPriceAgeThreshold = _chainlinkPriceAgeThreshold;
    }

    /*
    * @notice Updates the source of an asset
    * @param assets The addresses of the assets
    * @param baseTokens The addresses of the base tokens
    * @param sources The address of the source of each asset
    */
    function setAssetSources(address[] calldata assets, address[] calldata baseTokens, address[] calldata sources)
        external
        onlyRole(MAINTAINER_ROLE)
    {
        _setAssetsSources(assets, baseTokens, sources);
    }

    function _setAssetsSources(address[] memory assets, address[] memory baseToken, address[] memory sources)
        internal
    {
        if (assets.length != sources.length || assets.length != baseToken.length) {
            revert NoyaChainlinkOracle_INCONSISTENT_PARAMS_LENGTH();
        }
        for (uint256 i = 0; i < assets.length; i++) {
            assetsSources[assets[i]][baseToken[i]] = sources[i];
            emit AssetSourceUpdated(assets[i], baseToken[i], sources[i]);
        }
    }

    /*
    * @notice Gets the value of an asset in terms of a base Token
    * @param asset The address of the asset
    * @param baseToken The address of the base Token
    * @param amount The amount of the asset
    * @return The value of the asset in terms of the base Token
    * @dev The value is returned in the asset token decimals
    * @dev If the tokens are not ETH or USD, it should support the decimals() function in IERC20Metadata interface since the logic depends on it
    */
    function getValue(address asset, address baseToken, uint256 amount) public view returns (uint256) {
        if (amount == 0) return 0;

        if (asset == baseToken) {
            return amount;
        }

        (
            address primarySource,
            address secondarySource,
            bool isPrimaryInverse,
            bool isSecondaryInverse,
            address intermediate
        ) = getSourceOfAsset(asset, baseToken);
        if (primarySource == address(0)) {
            revert NoyaChainlinkOracle_PRICE_ORACLE_UNAVAILABLE(asset, baseToken, primarySource);
        }
        uint256 amountOut = 0;
        if (secondarySource == address(0)) {
            amountOut = getValueFromChainlinkFeed(
                AggregatorV3Interface(primarySource),
                amount,
                getTokenDecimals(isPrimaryInverse ? baseToken : asset),
                isPrimaryInverse
            );
        } else {
            uint256 amountOutPrimary = getValueFromChainlinkFeed(
                AggregatorV3Interface(primarySource),
                amount,
                getTokenDecimals(isPrimaryInverse ? intermediate : asset),
                isPrimaryInverse
            );
            amountOut = getValueFromChainlinkFeed(
                AggregatorV3Interface(secondarySource),
                amountOutPrimary,
                getTokenDecimals(isSecondaryInverse ? baseToken : intermediate),
                isSecondaryInverse
            );
        }
        return uint256(amountOut);
    }

    /*
    * @notice Gets the chainlink price feed contract and returns the value of an asset in terms of a base Token
    * @param source The address of the chainlink price feed contract
    * @param amountIn The amount of the asset
    * @param sourceTokenUnit The unit of the asset
    * @param isInverse Whether the price feed is inverse or not
    * @return The value of the asset in terms of the base Token
    * @dev The chainlink price feed data should be up to date
    * @dev The Chainlink price is the price of a token based on another token(or currency) so if we need to claculate the price of the later based on the first, we should put isInverse to true
    */
    function getValueFromChainlinkFeed(
        AggregatorV3Interface source,
        uint256 amountIn,
        uint256 sourceTokenUnit,
        bool isInverse
    ) public view returns (uint256) {
        int256 price;
        uint256 updatedAt;
        (, price,, updatedAt,) = source.latestRoundData();
        uint256 uintprice = uint256(price);
        if (block.timestamp - updatedAt > chainlinkPriceAgeThreshold) {
            revert NoyaChainlinkOracle_DATA_OUT_OF_DATE();
        }
        if (isInverse) {
            return (amountIn * sourceTokenUnit) / uintprice;
        }
        return (amountIn * uintprice) / (sourceTokenUnit);
    }

    /// @notice Gets the decimals of a token
    function getTokenDecimals(address token) public view returns (uint256) {
        if (token == ETH) return 10 ** 18;
        if (token == USD) return 10 ** 8;
        uint256 decimals = IERC20Metadata(token).decimals();
        return 10 ** decimals;
    }

    /*
    * @notice based on predefined sources in the contract, it calculates the feeds to use to get the price of an asset in terms of a base Token
    * @param asset The address of the asset
    * @param baseToken The address of the base Token
    * @return The addresses of the primary and secondary sources (if needed)
    * @return Whether the primary source is inverse or not
    * @return Whether the secondary source is inverse or not
    * @return The address of the intermediate token
    * @dev Sometimes we need to use two sources to get the price of an asset in terms of a base Token (e.g. asset/USD and USD/baseToken or asset/ETH and ETH/baseToken)
    * @dev We used only USD and ETH as intermediate tokens since they are the most common ones
    */
    function getSourceOfAsset(address asset, address baseToken)
        public
        view
        returns (
            address primarySource,
            address secondarySource,
            bool isPrimaryInverse,
            bool isSecondarys,
            address intermediate
        )
    {
        if (assetsSources[asset][baseToken] != address(0) || assetsSources[baseToken][asset] != address(0)) {
            return (
                getNotZeroAddress(assetsSources[asset][baseToken], assetsSources[baseToken][asset]),
                address(0),
                assetsSources[asset][baseToken] == address(0),
                false,
                address(0)
            );
        }
        if (
            (assetsSources[asset][USD] != address(0) || assetsSources[USD][asset] != address(0))
                && (assetsSources[baseToken][USD] != address(0) || assetsSources[USD][baseToken] != address(0))
        ) {
            return (
                getNotZeroAddress(assetsSources[asset][USD], assetsSources[USD][asset]),
                getNotZeroAddress(assetsSources[baseToken][USD], assetsSources[USD][baseToken]),
                assetsSources[asset][USD] == address(0),
                assetsSources[baseToken][USD] != address(0),
                USD
            );
        }
        if (
            (assetsSources[asset][ETH] != address(0) || assetsSources[ETH][asset] != address(0))
                && (assetsSources[baseToken][ETH] != address(0) || assetsSources[ETH][baseToken] != address(0))
        ) {
            return (
                getNotZeroAddress(assetsSources[asset][ETH], assetsSources[ETH][asset]),
                getNotZeroAddress(assetsSources[baseToken][ETH], assetsSources[ETH][baseToken]),
                assetsSources[asset][ETH] == address(0),
                assetsSources[baseToken][ETH] != address(0),
                ETH
            );
        }
        return (address(0), address(0), false, false, address(0));
    }

    /// @notice Gets the address that is not zero (if both are zero, it returns zero)
    function getNotZeroAddress(address a, address b) public pure returns (address) {
        if (a != address(0)) return a;
        return b;
    }
}
