// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../helpers/BaseTest.sol";
import {GauloiStaking} from "../../src/GauloiStaking.sol";
import {IGauloiStaking} from "../../src/interfaces/IGauloiStaking.sol";
import {DataTypes} from "../../src/types/DataTypes.sol";
import {MockPriceFeed} from "../helpers/MockPriceFeed.sol";

contract GauloiStakingTest is BaseTest {
    address public mockEscrow = makeAddr("escrow");
    address public mockDisputes = makeAddr("disputes");

    function setUp() public {
        _deployBase();
        vm.startPrank(owner);
        staking.setEscrow(mockEscrow);
        staking.setDisputes(mockDisputes);
        vm.stopPrank();
    }

    // --- Staking ---

    function test_stake() public {
        _stakeMaker(maker1, 50_000e6);

        DataTypes.MakerInfo memory info = staking.getMakerInfo(maker1);
        assertEq(info.stakedAmount, 50_000e6);
        assertTrue(info.isActive);
        assertEq(info.activeExposure, 0);
    }

    function test_stake_belowMinimum_notActive() public {
        _stakeMaker(maker1, 5_000e6); // Below MIN_STAKE

        DataTypes.MakerInfo memory info = staking.getMakerInfo(maker1);
        assertEq(info.stakedAmount, 5_000e6);
        assertFalse(info.isActive);
    }

    function test_stake_incrementalToActive() public {
        _stakeMaker(maker1, 5_000e6);
        assertFalse(staking.isActiveMaker(maker1));

        _stakeMaker(maker1, 5_000e6); // Now at 10,000 = MIN_STAKE
        assertTrue(staking.isActiveMaker(maker1));
    }

    function test_stake_zeroAmount_reverts() public {
        vm.startPrank(maker1);
        usdc.approve(address(staking), 1e6);
        vm.expectRevert("GauloiStaking: zero amount");
        staking.stake(0);
        vm.stopPrank();
    }

    function test_stake_emitsEvent() public {
        vm.startPrank(maker1);
        usdc.approve(address(staking), 50_000e6);
        vm.expectEmit(true, false, false, true);
        emit IGauloiStaking.Staked(maker1, 50_000e6);
        staking.stake(50_000e6);
        vm.stopPrank();
    }

    // --- Unstake ---

    function test_requestUnstake() public {
        _stakeMaker(maker1, 50_000e6);

        vm.prank(maker1);
        staking.requestUnstake(20_000e6);

        DataTypes.MakerInfo memory info = staking.getMakerInfo(maker1);
        assertEq(info.unstakeAmount, 20_000e6);
        assertGt(info.unstakeRequestTime, 0);
    }

    function test_completeUnstake() public {
        _stakeMaker(maker1, 50_000e6);

        vm.prank(maker1);
        staking.requestUnstake(20_000e6);

        vm.warp(block.timestamp + COOLDOWN);

        uint256 balBefore = usdc.balanceOf(maker1);
        vm.prank(maker1);
        staking.completeUnstake();
        uint256 balAfter = usdc.balanceOf(maker1);

        assertEq(balAfter - balBefore, 20_000e6);

        DataTypes.MakerInfo memory info = staking.getMakerInfo(maker1);
        assertEq(info.stakedAmount, 30_000e6);
        assertEq(info.unstakeRequestTime, 0);
        assertEq(info.unstakeAmount, 0);
        assertTrue(info.isActive); // Still above MIN_STAKE
    }

    function test_completeUnstake_deactivatesIfBelowMin() public {
        _stakeMaker(maker1, 15_000e6);

        vm.prank(maker1);
        staking.requestUnstake(10_000e6);

        vm.warp(block.timestamp + COOLDOWN);

        vm.prank(maker1);
        staking.completeUnstake();

        assertFalse(staking.isActiveMaker(maker1));
    }

    function test_completeUnstake_beforeCooldown_reverts() public {
        _stakeMaker(maker1, 50_000e6);

        vm.prank(maker1);
        staking.requestUnstake(20_000e6);

        vm.warp(block.timestamp + COOLDOWN - 1);

        vm.prank(maker1);
        vm.expectRevert("GauloiStaking: cooldown not elapsed");
        staking.completeUnstake();
    }

    function test_requestUnstake_whilePending_reverts() public {
        _stakeMaker(maker1, 50_000e6);

        vm.prank(maker1);
        staking.requestUnstake(20_000e6);

        vm.prank(maker1);
        vm.expectRevert("GauloiStaking: unstake already pending");
        staking.requestUnstake(10_000e6);
    }

    function test_requestUnstake_moreThanAvailable_reverts() public {
        _stakeMaker(maker1, 50_000e6);

        // Simulate exposure
        vm.prank(mockEscrow);
        staking.increaseExposure(maker1, 40_000e6);

        vm.prank(maker1);
        vm.expectRevert("GauloiStaking: insufficient available stake");
        staking.requestUnstake(20_000e6); // Only 10k available
    }

    function test_completeUnstake_exposureChangedDuringCooldown_reverts() public {
        _stakeMaker(maker1, 50_000e6);

        vm.prank(maker1);
        staking.requestUnstake(30_000e6); // Request 30k, 50k available at request time

        // During cooldown, exposure increases
        vm.prank(mockEscrow);
        staking.increaseExposure(maker1, 30_000e6); // Now only 20k available

        vm.warp(block.timestamp + COOLDOWN);

        vm.prank(maker1);
        vm.expectRevert("GauloiStaking: insufficient available stake");
        staking.completeUnstake(); // Can't unstake 30k, only 20k available
    }

    // --- Exposure ---

    function test_increaseExposure() public {
        _stakeMaker(maker1, 50_000e6);

        vm.prank(mockEscrow);
        staking.increaseExposure(maker1, 30_000e6);

        DataTypes.MakerInfo memory info = staking.getMakerInfo(maker1);
        assertEq(info.activeExposure, 30_000e6);
    }

    function test_increaseExposure_exceedsStake_reverts() public {
        _stakeMaker(maker1, 50_000e6);

        vm.prank(mockEscrow);
        vm.expectRevert("GauloiStaking: exposure exceeds stake");
        staking.increaseExposure(maker1, 60_000e6);
    }

    function test_increaseExposure_inactiveMaker_reverts() public {
        _stakeMaker(maker1, 5_000e6); // Below minimum, not active

        vm.prank(mockEscrow);
        vm.expectRevert("GauloiStaking: maker not active");
        staking.increaseExposure(maker1, 1_000e6);
    }

    function test_increaseExposure_notEscrow_reverts() public {
        _stakeMaker(maker1, 50_000e6);

        vm.prank(maker1);
        vm.expectRevert("GauloiStaking: caller is not escrow");
        staking.increaseExposure(maker1, 10_000e6);
    }

    function test_decreaseExposure() public {
        _stakeMaker(maker1, 50_000e6);

        vm.prank(mockEscrow);
        staking.increaseExposure(maker1, 30_000e6);

        vm.prank(mockEscrow);
        staking.decreaseExposure(maker1, 10_000e6);

        assertEq(staking.getMakerInfo(maker1).activeExposure, 20_000e6);
    }

    function test_decreaseExposure_caps_at_zero() public {
        _stakeMaker(maker1, 50_000e6);

        // No exposure to decrease — should cap at 0, not revert
        vm.prank(mockEscrow);
        staking.decreaseExposure(maker1, 10_000e6);

        DataTypes.MakerInfo memory info = staking.getMakerInfo(maker1);
        assertEq(info.activeExposure, 0);
    }

    function test_availableCapacity() public {
        _stakeMaker(maker1, 50_000e6);

        vm.prank(mockEscrow);
        staking.increaseExposure(maker1, 20_000e6);

        assertEq(staking.availableCapacity(maker1), 30_000e6);
    }

    function test_availableCapacity_inactive_returnsZero() public view {
        assertEq(staking.availableCapacity(maker1), 0);
    }

    // --- Slashing ---

    function test_slash() public {
        _stakeMaker(maker1, 50_000e6);

        vm.prank(mockEscrow);
        staking.increaseExposure(maker1, 30_000e6);

        bytes32 intentId = keccak256("test_intent");
        uint256 disputesBalBefore = usdc.balanceOf(mockDisputes);

        vm.prank(mockDisputes);
        uint256 slashed = staking.slash(maker1, intentId);

        assertEq(slashed, 50_000e6);

        DataTypes.MakerInfo memory info = staking.getMakerInfo(maker1);
        assertEq(info.stakedAmount, 0);
        assertEq(info.activeExposure, 0);
        assertFalse(info.isActive);
        assertEq(info.unstakeRequestTime, 0);

        assertEq(usdc.balanceOf(mockDisputes) - disputesBalBefore, 50_000e6);
    }

    function test_slash_cancelsUnstake() public {
        _stakeMaker(maker1, 50_000e6);

        vm.prank(maker1);
        staking.requestUnstake(20_000e6);

        vm.prank(mockDisputes);
        staking.slash(maker1, keccak256("intent"));

        DataTypes.MakerInfo memory info = staking.getMakerInfo(maker1);
        assertEq(info.unstakeRequestTime, 0);
        assertEq(info.unstakeAmount, 0);
    }

    function test_slash_notDisputes_reverts() public {
        _stakeMaker(maker1, 50_000e6);

        vm.prank(maker1);
        vm.expectRevert("GauloiStaking: caller is not disputes");
        staking.slash(maker1, keccak256("intent"));
    }

    function test_slash_noStake_reverts() public {
        vm.prank(mockDisputes);
        vm.expectRevert("GauloiStaking: nothing to slash");
        staking.slash(maker1, keccak256("intent"));
    }

    // --- Access control ---

    function test_setEscrow_onlyOwner() public {
        vm.prank(maker1);
        vm.expectRevert();
        staking.setEscrow(makeAddr("newEscrow"));
    }

    function test_setDisputes_onlyOwner() public {
        vm.prank(maker1);
        vm.expectRevert();
        staking.setDisputes(makeAddr("newDisputes"));
    }

    function test_setEscrow_zeroAddress_reverts() public {
        vm.prank(owner);
        vm.expectRevert("GauloiStaking: zero address");
        staking.setEscrow(address(0));
    }

    // --- Fuzz ---

    function testFuzz_stake_anyAmount(uint256 amount) public {
        amount = bound(amount, 1, 1_000_000e6);

        vm.startPrank(maker1);
        usdc.approve(address(staking), amount);
        staking.stake(amount);
        vm.stopPrank();

        assertEq(staking.getMakerInfo(maker1).stakedAmount, amount);
    }

    function testFuzz_exposure_cannotExceedStake(uint256 stakeAmt, uint256 exposure) public {
        stakeAmt = bound(stakeAmt, MIN_STAKE, 1_000_000e6);
        exposure = bound(exposure, stakeAmt + 1, type(uint256).max);

        _stakeMaker(maker1, stakeAmt);

        vm.prank(mockEscrow);
        vm.expectRevert("GauloiStaking: exposure exceeds stake");
        staking.increaseExposure(maker1, exposure);
    }

    // --- Oracle-adjusted exposure ---

    function test_increaseExposure_oracleReducesCapacity() public {
        _stakeMaker(maker1, 50_000e6);

        // USDC depegs to $0.50
        priceFeed.setPrice(0.5e8);

        // Stake is worth $25,000 — exposure of 30,000 should fail
        vm.prank(mockEscrow);
        vm.expectRevert("GauloiStaking: exposure exceeds stake");
        staking.increaseExposure(maker1, 30_000e6);

        // But 25,000 should succeed
        vm.prank(mockEscrow);
        staking.increaseExposure(maker1, 25_000e6);

        assertEq(staking.getMakerInfo(maker1).activeExposure, 25_000e6);
    }

    function test_availableCapacity_oracleAdjusted() public {
        _stakeMaker(maker1, 50_000e6);

        // At $1.00, capacity = 50,000
        assertEq(staking.availableCapacity(maker1), 50_000e6);

        // USDC depegs to $0.80
        priceFeed.setPrice(0.8e8);
        assertEq(staking.availableCapacity(maker1), 40_000e6);

        // Add some exposure
        vm.prank(mockEscrow);
        staking.increaseExposure(maker1, 20_000e6);
        assertEq(staking.availableCapacity(maker1), 20_000e6);
    }

    function test_increaseExposure_staleOracle_reverts() public {
        _stakeMaker(maker1, 50_000e6);

        // Warp to a reasonable timestamp, then set oracle updatedAt to 2 hours ago
        vm.warp(10 hours);
        priceFeed.setUpdatedAt(block.timestamp - 2 hours);

        vm.prank(mockEscrow);
        vm.expectRevert("GauloiStaking: stale oracle price");
        staking.increaseExposure(maker1, 10_000e6);
    }

    function test_increaseExposure_noPriceFeed_fallsBackTo1to1() public {
        // Deploy fresh staking without oracle
        GauloiStaking noOracleStaking = new GauloiStaking(
            address(usdc), MIN_STAKE, COOLDOWN, 1 hours, owner
        );
        vm.startPrank(owner);
        noOracleStaking.setEscrow(mockEscrow);
        vm.stopPrank();

        vm.startPrank(maker1);
        usdc.approve(address(noOracleStaking), 50_000e6);
        noOracleStaking.stake(50_000e6);
        vm.stopPrank();

        // Without oracle, 50k stake = 50k capacity (raw 1:1)
        assertEq(noOracleStaking.availableCapacity(maker1), 50_000e6);

        vm.prank(mockEscrow);
        noOracleStaking.increaseExposure(maker1, 50_000e6);
        assertEq(noOracleStaking.availableCapacity(maker1), 0);
    }

    function test_increaseExposure_negativeOraclePrice_reverts() public {
        _stakeMaker(maker1, 50_000e6);

        priceFeed.setPrice(-1);

        vm.prank(mockEscrow);
        vm.expectRevert("GauloiStaking: invalid oracle price");
        staking.increaseExposure(maker1, 10_000e6);
    }

    function test_setPriceFeed_onlyOwner() public {
        vm.prank(maker1);
        vm.expectRevert();
        staking.setPriceFeed(makeAddr("feed"));
    }

    function test_setPriceFeed_zeroAddress_disablesOracle() public {
        _stakeMaker(maker1, 50_000e6);

        // Disable oracle
        vm.prank(owner);
        staking.setPriceFeed(address(0));

        // Should fall back to 1:1
        assertEq(staking.availableCapacity(maker1), 50_000e6);
    }

    function test_availableCapacity_cappedAbovePeg() public {
        _stakeMaker(maker1, 50_000e6);

        // USDC at $1.05 — capacity should still be 50,000 (capped at 1:1)
        priceFeed.setPrice(1.05e8);
        assertEq(staking.availableCapacity(maker1), 50_000e6);

        // USDC at $2.00 — still capped
        priceFeed.setPrice(2e8);
        assertEq(staking.availableCapacity(maker1), 50_000e6);
    }

    function testFuzz_oracleAdjustedCapacity(uint256 stakeAmt, uint256 priceCents) public {
        stakeAmt = bound(stakeAmt, MIN_STAKE, 1_000_000e6);
        priceCents = bound(priceCents, 1, 200); // $0.01 to $2.00

        _stakeMaker(maker1, stakeAmt);

        int256 oraclePrice = int256(priceCents * 1e6); // 8-decimal price from cents
        priceFeed.setPrice(oraclePrice);

        uint256 rawCapacity = (stakeAmt * priceCents * 1e6) / 1e8;
        // Capped at stakedAmount — oracle can only reduce, never inflate
        uint256 expectedCapacity = rawCapacity < stakeAmt ? rawCapacity : stakeAmt;
        assertEq(staking.availableCapacity(maker1), expectedCapacity);
    }
}
