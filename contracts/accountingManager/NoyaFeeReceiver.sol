// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { AccountingManager } from "./AccountingManager.sol";
import "@openzeppelin/contracts-5.0/access/Ownable.sol";

contract NoyaManagementFeeReceiver is Ownable {
    address public receiver;
    address public accountingManager;
    address public baseToken;

    event ManagementFeeReceived(address indexed token, uint256 amount);

    constructor(address _accountingManager, address _baseToken, address _receiver) Ownable(msg.sender) {
        accountingManager = _accountingManager;
        baseToken = _baseToken;
        receiver = _receiver;
    }

    function withdrawShares(uint256 amount) external onlyOwner {
        AccountingManager(accountingManager).withdraw(amount, receiver);
    }

    function burnShares(uint256 amount) external onlyOwner {
        AccountingManager(accountingManager).burnShares(amount);
    }
}
