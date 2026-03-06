// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "./MockERC20.sol";
import {MockPriceFeed} from "./MockPriceFeed.sol";
import {GauloiStaking} from "../../src/GauloiStaking.sol";
import {GauloiEscrow} from "../../src/GauloiEscrow.sol";
import {DataTypes} from "../../src/types/DataTypes.sol";
import {IntentLib} from "../../src/libraries/IntentLib.sol";
import {SignatureLib} from "../../src/libraries/SignatureLib.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

abstract contract BaseTest is Test {
    MockERC20 public usdc;
    MockPriceFeed public priceFeed;
    GauloiStaking public staking;
    GauloiEscrow public escrow;

    address public owner = makeAddr("owner");
    address public maker1 = makeAddr("maker1");
    address public maker2 = makeAddr("maker2");
    address public maker3 = makeAddr("maker3");

    // Taker with private key for signing
    uint256 public takerKey = 0x7A4E5;
    address public taker;

    uint256 public constant MIN_STAKE = 10_000e6; // 10,000 USDC
    uint256 public constant COOLDOWN = 48 hours;
    uint256 public constant SETTLEMENT_WINDOW = 15 minutes;
    uint256 public constant COMMITMENT_TIMEOUT = 5 minutes;

    // Destination chain params (simulated Arbitrum)
    uint256 public constant DEST_CHAIN_ID = 42161;
    address public constant DEST_ADDRESS = address(0xBEEF);

    // Default nonce counter for test order creation
    uint256 internal _testNonce;

    function _deployBase() internal {
        taker = vm.addr(takerKey);

        usdc = new MockERC20("USD Coin", "USDC", 6);
        priceFeed = new MockPriceFeed(1e8, 8); // USDC at $1.00, 8 decimals
        staking = new GauloiStaking(
            address(usdc),
            MIN_STAKE,
            COOLDOWN,
            1 hours,
            owner
        );

        // Set oracle on staking
        vm.prank(owner);
        staking.setPriceFeed(address(priceFeed));

        // Fund makers and taker
        usdc.mint(maker1, 1_000_000e6);
        usdc.mint(maker2, 1_000_000e6);
        usdc.mint(maker3, 1_000_000e6);
        usdc.mint(taker, 1_000_000e6);
    }

    function _deployEscrow() internal {
        escrow = new GauloiEscrow(
            address(staking),
            SETTLEMENT_WINDOW,
            COMMITMENT_TIMEOUT,
            owner
        );

        vm.startPrank(owner);
        staking.setEscrow(address(escrow));
        escrow.addSupportedToken(address(usdc));
        vm.stopPrank();

        // Approve escrow to pull from taker
        vm.prank(taker);
        usdc.approve(address(escrow), type(uint256).max);
    }

    function _stakeMaker(address maker, uint256 amount) internal {
        vm.startPrank(maker);
        usdc.approve(address(staking), amount);
        staking.stake(amount);
        vm.stopPrank();
    }

    function _makeOrder(uint256 inputAmount, uint256 minOutput) internal returns (DataTypes.Order memory) {
        return DataTypes.Order({
            taker: taker,
            inputToken: address(usdc),
            inputAmount: inputAmount,
            outputToken: address(usdc),
            minOutputAmount: minOutput,
            destinationChainId: DEST_CHAIN_ID,
            destinationAddress: DEST_ADDRESS,
            expiry: block.timestamp + 1 hours,
            nonce: _testNonce++
        });
    }

    function _signOrder(uint256 privateKey, DataTypes.Order memory order) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(abi.encode(
            IntentLib.ORDER_TYPEHASH,
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
        bytes32 digest = MessageHashUtils.toTypedDataHash(
            escrow.domainSeparator(), structHash
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _executeOrder(
        DataTypes.Order memory order,
        bytes memory sig,
        address maker
    ) internal returns (bytes32) {
        vm.prank(maker);
        return escrow.executeOrder(order, sig);
    }

    function _createAndExecuteOrder(uint256 inputAmount, uint256 minOutput, address maker) internal returns (bytes32, DataTypes.Order memory) {
        DataTypes.Order memory order = _makeOrder(inputAmount, minOutput);
        bytes memory sig = _signOrder(takerKey, order);
        bytes32 intentId = _executeOrder(order, sig, maker);
        return (intentId, order);
    }
}
