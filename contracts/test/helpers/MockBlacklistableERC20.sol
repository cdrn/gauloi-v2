// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev ERC20 that reverts transfers to/from blacklisted addresses (like USDC Centre blacklist)
contract MockBlacklistableERC20 is ERC20 {
    uint8 private _decimals;
    mapping(address => bool) public blacklisted;

    constructor(string memory name, string memory symbol, uint8 decimals_) ERC20(name, symbol) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function blacklist(address account) external {
        blacklisted[account] = true;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        require(!blacklisted[to], "MockBlacklistableERC20: recipient blacklisted");
        require(!blacklisted[msg.sender], "MockBlacklistableERC20: sender blacklisted");
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        require(!blacklisted[to], "MockBlacklistableERC20: recipient blacklisted");
        require(!blacklisted[from], "MockBlacklistableERC20: sender blacklisted");
        return super.transferFrom(from, to, amount);
    }
}
