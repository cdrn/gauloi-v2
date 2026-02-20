// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library IntentLib {
    function computeIntentId(
        address taker,
        address inputToken,
        uint256 inputAmount,
        address outputToken,
        uint256 minOutputAmount,
        uint256 destinationChainId,
        address destinationAddress,
        uint256 expiry,
        uint256 nonce
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(
            taker,
            inputToken,
            inputAmount,
            outputToken,
            minOutputAmount,
            destinationChainId,
            destinationAddress,
            expiry,
            nonce
        ));
    }
}
