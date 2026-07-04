// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IGauloiDisputes} from "./interfaces/IGauloiDisputes.sol";
import {IGauloiStaking} from "./interfaces/IGauloiStaking.sol";
import {IResolver} from "./interfaces/IResolver.sol";
import {GauloiEscrow} from "./GauloiEscrow.sol";
import {DataTypes} from "./types/DataTypes.sol";
import {IntentLib} from "./libraries/IntentLib.sol";
import {TransferLib} from "./libraries/TransferLib.sol";

/// @notice Dispute layer, v2. Detection and judgment are separated:
///
///         - Detection is permissionless. Anyone — the taker, a rival maker, a
///           third-party watcher — challenges a fill claim by posting a bond.
///         - Judgment terminates in the corridor's resolver (IResolver): a storage
///           proof where the destination chain is provable, a named council where
///           it is not. There is no attestor vote.
///         - A challenged fill with no verdict by the deadline resolves INVALID:
///           the maker must defend, silence convicts. This is safe because fills
///           are registry-recorded on the destination chain, so an honest maker
///           always has an unambiguous defense.
contract GauloiDisputes is IGauloiDisputes, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using TransferLib for IERC20;

    IGauloiStaking public staking;
    GauloiEscrow public escrow;
    IERC20 public bondToken; // Same as stake token (USDC)
    address public treasury;

    uint256 public disputeResolutionDuration; // Time for the maker to defend before default-invalid
    uint256 public disputeBondBps; // Bond as basis points of fill amount
    uint256 public minDisputeBond; // Minimum bond in absolute terms

    // Slash curve params
    uint256 public slashBaseMultiplier; // 2
    uint256 public slashCurveK;         // 650e6
    uint256 public slashMaxMultiplier;  // 15

    // Corridor resolvers: destination chain id => terminal arbiter
    mapping(uint256 => IResolver) public resolvers;

    // Per-corridor resolution window overrides (0 = use default) — proof corridors
    // can afford tighter defense deadlines than council corridors
    mapping(uint256 => uint256) public corridorResolutionWindow;

    mapping(bytes32 => DataTypes.Dispute) internal _disputes;
    mapping(bytes32 => DataTypes.Order) internal _disputeOrders;

    constructor(
        address _staking,
        address _escrow,
        address _bondToken,
        uint256 _resolutionWindow,
        uint256 _bondBps,
        uint256 _minBond,
        address _treasury,
        address _owner
    ) Ownable(_owner) {
        require(
            _staking != address(0) && _escrow != address(0) && _bondToken != address(0)
                && _treasury != address(0),
            "GauloiDisputes: zero address"
        );
        staking = IGauloiStaking(_staking);
        escrow = GauloiEscrow(_escrow);
        bondToken = IERC20(_bondToken);
        treasury = _treasury;
        disputeResolutionDuration = _resolutionWindow;
        disputeBondBps = _bondBps;
        minDisputeBond = _minBond;

        // Slash curve defaults
        slashBaseMultiplier = 2;
        slashCurveK = 650e6;
        slashMaxMultiplier = 15;
    }

    // --- Admin ---

    function setResolver(uint256 destinationChainId, address resolver) external onlyOwner {
        address oldResolver = address(resolvers[destinationChainId]);
        resolvers[destinationChainId] = IResolver(resolver);
        emit ResolverUpdated(destinationChainId, oldResolver, resolver);
    }

    function setTreasury(address _treasury) external onlyOwner {
        require(_treasury != address(0), "GauloiDisputes: zero address");
        address oldTreasury = treasury;
        treasury = _treasury;
        emit TreasuryUpdated(oldTreasury, _treasury);
    }

    function setDisputeResolutionWindow(uint256 newWindow) external onlyOwner {
        require(newWindow >= 1 hours && newWindow <= 30 days, "GauloiDisputes: window out of range");
        uint256 oldValue = disputeResolutionDuration;
        disputeResolutionDuration = newWindow;
        emit ResolutionWindowUpdated(oldValue, newWindow);
    }

    function setCorridorResolutionWindow(uint256 destinationChainId, uint256 newWindow) external onlyOwner {
        require(
            newWindow == 0 || (newWindow >= 1 hours && newWindow <= 30 days),
            "GauloiDisputes: window out of range"
        );
        uint256 oldValue = corridorResolutionWindow[destinationChainId];
        corridorResolutionWindow[destinationChainId] = newWindow;
        emit CorridorResolutionWindowUpdated(destinationChainId, oldValue, newWindow);
    }

    function setDisputeBondParams(uint256 newBps, uint256 newMinBond) external onlyOwner {
        require(newBps <= 10_000, "GauloiDisputes: bps exceeds 100%");
        disputeBondBps = newBps;
        minDisputeBond = newMinBond;
        emit BondParamsUpdated(newBps, newMinBond);
    }

    function setSlashCurveParams(uint256 _base, uint256 _k, uint256 _max) external onlyOwner {
        require(_base >= 1 && _max >= _base && _max <= 100, "GauloiDisputes: invalid slash curve");
        slashBaseMultiplier = _base;
        slashCurveK = _k;
        slashMaxMultiplier = _max;
        emit SlashCurveUpdated(_base, _k, _max);
    }

    /// @dev Sweep funds held by this contract (failed reward transfers, dust)
    function withdrawTreasury(address to, uint256 amount) external onlyOwner nonReentrant {
        require(to != address(0), "GauloiDisputes: zero address");
        bondToken.safeTransfer(to, amount);
    }

    // --- Dispute lifecycle ---

    function challenge(DataTypes.Order calldata order) external nonReentrant {
        bytes32 intentId = IntentLib.computeIntentId(order);
        require(_disputes[intentId].challenger == address(0), "GauloiDisputes: already challenged");

        DataTypes.Commitment memory commitment = escrow.getCommitment(intentId);
        require(commitment.state == DataTypes.IntentState.Filled, "GauloiDisputes: not filled");
        require(block.timestamp < commitment.disputeWindowEnd, "GauloiDisputes: window closed");
        require(msg.sender != commitment.maker, "GauloiDisputes: cannot challenge own fill");

        // A dispute must be adjudicable. Without a resolver the only exit is the
        // deadline default, which would let a griefer force-slash an honest,
        // registry-recorded fill on an unconfigured corridor. Require the
        // corridor's arbiter to exist before the challenge can open.
        require(
            address(resolvers[order.destinationChainId]) != address(0),
            "GauloiDisputes: no resolver for corridor"
        );

        uint256 bondAmount = calculateDisputeBond(order.inputAmount);

        // Transfer bond from challenger
        bondToken.safeTransferFrom(msg.sender, address(this), bondAmount);

        _disputes[intentId] = DataTypes.Dispute({
            intentId: intentId,
            challenger: msg.sender,
            bondAmount: bondAmount,
            disputeDeadline: block.timestamp + resolutionWindowFor(order.destinationChainId),
            resolved: false,
            fillDeemedValid: false
        });

        // Store order for later resolution
        _disputeOrders[intentId] = order;

        // Transition intent to Disputed in escrow
        escrow.setDisputed(intentId);

        emit DisputeRaised(intentId, msg.sender, bondAmount);
    }

    function resolve(bytes32 intentId, bytes calldata evidence) external nonReentrant {
        DataTypes.Dispute storage disp = _disputes[intentId];
        require(disp.challenger != address(0), "GauloiDisputes: no dispute");
        require(!disp.resolved, "GauloiDisputes: already resolved");
        require(block.timestamp <= disp.disputeDeadline, "GauloiDisputes: deadline passed");

        DataTypes.Order storage order = _disputeOrders[intentId];
        IResolver resolver = resolvers[order.destinationChainId];
        require(address(resolver) != address(0), "GauloiDisputes: no resolver for corridor");

        IResolver.Verdict verdict = resolver.resolve(intentId, order, evidence);
        require(verdict != IResolver.Verdict.Pending, "GauloiDisputes: no verdict");

        DataTypes.Commitment memory commitment = escrow.getCommitment(intentId);

        bool valid = verdict == IResolver.Verdict.Valid;
        disp.resolved = true;
        disp.fillDeemedValid = valid;

        if (valid) {
            _resolveAsValid(intentId, commitment, disp);
        } else {
            _resolveAsInvalid(intentId, commitment, disp);
        }

        emit DisputeResolved(intentId, valid);
    }

    function finalizeExpiredDispute(bytes32 intentId) external nonReentrant {
        DataTypes.Dispute storage disp = _disputes[intentId];
        require(disp.challenger != address(0), "GauloiDisputes: no dispute");
        require(!disp.resolved, "GauloiDisputes: already resolved");
        require(block.timestamp > disp.disputeDeadline, "GauloiDisputes: deadline not passed");

        DataTypes.Commitment memory commitment = escrow.getCommitment(intentId);
        DataTypes.Order storage order = _disputeOrders[intentId];

        // If the corridor lost its resolver after the challenge opened, the maker
        // can no longer defend — voiding in the maker's favor is the griefing-safe
        // direction (owner removing an arbiter must not auto-convict). Otherwise
        // the maker failed to defend a defendable fill: silence convicts.
        bool defendable = address(resolvers[order.destinationChainId]) != address(0);

        disp.resolved = true;
        disp.fillDeemedValid = defendable ? false : true;

        if (defendable) {
            _resolveAsInvalid(intentId, commitment, disp);
        } else {
            _resolveAsValid(intentId, commitment, disp);
        }

        emit DisputeResolved(intentId, !defendable);
    }

    // --- Internal resolution ---

    function _resolveAsValid(
        bytes32 intentId,
        DataTypes.Commitment memory commitment,
        DataTypes.Dispute storage disp
    ) internal {
        DataTypes.Order storage order = _disputeOrders[intentId];

        // Fill was valid — challenger was wrong.
        // Bond: 50% to the wrongly-accused maker, 50% (+ dust) to treasury.
        uint256 makerReward = disp.bondAmount / 2;
        uint256 treasuryShare = disp.bondAmount - makerReward;

        if (!bondToken.tryTransfer(commitment.maker, makerReward)) {
            emit MakerRewardFailed(intentId, commitment.maker, makerReward);
        }
        if (!bondToken.tryTransfer(treasury, treasuryShare)) {
            emit TreasuryTransferFailed(intentId, treasuryShare);
        }

        // Release escrow to maker
        escrow.resolveValid(intentId, order);

        // Reclaim storage
        delete _disputeOrders[intentId];

        emit ChallengerBondSlashed(disp.challenger, disp.bondAmount);
    }

    function _resolveAsInvalid(
        bytes32 intentId,
        DataTypes.Commitment memory commitment,
        DataTypes.Dispute storage disp
    ) internal {
        DataTypes.Order storage order = _disputeOrders[intentId];

        // Fill was invalid — maker committed fraud (or failed to defend).
        // Calculate slash amount via curve
        uint256 makerStake = staking.getStake(commitment.maker);
        uint256 slashAmt = calculateSlashAmount(order.inputAmount, makerStake);

        // Snapshot exposure before slash — slashPartial may cap exposure at remaining stake
        uint256 exposureBefore = staking.getExposure(commitment.maker);

        // Partial slash — returns actual slashed amount (transferred to this contract)
        uint256 actualSlashed = staking.slashPartial(commitment.maker, intentId, slashAmt);

        // Bond returned to challenger in full, plus 25% of the slash.
        // Remaining 75% (+ dust) to treasury.
        uint256 challengerSlashReward = actualSlashed / 4;
        uint256 treasuryShare = actualSlashed - challengerSlashReward;

        uint256 challengerTotal = disp.bondAmount + challengerSlashReward;
        if (bondToken.tryTransfer(disp.challenger, challengerTotal)) {
            emit ChallengerRewarded(disp.challenger, challengerTotal);
        } else {
            emit ChallengerRewardFailed(intentId, disp.challenger, challengerTotal);
        }
        if (!bondToken.tryTransfer(treasury, treasuryShare)) {
            emit TreasuryTransferFailed(intentId, treasuryShare);
        }

        // Refund taker's escrowed funds.
        // Only decrease exposure by what slashPartial's cap didn't already absorb
        uint256 exposureAfter = staking.getExposure(commitment.maker);
        uint256 alreadyReduced = exposureBefore - exposureAfter;
        if (order.inputAmount > alreadyReduced) {
            staking.decreaseExposure(commitment.maker, order.inputAmount - alreadyReduced);
        }
        escrow.resolveInvalid(intentId, order);

        // Reclaim storage
        delete _disputeOrders[intentId];
    }

    // --- View functions ---

    function getDispute(bytes32 intentId) external view returns (DataTypes.Dispute memory) {
        return _disputes[intentId];
    }

    function getDisputeOrder(bytes32 intentId) external view returns (DataTypes.Order memory) {
        return _disputeOrders[intentId];
    }

    function calculateDisputeBond(uint256 fillAmount) public view returns (uint256) {
        uint256 bpsBond = (fillAmount * disputeBondBps) / 10_000;
        return bpsBond > minDisputeBond ? bpsBond : minDisputeBond;
    }

    function calculateSlashAmount(uint256 fillAmount, uint256 makerTotalStake) public view returns (uint256) {
        if (fillAmount == 0) return 0;
        uint256 multiplier_e18 = slashBaseMultiplier * 1e18 + (slashCurveK * 1e18) / fillAmount;
        uint256 maxMul_e18 = slashMaxMultiplier * 1e18;
        if (multiplier_e18 > maxMul_e18) multiplier_e18 = maxMul_e18;
        uint256 slashAmt = (fillAmount * multiplier_e18) / 1e18;
        return slashAmt > makerTotalStake ? makerTotalStake : slashAmt;
    }

    function disputeResolutionWindow() external view returns (uint256) {
        return disputeResolutionDuration;
    }

    function resolutionWindowFor(uint256 destinationChainId) public view returns (uint256) {
        uint256 corridorWindow = corridorResolutionWindow[destinationChainId];
        return corridorWindow == 0 ? disputeResolutionDuration : corridorWindow;
    }
}
