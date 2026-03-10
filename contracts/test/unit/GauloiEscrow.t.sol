// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../helpers/BaseTest.sol";
import {GauloiEscrow} from "../../src/GauloiEscrow.sol";
import {IGauloiEscrow} from "../../src/interfaces/IGauloiEscrow.sol";
import {DataTypes} from "../../src/types/DataTypes.sol";
import {IntentLib} from "../../src/libraries/IntentLib.sol";
import {MockFeeOnTransferToken} from "../helpers/MockFeeOnTransferToken.sol";
import {MockBlacklistableERC20} from "../helpers/MockBlacklistableERC20.sol";
import {GauloiStaking} from "../../src/GauloiStaking.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

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

    // --- Execute order ---

    function test_executeOrder() public {
        (bytes32 intentId, DataTypes.Order memory order) = _createAndExecuteOrder(10_000e6, 9_990e6, maker1);

        DataTypes.Commitment memory commitment = escrow.getCommitment(intentId);
        assertEq(commitment.taker, taker);
        assertEq(commitment.maker, maker1);
        assertTrue(commitment.state == DataTypes.IntentState.Committed);
        assertGt(commitment.commitmentDeadline, uint40(block.timestamp));

        // Tokens moved to escrow
        assertEq(usdc.balanceOf(address(escrow)), 10_000e6);

        // Exposure increased
        assertEq(staking.getMakerInfo(maker1).activeExposure, 10_000e6);
    }

    function test_executeOrder_unsupportedToken_reverts() public {
        MockERC20Fake fake = new MockERC20Fake();

        DataTypes.Order memory order = DataTypes.Order({
            taker: taker,
            inputToken: address(fake),
            inputAmount: 10_000e6,
            outputToken: address(usdc),
            minOutputAmount: 9_990e6,
            destinationChainId: DEST_CHAIN_ID,
            destinationAddress: DEST_ADDRESS,
            expiry: block.timestamp + 1 hours,
            nonce: 99
        });
        bytes memory sig = _signOrder(takerKey, order);

        vm.prank(maker1);
        vm.expectRevert("GauloiEscrow: unsupported input token");
        escrow.executeOrder(order, sig);
    }

    function test_executeOrder_zeroAmount_reverts() public {
        DataTypes.Order memory order = _makeOrder(0, 9_990e6);
        // Fix: inputAmount was set to 0 by _makeOrder
        bytes memory sig = _signOrder(takerKey, order);

        vm.prank(maker1);
        vm.expectRevert("GauloiEscrow: zero amount");
        escrow.executeOrder(order, sig);
    }

    function test_executeOrder_expiredOrder_reverts() public {
        DataTypes.Order memory order = _makeOrder(10_000e6, 9_990e6);
        order.expiry = block.timestamp - 1;
        bytes memory sig = _signOrder(takerKey, order);

        vm.prank(maker1);
        vm.expectRevert("GauloiEscrow: order expired");
        escrow.executeOrder(order, sig);
    }

    function test_executeOrder_invalidSignature_reverts() public {
        DataTypes.Order memory order = _makeOrder(10_000e6, 9_990e6);
        // Sign with wrong key
        uint256 wrongKey = 0xDEAD;
        bytes memory sig = _signOrder(wrongKey, order);

        vm.prank(maker1);
        vm.expectRevert("GauloiEscrow: invalid signature");
        escrow.executeOrder(order, sig);
    }

    function test_executeOrder_notActiveMaker_reverts() public {
        DataTypes.Order memory order = _makeOrder(10_000e6, 9_990e6);
        bytes memory sig = _signOrder(takerKey, order);

        address nobody = makeAddr("nobody");
        vm.prank(nobody);
        vm.expectRevert("GauloiEscrow: not active maker");
        escrow.executeOrder(order, sig);
    }

    function test_executeOrder_replay_reverts() public {
        DataTypes.Order memory order = _makeOrder(10_000e6, 9_990e6);
        bytes memory sig = _signOrder(takerKey, order);

        vm.prank(maker1);
        escrow.executeOrder(order, sig);

        vm.prank(maker1);
        vm.expectRevert("GauloiEscrow: already executed");
        escrow.executeOrder(order, sig);
    }

    function test_executeOrder_uniqueNonces() public {
        DataTypes.Order memory order1 = _makeOrder(1_000e6, 990e6);
        DataTypes.Order memory order2 = _makeOrder(1_000e6, 990e6);
        bytes memory sig1 = _signOrder(takerKey, order1);
        bytes memory sig2 = _signOrder(takerKey, order2);

        vm.prank(maker1);
        bytes32 id1 = escrow.executeOrder(order1, sig1);
        vm.prank(maker1);
        bytes32 id2 = escrow.executeOrder(order2, sig2);

        assertTrue(id1 != id2);
    }

    function test_executeOrder_exceedsCapacity_reverts() public {
        // Maker1 has 50k staked. Create order for 60k.
        usdc.mint(taker, 100_000e6);
        vm.prank(taker);
        usdc.approve(address(escrow), type(uint256).max);

        DataTypes.Order memory order = _makeOrder(60_000e6, 59_000e6);
        bytes memory sig = _signOrder(takerKey, order);

        vm.prank(maker1);
        vm.expectRevert("GauloiStaking: exposure exceeds stake");
        escrow.executeOrder(order, sig);
    }

    function test_executeOrder_emitsEvent() public {
        DataTypes.Order memory order = _makeOrder(10_000e6, 9_990e6);
        bytes memory sig = _signOrder(takerKey, order);

        vm.prank(maker1);
        vm.expectEmit(false, true, true, true);
        emit IGauloiEscrow.OrderExecuted(
            bytes32(0), // intentId — not checked
            taker,
            maker1,
            address(usdc),
            10_000e6,
            DEST_CHAIN_ID,
            address(usdc),
            9_990e6
        );
        escrow.executeOrder(order, sig);
    }

    // --- Submit fill ---

    function test_submitFill() public {
        (bytes32 intentId, DataTypes.Order memory order) = _createAndExecuteOrder(10_000e6, 9_990e6, maker1);

        bytes32 txHash = keccak256("dest_tx_hash");

        vm.prank(maker1);
        escrow.submitFill(intentId, txHash);

        DataTypes.Commitment memory commitment = escrow.getCommitment(intentId);
        assertTrue(commitment.state == DataTypes.IntentState.Filled);
        assertEq(commitment.fillTxHash, txHash);
        assertEq(commitment.disputeWindowEnd, uint40(block.timestamp + SETTLEMENT_WINDOW));
    }

    function test_submitFill_notCommittedMaker_reverts() public {
        (bytes32 intentId, ) = _createAndExecuteOrder(10_000e6, 9_990e6, maker1);

        _stakeMaker(maker2, 50_000e6);
        vm.prank(maker2);
        vm.expectRevert("GauloiEscrow: not committed maker");
        escrow.submitFill(intentId, keccak256("hash"));
    }

    function test_submitFill_afterCommitmentExpiry_reverts() public {
        (bytes32 intentId, ) = _createAndExecuteOrder(10_000e6, 9_990e6, maker1);

        vm.warp(block.timestamp + COMMITMENT_TIMEOUT + 1);

        vm.prank(maker1);
        vm.expectRevert("GauloiEscrow: commitment expired");
        escrow.submitFill(intentId, keccak256("hash"));
    }

    function test_submitFill_emptyTxHash_reverts() public {
        (bytes32 intentId, ) = _createAndExecuteOrder(10_000e6, 9_990e6, maker1);

        vm.prank(maker1);
        vm.expectRevert("GauloiEscrow: empty tx hash");
        escrow.submitFill(intentId, bytes32(0));
    }

    // --- Settle ---

    function test_settle() public {
        (bytes32 intentId, DataTypes.Order memory order) = _createAndExecuteOrder(10_000e6, 9_990e6, maker1);

        vm.prank(maker1);
        escrow.submitFill(intentId, keccak256("hash"));

        vm.warp(block.timestamp + SETTLEMENT_WINDOW);

        uint256 makerBalBefore = usdc.balanceOf(maker1);
        escrow.settle(order);

        DataTypes.Commitment memory commitment = escrow.getCommitment(intentId);
        assertTrue(commitment.state == DataTypes.IntentState.Settled);
        assertEq(usdc.balanceOf(maker1) - makerBalBefore, 10_000e6);
        assertEq(staking.getMakerInfo(maker1).activeExposure, 0);
    }

    function test_settle_beforeWindowExpires_reverts() public {
        (bytes32 intentId, DataTypes.Order memory order) = _createAndExecuteOrder(10_000e6, 9_990e6, maker1);

        vm.prank(maker1);
        escrow.submitFill(intentId, keccak256("hash"));

        vm.warp(block.timestamp + SETTLEMENT_WINDOW - 1);

        vm.expectRevert("GauloiEscrow: dispute window open");
        escrow.settle(order);
    }

    function test_settle_notFilled_reverts() public {
        (, DataTypes.Order memory order) = _createAndExecuteOrder(10_000e6, 9_990e6, maker1);

        vm.expectRevert("GauloiEscrow: not filled");
        escrow.settle(order);
    }

    // --- Batch settle ---

    function test_settleBatch() public {
        (bytes32 id1, DataTypes.Order memory order1) = _createAndExecuteOrder(5_000e6, 4_990e6, maker1);
        (bytes32 id2, DataTypes.Order memory order2) = _createAndExecuteOrder(5_000e6, 4_990e6, maker1);

        vm.startPrank(maker1);
        escrow.submitFill(id1, keccak256("hash1"));
        escrow.submitFill(id2, keccak256("hash2"));
        vm.stopPrank();

        vm.warp(block.timestamp + SETTLEMENT_WINDOW);

        uint256 makerBalBefore = usdc.balanceOf(maker1);

        DataTypes.Order[] memory orders = new DataTypes.Order[](2);
        orders[0] = order1;
        orders[1] = order2;
        escrow.settleBatch(orders);

        assertEq(usdc.balanceOf(maker1) - makerBalBefore, 10_000e6);
        assertTrue(escrow.getCommitment(id1).state == DataTypes.IntentState.Settled);
        assertTrue(escrow.getCommitment(id2).state == DataTypes.IntentState.Settled);
    }

    function test_settleBatch_skipsFailures() public {
        (bytes32 id1, DataTypes.Order memory order1) = _createAndExecuteOrder(5_000e6, 4_990e6, maker1);
        (bytes32 id2, DataTypes.Order memory order2) = _createAndExecuteOrder(5_000e6, 4_990e6, maker1);

        vm.startPrank(maker1);
        escrow.submitFill(id1, keccak256("hash1"));
        escrow.submitFill(id2, keccak256("hash2"));
        vm.stopPrank();

        vm.warp(block.timestamp + SETTLEMENT_WINDOW);

        // Settle id1 individually first
        escrow.settle(order1);

        // Batch should skip id1 (already settled) and settle id2
        DataTypes.Order[] memory orders = new DataTypes.Order[](2);
        orders[0] = order1;
        orders[1] = order2;
        escrow.settleBatch(orders);

        assertTrue(escrow.getCommitment(id2).state == DataTypes.IntentState.Settled);
    }

    // --- Reclaim ---

    function test_reclaimExpired_commitmentTimeout() public {
        (bytes32 intentId, DataTypes.Order memory order) = _createAndExecuteOrder(10_000e6, 9_990e6, maker1);

        vm.warp(block.timestamp + COMMITMENT_TIMEOUT + 1);

        uint256 takerBalBefore = usdc.balanceOf(taker);

        vm.prank(taker);
        escrow.reclaimExpired(order);

        assertEq(usdc.balanceOf(taker) - takerBalBefore, 10_000e6);
        assertEq(staking.getMakerInfo(maker1).activeExposure, 0); // Exposure released
        assertTrue(escrow.getCommitment(intentId).state == DataTypes.IntentState.Expired);
    }

    function test_reclaimExpired_notTimedOut_reverts() public {
        (, DataTypes.Order memory order) = _createAndExecuteOrder(10_000e6, 9_990e6, maker1);

        vm.prank(taker);
        vm.expectRevert("GauloiEscrow: commitment not timed out");
        escrow.reclaimExpired(order);
    }

    function test_reclaimExpired_notTaker_reverts() public {
        (, DataTypes.Order memory order) = _createAndExecuteOrder(10_000e6, 9_990e6, maker1);

        vm.warp(block.timestamp + COMMITMENT_TIMEOUT + 1);

        vm.prank(maker1);
        vm.expectRevert("GauloiEscrow: not taker");
        escrow.reclaimExpired(order);
    }

    function test_reclaimExpired_filled_reverts() public {
        (bytes32 intentId, DataTypes.Order memory order) = _createAndExecuteOrder(10_000e6, 9_990e6, maker1);

        vm.prank(maker1);
        escrow.submitFill(intentId, keccak256("hash"));

        vm.warp(block.timestamp + 2 hours);

        vm.prank(taker);
        vm.expectRevert("GauloiEscrow: not committed");
        escrow.reclaimExpired(order);
    }

    // --- Disputes integration ---

    function test_setDisputed() public {
        (bytes32 intentId, ) = _createAndExecuteOrder(10_000e6, 9_990e6, maker1);

        vm.prank(maker1);
        escrow.submitFill(intentId, keccak256("hash"));

        vm.prank(mockDisputes);
        escrow.setDisputed(intentId);

        assertTrue(escrow.getCommitment(intentId).state == DataTypes.IntentState.Disputed);
    }

    function test_resolveValid() public {
        (bytes32 intentId, DataTypes.Order memory order) = _createAndExecuteOrder(10_000e6, 9_990e6, maker1);

        vm.prank(maker1);
        escrow.submitFill(intentId, keccak256("hash"));

        vm.prank(mockDisputes);
        escrow.setDisputed(intentId);

        uint256 makerBalBefore = usdc.balanceOf(maker1);

        vm.prank(mockDisputes);
        escrow.resolveValid(intentId, order);

        assertTrue(escrow.getCommitment(intentId).state == DataTypes.IntentState.Settled);
        assertEq(usdc.balanceOf(maker1) - makerBalBefore, 10_000e6);
    }

    function test_resolveInvalid() public {
        (bytes32 intentId, DataTypes.Order memory order) = _createAndExecuteOrder(10_000e6, 9_990e6, maker1);

        vm.prank(maker1);
        escrow.submitFill(intentId, keccak256("hash"));

        vm.prank(mockDisputes);
        escrow.setDisputed(intentId);

        uint256 takerBalBefore = usdc.balanceOf(taker);

        vm.prank(mockDisputes);
        escrow.resolveInvalid(intentId, order);

        assertTrue(escrow.getCommitment(intentId).state == DataTypes.IntentState.Expired);
        assertEq(usdc.balanceOf(taker) - takerBalBefore, 10_000e6);
    }

    function test_setDisputed_notDisputes_reverts() public {
        (bytes32 intentId, ) = _createAndExecuteOrder(10_000e6, 9_990e6, maker1);

        vm.prank(maker1);
        escrow.submitFill(intentId, keccak256("hash"));

        vm.prank(maker1);
        vm.expectRevert("GauloiEscrow: caller is not disputes");
        escrow.setDisputed(intentId);
    }

    // --- Pause ---

    function test_pause_onlyDisputes() public {
        vm.prank(maker1);
        vm.expectRevert("GauloiEscrow: caller is not disputes");
        escrow.pause();

        vm.prank(owner);
        vm.expectRevert("GauloiEscrow: caller is not disputes");
        escrow.pause();
    }

    function test_unpause_onlyOwner() public {
        vm.prank(mockDisputes);
        escrow.pause();

        vm.prank(maker1);
        vm.expectRevert();
        escrow.unpause();

        vm.prank(owner);
        escrow.unpause();
        assertFalse(escrow.paused());
    }

    function test_executeOrder_reverts_whenPaused() public {
        vm.prank(mockDisputes);
        escrow.pause();

        DataTypes.Order memory order = _makeOrder(10_000e6, 9_990e6);
        bytes memory sig = _signOrder(takerKey, order);

        vm.prank(maker1);
        vm.expectRevert("GauloiEscrow: paused");
        escrow.executeOrder(order, sig);
    }

    function test_settle_works_whenPaused() public {
        (bytes32 intentId, DataTypes.Order memory order) = _createAndExecuteOrder(10_000e6, 9_990e6, maker1);

        vm.prank(maker1);
        escrow.submitFill(intentId, keccak256("hash"));

        vm.warp(block.timestamp + SETTLEMENT_WINDOW);

        // Pause escrow
        vm.prank(mockDisputes);
        escrow.pause();

        // Settle should still work even when paused
        uint256 makerBalBefore = usdc.balanceOf(maker1);
        escrow.settle(order);
        assertEq(usdc.balanceOf(maker1) - makerBalBefore, 10_000e6);
    }

    // --- Bounds now prevent overflow before SafeCast can trigger ---

    function test_executeOrder_hugeCommitmentTimeout_reverts() public {
        // Bounds reject values above 24 hours
        vm.prank(owner);
        vm.expectRevert("GauloiEscrow: timeout out of range");
        escrow.setCommitmentTimeout(type(uint40).max);
    }

    function test_submitFill_hugeSettlementWindow_reverts() public {
        // Bounds reject values above 7 days
        vm.prank(owner);
        vm.expectRevert("GauloiEscrow: window out of range");
        escrow.setSettlementWindow(type(uint40).max);
    }

    function test_executeOrder_normalTimestamp_succeeds() public {
        // Sanity check: normal durations work after SafeCast is in place
        (bytes32 intentId, ) = _createAndExecuteOrder(10_000e6, 9_990e6, maker1);

        DataTypes.Commitment memory c = escrow.getCommitment(intentId);
        assertEq(c.commitmentDeadline, uint40(block.timestamp + COMMITMENT_TIMEOUT));
    }

    // --- Fee-on-transfer protection ---

    function test_executeOrder_feeOnTransferToken_reverts() public {
        MockFeeOnTransferToken fotToken = new MockFeeOnTransferToken("FoT", "FOT", 6);

        // Whitelist the FoT token
        vm.prank(owner);
        escrow.addSupportedToken(address(fotToken));

        // Mint and approve for taker
        fotToken.mint(taker, 100_000e6);
        vm.prank(taker);
        fotToken.approve(address(escrow), type(uint256).max);

        // Create order using FoT token
        DataTypes.Order memory order = DataTypes.Order({
            taker: taker,
            inputToken: address(fotToken),
            inputAmount: 10_000e6,
            outputToken: address(usdc),
            minOutputAmount: 9_990e6,
            destinationChainId: DEST_CHAIN_ID,
            destinationAddress: DEST_ADDRESS,
            expiry: block.timestamp + 1 hours,
            nonce: 999
        });
        bytes memory sig = _signOrder(takerKey, order);

        // Should revert because FoT delivers less than inputAmount
        vm.prank(maker1);
        vm.expectRevert("GauloiEscrow: fee-on-transfer token");
        escrow.executeOrder(order, sig);
    }

    function test_executeOrder_normalToken_balanceCheckPasses() public {
        // Verify normal USDC still passes the balance check
        (, DataTypes.Order memory order) = _createAndExecuteOrder(10_000e6, 9_990e6, maker1);

        // Escrow received exactly the right amount
        assertEq(usdc.balanceOf(address(escrow)), order.inputAmount);
    }

    // --- Admin events ---

    function test_setDisputes_emitsEvent() public {
        address newDisputes = makeAddr("newDisputes");
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit IGauloiEscrow.DisputesUpdated(mockDisputes, newDisputes);
        escrow.setDisputes(newDisputes);
    }

    function test_setSettlementWindow_emitsEvent() public {
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit IGauloiEscrow.SettlementWindowUpdated(SETTLEMENT_WINDOW, 30 minutes);
        escrow.setSettlementWindow(30 minutes);
    }

    function test_setCommitmentTimeout_emitsEvent() public {
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit IGauloiEscrow.CommitmentTimeoutUpdated(COMMITMENT_TIMEOUT, 10 minutes);
        escrow.setCommitmentTimeout(10 minutes);
    }

    function test_addSupportedToken_emitsEvent() public {
        address newToken = makeAddr("newToken");
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit IGauloiEscrow.TokenAdded(newToken);
        escrow.addSupportedToken(newToken);
    }

    function test_removeSupportedToken_emitsEvent() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit IGauloiEscrow.TokenRemoved(address(usdc));
        escrow.removeSupportedToken(address(usdc));
    }

    // --- Bounds ---

    function test_setSettlementWindow_tooShort_reverts() public {
        vm.prank(owner);
        vm.expectRevert("GauloiEscrow: window out of range");
        escrow.setSettlementWindow(59);
    }

    function test_setSettlementWindow_tooLong_reverts() public {
        vm.prank(owner);
        vm.expectRevert("GauloiEscrow: window out of range");
        escrow.setSettlementWindow(7 days + 1);
    }

    function test_setSettlementWindow_atBounds_succeeds() public {
        vm.startPrank(owner);
        escrow.setSettlementWindow(1 minutes);
        assertEq(escrow.settlementWindow(), 1 minutes);
        escrow.setSettlementWindow(7 days);
        assertEq(escrow.settlementWindow(), 7 days);
        vm.stopPrank();
    }

    function test_setCommitmentTimeout_tooShort_reverts() public {
        vm.prank(owner);
        vm.expectRevert("GauloiEscrow: timeout out of range");
        escrow.setCommitmentTimeout(59);
    }

    function test_setCommitmentTimeout_tooLong_reverts() public {
        vm.prank(owner);
        vm.expectRevert("GauloiEscrow: timeout out of range");
        escrow.setCommitmentTimeout(24 hours + 1);
    }

    function test_setCommitmentTimeout_atBounds_succeeds() public {
        vm.startPrank(owner);
        escrow.setCommitmentTimeout(1 minutes);
        assertEq(escrow.commitmentTimeout(), 1 minutes);
        escrow.setCommitmentTimeout(24 hours);
        assertEq(escrow.commitmentTimeout(), 24 hours);
        vm.stopPrank();
    }

    // --- BatchSettleFailed event ---

    function test_settleBatch_emitsBatchSettleFailed() public {
        (bytes32 id1, DataTypes.Order memory order1) = _createAndExecuteOrder(5_000e6, 4_990e6, maker1);
        (bytes32 id2, DataTypes.Order memory order2) = _createAndExecuteOrder(5_000e6, 4_990e6, maker1);

        vm.startPrank(maker1);
        escrow.submitFill(id1, keccak256("hash1"));
        escrow.submitFill(id2, keccak256("hash2"));
        vm.stopPrank();

        vm.warp(block.timestamp + SETTLEMENT_WINDOW);

        // Settle id1 individually first
        escrow.settle(order1);

        // Batch: id1 already settled (will fail), id2 should succeed
        DataTypes.Order[] memory orders = new DataTypes.Order[](2);
        orders[0] = order1;
        orders[1] = order2;

        vm.expectEmit(true, false, false, true);
        emit IGauloiEscrow.BatchSettleFailed(id1);
        escrow.settleBatch(orders);

        // id2 still settled successfully
        assertTrue(escrow.getCommitment(id2).state == DataTypes.IntentState.Settled);
    }

    // --- Blacklist DoS protection ---

    function _deployBlacklistEscrow()
        internal
        returns (MockBlacklistableERC20 bToken, GauloiStaking bStaking, GauloiEscrow bEscrow)
    {
        bToken = new MockBlacklistableERC20("USD Coin", "USDC", 6);
        bStaking = new GauloiStaking(address(bToken), MIN_STAKE, COOLDOWN, 1 hours, owner);
        bEscrow = new GauloiEscrow(address(bStaking), SETTLEMENT_WINDOW, COMMITMENT_TIMEOUT, owner);

        vm.startPrank(owner);
        bStaking.setEscrow(address(bEscrow));
        bEscrow.addSupportedToken(address(bToken));
        vm.stopPrank();

        // Fund and stake maker1
        bToken.mint(maker1, 1_000_000e6);
        vm.startPrank(maker1);
        bToken.approve(address(bStaking), type(uint256).max);
        bStaking.stake(50_000e6);
        vm.stopPrank();

        // Fund taker and approve escrow
        bToken.mint(taker, 1_000_000e6);
        vm.prank(taker);
        bToken.approve(address(bEscrow), type(uint256).max);
    }

    function _signOrderForEscrow(
        GauloiEscrow esc,
        uint256 privateKey,
        DataTypes.Order memory order
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(abi.encode(
            IntentLib.ORDER_TYPEHASH,
            order.taker, order.inputToken, order.inputAmount,
            order.outputToken, order.minOutputAmount, order.destinationChainId,
            order.destinationAddress, order.expiry, order.nonce
        ));
        bytes32 digest = MessageHashUtils.toTypedDataHash(esc.domainSeparator(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function test_settle_blacklistedMaker_stillCompletes() public {
        (MockBlacklistableERC20 bToken, GauloiStaking bStaking, GauloiEscrow bEscrow) = _deployBlacklistEscrow();

        // Execute and fill order
        DataTypes.Order memory order = DataTypes.Order({
            taker: taker, inputToken: address(bToken), inputAmount: 10_000e6,
            outputToken: address(bToken), minOutputAmount: 9_990e6,
            destinationChainId: DEST_CHAIN_ID, destinationAddress: DEST_ADDRESS,
            expiry: block.timestamp + 1 hours, nonce: 0
        });
        bytes memory sig = _signOrderForEscrow(bEscrow, takerKey, order);

        vm.prank(maker1);
        bytes32 intentId = bEscrow.executeOrder(order, sig);

        vm.prank(maker1);
        bEscrow.submitFill(intentId, keccak256("hash"));

        vm.warp(block.timestamp + SETTLEMENT_WINDOW);

        // Blacklist maker BEFORE settlement
        bToken.blacklist(maker1);
        uint256 makerBalBefore = bToken.balanceOf(maker1);

        // Settle must NOT revert
        vm.expectEmit(true, true, false, true);
        emit IGauloiEscrow.SettlementTransferFailed(intentId, maker1, 10_000e6);
        bEscrow.settle(order);

        // State transitioned despite failed transfer
        assertTrue(bEscrow.getCommitment(intentId).state == DataTypes.IntentState.Settled);
        // Exposure released
        assertEq(bStaking.getExposure(maker1), 0);
        // Maker didn't receive tokens (blacklisted)
        assertEq(bToken.balanceOf(maker1), makerBalBefore);
        // Funds still in escrow (recoverable via rescueTokens)
        assertEq(bToken.balanceOf(address(bEscrow)), 10_000e6);
    }

    function test_reclaimExpired_blacklistedTaker_stillCompletes() public {
        (MockBlacklistableERC20 bToken, GauloiStaking bStaking, GauloiEscrow bEscrow) = _deployBlacklistEscrow();

        // Execute order (maker commits but never fills)
        DataTypes.Order memory order = DataTypes.Order({
            taker: taker, inputToken: address(bToken), inputAmount: 10_000e6,
            outputToken: address(bToken), minOutputAmount: 9_990e6,
            destinationChainId: DEST_CHAIN_ID, destinationAddress: DEST_ADDRESS,
            expiry: block.timestamp + 1 hours, nonce: 0
        });
        bytes memory sig = _signOrderForEscrow(bEscrow, takerKey, order);

        vm.prank(maker1);
        bytes32 intentId = bEscrow.executeOrder(order, sig);

        // Commitment times out
        vm.warp(block.timestamp + COMMITMENT_TIMEOUT + 1);

        // Blacklist taker BEFORE reclaim
        bToken.blacklist(taker);
        uint256 takerBalBefore = bToken.balanceOf(taker);

        // Reclaim must NOT revert
        vm.prank(taker);
        vm.expectEmit(true, true, false, true);
        emit IGauloiEscrow.SettlementTransferFailed(intentId, taker, 10_000e6);
        bEscrow.reclaimExpired(order);

        // State transitioned despite failed transfer
        assertTrue(bEscrow.getCommitment(intentId).state == DataTypes.IntentState.Expired);
        // Exposure released
        assertEq(bStaking.getExposure(maker1), 0);
        // Taker didn't receive tokens (blacklisted)
        assertEq(bToken.balanceOf(taker), takerBalBefore);
        // Funds still in escrow (recoverable via rescueTokens)
        assertEq(bToken.balanceOf(address(bEscrow)), 10_000e6);
    }

    // --- Happy path end-to-end ---

    function test_fullLifecycle() public {
        // Maker executes taker's signed order
        (bytes32 intentId, DataTypes.Order memory order) = _createAndExecuteOrder(10_000e6, 9_990e6, maker1);
        assertTrue(escrow.getCommitment(intentId).state == DataTypes.IntentState.Committed);

        // Maker fills
        vm.prank(maker1);
        escrow.submitFill(intentId, keccak256("real_tx_hash"));
        assertTrue(escrow.getCommitment(intentId).state == DataTypes.IntentState.Filled);

        // Wait for dispute window
        vm.warp(block.timestamp + SETTLEMENT_WINDOW);

        // Settle
        uint256 makerBalBefore = usdc.balanceOf(maker1);
        escrow.settle(order);

        assertTrue(escrow.getCommitment(intentId).state == DataTypes.IntentState.Settled);
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
