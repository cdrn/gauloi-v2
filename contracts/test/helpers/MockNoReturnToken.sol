// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev USDT-style token: transfer/transferFrom/approve return NO data.
///      `try IERC20.transfer() returns (bool)` decode-fails on this token even
///      when the transfer succeeds — the exact bug TransferLib.tryTransfer fixes.
contract MockNoReturnToken {
    string public name;
    string public symbol;
    uint8 public decimals;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function transfer(address to, uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "MockNoReturnToken: insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        require(allowance[from][msg.sender] >= amount, "MockNoReturnToken: insufficient allowance");
        require(balanceOf[from] >= amount, "MockNoReturnToken: insufficient balance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}
