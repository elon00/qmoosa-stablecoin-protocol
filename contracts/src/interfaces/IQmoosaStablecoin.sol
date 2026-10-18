// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IERC20.sol";

interface IQmoosaStablecoin is IERC20 {
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
    function addMinter(address minter) external;
    function removeMinter(address minter) external;
    function isMinter(address account) external view returns (bool);
}
