// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../helpers/BaseTest.sol";
import {MockERC20} from "../helpers/MockERC20.sol";
import {GauloiStaking} from "../../src/GauloiStaking.sol";
import {GauloiEscrow} from "../../src/GauloiEscrow.sol";
import {GauloiDisputes} from "../../src/GauloiDisputes.sol";
import {CouncilResolver} from "../../src/resolvers/CouncilResolver.sol";
import {IResolver} from "../../src/interfaces/IResolver.sol";
import {DataTypes} from "../../src/types/DataTypes.sol";

contract CouncilResolverTest is BaseTest {
    CouncilResolver public council;

    // Council members with known keys, addresses sorted ascending by construction below
    uint256 public member1Key = 0xC0DE01;
    uint256 public member2Key = 0xC0DE02;
    uint256 public member3Key = 0xC0DE03;
    address public member1;
    address public member2;
    address public member3;

    bytes32 public constant INTENT_ID = keccak256("intent");

    function setUp() public {
        member1 = vm.addr(member1Key);
        member2 = vm.addr(member2Key);
        member3 = vm.addr(member3Key);

        address[] memory members = new address[](3);
        members[0] = member1;
        members[1] = member2;
        members[2] = member3;

        council = new CouncilResolver(members, 2, owner);
    }

    function _dummyOrder() internal view returns (DataTypes.Order memory) {
        return DataTypes.Order({
            taker: address(0x1),
            inputToken: address(0x2),
            inputAmount: 1,
            outputToken: address(0x3),
            minOutputAmount: 1,
            destinationChainId: DEST_CHAIN_ID,
            destinationAddress: DEST_ADDRESS,
            expiry: 1,
            nonce: 1
        });
    }

    function _signVerdict(uint256 key, bytes32 intentId, bool fillValid) internal view returns (bytes memory) {
        bytes32 digest = council.verdictDigest(intentId, fillValid, DEST_CHAIN_ID);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev signatures must be sorted by ascending recovered address
    function _sortedSigs(uint256 keyA, uint256 keyB, bytes32 intentId, bool fillValid)
        internal view returns (bytes[] memory sigs)
    {
        (uint256 lowKey, uint256 highKey) =
            vm.addr(keyA) < vm.addr(keyB) ? (keyA, keyB) : (keyB, keyA);
        sigs = new bytes[](2);
        sigs[0] = _signVerdict(lowKey, intentId, fillValid);
        sigs[1] = _signVerdict(highKey, intentId, fillValid);
    }

    // --- Construction ---

    function test_constructor() public view {
        assertEq(council.memberCount(), 3);
        assertEq(council.threshold(), 2);
        assertTrue(council.isMember(member1));
        assertTrue(council.isMember(member2));
        assertTrue(council.isMember(member3));
    }

    function test_constructor_invalidThresholdReverts() public {
        address[] memory members = new address[](2);
        members[0] = member1;
        members[1] = member2;

        vm.expectRevert("CouncilResolver: invalid threshold");
        new CouncilResolver(members, 3, owner);

        vm.expectRevert("CouncilResolver: invalid threshold");
        new CouncilResolver(members, 0, owner);
    }

    function test_constructor_duplicateMemberReverts() public {
        address[] memory members = new address[](2);
        members[0] = member1;
        members[1] = member1;

        vm.expectRevert("CouncilResolver: already a member");
        new CouncilResolver(members, 1, owner);
    }

    // --- resolve ---

    function test_resolve_thresholdMet_valid() public view {
        bytes memory evidence = abi.encode(true, _sortedSigs(member1Key, member2Key, INTENT_ID, true));
        IResolver.Verdict verdict = council.resolve(INTENT_ID, _dummyOrder(), evidence);
        assertTrue(verdict == IResolver.Verdict.Valid);
    }

    function test_resolve_thresholdMet_invalid() public view {
        bytes memory evidence = abi.encode(false, _sortedSigs(member2Key, member3Key, INTENT_ID, false));
        IResolver.Verdict verdict = council.resolve(INTENT_ID, _dummyOrder(), evidence);
        assertTrue(verdict == IResolver.Verdict.Invalid);
    }

    function test_resolve_belowThreshold_pending() public view {
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _signVerdict(member1Key, INTENT_ID, true);
        bytes memory evidence = abi.encode(true, sigs);

        IResolver.Verdict verdict = council.resolve(INTENT_ID, _dummyOrder(), evidence);
        assertTrue(verdict == IResolver.Verdict.Pending);
    }

    function test_resolve_duplicateSignerReverts() public {
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _signVerdict(member1Key, INTENT_ID, true);
        sigs[1] = _signVerdict(member1Key, INTENT_ID, true);
        bytes memory evidence = abi.encode(true, sigs);

        vm.expectRevert("CouncilResolver: signers not sorted");
        council.resolve(INTENT_ID, _dummyOrder(), evidence);
    }

    function test_resolve_unsortedSignersReverts() public {
        bytes[] memory sorted = _sortedSigs(member1Key, member2Key, INTENT_ID, true);
        bytes[] memory unsorted = new bytes[](2);
        unsorted[0] = sorted[1];
        unsorted[1] = sorted[0];
        bytes memory evidence = abi.encode(true, unsorted);

        vm.expectRevert("CouncilResolver: signers not sorted");
        council.resolve(INTENT_ID, _dummyOrder(), evidence);
    }

    function test_resolve_nonMemberReverts() public {
        uint256 strangerKey = 0xBAD;
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _signVerdict(strangerKey, INTENT_ID, true);
        bytes memory evidence = abi.encode(true, sigs);

        vm.expectRevert("CouncilResolver: not a member");
        council.resolve(INTENT_ID, _dummyOrder(), evidence);
    }

    function test_resolve_signatureOverWrongVerdictDoesNotCount() public {
        // Member signs fillValid=false, evidence claims fillValid=true —
        // recovered address is garbage, not a member
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _signVerdict(member1Key, INTENT_ID, false);
        bytes memory evidence = abi.encode(true, sigs);

        vm.expectRevert("CouncilResolver: not a member");
        council.resolve(INTENT_ID, _dummyOrder(), evidence);
    }

    function test_resolve_signatureBoundToIntent() public {
        // Signature for another intent doesn't recover to a member for this one
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _signVerdict(member1Key, keccak256("other-intent"), true);
        bytes memory evidence = abi.encode(true, sigs);

        vm.expectRevert("CouncilResolver: not a member");
        council.resolve(INTENT_ID, _dummyOrder(), evidence);
    }

    // --- Membership admin ---

    function test_addRemoveMember() public {
        address newMember = makeAddr("newMember");

        vm.prank(owner);
        council.addMember(newMember);
        assertTrue(council.isMember(newMember));
        assertEq(council.memberCount(), 4);

        vm.prank(owner);
        council.removeMember(newMember);
        assertFalse(council.isMember(newMember));
        assertEq(council.memberCount(), 3);
    }

    function test_removeMember_cannotBreakThreshold() public {
        // 3 members, threshold 2 → can remove one, not two
        vm.startPrank(owner);
        council.removeMember(member3);
        vm.expectRevert("CouncilResolver: would break threshold");
        council.removeMember(member2);
        vm.stopPrank();
    }

    function test_setThreshold_bounds() public {
        vm.startPrank(owner);
        council.setThreshold(3);
        assertEq(council.threshold(), 3);

        vm.expectRevert("CouncilResolver: invalid threshold");
        council.setThreshold(4);
        vm.expectRevert("CouncilResolver: invalid threshold");
        council.setThreshold(0);
        vm.stopPrank();
    }

    function test_membershipAdmin_onlyOwner() public {
        address stranger = makeAddr("stranger");
        vm.startPrank(stranger);
        vm.expectRevert();
        council.addMember(stranger);
        vm.expectRevert();
        council.removeMember(member1);
        vm.expectRevert();
        council.setThreshold(1);
        vm.stopPrank();
    }
}

/// @dev End-to-end: a dispute resolved through the real CouncilResolver wired
///      into GauloiDisputes
contract CouncilResolverIntegrationTest is BaseTest {
    GauloiDisputes public disputes;
    CouncilResolver public council;

    uint256 public member1Key = 0xC0DE01;
    uint256 public member2Key = 0xC0DE02;

    address public makerAddr = makeAddr("councilMaker");
    address public challengerAddr = makeAddr("councilChallenger");
    address public treasury = makeAddr("councilTreasury");

    function setUp() public {
        taker = vm.addr(takerKey);

        usdc = new MockERC20("USD Coin", "USDC", 6);
        staking = new GauloiStaking(address(usdc), MIN_STAKE, COOLDOWN, 1 hours, owner);
        escrow = new GauloiEscrow(address(staking), SETTLEMENT_WINDOW, COMMITMENT_TIMEOUT, owner);
        disputes = new GauloiDisputes(
            address(staking), address(escrow), address(usdc),
            24 hours, 200, 250e6, treasury, owner
        );

        address[] memory members = new address[](2);
        members[0] = vm.addr(member1Key);
        members[1] = vm.addr(member2Key);
        council = new CouncilResolver(members, 2, owner);

        vm.startPrank(owner);
        staking.setEscrow(address(escrow));
        staking.setDisputes(address(disputes));
        escrow.setDisputes(address(disputes));
        escrow.addSupportedToken(address(usdc));
        disputes.setResolver(DEST_CHAIN_ID, address(council));
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

    function test_disputeResolvedThroughCouncil() public {
        // Fill an intent
        DataTypes.Order memory order = _makeOrder(10_000e6, 9_990e6);
        bytes memory sig = _signOrder(takerKey, order);
        vm.prank(makerAddr);
        bytes32 intentId = escrow.executeOrder(order, sig);
        vm.prank(makerAddr);
        escrow.submitFill(order, keccak256("tx"));

        // Challenge
        vm.prank(challengerAddr);
        disputes.challenge(order);
        uint256 bond = disputes.calculateDisputeBond(10_000e6);

        uint256 makerBefore = usdc.balanceOf(makerAddr);

        // Anyone submits the council's fill-valid verdict
        disputes.resolve(intentId, _councilEvidence(intentId, true));

        assertEq(usdc.balanceOf(makerAddr) - makerBefore, 10_000e6 + bond / 2);
        assertTrue(escrow.getCommitment(intentId).state == DataTypes.IntentState.Settled);
        assertTrue(disputes.getDispute(intentId).fillDeemedValid);
    }

    /// @dev Both council members sign, sorted by ascending signer address
    function _councilEvidence(bytes32 intentId, bool fillValid) internal view returns (bytes memory) {
        bytes32 digest = council.verdictDigest(intentId, fillValid, DEST_CHAIN_ID);
        (uint256 lowKey, uint256 highKey) = vm.addr(member1Key) < vm.addr(member2Key)
            ? (member1Key, member2Key)
            : (member2Key, member1Key);

        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(lowKey, digest);
        sigs[1] = _sign(highKey, digest);
        return abi.encode(fillValid, sigs);
    }

    function _sign(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function test_insufficientCouncilSignaturesStayPending() public {
        DataTypes.Order memory order = _makeOrder(10_000e6, 9_990e6);
        bytes memory sig = _signOrder(takerKey, order);
        vm.prank(makerAddr);
        bytes32 intentId = escrow.executeOrder(order, sig);
        vm.prank(makerAddr);
        escrow.submitFill(order, keccak256("tx"));

        vm.prank(challengerAddr);
        disputes.challenge(order);

        // Only one of two required signatures
        bytes32 digest = council.verdictDigest(intentId, true, DEST_CHAIN_ID);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(member1Key, digest);
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = abi.encodePacked(r, s, v);

        vm.expectRevert("GauloiDisputes: no verdict");
        disputes.resolve(intentId, abi.encode(true, sigs));
    }
}
