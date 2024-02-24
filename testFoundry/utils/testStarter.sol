pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import { Vm } from "forge-std/Vm.sol";

import "@openzeppelin/contracts-5.0/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-5.0/token/ERC20/IERC20.sol";
import "contracts/helpers/SwapHandler/GenericSwapAndBridgeHandler.sol"; //
import { LifiImplementation } from "contracts/helpers/SwapHandler/Implementaions/LifiImplementation.sol";
//
import "contracts/governance/NoyaGovernanceBase.sol";
import "contracts/helpers/valueOracle/NoyaValueOracle.sol";
import { ChainlinkOracleConnector } from "contracts/helpers/valueOracle/oracles/ChainlinkOracleConnector.sol";
import "contracts/accountingManager/AccountingManager.sol";

contract testStarter is Test {
    address public owner;
    address public alice;
    address public baseToken;

    uint256 vaultId = 0;

    SwapAndBridgeHandler swapHandler;
    LifiImplementation lifiImplementation;
    NoyaValueOracle noyaOracle;
    ChainlinkOracleConnector oracleConnector;
    AccountingManager accountingManager;
    PositionRegistry registry;

    address constant lifiDiamond = 0x1231DEB6f5749EF6cE6943a275A1D3E7486F4EaE;

    constructor() {
        owner = address(0xB54c2435Dc58Fd6F172BecEe6B2F95b9423f9E79);
        alice = address(0xE9DD92FeC168e0b4FCffEEf6F602E5575E8F12b4);
    }

    function deployEverythingNormal(address _base) public {
        baseToken = _base;
        registry = new PositionRegistry(owner, owner, owner);
        console.log("PositionRegistry deployed: %s", address(registry));
        deployNoyaOracle();

        address[] memory assets = new address[](0);
        address[] memory baseTokens = new address[](0);
        address[] memory sources = new address[](0);

        deployValueOracle(assets, baseTokens, sources);
        deployNoyaAccounting();

        registry.addVault(0, address(accountingManager), baseToken, owner, owner, owner, owner, owner, owner, assets);

        INoyaValueOracle[][] memory oracles2 = new INoyaValueOracle[][](0);

        noyaOracle.addBaseTokenDefaultPriceSource(assets, oracles2);

        accountingManager.setDepositLimits(10e20, 10e20);

        deploySwapHandler();
    }

    function deployNoyaAccounting() public {
        accountingManager = new AccountingManager("V1", "V1", baseToken, registry, address(noyaOracle), 0);

        console.log("Accounting deployed: %s", address(accountingManager));
    }

    function deployNoyaOracle() public {
        noyaOracle = new NoyaValueOracle(registry, 0);

        console.log("NoyaValueOracle deployed: %s", address(noyaOracle));
    }

    function deployValueOracle(address[] memory assets, address[] memory baseTokens, address[] memory sources) public {
        oracleConnector = new ChainlinkOracleConnector(assets, baseTokens, sources);

        console.log("ChainlinkOracleConnector deployed: %s", address(oracleConnector));
    }

    function deploySwapHandler() public {
        swapHandler = new SwapAndBridgeHandler(new address[](0), address(noyaOracle), registry, 0);

        lifiImplementation = new LifiImplementation(address(swapHandler));

        console.log("SwapHandler deployed: %s", address(swapHandler));
        console.log("LifiImplementation deployed: %s", address(lifiImplementation));

        // --------------------------------- add swap route ---------------------------------
        RouteData[] memory _routeData = new RouteData[](1);
        _routeData[0].route = address(lifiImplementation);
        _routeData[0].isEnabled = true;
        _routeData[0].isBridge = false;

        swapHandler.addRoutes(_routeData);
    }

    function addTokenToChainlinkOracle(address token, address base, address source) public {
        address[] memory assets = new address[](1);
        assets[0] = token;
        address[] memory baseTokens = new address[](1);
        baseTokens[0] = base;
        address[] memory sources = new address[](1);
        sources[0] = source;
        oracleConnector.setAssetSources(assets, baseTokens, sources);
    }

    function addTokenToNoyaOracle(address token, ChainlinkOracleConnector connector) public {
        INoyaValueOracle[] memory oracles = new INoyaValueOracle[](1);
        oracles[0] = INoyaValueOracle(connector);
        INoyaValueOracle[][] memory oracles2 = new INoyaValueOracle[][](1);
        oracles2[0] = oracles;
        address[] memory assets = new address[](1);
        assets[0] = token;
        noyaOracle.addBaseTokenDefaultPriceSource(assets, oracles2);
    }

    function addTrustedTokens(uint256 _vaultId, address connector, address token) internal {
        address[] memory tokens = new address[](1);
        tokens[0] = token;
        registry.updateConnectorTrustedTokens(_vaultId, connector, tokens, true);
    }

    function addConnectorToRegistry(uint256 _vaultId, address connector) public {
        address[] memory connectors = new address[](1);
        connectors[0] = connector;
        bool[] memory enabled = new bool[](1);
        enabled[0] = true;
        registry.addConnector(_vaultId, connectors, enabled);
        swapHandler.addEligibleUser(connector);
        console.log("added as eligible user for swap: %s", connector);
    }

    function _dealERC20(address _token, address _recipient, uint256 _amount) internal {
        deal({ token: address(_token), to: _recipient, give: _amount });
    }

    function _dealWhale(address _token, address _recipient, address _whale, uint256 _amount) internal {
        vm.startPrank(_whale);
        IERC20(_token).transfer(_recipient, _amount);
        vm.stopPrank();
    }

    function isCloseTo(uint256 a, uint256 b, uint256 precisionBP) internal pure returns (bool) {
        uint256 diff = a > b ? a - b : b - a;
        uint256 precision = (b * precisionBP) / 10_000;
        return diff <= precision;
    }
}
