// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title DisputeBondEconomics
 * @notice Encodes and enforces the invariants that keep dispute bond economics sound.
 *
 * KEY INVARIANT (load-bearing for fraud-prevention):
 *   maker_stake >= max_fill_size
 *
 * This must hold at all times because the challenger reward formula is:
 *   challenger_reward = bond + 25% * slashed_stake
 *
 * If fill_size > maker_stake, a fraudulent maker profits:
 *   fraud_profit = fill_size - maker_stake > 0
 *
 * The 1x exposure multiplier enforces this by design. Any governance action
 * that raises the exposure multiplier MUST be reviewed against this invariant.
 *
 * GRIEFING MITIGATION:
 *   Repeated disputes cost the attacker 0.5% of fill per dispute.
 *   The maker receives 50% of each forfeited bond as compensation.
 *   A cooldown period between disputes per (attacker, maker) pair raises
 *   the cost of sustained griefing from O(n) to O(n * cooldown_hours).
 */
contract DisputeBondEconomics {
    // -------------------------------------------------------------------------
    // Constants — changing these requires a full re-analysis of the tables in
    // Issue #25 before any governance proposal is submitted.
    // -------------------------------------------------------------------------

    /// @notice Bond rate as a fraction of fill size (0.5% = 50 bps).
    /// WHY 50 bps: Calibrated so bond >> gas cost yet << fill, keeping disputes
    /// net-positive for honest challengers while remaining affordable for makers.
    uint256 public constant BOND_RATE_BPS = 50;

    /// @notice Minimum bond in base units (e.g. USDC with 6 decimals → 25e6).
    /// WHY minimum: Prevents dust fills from producing zero-bond disputes.
    uint256 public constant MIN_BOND = 25e6;

    /// @notice Percentage of slashed stake awarded to the challenger (25%).
    /// WHY 25%: Provides strong challenger incentive while leaving 75% as
    /// protocol revenue / treasury to fund future security work.
    uint256 public constant CHALLENGER_REWARD_RATE_BPS = 2500;

    /// @notice Fraction of forfeited bond returned to the maker (50%).
    /// WHY 50%: Partially compensates makers for griefing-locked capital.
    uint256 public constant MAKER_BOND_REFUND_RATE_BPS = 5000;

    /// @notice Exposure multiplier (fill / stake). MUST remain 1x unless
    /// the invariant below is re-verified with the new value.
    /// @dev THIS IS THE LOAD-BEARING CONSTANT. See module-level natspec.
    uint256 public constant EXPOSURE_MULTIPLIER = 1;

    /// @notice Minimum seconds between two disputes filed by the same address
    /// against the same maker. Raises griefing cost from cheap O(n) to O(n).
    /// WHY 1 hour: Attacker must lock 0.5% * fill every hour per target maker,
    /// making sustained DoS prohibitively expensive for large fills.
    uint256 public constant DISPUTE_COOLDOWN = 1 hours;

    // -------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------

    struct MakerState {
        uint256 stake;       // Current staked collateral
        uint256 maxFill;     // Cached: stake * EXPOSURE_MULTIPLIER
    }

    /// @dev challenger => maker => timestamp of last dispute filed
    mapping(address => mapping(address => uint256)) public lastDisputeTimestamp;

    mapping(address => MakerState) public makers;

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    /// @notice Thrown when a fill would exceed the maker's stake-backed exposure.
    /// @dev This is the primary guard for the load-bearing invariant.
    error ExposureExceedsStake(uint256 fillSize, uint256 maxFill);

    /// @notice Thrown when a challenger attempts a dispute too soon after the last one.
    error DisputeCooldownActive(uint256 retryAfter);

    /// @notice Thrown when governance would set an exposure multiplier that breaks
    /// the fraud-disincentive invariant without an explicit override.
    error MultiplierBreaksDisputeEconomics(uint256 proposedMultiplier);

    // -------------------------------------------------------------------------
    // Core logic
    // -------------------------------------------------------------------------

    /**
     * @notice Validate that a proposed fill is within the maker's staked exposure.
     * @dev Called before any fill is accepted. Reverts if fill > stake * multiplier.
     *      This is the enforcement point for the load-bearing invariant:
     *        maker_stake >= fill_size  (given EXPOSURE_MULTIPLIER == 1)
     * @param maker  Address of the maker accepting the fill.
     * @param fillSize  Amount being filled (in base units).
     */
    function validateFillExposure(address maker, uint256 fillSize) public view {
        MakerState storage ms = makers[maker];
        // maxFill is stake * EXPOSURE_MULTIPLIER; with multiplier=1 this is just stake.
        // WHY cache maxFill: avoids re-multiplying on every fill check and makes the
        // invariant explicit in storage rather than implicit in call-site arithmetic.
        if (fillSize > ms.maxFill) {
            revert ExposureExceedsStake(fillSize, ms.maxFill);
        }
    }

    /**
     * @notice Compute the bond required for a given fill size.
     * @param fillSize  Fill amount in base units.
     * @return bond  The larger of (fillSize * BOND_RATE_BPS / 10000) and MIN_BOND.
     */
    function computeBond(uint256 fillSize) public pure returns (uint256 bond) {
        uint256 rateBond = (fillSize * BOND_RATE_BPS) / 10_000;
        bond = rateBond > MIN_BOND ? rateBond : MIN_BOND;
    }

    /**
     * @notice Compute the challenger reward for a successful dispute.
     * @dev challenger_reward = bond + 25% * slashed_stake
     *      With EXPOSURE_MULTIPLIER=1, slashed_stake <= fill_size <= maker_stake,
     *      so the reward is always funded by the maker's stake. If the multiplier
     *      were raised this guarantee breaks — see validateExposureMultiplier.
     * @param bond        The bond posted by the challenger.
     * @param slashedStake  The maker stake amount being slashed.
     * @return reward  Total tokens awarded to the challenger.
     */
    function computeChallengerReward(
        uint256 bond,
        uint256 slashedStake
    ) public pure returns (uint256 reward) {
        uint256 stakeShare = (slashedStake * CHALLENGER_REWARD_RATE_BPS) / 10_000;
        reward = bond + stakeShare;
    }

    /**
     * @notice Enforce the dispute cooldown to mitigate griefing.
     * @dev Records the timestamp of the dispute. Reverts if called again before
     *      DISPUTE_COOLDOWN seconds have elapsed for the same (challenger, maker).
     * @param challenger  Address filing the dispute.
     * @param maker       Address of the maker being disputed.
     */
    function enforceDisputeCooldown(address challenger, address maker) public {
        uint256 last = lastDisputeTimestamp[challenger][maker];
        // WHY block.timestamp: cooldown is approximate; a 1-block manipulation
        // (≈12 s) cannot meaningfully compress a 1-hour window.
        if (block.timestamp < last + DISPUTE_COOLDOWN) {
            revert DisputeCooldownActive(last + DISPUTE_COOLDOWN);
        }
        lastDisputeTimestamp[challenger][maker] = block.timestamp;
    }

    /**
     * @notice Governance guard: revert if a new exposure multiplier would break
     *         fraud-disincentive economics without explicit acknowledgement.
     * @dev Any multiplier > 1 allows fill_size > maker_stake, meaning a fraudulent
     *      maker can profit by the difference. This function documents the coupling
     *      and forces governance to handle it explicitly.
     * @param proposedMultiplier  The new exposure multiplier being proposed.
     */
    function validateExposureMultiplier(uint256 proposedMultiplier) public pure {
        // WHY only allow 1: The challenger reward formula assumes slashed_stake
        // fully covers fill_size. Any value > 1 creates a profitable fraud window
        // as shown in the Issue #25 table. Raise this limit only after:
        //   1. Redesigning the reward formula to account for under-collateralisation.
        //   2. Adding insurance / protocol backstop funds.
        //   3. A full economic audit.
        if (proposedMultiplier > 1) {
            revert MultiplierBreaksDisputeEconomics(proposedMultiplier);
        }
    }

    /**
     * @notice Register or update a maker's stake, recalculating maxFill.
     * @param maker  Maker address.
     * @param stake  New stake amount in base units.
     */
    function _setMakerStake(address maker, uint256 stake) internal {
        makers[maker] = MakerState({
            stake: stake,
            // WHY store maxFill explicitly: makes the invariant auditable on-chain
            // and prevents accidental inconsistency if EXPOSURE_MULTIPLIER changes.
            maxFill: stake * EXPOSURE_MULTIPLIER
        });
    }
}
