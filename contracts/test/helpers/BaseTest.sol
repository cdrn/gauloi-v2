// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "./MockERC20.sol";
import {GauloiStaking} from "../../src/GauloiStaking.sol";

abstract contract BaseTest is Test {
    MockERC20 public usdc;
    GauloiStaking public staking;

    address public owner = makeAddr("owner");
    address public maker1 = makeAddr("maker1");
    address public maker2 = makeAddr("maker2");
    address public maker3 = makeAddr("maker3");
    address public taker = makeAddr("taker");

    uint256 public constant MIN_STAKE = 10_000e6; // 10,000 USDC
    uint256 public constant COOLDOWN = 48 hours;

    function _deployBase() internal {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        staking = new GauloiStaking(
            address(usdc),
            MIN_STAKE,
            COOLDOWN,
            owner
        );

        // Fund makers
        usdc.mint(maker1, 1_000_000e6);
        usdc.mint(maker2, 1_000_000e6);
        usdc.mint(maker3, 1_000_000e6);
        usdc.mint(taker, 1_000_000e6);
    }

    function _stakeMaker(address maker, uint256 amount) internal {
        vm.startPrank(maker);
        usdc.approve(address(staking), amount);
        staking.stake(amount);
        vm.stopPrank();
    }
}
