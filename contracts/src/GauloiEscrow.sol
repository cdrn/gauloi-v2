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

contract GauloiEscrow is IGauloiEscrow, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IGauloiStaking public staking;
    address public disputes;

    uint256 public settlementWindowDuration;
    uint256 public commitmentTimeoutDuration;

    // Token whitelist
    mapping(address => bool) public supportedTokens;

    // Intent storage
    mapping(bytes32 => DataTypes.Intent) internal _intents;

    // Per-taker nonce for intent ID generation
    mapping(address => uint256) public nonces;

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

    // --- Intent lifecycle ---

    function createIntent(
        address inputToken,
        uint256 inputAmount,
        address outputToken,
        uint256 minOutputAmount,
        uint256 destinationChainId,
        address destinationAddress,
        uint256 expiry
    ) external nonReentrant returns (bytes32 intentId) {
        require(supportedTokens[inputToken], "GauloiEscrow: unsupported input token");
        require(inputAmount > 0, "GauloiEscrow: zero amount");
        require(destinationAddress != address(0), "GauloiEscrow: zero destination");
        require(expiry > block.timestamp, "GauloiEscrow: expiry in past");
        require(minOutputAmount > 0, "GauloiEscrow: zero min output");

        uint256 nonce = nonces[msg.sender]++;

        intentId = IntentLib.computeIntentId(
            msg.sender,
            inputToken,
            inputAmount,
            outputToken,
            minOutputAmount,
            destinationChainId,
            destinationAddress,
            expiry,
            nonce
        );

        require(_intents[intentId].taker == address(0), "GauloiEscrow: intent exists");

        // Effects before interaction (CEI pattern)
        _intents[intentId] = DataTypes.Intent({
            intentId: intentId,
            taker: msg.sender,
            inputToken: inputToken,
            inputAmount: inputAmount,
            destinationChainId: destinationChainId,
            destinationAddress: destinationAddress,
            outputToken: outputToken,
            minOutputAmount: minOutputAmount,
            expiry: expiry,
            state: DataTypes.IntentState.Open,
            maker: address(0),
            commitmentDeadline: 0,
            fillTxHash: bytes32(0),
            disputeWindowEnd: 0
        });

        emit IntentCreated(
            intentId,
            msg.sender,
            inputToken,
            inputAmount,
            destinationChainId,
            outputToken,
            minOutputAmount
        );

        // Interaction last
        IERC20(inputToken).safeTransferFrom(msg.sender, address(this), inputAmount);
    }

    function commitToIntent(bytes32 intentId) external nonReentrant {
        DataTypes.Intent storage intent = _intents[intentId];
        require(intent.state == DataTypes.IntentState.Open, "GauloiEscrow: not open");
        require(block.timestamp < intent.expiry, "GauloiEscrow: intent expired");
        require(staking.isActiveMaker(msg.sender), "GauloiEscrow: not active maker");

        // Reserve exposure in staking
        staking.increaseExposure(msg.sender, intent.inputAmount);

        intent.state = DataTypes.IntentState.Committed;
        intent.maker = msg.sender;
        intent.commitmentDeadline = block.timestamp + commitmentTimeoutDuration;

        emit IntentCommitted(intentId, msg.sender);
    }

    function submitFill(bytes32 intentId, bytes32 destinationTxHash) external nonReentrant {
        DataTypes.Intent storage intent = _intents[intentId];
        require(intent.state == DataTypes.IntentState.Committed, "GauloiEscrow: not committed");
        require(intent.maker == msg.sender, "GauloiEscrow: not committed maker");
        require(block.timestamp <= intent.commitmentDeadline, "GauloiEscrow: commitment expired");
        require(destinationTxHash != bytes32(0), "GauloiEscrow: empty tx hash");

        intent.state = DataTypes.IntentState.Filled;
        intent.fillTxHash = destinationTxHash;
        intent.disputeWindowEnd = block.timestamp + settlementWindowDuration;

        emit FillSubmitted(intentId, msg.sender, destinationTxHash, intent.disputeWindowEnd);
    }

    function settle(bytes32 intentId) external nonReentrant {
        _settle(intentId);
    }

    function settleBatch(bytes32[] calldata intentIds) external nonReentrant {
        for (uint256 i = 0; i < intentIds.length; i++) {
            // Skip failures so one bad intent doesn't block the batch
            try this.settleInternal(intentIds[i]) {} catch {}
        }
    }

    /// @dev Internal settle callable by this contract only (for try/catch in batch)
    function settleInternal(bytes32 intentId) external {
        require(msg.sender == address(this), "GauloiEscrow: internal only");
        _settle(intentId);
    }

    function _settle(bytes32 intentId) internal {
        DataTypes.Intent storage intent = _intents[intentId];
        require(intent.state == DataTypes.IntentState.Filled, "GauloiEscrow: not filled");
        require(block.timestamp >= intent.disputeWindowEnd, "GauloiEscrow: dispute window open");

        intent.state = DataTypes.IntentState.Settled;

        // Release exposure
        staking.decreaseExposure(intent.maker, intent.inputAmount);

        // Transfer escrowed tokens to maker
        IERC20(intent.inputToken).safeTransfer(intent.maker, intent.inputAmount);

        emit IntentSettled(intentId, intent.maker, intent.inputAmount);
    }

    function reclaimExpired(bytes32 intentId) external nonReentrant {
        DataTypes.Intent storage intent = _intents[intentId];
        require(intent.taker == msg.sender, "GauloiEscrow: not taker");

        if (intent.state == DataTypes.IntentState.Open) {
            require(block.timestamp >= intent.expiry, "GauloiEscrow: not expired");
        } else if (intent.state == DataTypes.IntentState.Committed) {
            require(
                block.timestamp > intent.commitmentDeadline,
                "GauloiEscrow: commitment not timed out"
            );
            // Release maker's exposure since they failed to fill
            staking.decreaseExposure(intent.maker, intent.inputAmount);
        } else {
            revert("GauloiEscrow: cannot reclaim in current state");
        }

        intent.state = DataTypes.IntentState.Expired;

        // Return tokens to taker
        IERC20(intent.inputToken).safeTransfer(intent.taker, intent.inputAmount);

        emit IntentReclaimed(intentId, intent.taker);
    }

    // --- Disputes integration ---

    /// @dev Called by Disputes contract to transition intent to Disputed
    function setDisputed(bytes32 intentId) external onlyDisputes {
        DataTypes.Intent storage intent = _intents[intentId];
        require(intent.state == DataTypes.IntentState.Filled, "GauloiEscrow: not filled");
        intent.state = DataTypes.IntentState.Disputed;
    }

    /// @dev Called by Disputes contract after resolution — fill was valid
    function resolveValid(bytes32 intentId) external onlyDisputes nonReentrant {
        DataTypes.Intent storage intent = _intents[intentId];
        require(intent.state == DataTypes.IntentState.Disputed, "GauloiEscrow: not disputed");

        intent.state = DataTypes.IntentState.Settled;
        staking.decreaseExposure(intent.maker, intent.inputAmount);
        IERC20(intent.inputToken).safeTransfer(intent.maker, intent.inputAmount);

        emit IntentSettled(intentId, intent.maker, intent.inputAmount);
    }

    /// @dev Called by Disputes contract after resolution — fill was invalid, refund taker
    function resolveInvalid(bytes32 intentId) external onlyDisputes nonReentrant {
        DataTypes.Intent storage intent = _intents[intentId];
        require(intent.state == DataTypes.IntentState.Disputed, "GauloiEscrow: not disputed");

        intent.state = DataTypes.IntentState.Expired;
        // Exposure is handled by disputes contract via staking.slash()
        IERC20(intent.inputToken).safeTransfer(intent.taker, intent.inputAmount);

        emit IntentReclaimed(intentId, intent.taker);
    }

    // --- View functions ---

    function getIntent(bytes32 intentId) external view returns (DataTypes.Intent memory) {
        return _intents[intentId];
    }

    function settlementWindow() external view returns (uint256) {
        return settlementWindowDuration;
    }

    function commitmentTimeout() external view returns (uint256) {
        return commitmentTimeoutDuration;
    }
}
