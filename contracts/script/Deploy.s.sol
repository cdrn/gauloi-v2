// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {MockERC20} from "../test/helpers/MockERC20.sol";
import {GauloiStaking} from "../src/GauloiStaking.sol";
import {GauloiEscrow} from "../src/GauloiEscrow.sol";
import {GauloiDisputes} from "../src/GauloiDisputes.sol";

contract Deploy is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        // Deploy mock USDC
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        console.log("USDC:", address(usdc));

        // Deploy staking
        GauloiStaking staking = new GauloiStaking(
            address(usdc),
            10_000e6, // 10k min stake
            48 hours,
            deployer
        );
        console.log("Staking:", address(staking));

        // Deploy escrow
        uint256 settlementWindow = vm.envOr("SETTLEMENT_WINDOW", uint256(15 minutes));
        GauloiEscrow escrow = new GauloiEscrow(
            address(staking),
            settlementWindow,
            5 minutes,
            deployer
        );
        console.log("Escrow:", address(escrow));

        // Deploy disputes
        GauloiDisputes disputes = new GauloiDisputes(
            address(staking),
            address(escrow),
            address(usdc),
            24 hours,
            50,    // 50 bps = 0.5%
            25e6,  // 25 USDC min bond
            deployer
        );
        console.log("Disputes:", address(disputes));

        // Wire up permissions
        staking.setEscrow(address(escrow));
        staking.setDisputes(address(disputes));
        escrow.setDisputes(address(disputes));
        escrow.addSupportedToken(address(usdc));

        vm.stopBroadcast();
    }
}
