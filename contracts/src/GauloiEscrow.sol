// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IGauloiEscrow} from "./interfaces/IGauloiEscrow.sol";
import {IGauloiStaking} from "./interfaces/IGauloiStaking.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {DataTypes} from "./types/DataTypes.sol";
import {IntentLib} from "./libraries/IntentLib.sol";
import {SignatureLib} from "./libraries/SignatureLib.sol";
import {TransferLib} from "./libraries/TransferLib.sol";

contract GauloiEscrow is IGauloiEscrow, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using TransferLib for IERC20;

    IGauloiStaking public staking;
    address public disputes;

    uint256 public settlementWindowDuration;
    uint256 public commitmentTimeoutDuration;

    // Per-corridor settlement window overrides (destination chain id => window).
    // 0 means "use the default". The window is an insurance premium priced by
    // corridor verifiability: provable corridors shrink toward destination
    // finality, council corridors stay wide.
    mapping(uint256 => uint256) public corridorSettlementWindow;

    // Protocol fee, taken from the maker's settlement proceeds (never from
    // taker refunds). Hard-capped; ships at 0 so the switch is audited in
    // before it is ever non-zero.
    uint256 public constant MAX_PROTOCOL_FEE_BPS = 100; // 1%
    uint256 public protocolFeeBps;
    address public treasury;

    bytes32 public immutable domainSeparator;

    // Token whitelist
    mapping(address => bool) public supportedTokens;

    // Commitment storage (intentId → Commitment)
    mapping(bytes32 => DataTypes.Commitment) internal _commitments;

    // Live escrowed liability per token — the sum currently owed to takers/makers
    // across open commitments. rescueTokens can only touch balance above this.
    mapping(address => uint256) public escrowedBalance;

    bool public paused;

    modifier whenNotPaused() {
        require(!paused, "GauloiEscrow: paused");
        _;
    }

    modifier onlyDisputes() {
        require(msg.sender == disputes, "GauloiEscrow: caller is not disputes");
        _;
    }

    modifier onlyOwnerOrDisputes() {
        require(
            msg.sender == owner() || msg.sender == disputes,
            "GauloiEscrow: caller is not owner or disputes"
        );
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
        address oldDisputes = disputes;
        disputes = _disputes;
        emit DisputesUpdated(oldDisputes, _disputes);
    }

    function setSettlementWindow(uint256 newWindow) external onlyOwner {
        require(newWindow >= 1 minutes && newWindow <= 7 days, "GauloiEscrow: window out of range");
        uint256 oldValue = settlementWindowDuration;
        settlementWindowDuration = newWindow;
        emit SettlementWindowUpdated(oldValue, newWindow);
    }

    function setCorridorSettlementWindow(uint256 destinationChainId, uint256 newWindow) external onlyOwner {
        require(
            newWindow == 0 || (newWindow >= 1 minutes && newWindow <= 7 days),
            "GauloiEscrow: window out of range"
        );
        uint256 oldValue = corridorSettlementWindow[destinationChainId];
        corridorSettlementWindow[destinationChainId] = newWindow;
        emit CorridorSettlementWindowUpdated(destinationChainId, oldValue, newWindow);
    }

    function setCommitmentTimeout(uint256 newTimeout) external onlyOwner {
        require(newTimeout >= 1 minutes && newTimeout <= 24 hours, "GauloiEscrow: timeout out of range");
        uint256 oldValue = commitmentTimeoutDuration;
        commitmentTimeoutDuration = newTimeout;
        emit CommitmentTimeoutUpdated(oldValue, newTimeout);
    }

    function setTreasury(address _treasury) external onlyOwner {
        require(_treasury != address(0), "GauloiEscrow: zero address");
        address oldTreasury = treasury;
        treasury = _treasury;
        emit TreasuryUpdated(oldTreasury, _treasury);
    }

    function setProtocolFee(uint256 newFeeBps) external onlyOwner {
        require(newFeeBps <= MAX_PROTOCOL_FEE_BPS, "GauloiEscrow: fee exceeds cap");
        require(newFeeBps == 0 || treasury != address(0), "GauloiEscrow: treasury not set");
        uint256 oldValue = protocolFeeBps;
        protocolFeeBps = newFeeBps;
        emit ProtocolFeeUpdated(oldValue, newFeeBps);
    }

    function addSupportedToken(address token) external onlyOwner {
        require(token != address(0), "GauloiEscrow: zero address");
        supportedTokens[token] = true;
        emit TokenAdded(token);
    }

    function removeSupportedToken(address token) external onlyOwner {
        supportedTokens[token] = false;
        emit TokenRemoved(token);
    }

    /// @dev Recover only the surplus above live escrow liability — tokens stranded
    ///      by failed transfers or sent in by mistake. Cannot touch funds backing
    ///      open commitments, so the owner can never rug escrowed taker/maker funds.
    function rescueTokens(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        require(to != address(0), "GauloiEscrow: zero address");
        uint256 liability = escrowedBalance[token];
        uint256 bal = IERC20(token).balanceOf(address(this));
        uint256 surplus = bal > liability ? bal - liability : 0;
        require(amount <= surplus, "GauloiEscrow: exceeds rescuable surplus");
        IERC20(token).safeTransfer(to, amount);
    }

    // --- Pause ---

    function pause() external onlyOwnerOrDisputes {
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
            commitmentDeadline: SafeCast.toUint40(block.timestamp + commitmentTimeoutDuration),
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

        // Pull tokens from taker — reject fee-on-transfer tokens
        uint256 balBefore = IERC20(order.inputToken).balanceOf(address(this));
        IERC20(order.inputToken).safeTransferFrom(order.taker, address(this), order.inputAmount);
        require(
            IERC20(order.inputToken).balanceOf(address(this)) - balBefore == order.inputAmount,
            "GauloiEscrow: fee-on-transfer token"
        );

        // Record the new escrow liability (checked exact above)
        escrowedBalance[order.inputToken] += order.inputAmount;
    }

    /// @dev Takes the full order so the dispute window can be priced per corridor.
    ///      The order is bound to the commitment via intentId — a mismatched order
    ///      computes a different id and fails the state/maker checks.
    function submitFill(DataTypes.Order calldata order, bytes32 destinationTxHash) external nonReentrant {
        bytes32 intentId = IntentLib.computeIntentId(order);
        DataTypes.Commitment storage commitment = _commitments[intentId];
        require(commitment.state == DataTypes.IntentState.Committed, "GauloiEscrow: not committed");
        require(commitment.maker == msg.sender, "GauloiEscrow: not committed maker");
        require(block.timestamp <= commitment.commitmentDeadline, "GauloiEscrow: commitment expired");
        require(destinationTxHash != bytes32(0), "GauloiEscrow: empty tx hash");

        commitment.state = DataTypes.IntentState.Filled;
        commitment.fillTxHash = destinationTxHash;
        commitment.disputeWindowEnd =
            SafeCast.toUint40(block.timestamp + settlementWindowFor(order.destinationChainId));

        emit FillSubmitted(intentId, msg.sender, destinationTxHash, commitment.disputeWindowEnd);
    }

    function settle(DataTypes.Order calldata order) external nonReentrant {
        _settle(order);
    }

    function settleBatch(DataTypes.Order[] calldata orders) external nonReentrant {
        for (uint256 i = 0; i < orders.length; i++) {
            try this.settleInternal(orders[i]) {}
            catch {
                emit BatchSettleFailed(IntentLib.computeIntentId(orders[i]));
            }
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

        _payoutMaker(intentId, commitment.maker, order.inputToken, order.inputAmount);
    }

    /// @dev Maker settlement payout with protocol fee. tryTransfer so a
    ///      blacklisted maker cannot DoS settlement (funds recoverable via
    ///      rescueTokens) — and, unlike try/catch on IERC20.transfer, it
    ///      reports success correctly for no-return-data tokens (USDT).
    function _payoutMaker(bytes32 intentId, address maker, address token, uint256 amount) internal {
        // Liability discharged whether or not the transfer succeeds — a failed
        // transfer leaves the funds as recoverable surplus, not live escrow.
        escrowedBalance[token] -= amount;

        uint256 fee = (amount * protocolFeeBps) / 10_000;
        uint256 makerAmount = amount - fee;

        if (IERC20(token).tryTransfer(maker, makerAmount)) {
            emit IntentSettled(intentId, maker, makerAmount);
        } else {
            emit SettlementTransferFailed(intentId, maker, makerAmount);
        }

        if (fee > 0) {
            if (IERC20(token).tryTransfer(treasury, fee)) {
                emit ProtocolFeeCollected(intentId, token, fee);
            } else {
                emit SettlementTransferFailed(intentId, treasury, fee);
            }
        }
    }

    /// @dev Taker refund — never fee'd. tryTransfer so a blacklisted taker
    ///      cannot block exposure release (funds recoverable via rescueTokens)
    function _refundTaker(bytes32 intentId, address taker, address token, uint256 amount) internal {
        escrowedBalance[token] -= amount;

        if (IERC20(token).tryTransfer(taker, amount)) {
            emit IntentReclaimed(intentId, taker);
        } else {
            emit SettlementTransferFailed(intentId, taker, amount);
        }
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

        _refundTaker(intentId, commitment.taker, order.inputToken, order.inputAmount);
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

        _payoutMaker(intentId, commitment.maker, order.inputToken, order.inputAmount);
    }

    /// @dev Called by Disputes contract after resolution — fill was invalid, refund taker
    function resolveInvalid(bytes32 intentId, DataTypes.Order calldata order) external onlyDisputes nonReentrant {
        require(IntentLib.computeIntentId(order) == intentId, "GauloiEscrow: order mismatch");
        DataTypes.Commitment storage commitment = _commitments[intentId];
        require(commitment.state == DataTypes.IntentState.Disputed, "GauloiEscrow: not disputed");

        commitment.state = DataTypes.IntentState.Expired;

        _refundTaker(intentId, commitment.taker, order.inputToken, order.inputAmount);
    }

    // --- View functions ---

    function getCommitment(bytes32 intentId) external view returns (DataTypes.Commitment memory) {
        return _commitments[intentId];
    }

    function settlementWindow() external view returns (uint256) {
        return settlementWindowDuration;
    }

    function settlementWindowFor(uint256 destinationChainId) public view returns (uint256) {
        uint256 corridorWindow = corridorSettlementWindow[destinationChainId];
        return corridorWindow == 0 ? settlementWindowDuration : corridorWindow;
    }

    function commitmentTimeout() external view returns (uint256) {
        return commitmentTimeoutDuration;
    }
}
