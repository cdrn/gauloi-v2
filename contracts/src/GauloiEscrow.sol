// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IGauloiEscrow} from "./interfaces/IGauloiEscrow.sol";
import {IGauloiStaking} from "./interfaces/IGauloiStaking.sol";
import {DataTypes} from "./types/DataTypes.sol";
import {IntentLib} from "./libraries/IntentLib.sol";
import {SignatureLib} from "./libraries/SignatureLib.sol";

contract GauloiEscrow is IGauloiEscrow, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IGauloiStaking public staking;
    address public disputes;

    uint256 public settlementWindowDuration;
    uint256 public commitmentTimeoutDuration;

    bytes32 public immutable domainSeparator;

    // Token whitelist
    mapping(address => bool) public supportedTokens;

    // Commitment storage (intentId → Commitment)
    mapping(bytes32 => DataTypes.Commitment) internal _commitments;

    bool public paused;

    modifier whenNotPaused() {
        require(!paused, "GauloiEscrow: paused");
        _;
    }

    modifier onlyDisputes() {
        require(msg.sender == disputes, "GauloiEscrow: caller is not disputes");
        _;
    }

    constructor(
        address _staking,
        uint256 _settlementWindow,
        uint256 _commitmentTimeout,
        address _owner
    ) Ownable(_owner) {
        require(_staking != address(0), "GauloiEscrow: zero address");
        staking = IGauloiStaking(_staking);
        settlementWindowDuration = _settlementWindow;
        commitmentTimeoutDuration = _commitmentTimeout;
        domainSeparator = SignatureLib.buildDomainSeparator("GauloiEscrow", address(this));
    }

    // --- Admin ---

    function setDisputes(address _disputes) external onlyOwner {
        require(_disputes != address(0), "GauloiEscrow: zero address");
        disputes = _disputes;
    }

    function setSettlementWindow(uint256 newWindow) external onlyOwner {
        require(newWindow > 0, "GauloiEscrow: zero window");
        settlementWindowDuration = newWindow;
    }

    function setCommitmentTimeout(uint256 newTimeout) external onlyOwner {
        require(newTimeout > 0, "GauloiEscrow: zero timeout");
        commitmentTimeoutDuration = newTimeout;
    }

    function addSupportedToken(address token) external onlyOwner {
        require(token != address(0), "GauloiEscrow: zero address");
        supportedTokens[token] = true;
    }

    function removeSupportedToken(address token) external onlyOwner {
        supportedTokens[token] = false;
    }

    /// @dev Recover tokens stuck from failed dispute-resolution transfers
    function rescueTokens(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        require(to != address(0), "GauloiEscrow: zero address");
        IERC20(token).safeTransfer(to, amount);
    }

    // --- Pause ---

    function pause() external onlyDisputes {
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    // --- Order execution ---

    function executeOrder(
        DataTypes.Order calldata order,
        bytes calldata takerSignature
    ) external nonReentrant whenNotPaused returns (bytes32 intentId) {
        require(supportedTokens[order.inputToken], "GauloiEscrow: unsupported input token");
        require(order.inputAmount > 0, "GauloiEscrow: zero amount");
        require(order.destinationAddress != address(0), "GauloiEscrow: zero destination");
        require(order.expiry > block.timestamp, "GauloiEscrow: order expired");
        require(order.minOutputAmount > 0, "GauloiEscrow: zero min output");
        require(staking.isActiveMaker(msg.sender), "GauloiEscrow: not active maker");

        // Verify taker signature
        address signer = SignatureLib.recoverOrderSigner(domainSeparator, order, takerSignature);
        require(signer == order.taker, "GauloiEscrow: invalid signature");

        intentId = IntentLib.computeIntentId(order);

        // Replay protection: ensure this order hasn't been executed
        require(_commitments[intentId].taker == address(0), "GauloiEscrow: already executed");

        // Reserve exposure in staking
        staking.increaseExposure(msg.sender, order.inputAmount);

        // Write commitment (3 storage slots)
        _commitments[intentId] = DataTypes.Commitment({
            taker: order.taker,
            state: DataTypes.IntentState.Committed,
            maker: msg.sender,
            commitmentDeadline: uint40(block.timestamp + commitmentTimeoutDuration),
            disputeWindowEnd: 0,
            fillTxHash: bytes32(0)
        });

        emit OrderExecuted(
            intentId,
            order.taker,
            msg.sender,
            order.inputToken,
            order.inputAmount,
            order.destinationChainId,
            order.outputToken,
            order.minOutputAmount
        );

        // Pull tokens from taker
        IERC20(order.inputToken).safeTransferFrom(order.taker, address(this), order.inputAmount);
    }

    function submitFill(bytes32 intentId, bytes32 destinationTxHash) external nonReentrant {
        DataTypes.Commitment storage commitment = _commitments[intentId];
        require(commitment.state == DataTypes.IntentState.Committed, "GauloiEscrow: not committed");
        require(commitment.maker == msg.sender, "GauloiEscrow: not committed maker");
        require(block.timestamp <= commitment.commitmentDeadline, "GauloiEscrow: commitment expired");
        require(destinationTxHash != bytes32(0), "GauloiEscrow: empty tx hash");

        commitment.state = DataTypes.IntentState.Filled;
        commitment.fillTxHash = destinationTxHash;
        commitment.disputeWindowEnd = uint40(block.timestamp + settlementWindowDuration);

        emit FillSubmitted(intentId, msg.sender, destinationTxHash, commitment.disputeWindowEnd);
    }

    function settle(DataTypes.Order calldata order) external nonReentrant {
        _settle(order);
    }

    function settleBatch(DataTypes.Order[] calldata orders) external nonReentrant {
        for (uint256 i = 0; i < orders.length; i++) {
            try this.settleInternal(orders[i]) {} catch {}
        }
    }

    /// @dev Internal settle callable by this contract only (for try/catch in batch)
    function settleInternal(DataTypes.Order calldata order) external {
        require(msg.sender == address(this), "GauloiEscrow: internal only");
        _settle(order);
    }

    function _settle(DataTypes.Order calldata order) internal {
        bytes32 intentId = IntentLib.computeIntentId(order);
        DataTypes.Commitment storage commitment = _commitments[intentId];
        require(commitment.state == DataTypes.IntentState.Filled, "GauloiEscrow: not filled");
        require(block.timestamp >= commitment.disputeWindowEnd, "GauloiEscrow: dispute window open");

        commitment.state = DataTypes.IntentState.Settled;

        // Release exposure
        staking.decreaseExposure(commitment.maker, order.inputAmount);

        // Transfer escrowed tokens to maker
        IERC20(order.inputToken).safeTransfer(commitment.maker, order.inputAmount);

        emit IntentSettled(intentId, commitment.maker, order.inputAmount);
    }

    function reclaimExpired(DataTypes.Order calldata order) external nonReentrant {
        bytes32 intentId = IntentLib.computeIntentId(order);
        DataTypes.Commitment storage commitment = _commitments[intentId];
        require(commitment.taker == msg.sender, "GauloiEscrow: not taker");
        require(commitment.state == DataTypes.IntentState.Committed, "GauloiEscrow: not committed");
        require(
            block.timestamp > commitment.commitmentDeadline,
            "GauloiEscrow: commitment not timed out"
        );

        // Release maker's exposure since they failed to fill
        staking.decreaseExposure(commitment.maker, order.inputAmount);

        commitment.state = DataTypes.IntentState.Expired;

        // Return tokens to taker
        IERC20(order.inputToken).safeTransfer(commitment.taker, order.inputAmount);

        emit IntentReclaimed(intentId, commitment.taker);
    }

    // --- Disputes integration ---

    /// @dev Called by Disputes contract to transition intent to Disputed
    function setDisputed(bytes32 intentId) external onlyDisputes {
        DataTypes.Commitment storage commitment = _commitments[intentId];
        require(commitment.state == DataTypes.IntentState.Filled, "GauloiEscrow: not filled");
        commitment.state = DataTypes.IntentState.Disputed;
    }

    /// @dev Called by Disputes contract after resolution — fill was valid
    function resolveValid(bytes32 intentId, DataTypes.Order calldata order) external onlyDisputes nonReentrant {
        require(IntentLib.computeIntentId(order) == intentId, "GauloiEscrow: order mismatch");
        DataTypes.Commitment storage commitment = _commitments[intentId];
        require(commitment.state == DataTypes.IntentState.Disputed, "GauloiEscrow: not disputed");

        commitment.state = DataTypes.IntentState.Settled;
        staking.decreaseExposure(commitment.maker, order.inputAmount);

        // Use try/catch to prevent a blacklisted maker from blocking dispute resolution
        try IERC20(order.inputToken).transfer(commitment.maker, order.inputAmount) returns (bool success) {
            if (success) {
                emit IntentSettled(intentId, commitment.maker, order.inputAmount);
            } else {
                emit SettlementTransferFailed(intentId, commitment.maker, order.inputAmount);
            }
        } catch {
            emit SettlementTransferFailed(intentId, commitment.maker, order.inputAmount);
        }
    }

    /// @dev Called by Disputes contract after resolution — fill was invalid, refund taker
    function resolveInvalid(bytes32 intentId, DataTypes.Order calldata order) external onlyDisputes nonReentrant {
        require(IntentLib.computeIntentId(order) == intentId, "GauloiEscrow: order mismatch");
        DataTypes.Commitment storage commitment = _commitments[intentId];
        require(commitment.state == DataTypes.IntentState.Disputed, "GauloiEscrow: not disputed");

        commitment.state = DataTypes.IntentState.Expired;

        // Use try/catch to prevent a blacklisted taker from blocking dispute resolution
        try IERC20(order.inputToken).transfer(commitment.taker, order.inputAmount) returns (bool success) {
            if (success) {
                emit IntentReclaimed(intentId, commitment.taker);
            } else {
                emit SettlementTransferFailed(intentId, commitment.taker, order.inputAmount);
            }
        } catch {
            emit SettlementTransferFailed(intentId, commitment.taker, order.inputAmount);
        }
    }

    // --- View functions ---

    function getCommitment(bytes32 intentId) external view returns (DataTypes.Commitment memory) {
        return _commitments[intentId];
    }

    function settlementWindow() external view returns (uint256) {
        return settlementWindowDuration;
    }

    function commitmentTimeout() external view returns (uint256) {
        return commitmentTimeoutDuration;
    }
}
