// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev ERC20 that takes a 1% fee on every transfer/transferFrom (delivers less to recipient)
contract MockFeeOnTransferToken is ERC20 {
    uint8 private _decimals;
    uint256 public constant FEE_BPS = 100; // 1%

    constructor(string memory name, string memory symbol, uint8 decimals_) ERC20(name, symbol) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        uint256 fee = (amount * FEE_BPS) / 10_000;
        _burn(msg.sender, fee);
        _transfer(msg.sender, to, amount - fee);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        uint256 fee = (amount * FEE_BPS) / 10_000;
        _burn(from, fee);
        _transfer(from, to, amount - fee);
        return true;
    }
}
