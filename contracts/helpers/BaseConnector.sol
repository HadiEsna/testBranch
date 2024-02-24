// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.20;

import "../interface/IConnector.sol";
import { NoyaGovernanceBase } from "../governance/NoyaGovernanceBase.sol";
import { PositionRegistry, PositionBP } from "../accountingManager/Registry.sol";
import "@openzeppelin/contracts-5.0/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-5.0/token/ERC721/utils/ERC721Holder.sol";
import { SwapAndBridgeHandler, SwapRequest } from "../helpers/SwapHandler/GenericSwapAndBridgeHandler.sol";
import "../interface/valueOracle/INoyaValueOracle.sol";
import "../governance/Watchers.sol";
import "@openzeppelin/contracts-5.0/token/ERC721/IERC721Receiver.sol";

struct BaseConnectorCP {
    PositionRegistry registry;
    uint256 vaultId;
    SwapAndBridgeHandler swapHandler;
    INoyaValueOracle valueOracle;
}

contract BaseConnector is NoyaGovernanceBase, IConnector {
    using SafeERC20 for IERC20;

    SwapAndBridgeHandler public swapHandler;
    INoyaValueOracle public valueOracle;

    uint256 public immutable MINIMUM_HEALTH_FACTOR = 15e17;
    uint256 public minimumHealthFactor;

    uint256 public DUST_LEVEL = 1;

    constructor(BaseConnectorCP memory params) NoyaGovernanceBase(params.registry, params.vaultId) {
        swapHandler = params.swapHandler;
        valueOracle = params.valueOracle;
        minimumHealthFactor = MINIMUM_HEALTH_FACTOR;
    }

    function updateMinimumHealthFactor(uint256 _minimumHealthFactor) external onlyMaintainer {
        if (_minimumHealthFactor < MINIMUM_HEALTH_FACTOR) {
            revert IConnector_LowHealthFactor(_minimumHealthFactor);
        }
        minimumHealthFactor = _minimumHealthFactor;
    }

    function updateSwapHandler(address payable _swapHandler) external onlyMaintainer {
        swapHandler = SwapAndBridgeHandler(_swapHandler);
        emit SwapHandlerUpdated(_swapHandler);
    }

    function updateValueOracle(address _valueOracle) external onlyMaintainer {
        valueOracle = INoyaValueOracle(_valueOracle);
        emit ValueOracleUpdated(_valueOracle);
    }

    function sendTokensToTrustedAddress(address token, uint256 amount, address caller, bytes memory data)
        external
        returns (uint256)
    {
        (address accountingManager,) = registry.getVaultAddresses(vaultId);
        if (registry.isAnActiveConnector(vaultId, msg.sender)) {
            IERC20(token).safeTransfer(address(msg.sender), amount);
        } else if (msg.sender == accountingManager) {
            (,,,, address watcherContract,) = registry.getGovernanceAddresses(vaultId);
            (uint256 newAmount, bytes memory newData) = abi.decode(data, (uint256, bytes));
            Watchers(watcherContract).verifyRemoveLiquidity(amount, newAmount, newData);

            IERC20(token).safeTransfer(address(accountingManager), newAmount);
            amount = newAmount;
        } else {
            uint256 routeId = abi.decode(data, (uint256));
            swapHandler.verifyRoute(routeId, msg.sender);
            if (caller != address(this)) revert IConnector_InvalidAddress(caller);
            IERC20(token).safeTransfer(msg.sender, amount);
        }
        _updateTokenInRegistry(token);
        return amount;
    }

    function _updateTokenInRegistry(address token, bool remove) internal {
        (address accountingManager,) = registry.getVaultAddresses(vaultId);
        bytes32 positionId = registry.calculatePositionId(accountingManager, 0, abi.encode(token));
        uint256 positionIndex =
            registry.getHoldingPositionIndex(vaultId, positionId, address(this), abi.encode(address(this)));
        if ((positionIndex == 0 && !remove) || (positionIndex > 0 && remove)) {
            registry.updateHoldingPosition(vaultId, positionId, abi.encode(address(this)), "", remove);
        }
    }

    function updateTokenInRegistry(address token) public onlyManager {
        _updateTokenInRegistry(token);
    }

    function _updateTokenInRegistry(address token) internal {
        _updateTokenInRegistry(token, IERC20(token).balanceOf(address(this)) == 0);
    }

    function addLiquidity(address[] memory tokens, uint256[] memory amounts, bytes memory data) external override {
        if (!registry.isAddressTrusted(vaultId, msg.sender)) {
            revert IConnector_InvalidAddress(msg.sender);
        }

        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 _balance = IERC20(tokens[i]).balanceOf(address(this));
            ITokenTransferCallBack(msg.sender).sendTokensToTrustedAddress(tokens[i], amounts[i], msg.sender, "");
            uint256 _balanceAfter = IERC20(tokens[i]).balanceOf(address(this));
            if (_balanceAfter < amounts[i] + _balance) {
                revert IConnector_InsufficientDepositAmount(_balanceAfter - _balance, amounts[i]);
            }
        }
        _addLiquidity(tokens, amounts, data);
        for (uint256 i = 0; i < tokens.length; i++) {
            _updateTokenInRegistry(tokens[i]);
        }
    }

    function swapHoldings(
        address[] memory tokensIn,
        address[] memory tokensOut,
        uint256[] memory amountsIn,
        bytes[] memory swapData,
        uint256[] memory routeIds
    ) external onlyManager {
        for (uint256 i = 0; i < tokensIn.length; i++) {
            _executeSwap(
                SwapRequest(address(this), routeIds[i], amountsIn[i], tokensIn[i], tokensOut[i], swapData[i], true, 0)
            );
            _updateTokenInRegistry(tokensIn[i]);
            _updateTokenInRegistry(tokensOut[i]);
        }
    }

    function _executeSwap(SwapRequest memory swapRequest) internal returns (uint256 amountOut) {
        amountOut = swapHandler.executeSwap(swapRequest);
    }

    function getUnderlyingTokens(uint256 positionTypeId, bytes memory data) public view returns (address[] memory) {
        if (positionTypeId == 0) {
            address[] memory tokens = new address[](1);
            tokens[0] = abi.decode(data, (address));
            return tokens;
        }
        return _getUnderlyingTokens(positionTypeId, data);
    }

    function getPositionTVL(HoldingPI memory p, address baseToken) public view returns (uint256) {
        return _getPositionTVL(p, baseToken);
    }

    function _getValue(address token, address baseToken, uint256 amount) internal view returns (uint256) {
        if (token == baseToken) {
            return amount;
        }
        if (amount == 0) {
            return 0;
        }
        return valueOracle.getValue(token, baseToken, amount);
    }

    function _getUnderlyingTokens(uint256, bytes memory) public view virtual returns (address[] memory) {
        return new address[](0);
    }

    function _removeLiquidity(address token, uint256 amount, bytes memory data) internal virtual { }

    function _addLiquidity(address[] memory, uint256[] memory, bytes memory) internal virtual returns (bool) {
        return true;
    }

    function _getPositionTVL(HoldingPI memory, address) public view virtual returns (uint256 tvl) {
        return 0;
    }

    function _approveOperations(address _token, address _spender, uint256 _amount) internal virtual {
        uint256 currentAllowance = IERC20(_token).allowance(address(this), _spender);
        if (currentAllowance >= _amount) {
            return;
        }
        IERC20(_token).forceApprove(_spender, _amount);
    }

    function _revokeApproval(address _token, address _spender) internal virtual {
        IERC20(_token).forceApprove(_spender, 0);
    }
}
