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
import {IntentLib} from "../../src/libraries/IntentLib.sol";
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

    // Taker with private key for signing
    uint256 public takerKey = 0x7A4E5;
    address public taker;

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

    uint256 internal _testNonce;

    function setUp() public {
        taker = vm.addr(takerKey);
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

        // Approve escrow for taker (both tokens)
        vm.startPrank(taker);
        usdc.approve(address(escrow), type(uint256).max);
        usdt.approve(address(escrow), type(uint256).max);
        vm.stopPrank();

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

    function _makeOrder(
        address inputToken,
        uint256 inputAmount,
        address outputToken,
        uint256 minOutput
    ) internal returns (DataTypes.Order memory) {
        return DataTypes.Order({
            taker: taker,
            inputToken: inputToken,
            inputAmount: inputAmount,
            outputToken: outputToken,
            minOutputAmount: minOutput,
            destinationChainId: DEST_CHAIN,
            destinationAddress: DEST_ADDR,
            expiry: block.timestamp + 1 hours,
            nonce: _testNonce++
        });
    }

    function _signOrder(DataTypes.Order memory order) internal view returns (bytes memory) {
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
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(takerKey, digest);
        return abi.encodePacked(r, s, v);
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
    // Happy path: sign → executeOrder → fill → settle
    // =========================================================================

    function test_happyPath_USDC() public {
        uint256 takerBalBefore = usdc.balanceOf(taker);
        uint256 makerBalBefore = usdc.balanceOf(makerA);

        // 1. Taker signs order off-chain, maker executes it
        DataTypes.Order memory order = _makeOrder(address(usdc), 50_000e6, address(usdc), 49_900e6);
        bytes memory sig = _signOrder(order);

        vm.prank(makerA);
        bytes32 intentId = escrow.executeOrder(order, sig);

        assertEq(usdc.balanceOf(taker), takerBalBefore - 50_000e6);
        assertEq(usdc.balanceOf(address(escrow)), 50_000e6);
        assertEq(staking.getMakerInfo(makerA).activeExposure, 50_000e6);

        // 2. MakerA fills on dest chain (simulated) and submits evidence
        bytes32 fillTx = keccak256("arb_tx_0x1234");
        vm.prank(makerA);
        escrow.submitFill(intentId, fillTx);

        // 3. Wait for settlement window
        vm.warp(block.timestamp + SETTLEMENT_WINDOW);

        // 4. Settle
        escrow.settle(order);

        // Verify final state
        DataTypes.Commitment memory commitment = escrow.getCommitment(intentId);
        assertTrue(commitment.state == DataTypes.IntentState.Settled);
        assertEq(usdc.balanceOf(makerA), makerBalBefore + 50_000e6);
        assertEq(staking.getMakerInfo(makerA).activeExposure, 0);
    }

    function test_happyPath_USDT() public {
        // Taker signs order for USDT input, wants USDC on Arbitrum
        DataTypes.Order memory order = _makeOrder(address(usdt), 25_000e6, address(usdc), 24_950e6);
        bytes memory sig = _signOrder(order);

        vm.prank(makerA);
        bytes32 intentId = escrow.executeOrder(order, sig);

        vm.prank(makerA);
        escrow.submitFill(intentId, keccak256("fill_tx"));

        vm.warp(block.timestamp + SETTLEMENT_WINDOW);
        escrow.settle(order);

        // Maker receives USDT (the input token)
        assertEq(usdt.balanceOf(makerA), 25_000e6);
        assertTrue(escrow.getCommitment(intentId).state == DataTypes.IntentState.Settled);
    }

    // =========================================================================
    // Batch settle: multiple intents settled in one tx
    // =========================================================================

    function test_batchSettle_multipleIntents() public {
        DataTypes.Order[] memory orders = new DataTypes.Order[](5);
        bytes32[] memory ids = new bytes32[](5);

        // Create 5 intents
        for (uint256 i = 0; i < 5; i++) {
            orders[i] = _makeOrder(address(usdc), 10_000e6, address(usdc), 9_990e6);
            bytes memory sig = _signOrder(orders[i]);

            vm.prank(makerA);
            ids[i] = escrow.executeOrder(orders[i], sig);

            vm.prank(makerA);
            escrow.submitFill(ids[i], keccak256(abi.encode("fill", i)));
        }

        assertEq(staking.getMakerInfo(makerA).activeExposure, 50_000e6);

        vm.warp(block.timestamp + SETTLEMENT_WINDOW);

        uint256 makerBalBefore = usdc.balanceOf(makerA);
        escrow.settleBatch(orders);

        // All settled, all funds released
        assertEq(usdc.balanceOf(makerA) - makerBalBefore, 50_000e6);
        assertEq(staking.getMakerInfo(makerA).activeExposure, 0);

        for (uint256 i = 0; i < 5; i++) {
            assertTrue(escrow.getCommitment(ids[i]).state == DataTypes.IntentState.Settled);
        }
    }

    // =========================================================================
    // Commitment timeout: maker commits but doesn't fill
    // =========================================================================

    function test_commitmentTimeout_makerFails() public {
        DataTypes.Order memory order = _makeOrder(address(usdc), 10_000e6, address(usdc), 9_990e6);
        bytes memory sig = _signOrder(order);

        vm.prank(makerA);
        escrow.executeOrder(order, sig);
        assertEq(staking.getMakerInfo(makerA).activeExposure, 10_000e6);

        // Maker doesn't fill. Commitment times out.
        vm.warp(block.timestamp + COMMITMENT_TIMEOUT + 1);

        vm.prank(taker);
        escrow.reclaimExpired(order);

        assertEq(staking.getMakerInfo(makerA).activeExposure, 0);
        bytes32 intentId = IntentLib.computeIntentId(order);
        assertTrue(escrow.getCommitment(intentId).state == DataTypes.IntentState.Expired);
    }

    // =========================================================================
    // Dispute: fill is valid (disputer is wrong)
    // =========================================================================

    function test_dispute_fillValid_fullFlow() public {
        // Create and fill
        DataTypes.Order memory order = _makeOrder(address(usdc), 20_000e6, address(usdc), 19_950e6);
        bytes memory sig = _signOrder(order);

        bytes32 fillTx = keccak256("legit_fill");
        vm.prank(makerA);
        bytes32 intentId = escrow.executeOrder(order, sig);

        vm.prank(makerA);
        escrow.submitFill(intentId, fillTx);

        // MakerB disputes (incorrectly)
        uint256 bondAmount = disputes.calculateDisputeBond(20_000e6);
        uint256 makerBBalBefore = usdc.balanceOf(makerB);

        vm.startPrank(makerB);
        usdc.approve(address(disputes), bondAmount);
        disputes.dispute(order);
        vm.stopPrank();

        assertEq(usdc.balanceOf(makerB), makerBBalBefore - bondAmount);

        // MakerC attests: fill is valid
        bytes memory attestSig = _signAttestation(makerCKey, intentId, true, fillTx, DEST_CHAIN);
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = attestSig;

        uint256 makerABalBefore = usdc.balanceOf(makerA);

        disputes.resolveDispute(intentId, true, sigs);

        // MakerA gets escrowed funds + half the bond
        assertEq(usdc.balanceOf(makerA) - makerABalBefore, 20_000e6 + bondAmount / 2);

        // Intent settled
        assertTrue(escrow.getCommitment(intentId).state == DataTypes.IntentState.Settled);
        assertEq(staking.getMakerInfo(makerA).activeExposure, 0);
    }

    // =========================================================================
    // Dispute: fill is invalid (maker committed fraud)
    // =========================================================================

    function test_dispute_fillInvalid_fullFlow() public {
        // Create and fill with fake tx hash
        DataTypes.Order memory order = _makeOrder(address(usdc), 20_000e6, address(usdc), 19_950e6);
        bytes memory sig = _signOrder(order);

        bytes32 fakeFillTx = keccak256("fake_fill");
        vm.prank(makerA);
        bytes32 intentId = escrow.executeOrder(order, sig);

        vm.prank(makerA);
        escrow.submitFill(intentId, fakeFillTx);

        uint256 makerAStakeBefore = staking.getMakerInfo(makerA).stakedAmount;

        // MakerB disputes (correctly)
        uint256 bondAmount = disputes.calculateDisputeBond(20_000e6);
        vm.startPrank(makerB);
        usdc.approve(address(disputes), bondAmount);
        disputes.dispute(order);
        vm.stopPrank();

        // MakerC attests: fill is invalid
        bytes memory attestSig = _signAttestation(makerCKey, intentId, false, fakeFillTx, DEST_CHAIN);
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = attestSig;

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
        assertTrue(escrow.getCommitment(intentId).state == DataTypes.IntentState.Expired);
    }

    // =========================================================================
    // Dispute: expires without resolution (defaults to fill-valid)
    // =========================================================================

    function test_dispute_expiresDefault_fillValid() public {
        DataTypes.Order memory order = _makeOrder(address(usdc), 10_000e6, address(usdc), 9_990e6);
        bytes memory sig = _signOrder(order);

        vm.prank(makerA);
        bytes32 intentId = escrow.executeOrder(order, sig);

        vm.prank(makerA);
        escrow.submitFill(intentId, keccak256("fill"));

        uint256 bondAmount = disputes.calculateDisputeBond(10_000e6);
        vm.startPrank(makerB);
        usdc.approve(address(disputes), bondAmount);
        disputes.dispute(order);
        vm.stopPrank();

        // Nobody resolves. Wait for deadline.
        vm.warp(block.timestamp + RESOLUTION_WINDOW + 1);

        uint256 makerABalBefore = usdc.balanceOf(makerA);
        disputes.finalizeExpiredDispute(intentId);

        // Defaults to fill-valid: maker gets escrowed funds + half bond
        assertEq(usdc.balanceOf(makerA) - makerABalBefore, 10_000e6 + bondAmount / 2);
        assertTrue(escrow.getCommitment(intentId).state == DataTypes.IntentState.Settled);
    }

    // =========================================================================
    // Multiple makers: sequential intents with different makers
    // =========================================================================

    function test_multipleMakers_sequentialIntents() public {
        // Intent 1: filled by makerA
        DataTypes.Order memory order1 = _makeOrder(address(usdc), 10_000e6, address(usdc), 9_990e6);
        bytes memory sig1 = _signOrder(order1);

        vm.prank(makerA);
        bytes32 id1 = escrow.executeOrder(order1, sig1);

        vm.prank(makerA);
        escrow.submitFill(id1, keccak256("fill_a"));

        // Intent 2: filled by makerB
        DataTypes.Order memory order2 = _makeOrder(address(usdc), 15_000e6, address(usdc), 14_990e6);
        bytes memory sig2 = _signOrder(order2);

        vm.prank(makerB);
        bytes32 id2 = escrow.executeOrder(order2, sig2);

        vm.prank(makerB);
        escrow.submitFill(id2, keccak256("fill_b"));

        vm.warp(block.timestamp + SETTLEMENT_WINDOW);

        // Both settle independently
        escrow.settle(order1);
        escrow.settle(order2);

        assertTrue(escrow.getCommitment(id1).state == DataTypes.IntentState.Settled);
        assertTrue(escrow.getCommitment(id2).state == DataTypes.IntentState.Settled);
    }

    // =========================================================================
    // Maker capacity: can't over-commit
    // =========================================================================

    function test_makerCapacity_enforced() public {
        // MakerA has 100k staked. Commit to 100k intent (at capacity).
        DataTypes.Order memory order1 = _makeOrder(address(usdc), 100_000e6, address(usdc), 99_900e6);
        bytes memory sig1 = _signOrder(order1);

        vm.prank(makerA);
        escrow.executeOrder(order1, sig1);

        // Try second intent — should fail (exceeds capacity)
        DataTypes.Order memory order2 = _makeOrder(address(usdc), 10_000e6, address(usdc), 9_990e6);
        bytes memory sig2 = _signOrder(order2);

        vm.prank(makerA);
        vm.expectRevert("GauloiStaking: exposure exceeds stake");
        escrow.executeOrder(order2, sig2);

        // MakerB can still execute
        vm.prank(makerB);
        escrow.executeOrder(order2, sig2);
    }

    // =========================================================================
    // Unstake blocked during active exposure
    // =========================================================================

    function test_unstakeBlocked_duringExposure() public {
        DataTypes.Order memory order = _makeOrder(address(usdc), 50_000e6, address(usdc), 49_900e6);
        bytes memory sig = _signOrder(order);

        vm.prank(makerA);
        escrow.executeOrder(order, sig);

        // MakerA can only unstake 50k (100k staked - 50k exposure)
        vm.prank(makerA);
        vm.expectRevert("GauloiStaking: insufficient available stake");
        staking.requestUnstake(60_000e6);

        // Can unstake up to the available amount
        vm.prank(makerA);
        staking.requestUnstake(50_000e6);
    }
}
