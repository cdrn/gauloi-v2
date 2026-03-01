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

        // USDC: use existing address if provided, otherwise deploy mock
        address usdc = vm.envOr("USDC_ADDRESS", address(0));
        if (usdc == address(0)) {
            usdc = address(new MockERC20("USD Coin", "USDC", 6));
            console.log("USDC (mock):", usdc);
        } else {
            console.log("USDC (existing):", usdc);
        }

        // Deploy staking
        GauloiStaking staking = new GauloiStaking(
            usdc,
            vm.envOr("MIN_STAKE", uint256(10_000e6)),
            vm.envOr("COOLDOWN", uint256(48 hours)),
            deployer
        );
        console.log("Staking:", address(staking));

        // Deploy escrow
        GauloiEscrow escrow = new GauloiEscrow(
            address(staking),
            vm.envOr("SETTLEMENT_WINDOW", uint256(15 minutes)),
            vm.envOr("COMMITMENT_TIMEOUT", uint256(5 minutes)),
            deployer
        );
        console.log("Escrow:", address(escrow));

        // Deploy disputes
        GauloiDisputes disputes = _deployDisputes(address(staking), address(escrow), usdc, deployer);
        console.log("Disputes:", address(disputes));

        // Wire up permissions
        staking.setEscrow(address(escrow));
        staking.setDisputes(address(disputes));
        escrow.setDisputes(address(disputes));
        escrow.addSupportedToken(usdc);

        vm.stopBroadcast();
    }

    function _deployDisputes(
        address staking,
        address escrow,
        address usdc,
        address owner
    ) internal returns (GauloiDisputes) {
        return new GauloiDisputes(
            staking,
            escrow,
            usdc,
            vm.envOr("RESOLUTION_WINDOW", uint256(24 hours)),
            vm.envOr("BOND_BPS", uint256(50)),
            vm.envOr("MIN_BOND", uint256(25e6)),
            owner
        );
    }
}
