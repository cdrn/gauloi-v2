// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "../helpers/MockERC20.sol";
import {GauloiStaking} from "../../src/GauloiStaking.sol";
import {GauloiEscrow} from "../../src/GauloiEscrow.sol";
import {GauloiDisputes} from "../../src/GauloiDisputes.sol";
import {DataTypes} from "../../src/types/DataTypes.sol";
import {IntentLib} from "../../src/libraries/IntentLib.sol";
import {SignatureLib} from "../../src/libraries/SignatureLib.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @title Gas Benchmark — isolated per-operation gas measurements
/// @dev Run with: forge test --match-contract GasBenchmark --gas-report
/// @dev Snapshot: forge snapshot --match-contract GasBenchmark
contract GasBenchmark is Test {
    MockERC20 usdc;
    GauloiStaking staking;
    GauloiEscrow escrow;
    GauloiDisputes disputes;

    address owner = makeAddr("owner");

    // Taker with private key
    uint256 takerKey = 0x7A4E5;
    address taker;

    // Makers with known private keys (for dispute signatures)
    uint256 maker1Key = 0xA11CE;
    uint256 maker2Key = 0xB0B;
    uint256 maker3Key = 0xCAFE;
    address maker1;
    address maker2;
    address maker3;

    uint256 constant MIN_STAKE = 10_000e6;
    uint256 constant COOLDOWN = 48 hours;
    uint256 constant SETTLEMENT_WINDOW = 15 minutes;
    uint256 constant COMMITMENT_TIMEOUT = 5 minutes;
    uint256 constant RESOLUTION_WINDOW = 24 hours;
    uint256 constant BOND_BPS = 50;
    uint256 constant MIN_BOND = 25e6;
    uint256 constant DEST_CHAIN_ID = 42161;
    address constant DEST_ADDRESS = address(0xBEEF);

    uint256 internal _testNonce;

    function setUp() public {
        taker = vm.addr(takerKey);
        maker1 = vm.addr(maker1Key);
        maker2 = vm.addr(maker2Key);
        maker3 = vm.addr(maker3Key);

        usdc = new MockERC20("USD Coin", "USDC", 6);
        staking = new GauloiStaking(address(usdc), MIN_STAKE, COOLDOWN, owner);
        escrow = new GauloiEscrow(address(staking), SETTLEMENT_WINDOW, COMMITMENT_TIMEOUT, owner);
        disputes = new GauloiDisputes(
            address(staking), address(escrow), address(usdc),
            RESOLUTION_WINDOW, BOND_BPS, MIN_BOND, owner
        );

        vm.startPrank(owner);
        staking.setEscrow(address(escrow));
        staking.setDisputes(address(disputes));
        escrow.setDisputes(address(disputes));
        escrow.addSupportedToken(address(usdc));
        vm.stopPrank();

        // Fund everyone generously
        usdc.mint(maker1, 10_000_000e6);
        usdc.mint(maker2, 10_000_000e6);
        usdc.mint(maker3, 10_000_000e6);
        usdc.mint(taker, 10_000_000e6);

        // Approve escrow for taker
        vm.prank(taker);
        usdc.approve(address(escrow), type(uint256).max);
    }

    // ═══════════════════════════════════════════
    //  Staking
    // ═══════════════════════════════════════════

    function test_gas_stake() public {
        vm.startPrank(maker1);
        usdc.approve(address(staking), 50_000e6);
        staking.stake(50_000e6);
        vm.stopPrank();
    }

    function test_gas_requestUnstake() public {
        _stake(maker1, 50_000e6);

        vm.prank(maker1);
        staking.requestUnstake(20_000e6);
    }

    function test_gas_completeUnstake() public {
        _stake(maker1, 50_000e6);

        vm.prank(maker1);
        staking.requestUnstake(50_000e6);

        vm.warp(block.timestamp + COOLDOWN);

        vm.prank(maker1);
        staking.completeUnstake();
    }

    // ═══════════════════════════════════════════
    //  Escrow — Order Lifecycle
    // ═══════════════════════════════════════════

    function test_gas_executeOrder() public {
        _stake(maker1, 50_000e6);

        DataTypes.Order memory order = _makeOrder(10_000e6);
        bytes memory sig = _signOrder(order);

        vm.prank(maker1);
        escrow.executeOrder(order, sig);
    }

    function test_gas_submitFill() public {
        _stake(maker1, 50_000e6);
        (bytes32 intentId, ) = _executeOrder(10_000e6);

        vm.prank(maker1);
        escrow.submitFill(intentId, keccak256("dest_tx"));
    }

    function test_gas_settle() public {
        _stake(maker1, 50_000e6);
        (, DataTypes.Order memory order) = _fillIntent(10_000e6);

        vm.warp(block.timestamp + SETTLEMENT_WINDOW);
        escrow.settle(order);
    }

    function test_gas_settleBatch_5() public {
        _stake(maker1, 500_000e6);
        DataTypes.Order[] memory orders = new DataTypes.Order[](5);
        for (uint256 i; i < 5; i++) {
            (, orders[i]) = _fillIntent(10_000e6);
        }

        vm.warp(block.timestamp + SETTLEMENT_WINDOW);
        escrow.settleBatch(orders);
    }

    function test_gas_settleBatch_10() public {
        _stake(maker1, 500_000e6);
        DataTypes.Order[] memory orders = new DataTypes.Order[](10);
        for (uint256 i; i < 10; i++) {
            (, orders[i]) = _fillIntent(10_000e6);
        }

        vm.warp(block.timestamp + SETTLEMENT_WINDOW);
        escrow.settleBatch(orders);
    }

    function test_gas_reclaimExpired() public {
        _stake(maker1, 50_000e6);
        (, DataTypes.Order memory order) = _executeOrder(10_000e6);

        vm.warp(block.timestamp + COMMITMENT_TIMEOUT + 1);

        vm.prank(taker);
        escrow.reclaimExpired(order);
    }

    // ═══════════════════════════════════════════
    //  Disputes
    // ═══════════════════════════════════════════

    function test_gas_dispute() public {
        (, DataTypes.Order memory order) = _setupDisputableIntent();

        vm.startPrank(maker2);
        usdc.approve(address(disputes), type(uint256).max);
        disputes.dispute(order);
        vm.stopPrank();
    }

    function test_gas_resolveDispute() public {
        (bytes32 intentId, DataTypes.Order memory order) = _setupDisputableIntent();

        // Maker2 disputes
        vm.startPrank(maker2);
        usdc.approve(address(disputes), type(uint256).max);
        disputes.dispute(order);
        vm.stopPrank();

        // Maker3 attests fill is valid
        DataTypes.Commitment memory commitment = escrow.getCommitment(intentId);
        bytes memory sig = _signAttestation(
            maker3Key, intentId, true, commitment.fillTxHash, order.destinationChainId
        );
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = sig;

        disputes.resolveDispute(intentId, true, sigs);
    }

    function test_gas_finalizeExpiredDispute() public {
        (bytes32 intentId, DataTypes.Order memory order) = _setupDisputableIntent();

        vm.startPrank(maker2);
        usdc.approve(address(disputes), type(uint256).max);
        disputes.dispute(order);
        vm.stopPrank();

        vm.warp(block.timestamp + RESOLUTION_WINDOW + 1);
        disputes.finalizeExpiredDispute(intentId);
    }

    // ═══════════════════════════════════════════
    //  Helpers
    // ═══════════════════════════════════════════

    function _stake(address maker, uint256 amount) internal {
        vm.startPrank(maker);
        usdc.approve(address(staking), amount);
        staking.stake(amount);
        vm.stopPrank();
    }

    function _makeOrder(uint256 amount) internal returns (DataTypes.Order memory) {
        return DataTypes.Order({
            taker: taker,
            inputToken: address(usdc),
            inputAmount: amount,
            outputToken: address(usdc),
            minOutputAmount: amount - 10e6,
            destinationChainId: DEST_CHAIN_ID,
            destinationAddress: DEST_ADDRESS,
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

    function _executeOrder(uint256 amount) internal returns (bytes32, DataTypes.Order memory) {
        DataTypes.Order memory order = _makeOrder(amount);
        bytes memory sig = _signOrder(order);
        vm.prank(maker1);
        bytes32 id = escrow.executeOrder(order, sig);
        return (id, order);
    }

    function _fillIntent(uint256 amount) internal returns (bytes32, DataTypes.Order memory) {
        (bytes32 id, DataTypes.Order memory order) = _executeOrder(amount);
        vm.startPrank(maker1);
        escrow.submitFill(id, keccak256(abi.encodePacked("tx", id)));
        vm.stopPrank();
        return (id, order);
    }

    function _setupDisputableIntent() internal returns (bytes32, DataTypes.Order memory) {
        _stake(maker1, 50_000e6);
        _stake(maker2, 50_000e6);
        _stake(maker3, 50_000e6);
        return _fillIntent(10_000e6);
    }

    function _signAttestation(
        uint256 privateKey,
        bytes32 intentId,
        bool fillValid,
        bytes32 fillTxHash,
        uint256 destChainId
    ) internal view returns (bytes memory) {
        bytes32 structHash = SignatureLib.hashAttestation(intentId, fillValid, fillTxHash, destChainId);
        bytes32 digest = MessageHashUtils.toTypedDataHash(disputes.domainSeparator(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }
}
