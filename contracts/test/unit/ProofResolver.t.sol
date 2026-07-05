// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../helpers/BaseTest.sol";
import {MockERC20} from "../helpers/MockERC20.sol";
import {MockFillProofVerifier} from "../helpers/MockFillProofVerifier.sol";
import {GauloiStaking} from "../../src/GauloiStaking.sol";
import {GauloiEscrow} from "../../src/GauloiEscrow.sol";
import {GauloiDisputes} from "../../src/GauloiDisputes.sol";
import {GauloiFillRegistry} from "../../src/GauloiFillRegistry.sol";
import {ProofResolver} from "../../src/resolvers/ProofResolver.sol";
import {IResolver} from "../../src/interfaces/IResolver.sol";
import {DataTypes} from "../../src/types/DataTypes.sol";
import {IntentLib} from "../../src/libraries/IntentLib.sol";

contract ProofResolverTest is BaseTest {
    ProofResolver public resolver;
    MockFillProofVerifier public verifier;
    GauloiFillRegistry public registry; // "destination" registry (same VM in tests)

    address public makerAddr = makeAddr("proofMaker");
    address public recipient = DEST_ADDRESS;

    // Registry _fills storage slot — pinned by test_fillSlot_matchesRegistryLayout
    uint256 public constant FILLS_SLOT = 0;

    function setUp() public {
        taker = vm.addr(takerKey);

        usdc = new MockERC20("USD Coin", "USDC", 6);
        staking = new GauloiStaking(address(usdc), MIN_STAKE, COOLDOWN, 1 hours, owner);
        escrow = new GauloiEscrow(address(staking), SETTLEMENT_WINDOW, COMMITMENT_TIMEOUT, owner);
        registry = new GauloiFillRegistry();
        verifier = new MockFillProofVerifier();
        resolver = new ProofResolver(address(verifier), address(escrow), owner);

        vm.startPrank(owner);
        staking.setEscrow(address(escrow));
        escrow.addSupportedToken(address(usdc));
        resolver.configureCorridor(DEST_CHAIN_ID, address(registry), FILLS_SLOT);
        vm.stopPrank();

        usdc.mint(makerAddr, 1_000_000e6);
        usdc.mint(taker, 1_000_000e6);

        vm.startPrank(makerAddr);
        usdc.approve(address(staking), 50_000e6);
        staking.stake(50_000e6);
        usdc.approve(address(registry), type(uint256).max);
        vm.stopPrank();

        vm.prank(taker);
        usdc.approve(address(escrow), type(uint256).max);
    }

    // Commit + fill an intent; returns intentId and order
    function _committedIntent(uint256 amount, uint256 minOut)
        internal
        returns (bytes32 intentId, DataTypes.Order memory order)
    {
        order = _makeOrder(amount, minOut);
        bytes memory sig = _signOrder(takerKey, order);
        vm.prank(makerAddr);
        intentId = escrow.executeOrder(order, sig);
        vm.prank(makerAddr);
        escrow.submitFill(order, keccak256("dest"));
    }

    // Encode ProofResolver evidence (preimage + opaque proof)
    function _evidence(address token, address recip, uint256 amount, uint256 blockNumber)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(token, recip, amount, blockNumber, hex"");
    }

    // Seed the verifier so the maker's slot proves to `commitment`
    function _seed(bytes32 intentId, bytes32 commitment) internal {
        bytes32 slot = resolver.fillStorageSlot(intentId, makerAddr, FILLS_SLOT);
        verifier.setSlot(DEST_CHAIN_ID, address(registry), slot, commitment);
    }

    // =====================================================================
    // Storage-layout pin: the resolver's slot math MUST match the registry.
    // If GauloiFillRegistry's storage layout ever changes, this fails loudly.
    // =====================================================================

    function test_fillSlot_matchesRegistryLayout() public {
        bytes32 intentId = keccak256("layout-probe");
        vm.roll(777);

        // Record a real fill in the registry
        vm.prank(makerAddr);
        registry.fill(intentId, address(usdc), recipient, 1_000e6);

        bytes32 expected = registry.getFill(intentId, makerAddr);
        assertTrue(expected != bytes32(0));

        // Read the raw slot the resolver computes and confirm it holds that value
        bytes32 slot = resolver.fillStorageSlot(intentId, makerAddr, FILLS_SLOT);
        bytes32 raw = vm.load(address(registry), slot);
        assertEq(raw, expected, "resolver slot math diverged from registry layout");
    }

    // =====================================================================
    // resolve() verdicts
    // =====================================================================

    function test_resolve_validFill_returnsValid() public {
        (bytes32 intentId, DataTypes.Order memory order) = _committedIntent(10_000e6, 9_990e6);

        // Maker recorded a satisfying fill at dest block 500
        uint256 blk = 500;
        bytes32 commitment = registry.computeFillCommitment(address(usdc), recipient, 9_990e6, makerAddr, blk);
        _seed(intentId, commitment);

        IResolver.Verdict v =
            resolver.resolve(intentId, order, _evidence(address(usdc), recipient, 9_990e6, blk));
        assertTrue(v == IResolver.Verdict.Valid);
    }

    function test_resolve_emptySlot_returnsInvalid() public {
        (bytes32 intentId, DataTypes.Order memory order) = _committedIntent(10_000e6, 9_990e6);

        // Proven empty — maker never recorded a fill
        _seed(intentId, bytes32(0));

        IResolver.Verdict v =
            resolver.resolve(intentId, order, _evidence(address(usdc), recipient, 9_990e6, 500));
        assertTrue(v == IResolver.Verdict.Invalid);
    }

    function test_resolve_underpaidFill_returnsInvalid() public {
        (bytes32 intentId, DataTypes.Order memory order) = _committedIntent(10_000e6, 9_990e6);

        // Maker recorded a fill for LESS than minOutput
        uint256 blk = 500;
        uint256 shortAmount = 9_000e6;
        bytes32 commitment =
            registry.computeFillCommitment(address(usdc), recipient, shortAmount, makerAddr, blk);
        _seed(intentId, commitment);

        IResolver.Verdict v =
            resolver.resolve(intentId, order, _evidence(address(usdc), recipient, shortAmount, blk));
        assertTrue(v == IResolver.Verdict.Invalid);
    }

    function test_resolve_wrongRecipient_returnsInvalid() public {
        (bytes32 intentId, DataTypes.Order memory order) = _committedIntent(10_000e6, 9_990e6);

        uint256 blk = 500;
        address wrongRecipient = makeAddr("attacker");
        bytes32 commitment =
            registry.computeFillCommitment(address(usdc), wrongRecipient, 9_990e6, makerAddr, blk);
        _seed(intentId, commitment);

        IResolver.Verdict v =
            resolver.resolve(intentId, order, _evidence(address(usdc), wrongRecipient, 9_990e6, blk));
        assertTrue(v == IResolver.Verdict.Invalid);
    }

    function test_resolve_wrongToken_returnsInvalid() public {
        (bytes32 intentId, DataTypes.Order memory order) = _committedIntent(10_000e6, 9_990e6);

        uint256 blk = 500;
        address wrongToken = makeAddr("wrongToken");
        bytes32 commitment =
            registry.computeFillCommitment(wrongToken, recipient, 9_990e6, makerAddr, blk);
        _seed(intentId, commitment);

        IResolver.Verdict v =
            resolver.resolve(intentId, order, _evidence(wrongToken, recipient, 9_990e6, blk));
        assertTrue(v == IResolver.Verdict.Invalid);
    }

    function test_resolve_lyingPreimage_reverts() public {
        (bytes32 intentId, DataTypes.Order memory order) = _committedIntent(10_000e6, 9_990e6);

        // Proven slot is a satisfying fill...
        uint256 blk = 500;
        bytes32 commitment = registry.computeFillCommitment(address(usdc), recipient, 9_990e6, makerAddr, blk);
        _seed(intentId, commitment);

        // ...but the submitter provides a preimage that doesn't hash to it
        vm.expectRevert("ProofResolver: preimage mismatch");
        resolver.resolve(intentId, order, _evidence(address(usdc), recipient, 1e6, blk));
    }

    function test_resolve_unverifiableProof_reverts() public {
        (bytes32 intentId, DataTypes.Order memory order) = _committedIntent(10_000e6, 9_990e6);
        // Nothing seeded — verifier cannot prove the slot
        vm.expectRevert("MockFillProofVerifier: unverifiable proof");
        resolver.resolve(intentId, order, _evidence(address(usdc), recipient, 9_990e6, 500));
    }

    function test_resolve_unconfiguredCorridor_reverts() public {
        DataTypes.Order memory order = _makeOrder(10_000e6, 9_990e6);
        order.destinationChainId = 999_999;
        // give it a real committed intent id path is unnecessary — corridor check is first
        vm.expectRevert("ProofResolver: corridor not configured");
        resolver.resolve(keccak256("x"), order, _evidence(address(usdc), recipient, 9_990e6, 1));
    }

    function test_resolve_bindsToCommittedMaker_notSubmitter() public {
        // The proof is looked up at the COMMITTED maker's slot. A fill recorded by
        // some other address (its own slot) cannot satisfy the dispute.
        (bytes32 intentId, DataTypes.Order memory order) = _committedIntent(10_000e6, 9_990e6);

        // Seed the committed maker's slot as empty; a different address's slot is
        // irrelevant because the resolver only ever queries makerAddr's slot.
        _seed(intentId, bytes32(0));

        IResolver.Verdict v =
            resolver.resolve(intentId, order, _evidence(address(usdc), recipient, 9_990e6, 500));
        assertTrue(v == IResolver.Verdict.Invalid);
    }

    // =====================================================================
    // Admin
    // =====================================================================

    function test_setVerifier() public {
        MockFillProofVerifier v2 = new MockFillProofVerifier();
        vm.prank(owner);
        resolver.setVerifier(address(v2));
        assertEq(address(resolver.verifier()), address(v2));

        vm.prank(owner);
        vm.expectRevert("ProofResolver: zero address");
        resolver.setVerifier(address(0));

        vm.prank(makerAddr);
        vm.expectRevert();
        resolver.setVerifier(address(v2));
    }

    function test_configureCorridor_onlyOwner() public {
        vm.prank(makerAddr);
        vm.expectRevert();
        resolver.configureCorridor(1, address(registry), 0);
    }
}

