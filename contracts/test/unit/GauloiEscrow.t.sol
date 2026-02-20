// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../helpers/BaseTest.sol";
import {GauloiEscrow} from "../../src/GauloiEscrow.sol";
import {IGauloiEscrow} from "../../src/interfaces/IGauloiEscrow.sol";
import {DataTypes} from "../../src/types/DataTypes.sol";

contract GauloiEscrowTest is BaseTest {
    address public mockDisputes = makeAddr("disputes");

    function setUp() public {
        _deployBase();
        _deployEscrow();
        _stakeMaker(maker1, 50_000e6);

        vm.startPrank(owner);
        escrow.setDisputes(mockDisputes);
        staking.setDisputes(mockDisputes);
        vm.stopPrank();
    }

    // --- Create intent ---

    function test_createIntent() public {
        bytes32 intentId = _createIntent(10_000e6, 9_990e6);

        DataTypes.Intent memory intent = escrow.getIntent(intentId);
        assertEq(intent.taker, taker);
        assertEq(intent.inputToken, address(usdc));
        assertEq(intent.inputAmount, 10_000e6);
        assertEq(intent.minOutputAmount, 9_990e6);
        assertEq(intent.destinationChainId, DEST_CHAIN_ID);
        assertEq(intent.destinationAddress, DEST_ADDRESS);
        assertTrue(intent.state == DataTypes.IntentState.Open);
        assertEq(intent.maker, address(0));

        // Tokens moved to escrow
        assertEq(usdc.balanceOf(address(escrow)), 10_000e6);
    }

    function test_createIntent_unsupportedToken_reverts() public {
        MockERC20Fake fake = new MockERC20Fake();

        vm.startPrank(taker);
        vm.expectRevert("GauloiEscrow: unsupported input token");
        escrow.createIntent(
            address(fake), 10_000e6, address(usdc), 9_990e6,
            DEST_CHAIN_ID, DEST_ADDRESS, block.timestamp + 1 hours
        );
        vm.stopPrank();
    }

    function test_createIntent_zeroAmount_reverts() public {
        vm.startPrank(taker);
        vm.expectRevert("GauloiEscrow: zero amount");
        escrow.createIntent(
            address(usdc), 0, address(usdc), 9_990e6,
            DEST_CHAIN_ID, DEST_ADDRESS, block.timestamp + 1 hours
        );
        vm.stopPrank();
    }

    function test_createIntent_expiryInPast_reverts() public {
        vm.startPrank(taker);
        usdc.approve(address(escrow), 10_000e6);
        vm.expectRevert("GauloiEscrow: expiry in past");
        escrow.createIntent(
            address(usdc), 10_000e6, address(usdc), 9_990e6,
            DEST_CHAIN_ID, DEST_ADDRESS, block.timestamp - 1
        );
        vm.stopPrank();
    }

    function test_createIntent_emitsEvent() public {
        vm.startPrank(taker);
        usdc.approve(address(escrow), 10_000e6);

        // We can't predict intentId exactly (depends on nonce), but we can check the event is emitted
        vm.expectEmit(false, true, false, true);
        emit IGauloiEscrow.IntentCreated(
            bytes32(0), // intentId — not checked (first indexed)
            taker,
            address(usdc),
            10_000e6,
            DEST_CHAIN_ID,
            address(usdc),
            9_990e6
        );
        escrow.createIntent(
            address(usdc), 10_000e6, address(usdc), 9_990e6,
            DEST_CHAIN_ID, DEST_ADDRESS, block.timestamp + 1 hours
        );
        vm.stopPrank();
    }

    function test_createIntent_incrementsNonce() public {
        bytes32 id1 = _createIntent(1_000e6, 990e6);
        bytes32 id2 = _createIntent(1_000e6, 990e6);
        assertTrue(id1 != id2);
        assertEq(escrow.nonces(taker), 2);
    }

    // --- Commit ---

    function test_commitToIntent() public {
        bytes32 intentId = _createIntent(10_000e6, 9_990e6);

        vm.prank(maker1);
        escrow.commitToIntent(intentId);

        DataTypes.Intent memory intent = escrow.getIntent(intentId);
        assertTrue(intent.state == DataTypes.IntentState.Committed);
        assertEq(intent.maker, maker1);
        assertGt(intent.commitmentDeadline, block.timestamp);

        // Exposure increased
        assertEq(staking.getMakerInfo(maker1).activeExposure, 10_000e6);
    }

    function test_commitToIntent_notOpen_reverts() public {
        bytes32 intentId = _createIntent(10_000e6, 9_990e6);

        vm.prank(maker1);
        escrow.commitToIntent(intentId);

        // Try to commit again
        _stakeMaker(maker2, 50_000e6);
        vm.prank(maker2);
        vm.expectRevert("GauloiEscrow: not open");
        escrow.commitToIntent(intentId);
    }

    function test_commitToIntent_expired_reverts() public {
        bytes32 intentId = _createIntent(10_000e6, 9_990e6);

        vm.warp(block.timestamp + 2 hours); // Past expiry

        vm.prank(maker1);
        vm.expectRevert("GauloiEscrow: intent expired");
        escrow.commitToIntent(intentId);
    }

    function test_commitToIntent_notActiveMaker_reverts() public {
        bytes32 intentId = _createIntent(10_000e6, 9_990e6);

        address nobody = makeAddr("nobody");
        vm.prank(nobody);
        vm.expectRevert("GauloiEscrow: not active maker");
        escrow.commitToIntent(intentId);
    }

    function test_commitToIntent_exceedsCapacity_reverts() public {
        // Maker1 has 50k staked. Create intent for 60k.
        usdc.mint(taker, 100_000e6);
        bytes32 intentId = _createIntent(60_000e6, 59_000e6);

        vm.prank(maker1);
        vm.expectRevert("GauloiStaking: exposure exceeds stake");
        escrow.commitToIntent(intentId);
    }

    // --- Submit fill ---

    function test_submitFill() public {
        bytes32 intentId = _createIntent(10_000e6, 9_990e6);

        vm.prank(maker1);
        escrow.commitToIntent(intentId);

        bytes32 txHash = keccak256("dest_tx_hash");

        vm.prank(maker1);
        escrow.submitFill(intentId, txHash);

        DataTypes.Intent memory intent = escrow.getIntent(intentId);
        assertTrue(intent.state == DataTypes.IntentState.Filled);
        assertEq(intent.fillTxHash, txHash);
        assertEq(intent.disputeWindowEnd, block.timestamp + SETTLEMENT_WINDOW);
    }

    function test_submitFill_notCommittedMaker_reverts() public {
        bytes32 intentId = _createIntent(10_000e6, 9_990e6);

        vm.prank(maker1);
        escrow.commitToIntent(intentId);

        _stakeMaker(maker2, 50_000e6);
        vm.prank(maker2);
        vm.expectRevert("GauloiEscrow: not committed maker");
        escrow.submitFill(intentId, keccak256("hash"));
    }

    function test_submitFill_afterCommitmentExpiry_reverts() public {
        bytes32 intentId = _createIntent(10_000e6, 9_990e6);

        vm.prank(maker1);
        escrow.commitToIntent(intentId);

        vm.warp(block.timestamp + COMMITMENT_TIMEOUT + 1);

        vm.prank(maker1);
        vm.expectRevert("GauloiEscrow: commitment expired");
        escrow.submitFill(intentId, keccak256("hash"));
    }

    function test_submitFill_emptyTxHash_reverts() public {
        bytes32 intentId = _createIntent(10_000e6, 9_990e6);

        vm.prank(maker1);
        escrow.commitToIntent(intentId);

        vm.prank(maker1);
        vm.expectRevert("GauloiEscrow: empty tx hash");
        escrow.submitFill(intentId, bytes32(0));
    }

    // --- Settle ---

    function test_settle() public {
        bytes32 intentId = _createIntent(10_000e6, 9_990e6);

        vm.prank(maker1);
        escrow.commitToIntent(intentId);

        vm.prank(maker1);
        escrow.submitFill(intentId, keccak256("hash"));

        vm.warp(block.timestamp + SETTLEMENT_WINDOW);

        uint256 makerBalBefore = usdc.balanceOf(maker1);
        escrow.settle(intentId);

        DataTypes.Intent memory intent = escrow.getIntent(intentId);
        assertTrue(intent.state == DataTypes.IntentState.Settled);
        assertEq(usdc.balanceOf(maker1) - makerBalBefore, 10_000e6);
        assertEq(staking.getMakerInfo(maker1).activeExposure, 0);
    }

    function test_settle_beforeWindowExpires_reverts() public {
        bytes32 intentId = _createIntent(10_000e6, 9_990e6);

        vm.prank(maker1);
        escrow.commitToIntent(intentId);

        vm.prank(maker1);
        escrow.submitFill(intentId, keccak256("hash"));

        vm.warp(block.timestamp + SETTLEMENT_WINDOW - 1);

        vm.expectRevert("GauloiEscrow: dispute window open");
        escrow.settle(intentId);
    }

    function test_settle_notFilled_reverts() public {
        bytes32 intentId = _createIntent(10_000e6, 9_990e6);

        vm.expectRevert("GauloiEscrow: not filled");
        escrow.settle(intentId);
    }

    // --- Batch settle ---

    function test_settleBatch() public {
        bytes32 id1 = _createIntent(5_000e6, 4_990e6);
        bytes32 id2 = _createIntent(5_000e6, 4_990e6);

        vm.startPrank(maker1);
        escrow.commitToIntent(id1);
        escrow.commitToIntent(id2);
        escrow.submitFill(id1, keccak256("hash1"));
        escrow.submitFill(id2, keccak256("hash2"));
        vm.stopPrank();

        vm.warp(block.timestamp + SETTLEMENT_WINDOW);

        uint256 makerBalBefore = usdc.balanceOf(maker1);

        bytes32[] memory ids = new bytes32[](2);
        ids[0] = id1;
        ids[1] = id2;
        escrow.settleBatch(ids);

        assertEq(usdc.balanceOf(maker1) - makerBalBefore, 10_000e6);
        assertTrue(escrow.getIntent(id1).state == DataTypes.IntentState.Settled);
        assertTrue(escrow.getIntent(id2).state == DataTypes.IntentState.Settled);
    }

    function test_settleBatch_skipsFailures() public {
        bytes32 id1 = _createIntent(5_000e6, 4_990e6);
        bytes32 id2 = _createIntent(5_000e6, 4_990e6);

        vm.startPrank(maker1);
        escrow.commitToIntent(id1);
        escrow.commitToIntent(id2);
        escrow.submitFill(id1, keccak256("hash1"));
        escrow.submitFill(id2, keccak256("hash2"));
        vm.stopPrank();

        vm.warp(block.timestamp + SETTLEMENT_WINDOW);

        // Settle id1 individually first
        escrow.settle(id1);

        // Batch should skip id1 (already settled) and settle id2
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = id1;
        ids[1] = id2;
        escrow.settleBatch(ids);

        assertTrue(escrow.getIntent(id2).state == DataTypes.IntentState.Settled);
    }

    // --- Reclaim ---

    function test_reclaimExpired_open() public {
        bytes32 intentId = _createIntent(10_000e6, 9_990e6);

        vm.warp(block.timestamp + 2 hours); // Past expiry

        uint256 takerBalBefore = usdc.balanceOf(taker);

        vm.prank(taker);
        escrow.reclaimExpired(intentId);

        assertEq(usdc.balanceOf(taker) - takerBalBefore, 10_000e6);
        assertTrue(escrow.getIntent(intentId).state == DataTypes.IntentState.Expired);
    }

    function test_reclaimExpired_commitmentTimeout() public {
        bytes32 intentId = _createIntent(10_000e6, 9_990e6);

        vm.prank(maker1);
        escrow.commitToIntent(intentId);

        vm.warp(block.timestamp + COMMITMENT_TIMEOUT + 1);

        uint256 takerBalBefore = usdc.balanceOf(taker);

        vm.prank(taker);
        escrow.reclaimExpired(intentId);

        assertEq(usdc.balanceOf(taker) - takerBalBefore, 10_000e6);
        assertEq(staking.getMakerInfo(maker1).activeExposure, 0); // Exposure released
    }

    function test_reclaimExpired_notExpired_reverts() public {
        bytes32 intentId = _createIntent(10_000e6, 9_990e6);

        vm.prank(taker);
        vm.expectRevert("GauloiEscrow: not expired");
        escrow.reclaimExpired(intentId);
    }

    function test_reclaimExpired_notTaker_reverts() public {
        bytes32 intentId = _createIntent(10_000e6, 9_990e6);

        vm.warp(block.timestamp + 2 hours);

        vm.prank(maker1);
        vm.expectRevert("GauloiEscrow: not taker");
        escrow.reclaimExpired(intentId);
    }

    function test_reclaimExpired_filled_reverts() public {
        bytes32 intentId = _createIntent(10_000e6, 9_990e6);

        vm.prank(maker1);
        escrow.commitToIntent(intentId);

        vm.prank(maker1);
        escrow.submitFill(intentId, keccak256("hash"));

        vm.warp(block.timestamp + 2 hours);

        vm.prank(taker);
        vm.expectRevert("GauloiEscrow: cannot reclaim in current state");
        escrow.reclaimExpired(intentId);
    }

    // --- Disputes integration ---

    function test_setDisputed() public {
        bytes32 intentId = _createIntent(10_000e6, 9_990e6);

        vm.prank(maker1);
        escrow.commitToIntent(intentId);

        vm.prank(maker1);
        escrow.submitFill(intentId, keccak256("hash"));

        vm.prank(mockDisputes);
        escrow.setDisputed(intentId);

        assertTrue(escrow.getIntent(intentId).state == DataTypes.IntentState.Disputed);
    }

    function test_resolveValid() public {
        bytes32 intentId = _createIntent(10_000e6, 9_990e6);

        vm.prank(maker1);
        escrow.commitToIntent(intentId);

        vm.prank(maker1);
        escrow.submitFill(intentId, keccak256("hash"));

        vm.prank(mockDisputes);
        escrow.setDisputed(intentId);

        uint256 makerBalBefore = usdc.balanceOf(maker1);

        vm.prank(mockDisputes);
        escrow.resolveValid(intentId);

        assertTrue(escrow.getIntent(intentId).state == DataTypes.IntentState.Settled);
        assertEq(usdc.balanceOf(maker1) - makerBalBefore, 10_000e6);
    }

    function test_resolveInvalid() public {
        bytes32 intentId = _createIntent(10_000e6, 9_990e6);

        vm.prank(maker1);
        escrow.commitToIntent(intentId);

        vm.prank(maker1);
        escrow.submitFill(intentId, keccak256("hash"));

        vm.prank(mockDisputes);
        escrow.setDisputed(intentId);

        uint256 takerBalBefore = usdc.balanceOf(taker);

        vm.prank(mockDisputes);
        escrow.resolveInvalid(intentId);

        assertTrue(escrow.getIntent(intentId).state == DataTypes.IntentState.Expired);
        assertEq(usdc.balanceOf(taker) - takerBalBefore, 10_000e6);
    }

    function test_setDisputed_notDisputes_reverts() public {
        bytes32 intentId = _createIntent(10_000e6, 9_990e6);

        vm.prank(maker1);
        escrow.commitToIntent(intentId);

        vm.prank(maker1);
        escrow.submitFill(intentId, keccak256("hash"));

        vm.prank(maker1);
        vm.expectRevert("GauloiEscrow: caller is not disputes");
        escrow.setDisputed(intentId);
    }

    // --- Happy path end-to-end ---

    function test_fullLifecycle() public {
        // Taker creates intent
        bytes32 intentId = _createIntent(10_000e6, 9_990e6);
        assertTrue(escrow.getIntent(intentId).state == DataTypes.IntentState.Open);

        // Maker commits
        vm.prank(maker1);
        escrow.commitToIntent(intentId);
        assertTrue(escrow.getIntent(intentId).state == DataTypes.IntentState.Committed);

        // Maker fills
        vm.prank(maker1);
        escrow.submitFill(intentId, keccak256("real_tx_hash"));
        assertTrue(escrow.getIntent(intentId).state == DataTypes.IntentState.Filled);

        // Wait for dispute window
        vm.warp(block.timestamp + SETTLEMENT_WINDOW);

        // Settle
        uint256 makerBalBefore = usdc.balanceOf(maker1);
        escrow.settle(intentId);

        assertTrue(escrow.getIntent(intentId).state == DataTypes.IntentState.Settled);
        assertEq(usdc.balanceOf(maker1) - makerBalBefore, 10_000e6);
        assertEq(staking.getMakerInfo(maker1).activeExposure, 0);
    }
}

// Minimal mock for unsupported token test
contract MockERC20Fake {
    function transferFrom(address, address, uint256) external pure returns (bool) {
        return true;
    }
}
