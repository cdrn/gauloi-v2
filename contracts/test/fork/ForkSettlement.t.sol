// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {GauloiStaking} from "../../src/GauloiStaking.sol";
import {GauloiEscrow} from "../../src/GauloiEscrow.sol";
import {GauloiDisputes} from "../../src/GauloiDisputes.sol";
import {DataTypes} from "../../src/types/DataTypes.sol";
import {IntentLib} from "../../src/libraries/IntentLib.sol";
import {SignatureLib} from "../../src/libraries/SignatureLib.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @notice Fork tests against real Ethereum mainnet USDC and USDT.
/// @dev Run with: forge test --match-contract ForkSettlement --fork-url $ETHEREUM_RPC_URL
contract ForkSettlementTest is Test {
    using SafeERC20 for IERC20;

    // Mainnet token addresses
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    // Mainnet USDC whale (Circle)
    address constant USDC_WHALE = 0x55FE002aefF02F77364de339a1292923A15844B8;
    // Mainnet USDT whale (Binance)
    address constant USDT_WHALE = 0xF977814e90dA44bFA03b6295A0616a897441aceC;

    GauloiStaking public staking;
    GauloiEscrow public escrow;
    GauloiDisputes public disputes;

    IERC20 public usdc;
    IERC20 public usdt;

    address public owner = makeAddr("owner");

    // Taker with private key for signing
    uint256 public takerKey = 0x7A4E5;
    address public taker;

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
        // Fork must be active — set via --fork-url or foundry.toml [profile.fork]
        usdc = IERC20(USDC);
        usdt = IERC20(USDT);

        taker = vm.addr(takerKey);
        makerA = vm.addr(makerAKey);
        makerB = vm.addr(makerBKey);
        makerC = vm.addr(makerCKey);

        // Deploy protocol using USDC as stake token
        staking = new GauloiStaking(USDC, MIN_STAKE, COOLDOWN, 1 hours, owner);
        escrow = new GauloiEscrow(address(staking), SETTLEMENT_WINDOW, COMMITMENT_TIMEOUT, owner);
        disputes = new GauloiDisputes(
            address(staking), address(escrow), USDC,
            RESOLUTION_WINDOW, BOND_BPS, MIN_BOND, owner
        );

        // Wire contracts
        vm.startPrank(owner);
        staking.setEscrow(address(escrow));
        staking.setDisputes(address(disputes));
        escrow.setDisputes(address(disputes));
        escrow.addSupportedToken(USDC);
        escrow.addSupportedToken(USDT);
        vm.stopPrank();

        // Fund accounts from whales
        _fundFromWhale(USDC_WHALE, USDC, makerA, 500_000e6);
        _fundFromWhale(USDC_WHALE, USDC, makerB, 500_000e6);
        _fundFromWhale(USDC_WHALE, USDC, makerC, 500_000e6);
        _fundFromWhale(USDC_WHALE, USDC, taker, 500_000e6);
        _fundFromWhale(USDT_WHALE, USDT, taker, 500_000e6);

        // Approve escrow for taker (both tokens)
        vm.startPrank(taker);
        usdc.approve(address(escrow), type(uint256).max);
        usdt.forceApprove(address(escrow), type(uint256).max);
        vm.stopPrank();

        // Stake all makers
        _stake(makerA, 100_000e6);
        _stake(makerB, 100_000e6);
        _stake(makerC, 100_000e6);
    }

    function _fundFromWhale(address whale, address token, address to, uint256 amount) internal {
        vm.prank(whale);
        IERC20(token).safeTransfer(to, amount);
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
    // Real USDC: full settlement loop
    // =========================================================================

    function test_fork_USDC_happyPath() public {
        uint256 takerBalBefore = usdc.balanceOf(taker);
        uint256 makerBalBefore = usdc.balanceOf(makerA);

        // 1. Taker signs order, maker executes
        DataTypes.Order memory order = _makeOrder(USDC, 50_000e6, USDC, 49_900e6);
        bytes memory sig = _signOrder(order);

        vm.prank(makerA);
        bytes32 intentId = escrow.executeOrder(order, sig);

        assertEq(usdc.balanceOf(taker), takerBalBefore - 50_000e6);
        assertEq(usdc.balanceOf(address(escrow)), 50_000e6);

        // 2. MakerA submits fill evidence
        vm.prank(makerA);
        escrow.submitFill(intentId, keccak256("arb_tx_real"));

        // 3. Wait for settlement window
        vm.warp(block.timestamp + SETTLEMENT_WINDOW);

        // 4. Settle
        escrow.settle(order);

        // Verify
        assertEq(usdc.balanceOf(makerA), makerBalBefore + 50_000e6);
        assertTrue(escrow.getCommitment(intentId).state == DataTypes.IntentState.Settled);
        assertEq(staking.getMakerInfo(makerA).activeExposure, 0);
    }

    // =========================================================================
    // Real USDT: the critical test — USDT's non-standard transfer
    // =========================================================================

    function test_fork_USDT_happyPath() public {
        uint256 takerUsdtBefore = usdt.balanceOf(taker);

        // Taker signs USDT order, maker executes
        DataTypes.Order memory order = _makeOrder(USDT, 25_000e6, USDC, 24_950e6);
        bytes memory sig = _signOrder(order);

        vm.prank(makerA);
        bytes32 intentId = escrow.executeOrder(order, sig);

        assertEq(usdt.balanceOf(taker), takerUsdtBefore - 25_000e6);
        assertEq(usdt.balanceOf(address(escrow)), 25_000e6);

        // Maker submits fill
        vm.prank(makerA);
        escrow.submitFill(intentId, keccak256("fill_usdt"));

        vm.warp(block.timestamp + SETTLEMENT_WINDOW);
        escrow.settle(order);

        // Maker receives USDT (the input token)
        assertEq(usdt.balanceOf(makerA), 25_000e6);
        assertTrue(escrow.getCommitment(intentId).state == DataTypes.IntentState.Settled);
    }

    // =========================================================================
    // Real USDT: taker reclaims expired commitment
    // =========================================================================

    function test_fork_USDT_expiry_reclaim() public {
        DataTypes.Order memory order = _makeOrder(USDT, 10_000e6, USDC, 9_990e6);
        bytes memory sig = _signOrder(order);

        vm.prank(makerA);
        escrow.executeOrder(order, sig);

        uint256 takerBalBefore = usdt.balanceOf(taker);

        vm.warp(block.timestamp + COMMITMENT_TIMEOUT + 1);

        vm.prank(taker);
        escrow.reclaimExpired(order);

        assertEq(usdt.balanceOf(taker) - takerBalBefore, 10_000e6);
        bytes32 intentId = IntentLib.computeIntentId(order);
        assertTrue(escrow.getCommitment(intentId).state == DataTypes.IntentState.Expired);
    }

    // =========================================================================
    // Real USDC: batch settle
    // =========================================================================

    function test_fork_USDC_batchSettle() public {
        DataTypes.Order[] memory orders = new DataTypes.Order[](3);

        for (uint256 i = 0; i < 3; i++) {
            orders[i] = _makeOrder(USDC, 10_000e6, USDC, 9_990e6);
            bytes memory sig = _signOrder(orders[i]);

            vm.prank(makerA);
            bytes32 intentId = escrow.executeOrder(orders[i], sig);

            vm.startPrank(makerA);
            escrow.submitFill(intentId, keccak256(abi.encode("fill", i)));
            vm.stopPrank();
        }

        vm.warp(block.timestamp + SETTLEMENT_WINDOW);

        uint256 makerBalBefore = usdc.balanceOf(makerA);
        escrow.settleBatch(orders);

        assertEq(usdc.balanceOf(makerA) - makerBalBefore, 30_000e6);
        assertEq(staking.getMakerInfo(makerA).activeExposure, 0);
    }

    // =========================================================================
    // Real USDC: dispute + resolution with real token transfers
    // =========================================================================

    function test_fork_USDC_dispute_fillInvalid() public {
        // Create and fill
        DataTypes.Order memory order = _makeOrder(USDC, 20_000e6, USDC, 19_950e6);
        bytes memory sig = _signOrder(order);

        bytes32 fakeFill = keccak256("fake");
        vm.prank(makerA);
        bytes32 intentId = escrow.executeOrder(order, sig);

        vm.prank(makerA);
        escrow.submitFill(intentId, fakeFill);

        uint256 makerAStake = staking.getMakerInfo(makerA).stakedAmount;

        // MakerB disputes
        uint256 bondAmount = disputes.calculateDisputeBond(20_000e6);
        vm.startPrank(makerB);
        usdc.approve(address(disputes), bondAmount);
        disputes.dispute(order);
        vm.stopPrank();

        // MakerC attests: fill is invalid
        bytes memory attestSig = _signAttestation(makerCKey, intentId, false, fakeFill, DEST_CHAIN);
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = attestSig;

        uint256 takerBalBefore = usdc.balanceOf(taker);
        uint256 makerBBalBefore = usdc.balanceOf(makerB);

        disputes.resolveDispute(intentId, false, sigs);

        // Taker refunded
        assertEq(usdc.balanceOf(taker) - takerBalBefore, 20_000e6);

        // MakerB gets bond back + 25% of slashed stake
        uint256 expectedReward = bondAmount + (makerAStake / 4);
        assertEq(usdc.balanceOf(makerB) - makerBBalBefore, expectedReward);

        // MakerA slashed
        assertFalse(staking.isActiveMaker(makerA));
        assertEq(staking.getMakerInfo(makerA).stakedAmount, 0);
    }

    // =========================================================================
    // Real USDC: staking lifecycle
    // =========================================================================

    function test_fork_USDC_stakeUnstake() public {
        address newMaker = makeAddr("newMaker");
        _fundFromWhale(USDC_WHALE, USDC, newMaker, 50_000e6);

        vm.startPrank(newMaker);
        usdc.approve(address(staking), 50_000e6);
        staking.stake(50_000e6);
        vm.stopPrank();

        assertTrue(staking.isActiveMaker(newMaker));
        assertEq(staking.getMakerInfo(newMaker).stakedAmount, 50_000e6);

        // Request unstake
        vm.prank(newMaker);
        staking.requestUnstake(20_000e6);

        // Wait for cooldown
        vm.warp(block.timestamp + COOLDOWN);

        uint256 balBefore = usdc.balanceOf(newMaker);
        vm.prank(newMaker);
        staking.completeUnstake();

        assertEq(usdc.balanceOf(newMaker) - balBefore, 20_000e6);
        assertEq(staking.getMakerInfo(newMaker).stakedAmount, 30_000e6);
        assertTrue(staking.isActiveMaker(newMaker));
    }
}
