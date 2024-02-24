// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

interface INoyaValueOracle {
    function getValue(address asset, address baseCurrency, uint256 amount) external view returns (uint256);
}
