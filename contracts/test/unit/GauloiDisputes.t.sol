// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../helpers/BaseTest.sol";
import {MockERC20} from "../helpers/MockERC20.sol";
import {MockResolver} from "../helpers/MockResolver.sol";
import {MockBlacklistableERC20} from "../helpers/MockBlacklistableERC20.sol";
import {GauloiStaking} from "../../src/GauloiStaking.sol";
import {GauloiEscrow} from "../../src/GauloiEscrow.sol";
import {GauloiDisputes} from "../../src/GauloiDisputes.sol";
import {IGauloiDisputes} from "../../src/interfaces/IGauloiDisputes.sol";
import {IResolver} from "../../src/interfaces/IResolver.sol";
import {DataTypes} from "../../src/types/DataTypes.sol";
import {IntentLib} from "../../src/libraries/IntentLib.sol";

contract GauloiDisputesTest is BaseTest {
    GauloiDisputes public disputes;
    MockResolver public resolver;

    address public maker1Addr = makeAddr("disputeMaker1");
    address public maker2Addr = makeAddr("disputeMaker2");
    address public challenger = makeAddr("challenger"); // NOT a staked maker
    address public treasury = makeAddr("treasury");

    uint256 public constant RESOLUTION_WINDOW = 24 hours;
    uint256 public constant BOND_BPS = 200; // 2%
    uint256 public constant MIN_BOND = 250e6; // 250 USDC

    function setUp() public {
        taker = vm.addr(takerKey);

        usdc = new MockERC20("USD Coin", "USDC", 6);
        staking = new GauloiStaking(address(usdc), MIN_STAKE, COOLDOWN, 1 hours, owner);
        escrow = new GauloiEscrow(address(staking), SETTLEMENT_WINDOW, COMMITMENT_TIMEOUT, owner);

        disputes = new GauloiDisputes(
            address(staking),
            address(escrow),
            address(usdc),
            RESOLUTION_WINDOW,
            BOND_BPS,
            MIN_BOND,
            treasury,
            owner
        );

        resolver = new MockResolver();

        vm.startPrank(owner);
        staking.setEscrow(address(escrow));
        staking.setDisputes(address(disputes));
        escrow.setDisputes(address(disputes));
        escrow.addSupportedToken(address(usdc));
        disputes.setResolver(DEST_CHAIN_ID, address(resolver));
        vm.stopPrank();

        // Fund and stake makers; fund the (non-maker) challenger and taker
        usdc.mint(maker1Addr, 1_000_000e6);
        usdc.mint(maker2Addr, 1_000_000e6);
        usdc.mint(challenger, 1_000_000e6);
        usdc.mint(taker, 1_000_000e6);

        _stakeWithAddr(maker1Addr, 50_000e6);
        _stakeWithAddr(maker2Addr, 50_000e6);

        // Approvals
        vm.prank(taker);
        usdc.approve(address(escrow), type(uint256).max);
        vm.prank(challenger);
        usdc.approve(address(disputes), type(uint256).max);
        vm.prank(maker2Addr);
        usdc.approve(address(disputes), type(uint256).max);
        vm.prank(taker);
        usdc.approve(address(disputes), type(uint256).max);
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

        vm.prank(maker1Addr);
        bytes32 intentId = escrow.executeOrder(order, sig);

        vm.prank(maker1Addr);
        escrow.submitFill(order, keccak256("dest_tx"));

        return (intentId, order);
    }

    function _challengeAs(address who, DataTypes.Order memory order) internal returns (bytes32) {
        vm.prank(who);
        disputes.challenge(order);
        return IntentLib.computeIntentId(order);
    }

    // =========================================================================
    // Corridor resolution windows
    // =========================================================================

    function test_challenge_corridorResolutionWindowOverride() public {
        vm.prank(owner);
        disputes.setCorridorResolutionWindow(DEST_CHAIN_ID, 2 hours);
        assertEq(disputes.resolutionWindowFor(DEST_CHAIN_ID), 2 hours);
        assertEq(disputes.resolutionWindowFor(999), RESOLUTION_WINDOW);

        (bytes32 intentId, DataTypes.Order memory order) = _createAndFillIntent(10_000e6);
        _challengeAs(challenger, order);

        assertEq(disputes.getDispute(intentId).disputeDeadline, block.timestamp + 2 hours);
    }

    function test_setCorridorResolutionWindow_bounds() public {
        vm.startPrank(owner);
        vm.expectRevert("GauloiDisputes: window out of range");
        disputes.setCorridorResolutionWindow(DEST_CHAIN_ID, 30 minutes);
        vm.expectRevert("GauloiDisputes: window out of range");
        disputes.setCorridorResolutionWindow(DEST_CHAIN_ID, 31 days);
        disputes.setCorridorResolutionWindow(DEST_CHAIN_ID, 0); // clearing allowed
        vm.stopPrank();

        vm.prank(challenger);
        vm.expectRevert();
        disputes.setCorridorResolutionWindow(DEST_CHAIN_ID, 2 hours);
    }

    // =========================================================================
    // challenge()
    // =========================================================================

    function test_challenge() public {
        (bytes32 intentId, DataTypes.Order memory order) = _createAndFillIntent(10_000e6);

        uint256 bond = disputes.calculateDisputeBond(10_000e6);
        uint256 balBefore = usdc.balanceOf(challenger);

        vm.expectEmit(true, true, false, true);
        emit IGauloiDisputes.DisputeRaised(intentId, challenger, bond);
        _challengeAs(challenger, order);

        // Bond pulled
        assertEq(usdc.balanceOf(challenger), balBefore - bond);

        // Dispute stored
        DataTypes.Dispute memory disp = disputes.getDispute(intentId);
        assertEq(disp.challenger, challenger);
        assertEq(disp.bondAmount, bond);
        assertEq(disp.disputeDeadline, block.timestamp + RESOLUTION_WINDOW);
        assertFalse(disp.resolved);

        // Order stored for resolution
        assertEq(disputes.getDisputeOrder(intentId).inputAmount, 10_000e6);

        // Escrow state transitioned
        assertTrue(escrow.getCommitment(intentId).state == DataTypes.IntentState.Disputed);
    }

    function test_challenge_permissionless_takerCanChallenge() public {
        // The taker — the victim of a fraudulent fill — needs no maker stake
        (bytes32 intentId, DataTypes.Order memory order) = _createAndFillIntent(10_000e6);

        vm.prank(taker);
        disputes.challenge(order);

        assertEq(disputes.getDispute(intentId).challenger, taker);
    }

    function test_challenge_revertsIfNotFilled() public {
        // Committed but not filled
        DataTypes.Order memory order = _makeOrder(10_000e6, 9_990e6);
        bytes memory sig = _signOrder(takerKey, order);
        vm.prank(maker1Addr);
        escrow.executeOrder(order, sig);

        vm.prank(challenger);
        vm.expectRevert("GauloiDisputes: not filled");
        disputes.challenge(order);
    }

    function test_challenge_revertsIfWindowClosed() public {
        (, DataTypes.Order memory order) = _createAndFillIntent(10_000e6);

        vm.warp(block.timestamp + SETTLEMENT_WINDOW);

        vm.prank(challenger);
        vm.expectRevert("GauloiDisputes: window closed");
        disputes.challenge(order);
    }

    function test_challenge_revertsIfAlreadyChallenged() public {
        (, DataTypes.Order memory order) = _createAndFillIntent(10_000e6);

        _challengeAs(challenger, order);

        vm.prank(maker2Addr);
        vm.expectRevert("GauloiDisputes: already challenged");
        disputes.challenge(order);
    }

    function test_challenge_revertsOnSelfChallenge() public {
        (, DataTypes.Order memory order) = _createAndFillIntent(10_000e6);

        vm.startPrank(maker1Addr);
        usdc.approve(address(disputes), type(uint256).max);
        vm.expectRevert("GauloiDisputes: cannot challenge own fill");
        disputes.challenge(order);
        vm.stopPrank();
    }

    function test_challenge_revertsWithoutBond() public {
        (, DataTypes.Order memory order) = _createAndFillIntent(10_000e6);

        address broke = makeAddr("broke");
        vm.prank(broke);
        vm.expectRevert();
        disputes.challenge(order);
    }

    function test_calculateDisputeBond() public view {
        // 2% of 100k = 2000 > 250 min
        assertEq(disputes.calculateDisputeBond(100_000e6), 2_000e6);
        // 2% of 1k = 20 < 250 min → min applies
        assertEq(disputes.calculateDisputeBond(1_000e6), MIN_BOND);
    }

    // =========================================================================
    // resolve() — verdict Valid
    // =========================================================================

    function test_resolve_valid() public {
        (bytes32 intentId, DataTypes.Order memory order) = _createAndFillIntent(10_000e6);
        uint256 bond = disputes.calculateDisputeBond(10_000e6);
        _challengeAs(challenger, order);

        resolver.setVerdict(IResolver.Verdict.Valid);

        uint256 makerBefore = usdc.balanceOf(maker1Addr);
        uint256 treasuryBefore = usdc.balanceOf(treasury);

        vm.expectEmit(true, false, false, true);
        emit IGauloiDisputes.DisputeResolved(intentId, true);
        disputes.resolve(intentId, "");

        // Maker: escrowed funds + half the bond
        assertEq(usdc.balanceOf(maker1Addr) - makerBefore, 10_000e6 + bond / 2);
        // Treasury: other half
        assertEq(usdc.balanceOf(treasury) - treasuryBefore, bond - bond / 2);

        // State
        DataTypes.Dispute memory disp = disputes.getDispute(intentId);
        assertTrue(disp.resolved);
        assertTrue(disp.fillDeemedValid);
        assertTrue(escrow.getCommitment(intentId).state == DataTypes.IntentState.Settled);
        assertEq(staking.getExposure(maker1Addr), 0);

        // Order storage reclaimed
        assertEq(disputes.getDisputeOrder(intentId).taker, address(0));
    }

    function test_resolve_valid_anyoneCanSubmit() public {
        (bytes32 intentId, DataTypes.Order memory order) = _createAndFillIntent(10_000e6);
        _challengeAs(challenger, order);
        resolver.setVerdict(IResolver.Verdict.Valid);

        vm.prank(makeAddr("randomKeeper"));
        disputes.resolve(intentId, "");

        assertTrue(disputes.getDispute(intentId).resolved);
    }

    // =========================================================================
    // resolve() — verdict Invalid
    // =========================================================================

    function test_resolve_invalid() public {
        (bytes32 intentId, DataTypes.Order memory order) = _createAndFillIntent(20_000e6);
        uint256 bond = disputes.calculateDisputeBond(20_000e6);
        _challengeAs(challenger, order);

        resolver.setVerdict(IResolver.Verdict.Invalid);

        uint256 takerBefore = usdc.balanceOf(taker);
        uint256 challengerBefore = usdc.balanceOf(challenger);
        uint256 treasuryBefore = usdc.balanceOf(treasury);

        disputes.resolve(intentId, "");

        // Taker refunded from escrow
        assertEq(usdc.balanceOf(taker) - takerBefore, 20_000e6);

        // Slash curve: 20k fill → multiplier = 2 + 650e6/20_000e6 = 2.0325 → 40_650e6
        uint256 expectedSlash = 40_650e6;
        assertEq(staking.getStake(maker1Addr), 50_000e6 - expectedSlash);

        // Challenger: bond back + 25% of slash
        assertEq(usdc.balanceOf(challenger) - challengerBefore, bond + expectedSlash / 4);

        // Treasury: 75% of slash
        assertEq(usdc.balanceOf(treasury) - treasuryBefore, expectedSlash - expectedSlash / 4);

        // State
        DataTypes.Dispute memory disp = disputes.getDispute(intentId);
        assertTrue(disp.resolved);
        assertFalse(disp.fillDeemedValid);
        assertTrue(escrow.getCommitment(intentId).state == DataTypes.IntentState.Expired);
        assertEq(staking.getExposure(maker1Addr), 0);
    }

    function test_resolve_invalid_slashExceedsStake() public {
        // 30k fill: slash = 30k * (2 + 650/30000) ≈ 60_650e6 > 50k stake → full stake
        (bytes32 intentId, DataTypes.Order memory order) = _createAndFillIntent(30_000e6);
        _challengeAs(challenger, order);
        resolver.setVerdict(IResolver.Verdict.Invalid);

        uint256 takerBefore = usdc.balanceOf(taker);

        disputes.resolve(intentId, "");

        // Full stake slashed, maker deactivated, exposure fully absorbed by cap
        assertEq(staking.getStake(maker1Addr), 0);
        assertFalse(staking.isActiveMaker(maker1Addr));
        assertEq(staking.getExposure(maker1Addr), 0);

        // Taker still made whole from escrow
        assertEq(usdc.balanceOf(taker) - takerBefore, 30_000e6);
    }

    // =========================================================================
    // resolve() — guards
    // =========================================================================

    function test_resolve_revertsOnPendingVerdict() public {
        (bytes32 intentId, DataTypes.Order memory order) = _createAndFillIntent(10_000e6);
        _challengeAs(challenger, order);

        // MockResolver defaults to Pending
        vm.expectRevert("GauloiDisputes: no verdict");
        disputes.resolve(intentId, "");
    }

    function test_resolve_revertsIfNoDispute() public {
        vm.expectRevert("GauloiDisputes: no dispute");
        disputes.resolve(keccak256("nothing"), "");
    }

    function test_resolve_revertsIfAlreadyResolved() public {
        (bytes32 intentId, DataTypes.Order memory order) = _createAndFillIntent(10_000e6);
        _challengeAs(challenger, order);
        resolver.setVerdict(IResolver.Verdict.Valid);
        disputes.resolve(intentId, "");

        vm.expectRevert("GauloiDisputes: already resolved");
        disputes.resolve(intentId, "");
    }

    function test_resolve_revertsAfterDeadline() public {
        (bytes32 intentId, DataTypes.Order memory order) = _createAndFillIntent(10_000e6);
        _challengeAs(challenger, order);
        resolver.setVerdict(IResolver.Verdict.Valid);

        vm.warp(block.timestamp + RESOLUTION_WINDOW + 1);

        vm.expectRevert("GauloiDisputes: deadline passed");
        disputes.resolve(intentId, "");
    }

    function test_challenge_revertsIfNoResolverForCorridor() public {
        // A fill to a corridor with no resolver cannot be challenged at all —
        // otherwise the deadline default would force-slash an undefendable maker
        DataTypes.Order memory order = DataTypes.Order({
            taker: taker,
            inputToken: address(usdc),
            inputAmount: 10_000e6,
            outputToken: address(usdc),
            minOutputAmount: 9_990e6,
            destinationChainId: 999_999, // unconfigured corridor
            destinationAddress: DEST_ADDRESS,
            expiry: block.timestamp + 1 hours,
            nonce: _testNonce++
        });
        bytes memory sig = _signOrder(takerKey, order);
        vm.prank(maker1Addr);
        bytes32 intentId = escrow.executeOrder(order, sig);
        vm.prank(maker1Addr);
        escrow.submitFill(order, keccak256("tx"));

        vm.prank(challenger);
        vm.expectRevert("GauloiDisputes: no resolver for corridor");
        disputes.challenge(order);
    }

    function test_finalizeExpired_voidsWhenResolverRemoved() public {
        // Owner removes the resolver after a challenge opens — the maker can no
        // longer defend, so finalize must void in the maker's favor, not convict
        (bytes32 intentId, DataTypes.Order memory order) = _createAndFillIntent(10_000e6);
        _challengeAs(challenger, order);

        vm.prank(owner);
        disputes.setResolver(DEST_CHAIN_ID, address(0));

        vm.warp(block.timestamp + RESOLUTION_WINDOW + 1);

        uint256 makerStakeBefore = staking.getStake(maker1Addr);
        disputes.finalizeExpiredDispute(intentId);

        // Resolved valid: maker NOT slashed, intent settled
        assertTrue(disputes.getDispute(intentId).fillDeemedValid);
        assertEq(staking.getStake(maker1Addr), makerStakeBefore);
        assertTrue(escrow.getCommitment(intentId).state == DataTypes.IntentState.Settled);
    }

    function test_resolve_passesArgsToResolver() public {
        (bytes32 intentId, DataTypes.Order memory order) = _createAndFillIntent(10_000e6);
        _challengeAs(challenger, order);
        resolver.setVerdict(IResolver.Verdict.Valid);

        disputes.resolve(intentId, hex"deadbeef");

        assertEq(resolver.lastIntentId(), intentId);
        assertEq(resolver.lastEvidence(), hex"deadbeef");
        assertEq(resolver.lastDestinationChainId(), DEST_CHAIN_ID);
        assertEq(resolver.callCount(), 1);
    }

    // =========================================================================
    // finalizeExpiredDispute() — maker must defend; silence convicts
    // =========================================================================

    function test_finalizeExpired_resolvesInvalid() public {
        (bytes32 intentId, DataTypes.Order memory order) = _createAndFillIntent(20_000e6);
        uint256 bond = disputes.calculateDisputeBond(20_000e6);
        _challengeAs(challenger, order);

        vm.warp(block.timestamp + RESOLUTION_WINDOW + 1);

        uint256 takerBefore = usdc.balanceOf(taker);
        uint256 challengerBefore = usdc.balanceOf(challenger);

        vm.expectEmit(true, false, false, true);
        emit IGauloiDisputes.DisputeResolved(intentId, false);
        disputes.finalizeExpiredDispute(intentId);

        // Undefended challenge resolves against the maker
        uint256 expectedSlash = 40_650e6;
        assertEq(usdc.balanceOf(taker) - takerBefore, 20_000e6);
        assertEq(usdc.balanceOf(challenger) - challengerBefore, bond + expectedSlash / 4);
        assertEq(staking.getStake(maker1Addr), 50_000e6 - expectedSlash);
        assertTrue(escrow.getCommitment(intentId).state == DataTypes.IntentState.Expired);
    }

    function test_finalizeExpired_revertsBeforeDeadline() public {
        (bytes32 intentId, DataTypes.Order memory order) = _createAndFillIntent(10_000e6);
        _challengeAs(challenger, order);

        vm.expectRevert("GauloiDisputes: deadline not passed");
        disputes.finalizeExpiredDispute(intentId);
    }

    function test_finalizeExpired_revertsIfResolved() public {
        (bytes32 intentId, DataTypes.Order memory order) = _createAndFillIntent(10_000e6);
        _challengeAs(challenger, order);
        resolver.setVerdict(IResolver.Verdict.Valid);
        disputes.resolve(intentId, "");

        vm.warp(block.timestamp + RESOLUTION_WINDOW + 1);
        vm.expectRevert("GauloiDisputes: already resolved");
        disputes.finalizeExpiredDispute(intentId);
    }

    function test_finalizeExpired_revertsIfNoDispute() public {
        vm.expectRevert("GauloiDisputes: no dispute");
        disputes.finalizeExpiredDispute(keccak256("nothing"));
    }

    // =========================================================================
    // Slash curve
    // =========================================================================

    function test_calculateSlashAmount_curve() public view {
        // Large fill: multiplier → base (2×). 100k fill → 2 + 650/100_000 = 2.0065×
        assertEq(disputes.calculateSlashAmount(100_000e6, type(uint256).max), 200_650e6);

        // Tiny fill: capped at 15×. 50 USDC fill → 2 + 13 = 15 (capped)
        assertEq(disputes.calculateSlashAmount(50e6, type(uint256).max), 750e6);

        // Capped at maker stake
        assertEq(disputes.calculateSlashAmount(100_000e6, 50_000e6), 50_000e6);

        // Zero fill → zero
        assertEq(disputes.calculateSlashAmount(0, 50_000e6), 0);
    }

    // =========================================================================
    // Admin
    // =========================================================================

    function test_setResolver() public {
        address newResolver = makeAddr("newResolver");
        vm.expectEmit(true, true, true, false);
        emit IGauloiDisputes.ResolverUpdated(1, address(0), newResolver);
        vm.prank(owner);
        disputes.setResolver(1, newResolver);
        assertEq(address(disputes.resolvers(1)), newResolver);

        // Can be unset (corridor loses its arbiter → resolve reverts, finalize still works)
        vm.prank(owner);
        disputes.setResolver(1, address(0));
        assertEq(address(disputes.resolvers(1)), address(0));
    }

    function test_setResolver_onlyOwner() public {
        vm.prank(challenger);
        vm.expectRevert();
        disputes.setResolver(1, address(resolver));
    }

    function test_setTreasury() public {
        address newTreasury = makeAddr("newTreasury");
        vm.prank(owner);
        disputes.setTreasury(newTreasury);
        assertEq(disputes.treasury(), newTreasury);

        vm.prank(owner);
        vm.expectRevert("GauloiDisputes: zero address");
        disputes.setTreasury(address(0));

        vm.prank(challenger);
        vm.expectRevert();
        disputes.setTreasury(newTreasury);
    }

    function test_setDisputeResolutionWindow_bounds() public {
        vm.startPrank(owner);
        vm.expectRevert("GauloiDisputes: window out of range");
        disputes.setDisputeResolutionWindow(30 minutes);
        vm.expectRevert("GauloiDisputes: window out of range");
        disputes.setDisputeResolutionWindow(31 days);
        disputes.setDisputeResolutionWindow(12 hours);
        vm.stopPrank();
        assertEq(disputes.disputeResolutionWindow(), 12 hours);
    }

    function test_setDisputeBondParams() public {
        vm.prank(owner);
        disputes.setDisputeBondParams(100, 500e6);
        assertEq(disputes.disputeBondBps(), 100);
        assertEq(disputes.minDisputeBond(), 500e6);

        vm.prank(owner);
        vm.expectRevert("GauloiDisputes: bps exceeds 100%");
        disputes.setDisputeBondParams(10_001, 500e6);
    }

    function test_setSlashCurveParams_bounds() public {
        vm.startPrank(owner);
        vm.expectRevert("GauloiDisputes: invalid slash curve");
        disputes.setSlashCurveParams(0, 650e6, 15);
        vm.expectRevert("GauloiDisputes: invalid slash curve");
        disputes.setSlashCurveParams(3, 650e6, 2); // max < base
        vm.expectRevert("GauloiDisputes: invalid slash curve");
        disputes.setSlashCurveParams(2, 650e6, 101);
        disputes.setSlashCurveParams(3, 500e6, 20);
        vm.stopPrank();
        assertEq(disputes.slashBaseMultiplier(), 3);
    }

    function test_withdrawTreasury() public {
        usdc.mint(address(disputes), 1_000e6);

        vm.prank(owner);
        disputes.withdrawTreasury(treasury, 1_000e6);
        assertEq(usdc.balanceOf(treasury), 1_000e6);

        vm.prank(challenger);
        vm.expectRevert();
        disputes.withdrawTreasury(challenger, 1);
    }

    function test_constructor_zeroAddressReverts() public {
        vm.expectRevert("GauloiDisputes: zero address");
        new GauloiDisputes(address(0), address(escrow), address(usdc), 24 hours, 200, 250e6, treasury, owner);

        vm.expectRevert("GauloiDisputes: zero address");
        new GauloiDisputes(address(staking), address(escrow), address(usdc), 24 hours, 200, 250e6, address(0), owner);
    }
}

