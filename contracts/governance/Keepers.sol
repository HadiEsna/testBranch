pragma solidity 0.8.20;

import "@openzeppelin/contracts-5.0/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts-5.0/access/Ownable.sol";

contract Keepers is EIP712, Ownable {
    mapping(address => bool) public isOwner;
    bytes32 public constant TXTYPE_HASH = keccak256(
        "Execute(uint256 nonce,address destination,uint256 value,bytes data,uint256 gasLimit,address executor)"
    );
    uint256 public nonce;
    uint8 public threshold;
    uint256 public numOwners;

    constructor(address[] memory _owners, uint8 _threshold) EIP712("Keepers", "1") Ownable(msg.sender) {
        require(_owners.length <= 10 && _threshold <= _owners.length && _threshold != 0);
        for (uint256 i = 0; i < _owners.length; i++) {
            isOwner[_owners[i]] = true;
        }
        numOwners = _owners.length;
        threshold = _threshold;
    }

    function updateOwners(address[] memory _owners, bool[] memory addOrRemove) public onlyOwner {
        uint256 numOwnersTemp = numOwners;
        for (uint256 i = 0; i < _owners.length; i++) {
            if (addOrRemove[i] && !isOwner[_owners[i]]) {
                isOwner[_owners[i]] = true;
                numOwnersTemp++;
            } else if (!addOrRemove[i] && isOwner[_owners[i]]) {
                isOwner[_owners[i]] = false;
                numOwnersTemp--;
            }
        }
        require(numOwnersTemp <= 10 && threshold <= numOwnersTemp && threshold != 0);
        numOwners = numOwnersTemp;
    }

    function setThreshold(uint8 _threshold) public onlyOwner {
        require(_threshold <= numOwners && _threshold != 0);
        threshold = _threshold;
    }

    function execute(
        address destination,
        uint256 value,
        bytes calldata data,
        uint256 gasLimit,
        address executor,
        bytes32[] calldata sigR,
        bytes32[] calldata sigS,
        uint8[] calldata sigV
    ) public {
        require(isOwner[msg.sender]);
        require(sigR.length == threshold);
        require(sigR.length == sigS.length && sigR.length == sigV.length);
        {
            bytes32 txInputHash = keccak256(abi.encode(destination, value, data, gasLimit, executor));
            bytes32 totalHash = keccak256(abi.encodePacked("\x19\x01", _domainSeparatorV4(), txInputHash));
            address lastAdd = address(0);
            for (uint256 i = 0; i < threshold; i++) {
                address recovered = ecrecover(totalHash, sigV[i], sigR[i], sigS[i]);
                require(recovered > lastAdd && isOwner[recovered]);
                lastAdd = recovered;
            }

            nonce++;
        }
        (bool success,) = destination.call{ value: value, gas: gasLimit }(data);
        require(success, "Transaction execution reverted.");
    }
}
