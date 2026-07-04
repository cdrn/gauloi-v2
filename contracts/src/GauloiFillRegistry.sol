// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IGauloiFillRegistry} from "./interfaces/IGauloiFillRegistry.sol";

/// @notice Destination-side fill registry. Makes fills canonical, unique, on-chain facts:
///         one fill per intent, one intent per fill. Deployed on every chain Gauloi
///         delivers to; makers route destination transfers through `fill()` instead of
///         bare ERC-20 transfers, so a fill's existence and parameters can be checked
///         (or storage-proven) against a single mapping slot.
///
///         Deliberately permissionless and admin-free: the registry records transfers,
///         it does not judge them. Whether a fill satisfies an order (token, recipient,
///         amount >= minOutputAmount) is checked by whoever resolves disputes on the
///         source chain, using the commitment preimage as evidence. The preimage travels
///         with the proof because `minOutputAmount` is an inequality — it cannot be
///         checked inside an opaque hash.
contract GauloiFillRegistry is IGauloiFillRegistry, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // intentId => keccak256(abi.encode(token, recipient, amount, filler, block.number))
    mapping(bytes32 => bytes32) internal _fills;

    function fill(
        bytes32 intentId,
        address token,
        address recipient,
        uint256 amount
    ) external nonReentrant {
        require(intentId != bytes32(0), "GauloiFillRegistry: zero intent id");
        require(token != address(0), "GauloiFillRegistry: zero token");
        require(recipient != address(0), "GauloiFillRegistry: zero recipient");
        require(amount > 0, "GauloiFillRegistry: zero amount");
        require(_fills[intentId] == bytes32(0), "GauloiFillRegistry: already filled");

        // Effects before interaction (CEI pattern)
        _fills[intentId] = computeFillCommitment(token, recipient, amount, msg.sender, block.number);

        emit Filled(intentId, token, recipient, amount, msg.sender);

        // Deliver to recipient — reject fee-on-transfer tokens, since the recorded
        // amount would otherwise overstate what the recipient actually received
        uint256 balBefore = IERC20(token).balanceOf(recipient);
        IERC20(token).safeTransferFrom(msg.sender, recipient, amount);
        require(
            IERC20(token).balanceOf(recipient) - balBefore == amount,
            "GauloiFillRegistry: fee-on-transfer token"
        );
    }

    // --- View functions ---

    function getFill(bytes32 intentId) external view returns (bytes32) {
        return _fills[intentId];
    }

    function isFilled(bytes32 intentId) external view returns (bool) {
        return _fills[intentId] != bytes32(0);
    }

    function computeFillCommitment(
        address token,
        address recipient,
        uint256 amount,
        address filler,
        uint256 blockNumber
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(token, recipient, amount, filler, blockNumber));
    }
}