/// @dev Blacklist tolerance: resolution must complete even when a reward
///      recipient is blacklisted by the bond token (funds stay in the contract,
///      recoverable via withdrawTreasury)
contract GauloiDisputesBlacklistTest is BaseTest {
    GauloiDisputes public disputes;
    MockResolver public resolver;
    MockBlacklistableERC20 public busdc;

    address public maker1Addr = makeAddr("blMaker1");
    address public challenger = makeAddr("blChallenger");
    address public treasury = makeAddr("blTreasury");

    function setUp() public {
        taker = vm.addr(takerKey);

        busdc = new MockBlacklistableERC20("USD Coin", "USDC", 6);
        staking = new GauloiStaking(address(busdc), MIN_STAKE, COOLDOWN, 1 hours, owner);
        escrow = new GauloiEscrow(address(staking), SETTLEMENT_WINDOW, COMMITMENT_TIMEOUT, owner);
        disputes = new GauloiDisputes(
            address(staking), address(escrow), address(busdc),
            24 hours, 200, 250e6, treasury, owner
        );
        resolver = new MockResolver();

        vm.startPrank(owner);
        staking.setEscrow(address(escrow));
        staking.setDisputes(address(disputes));
        escrow.setDisputes(address(disputes));
        escrow.addSupportedToken(address(busdc));
        disputes.setResolver(DEST_CHAIN_ID, address(resolver));
        vm.stopPrank();

        busdc.mint(maker1Addr, 1_000_000e6);
        busdc.mint(challenger, 1_000_000e6);
        busdc.mint(taker, 1_000_000e6);

        vm.startPrank(maker1Addr);
        busdc.approve(address(staking), 50_000e6);
        staking.stake(50_000e6);
        vm.stopPrank();

        vm.prank(taker);
        busdc.approve(address(escrow), type(uint256).max);
        vm.prank(challenger);
        busdc.approve(address(disputes), type(uint256).max);
    }

    function test_resolve_valid_blacklistedMakerCannotBlock() public {
        DataTypes.Order memory order = DataTypes.Order({
            taker: taker,
            inputToken: address(busdc),
            inputAmount: 10_000e6,
            outputToken: address(busdc),
            minOutputAmount: 9_990e6,
            destinationChainId: DEST_CHAIN_ID,
            destinationAddress: DEST_ADDRESS,
            expiry: block.timestamp + 1 hours,
            nonce: 1
        });

        // Sign with escrow's domain
        bytes memory sig = _signOrderFor(order);

        vm.prank(maker1Addr);
        bytes32 intentId = escrow.executeOrder(order, sig);
        vm.prank(maker1Addr);
        escrow.submitFill(order, keccak256("tx"));

        vm.prank(challenger);
        disputes.challenge(order);

        // Maker gets blacklisted mid-dispute
        busdc.blacklist(maker1Addr);

        resolver.setVerdict(IResolver.Verdict.Valid);

        // Resolution completes despite the blacklisted maker
        disputes.resolve(intentId, "");

        DataTypes.Dispute memory disp = disputes.getDispute(intentId);
        assertTrue(disp.resolved);
        assertTrue(disp.fillDeemedValid);
        assertTrue(escrow.getCommitment(intentId).state == DataTypes.IntentState.Settled);
        // Maker's bond share stranded in disputes, escrow amount stranded in escrow —
        // both recoverable by owner rescue paths; the dispute itself cannot be bricked
    }

    function _signOrderFor(DataTypes.Order memory order) internal view returns (bytes memory) {
        return _signOrder(takerKey, order);
    }
}
