// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {GauloiFillRegistry} from "../../src/GauloiFillRegistry.sol";
import {IGauloiFillRegistry} from "../../src/interfaces/IGauloiFillRegistry.sol";
import {MockERC20} from "../helpers/MockERC20.sol";
import {MockFeeOnTransferToken} from "../helpers/MockFeeOnTransferToken.sol";

contract GauloiFillRegistryTest is Test {
    GauloiFillRegistry public registry;
    MockERC20 public usdc;
    MockFeeOnTransferToken public feeToken;

    address public maker = makeAddr("maker");
    address public recipient = makeAddr("recipient");

    bytes32 public constant INTENT_ID = keccak256("intent-1");
    uint256 public constant FILL_AMOUNT = 1_000e6;

    function setUp() public {
        registry = new GauloiFillRegistry();
        usdc = new MockERC20("USD Coin", "USDC", 6);
        feeToken = new MockFeeOnTransferToken("Fee Token", "FEE", 6);

        usdc.mint(maker, 1_000_000e6);
        feeToken.mint(maker, 1_000_000e6);

        vm.startPrank(maker);
        usdc.approve(address(registry), type(uint256).max);
        feeToken.approve(address(registry), type(uint256).max);
        vm.stopPrank();
    }

    // --- fill ---

    function test_Fill_TransfersToRecipient() public {
        uint256 makerBefore = usdc.balanceOf(maker);

        vm.prank(maker);
        registry.fill(INTENT_ID, address(usdc), recipient, FILL_AMOUNT);

        assertEq(usdc.balanceOf(recipient), FILL_AMOUNT);
        assertEq(usdc.balanceOf(maker), makerBefore - FILL_AMOUNT);
        assertEq(usdc.balanceOf(address(registry)), 0); // registry never holds funds
    }

    function test_Fill_RecordsCommitment() public {
        vm.prank(maker);
        registry.fill(INTENT_ID, address(usdc), recipient, FILL_AMOUNT);

        bytes32 expected = registry.computeFillCommitment(
            address(usdc), recipient, FILL_AMOUNT, maker, block.number
        );
        assertEq(registry.getFill(INTENT_ID, maker), expected);
        assertTrue(registry.isFilled(INTENT_ID, maker));
    }

    function test_Fill_EmitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit IGauloiFillRegistry.Filled(INTENT_ID, address(usdc), recipient, FILL_AMOUNT, maker);

        vm.prank(maker);
        registry.fill(INTENT_ID, address(usdc), recipient, FILL_AMOUNT);
    }

    function test_Fill_RevertsOnDoubleFill_sameFiller() public {
        vm.prank(maker);
        registry.fill(INTENT_ID, address(usdc), recipient, FILL_AMOUNT);

        // Same intent, same filler — one fill per (intent, filler)
        vm.prank(maker);
        vm.expectRevert("GauloiFillRegistry: already filled");
        registry.fill(INTENT_ID, address(usdc), recipient, FILL_AMOUNT);
    }

    function test_Fill_squatterCannotBlockRealMaker() public {
        // A squatter records the same intentId first. Under (intentId, filler)
        // keying this occupies only the squatter's slot — the real maker's slot
        // is independent, so the maker can still record their genuine fill.
        address squatter = makeAddr("squatter");
        address squatterDest = makeAddr("squatterDest");
        usdc.mint(squatter, FILL_AMOUNT);
        vm.startPrank(squatter);
        usdc.approve(address(registry), FILL_AMOUNT);
        registry.fill(INTENT_ID, address(usdc), squatterDest, 1); // dust to poison the intent
        vm.stopPrank();

        // Real maker's fill still lands, and resolves against the maker's slot
        vm.prank(maker);
        registry.fill(INTENT_ID, address(usdc), recipient, FILL_AMOUNT);

        assertTrue(registry.isFilled(INTENT_ID, maker));
        assertEq(usdc.balanceOf(recipient), FILL_AMOUNT);
        // The squatter's slot is a separate, ignored record
        assertTrue(registry.isFilled(INTENT_ID, squatter));
        assertFalse(registry.getFill(INTENT_ID, maker) == registry.getFill(INTENT_ID, squatter));
    }

    function test_Fill_DistinctIntentsSameParams() public {
        // Two orders with identical params (different nonce → different intentId)
        // each need their own fill — one transfer cannot be claimed twice
        vm.startPrank(maker);
        registry.fill(keccak256("intent-a"), address(usdc), recipient, FILL_AMOUNT);
        registry.fill(keccak256("intent-b"), address(usdc), recipient, FILL_AMOUNT);
        vm.stopPrank();

        assertEq(usdc.balanceOf(recipient), 2 * FILL_AMOUNT);
        assertTrue(registry.isFilled(keccak256("intent-a"), maker));
        assertTrue(registry.isFilled(keccak256("intent-b"), maker));
    }

    function test_Fill_RevertsOnFeeOnTransferToken() public {
        vm.prank(maker);
        vm.expectRevert("GauloiFillRegistry: fee-on-transfer token");
        registry.fill(INTENT_ID, address(feeToken), recipient, FILL_AMOUNT);

        assertFalse(registry.isFilled(INTENT_ID, maker));
    }

    function test_Fill_RevertsWithoutApproval() public {
        address stranger = makeAddr("stranger");
        usdc.mint(stranger, FILL_AMOUNT);

        vm.prank(stranger);
        vm.expectRevert();
        registry.fill(INTENT_ID, address(usdc), recipient, FILL_AMOUNT);
    }

    function test_Fill_RevertsOnZeroInputs() public {
        vm.startPrank(maker);

        vm.expectRevert("GauloiFillRegistry: zero intent id");
        registry.fill(bytes32(0), address(usdc), recipient, FILL_AMOUNT);

        vm.expectRevert("GauloiFillRegistry: zero token");
        registry.fill(INTENT_ID, address(0), recipient, FILL_AMOUNT);

        vm.expectRevert("GauloiFillRegistry: zero recipient");
        registry.fill(INTENT_ID, address(usdc), address(0), FILL_AMOUNT);

        vm.expectRevert("GauloiFillRegistry: zero amount");
        registry.fill(INTENT_ID, address(usdc), recipient, 0);

        vm.stopPrank();
    }

    // --- views ---

    function test_GetFill_UnfilledIsZero() public view {
        assertEq(registry.getFill(INTENT_ID, maker), bytes32(0));
        assertFalse(registry.isFilled(INTENT_ID, maker));
    }

    function test_ComputeFillCommitment_MatchesPreimage() public {
        vm.roll(12_345);
        vm.prank(maker);
        registry.fill(INTENT_ID, address(usdc), recipient, FILL_AMOUNT);

        // A verifier holding the preimage recomputes the slot value:
        // wrong amount, filler, or block must not match
        bytes32 stored = registry.getFill(INTENT_ID, maker);
        assertEq(stored, keccak256(abi.encode(address(usdc), recipient, FILL_AMOUNT, maker, uint256(12_345))));
        assertTrue(stored != registry.computeFillCommitment(address(usdc), recipient, FILL_AMOUNT - 1, maker, 12_345));
        assertTrue(stored != registry.computeFillCommitment(address(usdc), recipient, FILL_AMOUNT, recipient, 12_345));
        assertTrue(stored != registry.computeFillCommitment(address(usdc), recipient, FILL_AMOUNT, maker, 12_344));
    }

    function testFuzz_Fill_CommitmentRoundTrip(bytes32 intentId, uint256 amount, uint64 blockNumber) public {
        vm.assume(intentId != bytes32(0));
        amount = bound(amount, 1, 1_000_000e6);
        vm.roll(uint256(blockNumber) + 1);

        vm.prank(maker);
        registry.fill(intentId, address(usdc), recipient, amount);

        assertEq(
            registry.getFill(intentId, maker),
            registry.computeFillCommitment(address(usdc), recipient, amount, maker, block.number)
        );
    }
}
