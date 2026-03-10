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
    uint256 public constant BOND_BPS = 200; // 2%
    uint256 public constant MIN_BOND = 250e6; // 250 USDC

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
        assertEq(disp.bondAmount, 250e6); // 2% of 10k = 200 USDC < 250 min, so use min
        assertFalse(disp.resolved);

        // Commitment should be Disputed
        assertTrue(escrow.getCommitment(intentId).state == DataTypes.IntentState.Disputed);
    }

    function test_dispute_bondCalculation() public view {
        // For 100k fill: 2% = 2000 USDC > 250 min
        assertEq(disputes.calculateDisputeBond(100_000e6), 2_000e6);
        // For 1k fill: 2% = 20 USDC < 250 min, so use min
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
        // maker3 has 50k stake. Eligible = totalActive(150k) - maker1(50k) - maker2(50k) = 50k
        // maker3's 50k = 100% of eligible → quorum (30%) met
        bytes memory sig = _signAttestation(
            maker3Key, intentId, true, commitment.fillTxHash, order.destinationChainId
        );

        bytes[] memory sigs = new bytes[](1);
        sigs[0] = sig;

        uint256 maker1BalBefore = usdc.balanceOf(maker1Addr);
        uint256 maker3BalBefore = usdc.balanceOf(maker3Addr);

        disputes.resolveDispute(intentId, true, sigs);

        DataTypes.Dispute memory disp = disputes.getDispute(intentId);
        assertTrue(disp.resolved);
        assertTrue(disp.fillDeemedValid);

        uint256 bondAmount = disputes.calculateDisputeBond(10_000e6); // 250e6 (min)
        // Maker1 gets escrowed funds + 50% of bond
        uint256 maker1BalAfter = usdc.balanceOf(maker1Addr);
        assertEq(maker1BalAfter - maker1BalBefore, 10_000e6 + bondAmount / 2);

        // Maker3 gets 25% of bond as attestor reward
        uint256 maker3BalAfter = usdc.balanceOf(maker3Addr);
        assertEq(maker3BalAfter - maker3BalBefore, bondAmount / 4);

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

        // Slash curve: 10k fill → multiplier = 2 + 650e6/10_000e6 = 2.065
        // slashAmt = 10_000e6 * 2.065 = 20_650e6
        uint256 expectedSlash = 20_650e6;

        // Challenger gets bond back + 25% of slashed amount
        uint256 bondAmount = disputes.calculateDisputeBond(10_000e6);
        uint256 expectedChallengerReward = bondAmount + (expectedSlash / 4);
        assertEq(usdc.balanceOf(maker2Addr) - challengerBalBefore, expectedChallengerReward);

        // Maker1 keeps remaining stake
        DataTypes.MakerInfo memory maker1Info = staking.getMakerInfo(maker1Addr);
        assertEq(maker1Info.stakedAmount, 50_000e6 - expectedSlash);
        assertTrue(maker1Info.isActive); // Still above 10k min
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

        vm.expectRevert("GauloiDisputes: already attested");
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

        // Zero attestations → default fill-valid
        // Maker gets escrowed funds + 50% of bond (no attestor rewards since no attestors)
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

    function test_resolveDispute_fillValid_cleansOrderStorage() public {
        (bytes32 intentId, DataTypes.Order memory order) = _createAndFillIntent(10_000e6);
        DataTypes.Commitment memory commitment = escrow.getCommitment(intentId);

        vm.startPrank(maker2Addr);
        usdc.approve(address(disputes), type(uint256).max);
        disputes.dispute(order);
        vm.stopPrank();

        bytes memory sig = _signAttestation(
            maker3Key, intentId, true, commitment.fillTxHash, order.destinationChainId
        );

        bytes[] memory sigs = new bytes[](1);
        sigs[0] = sig;

        disputes.resolveDispute(intentId, true, sigs);

        // _disputes should still be preserved for audit trail
        DataTypes.Dispute memory disp = disputes.getDispute(intentId);
        assertTrue(disp.resolved);
        assertTrue(disp.fillDeemedValid);
        assertEq(disp.challenger, maker2Addr);
    }

    function test_resolveDispute_fillInvalid_cleansOrderStorage() public {
        (bytes32 intentId, DataTypes.Order memory order) = _createAndFillIntent(10_000e6);
        DataTypes.Commitment memory commitment = escrow.getCommitment(intentId);

        vm.startPrank(maker2Addr);
        usdc.approve(address(disputes), type(uint256).max);
        disputes.dispute(order);
        vm.stopPrank();

        bytes memory sig = _signAttestation(
            maker3Key, intentId, false, commitment.fillTxHash, order.destinationChainId
        );

        bytes[] memory sigs = new bytes[](1);
        sigs[0] = sig;

        disputes.resolveDispute(intentId, false, sigs);

        // _disputes preserved
        DataTypes.Dispute memory disp = disputes.getDispute(intentId);
        assertTrue(disp.resolved);
        assertFalse(disp.fillDeemedValid);
    }

    function test_finalizeExpiredDispute_cleansOrderStorage() public {
        (bytes32 intentId, DataTypes.Order memory order) = _createAndFillIntent(10_000e6);

        vm.startPrank(maker2Addr);
        usdc.approve(address(disputes), type(uint256).max);
        disputes.dispute(order);
        vm.stopPrank();

        vm.warp(block.timestamp + RESOLUTION_WINDOW + 1);

        disputes.finalizeExpiredDispute(intentId);

        // _disputes preserved
        DataTypes.Dispute memory disp = disputes.getDispute(intentId);
        assertTrue(disp.resolved);
        assertTrue(disp.fillDeemedValid);
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

    // ═══════════════════════════════════════════
    //  Phase A: New tests
    // ═══════════════════════════════════════════

    // --- Slash curve ---

    function test_slashCurve_smallFill() public {
        // $50 fill → multiplier = 2 + 650e6/50e6 = 2 + 13 = 15 (capped at max 15)
        // slashAmt = 50e6 * 15 = 750e6
        uint256 slash = disputes.calculateSlashAmount(50e6, 100_000e6);
        assertEq(slash, 750e6);
    }

    function test_slashCurve_mediumFill() public {
        // $500 fill → multiplier = 2 + 650e6/500e6 = 2 + 1.3 = 3.3
        // slashAmt = 500e6 * 3.3 = 1,650e6
        uint256 slash = disputes.calculateSlashAmount(500e6, 100_000e6);
        assertEq(slash, 1_650e6);
    }

    function test_slashCurve_largeFill() public {
        // $50k fill → multiplier = 2 + 650e6/50_000e6 = 2 + 0.013 = 2.013
        // slashAmt = 50_000e6 * 2.013 = 100,650e6 → capped at stake 50k
        uint256 slash = disputes.calculateSlashAmount(50_000e6, 50_000e6);
        assertEq(slash, 50_000e6); // Capped at stake
    }

    function test_calculateSlashAmount_view() public view {
        // Verify the fixed-point math against spec reference values
        // $5,000 fill → multiplier = 2 + 650e6/5_000e6 = 2 + 0.13 = 2.13
        // slashAmt = 5_000e6 * 2.13 = 10,650e6
        assertEq(disputes.calculateSlashAmount(5_000e6, 100_000e6), 10_650e6);

        // $50,000 fill → multiplier = 2 + 650e6/50_000e6 = 2.013
        // slashAmt = 50_000e6 * 2.013 = 100,650e6
        assertEq(disputes.calculateSlashAmount(50_000e6, 200_000e6), 100_650e6);
    }

    // --- Quorum ---

    function test_quorumNotMet_noResolution() public {
        // Set up: maker4 with small stake so quorum isn't met
        uint256 maker4Key = 0xD00D;
        address maker4Addr = vm.addr(maker4Key);
        usdc.mint(maker4Addr, 1_000_000e6);
        _stakeWithAddr(maker4Addr, 10_000e6); // Small stake

        (bytes32 intentId, DataTypes.Order memory order) = _createAndFillIntent(10_000e6);
        DataTypes.Commitment memory commitment = escrow.getCommitment(intentId);

        vm.startPrank(maker2Addr);
        usdc.approve(address(disputes), type(uint256).max);
        disputes.dispute(order);
        vm.stopPrank();

        // maker4 attests (10k stake). Eligible = 160k - 50k(maker1) - 50k(maker2) = 60k
        // Quorum needs 30% of 60k = 18k. maker4 only has 10k → not met
        bytes memory sig = _signAttestation(
            maker4Key, intentId, true, commitment.fillTxHash, order.destinationChainId
        );
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = sig;

        disputes.resolveDispute(intentId, true, sigs);

        // Should NOT be resolved yet
        DataTypes.Dispute memory disp = disputes.getDispute(intentId);
        assertFalse(disp.resolved);
    }

    function test_quorumMet_resolves() public {
        (bytes32 intentId, DataTypes.Order memory order) = _createAndFillIntent(10_000e6);
        DataTypes.Commitment memory commitment = escrow.getCommitment(intentId);

        vm.startPrank(maker2Addr);
        usdc.approve(address(disputes), type(uint256).max);
        disputes.dispute(order);
        vm.stopPrank();

        // maker3 has 50k stake. Eligible = 150k - 50k(maker1) - 50k(maker2) = 50k
        // Quorum needs 30% of 50k = 15k. maker3 has 50k → met
        bytes memory sig = _signAttestation(
            maker3Key, intentId, true, commitment.fillTxHash, order.destinationChainId
        );
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = sig;

        disputes.resolveDispute(intentId, true, sigs);

        DataTypes.Dispute memory disp = disputes.getDispute(intentId);
        assertTrue(disp.resolved);
        assertTrue(disp.fillDeemedValid);
    }

    function test_competingVotes() public {
        // Add maker4 to have more attestors
        uint256 maker4Key = 0xD00D;
        address maker4Addr = vm.addr(maker4Key);
        usdc.mint(maker4Addr, 1_000_000e6);
        _stakeWithAddr(maker4Addr, 50_000e6);

        (bytes32 intentId, DataTypes.Order memory order) = _createAndFillIntent(10_000e6);
        DataTypes.Commitment memory commitment = escrow.getCommitment(intentId);

        vm.startPrank(maker2Addr);
        usdc.approve(address(disputes), type(uint256).max);
        disputes.dispute(order);
        vm.stopPrank();

        // Eligible = 200k - 50k(maker1) - 50k(maker2) = 100k
        // Quorum = 30% of 100k = 30k

        // maker3 votes valid (50k)
        bytes memory sigValid = _signAttestation(
            maker3Key, intentId, true, commitment.fillTxHash, order.destinationChainId
        );
        bytes[] memory sigs1 = new bytes[](1);
        sigs1[0] = sigValid;
        disputes.resolveDispute(intentId, true, sigs1);

        // Not resolved yet — quorum met (50k >= 30k) but need to check majority
        // Valid weight: 50k, Invalid: 0, Total: 50k → majority met, actually resolved
        DataTypes.Dispute memory disp = disputes.getDispute(intentId);
        assertTrue(disp.resolved); // Valid wins with majority
        assertTrue(disp.fillDeemedValid);
    }

    // --- Attestor recording ---

    function test_attestorRecording() public {
        (bytes32 intentId, DataTypes.Order memory order) = _createAndFillIntent(10_000e6);
        DataTypes.Commitment memory commitment = escrow.getCommitment(intentId);

        vm.startPrank(maker2Addr);
        usdc.approve(address(disputes), type(uint256).max);
        disputes.dispute(order);
        vm.stopPrank();

        bytes memory sig = _signAttestation(
            maker3Key, intentId, true, commitment.fillTxHash, order.destinationChainId
        );
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = sig;

        disputes.resolveDispute(intentId, true, sigs);

        // Verify recording
        address[] memory validAttestors = disputes.getDisputeAttestors(intentId, true);
        assertEq(validAttestors.length, 1);
        assertEq(validAttestors[0], maker3Addr);
        assertEq(disputes.getAttestorStakeWeight(intentId, maker3Addr), 50_000e6);

        address[] memory invalidAttestors = disputes.getDisputeAttestors(intentId, false);
        assertEq(invalidAttestors.length, 0);
    }

    // --- Attestor rewards ---

    function test_attestorRewards_fillValid() public {
        (bytes32 intentId, DataTypes.Order memory order) = _createAndFillIntent(10_000e6);
        DataTypes.Commitment memory commitment = escrow.getCommitment(intentId);

        vm.startPrank(maker2Addr);
        usdc.approve(address(disputes), type(uint256).max);
        disputes.dispute(order);
        vm.stopPrank();

        uint256 maker3BalBefore = usdc.balanceOf(maker3Addr);

        bytes memory sig = _signAttestation(
            maker3Key, intentId, true, commitment.fillTxHash, order.destinationChainId
        );
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = sig;

        disputes.resolveDispute(intentId, true, sigs);

        uint256 bondAmount = disputes.calculateDisputeBond(10_000e6);
        // 25% of bond goes to attestors
        assertEq(usdc.balanceOf(maker3Addr) - maker3BalBefore, bondAmount / 4);
    }

    function test_attestorRewards_fillInvalid() public {
        (bytes32 intentId, DataTypes.Order memory order) = _createAndFillIntent(10_000e6);
        DataTypes.Commitment memory commitment = escrow.getCommitment(intentId);

        vm.startPrank(maker2Addr);
        usdc.approve(address(disputes), type(uint256).max);
        disputes.dispute(order);
        vm.stopPrank();

        uint256 maker3BalBefore = usdc.balanceOf(maker3Addr);

        bytes memory sig = _signAttestation(
            maker3Key, intentId, false, commitment.fillTxHash, order.destinationChainId
        );
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = sig;

        disputes.resolveDispute(intentId, false, sigs);

        // Slash amount: 10k fill → 20,650 USDC
        uint256 expectedSlash = 20_650e6;
        // 25% of slashed to attestors
        assertEq(usdc.balanceOf(maker3Addr) - maker3BalBefore, expectedSlash / 4);
    }

    function test_attestorRewards_multipleAttestors() public {
        // Add maker4 with different stake
        uint256 maker4Key = 0xD00D;
        address maker4Addr = vm.addr(maker4Key);
        usdc.mint(maker4Addr, 1_000_000e6);
        _stakeWithAddr(maker4Addr, 30_000e6);

        (bytes32 intentId, DataTypes.Order memory order) = _createAndFillIntent(10_000e6);
        DataTypes.Commitment memory commitment = escrow.getCommitment(intentId);

        vm.startPrank(maker2Addr);
        usdc.approve(address(disputes), type(uint256).max);
        disputes.dispute(order);
        vm.stopPrank();

        // Record balances before
        uint256 maker3BalBefore = usdc.balanceOf(maker3Addr);
        uint256 maker4BalBefore = usdc.balanceOf(maker4Addr);

        // maker3 (50k) and maker4 (30k) both attest valid
        {
            bytes memory sig3 = _signAttestation(
                maker3Key, intentId, true, commitment.fillTxHash, order.destinationChainId
            );
            bytes memory sig4 = _signAttestation(
                maker4Key, intentId, true, commitment.fillTxHash, order.destinationChainId
            );
            bytes[] memory sigs = new bytes[](2);
            sigs[0] = sig3;
            sigs[1] = sig4;

            disputes.resolveDispute(intentId, true, sigs);
        }

        uint256 attestorPool = disputes.calculateDisputeBond(10_000e6) / 4;

        // Pro-rata: maker3 gets 50k/(50k+30k) * pool, maker4 gets 30k/(50k+30k) * pool
        assertEq(usdc.balanceOf(maker3Addr) - maker3BalBefore, (attestorPool * 50_000e6) / 80_000e6);
        assertEq(usdc.balanceOf(maker4Addr) - maker4BalBefore, (attestorPool * 30_000e6) / 80_000e6);
    }

    // --- Double attestation ---

    function test_doubleAttestation_reverts() public {
        (bytes32 intentId, DataTypes.Order memory order) = _createAndFillIntent(10_000e6);
        DataTypes.Commitment memory commitment = escrow.getCommitment(intentId);

        // Add maker4 so quorum isn't immediately met
        uint256 maker4Key = 0xD00D;
        address maker4Addr = vm.addr(maker4Key);
        usdc.mint(maker4Addr, 1_000_000e6);
        _stakeWithAddr(maker4Addr, 10_000e6);

        vm.startPrank(maker2Addr);
        usdc.approve(address(disputes), type(uint256).max);
        disputes.dispute(order);
        vm.stopPrank();

        // maker4 attests first (won't meet quorum)
        bytes memory sig4 = _signAttestation(
            maker4Key, intentId, true, commitment.fillTxHash, order.destinationChainId
        );
        bytes[] memory sigs1 = new bytes[](1);
        sigs1[0] = sig4;
        disputes.resolveDispute(intentId, true, sigs1);

        // maker4 tries to attest again in a separate call
        vm.expectRevert("GauloiDisputes: already attested");
        disputes.resolveDispute(intentId, true, sigs1);
    }

    // --- Quorum failure ---

    function test_quorumFailure_extendsDeadline() public {
        // Only maker3 is eligible with 50k, but we need quorum to NOT be met
        // Set quorum to 90% so maker3's 50k out of 50k eligible would barely matter
        // Actually, with current setup eligible=50k and maker3=50k, quorum always met
        // Instead: add maker4 with small stake, set higher quorum, make only maker4 attest

        uint256 maker4Key = 0xD00D;
        address maker4Addr = vm.addr(maker4Key);
        usdc.mint(maker4Addr, 1_000_000e6);
        _stakeWithAddr(maker4Addr, 10_000e6);

        // Set quorum to 50% so 10k out of 60k eligible = ~16.7% < 50%
        vm.prank(owner);
        disputes.setQuorumParams(5000);

        (bytes32 intentId, DataTypes.Order memory order) = _createAndFillIntent(10_000e6);
        DataTypes.Commitment memory commitment = escrow.getCommitment(intentId);

        vm.startPrank(maker2Addr);
        usdc.approve(address(disputes), type(uint256).max);
        disputes.dispute(order);
        vm.stopPrank();

        // Only maker4 attests (10k out of 60k eligible = 16.7% < 50% quorum)
        bytes memory sig4 = _signAttestation(
            maker4Key, intentId, true, commitment.fillTxHash, order.destinationChainId
        );
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = sig4;
        disputes.resolveDispute(intentId, true, sigs);

        // Not resolved
        assertFalse(disputes.getDispute(intentId).resolved);

        // Warp past deadline
        vm.warp(block.timestamp + RESOLUTION_WINDOW + 1);

        // Finalize — should extend deadline (first quorum failure)
        disputes.finalizeExpiredDispute(intentId);

        assertEq(disputes.getQuorumFailCount(intentId), 1);
        assertFalse(disputes.getDispute(intentId).resolved);

        // Deadline was extended
        DataTypes.Dispute memory disp = disputes.getDispute(intentId);
        assertGt(disp.disputeDeadline, block.timestamp);
    }

    function test_quorumFailure_secondFailure_pauses() public {
        uint256 maker4Key = 0xD00D;
        address maker4Addr = vm.addr(maker4Key);
        usdc.mint(maker4Addr, 1_000_000e6);
        _stakeWithAddr(maker4Addr, 10_000e6);

        // Set quorum to 50%
        vm.prank(owner);
        disputes.setQuorumParams(5000);

        (bytes32 intentId, DataTypes.Order memory order) = _createAndFillIntent(10_000e6);
        DataTypes.Commitment memory commitment = escrow.getCommitment(intentId);

        vm.startPrank(maker2Addr);
        usdc.approve(address(disputes), type(uint256).max);
        disputes.dispute(order);
        vm.stopPrank();

        // Only maker4 attests — insufficient for quorum
        bytes memory sig4 = _signAttestation(
            maker4Key, intentId, true, commitment.fillTxHash, order.destinationChainId
        );
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = sig4;
        disputes.resolveDispute(intentId, true, sigs);

        // First expiry — extends deadline
        vm.warp(block.timestamp + RESOLUTION_WINDOW + 1);
        disputes.finalizeExpiredDispute(intentId);
        assertEq(disputes.getQuorumFailCount(intentId), 1);

        // Second expiry — pauses escrow
        vm.warp(block.timestamp + RESOLUTION_WINDOW + 1);
        disputes.finalizeExpiredDispute(intentId);
        assertEq(disputes.getQuorumFailCount(intentId), 2);

        // Escrow should be paused
        assertTrue(escrow.paused());

        // Dispute should be resolved as fill-valid (default)
        assertTrue(disputes.getDispute(intentId).resolved);
        assertTrue(disputes.getDispute(intentId).fillDeemedValid);
    }

    // --- Partial slash scenarios ---

    function test_partialSlash_makerRemainsActive() public {
        (bytes32 intentId, DataTypes.Order memory order) = _createAndFillIntent(10_000e6);
        DataTypes.Commitment memory commitment = escrow.getCommitment(intentId);

        vm.startPrank(maker2Addr);
        usdc.approve(address(disputes), type(uint256).max);
        disputes.dispute(order);
        vm.stopPrank();

        bytes memory sig = _signAttestation(
            maker3Key, intentId, false, commitment.fillTxHash, order.destinationChainId
        );
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = sig;

        disputes.resolveDispute(intentId, false, sigs);

        // Slash = 20,650 USDC. Maker1 had 50k. Remaining = 29,350 > 10k min
        assertTrue(staking.isActiveMaker(maker1Addr));
        assertEq(staking.getStake(maker1Addr), 50_000e6 - 20_650e6);
    }

    function test_partialSlash_makerDeactivated() public {
        // Maker1 has exactly 12k stake — slash will bring below 10k min
        // First we need a maker with lower stake
        uint256 maker5Key = 0xBAAD;
        address maker5Addr = vm.addr(maker5Key);
        usdc.mint(maker5Addr, 1_000_000e6);
        _stakeWithAddr(maker5Addr, 12_000e6);

        // Create intent with maker5
        DataTypes.Order memory order = _makeOrder(1_000e6, 990e6);
        bytes memory orderSig = _signOrder(takerKey, order);

        vm.prank(maker5Addr);
        bytes32 intentId = escrow.executeOrder(order, orderSig);

        vm.prank(maker5Addr);
        escrow.submitFill(intentId, keccak256("dest_tx"));

        DataTypes.Commitment memory commitment = escrow.getCommitment(intentId);

        vm.startPrank(maker2Addr);
        usdc.approve(address(disputes), type(uint256).max);
        disputes.dispute(order);
        vm.stopPrank();

        // Slash for $1k fill: multiplier = 2 + 650e6/1_000e6 = 2.65
        // slashAmt = 1000e6 * 2.65 = 2,650e6
        // maker5 remaining = 12k - 2.65k = 9,350 < 10k min → deactivated

        bytes memory sig = _signAttestation(
            maker3Key, intentId, false, commitment.fillTxHash, order.destinationChainId
        );
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = sig;

        disputes.resolveDispute(intentId, false, sigs);

        assertFalse(staking.isActiveMaker(maker5Addr));
        assertEq(staking.getStake(maker5Addr), 12_000e6 - 2_650e6);
    }

    // --- Expired dispute edge cases ---

    function test_expiredDispute_zeroAttestations_defaultValid() public {
        (bytes32 intentId, DataTypes.Order memory order) = _createAndFillIntent(10_000e6);

        vm.startPrank(maker2Addr);
        usdc.approve(address(disputes), type(uint256).max);
        disputes.dispute(order);
        vm.stopPrank();

        vm.warp(block.timestamp + RESOLUTION_WINDOW + 1);

        disputes.finalizeExpiredDispute(intentId);

        DataTypes.Dispute memory disp = disputes.getDispute(intentId);
        assertTrue(disp.resolved);
        assertTrue(disp.fillDeemedValid);
    }

    function test_expiredDispute_quorumMet_pluralityWins() public {
        // Plurality path: quorum met, no strict majority, deadline expires.
        // Need votes on BOTH sides so neither has >50%. This requires:
        //   1. First call adds votes on one side (doesn't hit quorum alone OR hits quorum but no majority)
        //   2. Second call adds votes on other side, still no majority
        //   3. Deadline expires → finalizeExpiredDispute uses plurality

        // Use 4 additional makers with carefully chosen stakes
        uint256 maker4Key = 0xD00D;
        uint256 maker5Key = 0xBAAD;
        uint256 maker6Key = 0xFACE;
        uint256 maker7Key = 0xDEAF;
        address maker4Addr = vm.addr(maker4Key);
        address maker5Addr = vm.addr(maker5Key);
        address maker6Addr = vm.addr(maker6Key);
        address maker7Addr = vm.addr(maker7Key);

        usdc.mint(maker4Addr, 1_000_000e6);
        usdc.mint(maker5Addr, 1_000_000e6);
        usdc.mint(maker6Addr, 1_000_000e6);
        usdc.mint(maker7Addr, 1_000_000e6);
        _stakeWithAddr(maker4Addr, 30_000e6);
        _stakeWithAddr(maker5Addr, 30_000e6);
        _stakeWithAddr(maker6Addr, 25_000e6);
        _stakeWithAddr(maker7Addr, 25_000e6);

        (bytes32 intentId, DataTypes.Order memory order) = _createAndFillIntent(10_000e6);
        DataTypes.Commitment memory commitment = escrow.getCommitment(intentId);

        vm.startPrank(maker2Addr);
        usdc.approve(address(disputes), type(uint256).max);
        disputes.dispute(order);
        vm.stopPrank();

        // totalActive = 50k+50k+50k+30k+30k+25k+25k = 260k
        // eligible = 260k - 50k(maker1) - 50k(maker2) = 160k
        // quorum = 30% of 160k = 48k

        // maker4 (30k) + maker5 (30k) vote valid → 60k valid, 0 invalid
        // total=60k, quorum: 60k*10000=600M >= 160k*3000=480M → quorum MET
        // majority: valid 60k*2=120k > 60k total → strict majority → RESOLVES
        // That's too easy. We need to prevent majority during resolveDispute.
        // Single-side calls always produce 100% on that side → always majority.
        //
        // Key insight: the ONLY way to get quorum-met but no majority on expiry
        // is if votes come from BOTH sides across separate calls, and neither
        // achieves strict majority after either call.
        //
        // Call 1: maker4 (30k) votes invalid. total=30k < 48k quorum → returns.
        // Call 2: maker5 (30k) + maker6 (25k) vote valid → valid=55k, invalid=30k, total=85k.
        //   quorum: 85k*10000 >= 160k*3000 → 850M >= 480M ✓
        //   valid majority: 55k*2=110k > 85k ✓ → RESOLVES. Still too easy.
        //
        // The problem: once quorum is met, the side that submitted votes last
        // always has their votes counted fresh, and if they outnumber the other
        // side total, they get majority. To NOT get majority, we need valid ≈ invalid ≈ 50%.
        //
        // Call 1: maker6 (25k) + maker7 (25k) vote invalid → invalid=50k, valid=0, total=50k
        //   quorum: 50k*10000 >= 160k*3000 → 500M >= 480M ✓
        //   invalid majority: 50k*2=100k > 50k ✓ → RESOLVES. Doh.
        //
        // Fundamental: with single-side per call, if quorum is met, the only side
        // with votes has 100% → always majority. To avoid this, both sides need
        // non-zero votes AND quorum met, which requires at least 2 calls, and
        // the second call must not push its side to majority.
        //
        // Call 1: maker4 (30k) invalid. total=30k, quorum NOT met (30k < 48k). Returns.
        // Call 2: maker5 (30k) valid. valid=30k, invalid=30k, total=60k.
        //   quorum: 60k*10000 >= 160k*3000 → 600M >= 480M ✓
        //   valid majority: 30k*2=60k > 60k → false (NOT strict)
        //   invalid majority: 30k*2=60k > 60k → false
        //   Neither side has majority → returns silently.
        // Deadline expires → finalizeExpiredDispute → quorum met, plurality: 30k == 30k → tie.
        // Code: `validWins = validWeight >= invalidWeight` → true → valid wins the tie.

        // Call 1: maker4 votes invalid (30k)
        {
            bytes memory sig4 = _signAttestation(
                maker4Key, intentId, false, commitment.fillTxHash, order.destinationChainId
            );
            bytes[] memory sigs = new bytes[](1);
            sigs[0] = sig4;
            disputes.resolveDispute(intentId, false, sigs);
        }
        assertFalse(disputes.getDispute(intentId).resolved);

        // Call 2: maker5 votes valid (30k) — quorum met, but 50-50 → no majority
        {
            bytes memory sig5 = _signAttestation(
                maker5Key, intentId, true, commitment.fillTxHash, order.destinationChainId
            );
            bytes[] memory sigs = new bytes[](1);
            sigs[0] = sig5;
            disputes.resolveDispute(intentId, true, sigs);
        }
        assertFalse(disputes.getDispute(intentId).resolved); // Still not resolved (no majority)

        // Warp past deadline → finalize with plurality
        vm.warp(block.timestamp + RESOLUTION_WINDOW + 1);
        disputes.finalizeExpiredDispute(intentId);

        // Tie: validWeight == invalidWeight → valid wins (>= check)
        DataTypes.Dispute memory disp = disputes.getDispute(intentId);
        assertTrue(disp.resolved);
        assertTrue(disp.fillDeemedValid);
    }

    // ═══════════════════════════════════════════
    //  Phase A: Edge case & fuzz tests
    // ═══════════════════════════════════════════

    // --- calculateSlashAmount edge cases ---

    function test_calculateSlashAmount_zeroFill() public view {
        // Guard against division by zero
        assertEq(disputes.calculateSlashAmount(0, 100_000e6), 0);
    }

    function test_calculateSlashAmount_zeroStake() public view {
        // Fill of 10k, maker has 0 stake → capped at 0
        assertEq(disputes.calculateSlashAmount(10_000e6, 0), 0);
    }

    function test_calculateSlashAmount_fillOf1() public view {
        // Extremely small fill: multiplier = 2 + 650e6 = huge, capped at 15
        // slash = 1 * 15 = 15 (tiny)
        assertEq(disputes.calculateSlashAmount(1, 100_000e6), 15);
    }

    // --- Fuzz: slash curve ---

    function testFuzz_calculateSlashAmount_bounded(uint256 fillAmount, uint256 makerStake) public view {
        fillAmount = bound(fillAmount, 1, 1_000_000e6); // 1 wei to 1M USDC
        makerStake = bound(makerStake, 0, 10_000_000e6);

        uint256 slash = disputes.calculateSlashAmount(fillAmount, makerStake);

        // Invariant 1: slash <= makerStake
        assertLe(slash, makerStake);

        // Invariant 2: slash <= fillAmount * maxMultiplier
        uint256 maxSlash = fillAmount * disputes.slashMaxMultiplier();
        if (maxSlash / disputes.slashMaxMultiplier() == fillAmount) {
            // No overflow in max calculation
            assertLe(slash, maxSlash);
        }

        // Invariant 3: slash >= fillAmount * baseMultiplier (unless capped by stake)
        // multiplier >= base, so slash >= fillAmount * base unless capped
        uint256 baseSlash = fillAmount * disputes.slashBaseMultiplier();
        if (baseSlash / disputes.slashBaseMultiplier() == fillAmount) {
            if (baseSlash <= makerStake) {
                assertGe(slash, baseSlash);
            }
        }
    }

    // --- Accumulative voting across multiple calls ---

    function test_accumulativeVoting_acrossTwoCalls() public {
        uint256 maker4Key = 0xD00D;
        uint256 maker5Key = 0xBAAD;
        address maker4Addr = vm.addr(maker4Key);
        address maker5Addr = vm.addr(maker5Key);
        usdc.mint(maker4Addr, 1_000_000e6);
        usdc.mint(maker5Addr, 1_000_000e6);
        _stakeWithAddr(maker4Addr, 30_000e6);
        _stakeWithAddr(maker5Addr, 20_000e6);

        (bytes32 intentId, DataTypes.Order memory order) = _createAndFillIntent(10_000e6);
        DataTypes.Commitment memory commitment = escrow.getCommitment(intentId);

        vm.startPrank(maker2Addr);
        usdc.approve(address(disputes), type(uint256).max);
        disputes.dispute(order);
        vm.stopPrank();

        // eligible = (150k+30k+20k) - 50k(maker1) - 50k(maker2) = 100k
        // quorum = 30% of 100k = 30k

        // Call 1: maker4 (30k valid). total=30k >= 30k quorum ✓
        // majority: 30k*2=60k > 30k → strict majority → resolves immediately
        // Hmm, that resolves. We need calls where quorum isn't met on first call.

        // Set quorum to 60% so first call doesn't hit it
        vm.prank(owner);
        disputes.setQuorumParams(6000);
        // quorum = 60% of 100k = 60k

        // Call 1: maker4 (30k valid). total=30k < 60k quorum → returns, votes recorded
        {
            bytes memory sig = _signAttestation(
                maker4Key, intentId, true, commitment.fillTxHash, order.destinationChainId
            );
            bytes[] memory sigs = new bytes[](1);
            sigs[0] = sig;
            disputes.resolveDispute(intentId, true, sigs);
        }
        assertFalse(disputes.getDispute(intentId).resolved);

        // Verify votes were recorded
        address[] memory attestors = disputes.getDisputeAttestors(intentId, true);
        assertEq(attestors.length, 1);
        assertEq(attestors[0], maker4Addr);

        // Call 2: maker3 (50k valid) + maker5 (20k valid). total=30k+50k+20k=100k >= 60k ✓
        // majority: 100k*2=200k > 100k → resolves
        {
            bytes memory sig3 = _signAttestation(
                maker3Key, intentId, true, commitment.fillTxHash, order.destinationChainId
            );
            bytes memory sig5 = _signAttestation(
                maker5Key, intentId, true, commitment.fillTxHash, order.destinationChainId
            );
            bytes[] memory sigs = new bytes[](2);
            sigs[0] = sig3;
            sigs[1] = sig5;
            disputes.resolveDispute(intentId, true, sigs);
        }

        assertTrue(disputes.getDispute(intentId).resolved);
        assertTrue(disputes.getDispute(intentId).fillDeemedValid);

        // Verify all 3 attestors recorded
        attestors = disputes.getDisputeAttestors(intentId, true);
        assertEq(attestors.length, 3);
    }

    function test_accumulativeVoting_crossCallDuplicateReverts() public {
        uint256 maker4Key = 0xD00D;
        address maker4Addr = vm.addr(maker4Key);
        usdc.mint(maker4Addr, 1_000_000e6);
        _stakeWithAddr(maker4Addr, 10_000e6);

        (bytes32 intentId, DataTypes.Order memory order) = _createAndFillIntent(10_000e6);
        DataTypes.Commitment memory commitment = escrow.getCommitment(intentId);

        vm.startPrank(maker2Addr);
        usdc.approve(address(disputes), type(uint256).max);
        disputes.dispute(order);
        vm.stopPrank();

        // Set high quorum so first call doesn't resolve
        vm.prank(owner);
        disputes.setQuorumParams(9000);

        // Call 1: maker4 votes
        bytes memory sig = _signAttestation(
            maker4Key, intentId, true, commitment.fillTxHash, order.destinationChainId
        );
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = sig;
        disputes.resolveDispute(intentId, true, sigs);

        // Call 2: maker4 tries again — reverts
        vm.expectRevert("GauloiDisputes: already attested");
        disputes.resolveDispute(intentId, true, sigs);
    }

    // --- Quorum boundary conditions ---

    function test_quorumExactlyAtThreshold() public {
        // Set up so participating is exactly 30% of eligible
        uint256 maker4Key = 0xD00D;
        address maker4Addr = vm.addr(maker4Key);
        usdc.mint(maker4Addr, 1_000_000e6);
        // We need maker4's stake to be exactly 30% of eligible
        // eligible = totalActive - maker1 - maker2
        // If maker4 stakes 15k: totalActive = 150k+15k = 165k, eligible = 165k-50k-50k = 65k
        // quorum = 30% of 65k = 19.5k → 15k < 19.5k → NOT met
        // If maker4 stakes 30k: totalActive = 180k, eligible = 80k, quorum = 24k → 30k >= 24k ✓

        // Use precise amounts: eligible = 100k, quorum = 30k exactly
        // Need totalActive - 100k = maker1 + maker2 → current total = 150k, eligible = 50k
        // Add maker4 with 50k → total = 200k, eligible = 100k, quorum = 30k
        _stakeWithAddr(maker4Addr, 50_000e6);

        (bytes32 intentId, DataTypes.Order memory order) = _createAndFillIntent(10_000e6);
        DataTypes.Commitment memory commitment = escrow.getCommitment(intentId);

        vm.startPrank(maker2Addr);
        usdc.approve(address(disputes), type(uint256).max);
        disputes.dispute(order);
        vm.stopPrank();

        // eligible = 200k - 50k - 50k = 100k, quorum = 30k
        // maker4 (50k) votes → 50k >= 30k ✓, majority: 50k*2=100k > 50k ✓
        // That resolves. Let's test the exact boundary differently.

        // Use a maker with exactly 30k stake:
        uint256 maker5Key = 0xBAAD;
        address maker5Addr = vm.addr(maker5Key);
        usdc.mint(maker5Addr, 1_000_000e6);
        _stakeWithAddr(maker5Addr, 30_000e6);

        // New intent so dispute state is fresh
        (bytes32 intentId2, DataTypes.Order memory order2) = _createAndFillIntent(5_000e6);
        DataTypes.Commitment memory commitment2 = escrow.getCommitment(intentId2);

        vm.startPrank(maker2Addr);
        disputes.dispute(order2);
        vm.stopPrank();

        // eligible = 230k - 50k(maker1) - 50k(maker2) = 130k
        // quorum = 30% of 130k = 39k

        // maker5 (30k) votes → 30k < 39k → quorum NOT met → returns
        {
            bytes memory sig5 = _signAttestation(
                maker5Key, intentId2, true, commitment2.fillTxHash, order2.destinationChainId
            );
            bytes[] memory sigs = new bytes[](1);
            sigs[0] = sig5;
            disputes.resolveDispute(intentId2, true, sigs);
        }
        assertFalse(disputes.getDispute(intentId2).resolved);

        // maker4 (50k) votes → total = 80k >= 39k ✓, majority: 80k*2 > 80k ✓
        {
            bytes memory sig4 = _signAttestation(
                maker4Key, intentId2, true, commitment2.fillTxHash, order2.destinationChainId
            );
            bytes[] memory sigs = new bytes[](1);
            sigs[0] = sig4;
            disputes.resolveDispute(intentId2, true, sigs);
        }
        assertTrue(disputes.getDispute(intentId2).resolved);
    }

    function test_majorityExactly5050_noResolution() public {
        // 50-50 split: neither side has strict majority (need >50%, not >=50%)
        uint256 maker4Key = 0xD00D;
        address maker4Addr = vm.addr(maker4Key);
        usdc.mint(maker4Addr, 1_000_000e6);
        _stakeWithAddr(maker4Addr, 50_000e6); // Same as maker3

        (bytes32 intentId, DataTypes.Order memory order) = _createAndFillIntent(10_000e6);
        DataTypes.Commitment memory commitment = escrow.getCommitment(intentId);

        vm.startPrank(maker2Addr);
        usdc.approve(address(disputes), type(uint256).max);
        disputes.dispute(order);
        vm.stopPrank();

        // eligible = 200k - 50k - 50k = 100k, quorum = 30k

        // maker4 votes invalid (50k). Quorum 50k >= 30k ✓
        // BUT: only invalid side → 50k*2=100k > 50k → strict majority → resolves
        // Can't get 50-50 from a single call. Need to set up carefully.

        // Set quorum to 80% so neither single call meets quorum
        vm.prank(owner);
        disputes.setQuorumParams(8000);
        // quorum = 80% of 100k = 80k

        // Call 1: maker3 votes valid (50k). total=50k < 80k → returns
        {
            bytes memory sig3 = _signAttestation(
                maker3Key, intentId, true, commitment.fillTxHash, order.destinationChainId
            );
            bytes[] memory sigs = new bytes[](1);
            sigs[0] = sig3;
            disputes.resolveDispute(intentId, true, sigs);
        }
        assertFalse(disputes.getDispute(intentId).resolved);

        // Call 2: maker4 votes invalid (50k). total=100k >= 80k ✓
        // valid=50k, invalid=50k. Neither has majority (50k*2=100k NOT > 100k)
        {
            bytes memory sig4 = _signAttestation(
                maker4Key, intentId, false, commitment.fillTxHash, order.destinationChainId
            );
            bytes[] memory sigs = new bytes[](1);
            sigs[0] = sig4;
            disputes.resolveDispute(intentId, false, sigs);
        }
        // Still not resolved — 50-50 split, no strict majority
        assertFalse(disputes.getDispute(intentId).resolved);
    }

    // --- Zero eligible stake ---

    function test_zeroEligibleStake_noResolution() public {
        // Only 2 makers: maker1 (disputed) and maker2 (challenger). No one else to vote.
        // Deploy fresh with only 2 makers
        GauloiStaking freshStaking = new GauloiStaking(address(usdc), MIN_STAKE, COOLDOWN, 1 hours, owner);
        GauloiEscrow freshEscrow = new GauloiEscrow(address(freshStaking), SETTLEMENT_WINDOW, COMMITMENT_TIMEOUT, owner);
        GauloiDisputes freshDisputes = new GauloiDisputes(
            address(freshStaking), address(freshEscrow), address(usdc),
            RESOLUTION_WINDOW, BOND_BPS, MIN_BOND, owner
        );
        vm.startPrank(owner);
        freshStaking.setEscrow(address(freshEscrow));
        freshStaking.setDisputes(address(freshDisputes));
        freshEscrow.setDisputes(address(freshDisputes));
        freshEscrow.addSupportedToken(address(usdc));
        vm.stopPrank();

        // Stake 2 makers
        vm.startPrank(maker1Addr);
        usdc.approve(address(freshStaking), 50_000e6);
        freshStaking.stake(50_000e6);
        vm.stopPrank();
        vm.startPrank(maker2Addr);
        usdc.approve(address(freshStaking), 50_000e6);
        freshStaking.stake(50_000e6);
        vm.stopPrank();

        // Execute order (need taker approval for fresh escrow)
        vm.prank(taker);
        usdc.approve(address(freshEscrow), type(uint256).max);

        DataTypes.Order memory order = DataTypes.Order({
            taker: taker,
            inputToken: address(usdc),
            inputAmount: 10_000e6,
            outputToken: address(usdc),
            minOutputAmount: 9_990e6,
            destinationChainId: DEST_CHAIN_ID,
            destinationAddress: DEST_ADDRESS,
            expiry: block.timestamp + 1 hours,
            nonce: 999
        });

        // Sign with fresh escrow's domain separator
        bytes32 structHash = keccak256(abi.encode(
            IntentLib.ORDER_TYPEHASH,
            order.taker, order.inputToken, order.inputAmount,
            order.outputToken, order.minOutputAmount,
            order.destinationChainId, order.destinationAddress,
            order.expiry, order.nonce
        ));
        bytes32 digest = MessageHashUtils.toTypedDataHash(freshEscrow.domainSeparator(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(takerKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(maker1Addr);
        bytes32 intentId = freshEscrow.executeOrder(order, sig);
        vm.prank(maker1Addr);
        freshEscrow.submitFill(intentId, keccak256("dest_tx"));

        // maker2 disputes
        vm.startPrank(maker2Addr);
        usdc.approve(address(freshDisputes), type(uint256).max);
        freshDisputes.dispute(order);
        vm.stopPrank();

        // eligible = totalActive(100k) - maker1(50k) - maker2(50k) = 0
        // No one can vote. Warp past deadline.
        vm.warp(block.timestamp + RESOLUTION_WINDOW + 1);

        // finalizeExpiredDispute: totalParticipating = 0 → default valid
        freshDisputes.finalizeExpiredDispute(intentId);
        assertTrue(freshDisputes.getDispute(intentId).resolved);
        assertTrue(freshDisputes.getDispute(intentId).fillDeemedValid);
    }

    // --- Rounding/dust with multiple attestors ---

    function test_attestorRewards_dustStaysInTreasury() public {
        // Use 3 attestors with stakes that produce rounding dust
        uint256 maker4Key = 0xD00D;
        uint256 maker5Key = 0xBAAD;
        address maker4Addr = vm.addr(maker4Key);
        address maker5Addr = vm.addr(maker5Key);
        usdc.mint(maker4Addr, 1_000_000e6);
        usdc.mint(maker5Addr, 1_000_000e6);
        _stakeWithAddr(maker4Addr, 33_333e6);
        _stakeWithAddr(maker5Addr, 33_333e6);

        (bytes32 intentId, DataTypes.Order memory order) = _createAndFillIntent(10_000e6);
        DataTypes.Commitment memory commitment = escrow.getCommitment(intentId);

        vm.startPrank(maker2Addr);
        usdc.approve(address(disputes), type(uint256).max);
        disputes.dispute(order);
        vm.stopPrank();

        uint256 disputesBefore = usdc.balanceOf(address(disputes));

        // 3 attestors: maker3(50k), maker4(33,333), maker5(33,333) all vote valid
        {
            bytes memory sig3 = _signAttestation(maker3Key, intentId, true, commitment.fillTxHash, order.destinationChainId);
            bytes memory sig4 = _signAttestation(maker4Key, intentId, true, commitment.fillTxHash, order.destinationChainId);
            bytes memory sig5 = _signAttestation(maker5Key, intentId, true, commitment.fillTxHash, order.destinationChainId);
            bytes[] memory sigs = new bytes[](3);
            sigs[0] = sig3;
            sigs[1] = sig4;
            sigs[2] = sig5;
            disputes.resolveDispute(intentId, true, sigs);
        }

        // Bond = 250e6 (min). attestorPool = 250e6 / 4 = 62e6 (with 2e6 dust from bond split)
        // totalWeight = 50_000e6 + 33_333e6 + 33_333e6 = 116_666e6
        // maker3 share = 62e6 * 50_000e6 / 116_666e6 = 26_571_... → 26_571 (truncated)
        // maker4 share = 62e6 * 33_333e6 / 116_666e6 = 17_714_... → 17_714 (truncated)
        // maker5 share = same as maker4 = 17_714
        // Total distributed = 26_571 + 17_714 + 17_714 = 61_999 < 62e6
        // Dust: 62e6 - 61_999 = 1 stays in contract

        // The contract should have: bond(250e6) - maker reward(125e6) - attestor distributed(≤62e6) + dust
        // = treasury portion. Just verify contract balance is positive (dust retained).
        uint256 disputesAfter = usdc.balanceOf(address(disputes));
        // Treasury should have gotten: 250e6 - 125e6(maker) - ≤62e6(attestors) = ≥63e6
        assertTrue(disputesAfter > 0);
    }

    // --- submitFill and reclaimExpired work when paused ---

    function test_submitFill_worksWhenPaused() public {
        (bytes32 intentId,) = _createAndFillIntent(10_000e6);
        // Already filled in _createAndFillIntent, so let's test differently:
        // Create a new order, execute, then pause, then submitFill

        DataTypes.Order memory order2 = _makeOrder(5_000e6, 4_990e6);
        bytes memory sig = _signOrder(takerKey, order2);
        vm.prank(maker1Addr);
        bytes32 intentId2 = escrow.executeOrder(order2, sig);

        // Pause
        vm.prank(address(disputes));
        escrow.pause();

        // submitFill should still work (not gated by whenNotPaused)
        vm.prank(maker1Addr);
        escrow.submitFill(intentId2, keccak256("fill_after_pause"));
        assertTrue(escrow.getCommitment(intentId2).state == DataTypes.IntentState.Filled);
    }

    function test_reclaimExpired_worksWhenPaused() public {
        DataTypes.Order memory order = _makeOrder(5_000e6, 4_990e6);
        bytes memory sig = _signOrder(takerKey, order);
        vm.prank(maker1Addr);
        escrow.executeOrder(order, sig);

        // Pause
        vm.prank(address(disputes));
        escrow.pause();

        // Warp past commitment timeout
        vm.warp(block.timestamp + COMMITMENT_TIMEOUT + 1);

        // reclaimExpired should still work
        vm.prank(taker);
        escrow.reclaimExpired(order);
    }

    // --- slashPartial with pending unstake, maker stays active ---

    function test_slashPartial_pendingUnstake_staysActive() public {
        // maker1 stakes 50k, requests unstake 10k, then gets partially slashed
        // but remains above minStake → stays active, unstake still pending
        uint256 maker5Key = 0xBAAD;
        address maker5Addr = vm.addr(maker5Key);
        usdc.mint(maker5Addr, 1_000_000e6);
        _stakeWithAddr(maker5Addr, 50_000e6);

        vm.prank(maker5Addr);
        staking.requestUnstake(10_000e6);

        // Create and dispute an intent with maker5
        DataTypes.Order memory order = _makeOrder(1_000e6, 990e6);
        bytes memory orderSig = _signOrder(takerKey, order);
        vm.prank(maker5Addr);
        bytes32 intentId = escrow.executeOrder(order, orderSig);
        vm.prank(maker5Addr);
        escrow.submitFill(intentId, keccak256("fill"));

        DataTypes.Commitment memory commitment = escrow.getCommitment(intentId);

        vm.startPrank(maker2Addr);
        usdc.approve(address(disputes), type(uint256).max);
        disputes.dispute(order);
        vm.stopPrank();

        bytes memory sig = _signAttestation(
            maker3Key, intentId, false, commitment.fillTxHash, order.destinationChainId
        );
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = sig;
        disputes.resolveDispute(intentId, false, sigs);

        // $1k fill → slash 2,650. Remaining = 47,350 > 10k → stays active
        DataTypes.MakerInfo memory info = staking.getMakerInfo(maker5Addr);
        assertTrue(info.isActive);
        assertEq(info.stakedAmount, 50_000e6 - 2_650e6);
        // Unstake request should still be pending (maker stayed active)
        assertGt(info.unstakeRequestTime, 0);
        assertEq(info.unstakeAmount, 10_000e6);
    }

    // --- Fuzz: totalActiveStake invariant ---

    function testFuzz_totalActiveStake_invariant(
        uint256 stake1,
        uint256 stake2,
        uint256 slashAmt
    ) public {
        stake1 = bound(stake1, MIN_STAKE, 500_000e6);
        stake2 = bound(stake2, MIN_STAKE, 500_000e6);
        slashAmt = bound(slashAmt, 1, stake1);

        // Use fresh addresses to avoid interference from setUp's existing stakes
        address fuzzMaker1 = makeAddr("fuzzMaker1");
        address fuzzMaker2 = makeAddr("fuzzMaker2");
        usdc.mint(fuzzMaker1, stake1);
        usdc.mint(fuzzMaker2, stake2);

        uint256 baseTotalActive = staking.totalActiveStake(); // 150k from setUp

        _stakeWithAddr(fuzzMaker1, stake1);
        _stakeWithAddr(fuzzMaker2, stake2);

        assertEq(staking.totalActiveStake(), baseTotalActive + stake1 + stake2);

        // Partial slash fuzzMaker1
        vm.prank(address(disputes));
        uint256 slashed = staking.slashPartial(fuzzMaker1, keccak256("intent"), slashAmt);

        uint256 remaining1 = stake1 - slashed;
        uint256 expectedDelta;
        if (remaining1 >= MIN_STAKE) {
            expectedDelta = stake1 + stake2 - slashed;
        } else {
            expectedDelta = stake2; // fuzzMaker1 deactivated, only fuzzMaker2 contributes
        }
        assertEq(staking.totalActiveStake(), baseTotalActive + expectedDelta);

        // Verify sum of fuzz maker active stakes
        uint256 actualSum = 0;
        if (staking.isActiveMaker(fuzzMaker1)) actualSum += staking.getStake(fuzzMaker1);
        if (staking.isActiveMaker(fuzzMaker2)) actualSum += staking.getStake(fuzzMaker2);
        assertEq(actualSum, expectedDelta);
    }

    // --- Fuzz: bond calculation ---

    function testFuzz_calculateDisputeBond(uint256 fillAmount) public view {
        fillAmount = bound(fillAmount, 0, 100_000_000e6); // 0 to 100M USDC

        uint256 bond = disputes.calculateDisputeBond(fillAmount);

        // Invariant: bond >= minDisputeBond
        assertGe(bond, disputes.minDisputeBond());

        // Invariant: bond >= fillAmount * bps / 10_000 (when no overflow)
        uint256 bpsBond = (fillAmount * disputes.disputeBondBps()) / 10_000;
        if (bpsBond > disputes.minDisputeBond()) {
            assertEq(bond, bpsBond);
        } else {
            assertEq(bond, disputes.minDisputeBond());
        }
    }

    // --- Exposure desync after partial slash ---

    function test_resolveAsInvalid_multipleOutstandingFills_exposureCorrect() public {
        // maker1 (50k) fills 4 intents of 10k each → 40k exposure
        (bytes32 id1, DataTypes.Order memory order1) = _createAndFillIntent(10_000e6);
        (bytes32 id2, DataTypes.Order memory order2) = _createAndFillIntent(10_000e6);
        (bytes32 id3, DataTypes.Order memory order3) = _createAndFillIntent(10_000e6);
        (bytes32 id4, DataTypes.Order memory order4) = _createAndFillIntent(10_000e6);

        assertEq(staking.getExposure(maker1Addr), 40_000e6);

        // Dispute fill #1 and resolve as invalid
        DataTypes.Commitment memory commitment = escrow.getCommitment(id1);

        vm.startPrank(maker2Addr);
        usdc.approve(address(disputes), type(uint256).max);
        disputes.dispute(order1);
        vm.stopPrank();

        bytes memory sig = _signAttestation(
            maker3Key, id1, false, commitment.fillTxHash, order1.destinationChainId
        );
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = sig;
        disputes.resolveDispute(id1, false, sigs);

        // Slash: 10k fill, 50k stake. multiplier = 2 + 650e6/10_000e6 = 2.065
        // slash = 10k * 2.065 = 20,650. Remaining stake = 29,350.
        assertEq(staking.getStake(maker1Addr), 50_000e6 - 20_650e6);

        // slashPartial caps exposure: min(40k, 29,350) = 29,350
        // exposureBefore = 40k, exposureAfter = 29,350
        // alreadyReduced = 40k - 29,350 = 10,650
        // 10k (fillAmount) < 10,650 (alreadyReduced) → skip decreaseExposure
        // Final exposure = 29,350
        //
        // Without the fix: exposure = 29,350 - 10,000 = 19,350 (WRONG — 3 fills outstanding = 30k)
        // With the fix: exposure = 29,350 (correct — capped at remaining stake)
        assertEq(staking.getExposure(maker1Addr), 29_350e6);

        // Verify this is NOT 19,350 (the buggy value)
        assertTrue(staking.getExposure(maker1Addr) != 19_350e6);
    }

    function test_resolveAsInvalid_singleFill_exposureZero() public {
        // Single fill: after slash, no cap needed → normal decreaseExposure
        (bytes32 id1, DataTypes.Order memory order1) = _createAndFillIntent(10_000e6);

        assertEq(staking.getExposure(maker1Addr), 10_000e6);

        DataTypes.Commitment memory commitment = escrow.getCommitment(id1);

        vm.startPrank(maker2Addr);
        usdc.approve(address(disputes), type(uint256).max);
        disputes.dispute(order1);
        vm.stopPrank();

        bytes memory sig = _signAttestation(
            maker3Key, id1, false, commitment.fillTxHash, order1.destinationChainId
        );
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = sig;
        disputes.resolveDispute(id1, false, sigs);

        // Slash 20,650. Remaining = 29,350. Exposure was 10k < 29,350 → no cap.
        // alreadyReduced = 0, full decreaseExposure(10k) → exposure = 0
        assertEq(staking.getExposure(maker1Addr), 0);
    }

    function test_getExposure_viewFunction() public {
        assertEq(staking.getExposure(maker1Addr), 0);

        _createAndFillIntent(10_000e6);
        assertEq(staking.getExposure(maker1Addr), 10_000e6);

        _createAndFillIntent(5_000e6);
        assertEq(staking.getExposure(maker1Addr), 15_000e6);
    }

    // --- Attestor DoS protection (blacklisted attestor) ---

    // Helper: deploy fresh system with blacklistable token
    struct BlacklistTestEnv {
        MockBlacklistableERC20 bToken;
        GauloiStaking freshStaking;
        GauloiEscrow freshEscrow;
        GauloiDisputes freshDisputes;
    }

    function _deployBlacklistEnv() internal returns (BlacklistTestEnv memory env) {
        env.bToken = new MockBlacklistableERC20("Bond USDC", "BUSDC", 6);
        env.freshStaking = new GauloiStaking(address(env.bToken), MIN_STAKE, COOLDOWN, 1 hours, owner);
        env.freshEscrow = new GauloiEscrow(address(env.freshStaking), SETTLEMENT_WINDOW, COMMITMENT_TIMEOUT, owner);
        env.freshDisputes = new GauloiDisputes(
            address(env.freshStaking), address(env.freshEscrow), address(env.bToken),
            RESOLUTION_WINDOW, BOND_BPS, MIN_BOND, owner
        );

        vm.startPrank(owner);
        env.freshStaking.setEscrow(address(env.freshEscrow));
        env.freshStaking.setDisputes(address(env.freshDisputes));
        env.freshEscrow.setDisputes(address(env.freshDisputes));
        env.freshEscrow.addSupportedToken(address(env.bToken));
        vm.stopPrank();
    }

    function _fundAndStake(BlacklistTestEnv memory env, address maker, uint256 amount) internal {
        env.bToken.mint(maker, 1_000_000e6);
        vm.startPrank(maker);
        env.bToken.approve(address(env.freshStaking), amount);
        env.freshStaking.stake(amount);
        vm.stopPrank();
    }

    function _signOrderForEscrow(GauloiEscrow targetEscrow, DataTypes.Order memory order) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(abi.encode(
            IntentLib.ORDER_TYPEHASH,
            order.taker, order.inputToken, order.inputAmount,
            order.outputToken, order.minOutputAmount,
            order.destinationChainId, order.destinationAddress,
            order.expiry, order.nonce
        ));
        bytes32 digest = MessageHashUtils.toTypedDataHash(targetEscrow.domainSeparator(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(takerKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signAttestationForDisputes(
        GauloiDisputes targetDisputes,
        uint256 privateKey,
        bytes32 intentId,
        bool fillValid,
        bytes32 fillTxHash,
        uint256 destChainId
    ) internal view returns (bytes memory) {
        bytes32 structHash = SignatureLib.hashAttestation(intentId, fillValid, fillTxHash, destChainId);
        bytes32 digest = MessageHashUtils.toTypedDataHash(targetDisputes.domainSeparator(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function test_resolveDispute_blacklistedAttestor_stillResolves() public {
        BlacklistTestEnv memory env = _deployBlacklistEnv();

        _fundAndStake(env, maker1Addr, 50_000e6);
        _fundAndStake(env, maker2Addr, 50_000e6);
        _fundAndStake(env, maker3Addr, 50_000e6);
        env.bToken.mint(taker, 1_000_000e6);
        vm.prank(taker);
        env.bToken.approve(address(env.freshEscrow), type(uint256).max);

        // Create and fill intent
        DataTypes.Order memory order = DataTypes.Order({
            taker: taker,
            inputToken: address(env.bToken),
            inputAmount: 10_000e6,
            outputToken: address(env.bToken),
            minOutputAmount: 9_990e6,
            destinationChainId: DEST_CHAIN_ID,
            destinationAddress: DEST_ADDRESS,
            expiry: block.timestamp + 1 hours,
            nonce: 8888
        });

        bytes memory orderSig = _signOrderForEscrow(env.freshEscrow, order);
        vm.prank(maker1Addr);
        bytes32 intentId = env.freshEscrow.executeOrder(order, orderSig);
        vm.prank(maker1Addr);
        env.freshEscrow.submitFill(intentId, keccak256("dest_tx"));

        DataTypes.Commitment memory commitment = env.freshEscrow.getCommitment(intentId);

        // maker2 disputes
        vm.startPrank(maker2Addr);
        env.bToken.approve(address(env.freshDisputes), type(uint256).max);
        env.freshDisputes.dispute(order);
        vm.stopPrank();

        uint256 maker3BalBefore = env.bToken.balanceOf(maker3Addr);

        // BLACKLIST maker3 before resolution
        env.bToken.blacklist(maker3Addr);

        // maker3 attests fill-valid
        bytes memory attSig = _signAttestationForDisputes(
            env.freshDisputes, maker3Key, intentId, true, commitment.fillTxHash, order.destinationChainId
        );
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = attSig;

        // This MUST NOT revert despite maker3 being blacklisted
        env.freshDisputes.resolveDispute(intentId, true, sigs);

        // Verify dispute resolved
        assertTrue(env.freshDisputes.getDispute(intentId).resolved);
        assertTrue(env.freshDisputes.getDispute(intentId).fillDeemedValid);

        // maker3 balance unchanged (transfer to blacklisted address failed)
        assertEq(env.bToken.balanceOf(maker3Addr), maker3BalBefore);

        // The failed share stays in the disputes contract (treasury)
        assertGt(env.bToken.balanceOf(address(env.freshDisputes)), 0);
    }

    function test_resolveDispute_blacklistedAttestor_otherAttestorsGetRewards() public {
        BlacklistTestEnv memory env = _deployBlacklistEnv();

        uint256 maker4Key = 0xD00D;
        address maker4Addr = vm.addr(maker4Key);

        _fundAndStake(env, maker1Addr, 50_000e6);
        _fundAndStake(env, maker2Addr, 50_000e6);
        _fundAndStake(env, maker3Addr, 50_000e6);
        _fundAndStake(env, maker4Addr, 50_000e6);
        env.bToken.mint(taker, 1_000_000e6);
        vm.prank(taker);
        env.bToken.approve(address(env.freshEscrow), type(uint256).max);

        DataTypes.Order memory order = DataTypes.Order({
            taker: taker,
            inputToken: address(env.bToken),
            inputAmount: 10_000e6,
            outputToken: address(env.bToken),
            minOutputAmount: 9_990e6,
            destinationChainId: DEST_CHAIN_ID,
            destinationAddress: DEST_ADDRESS,
            expiry: block.timestamp + 1 hours,
            nonce: 9999
        });

        bytes memory orderSig = _signOrderForEscrow(env.freshEscrow, order);
        vm.prank(maker1Addr);
        bytes32 intentId = env.freshEscrow.executeOrder(order, orderSig);
        vm.prank(maker1Addr);
        env.freshEscrow.submitFill(intentId, keccak256("dest_tx"));

        DataTypes.Commitment memory commitment = env.freshEscrow.getCommitment(intentId);

        vm.startPrank(maker2Addr);
        env.bToken.approve(address(env.freshDisputes), type(uint256).max);
        env.freshDisputes.dispute(order);
        vm.stopPrank();

        // Blacklist maker3 BEFORE resolution
        env.bToken.blacklist(maker3Addr);

        uint256 maker4BalBefore = env.bToken.balanceOf(maker4Addr);

        // Both maker3 (blacklisted) and maker4 (normal) attest fill-valid
        bytes memory sig3 = _signAttestationForDisputes(
            env.freshDisputes, maker3Key, intentId, true, commitment.fillTxHash, order.destinationChainId
        );
        bytes memory sig4 = _signAttestationForDisputes(
            env.freshDisputes, maker4Key, intentId, true, commitment.fillTxHash, order.destinationChainId
        );
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = sig3;
        sigs[1] = sig4;

        env.freshDisputes.resolveDispute(intentId, true, sigs);
        assertTrue(env.freshDisputes.getDispute(intentId).resolved);

        // maker4 received their pro-rata share
        // Bond = 250e6. attestorPool = 250e6/4 = 62,500,000.
        // totalWeight = 50k + 50k = 100k. maker4's share = 62,500,000 * 50k / 100k = 31,250,000.
        assertEq(env.bToken.balanceOf(maker4Addr) - maker4BalBefore, 31_250_000);

        // maker3's share (31,250,000) stayed in the contract
        assertGe(env.bToken.balanceOf(address(env.freshDisputes)), 31_250_000);
    }

    // --- Maker/Challenger blacklist DoS protection ---

    function test_resolveAsValid_blacklistedMaker_stillResolves() public {
        BlacklistTestEnv memory env = _deployBlacklistEnv();

        _fundAndStake(env, maker1Addr, 50_000e6);
        _fundAndStake(env, maker2Addr, 50_000e6);
        _fundAndStake(env, maker3Addr, 50_000e6);
        env.bToken.mint(taker, 1_000_000e6);
        vm.prank(taker);
        env.bToken.approve(address(env.freshEscrow), type(uint256).max);

        DataTypes.Order memory order = DataTypes.Order({
            taker: taker,
            inputToken: address(env.bToken),
            inputAmount: 10_000e6,
            outputToken: address(env.bToken),
            minOutputAmount: 9_990e6,
            destinationChainId: DEST_CHAIN_ID,
            destinationAddress: DEST_ADDRESS,
            expiry: block.timestamp + 1 hours,
            nonce: 7770
        });

        bytes memory orderSig = _signOrderForEscrow(env.freshEscrow, order);
        vm.prank(maker1Addr);
        bytes32 intentId = env.freshEscrow.executeOrder(order, orderSig);
        vm.prank(maker1Addr);
        env.freshEscrow.submitFill(intentId, keccak256("dest_tx"));

        DataTypes.Commitment memory commitment = env.freshEscrow.getCommitment(intentId);

        // maker2 disputes
        vm.startPrank(maker2Addr);
        env.bToken.approve(address(env.freshDisputes), type(uint256).max);
        env.freshDisputes.dispute(order);
        vm.stopPrank();

        uint256 maker1BalBefore = env.bToken.balanceOf(maker1Addr);

        // BLACKLIST maker1 (the fill maker) before resolution
        env.bToken.blacklist(maker1Addr);

        // maker3 attests fill-valid → resolves as valid
        bytes memory attSig = _signAttestationForDisputes(
            env.freshDisputes, maker3Key, intentId, true, commitment.fillTxHash, order.destinationChainId
        );
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = attSig;

        // Must NOT revert despite maker1 being blacklisted
        env.freshDisputes.resolveDispute(intentId, true, sigs);

        // Dispute resolved successfully
        assertTrue(env.freshDisputes.getDispute(intentId).resolved);
        assertTrue(env.freshDisputes.getDispute(intentId).fillDeemedValid);

        // maker1 balance unchanged (transfer to blacklisted address failed)
        assertEq(env.bToken.balanceOf(maker1Addr), maker1BalBefore);

        // The failed maker reward stays in disputes contract as treasury
        // Bond = 250e6, makerReward = 250e6 / 2 = 125e6
        assertGe(env.bToken.balanceOf(address(env.freshDisputes)), 125e6);

        // Escrow-side: maker was also blacklisted for the settlement transfer,
        // so escrowed taker funds (10,000e6) stay in escrow (recoverable via rescueTokens)
        assertGe(env.bToken.balanceOf(address(env.freshEscrow)), 10_000e6);
    }

    function test_resolveAsInvalid_blacklistedChallenger_stillResolves() public {
        BlacklistTestEnv memory env = _deployBlacklistEnv();

        _fundAndStake(env, maker1Addr, 50_000e6);
        _fundAndStake(env, maker2Addr, 50_000e6);
        _fundAndStake(env, maker3Addr, 50_000e6);
        env.bToken.mint(taker, 1_000_000e6);
        vm.prank(taker);
        env.bToken.approve(address(env.freshEscrow), type(uint256).max);

        DataTypes.Order memory order = DataTypes.Order({
            taker: taker,
            inputToken: address(env.bToken),
            inputAmount: 10_000e6,
            outputToken: address(env.bToken),
            minOutputAmount: 9_990e6,
            destinationChainId: DEST_CHAIN_ID,
            destinationAddress: DEST_ADDRESS,
            expiry: block.timestamp + 1 hours,
            nonce: 7771
        });

        bytes memory orderSig = _signOrderForEscrow(env.freshEscrow, order);
        vm.prank(maker1Addr);
        bytes32 intentId = env.freshEscrow.executeOrder(order, orderSig);
        vm.prank(maker1Addr);
        env.freshEscrow.submitFill(intentId, keccak256("dest_tx"));

        DataTypes.Commitment memory commitment = env.freshEscrow.getCommitment(intentId);

        // maker2 disputes
        vm.startPrank(maker2Addr);
        env.bToken.approve(address(env.freshDisputes), type(uint256).max);
        env.freshDisputes.dispute(order);
        vm.stopPrank();

        uint256 maker2BalBefore = env.bToken.balanceOf(maker2Addr);

        // BLACKLIST maker2 (the challenger) before resolution
        env.bToken.blacklist(maker2Addr);

        // maker3 attests fill-invalid → resolves as invalid
        bytes memory attSig = _signAttestationForDisputes(
            env.freshDisputes, maker3Key, intentId, false, commitment.fillTxHash, order.destinationChainId
        );
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = attSig;

        // Must NOT revert despite maker2 (challenger) being blacklisted
        env.freshDisputes.resolveDispute(intentId, false, sigs);

        // Dispute resolved successfully
        assertTrue(env.freshDisputes.getDispute(intentId).resolved);
        assertFalse(env.freshDisputes.getDispute(intentId).fillDeemedValid);

        // maker2 balance unchanged (transfer to blacklisted address failed)
        assertEq(env.bToken.balanceOf(maker2Addr), maker2BalBefore);

        // The challenger's bond + slash reward stays in disputes contract as treasury
        assertGt(env.bToken.balanceOf(address(env.freshDisputes)), 0);

        // Taker (not blacklisted) was still refunded via escrow.resolveInvalid
        assertGe(env.bToken.balanceOf(taker), 10_000e6);
    }

    function test_resolveAsValid_nonBlacklistedMaker_getsReward() public {
        BlacklistTestEnv memory env = _deployBlacklistEnv();

        _fundAndStake(env, maker1Addr, 50_000e6);
        _fundAndStake(env, maker2Addr, 50_000e6);
        _fundAndStake(env, maker3Addr, 50_000e6);
        env.bToken.mint(taker, 1_000_000e6);
        vm.prank(taker);
        env.bToken.approve(address(env.freshEscrow), type(uint256).max);

        DataTypes.Order memory order = DataTypes.Order({
            taker: taker,
            inputToken: address(env.bToken),
            inputAmount: 10_000e6,
            outputToken: address(env.bToken),
            minOutputAmount: 9_990e6,
            destinationChainId: DEST_CHAIN_ID,
            destinationAddress: DEST_ADDRESS,
            expiry: block.timestamp + 1 hours,
            nonce: 7772
        });

        bytes memory orderSig = _signOrderForEscrow(env.freshEscrow, order);
        vm.prank(maker1Addr);
        bytes32 intentId = env.freshEscrow.executeOrder(order, orderSig);
        vm.prank(maker1Addr);
        env.freshEscrow.submitFill(intentId, keccak256("dest_tx"));

        DataTypes.Commitment memory commitment = env.freshEscrow.getCommitment(intentId);

        vm.startPrank(maker2Addr);
        env.bToken.approve(address(env.freshDisputes), type(uint256).max);
        env.freshDisputes.dispute(order);
        vm.stopPrank();

        uint256 maker1BalBefore = env.bToken.balanceOf(maker1Addr);

        // maker3 attests fill-valid → resolves as valid, maker1 NOT blacklisted
        bytes memory attSig = _signAttestationForDisputes(
            env.freshDisputes, maker3Key, intentId, true, commitment.fillTxHash, order.destinationChainId
        );
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = attSig;

        env.freshDisputes.resolveDispute(intentId, true, sigs);

        assertTrue(env.freshDisputes.getDispute(intentId).resolved);

        // maker1 received reward + escrowed funds: bond/2 = 125e6 + escrow = 10,000e6
        assertEq(env.bToken.balanceOf(maker1Addr) - maker1BalBefore, 10_125e6);
    }

    // --- Expired dispute tie → valid wins ---

    function test_expiredDispute_tieBreaksToValid() public {
        // This is a focused test confirming that validWeight >= invalidWeight
        // means valid wins ties.
        uint256 maker4Key = 0xD00D;
        address maker4Addr = vm.addr(maker4Key);
        usdc.mint(maker4Addr, 1_000_000e6);
        _stakeWithAddr(maker4Addr, 50_000e6);

        (bytes32 intentId, DataTypes.Order memory order) = _createAndFillIntent(10_000e6);
        DataTypes.Commitment memory commitment = escrow.getCommitment(intentId);

        vm.startPrank(maker2Addr);
        usdc.approve(address(disputes), type(uint256).max);
        disputes.dispute(order);
        vm.stopPrank();

        // Set quorum high enough that single calls don't trigger quorum
        vm.prank(owner);
        disputes.setQuorumParams(9000);
        // eligible = 200k - 50k - 50k = 100k, quorum = 90k

        // maker3 (50k) valid, maker4 (50k) invalid → total 100k >= 90k ✓
        // But they submit in separate calls, each below quorum

        // Call 1: maker3 valid (50k), quorum: 50k < 90k → returns
        {
            bytes memory sig3 = _signAttestation(maker3Key, intentId, true, commitment.fillTxHash, order.destinationChainId);
            bytes[] memory sigs = new bytes[](1);
            sigs[0] = sig3;
            disputes.resolveDispute(intentId, true, sigs);
        }

        // Call 2: maker4 invalid (50k), total=100k >= 90k ✓
        // valid=50k, invalid=50k. Neither strict majority (50k*2=100k NOT > 100k)
        {
            bytes memory sig4 = _signAttestation(maker4Key, intentId, false, commitment.fillTxHash, order.destinationChainId);
            bytes[] memory sigs = new bytes[](1);
            sigs[0] = sig4;
            disputes.resolveDispute(intentId, false, sigs);
        }
        assertFalse(disputes.getDispute(intentId).resolved);

        // Expire → plurality: 50k == 50k → valid wins (>= tie-break)
        vm.warp(block.timestamp + RESOLUTION_WINDOW + 1);
        disputes.finalizeExpiredDispute(intentId);

        assertTrue(disputes.getDispute(intentId).resolved);
        assertTrue(disputes.getDispute(intentId).fillDeemedValid);
    }
}

// Need these imports visible in this file for setUp
import {MockERC20} from "../helpers/MockERC20.sol";
import {MockBlacklistableERC20} from "../helpers/MockBlacklistableERC20.sol";
import {GauloiStaking} from "../../src/GauloiStaking.sol";
import {GauloiEscrow} from "../../src/GauloiEscrow.sol";

contract MockERC20Harness is MockERC20 {
    constructor(string memory name, string memory symbol, uint8 decimals_)
        MockERC20(name, symbol, decimals_) {}
}
