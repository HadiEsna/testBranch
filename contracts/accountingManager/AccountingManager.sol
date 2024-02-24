// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts-5.0/utils/ReentrancyGuard.sol";
import { ERC4626, ERC20 } from "@openzeppelin/contracts-5.0/token/ERC20/extensions/ERC4626.sol";
import "../interface/Accounting/IAccountingManager.sol";
import { NoyaGovernanceBase, PositionBP } from "../governance/NoyaGovernanceBase.sol";
import "../helpers/TVLHelper.sol";

/*
* @title AccountingManager
* @notice AccountingManager is a contract that handles the accounting of the vault
* @notice It is also responsible for managing deposits and withdraws
* @notice It is also responsible for holding the shares of the users
**/
contract AccountingManager is IAccountingManager, ERC4626, ReentrancyGuard, Pausable, NoyaGovernanceBase {
    using SafeERC20 for IERC20;

    // ------------ state variable -------------- //
    /// @notice depositQueue is a struct that holds the deposit queue
    DepositQueue public depositQueue;
    /// @notice withdrawQueue is a struct that holds the withdraw queue
    WithdrawQueue public withdrawQueue;

    /// @notice withdrawRequestsByAddress is a mapping that holds the withdraw requests of the users
    /// @dev withdrawRequestsByAddress is used to prevent users from withdrawing or transferring more than their shares, while their withdraw request are waiting for execution
    mapping(address => uint256) public withdrawRequestsByAddress;
    uint256 public amountAskedForWithdraw;

    uint256 public totalDepositedAmount;
    uint256 public totalWithdrawnAmount;
    uint256 public storedProfitForFee;
    uint256 public profitStoredTime;
    uint256 public lastFeeDistributionTime;
    uint256 public totalProfitCalculated;
    uint256 public preformanceFeeSharesWaitingForDistribution;

    uint256 public constant FEE_PRECISION = 1e6;

    IERC20 public baseToken;

    uint256 public withdrawFee; // 0.0001% = 1
    uint256 public performanceFee;
    uint256 public managementFee;

    address public withdrawFeeReceiver;
    address public performanceFeeReceiver;
    address public managementFeeReceiver;

    WithdrawGroup public currentWithdrawGroup;

    uint256 public depositWaitingTime = 30 minutes;
    uint256 public withdrawWaitingTime = 6 hours;

    uint256 public depositLimitTotalAmount = 1e6 * 200_000;
    uint256 public depositLimitPerTransaction = 1e6 * 2000;

    INoyaValueOracle public valueOracle;

    constructor(
        string memory _name,
        string memory _symbol,
        address _baseTokenAddress,
        PositionRegistry _registry,
        address _valueOracle,
        uint256 _vaultId
    ) ERC4626(IERC20(_baseTokenAddress)) ERC20(_name, _symbol) NoyaGovernanceBase(_registry, _vaultId) {
        baseToken = IERC20(_baseTokenAddress);
        valueOracle = INoyaValueOracle(_valueOracle);
        withdrawFeeReceiver = msg.sender;
        performanceFeeReceiver = msg.sender;
        managementFeeReceiver = msg.sender;
    }

    function updateValueOracle(INoyaValueOracle _valueOracle) public onlyMaintainer {
        valueOracle = _valueOracle;
        emit ValueOracleUpdated(address(_valueOracle));
    }

    function setFeeReceivers(
        address _withdrawFeeReceiver,
        address _performanceFeeReceiver,
        address _managementFeeReceiver
    ) public onlyMaintainer {
        withdrawFeeReceiver = _withdrawFeeReceiver;
        performanceFeeReceiver = _performanceFeeReceiver;
        managementFeeReceiver = _managementFeeReceiver;
        emit FeeRecepientsChanged(_withdrawFeeReceiver, _performanceFeeReceiver, _managementFeeReceiver);
    }

    function sendTokensToTrustedAddress(address token, uint256 amount, address caller, bytes calldata data)
        external
        returns (uint256)
    {
        if (registry.isAnActiveConnector(vaultId, msg.sender)) {
            IERC20(token).safeTransfer(address(msg.sender), amount);
            return amount;
        }
        return 0;
    }

    function setFees(uint256 _withdrawFee, uint256 _performanceFee, uint256 _managementFee) public onlyMaintainer {
        withdrawFee = _withdrawFee;
        performanceFee = _performanceFee;
        managementFee = _managementFee;
        emit FeeRatesChanged(_withdrawFee, _performanceFee, _managementFee);
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (!(from == address(0)) && balanceOf(from) < amount + withdrawRequestsByAddress[from]) {
            revert NoyaAccounting_INSUFFICIENT_FUNDS(balanceOf(from), amount, withdrawRequestsByAddress[from]);
        }
        super._update(from, to, amount);
    }

    /*
    * @notice users can deposit base token to the vault using this function
    * @param receiver is the last index of the withdraw queue that is waiting for execution
    * @param amount is the total amount of the base token that is waiting for execution
    * @param referrer is the total amount of the base token that is available for withdraw
    * @dev if isStarted is true and isFullfilled is false, it means that the withdraw group is active
    * @dev if isStarted is false and isFullfilled is false, it means that there is no active withdraw group
    * @dev if isStarted is true and isFullfilled is true, it means that the withdraw group is fullfilled and but there are still some withdraws that are waiting for execution
    * @dev users of the withdraw group will bear the gas cost of the withdraw
    **/
    function deposit(address receiver, uint256 amount, address referrer) public nonReentrant whenNotPaused {
        if (amount == 0) {
            revert NoyaAccounting_INVALID_AMOUNT();
        }

        baseToken.safeTransferFrom(msg.sender, address(this), amount);

        if (amount > depositLimitPerTransaction) {
            revert NoyaAccounting_DepositLimitPerTransactionExceeded();
        }

        if (TVL() + amount > depositLimitTotalAmount) {
            revert NoyaAccounting_TotalDepositLimitExceeded();
        }

        depositQueue.queue[depositQueue.last] = DepositRequest(receiver, block.timestamp, 0, amount, 0);
        emit RecordDeposit(depositQueue.last, receiver, amount, block.timestamp, referrer);
        depositQueue.last += 1;
        depositQueue.totalAWFDeposit += amount;
    }

    /*
    * @notice calculateDepositShares is a function that calculates the shares of the deposits that are waiting for calculation
    * @param maxIterations is the maximum number of iterations that the function can do
    * @dev this function is used to calculate the users desposit shares that has been deposited before the oldest update time of the vault
    */
    function calculateDepositShares(uint256 maxIterations) public onlyManager nonReentrant whenNotPaused {
        uint256 middleTemp = depositQueue.middle;
        uint64 i = 0;

        uint256 oldestUpdateTime = TVLHelper.getLatestUpdateTime(vaultId, registry);

        while (
            depositQueue.last > middleTemp && depositQueue.queue[middleTemp].recordTime <= oldestUpdateTime
                && i < maxIterations
        ) {
            i += 1;
            DepositRequest storage data = depositQueue.queue[middleTemp];

            uint256 shares = previewDeposit(data.amount);
            data.shares = shares;
            data.calculationTime = block.timestamp;
            emit CalculateDeposit(
                middleTemp, data.receiver, block.timestamp, shares, data.amount, shares * 1e18 / data.amount
            );

            middleTemp += 1;
        }

        depositQueue.middle = middleTemp;
    }

    function executeDeposit(uint256 maxI, address connector, bytes memory addLPdata) public onlyManager whenNotPaused {
        uint256 firstTemp = depositQueue.first;
        uint64 i = 0;
        uint256 processedBaseTokenAmount = 0;

        while (
            depositQueue.middle > firstTemp
                && depositQueue.queue[firstTemp].calculationTime + depositWaitingTime <= block.timestamp && i < maxI
        ) {
            i += 1;
            DepositRequest memory data = depositQueue.queue[firstTemp];

            emit ExecuteDeposit(
                firstTemp, data.receiver, block.timestamp, data.shares, data.amount, data.shares * 1e18 / data.amount
            );
            // minting shares for receiver address
            _mint(data.receiver, data.shares);

            processedBaseTokenAmount += data.amount;
            delete depositQueue.queue[firstTemp];
            firstTemp += 1;
        }
        depositQueue.totalAWFDeposit -= processedBaseTokenAmount;

        if (registry.isAnActiveConnector(vaultId, connector) && processedBaseTokenAmount > 0) {
            uint256[] memory amounts = new uint256[](1);
            amounts[0] = processedBaseTokenAmount;
            address[] memory tokens = new address[](1);
            tokens[0] = address(baseToken);
            IConnector(connector).addLiquidity(tokens, amounts, addLPdata);
        }

        depositQueue.first = firstTemp;
    }

    function withdraw(uint256 share, address receiver) public nonReentrant whenNotPaused {
        if (balanceOf(msg.sender) < share + withdrawRequestsByAddress[msg.sender]) {
            revert NoyaAccounting_INSUFFICIENT_FUNDS(
                balanceOf(msg.sender), share, withdrawRequestsByAddress[msg.sender]
            );
        }
        withdrawRequestsByAddress[msg.sender] += share;
        withdrawQueue.queue[withdrawQueue.last] = WithdrawRequest(msg.sender, receiver, block.timestamp, 0, share, 0);
        emit RecordWithdraw(withdrawQueue.last, msg.sender, receiver, share, block.timestamp);
        withdrawQueue.last += 1;
    }

    function calculateWithdrawShares(uint256 maxIterations) public onlyManager nonReentrant whenNotPaused {
        uint256 middleTemp = withdrawQueue.middle;
        uint64 i = 0;
        uint256 processedShares = 0;
        uint256 assetsNeededForWithdraw = 0;
        uint256 oldestUpdateTime = TVLHelper.getLatestUpdateTime(vaultId, registry);

        if (currentWithdrawGroup.isFullfilled == false && currentWithdrawGroup.isStarted == true) {
            revert NoyaAccounting_ThereIsAnActiveWithdrawGroup();
        }
        while (
            withdrawQueue.last > middleTemp && withdrawQueue.queue[middleTemp].recordTime <= oldestUpdateTime
                && i < maxIterations
        ) {
            i += 1;
            WithdrawRequest storage data = withdrawQueue.queue[middleTemp];
            uint256 assets = previewRedeem(data.shares);
            data.amount = assets;
            data.calculationTime = block.timestamp;
            assetsNeededForWithdraw += assets;
            processedShares += data.shares;
            emit CalculateWithdraw(middleTemp, data.owner, data.receiver, data.shares, assets, block.timestamp);

            middleTemp += 1;
        }
        if (
            (currentWithdrawGroup.isStarted == true && currentWithdrawGroup.isFullfilled == true)
                || (currentWithdrawGroup.lastId == 0)
        ) {
            currentWithdrawGroup.lastId = middleTemp;
        } else {
            currentWithdrawGroup.lastId = middleTemp;
        }
        currentWithdrawGroup.totalCBAmount += assetsNeededForWithdraw;
        withdrawQueue.middle = middleTemp;
    }

    function startCurrentWithdrawGroup() public onlyManager nonReentrant whenNotPaused {
        require(currentWithdrawGroup.isStarted == false && currentWithdrawGroup.isFullfilled == false);
        currentWithdrawGroup.isStarted = true;
    }

    function fulfillCurrentWithdrawGroup() public onlyManager nonReentrant whenNotPaused {
        require(currentWithdrawGroup.isStarted == true && currentWithdrawGroup.isFullfilled == false);
        currentWithdrawGroup.isFullfilled = true;
        uint256 neededAssets = neededAssetsForWithdraw();

        if (neededAssets != 0 && amountAskedForWithdraw != currentWithdrawGroup.totalCBAmount) {
            revert NoyaAccounting_NOT_READY_TO_FULFILL();
        }
        amountAskedForWithdraw = 0;
        uint256 availableAssets = baseToken.balanceOf(address(this)) - depositQueue.totalAWFDeposit;
        if (availableAssets >= currentWithdrawGroup.totalCBAmount) {
            currentWithdrawGroup.totalABAmount = currentWithdrawGroup.totalCBAmount;
        } else {
            currentWithdrawGroup.totalABAmount = availableAssets;
        }
    }

    function executeWithdraw(uint256 maxIterations) public onlyManager nonReentrant whenNotPaused {
        if (currentWithdrawGroup.isFullfilled == false) {
            revert NoyaAccounting_ThereIsAnActiveWithdrawGroup();
        }
        uint64 i = 0;
        uint256 firstTemp = withdrawQueue.first;

        uint256 withdrawFeeAmount = 0;
        uint256 processedBaseTokenAmount = 0;
        while (
            currentWithdrawGroup.lastId > firstTemp
                && withdrawQueue.queue[firstTemp].calculationTime + withdrawWaitingTime <= block.timestamp
                && i < maxIterations
        ) {
            i += 1;
            WithdrawRequest memory data = withdrawQueue.queue[firstTemp];
            uint256 shares = data.shares;
            uint256 baseTokenAmount =
                data.amount * currentWithdrawGroup.totalABAmount / currentWithdrawGroup.totalCBAmount;

            withdrawRequestsByAddress[data.owner] -= shares;
            _burn(data.owner, shares);

            processedBaseTokenAmount += data.amount;
            {
                uint256 feeAmount = baseTokenAmount * withdrawFee / FEE_PRECISION;
                withdrawFeeAmount += feeAmount;
                baseTokenAmount = baseTokenAmount - feeAmount;
            }

            baseToken.safeTransfer(data.receiver, baseTokenAmount);
            emit ExecuteWithdraw(
                firstTemp, data.owner, data.receiver, shares, data.amount, baseTokenAmount, block.timestamp
            );
            delete withdrawQueue.queue[firstTemp];
            firstTemp += 1;
        }
        totalWithdrawnAmount += processedBaseTokenAmount;

        if (withdrawFeeAmount > 0) {
            baseToken.safeTransfer(withdrawFeeReceiver, withdrawFeeAmount);
        }

        withdrawQueue.first = firstTemp;
        if (currentWithdrawGroup.lastId == firstTemp) {
            delete currentWithdrawGroup;
        }
    }

    function resetMiddle(uint256 newMiddle, bool depositOrWithdraw) public onlyManager {
        if (depositOrWithdraw) {
            if (newMiddle > depositQueue.middle || newMiddle < depositQueue.first) {
                revert NoyaAccounting_INVALID_AMOUNT();
            }
            depositQueue.middle = newMiddle;
        } else {
            if (newMiddle > withdrawQueue.middle || newMiddle < withdrawQueue.first || currentWithdrawGroup.isStarted) {
                revert NoyaAccounting_INVALID_AMOUNT();
            }
            withdrawQueue.middle = newMiddle;
        }
    }

    // ------------ fee functions -------------- //
    function recordTVLForFee() public onlyManager {
        if (preformanceFeeSharesWaitingForDistribution > 0) {
            _burn(address(this), preformanceFeeSharesWaitingForDistribution);
            preformanceFeeSharesWaitingForDistribution = 0;
        }
        storedProfitForFee = getProfit();
        profitStoredTime = block.timestamp;

        if (storedProfitForFee < totalProfitCalculated) {
            return;
        }

        _mint(
            performanceFeeReceiver,
            previewDeposit(((storedProfitForFee - totalProfitCalculated) * performanceFee) / FEE_PRECISION)
        );
    }

    function checkIfTVLHasDroped() public {
        if (getProfit() < storedProfitForFee) {
            _burn(address(this), preformanceFeeSharesWaitingForDistribution);
            preformanceFeeSharesWaitingForDistribution = 0;
            profitStoredTime = 0;
        }
    }

    function collectManagementFees() public onlyManager {
        if (block.timestamp - lastFeeDistributionTime < 1 days) {
            return;
        }
        uint256 timePassed = block.timestamp - lastFeeDistributionTime;
        uint256 totalShares = totalSupply();
        uint256 currentFeeShares = balanceOf(managementFeeReceiver);

        uint256 managementFeeAmount =
            (timePassed * managementFee * (totalShares - currentFeeShares)) / FEE_PRECISION / 365 days;
        _mint(managementFeeReceiver, managementFeeAmount);
    }

    function collectPerformanceFees() public onlyManager {
        if (block.timestamp - profitStoredTime < 12 hours && block.timestamp - profitStoredTime > 48 hours) {
            return;
        }

        _transfer(address(this), performanceFeeReceiver, preformanceFeeSharesWaitingForDistribution);
    }

    function burnShares(uint256 amount) public {
        _burn(msg.sender, amount);
    }

    function retrieveTokensForWithdraw(RetrieveData[] calldata retrieveData) public onlyManager {
        uint256 amountAskedForWithdraw_temp = 0;
        uint256 neededAssets = neededAssetsForWithdraw();
        for (uint256 i = 0; i < retrieveData.length; i++) {
            if (!registry.isAnActiveConnector(vaultId, retrieveData[i].connectorAddress)) {
                continue;
            }
            uint256 balanceBefore = baseToken.balanceOf(address(this));
            uint256 amount = IConnector(retrieveData[i].connectorAddress).sendTokensToTrustedAddress(
                address(baseToken), retrieveData[i].withdrawAmount, address(this), retrieveData[i].data
            );
            uint256 balanceAfter = baseToken.balanceOf(address(this));
            if (balanceBefore + amount > balanceAfter) revert NoyaAccounting_banalceAfterIsNotEnough();
            amountAskedForWithdraw_temp += retrieveData[i].withdrawAmount;
        }
        amountAskedForWithdraw += amountAskedForWithdraw_temp;
        if (amountAskedForWithdraw_temp > neededAssets) {
            revert NoyaAccounting_INVALID_AMOUNT();
        }
    }

    // ------------ view functions -------------- //

    function getProfit() public view returns (uint256) {
        uint256 tvl = TVL();
        if (tvl + totalWithdrawnAmount > totalDepositedAmount) {
            return tvl + totalWithdrawnAmount - totalDepositedAmount;
        }
        return 0;
    }

    function totalAssets() public view override returns (uint256) {
        return TVL();
    }

    function getQueueItems(bool depositOrWithdraw, uint256[] memory items)
        public
        view
        returns (DepositRequest[] memory depositData, WithdrawRequest[] memory withdrawData)
    {
        if (depositOrWithdraw) {
            depositData = new DepositRequest[](items.length);
            for (uint256 i = 0; i < items.length; i++) {
                depositData[i] = depositQueue.queue[items[i]];
            }
        } else {
            withdrawData = new WithdrawRequest[](items.length);
            for (uint256 i = 0; i < items.length; i++) {
                withdrawData[i] = withdrawQueue.queue[items[i]];
            }
        }
        return (depositData, withdrawData);
    }

    function neededAssetsForWithdraw() public view returns (uint256) {
        uint256 availableAssets = baseToken.balanceOf(address(this)) - depositQueue.totalAWFDeposit;
        if (
            currentWithdrawGroup.isStarted == false || currentWithdrawGroup.isFullfilled == true
                || availableAssets >= currentWithdrawGroup.totalCBAmount
        ) {
            return 0;
        }
        return currentWithdrawGroup.totalCBAmount - availableAssets;
    }

    function TVL() public view returns (uint256) {
        return TVLHelper.getTVL(vaultId, registry, address(baseToken)) + baseToken.balanceOf(address(this))
            - depositQueue.totalAWFDeposit;
    }

    function getPositionTVL(HoldingPI memory position, address base) public view returns (uint256) {
        PositionBP memory p = registry.getPositionBP(vaultId, position.positionId);
        if (p.positionTypeId == 0) {
            address token = abi.decode(p.data, (address));
            uint256 amount = IERC20(token).balanceOf(abi.decode(position.data, (address)));
            return _getValue(token, base, amount);
        }
        return 0;
    }

    function _getValue(address token, address base, uint256 amount) internal view returns (uint256) {
        if (token == base) {
            return amount;
        }
        return valueOracle.getValue(token, base, amount);
    }

    function getUnderlyingTokens(uint256 positionTypeId, bytes memory data) public view returns (address[] memory) {
        if (positionTypeId == 0) {
            address[] memory tokens = new address[](1);
            tokens[0] = abi.decode(data, (address));
            return tokens;
        }
        return new address[](0);
    }

    // ------------ Config functions -------------- //
    function emergencyStop() public whenNotPaused onlyEmergency {
        _pause();
    }

    function unpause() public whenPaused onlyEmergency {
        _unpause();
    }

    function setDepositLimits(uint256 _depositLimitPerTransaction, uint256 _depositTotalAmount) public onlyMaintainer {
        depositLimitPerTransaction = _depositLimitPerTransaction;
        depositLimitTotalAmount = _depositTotalAmount;
        emit SetDepositLimits(_depositLimitPerTransaction, _depositTotalAmount);
    }

    function changeDepositWaitingTime(uint256 _depositWaitingTime) public onlyMaintainer {
        depositWaitingTime = _depositWaitingTime;
        emit SetDepositWaitingTime(_depositWaitingTime);
    }

    function changeWithdrawWaitingTime(uint256 _withdrawWaitingTime) public onlyMaintainer {
        withdrawWaitingTime = _withdrawWaitingTime;
        emit SetWithdrawWaitingTime(_withdrawWaitingTime);
    }

    function rescue(address token, uint256 amount) public onlyEmergency {
        if (token == address(0)) {
            payable(msg.sender).transfer(amount);
        } else {
            IERC20(token).safeTransfer(msg.sender, amount);
        }
    }
}
