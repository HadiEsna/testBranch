// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { Ownable } from "@openzeppelin/contracts-5.0/access/Ownable.sol";
import { SafeERC20, IERC20 } from "@openzeppelin/contracts-5.0/token/ERC20/utils/SafeERC20.sol";
import "../../../interface/SwapHandler/ISwapAndBridgeHandler.sol";
import "../../../interface/ITokenTransferCallBack.sol";

contract LifiImplementation is ISwapAndBridgeImplementation, Ownable {
    using SafeERC20 for IERC20;

    mapping(address => bool) public isHandler;
    mapping(string => bool) public isBridgeWhiteListed;
    mapping(uint256 => bool) public isChainSupported;
    address public lifi = 0x1231DEB6f5749EF6cE6943a275A1D3E7486F4EaE;

    bytes4 public constant LI_FI_GENERIC_SWAP_SELECTOR = 0x4630a0d8;

    // --------------------- Constructor --------------------- //

    constructor(address swapHandler) Ownable(msg.sender) {
        isHandler[swapHandler] = true;
    }

    // --------------------- Modifiers --------------------- //

    modifier onlyHandler() {
        require(isHandler[msg.sender] == true, "LifiImplementation: INVALID_SENDER");
        _;
    }

    // --------------------- Management Functions --------------------- //

    function addHandler(address _handler, bool state) external onlyOwner {
        isHandler[_handler] = state;
    }

    function addChain(uint256 _chainId, bool state) external onlyOwner {
        isChainSupported[_chainId] = state;
    }

    function addBridgeBlacklist(string memory _chainId, bool state) external onlyOwner {
        isBridgeWhiteListed[_chainId] = state;
    }

    // --------------------- Swap Functions --------------------- //

    function performSwapAction(address caller, SwapRequest calldata _request)
        external
        payable
        override
        returns (uint256)
    {
        require(verifySwapData(_request), "LifiImplementation: INVALID_SWAP_DATA");
        uint256 balanceOut0 = 0;
        if (_request.outputToken == address(0)) {
            balanceOut0 = address(_request.from).balance;
        } else {
            balanceOut0 = IERC20(_request.outputToken).balanceOf(_request.from);
        }
        _forward(IERC20(_request.inputToken), _request.from, _request.amount, caller, _request.data, _request.routeId);
        uint256 balanceOut1 = 0;
        if (_request.outputToken == address(0)) {
            balanceOut1 = address(_request.from).balance;
        } else {
            balanceOut1 = IERC20(_request.outputToken).balanceOf(_request.from);
        }

        emit Swapped(balanceOut0, balanceOut1, _request.outputToken);

        return balanceOut1 - balanceOut0;
    }

    function verifySwapData(SwapRequest calldata _request) public view override returns (bool) {
        bytes4 selector = bytes4(_request.data[:4]);
        if (selector != LI_FI_GENERIC_SWAP_SELECTOR) {
            revert InvalidSelector();
        }
        (address sendingAssetId, uint256 amount, address from, address receivingAssetId, uint256 receivingAmount) =
            ILiFi(lifi).extractGenericSwapParameters(_request.data);

        if (from != _request.from) revert InvalidReceiver(from, _request.from);
        if (receivingAmount < _request.minAmount) revert InvalidMinAmount();
        if (sendingAssetId != _request.inputToken) revert InvalidInputToken();
        if (receivingAssetId != _request.outputToken) revert InvalidOutputToken();
        if (amount != _request.amount) revert InvalidAmount();

        return true;
    }

    // --------------------- Bridge Functions --------------------- //

    function performBridgeAction(address caller, BridgeRequest calldata _request)
        external
        payable
        override
        onlyHandler
    {
        verifyBridgeData(_request);
        _forward(IERC20(_request.inputToken), _request.from, _request.amount, caller, _request.data, _request.routeId);
    }

    function verifyBridgeData(BridgeRequest calldata _request) public view override returns (bool) {
        ILiFi.BridgeData memory bridgeData = ILiFi(lifi).extractBridgeData(_request.data);

        if (isBridgeWhiteListed[bridgeData.bridge] == false) revert BridgeBlacklisted();
        if (isChainSupported[bridgeData.destinationChainId] == false) revert InvalidChainId();
        if (bridgeData.sendingAssetId != _request.inputToken) revert InvalidFromToken();
        if (bridgeData.receiver != _request.receiverAddress) {
            revert InvalidReceiver(bridgeData.receiver, _request.receiverAddress);
        }
        if (bridgeData.minAmount > _request.amount) revert InvalidMinAmount();
        if (bridgeData.destinationChainId != _request.destChainId) revert InvalidToChainId();

        return true;
    }

    function _forward(IERC20 token, address from, uint256 amount, address caller, bytes calldata data, uint256 routeId)
        internal
        virtual
    {
        if (!_isNative(token)) {
            ITokenTransferCallBack(from).sendTokensToTrustedAddress(address(token), amount, caller, abi.encode(routeId));

            _setAllowance(token, lifi, amount);
        }

        (bool success, bytes memory err) = lifi.call{ value: msg.value }(data);

        if (!success) {
            revert FailedToForward(err);
        }

        emit Forwarded(lifi, address(token), amount, data);
    }

    function _setAllowance(IERC20 token, address spender, uint256 amount) internal {
        if (_isNative(token)) {
            return;
        }
        if (spender == address(0)) {
            revert SpenderIsInvalid();
        }

        uint256 allowance = token.allowance(address(this), spender);

        if (allowance < amount) {
            if (allowance != 0) {
                token.approve(spender, 0);
            }
            token.approve(spender, type(uint256).max);
        }
    }

    function _isNative(IERC20 token) internal pure returns (bool isNative) {
        return address(token) == address(0);
    }

    function rescueFunds(address token, address userAddress, uint256 amount) external onlyOwner {
        if (token == address(0)) {
            payable(userAddress).transfer(amount);
        } else {
            IERC20(token).safeTransfer(userAddress, amount);
        }
    }
}
