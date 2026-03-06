// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../helpers/BaseTest.sol";
import {GauloiDisputes} from "../../src/GauloiDisputes.sol";
import {IGauloiDisputes} from "../../src/interfaces/IGauloiDisputes.sol";
import {DataTypes} from "../../src/types/DataTypes.sol";
import {SignatureLib} from "../../src/libraries/SignatureLib.sol";
import {IntentLib} from "../../src/libraries/IntentLib.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

contract GauloiDisputesTest is BaseTest {
    GauloiDisputes public disputes;

    // Use actual private keys for signing (makers)
    uint256 public maker1Key = 0xA11CE;
    uint256 public maker2Key = 0xB0B;
    uint256 public maker3Key = 0xCAFE;
    address public maker1Addr;
    address public maker2Addr;
    address public maker3Addr;

    uint256 public constant RESOLUTION_WINDOW = 24 hours;
    uint256 public constant BOND_BPS = 50; // 0.5%
    uint256 public constant MIN_BOND = 25e6; // 25 USDC

    function setUp() public {
        // Derive addresses from keys
        maker1Addr = vm.addr(maker1Key);
        maker2Addr = vm.addr(maker2Key);
        maker3Addr = vm.addr(maker3Key);

        // Override the BaseTest taker with our keyed address
        taker = vm.addr(takerKey);

        usdc = new MockERC20Harness("USD Coin", "USDC", 6);
        staking = new GauloiStaking(address(usdc), MIN_STAKE, COOLDOWN, 1 hours, owner);

        escrow = new GauloiEscrow(address(staking), SETTLEMENT_WINDOW, COMMITMENT_TIMEOUT, owner);

        disputes = new GauloiDisputes(
            address(staking),
            address(escrow),
            address(usdc),
            RESOLUTION_WINDOW,
            BOND_BPS,
            MIN_BOND,
            owner
        );

        vm.startPrank(owner);
        staking.setEscrow(address(escrow));
        staking.setDisputes(address(disputes));
        escrow.setDisputes(address(disputes));
        escrow.addSupportedToken(address(usdc));
        vm.stopPrank();

        // Fund and stake makers
        usdc.mint(maker1Addr, 1_000_000e6);
        usdc.mint(maker2Addr, 1_000_000e6);
        usdc.mint(maker3Addr, 1_000_000e6);
        usdc.mint(taker, 1_000_000e6);

        _stakeWithAddr(maker1Addr, 50_000e6);
        _stakeWithAddr(maker2Addr, 50_000e6);
        _stakeWithAddr(maker3Addr, 50_000e6);

        // Approve escrow to pull from taker
        vm.prank(taker);
        usdc.approve(address(escrow), type(uint256).max);
    }

    function _stakeWithAddr(address maker, uint256 amount) internal {
        vm.startPrank(maker);
        usdc.approve(address(staking), amount);
        staking.stake(amount);
        vm.stopPrank();
    }

    function _createAndFillIntent(uint256 amount) internal returns (bytes32, DataTypes.Order memory) {
        DataTypes.Order memory order = _makeOrder(amount, amount - 10e6);
        bytes memory sig = _signOrder(takerKey, order);

        // Maker1 executes and fills
        vm.prank(maker1Addr);
        bytes32 intentId = escrow.executeOrder(order, sig);

        vm.startPrank(maker1Addr);
        escrow.submitFill(intentId, keccak256("dest_tx"));
        vm.stopPrank();

        return (intentId, order);
    }

    function _signAttestation(
        uint256 privateKey,
        bytes32 intentId,
        bool fillValid,
        bytes32 fillTxHash,
        uint256 destChainId
    ) internal view returns (bytes memory) {
        bytes32 structHash = SignatureLib.hashAttestation(
            intentId, fillValid, fillTxHash, destChainId
        );
        bytes32 digest = MessageHashUtils.toTypedDataHash(
            disputes.domainSeparator(), structHash
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    // --- Dispute creation ---

    function test_dispute() public {
        (bytes32 intentId, DataTypes.Order memory order) = _createAndFillIntent(10_000e6);

        vm.startPrank(maker2Addr);
        usdc.approve(address(disputes), type(uint256).max);
        disputes.dispute(order);
        vm.stopPrank();

        DataTypes.Dispute memory disp = disputes.getDispute(intentId);
        assertEq(disp.challenger, maker2Addr);
        assertEq(disp.bondAmount, 50e6); // 0.5% of 10k = 50 USDC (above 25 min)
        assertFalse(disp.resolved);

        // Commitment should be Disputed
        assertTrue(escrow.getCommitment(intentId).state == DataTypes.IntentState.Disputed);
    }

    function test_dispute_bondCalculation() public view {
        // For 100k fill: 0.5% = 500 USDC > 25 min
        assertEq(disputes.calculateDisputeBond(100_000e6), 500e6);
        // For 1k fill: 0.5% = 5 USDC < 25 min, so use min
        assertEq(disputes.calculateDisputeBond(1_000e6), MIN_BOND);
    }

    function test_dispute_notActiveMaker_reverts() public {
        (, DataTypes.Order memory order) = _createAndFillIntent(10_000e6);

        address nobody = makeAddr("nobody");
        usdc.mint(nobody, 1_000e6);

        vm.startPrank(nobody);
        usdc.approve(address(disputes), type(uint256).max);
        vm.expectRevert("GauloiDisputes: not active maker");
        disputes.dispute(order);
        vm.stopPrank();
    }

    function test_dispute_ownFill_reverts() public {
        (, DataTypes.Order memory order) = _createAndFillIntent(10_000e6);

        vm.startPrank(maker1Addr);
        usdc.approve(address(disputes), type(uint256).max);
        vm.expectRevert("GauloiDisputes: cannot dispute own fill");
        disputes.dispute(order);
        vm.stopPrank();
    }

    function test_dispute_alreadyDisputed_reverts() public {
        (, DataTypes.Order memory order) = _createAndFillIntent(10_000e6);

        vm.startPrank(maker2Addr);
        usdc.approve(address(disputes), type(uint256).max);
        disputes.dispute(order);
        vm.stopPrank();

        vm.startPrank(maker3Addr);
        usdc.approve(address(disputes), type(uint256).max);
        vm.expectRevert("GauloiDisputes: already disputed");
        disputes.dispute(order);
        vm.stopPrank();
    }

    function test_dispute_afterWindowClosed_reverts() public {
        (, DataTypes.Order memory order) = _createAndFillIntent(10_000e6);

        vm.warp(block.timestamp + SETTLEMENT_WINDOW + 1);

        vm.startPrank(maker2Addr);
        usdc.approve(address(disputes), type(uint256).max);
        vm.expectRevert("GauloiDisputes: window closed");
        disputes.dispute(order);
        vm.stopPrank();
    }

    // --- Dispute resolution: fill valid ---

    function test_resolveDispute_fillValid() public {
        (bytes32 intentId, DataTypes.Order memory order) = _createAndFillIntent(10_000e6);
        DataTypes.Commitment memory commitment = escrow.getCommitment(intentId);

        vm.startPrank(maker2Addr);
        usdc.approve(address(disputes), type(uint256).max);
        disputes.dispute(order);
        vm.stopPrank();

        // Maker3 attests fill is valid
        bytes memory sig = _signAttestation(
            maker3Key, intentId, true, commitment.fillTxHash, order.destinationChainId
        );

        bytes[] memory sigs = new bytes[](1);
        sigs[0] = sig;

        uint256 maker1BalBefore = usdc.balanceOf(maker1Addr);

        disputes.resolveDispute(intentId, true, sigs);

        DataTypes.Dispute memory disp = disputes.getDispute(intentId);
        assertTrue(disp.resolved);
        assertTrue(disp.fillDeemedValid);

        // Maker1 gets escrowed funds + half the dispute bond (50/2 = 25)
        uint256 bondAmount = disputes.calculateDisputeBond(10_000e6);
        uint256 maker1BalAfter = usdc.balanceOf(maker1Addr);
        assertEq(maker1BalAfter - maker1BalBefore, 10_000e6 + bondAmount / 2);

        // Intent settled
        assertTrue(escrow.getCommitment(intentId).state == DataTypes.IntentState.Settled);
    }

    // --- Dispute resolution: fill invalid ---

    function test_resolveDispute_fillInvalid() public {
        (bytes32 intentId, DataTypes.Order memory order) = _createAndFillIntent(10_000e6);
        DataTypes.Commitment memory commitment = escrow.getCommitment(intentId);

        vm.startPrank(maker2Addr);
        usdc.approve(address(disputes), type(uint256).max);
        disputes.dispute(order);
        vm.stopPrank();

        // Maker3 attests fill is invalid
        bytes memory sig = _signAttestation(
            maker3Key, intentId, false, commitment.fillTxHash, order.destinationChainId
        );

        bytes[] memory sigs = new bytes[](1);
        sigs[0] = sig;

        uint256 takerBalBefore = usdc.balanceOf(taker);
        uint256 challengerBalBefore = usdc.balanceOf(maker2Addr);

        disputes.resolveDispute(intentId, false, sigs);

        // Taker gets escrowed funds back
        assertEq(usdc.balanceOf(taker) - takerBalBefore, 10_000e6);

        // Challenger gets bond back + 25% of slashed stake
        uint256 bondAmount = disputes.calculateDisputeBond(10_000e6);
        uint256 challengerReward = bondAmount + (50_000e6 / 4);
        assertEq(usdc.balanceOf(maker2Addr) - challengerBalBefore, challengerReward);

        // Maker1 is slashed — no longer active
        assertFalse(staking.isActiveMaker(maker1Addr));
        assertEq(staking.getMakerInfo(maker1Addr).stakedAmount, 0);
    }

    // --- Signature verification ---

    function test_resolveDispute_duplicateSigner_reverts() public {
        (bytes32 intentId, DataTypes.Order memory order) = _createAndFillIntent(10_000e6);
        DataTypes.Commitment memory commitment = escrow.getCommitment(intentId);

        vm.startPrank(maker2Addr);
        usdc.approve(address(disputes), type(uint256).max);
        disputes.dispute(order);
        vm.stopPrank();

        bytes memory sig = _signAttestation(
            maker3Key, intentId, true, commitment.fillTxHash, order.destinationChainId
        );

        bytes[] memory sigs = new bytes[](2);
        sigs[0] = sig;
        sigs[1] = sig; // Duplicate

        vm.expectRevert("GauloiDisputes: duplicate signer");
        disputes.resolveDispute(intentId, true, sigs);
    }

    function test_resolveDispute_makerCannotAttestOwn_reverts() public {
        (bytes32 intentId, DataTypes.Order memory order) = _createAndFillIntent(10_000e6);
        DataTypes.Commitment memory commitment = escrow.getCommitment(intentId);

        vm.startPrank(maker2Addr);
        usdc.approve(address(disputes), type(uint256).max);
        disputes.dispute(order);
        vm.stopPrank();

        // Maker1 (the disputed maker) tries to attest their own fill
        bytes memory sig = _signAttestation(
            maker1Key, intentId, true, commitment.fillTxHash, order.destinationChainId
        );

        bytes[] memory sigs = new bytes[](1);
        sigs[0] = sig;

        vm.expectRevert("GauloiDisputes: maker cannot attest own fill");
        disputes.resolveDispute(intentId, true, sigs);
    }

    function test_resolveDispute_challengerCannotAttest_reverts() public {
        (bytes32 intentId, DataTypes.Order memory order) = _createAndFillIntent(10_000e6);
        DataTypes.Commitment memory commitment = escrow.getCommitment(intentId);

        vm.startPrank(maker2Addr);
        usdc.approve(address(disputes), type(uint256).max);
        disputes.dispute(order);
        vm.stopPrank();

        // Maker2 (challenger) tries to attest
        bytes memory sig = _signAttestation(
            maker2Key, intentId, true, commitment.fillTxHash, order.destinationChainId
        );

        bytes[] memory sigs = new bytes[](1);
        sigs[0] = sig;

        vm.expectRevert("GauloiDisputes: challenger cannot attest");
        disputes.resolveDispute(intentId, true, sigs);
    }

    // --- Expired dispute (defaults to fill-valid) ---

    function test_finalizeExpiredDispute() public {
        (bytes32 intentId, DataTypes.Order memory order) = _createAndFillIntent(10_000e6);

        vm.startPrank(maker2Addr);
        usdc.approve(address(disputes), type(uint256).max);
        disputes.dispute(order);
        vm.stopPrank();

        vm.warp(block.timestamp + RESOLUTION_WINDOW + 1);

        uint256 maker1BalBefore = usdc.balanceOf(maker1Addr);

        disputes.finalizeExpiredDispute(intentId);

        DataTypes.Dispute memory disp = disputes.getDispute(intentId);
        assertTrue(disp.resolved);
        assertTrue(disp.fillDeemedValid);

        // Maker gets escrowed funds + half bond
        uint256 bondAmount = disputes.calculateDisputeBond(10_000e6);
        assertEq(usdc.balanceOf(maker1Addr) - maker1BalBefore, 10_000e6 + bondAmount / 2);
    }

    function test_finalizeExpiredDispute_beforeDeadline_reverts() public {
        (, DataTypes.Order memory order) = _createAndFillIntent(10_000e6);
        bytes32 intentId = IntentLib.computeIntentId(order);

        vm.startPrank(maker2Addr);
        usdc.approve(address(disputes), type(uint256).max);
        disputes.dispute(order);
        vm.stopPrank();

        vm.expectRevert("GauloiDisputes: deadline not passed");
        disputes.finalizeExpiredDispute(intentId);
    }

    function test_resolveDispute_afterDeadline_reverts() public {
        (bytes32 intentId, DataTypes.Order memory order) = _createAndFillIntent(10_000e6);
        DataTypes.Commitment memory commitment = escrow.getCommitment(intentId);

        vm.startPrank(maker2Addr);
        usdc.approve(address(disputes), type(uint256).max);
        disputes.dispute(order);
        vm.stopPrank();

        vm.warp(block.timestamp + RESOLUTION_WINDOW + 1);

        bytes memory sig = _signAttestation(
            maker3Key, intentId, true, commitment.fillTxHash, order.destinationChainId
        );

        bytes[] memory sigs = new bytes[](1);
        sigs[0] = sig;

        vm.expectRevert("GauloiDisputes: deadline passed");
        disputes.resolveDispute(intentId, true, sigs);
    }
}

// Need these imports visible in this file for setUp
import {MockERC20} from "../helpers/MockERC20.sol";
import {GauloiStaking} from "../../src/GauloiStaking.sol";
import {GauloiEscrow} from "../../src/GauloiEscrow.sol";

contract MockERC20Harness is MockERC20 {
    constructor(string memory name, string memory symbol, uint8 decimals_)
        MockERC20(name, symbol, decimals_) {}
}
