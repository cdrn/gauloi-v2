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

    // keccak256(intentId, filler) => keccak256(abi.encode(token, recipient, amount, filler, block.number))
    //
    // Keyed by (intentId, filler), not intentId alone. A fill is a claim by a
    // specific filler; the slot must belong to the filler who made it. Otherwise
    // anyone could front-run the committed maker's destination fill with a dust
    // transfer and permanently occupy the intent's only slot — a cheap DoS
    // against makers. The resolver looks up the committed maker's slot
    // specifically, so a squatter's slot is simply ignored.
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

        bytes32 slot = _slot(intentId, msg.sender);
        require(_fills[slot] == bytes32(0), "GauloiFillRegistry: already filled");

        // Effects before interaction (CEI pattern)
        _fills[slot] = computeFillCommitment(token, recipient, amount, msg.sender, block.number);

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

    function getFill(bytes32 intentId, address filler) external view returns (bytes32) {
        return _fills[_slot(intentId, filler)];
    }

    function isFilled(bytes32 intentId, address filler) external view returns (bool) {
        return _fills[_slot(intentId, filler)] != bytes32(0);
    }

    function _slot(bytes32 intentId, address filler) internal pure returns (bytes32) {
        return keccak256(abi.encode(intentId, filler));
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
