// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "../helpers/MockERC20.sol";
import {GauloiStaking} from "../../src/GauloiStaking.sol";
import {GauloiEscrow} from "../../src/GauloiEscrow.sol";
import {GauloiDisputes} from "../../src/GauloiDisputes.sol";
import {IGauloiEscrow} from "../../src/interfaces/IGauloiEscrow.sol";
import {IGauloiDisputes} from "../../src/interfaces/IGauloiDisputes.sol";
import {DataTypes} from "../../src/types/DataTypes.sol";
import {SignatureLib} from "../../src/libraries/SignatureLib.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @notice Full integration test: all three contracts deployed and wired together.
contract SettlementLoopTest is Test {
    MockERC20 public usdc;
    MockERC20 public usdt;
    GauloiStaking public staking;
    GauloiEscrow public escrow;
    GauloiDisputes public disputes;

    address public owner = makeAddr("owner");
    address public taker = makeAddr("taker");

    // Makers with private keys for signing
    uint256 public makerAKey = 0xA1;
    uint256 public makerBKey = 0xB2;
    uint256 public makerCKey = 0xC3;
    address public makerA;
    address public makerB;
    address public makerC;

    uint256 constant MIN_STAKE = 10_000e6;
    uint256 constant COOLDOWN = 48 hours;
    uint256 constant SETTLEMENT_WINDOW = 15 minutes;
    uint256 constant COMMITMENT_TIMEOUT = 5 minutes;
    uint256 constant RESOLUTION_WINDOW = 24 hours;
    uint256 constant BOND_BPS = 50;
    uint256 constant MIN_BOND = 25e6;
    uint256 constant DEST_CHAIN = 42161;
    address constant DEST_ADDR = address(0xBEEF);

    function setUp() public {
        makerA = vm.addr(makerAKey);
        makerB = vm.addr(makerBKey);
        makerC = vm.addr(makerCKey);

        // Deploy tokens
        usdc = new MockERC20("USD Coin", "USDC", 6);
        usdt = new MockERC20("Tether USD", "USDT", 6);

        // Deploy protocol
        staking = new GauloiStaking(address(usdc), MIN_STAKE, COOLDOWN, owner);
        escrow = new GauloiEscrow(address(staking), SETTLEMENT_WINDOW, COMMITMENT_TIMEOUT, owner);
        disputes = new GauloiDisputes(
            address(staking), address(escrow), address(usdc),
            RESOLUTION_WINDOW, BOND_BPS, MIN_BOND, owner
        );

        // Wire contracts
        vm.startPrank(owner);
        staking.setEscrow(address(escrow));
        staking.setDisputes(address(disputes));
        escrow.setDisputes(address(disputes));
        escrow.addSupportedToken(address(usdc));
        escrow.addSupportedToken(address(usdt));
        vm.stopPrank();

        // Fund participants
        usdc.mint(makerA, 500_000e6);
        usdc.mint(makerB, 500_000e6);
        usdc.mint(makerC, 500_000e6);
        usdc.mint(taker, 500_000e6);
        usdt.mint(taker, 500_000e6);

        // Stake all makers
        _stake(makerA, 100_000e6);
        _stake(makerB, 100_000e6);
        _stake(makerC, 100_000e6);
    }

    function _stake(address maker, uint256 amount) internal {
        vm.startPrank(maker);
        usdc.approve(address(staking), amount);
        staking.stake(amount);
        vm.stopPrank();
    }

    function _signAttestation(
        uint256 key, bytes32 intentId, bool fillValid,
        bytes32 fillTxHash, uint256 destChainId
    ) internal view returns (bytes memory) {
        bytes32 structHash = SignatureLib.hashAttestation(
            intentId, fillValid, fillTxHash, destChainId
        );
        bytes32 digest = MessageHashUtils.toTypedDataHash(
            disputes.domainSeparator(), structHash
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    // =========================================================================
    // Happy path: create → commit → fill → settle
    // =========================================================================

    function test_happyPath_USDC() public {
        uint256 takerBalBefore = usdc.balanceOf(taker);
        uint256 makerBalBefore = usdc.balanceOf(makerA);

        // 1. Taker creates intent: 50k USDC for USDC on Arbitrum
        vm.startPrank(taker);
        usdc.approve(address(escrow), 50_000e6);
        bytes32 intentId = escrow.createIntent(
            address(usdc), 50_000e6, address(usdc), 49_900e6,
            DEST_CHAIN, DEST_ADDR, block.timestamp + 1 hours
        );
        vm.stopPrank();

        assertEq(usdc.balanceOf(taker), takerBalBefore - 50_000e6);
        assertEq(usdc.balanceOf(address(escrow)), 50_000e6);

        // 2. MakerA commits
        vm.prank(makerA);
        escrow.commitToIntent(intentId);
        assertEq(staking.getMakerInfo(makerA).activeExposure, 50_000e6);

        // 3. MakerA fills on dest chain (simulated) and submits evidence
        bytes32 fillTx = keccak256("arb_tx_0x1234");
        vm.prank(makerA);
        escrow.submitFill(intentId, fillTx);

        // 4. Wait for settlement window
        vm.warp(block.timestamp + SETTLEMENT_WINDOW);

        // 5. Settle
        escrow.settle(intentId);

        // Verify final state
        DataTypes.Intent memory intent = escrow.getIntent(intentId);
        assertTrue(intent.state == DataTypes.IntentState.Settled);
        assertEq(usdc.balanceOf(makerA), makerBalBefore + 50_000e6);
        assertEq(staking.getMakerInfo(makerA).activeExposure, 0);
    }

    function test_happyPath_USDT() public {
        // Taker deposits USDT, wants USDC on Arbitrum
        vm.startPrank(taker);
        usdt.approve(address(escrow), 25_000e6);
        bytes32 intentId = escrow.createIntent(
            address(usdt), 25_000e6, address(usdc), 24_950e6,
            DEST_CHAIN, DEST_ADDR, block.timestamp + 1 hours
        );
        vm.stopPrank();

        vm.prank(makerA);
        escrow.commitToIntent(intentId);

        vm.prank(makerA);
        escrow.submitFill(intentId, keccak256("fill_tx"));

        vm.warp(block.timestamp + SETTLEMENT_WINDOW);
        escrow.settle(intentId);

        // Maker receives USDT (the input token)
        assertEq(usdt.balanceOf(makerA), 25_000e6);
        assertTrue(escrow.getIntent(intentId).state == DataTypes.IntentState.Settled);
    }

    // =========================================================================
    // Batch settle: multiple intents settled in one tx
    // =========================================================================

    function test_batchSettle_multipleIntents() public {
        bytes32[] memory ids = new bytes32[](5);

        // Create 5 intents
        for (uint256 i = 0; i < 5; i++) {
            vm.startPrank(taker);
            usdc.approve(address(escrow), 10_000e6);
            ids[i] = escrow.createIntent(
                address(usdc), 10_000e6, address(usdc), 9_990e6,
                DEST_CHAIN, DEST_ADDR, block.timestamp + 1 hours
            );
            vm.stopPrank();

            vm.startPrank(makerA);
            escrow.commitToIntent(ids[i]);
            escrow.submitFill(ids[i], keccak256(abi.encode("fill", i)));
            vm.stopPrank();
        }

        assertEq(staking.getMakerInfo(makerA).activeExposure, 50_000e6);

        vm.warp(block.timestamp + SETTLEMENT_WINDOW);

        uint256 makerBalBefore = usdc.balanceOf(makerA);
        escrow.settleBatch(ids);

        // All settled, all funds released
        assertEq(usdc.balanceOf(makerA) - makerBalBefore, 50_000e6);
        assertEq(staking.getMakerInfo(makerA).activeExposure, 0);

        for (uint256 i = 0; i < 5; i++) {
            assertTrue(escrow.getIntent(ids[i]).state == DataTypes.IntentState.Settled);
        }
    }

    // =========================================================================
    // Expiry: no maker commits, taker reclaims
    // =========================================================================

    function test_expiry_noMaker() public {
        vm.startPrank(taker);
        usdc.approve(address(escrow), 10_000e6);
        bytes32 intentId = escrow.createIntent(
            address(usdc), 10_000e6, address(usdc), 9_990e6,
            DEST_CHAIN, DEST_ADDR, block.timestamp + 1 hours
        );
        vm.stopPrank();

        uint256 takerBalBefore = usdc.balanceOf(taker);

        vm.warp(block.timestamp + 2 hours);

        vm.prank(taker);
        escrow.reclaimExpired(intentId);

        assertEq(usdc.balanceOf(taker) - takerBalBefore, 10_000e6);
        assertTrue(escrow.getIntent(intentId).state == DataTypes.IntentState.Expired);
    }

    // =========================================================================
    // Commitment timeout: maker commits but doesn't fill
    // =========================================================================

    function test_commitmentTimeout_makerFails() public {
        vm.startPrank(taker);
        usdc.approve(address(escrow), 10_000e6);
        bytes32 intentId = escrow.createIntent(
            address(usdc), 10_000e6, address(usdc), 9_990e6,
            DEST_CHAIN, DEST_ADDR, block.timestamp + 1 hours
        );
        vm.stopPrank();

        vm.prank(makerA);
        escrow.commitToIntent(intentId);
        assertEq(staking.getMakerInfo(makerA).activeExposure, 10_000e6);

        // Maker doesn't fill. Commitment times out.
        vm.warp(block.timestamp + COMMITMENT_TIMEOUT + 1);

        vm.prank(taker);
        escrow.reclaimExpired(intentId);

        assertEq(staking.getMakerInfo(makerA).activeExposure, 0);
        assertTrue(escrow.getIntent(intentId).state == DataTypes.IntentState.Expired);
    }

    // =========================================================================
    // Dispute: fill is valid (disputer is wrong)
    // =========================================================================

    function test_dispute_fillValid_fullFlow() public {
        // Create and fill
        vm.startPrank(taker);
        usdc.approve(address(escrow), 20_000e6);
        bytes32 intentId = escrow.createIntent(
            address(usdc), 20_000e6, address(usdc), 19_950e6,
            DEST_CHAIN, DEST_ADDR, block.timestamp + 1 hours
        );
        vm.stopPrank();

        bytes32 fillTx = keccak256("legit_fill");
        vm.startPrank(makerA);
        escrow.commitToIntent(intentId);
        escrow.submitFill(intentId, fillTx);
        vm.stopPrank();

        // MakerB disputes (incorrectly)
        uint256 bondAmount = disputes.calculateDisputeBond(20_000e6);
        uint256 makerBBalBefore = usdc.balanceOf(makerB);

        vm.startPrank(makerB);
        usdc.approve(address(disputes), bondAmount);
        disputes.dispute(intentId);
        vm.stopPrank();

        assertEq(usdc.balanceOf(makerB), makerBBalBefore - bondAmount);

        // MakerC attests: fill is valid
        bytes memory sig = _signAttestation(makerCKey, intentId, true, fillTx, DEST_CHAIN);
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = sig;

        uint256 makerABalBefore = usdc.balanceOf(makerA);

        disputes.resolveDispute(intentId, true, sigs);

        // MakerA gets escrowed funds + half the bond
        assertEq(usdc.balanceOf(makerA) - makerABalBefore, 20_000e6 + bondAmount / 2);

        // MakerB lost their bond
        // (makerB balance should still be makerBBalBefore - bondAmount, no refund)

        // Intent settled
        assertTrue(escrow.getIntent(intentId).state == DataTypes.IntentState.Settled);
        assertEq(staking.getMakerInfo(makerA).activeExposure, 0);
    }

    // =========================================================================
    // Dispute: fill is invalid (maker committed fraud)
    // =========================================================================

    function test_dispute_fillInvalid_fullFlow() public {
        // Create and fill with fake tx hash
        vm.startPrank(taker);
        usdc.approve(address(escrow), 20_000e6);
        bytes32 intentId = escrow.createIntent(
            address(usdc), 20_000e6, address(usdc), 19_950e6,
            DEST_CHAIN, DEST_ADDR, block.timestamp + 1 hours
        );
        vm.stopPrank();

        bytes32 fakeFillTx = keccak256("fake_fill");
        vm.startPrank(makerA);
        escrow.commitToIntent(intentId);
        escrow.submitFill(intentId, fakeFillTx);
        vm.stopPrank();

        uint256 makerAStakeBefore = staking.getMakerInfo(makerA).stakedAmount;

        // MakerB disputes (correctly)
        uint256 bondAmount = disputes.calculateDisputeBond(20_000e6);
        vm.startPrank(makerB);
        usdc.approve(address(disputes), bondAmount);
        disputes.dispute(intentId);
        vm.stopPrank();

        // MakerC attests: fill is invalid
        bytes memory sig = _signAttestation(makerCKey, intentId, false, fakeFillTx, DEST_CHAIN);
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = sig;

        uint256 takerBalBefore = usdc.balanceOf(taker);
        uint256 makerBBalBefore = usdc.balanceOf(makerB);

        disputes.resolveDispute(intentId, false, sigs);

        // Taker gets escrowed funds back
        assertEq(usdc.balanceOf(taker) - takerBalBefore, 20_000e6);

        // MakerB gets bond back + 25% of slashed stake
        uint256 expectedReward = bondAmount + (makerAStakeBefore / 4);
        assertEq(usdc.balanceOf(makerB) - makerBBalBefore, expectedReward);

        // MakerA is slashed completely
        assertFalse(staking.isActiveMaker(makerA));
        assertEq(staking.getMakerInfo(makerA).stakedAmount, 0);

        // Intent refunded
        assertTrue(escrow.getIntent(intentId).state == DataTypes.IntentState.Expired);
    }

    // =========================================================================
    // Dispute: expires without resolution (defaults to fill-valid)
    // =========================================================================

    function test_dispute_expiresDefault_fillValid() public {
        vm.startPrank(taker);
        usdc.approve(address(escrow), 10_000e6);
        bytes32 intentId = escrow.createIntent(
            address(usdc), 10_000e6, address(usdc), 9_990e6,
            DEST_CHAIN, DEST_ADDR, block.timestamp + 1 hours
        );
        vm.stopPrank();

        vm.startPrank(makerA);
        escrow.commitToIntent(intentId);
        escrow.submitFill(intentId, keccak256("fill"));
        vm.stopPrank();

        uint256 bondAmount = disputes.calculateDisputeBond(10_000e6);
        vm.startPrank(makerB);
        usdc.approve(address(disputes), bondAmount);
        disputes.dispute(intentId);
        vm.stopPrank();

        // Nobody resolves. Wait for deadline.
        vm.warp(block.timestamp + RESOLUTION_WINDOW + 1);

        uint256 makerABalBefore = usdc.balanceOf(makerA);
        disputes.finalizeExpiredDispute(intentId);

        // Defaults to fill-valid: maker gets escrowed funds + half bond
        assertEq(usdc.balanceOf(makerA) - makerABalBefore, 10_000e6 + bondAmount / 2);
        assertTrue(escrow.getIntent(intentId).state == DataTypes.IntentState.Settled);
    }

    // =========================================================================
    // Multiple makers: sequential intents with different makers
    // =========================================================================

    function test_multipleMakers_sequentialIntents() public {
        // Intent 1: filled by makerA
        vm.startPrank(taker);
        usdc.approve(address(escrow), 10_000e6);
        bytes32 id1 = escrow.createIntent(
            address(usdc), 10_000e6, address(usdc), 9_990e6,
            DEST_CHAIN, DEST_ADDR, block.timestamp + 1 hours
        );
        vm.stopPrank();

        vm.startPrank(makerA);
        escrow.commitToIntent(id1);
        escrow.submitFill(id1, keccak256("fill_a"));
        vm.stopPrank();

        // Intent 2: filled by makerB
        vm.startPrank(taker);
        usdc.approve(address(escrow), 15_000e6);
        bytes32 id2 = escrow.createIntent(
            address(usdc), 15_000e6, address(usdc), 14_990e6,
            DEST_CHAIN, DEST_ADDR, block.timestamp + 1 hours
        );
        vm.stopPrank();

        vm.startPrank(makerB);
        escrow.commitToIntent(id2);
        escrow.submitFill(id2, keccak256("fill_b"));
        vm.stopPrank();

        vm.warp(block.timestamp + SETTLEMENT_WINDOW);

        // Both settle independently
        escrow.settle(id1);
        escrow.settle(id2);

        assertTrue(escrow.getIntent(id1).state == DataTypes.IntentState.Settled);
        assertTrue(escrow.getIntent(id2).state == DataTypes.IntentState.Settled);
    }

    // =========================================================================
    // Maker capacity: can't over-commit
    // =========================================================================

    function test_makerCapacity_enforced() public {
        // MakerA has 100k staked. Commit to 100k intent (at capacity).
        vm.startPrank(taker);
        usdc.approve(address(escrow), 100_000e6);
        bytes32 id1 = escrow.createIntent(
            address(usdc), 100_000e6, address(usdc), 99_900e6,
            DEST_CHAIN, DEST_ADDR, block.timestamp + 1 hours
        );
        vm.stopPrank();

        vm.prank(makerA);
        escrow.commitToIntent(id1);

        // Try second intent — should fail
        vm.startPrank(taker);
        usdc.approve(address(escrow), 10_000e6);
        bytes32 id2 = escrow.createIntent(
            address(usdc), 10_000e6, address(usdc), 9_990e6,
            DEST_CHAIN, DEST_ADDR, block.timestamp + 1 hours
        );
        vm.stopPrank();

        vm.prank(makerA);
        vm.expectRevert("GauloiStaking: exposure exceeds stake");
        escrow.commitToIntent(id2);

        // MakerB can still commit
        vm.prank(makerB);
        escrow.commitToIntent(id2);
    }

    // =========================================================================
    // Unstake blocked during active exposure
    // =========================================================================

    function test_unstakeBlocked_duringExposure() public {
        vm.startPrank(taker);
        usdc.approve(address(escrow), 50_000e6);
        bytes32 intentId = escrow.createIntent(
            address(usdc), 50_000e6, address(usdc), 49_900e6,
            DEST_CHAIN, DEST_ADDR, block.timestamp + 1 hours
        );
        vm.stopPrank();

        vm.prank(makerA);
        escrow.commitToIntent(intentId);

        // MakerA can only unstake 50k (100k staked - 50k exposure)
        vm.prank(makerA);
        vm.expectRevert("GauloiStaking: insufficient available stake");
        staking.requestUnstake(60_000e6);

        // Can unstake up to the available amount
        vm.prank(makerA);
        staking.requestUnstake(50_000e6);
    }
}
