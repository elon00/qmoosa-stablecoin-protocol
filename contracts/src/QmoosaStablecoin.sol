// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IQmoosaStablecoin.sol";

contract QmoosaStablecoin is IQmoosaStablecoin {
    string public constant name = "QMOOSA USD Stablecoin";
    string public constant symbol = "QUSD";
    uint8 public constant decimals = 18;

    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    address public owner;
    mapping(address => bool) private _minters;

    modifier onlyOwner() {
        require(msg.sender == owner, "QUSD: ONLY_OWNER");
        _;
    }

    modifier onlyMinter() {
        require(_minters[msg.sender], "QUSD: ONLY_MINTER");
        _;
    }

    constructor() {
        owner = msg.sender;
        _minters[msg.sender] = true;
    }

    function totalSupply() external view override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view override returns (uint256) {
        return _balances[account];
    }

    function transfer(address recipient, uint256 amount) external override returns (bool) {
        _transfer(msg.sender, recipient, amount);
        return true;
    }

    function allowance(address tokenOwner, address spender) external view override returns (uint256) {
        return _allowances[tokenOwner][spender];
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) external override returns (bool) {
        uint256 currentAllowance = _allowances[sender][msg.sender];
        require(currentAllowance >= amount, "QUSD: TRANSFER_AMOUNT_EXCEEDS_ALLOWANCE");
        unchecked {
            _approve(sender, msg.sender, currentAllowance - amount);
        }
        _transfer(sender, recipient, amount);
        return true;
    }

    function mint(address to, uint256 amount) external override onlyMinter {
        require(to != address(0), "QUSD: MINT_TO_ZERO_ADDRESS");
        _totalSupply += amount;
        _balances[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function burn(address from, uint256 amount) external override onlyMinter {
        require(from != address(0), "QUSD: BURN_FROM_ZERO_ADDRESS");
        require(_balances[from] >= amount, "QUSD: BURN_AMOUNT_EXCEEDS_BALANCE");
        unchecked {
            _balances[from] -= amount;
            _totalSupply -= amount;
        }
        emit Transfer(from, address(0), amount);
    }

    function addMinter(address minter) external override onlyOwner {
        require(minter != address(0), "QUSD: ZERO_ADDRESS");
        _minters[minter] = true;
    }

    function removeMinter(address minter) external override onlyOwner {
        _minters[minter] = false;
    }

    function isMinter(address account) external view override returns (bool) {
        return _minters[account];
    }

    function _transfer(address sender, address recipient, uint256 amount) internal {
        require(sender != address(0), "QUSD: TRANSFER_FROM_ZERO_ADDRESS");
        require(recipient != address(0), "QUSD: TRANSFER_TO_ZERO_ADDRESS");
        require(_balances[sender] >= amount, "QUSD: TRANSFER_AMOUNT_EXCEEDS_BALANCE");

        unchecked {
            _balances[sender] -= amount;
            _balances[recipient] += amount;
        }
        emit Transfer(sender, recipient, amount);
    }

    function _approve(address tokenOwner, address spender, uint256 amount) internal {
        require(tokenOwner != address(0), "QUSD: APPROVE_FROM_ZERO_ADDRESS");
        require(spender != address(0), "QUSD: APPROVE_TO_ZERO_ADDRESS");

        _allowances[tokenOwner][spender] = amount;
        emit Approval(tokenOwner, spender, amount);
    }
}
