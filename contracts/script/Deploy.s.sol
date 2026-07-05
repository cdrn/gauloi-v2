// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {MockERC20} from "../test/helpers/MockERC20.sol";
import {GauloiStaking} from "../src/GauloiStaking.sol";
import {GauloiEscrow} from "../src/GauloiEscrow.sol";
import {GauloiDisputes} from "../src/GauloiDisputes.sol";
import {GauloiFillRegistry} from "../src/GauloiFillRegistry.sol";
import {CouncilResolver} from "../src/resolvers/CouncilResolver.sol";

/// @notice Deploys the full v0.2 stack on one chain:
///         Staking + Escrow + Disputes + FillRegistry + CouncilResolver.
///
///         Env:
///         - DEPLOYER_KEY (required)
///         - USDC_ADDRESS (optional — deploys a mock if absent)
///         - TREASURY (optional — defaults to deployer)
///         - DEST_CHAIN_ID (optional — corridor to wire the council resolver for;
///           e.g. 421614 when deploying on Eth Sepolia, 11155111 on Arb Sepolia)
///         - MIN_STAKE, COOLDOWN, STALE_PRICE_THRESHOLD, SETTLEMENT_WINDOW,
///           COMMITMENT_TIMEOUT, RESOLUTION_WINDOW, BOND_BPS, MIN_BOND (optional)
contract Deploy is Script {
    function run() external {
        // Project convention: PRIVATE_KEY (DEPLOYER_KEY accepted as fallback)
        uint256 deployerKey = vm.envOr("PRIVATE_KEY", uint256(0));
        if (deployerKey == 0) deployerKey = vm.envUint("DEPLOYER_KEY");
        address deployer = vm.addr(deployerKey);
        address treasury = vm.envOr("TREASURY", deployer);

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
            vm.envOr("STALE_PRICE_THRESHOLD", uint256(24 hours)),
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

        // Deploy fill registry (destination-side; every chain is a destination)
        GauloiFillRegistry registry = new GauloiFillRegistry();
        console.log("FillRegistry:", address(registry));

        // Deploy council resolver — bootstrap council is the deployer, 1-of-1,
        // stated plainly in the README trust-model table until it isn't
        address[] memory members = new address[](1);
        members[0] = deployer;
        CouncilResolver council = new CouncilResolver(members, 1, deployer);
        console.log("CouncilResolver:", address(council));

        // Deploy disputes
        GauloiDisputes disputes = new GauloiDisputes(
            address(staking),
            address(escrow),
            usdc,
            vm.envOr("RESOLUTION_WINDOW", uint256(24 hours)),
            vm.envOr("BOND_BPS", uint256(200)),
            vm.envOr("MIN_BOND", uint256(250e6)),
            treasury,
            deployer
        );
        console.log("Disputes:", address(disputes));

        // Wire up permissions
        staking.setEscrow(address(escrow));
        staking.setDisputes(address(disputes));
        escrow.setDisputes(address(disputes));
        escrow.setTreasury(treasury);
        escrow.addSupportedToken(usdc);

        // Wire the corridor's resolver (destination chain served from this chain).
        // Council is the default/bootstrap arbiter. A corridor graduates to the
        // trustless ProofResolver later — that needs an audited IFillProofVerifier
        // (ZK light client / Axiom / Herodotus) chosen per deployment, so it is
        // NOT deployed here. To graduate a corridor:
        //   ProofResolver pr = new ProofResolver(auditedVerifier, address(escrow), owner);
        //   pr.configureCorridor(destChainId, destFillRegistry, FILLS_SLOT);
        //   disputes.setResolver(destChainId, address(pr));
        // FILLS_SLOT is pinned by ProofResolver.t.sol:test_fillSlot_matchesRegistryLayout.
        uint256 destChainId = vm.envOr("DEST_CHAIN_ID", uint256(0));
        if (destChainId != 0) {
            disputes.setResolver(destChainId, address(council));
            console.log("Council resolver wired for corridor:", destChainId);
        }

        vm.stopBroadcast();
    }
}
