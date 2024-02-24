// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "../../interface/valueOracle/INoyaValueOracle.sol";
import "../../governance/NoyaGovernanceBase.sol";
import "../../interface/SwapHandler/ISwapAndBridgeHandler.sol";
import { SafeERC20, IERC20 } from "@openzeppelin/contracts-5.0/token/ERC20/utils/SafeERC20.sol";

contract SwapAndBridgeHandler is NoyaGovernanceBase, ISwapAndBridgeHandler {
    using SafeERC20 for IERC20;

    mapping(address => bool) public isEligibleToUse;
    INoyaValueOracle public valueOracle;
    mapping(address => mapping(address => uint256)) public slippageTolerance;
    uint256 public genericSlippageTolerance = 50_000; // 5% slippage tolerance
    RouteData[] public routes;

    modifier onlyEligibleUser() {
        require(isEligibleToUse[msg.sender], "NoyaSwapHandler: Not eligible to use");
        _;
    }

    modifier onlyExistingRoute(uint256 _routeId) {
        if (routes[_routeId].route == address(0) && !routes[_routeId].isEnabled) revert RouteNotFound();
        _;
    }

    constructor(address[] memory usersAddresses, address _valueOracle, PositionRegistry _registry, uint256 _vaultId)
        NoyaGovernanceBase(_registry, _vaultId)
    {
        for (uint256 i = 0; i < usersAddresses.length; i++) {
            isEligibleToUse[usersAddresses[i]] = true;
        }
        valueOracle = INoyaValueOracle(_valueOracle);
    }

    function setValueOracle(address _valueOracle) external onlyMaintainerOrEmergency {
        valueOracle = INoyaValueOracle(_valueOracle);
    }

    function setGeneralSlippageTolerance(uint256 _slippageTolerance) external onlyMaintainerOrEmergency {
        genericSlippageTolerance = _slippageTolerance;
    }

    function setSlippageTolerance(address _inputToken, address _outputToken, uint256 _slippageTolerance)
        external
        onlyMaintainerOrEmergency
    {
        slippageTolerance[_inputToken][_outputToken] = _slippageTolerance;
    }

    function addEligibleUser(address _user) external onlyMaintainerOrEmergency {
        isEligibleToUse[_user] = true;
    }

    /**
     * // @notice function responsible for calling the respective implementation
     *     // depending on the dex to be used
     *     // @param _swapRequest calldata follows the input data struct
     */
    function executeSwap(SwapRequest memory _swapRequest)
        external
        payable
        onlyEligibleUser
        onlyExistingRoute(_swapRequest.routeId)
        returns (uint256 _amountOut)
    {
        if (_swapRequest.amount == 0) revert InvalidAmount();
        RouteData memory swapImplInfo = routes[_swapRequest.routeId];
        if (swapImplInfo.isBridge) revert RouteNotAllowedForThisAction();

        if (_swapRequest.checkForSlippage && _swapRequest.minAmount == 0) {
            uint256 _slippageTolerance = slippageTolerance[_swapRequest.inputToken][_swapRequest.outputToken];
            if (_slippageTolerance == 0) {
                _slippageTolerance = genericSlippageTolerance;
            }
            INoyaValueOracle _priceOracle = INoyaValueOracle(valueOracle);
            uint256 _outputTokenValue =
                _priceOracle.getValue(_swapRequest.inputToken, _swapRequest.outputToken, _swapRequest.amount);

            _swapRequest.minAmount = (((1e6 - _slippageTolerance) * _outputTokenValue) / 1e6);
        }

        _amountOut = ISwapAndBridgeImplementation(swapImplInfo.route).performSwapAction(msg.sender, _swapRequest);

        emit ExecutionCompleted(
            _swapRequest.routeId, _swapRequest.amount, _amountOut, _swapRequest.inputToken, _swapRequest.outputToken
        );
    }

    function executeBridge(BridgeRequest calldata _bridgeRequest)
        external
        payable
        onlyEligibleUser
        onlyExistingRoute(_bridgeRequest.routeId)
    {
        RouteData memory bridgeImplInfo = routes[_bridgeRequest.routeId];

        if (!bridgeImplInfo.isBridge) revert RouteNotAllowedForThisAction();

        ISwapAndBridgeImplementation(bridgeImplInfo.route).performBridgeAction(msg.sender, _bridgeRequest);
    }

    function _isNative(address token) internal pure returns (bool isNative) {
        return token == address(0);
    }

    //
    // Route management functions
    //
    function addRoutes(RouteData[] memory _routes) public onlyMaintainer {
        for (uint256 i = 0; i < _routes.length; i++) {
            if (_routes[i].route == address(0)) revert invalidAddress();
            routes.push(_routes[i]);
            emit NewRouteAdded(i, _routes[i].route, _routes[i].isEnabled, _routes[i].isBridge);
        }
    }

    ///@notice disables the route  if required.
    function setEnableRoute(uint256 _routeId, bool enable) external onlyMaintainerOrEmergency {
        routes[_routeId].isEnabled = enable;
        emit RouteUpdate(_routeId, false);
    }

    function verifyRoute(uint256 _routeId, address addr) external view onlyExistingRoute(_routeId) {
        if (routes[_routeId].route != addr) {
            revert RouteNotFound();
        }
    }
}
