pragma solidity 0.8.20;

import { PositionRegistry, HoldingPI } from "../accountingManager/Registry.sol";
import { IConnector } from "../interface/IConnector.sol";

library TVLHelper {
    function getTVL(uint256 vaultId, PositionRegistry registry, address baseToken) public view returns (uint256) {
        uint256 totalTVL;
        uint256 totalDebt;
        HoldingPI[] memory positions = registry.getHoldingPositions(vaultId);
        for (uint256 i = 0; i < positions.length; i++) {
            if (positions[i].calculatorConnector == address(0)) {
                continue;
            }
            uint256 tvl = IConnector(positions[i].calculatorConnector).getPositionTVL(positions[i], baseToken);
            bool isPositionDebt = registry.isPositionDebt(vaultId, positions[i].positionId);
            if (isPositionDebt) {
                totalDebt += tvl;
            } else {
                totalTVL += tvl;
            }
        }
        if (totalTVL < totalDebt) {
            return 0;
        }
        return (totalTVL - totalDebt);
    }

    function getLatestUpdateTime(uint256 vaultId, PositionRegistry registry) public view returns (uint256) {
        uint256 latestUpdateTime;
        HoldingPI[] memory positions = registry.getHoldingPositions(vaultId);
        for (uint256 i = 0; i < positions.length; i++) {
            if (latestUpdateTime == 0 || positions[i].positionTimestamp < latestUpdateTime) {
                latestUpdateTime = positions[i].positionTimestamp;
            }
        }
        if (latestUpdateTime == 0) {
            latestUpdateTime = block.timestamp;
        }
        return latestUpdateTime;
    }
}