/// @dev End-to-end: a dispute resolved trustlessly through the ProofResolver
///      wired into GauloiDisputes — proving the maker's fill valid releases escrow.
contract ProofResolverIntegrationTest is BaseTest {
    GauloiDisputes public disputes;
    ProofResolver public resolver;
    MockFillProofVerifier public verifier;
    GauloiFillRegistry public registry;

    address public makerAddr = makeAddr("e2eProofMaker");
    address public challengerAddr = makeAddr("e2eProofChallenger");
    address public treasury = makeAddr("e2eProofTreasury");

    function setUp() public {
        taker = vm.addr(takerKey);

        usdc = new MockERC20("USD Coin", "USDC", 6);
        staking = new GauloiStaking(address(usdc), MIN_STAKE, COOLDOWN, 1 hours, owner);
        escrow = new GauloiEscrow(address(staking), SETTLEMENT_WINDOW, COMMITMENT_TIMEOUT, owner);
        disputes = new GauloiDisputes(
            address(staking), address(escrow), address(usdc),
            24 hours, 200, 250e6, treasury, owner
        );
        registry = new GauloiFillRegistry();
        verifier = new MockFillProofVerifier();
        resolver = new ProofResolver(address(verifier), address(escrow), owner);

        vm.startPrank(owner);
        staking.setEscrow(address(escrow));
        staking.setDisputes(address(disputes));
        escrow.setDisputes(address(disputes));
        escrow.addSupportedToken(address(usdc));
        disputes.setResolver(DEST_CHAIN_ID, address(resolver));
        resolver.configureCorridor(DEST_CHAIN_ID, address(registry), 0);
        vm.stopPrank();

        usdc.mint(makerAddr, 1_000_000e6);
        usdc.mint(challengerAddr, 1_000_000e6);
        usdc.mint(taker, 1_000_000e6);

        vm.startPrank(makerAddr);
        usdc.approve(address(staking), 50_000e6);
        staking.stake(50_000e6);
        vm.stopPrank();

        vm.prank(taker);
        usdc.approve(address(escrow), type(uint256).max);
        vm.prank(challengerAddr);
        usdc.approve(address(disputes), type(uint256).max);
    }

    function test_disputeResolvedByProof_validFill() public {
        DataTypes.Order memory order = _makeOrder(10_000e6, 9_990e6);
        bytes memory sig = _signOrder(takerKey, order);
        vm.prank(makerAddr);
        bytes32 intentId = escrow.executeOrder(order, sig);
        vm.prank(makerAddr);
        escrow.submitFill(order, keccak256("dest"));

        // Challenge
        vm.prank(challengerAddr);
        disputes.challenge(order);
        uint256 bond = disputes.calculateDisputeBond(10_000e6);

        // Seed a proof that the maker's registry slot holds a satisfying fill
        uint256 blk = 500;
        bytes32 commitment =
            registry.computeFillCommitment(address(usdc), DEST_ADDRESS, 9_990e6, makerAddr, blk);
        bytes32 slot = resolver.fillStorageSlot(intentId, makerAddr, 0);
        verifier.setSlot(DEST_CHAIN_ID, address(registry), slot, commitment);

        bytes memory evidence = abi.encode(address(usdc), DEST_ADDRESS, uint256(9_990e6), blk, hex"");

        uint256 makerBefore = usdc.balanceOf(makerAddr);
        disputes.resolve(intentId, evidence);

        // Fill proven valid: maker gets escrow + half the challenger's bond
        assertEq(usdc.balanceOf(makerAddr) - makerBefore, 10_000e6 + bond / 2);
        assertTrue(escrow.getCommitment(intentId).state == DataTypes.IntentState.Settled);
        assertTrue(disputes.getDispute(intentId).fillDeemedValid);
    }

    function test_disputeResolvedByProof_missingFill_slashesMaker() public {
        DataTypes.Order memory order = _makeOrder(20_000e6, 19_950e6);
        bytes memory sig = _signOrder(takerKey, order);
        vm.prank(makerAddr);
        bytes32 intentId = escrow.executeOrder(order, sig);
        vm.prank(makerAddr);
        escrow.submitFill(order, keccak256("fake"));

        vm.prank(challengerAddr);
        disputes.challenge(order);

        // Prove the maker's slot is EMPTY — no fill was recorded
        bytes32 slot = resolver.fillStorageSlot(intentId, makerAddr, 0);
        verifier.setSlot(DEST_CHAIN_ID, address(registry), slot, bytes32(0));

        bytes memory evidence = abi.encode(address(usdc), DEST_ADDRESS, uint256(19_950e6), uint256(1), hex"");

        uint256 takerBefore = usdc.balanceOf(taker);
        disputes.resolve(intentId, evidence);

        // Fill proven invalid: taker refunded, maker slashed
        assertEq(usdc.balanceOf(taker) - takerBefore, 20_000e6);
        assertEq(staking.getStake(makerAddr), 50_000e6 - 40_650e6); // 20k * (2 + 650/20000)
        assertTrue(escrow.getCommitment(intentId).state == DataTypes.IntentState.Expired);
        assertFalse(disputes.getDispute(intentId).fillDeemedValid);
    }
}
