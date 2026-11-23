// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title Prooflock
/// @notice Permissionless USDC escrow for a single agent job. The client funds a job naming a
///         provider, a deadline, an optional arbiter and an optional provider bond. The provider
///         submits a deliverable hash/URI. Funds then release on client accept, auto-release after
///         a review window if the client is silent, refund on a missed deadline, or an arbiter
///         decision (a split is allowed).
contract Prooflock is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum Status {
        None,
        Funded,
        Delivered,
        Disputed,
        Released,
        Refunded,
        Resolved
    }

    struct JobParams {
        address provider;
        address arbiter;
        uint256 amount;
        uint64 deadline;
        uint64 reviewWindow;
        uint256 bondRequired;
        uint256 clientAgentId;
        uint256 providerAgentId;
        string metadataURI;
    }

    struct Job {
        address client;
        address provider;
        address arbiter;
        uint256 amount;
        uint256 bondRequired;
        uint256 bondDeposited;
        uint64 deadline;
        uint64 reviewWindow;
        uint64 reviewDeadline;
        uint16 feeBps;
        uint256 clientAgentId;
        uint256 providerAgentId;
        bytes32 deliverableHash;
        string deliverableURI;
        string metadataURI;
        Status status;
    }

    uint16 public constant MAX_FEE_BPS = 500; // 5% hard cap
    uint64 public constant MIN_REVIEW_WINDOW = 1 hours;
    uint64 public constant MAX_REVIEW_WINDOW = 30 days;
    uint64 public constant MIN_DEADLINE_LEAD = 1 hours;
    uint64 public constant MAX_JOB_DURATION = 180 days;
    /// @notice If the arbiter has not resolved a dispute this long after the review deadline, anyone can
    ///         settle it with a 50/50 split and the bond back to the provider (audit fix M-1).
    uint64 public constant DISPUTE_TIMEOUT = 30 days;

    IERC20 public immutable usdc;
    address public feeRecipient;
    uint16 public feeBps; // default 0; snapshotted onto each job at creation

    uint256 public nextJobId = 1;
    /// @notice USDC currently escrowed as job amounts plus posted bonds. Fees are paid out on settle.
    uint256 public totalLocked;

    mapping(uint256 => Job) private _jobs;
    mapping(address => uint256[]) private _jobsOf;

    event JobCreated(
        uint256 indexed jobId,
        address indexed client,
        address indexed provider,
        address arbiter,
        uint256 amount,
        uint64 deadline,
        uint256 bondRequired,
        uint16 feeBps
    );
    event BondPosted(uint256 indexed jobId, uint256 amount);
    event DeliverableSubmitted(
        uint256 indexed jobId, bytes32 deliverableHash, string deliverableURI, uint64 reviewDeadline
    );
    event Released(
        uint256 indexed jobId, address indexed caller, uint256 providerPayout, uint256 fee, bool autoReleased
    );
    event Refunded(uint256 indexed jobId, uint256 amount, uint256 bondReturned);
    event Disputed(uint256 indexed jobId, address indexed client);
    event Resolved(uint256 indexed jobId, uint256 providerPayout, uint256 clientPayout, uint256 fee, bool slashBond);
    event DisputeTimedOut(uint256 indexed jobId, address indexed caller);
    event FeeUpdated(uint16 feeBps);
    event FeeRecipientUpdated(address indexed feeRecipient);

    error ZeroAddress();
    error InvalidProvider();
    error InvalidArbiter();
    error ZeroAmount();
    error InvalidDeadline();
    error InvalidReviewWindow();
    error InvalidStatus();
    error NotClient();
    error NotProvider();
    error NotArbiter();
    error BondNotRequired();
    error BondAlreadyPosted();
    error BondNotPosted();
    error EmptyDeliverable();
    error DeadlinePassed();
    error DeadlineNotReached();
    error ReviewWindowOpen();
    error ReviewWindowClosed();
    error NoArbiter();
    error InvalidSplit();
    error FeeTooHigh();
    error DisputeNotExpired();

    constructor(address usdc_, address owner_, address feeRecipient_) Ownable(owner_) {
        if (usdc_ == address(0) || feeRecipient_ == address(0) || owner_ == address(0)) revert ZeroAddress();
        usdc = IERC20(usdc_);
        feeRecipient = feeRecipient_;
        emit FeeRecipientUpdated(feeRecipient_);
    }

    // ── Owner ────────────────────────────────────────────────────────────────

    /// @notice Protocol fee in bps, taken only from the provider's payout at settlement. Default 0.
    function setFeeBps(uint16 newFeeBps) external onlyOwner {
        if (newFeeBps > MAX_FEE_BPS) revert FeeTooHigh();
        feeBps = newFeeBps;
        emit FeeUpdated(newFeeBps);
    }

    function setFeeRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0)) revert ZeroAddress();
        feeRecipient = newRecipient;
        emit FeeRecipientUpdated(newRecipient);
    }

    // ── Job lifecycle ────────────────────────────────────────────────────────

    /// @notice Create and fund a job in one call. Pulls `amount` USDC from the caller (the client).
    function createJob(JobParams calldata p) external nonReentrant returns (uint256 id) {
        if (p.provider == address(0) || p.provider == msg.sender) revert InvalidProvider();
        if (p.arbiter != address(0) && (p.arbiter == msg.sender || p.arbiter == p.provider)) revert InvalidArbiter();
        if (p.amount == 0) revert ZeroAmount();
        if (p.deadline < block.timestamp + MIN_DEADLINE_LEAD || p.deadline > block.timestamp + MAX_JOB_DURATION) {
            revert InvalidDeadline();
        }
        if (p.reviewWindow < MIN_REVIEW_WINDOW || p.reviewWindow > MAX_REVIEW_WINDOW) revert InvalidReviewWindow();

        id = nextJobId++;
        Job storage job = _jobs[id];
        job.client = msg.sender;
        job.provider = p.provider;
        job.arbiter = p.arbiter;
        job.amount = p.amount;
        job.bondRequired = p.bondRequired;
        job.deadline = p.deadline;
        job.reviewWindow = p.reviewWindow;
        job.feeBps = feeBps;
        job.clientAgentId = p.clientAgentId;
        job.providerAgentId = p.providerAgentId;
        job.metadataURI = p.metadataURI;
        job.status = Status.Funded;

        totalLocked += p.amount;
        _jobsOf[msg.sender].push(id);
        _jobsOf[p.provider].push(id);

        usdc.safeTransferFrom(msg.sender, address(this), p.amount);
        emit JobCreated(id, msg.sender, p.provider, p.arbiter, p.amount, p.deadline, p.bondRequired, job.feeBps);
    }

    /// @notice Provider posts the required bond. Must be called before `deliver` when a bond is required.
    function postBond(uint256 id) external nonReentrant {
        Job storage job = _jobs[id];
        if (job.status != Status.Funded) revert InvalidStatus();
        if (msg.sender != job.provider) revert NotProvider();
        if (job.bondRequired == 0) revert BondNotRequired();
        if (job.bondDeposited != 0) revert BondAlreadyPosted();
        if (block.timestamp >= job.deadline) revert DeadlinePassed();

        uint256 amount = job.bondRequired;
        job.bondDeposited = amount;
        totalLocked += amount;
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        emit BondPosted(id, amount);
    }

    /// @notice Provider submits a deliverable hash (and optional URI) before the deadline.
    function deliver(uint256 id, bytes32 deliverableHash, string calldata deliverableURI) external nonReentrant {
        Job storage job = _jobs[id];
        if (job.status != Status.Funded) revert InvalidStatus();
        if (msg.sender != job.provider) revert NotProvider();
        if (block.timestamp >= job.deadline) revert DeadlinePassed();
        if (deliverableHash == bytes32(0)) revert EmptyDeliverable();
        if (job.bondRequired > 0 && job.bondDeposited < job.bondRequired) revert BondNotPosted();

        job.deliverableHash = deliverableHash;
        job.deliverableURI = deliverableURI;
        job.reviewDeadline = uint64(block.timestamp) + job.reviewWindow;
        job.status = Status.Delivered;
        emit DeliverableSubmitted(id, deliverableHash, deliverableURI, job.reviewDeadline);
    }

    /// @notice Client accepts the deliverable and releases the escrow (minus any snapshotted fee).
    function accept(uint256 id) external nonReentrant {
        Job storage job = _jobs[id];
        if (job.status != Status.Delivered) revert InvalidStatus();
        if (msg.sender != job.client) revert NotClient();
        uint256 payout = job.amount;
        uint256 fee = _settle(job, payout, false, Status.Released);
        emit Released(id, msg.sender, payout - fee, fee, false);
    }

    /// @notice Anyone can release to the provider once the review window has passed without a dispute.
    function autoRelease(uint256 id) external nonReentrant {
        Job storage job = _jobs[id];
        if (job.status != Status.Delivered) revert InvalidStatus();
        if (block.timestamp < job.reviewDeadline) revert ReviewWindowOpen();
        uint256 payout = job.amount;
        uint256 fee = _settle(job, payout, false, Status.Released);
        emit Released(id, msg.sender, payout - fee, fee, true);
    }

    /// @notice Anyone can refund the client if the provider missed the deadline and never delivered.
    ///         A posted bond is returned to the provider (not slashed).
    function refund(uint256 id) external nonReentrant {
        Job storage job = _jobs[id];
        if (job.status != Status.Funded) revert InvalidStatus();
        if (block.timestamp < job.deadline) revert DeadlineNotReached();
        uint256 amount = job.amount;
        uint256 bond = job.bondDeposited;
        _settle(job, 0, false, Status.Refunded);
        emit Refunded(id, amount, bond);
    }

    /// @notice Client disputes a deliverable during the review window. Requires a named arbiter.
    function dispute(uint256 id) external nonReentrant {
        Job storage job = _jobs[id];
        if (job.status != Status.Delivered) revert InvalidStatus();
        if (msg.sender != job.client) revert NotClient();
        if (job.arbiter == address(0)) revert NoArbiter();
        if (block.timestamp >= job.reviewDeadline) revert ReviewWindowClosed();
        job.status = Status.Disputed;
        emit Disputed(id, msg.sender);
    }

    /// @notice Arbiter awards `providerPayout` of the escrow (0..amount) and optionally slashes the bond to the client.
    function resolve(uint256 id, uint256 providerPayout, bool slashBond) external nonReentrant {
        Job storage job = _jobs[id];
        if (job.status != Status.Disputed) revert InvalidStatus();
        if (msg.sender != job.arbiter) revert NotArbiter();
        if (providerPayout > job.amount) revert InvalidSplit();
        uint256 amount = job.amount;
        uint256 fee = _settle(job, providerPayout, slashBond, Status.Resolved);
        emit Resolved(id, providerPayout - fee, amount - providerPayout, fee, slashBond);
    }

    /// @notice Anyone can settle a dispute the arbiter left unresolved for `DISPUTE_TIMEOUT` after the
    ///         review deadline: the escrow is split 50/50 (odd unit to the client, fee only on the
    ///         provider half) and a posted bond goes back to the provider. Audit fix M-1.
    function resolveStaleDispute(uint256 id) external nonReentrant {
        Job storage job = _jobs[id];
        if (job.status != Status.Disputed) revert InvalidStatus();
        if (block.timestamp < uint256(job.reviewDeadline) + DISPUTE_TIMEOUT) revert DisputeNotExpired();
        uint256 amount = job.amount;
        uint256 providerPayout = amount / 2;
        uint256 fee = _settle(job, providerPayout, false, Status.Resolved);
        emit DisputeTimedOut(id, msg.sender);
        emit Resolved(id, providerPayout - fee, amount - providerPayout, fee, false);
    }

    // ── Views ────────────────────────────────────────────────────────────────

    function jobs(uint256 id) external view returns (Job memory) {
        return _jobs[id];
    }

    function jobsOf(address user) external view returns (uint256[] memory) {
        return _jobsOf[user];
    }

    function isTerminal(Status status) public pure returns (bool) {
        return status == Status.Released || status == Status.Refunded || status == Status.Resolved;
    }

    // ── Internals ────────────────────────────────────────────────────────────

    /// @dev Pays the provider `providerPayout` (minus fee), the client the remainder, and routes the bond.
    ///      Updates status and `totalLocked` before any transfer (CEI). Returns the fee taken.
    function _settle(Job storage job, uint256 providerPayout, bool slashBond, Status newStatus)
        internal
        returns (uint256 fee)
    {
        uint256 amount = job.amount;
        uint256 bond = job.bondDeposited;
        fee = (providerPayout * uint256(job.feeBps)) / 10_000;
        uint256 toProvider = providerPayout - fee;
        uint256 toClient = amount - providerPayout;

        job.amount = 0;
        job.bondDeposited = 0;
        job.status = newStatus;
        totalLocked -= amount + bond;

        if (toProvider > 0) usdc.safeTransfer(job.provider, toProvider);
        if (toClient > 0) usdc.safeTransfer(job.client, toClient);
        if (fee > 0) usdc.safeTransfer(feeRecipient, fee);
        if (bond > 0) {
            usdc.safeTransfer(slashBond ? job.client : job.provider, bond);
        }
    }
}
