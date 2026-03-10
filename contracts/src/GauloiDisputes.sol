// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IGauloiDisputes} from "./interfaces/IGauloiDisputes.sol";
import {IGauloiStaking} from "./interfaces/IGauloiStaking.sol";
import {GauloiEscrow} from "./GauloiEscrow.sol";
import {DataTypes} from "./types/DataTypes.sol";
import {SignatureLib} from "./libraries/SignatureLib.sol";
import {IntentLib} from "./libraries/IntentLib.sol";

contract GauloiDisputes is IGauloiDisputes, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IGauloiStaking public staking;
    GauloiEscrow public escrow;
    IERC20 public bondToken; // Same as stake token (USDC)

    uint256 public disputeResolutionDuration; // Time to resolve before default
    uint256 public disputeBondBps; // Bond as basis points of fill amount
    uint256 public minDisputeBond; // Minimum bond in absolute terms

    bytes32 public immutable domainSeparator;

    mapping(bytes32 => DataTypes.Dispute) internal _disputes;
    mapping(bytes32 => DataTypes.Order) internal _disputeOrders;

    // --- Phase A state (appended after slot 7 to preserve layout) ---

    // Slash curve params
    uint256 public slashBaseMultiplier; // 2
    uint256 public slashCurveK;         // 650e6
    uint256 public slashMaxMultiplier;  // 15

    // Quorum
    uint256 public quorumBps; // 3000 (30%)

    // Attestor recording — split by vote direction
    mapping(bytes32 => address[]) internal _validAttestors;
    mapping(bytes32 => address[]) internal _invalidAttestors;
    mapping(bytes32 => mapping(address => uint256)) internal _attestorStakeWeights;
    mapping(bytes32 => uint256) internal _totalValidWeight;
    mapping(bytes32 => uint256) internal _totalInvalidWeight;
    mapping(bytes32 => mapping(address => bool)) internal _hasAttested;

    // Quorum failure
    mapping(bytes32 => uint256) public quorumFailCount;

    constructor(
        address _staking,
        address _escrow,
        address _bondToken,
        uint256 _resolutionWindow,
        uint256 _bondBps,
        uint256 _minBond,
        address _owner
    ) Ownable(_owner) {
        require(_staking != address(0) && _escrow != address(0) && _bondToken != address(0),
            "GauloiDisputes: zero address");
        staking = IGauloiStaking(_staking);
        escrow = GauloiEscrow(_escrow);
        bondToken = IERC20(_bondToken);
        disputeResolutionDuration = _resolutionWindow;
        disputeBondBps = _bondBps;
        minDisputeBond = _minBond;
        domainSeparator = SignatureLib.buildDomainSeparator("GauloiDisputes", address(this));

        // Slash curve defaults
        slashBaseMultiplier = 2;
        slashCurveK = 650e6;
        slashMaxMultiplier = 15;

        // Quorum default: 30%
        quorumBps = 3000;
    }

    // --- Admin ---

    function setDisputeResolutionWindow(uint256 newWindow) external onlyOwner {
        require(newWindow > 0, "GauloiDisputes: zero window");
        disputeResolutionDuration = newWindow;
    }

    function setDisputeBondParams(uint256 newBps, uint256 newMinBond) external onlyOwner {
        disputeBondBps = newBps;
        minDisputeBond = newMinBond;
    }

    function setSlashCurveParams(uint256 _base, uint256 _k, uint256 _max) external onlyOwner {
        slashBaseMultiplier = _base;
        slashCurveK = _k;
        slashMaxMultiplier = _max;
    }

    function setQuorumParams(uint256 _quorumBps) external onlyOwner {
        require(_quorumBps <= 10_000, "GauloiDisputes: invalid quorum");
        quorumBps = _quorumBps;
    }

    function withdrawTreasury(address to, uint256 amount) external onlyOwner nonReentrant {
        require(to != address(0), "GauloiDisputes: zero address");
        bondToken.safeTransfer(to, amount);
    }

    // --- Dispute lifecycle ---

    function dispute(DataTypes.Order calldata order) external nonReentrant {
        require(staking.isActiveMaker(msg.sender), "GauloiDisputes: not active maker");

        bytes32 intentId = IntentLib.computeIntentId(order);
        require(_disputes[intentId].challenger == address(0), "GauloiDisputes: already disputed");

        DataTypes.Commitment memory commitment = escrow.getCommitment(intentId);
        require(commitment.state == DataTypes.IntentState.Filled, "GauloiDisputes: not filled");
        require(block.timestamp < commitment.disputeWindowEnd, "GauloiDisputes: window closed");
        require(msg.sender != commitment.maker, "GauloiDisputes: cannot dispute own fill");

        uint256 bondAmount = calculateDisputeBond(order.inputAmount);

        // Transfer bond from challenger
        bondToken.safeTransferFrom(msg.sender, address(this), bondAmount);

        _disputes[intentId] = DataTypes.Dispute({
            intentId: intentId,
            challenger: msg.sender,
            bondAmount: bondAmount,
            disputeDeadline: block.timestamp + disputeResolutionDuration,
            resolved: false,
            fillDeemedValid: false
        });

        // Store order for later resolution
        _disputeOrders[intentId] = order;

        // Transition intent to Disputed in escrow
        escrow.setDisputed(intentId);

        emit DisputeRaised(intentId, msg.sender, bondAmount);
    }

    function resolveDispute(
        bytes32 intentId,
        bool fillValid,
        bytes[] calldata signatures
    ) external nonReentrant {
        DataTypes.Dispute storage disp = _disputes[intentId];
        require(disp.challenger != address(0), "GauloiDisputes: no dispute");
        require(!disp.resolved, "GauloiDisputes: already resolved");
        require(block.timestamp <= disp.disputeDeadline, "GauloiDisputes: deadline passed");

        DataTypes.Commitment memory commitment = escrow.getCommitment(intentId);
        DataTypes.Order storage order = _disputeOrders[intentId];

        // Record each attestor's vote and stake weight
        for (uint256 i = 0; i < signatures.length; i++) {
            address signer = SignatureLib.recoverAttestor(
                domainSeparator,
                intentId,
                fillValid,
                commitment.fillTxHash,
                order.destinationChainId,
                signatures[i]
            );

            // Must be an active staked maker
            require(staking.isActiveMaker(signer), "GauloiDisputes: signer not active maker");
            // Must not be the disputed maker or the challenger (conflict of interest)
            require(signer != commitment.maker, "GauloiDisputes: maker cannot attest own fill");
            require(signer != disp.challenger, "GauloiDisputes: challenger cannot attest");
            // No duplicate attestations across calls
            require(!_hasAttested[intentId][signer], "GauloiDisputes: already attested");

            uint256 weight = staking.getStake(signer);
            _hasAttested[intentId][signer] = true;
            _attestorStakeWeights[intentId][signer] = weight;

            if (fillValid) {
                _validAttestors[intentId].push(signer);
                _totalValidWeight[intentId] += weight;
            } else {
                _invalidAttestors[intentId].push(signer);
                _totalInvalidWeight[intentId] += weight;
            }

            emit AttestorRecorded(intentId, signer, fillValid, weight);
        }

        // Check quorum + majority
        uint256 makerStake = staking.getStake(commitment.maker);
        uint256 challengerStake = staking.getStake(disp.challenger);
        uint256 eligible = staking.totalActiveStake() - makerStake - challengerStake;

        uint256 totalParticipating = _totalValidWeight[intentId] + _totalInvalidWeight[intentId];

        // Quorum: participating >= quorumBps% of eligible
        if (eligible == 0 || totalParticipating * 10_000 < eligible * quorumBps) {
            return; // Not enough participation yet, votes recorded for future calls
        }

        // Strict majority: winningStake * 2 > totalParticipating
        uint256 validWeight = _totalValidWeight[intentId];
        uint256 invalidWeight = _totalInvalidWeight[intentId];

        bool validWins = validWeight * 2 > totalParticipating;
        bool invalidWins = invalidWeight * 2 > totalParticipating;

        if (!validWins && !invalidWins) {
            return; // No majority yet, votes recorded for future calls
        }

        disp.resolved = true;
        disp.fillDeemedValid = validWins;

        if (validWins) {
            _resolveAsValid(intentId, commitment, disp);
        } else {
            _resolveAsInvalid(intentId, commitment, disp);
        }

        emit DisputeResolved(intentId, validWins);
    }

    function finalizeExpiredDispute(bytes32 intentId) external nonReentrant {
        DataTypes.Dispute storage disp = _disputes[intentId];
        require(disp.challenger != address(0), "GauloiDisputes: no dispute");
        require(!disp.resolved, "GauloiDisputes: already resolved");
        require(block.timestamp > disp.disputeDeadline, "GauloiDisputes: deadline not passed");

        DataTypes.Commitment memory commitment = escrow.getCommitment(intentId);

        uint256 totalParticipating = _totalValidWeight[intentId] + _totalInvalidWeight[intentId];

        if (totalParticipating == 0) {
            // Case 1: Zero attestations — default fill-valid (griefing backstop)
            disp.resolved = true;
            disp.fillDeemedValid = true;
            _resolveAsValid(intentId, commitment, disp);
            emit DisputeResolved(intentId, true);
            return;
        }

        // Check if quorum was met
        uint256 makerStake = staking.getStake(commitment.maker);
        uint256 challengerStake = staking.getStake(disp.challenger);
        uint256 eligible = staking.totalActiveStake() - makerStake - challengerStake;

        bool quorumMet = eligible > 0 && totalParticipating * 10_000 >= eligible * quorumBps;

        if (quorumMet) {
            // Case 2: Quorum met — resolve by plurality (more weight wins)
            bool validWins = _totalValidWeight[intentId] >= _totalInvalidWeight[intentId];

            disp.resolved = true;
            disp.fillDeemedValid = validWins;

            if (validWins) {
                _resolveAsValid(intentId, commitment, disp);
            } else {
                _resolveAsInvalid(intentId, commitment, disp);
            }

            emit DisputeResolved(intentId, validWins);
        } else {
            // Case 3: Quorum NOT met
            quorumFailCount[intentId]++;

            if (quorumFailCount[intentId] >= 2) {
                // Second failure — pause escrow
                escrow.pause();

                // Default to fill-valid to resolve the dispute
                disp.resolved = true;
                disp.fillDeemedValid = true;
                _resolveAsValid(intentId, commitment, disp);
                emit DisputeResolved(intentId, true);
            } else {
                // First failure — extend deadline
                disp.disputeDeadline = block.timestamp + disputeResolutionDuration;
                emit QuorumExtended(intentId, disp.disputeDeadline, quorumFailCount[intentId]);
            }
        }
    }

    // --- Internal resolution ---

    function _resolveAsValid(
        bytes32 intentId,
        DataTypes.Commitment memory commitment,
        DataTypes.Dispute storage disp
    ) internal {
        DataTypes.Order storage order = _disputeOrders[intentId];

        // Fill was valid — disputer was wrong
        // Bond pool: 50% to maker, 25% to correct attestors, 25% + dust to treasury
        uint256 makerReward = disp.bondAmount / 2;
        uint256 attestorPool = disp.bondAmount / 4;

        bondToken.safeTransfer(commitment.maker, makerReward);

        // Distribute attestor rewards (valid-side attestors)
        _distributeAttestorRewards(intentId, true, attestorPool);

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

        // Fill was invalid — maker committed fraud
        // Calculate slash amount via curve
        uint256 makerStake = staking.getStake(commitment.maker);
        uint256 slashAmt = calculateSlashAmount(order.inputAmount, makerStake);

        // Snapshot exposure before slash — slashPartial may cap exposure at remaining stake
        uint256 exposureBefore = staking.getExposure(commitment.maker);

        // Partial slash — returns actual slashed amount
        uint256 actualSlashed = staking.slashPartial(commitment.maker, intentId, slashAmt);

        // Bond: returned to challenger in full
        // Slashed amount pool: 25% to challenger, 25% to correct attestors, 50% + dust to treasury
        uint256 challengerSlashReward = actualSlashed / 4;
        uint256 attestorPool = actualSlashed / 4;

        bondToken.safeTransfer(disp.challenger, disp.bondAmount + challengerSlashReward);

        // Distribute attestor rewards (invalid-side attestors)
        _distributeAttestorRewards(intentId, false, attestorPool);

        // Refund taker's escrowed funds
        // Only decrease exposure by what slashPartial's cap didn't already absorb
        uint256 exposureAfter = staking.getExposure(commitment.maker);
        uint256 alreadyReduced = exposureBefore - exposureAfter;
        if (order.inputAmount > alreadyReduced) {
            staking.decreaseExposure(commitment.maker, order.inputAmount - alreadyReduced);
        }
        escrow.resolveInvalid(intentId, order);

        // Reclaim storage
        delete _disputeOrders[intentId];

        emit ChallengerRewarded(disp.challenger, disp.bondAmount + challengerSlashReward);
    }

    function _distributeAttestorRewards(
        bytes32 intentId,
        bool validSide,
        uint256 pool
    ) internal {
        address[] storage attestors = validSide ? _validAttestors[intentId] : _invalidAttestors[intentId];
        uint256 totalWeight = validSide ? _totalValidWeight[intentId] : _totalInvalidWeight[intentId];

        if (totalWeight == 0 || attestors.length == 0) return;

        for (uint256 i = 0; i < attestors.length; i++) {
            uint256 weight = _attestorStakeWeights[intentId][attestors[i]];
            uint256 share = (pool * weight) / totalWeight;
            if (share > 0) {
                bondToken.safeTransfer(attestors[i], share);
                emit AttestorRewarded(intentId, attestors[i], share);
            }
        }
        // Dust stays in contract as treasury
    }

    // --- View functions ---

    function getDispute(bytes32 intentId) external view returns (DataTypes.Dispute memory) {
        return _disputes[intentId];
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

    function getDisputeAttestors(bytes32 intentId, bool validSide) external view returns (address[] memory) {
        return validSide ? _validAttestors[intentId] : _invalidAttestors[intentId];
    }

    function getAttestorStakeWeight(bytes32 intentId, address attestor) external view returns (uint256) {
        return _attestorStakeWeights[intentId][attestor];
    }

    function getQuorumFailCount(bytes32 intentId) external view returns (uint256) {
        return quorumFailCount[intentId];
    }
}
