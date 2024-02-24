// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.20;

import { PositionRegistry, PositionBP } from "../accountingManager/Registry.sol";

contract NoyaGovernanceBase {
    PositionRegistry public registry;
    uint256 public vaultId;

    error NoyaGovernance_Unauthorized(address);

    constructor(PositionRegistry _registry, uint256 _vaultId) {
        registry = _registry;
        vaultId = _vaultId;
    }

    modifier onlyManager() {
        (,,, address keeperContract,, address emergencyManager) = registry.getGovernanceAddresses(vaultId);
        if (!(msg.sender == keeperContract || msg.sender == emergencyManager)) {
            revert NoyaGovernance_Unauthorized(msg.sender);
        }
        _;
    }

    modifier onlyEmergency() {
        (,,,,, address emergencyManager) = registry.getGovernanceAddresses(vaultId);
        if (msg.sender != emergencyManager) revert NoyaGovernance_Unauthorized(msg.sender);
        _;
    }

    modifier onlyEmergencyOrWatcher() {
        (,,,, address watcherContract, address emergencyManager) = registry.getGovernanceAddresses(vaultId);
        if (msg.sender != emergencyManager && msg.sender != watcherContract) {
            revert NoyaGovernance_Unauthorized(msg.sender);
        }
        _;
    }

    modifier onlyMaintainerOrEmergency() {
        (, address maintainer,,,, address emergencyManager) = registry.getGovernanceAddresses(vaultId);
        if (msg.sender != maintainer && msg.sender != emergencyManager) revert NoyaGovernance_Unauthorized(msg.sender);
        _;
    }

    modifier onlyMaintainer() {
        (, address maintainer,,,,) = registry.getGovernanceAddresses(vaultId);
        if (msg.sender != maintainer) revert NoyaGovernance_Unauthorized(msg.sender);
        _;
    }

    modifier onlyGovernance() {
        (address governer,,,,,) = registry.getGovernanceAddresses(vaultId);
        if (msg.sender != governer) revert NoyaGovernance_Unauthorized(msg.sender);
        _;
    }
}
