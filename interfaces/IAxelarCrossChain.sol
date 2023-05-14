// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IAxelarCrossChain {
    function validateAddress(string memory _chainName, bytes32 _address) external view returns (bool);
    function getAddress(string memory _chainName, bytes32 _address) external view returns (address);
    function transfer(address _to, uint256 _value, string memory _assetName, bytes32 _address) external returns (bool);
    function transferToChainAndDestination(address fromChain, address toChain, uint256 amount) external;
    function getAssetName(string memory _chainName) external view returns (string memory);
    function getChainId(string memory _chainName) external view returns (uint256);
    function getLockedValue(bytes32 _crossChainTxId) external view returns (uint256);
    function getCrossChainTxId(string memory _chainName, bytes32 _txId) external pure returns (bytes32);
    function getTxId(bytes32 _crossChainTxId) external pure returns (bytes32);
    function unlockValue(bytes32 _crossChainTxId) external returns (bool);
    function createLendingPoolOnTargetChain(address poolAddress, uint amount, uint interestRate, uint dueDate, uint repaymentSchedule) external;

}
