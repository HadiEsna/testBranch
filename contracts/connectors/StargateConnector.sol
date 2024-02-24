pragma solidity 0.8.20;

import "../helpers/BaseConnector.sol";
import "../external/interfaces/Stargate/IStargateRouter.sol";

struct StargateRequest {
    uint256 poolId;
    uint256 routerAmount;
    uint256 LPStakingAmount;
}

contract StargateConnector is BaseConnector {
    // ------------ state variables -------------- //

    IStargateLPStaking LPStaking;
    IStargateRouter stargateRouter;
    address rewardToken;

    uint256 public constant STARGATE_LP_POSITION_TYPE = 1;

    // ------------ Constructor -------------- //
    constructor(address lpStacking, address _stargateRouter, BaseConnectorCP memory baseConnectorParams)
        BaseConnector(baseConnectorParams)
    {
        LPStaking = IStargateLPStaking(lpStacking);
        stargateRouter = IStargateRouter(_stargateRouter);
        rewardToken = LPStaking.stargate();
    }

    // ------------ Connector functions -------------- //
    function depositIntoStargatePool(StargateRequest calldata depositRequest) external onlyManager {
        address lpAddress = LPStaking.poolInfo(depositRequest.poolId).lpToken;
        address underlyingToken = IStargatePool(lpAddress).token();
        if (depositRequest.routerAmount > 0) {
            _approveOperations(underlyingToken, address(stargateRouter), depositRequest.routerAmount);
            stargateRouter.addLiquidity(depositRequest.poolId, depositRequest.routerAmount, address(this));
            _updateTokenInRegistry(underlyingToken);
        }
        if (depositRequest.LPStakingAmount > 0) {
            uint256 stakingAmount = depositRequest.LPStakingAmount;
            if (depositRequest.LPStakingAmount == type(uint256).max) {
                stakingAmount = IERC20(lpAddress).balanceOf(address(this));
            }
            _approveOperations(lpAddress, address(LPStaking), stakingAmount);
            LPStaking.deposit(depositRequest.poolId, stakingAmount);
        }
        _updateTokenInRegistry(rewardToken);
        bytes32 positionId =
            registry.calculatePositionId(address(this), STARGATE_LP_POSITION_TYPE, abi.encode(depositRequest.poolId));
        registry.updateHoldingPosition(vaultId, positionId, "", "", false);
    }

    function withdrawFromStargatePool(StargateRequest calldata withdrawRequest) external onlyManager {
        address lpAddress = LPStaking.poolInfo(withdrawRequest.poolId).lpToken;
        address underlyingToken = IStargatePool(lpAddress).token();
        if (withdrawRequest.LPStakingAmount > 0) {
            IStargateLPStaking(LPStaking).withdraw(withdrawRequest.poolId, withdrawRequest.LPStakingAmount);
        }
        if (withdrawRequest.routerAmount > 0) {
            stargateRouter.instantRedeemLocal(
                uint16(withdrawRequest.poolId), withdrawRequest.routerAmount, address(this)
            );
            _updateTokenInRegistry(underlyingToken);
        }
        uint256 LPAmount = LPStaking.userInfo(withdrawRequest.poolId, address(this)).amount;
        if (IERC20(lpAddress).balanceOf(address(this)) + LPAmount == 0) {
            bytes32 positionId = registry.calculatePositionId(
                address(this), STARGATE_LP_POSITION_TYPE, abi.encode(withdrawRequest.poolId)
            );
            registry.updateHoldingPosition(vaultId, positionId, "", "", true);
        }
        _updateTokenInRegistry(rewardToken);
    }

    function claimStargateRewards(uint256 poolId) external onlyManager {
        LPStaking.deposit(poolId, 0);
        _updateTokenInRegistry(rewardToken);
    }
    // ------------ TVL functions -------------- //

    function _getPositionTVL(HoldingPI memory p, address base) public view override returns (uint256 tvl) {
        PositionBP memory pBP = registry.getPositionBP(vaultId, p.positionId);
        uint256 poolId = abi.decode(pBP.data, (uint256));
        address lpAddress = LPStaking.poolInfo(poolId).lpToken;
        uint256 lpAmount = LPStaking.userInfo(poolId, address(this)).amount + IERC20(lpAddress).balanceOf(address(this));
        if (lpAmount == 0) {
            return 0;
        }
        address underlyingToken = IStargatePool(lpAddress).token();
        uint256 underlyingAmount = IStargatePool(lpAddress).amountLPtoLD(lpAmount);
        return _getValue(underlyingToken, base, underlyingAmount);
    }

    function _getUnderlyingTokens(uint256, bytes memory data) public view override returns (address[] memory) {
        uint256 poolId = abi.decode(data, (uint256));
        address lpAddress = LPStaking.poolInfo(poolId).lpToken;
        address[] memory tokens = new address[](1);
        tokens[0] = IStargatePool(lpAddress).token();
        return tokens;
    }
}
