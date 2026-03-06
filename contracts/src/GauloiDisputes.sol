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

        // Verify threshold of unique staked maker signatures
        uint256 required = requiredSignatures();
        require(signatures.length >= required, "GauloiDisputes: insufficient signatures");

        // Track unique signers to prevent duplicate attestations
        address[] memory signers = new address[](signatures.length);
        uint256 validCount = 0;

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

            // Check uniqueness
            for (uint256 j = 0; j < validCount; j++) {
                require(signers[j] != signer, "GauloiDisputes: duplicate signer");
            }

            signers[validCount] = signer;
            validCount++;
        }

        require(validCount >= required, "GauloiDisputes: insufficient valid signatures");

        disp.resolved = true;
        disp.fillDeemedValid = fillValid;

        if (fillValid) {
            _resolveAsValid(intentId, commitment, disp);
        } else {
            _resolveAsInvalid(intentId, commitment, disp);
        }

        emit DisputeResolved(intentId, fillValid);
    }

    function finalizeExpiredDispute(bytes32 intentId) external nonReentrant {
        DataTypes.Dispute storage disp = _disputes[intentId];
        require(disp.challenger != address(0), "GauloiDisputes: no dispute");
        require(!disp.resolved, "GauloiDisputes: already resolved");
        require(block.timestamp > disp.disputeDeadline, "GauloiDisputes: deadline not passed");

        DataTypes.Commitment memory commitment = escrow.getCommitment(intentId);

        // Default to fill-valid (prevents griefing by raising dispute and never resolving)
        disp.resolved = true;
        disp.fillDeemedValid = true;

        _resolveAsValid(intentId, commitment, disp);

        emit DisputeResolved(intentId, true);
    }

    // --- Internal resolution ---

    function _resolveAsValid(
        bytes32 intentId,
        DataTypes.Commitment memory commitment,
        DataTypes.Dispute storage disp
    ) internal {
        DataTypes.Order storage order = _disputeOrders[intentId];

        // Fill was valid — disputer was wrong
        // Slash disputer's bond: portion to maker as compensation, rest to protocol
        uint256 makerReward = disp.bondAmount / 2;

        bondToken.safeTransfer(commitment.maker, makerReward);
        // Remaining bond stays in this contract as protocol treasury

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
        // Slash maker's entire stake
        uint256 slashedAmount = staking.slash(commitment.maker, intentId);

        // Reward challenger: return bond + portion of slashed stake
        uint256 challengerReward = disp.bondAmount + (slashedAmount / 4);

        // Slashed funds were sent to this contract by staking.slash()
        bondToken.safeTransfer(disp.challenger, challengerReward);
        // Remaining slashed stake stays in this contract as protocol treasury

        // Refund taker's escrowed funds
        // Exposure is already zeroed by staking.slash()
        escrow.resolveInvalid(intentId, order);

        // Reclaim storage
        delete _disputeOrders[intentId];

        emit ChallengerRewarded(disp.challenger, challengerReward);
    }

    // --- View functions ---

    function getDispute(bytes32 intentId) external view returns (DataTypes.Dispute memory) {
        return _disputes[intentId];
    }

    function calculateDisputeBond(uint256 fillAmount) public view returns (uint256) {
        uint256 bpsBond = (fillAmount * disputeBondBps) / 10_000;
        return bpsBond > minDisputeBond ? bpsBond : minDisputeBond;
    }

    function requiredSignatures() public pure returns (uint256) {
        // For v0.1: at least 1 signature required (will scale with maker set)
        return 1;
    }

    function disputeResolutionWindow() external view returns (uint256) {
        return disputeResolutionDuration;
    }
}
