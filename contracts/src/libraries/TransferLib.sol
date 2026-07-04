// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

library TransferLib {
    /// @dev Attempt an ERC-20 transfer without letting a reverting or misbehaving
    ///      token block the caller (e.g. a USDC-blacklisted recipient DoS-ing
    ///      settlement). Returns true iff the transfer actually succeeded.
    ///
    ///      Unlike `try IERC20.transfer() returns (bool)`, this tolerates
    ///      no-return-data tokens (USDT): a successful call with empty return data
    ///      counts as success rather than falling into a catch block.
    function tryTransfer(IERC20 token, address to, uint256 amount) internal returns (bool) {
        if (address(token).code.length == 0) return false;
        (bool success, bytes memory data) = address(token).call(
            abi.encodeCall(IERC20.transfer, (to, amount))
        );
        return success && (data.length == 0 || (data.length >= 32 && abi.decode(data, (bool))));
    }
}
