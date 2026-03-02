// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DataTypes} from "../types/DataTypes.sol";

library IntentLib {
    bytes32 internal constant ORDER_TYPEHASH = keccak256(
        "Order(address taker,address inputToken,uint256 inputAmount,address outputToken,uint256 minOutputAmount,uint256 destinationChainId,address destinationAddress,uint256 expiry,uint256 nonce)"
    );

    function computeIntentId(DataTypes.Order memory order) internal pure returns (bytes32) {
        return keccak256(abi.encode(
            order.taker,
            order.inputToken,
            order.inputAmount,
            order.outputToken,
            order.minOutputAmount,
            order.destinationChainId,
            order.destinationAddress,
            order.expiry,
            order.nonce
        ));
    }

    function hashOrder(DataTypes.Order memory order) internal pure returns (bytes32) {
        return keccak256(abi.encode(
            ORDER_TYPEHASH,
            order.taker,
            order.inputToken,
            order.inputAmount,
            order.outputToken,
            order.minOutputAmount,
            order.destinationChainId,
            order.destinationAddress,
            order.expiry,
            order.nonce
        ));
    }
}
