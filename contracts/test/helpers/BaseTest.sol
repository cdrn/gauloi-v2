// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "./MockERC20.sol";
import {GauloiStaking} from "../../src/GauloiStaking.sol";
import {GauloiEscrow} from "../../src/GauloiEscrow.sol";
import {DataTypes} from "../../src/types/DataTypes.sol";

abstract contract BaseTest is Test {
    MockERC20 public usdc;
    GauloiStaking public staking;
    GauloiEscrow public escrow;

    address public owner = makeAddr("owner");
    address public maker1 = makeAddr("maker1");
    address public maker2 = makeAddr("maker2");
    address public maker3 = makeAddr("maker3");
    address public taker = makeAddr("taker");

    uint256 public constant MIN_STAKE = 10_000e6; // 10,000 USDC
    uint256 public constant COOLDOWN = 48 hours;
    uint256 public constant SETTLEMENT_WINDOW = 15 minutes;
    uint256 public constant COMMITMENT_TIMEOUT = 5 minutes;

    // Destination chain params (simulated Arbitrum)
    uint256 public constant DEST_CHAIN_ID = 42161;
    address public constant DEST_ADDRESS = address(0xBEEF);

    function _deployBase() internal {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        staking = new GauloiStaking(
            address(usdc),
            MIN_STAKE,
            COOLDOWN,
            owner
        );

        // Fund makers and takers
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
    }

    function _stakeMaker(address maker, uint256 amount) internal {
        vm.startPrank(maker);
        usdc.approve(address(staking), amount);
        staking.stake(amount);
        vm.stopPrank();
    }

    function _createIntent(uint256 inputAmount, uint256 minOutput) internal returns (bytes32) {
        vm.startPrank(taker);
        usdc.approve(address(escrow), inputAmount);
        bytes32 intentId = escrow.createIntent(
            address(usdc),
            inputAmount,
            address(usdc), // output token (on dest chain)
            minOutput,
            DEST_CHAIN_ID,
            DEST_ADDRESS,
            block.timestamp + 1 hours
        );
        vm.stopPrank();
        return intentId;
    }
}
