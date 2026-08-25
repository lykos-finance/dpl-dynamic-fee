// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title VolatilityGuardHookV6
/// @notice 
///
/// Access model:
///   owner    — proposes sensitive actions
///   guardian — approves proposed actions (2nd signature)
///
/// Sensitive actions (require 2-of-2, 24h timelock):
///   - withdraw ETH / ERC-20
///   - change parameters (MIN_FEE, PANIC_FEE, TICK_THRESHOLD, PANIC_DURATION)
///   - replace owner or guardian
///
/// Unilateral actions (owner OR guardian alone):
///   - pause / unpause the hook (emergency stop)

contract VolatilityGuardHookV6 is IHooks {
    using PoolIdLibrary  for PoolKey;
    using StateLibrary   for IPoolManager;
    using LPFeeLibrary   for uint24;
    using SafeERC20      for IERC20;

    // Immutable

    IPoolManager public immutable poolManager;

    // Access control state

    address public owner;
    address public guardian;
    bool    public paused;

    // Hook parameters (mutable via multisig)

    uint24  public minFee        = 3000;   
    uint24  public panicFee      = 10000; 
    int24   public tickThreshold = 60;
    uint256 public panicDuration = 300;  

    // 2-of-2 Proposal system

    uint256 public constant TIMELOCK_DELAY = 24 hours;

    enum ProposalType {
        None,
        WithdrawETH,
        WithdrawERC20,
        SetParams,
        SetOwner,
        SetGuardian
    }

    struct Proposal {
        ProposalType pType;
        // WithdrawETH / WithdrawERC20
        address token;   
        address recipient;
        uint256 amount;
        // SetParams
        uint24  newMinFee;
        uint24  newPanicFee;
        int24   newTickThreshold;
        uint256 newPanicDuration;
        // SetOwner / SetGuardian
        address newAddress;
        // Flow
        bool    approvedByGuardian;
        uint256 readyAt;
        bool    executed;
    }

    uint256 public proposalCount;
    mapping(uint256 => Proposal) public proposals;

    // Pool state

    struct PoolState {
        int24   referenceTick;
        uint256 panicExpiry;
        bool    initialized;
    }

    mapping(PoolId => PoolState) internal _states;

    // Events

    event PanicActivated(PoolId indexed poolId, int24 currentTick, int24 referenceTick, uint256 expiry);
    event PanicExpired  (PoolId indexed poolId, int24 newReferenceTick);

    event Paused  (address by);
    event Unpaused(address by);

    event ProposalCreated (uint256 indexed id, ProposalType pType, address by);
    event ProposalApproved(uint256 indexed id, address by);
    event ProposalExecuted(uint256 indexed id);
    event ProposalCancelled(uint256 indexed id, address by);

    event OwnerChanged   (address indexed oldOwner,    address indexed newOwner);
    event GuardianChanged(address indexed oldGuardian, address indexed newGuardian);
    event ETHWithdrawn   (address indexed recipient,   uint256 amount);
    event ERC20Withdrawn (address indexed token, address indexed recipient, uint256 amount);
    event ParamsUpdated  (uint24 minFee, uint24 panicFee, int24 tickThreshold, uint256 panicDuration);
    event ETHReceived    (address indexed sender, uint256 amount);

    // Modifiers

    modifier onlyPoolManager() {
        require(msg.sender == address(poolManager), "not PoolManager");
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    modifier onlyGuardian() {
        require(msg.sender == guardian, "not guardian");
        _;
    }

    modifier onlyOwnerOrGuardian() {
        require(msg.sender == owner || msg.sender == guardian, "not authorized");
        _;
    }

    modifier notPaused() {
        require(!paused, "hook paused");
        _;
    }

    // Constructor

    constructor(IPoolManager _poolManager, address _owner, address _guardian) {
        require(_owner    != address(0), "zero owner");
        require(_guardian != address(0), "zero guardian");
        require(_owner    != _guardian,  "owner == guardian");

        poolManager = _poolManager;
        owner       = _owner;
        guardian    = _guardian;
    }

    // Receive ETH
 
    receive() external payable {
        emit ETHReceived(msg.sender, msg.value);
    }


    // Emergency pause  (unilateral — either owner OR guardian)

    function pause() external onlyOwnerOrGuardian {
        require(!paused, "already paused");
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwnerOrGuardian {
        require(paused, "not paused");
        paused = false;
        emit Unpaused(msg.sender);
    }

    // Proposal helpers (internal)

    function _createProposal(Proposal memory p) internal returns (uint256 id) {
        id = proposalCount++;
        p.readyAt  = block.timestamp + TIMELOCK_DELAY;
        p.executed = false;
        p.approvedByGuardian = false;
        proposals[id] = p;
        emit ProposalCreated(id, p.pType, msg.sender);
    }

    function _requireReady(uint256 id) internal view returns (Proposal storage p) {
        p = proposals[id];
        require(p.pType       != ProposalType.None, "no proposal");
        require(!p.executed,                         "already executed");
        require(p.approvedByGuardian,                "not approved by guardian");
        require(block.timestamp >= p.readyAt,        "timelock not elapsed");
    }

    // Step 1: Owner proposes

    /// @notice Propose a withdrawal of ETH
    function proposeWithdrawETH(address recipient, uint256 amount)
        external onlyOwner returns (uint256)
    {
        require(recipient != address(0), "zero recipient");
        require(amount > 0,              "zero amount");
        Proposal memory p;
        p.pType     = ProposalType.WithdrawETH;
        p.recipient = recipient;
        p.amount    = amount;
        return _createProposal(p);
    }

    /// @notice Propose a withdrawal of an ERC-20 token
    function proposeWithdrawERC20(address token, address recipient, uint256 amount)
        external onlyOwner returns (uint256)
    {
        require(token     != address(0), "zero token");
        require(recipient != address(0), "zero recipient");
        require(amount    > 0,           "zero amount");
        Proposal memory p;
        p.pType     = ProposalType.WithdrawERC20;
        p.token     = token;
        p.recipient = recipient;
        p.amount    = amount;
        return _createProposal(p);
    }

    /// @notice Propose new hook parameters
    function proposeSetParams(
        uint24  _minFee,
        uint24  _panicFee,
        int24   _tickThreshold,
        uint256 _panicDuration
    ) external onlyOwner returns (uint256) {
        require(_minFee       > 0,  "zero minFee");
        require(_panicFee     > _minFee, "panicFee <= minFee");
        require(_tickThreshold > 0, "zero threshold");
        require(_panicDuration > 0, "zero duration");
        Proposal memory p;
        p.pType            = ProposalType.SetParams;
        p.newMinFee        = _minFee;
        p.newPanicFee      = _panicFee;
        p.newTickThreshold = _tickThreshold;
        p.newPanicDuration = _panicDuration;
        return _createProposal(p);
    }

    /// @notice Propose replacing the owner
    function proposeSetOwner(address newOwner) external onlyOwner returns (uint256) {
        require(newOwner != address(0), "zero address");
        require(newOwner != guardian,   "owner == guardian");
        Proposal memory p;
        p.pType      = ProposalType.SetOwner;
        p.newAddress = newOwner;
        return _createProposal(p);
    }

    /// @notice Propose replacing the guardian
    function proposeSetGuardian(address newGuardian) external onlyOwner returns (uint256) {
        require(newGuardian != address(0), "zero address");
        require(newGuardian != owner,      "owner == guardian");
        Proposal memory p;
        p.pType      = ProposalType.SetGuardian;
        p.newAddress = newGuardian;
        return _createProposal(p);
    }

    // Step 2: Guardian approves

    function approveProposal(uint256 id) external onlyGuardian {
        Proposal storage p = proposals[id];
        require(p.pType   != ProposalType.None, "no proposal");
        require(!p.executed,                     "already executed");
        require(!p.approvedByGuardian,           "already approved");
        p.approvedByGuardian = true;
        emit ProposalApproved(id, msg.sender);
    }

    // Step 3: Owner executes (after timelock)

    function executeProposal(uint256 id) external onlyOwner {
        Proposal storage p = _requireReady(id);
        p.executed = true;

        if (p.pType == ProposalType.WithdrawETH) {
            _withdrawETH(p.recipient, p.amount);

        } else if (p.pType == ProposalType.WithdrawERC20) {
            _withdrawERC20(p.token, p.recipient, p.amount);

        } else if (p.pType == ProposalType.SetParams) {
            minFee        = p.newMinFee;
            panicFee      = p.newPanicFee;
            tickThreshold = p.newTickThreshold;
            panicDuration = p.newPanicDuration;
            emit ParamsUpdated(minFee, panicFee, tickThreshold, panicDuration);

        } else if (p.pType == ProposalType.SetOwner) {
            emit OwnerChanged(owner, p.newAddress);
            owner = p.newAddress;

        } else if (p.pType == ProposalType.SetGuardian) {
            emit GuardianChanged(guardian, p.newAddress);
            guardian = p.newAddress;
        }

        emit ProposalExecuted(id);
    }

    /// @notice Owner can cancel a proposal at any time (before execution)
    function cancelProposal(uint256 id) external onlyOwner {
        Proposal storage p = proposals[id];
        require(p.pType   != ProposalType.None, "no proposal");
        require(!p.executed,                     "already executed");
        p.pType    = ProposalType.None;
        p.executed = true;   // prevents re-use
        emit ProposalCancelled(id, msg.sender);
    }

    // Internal withdrawal helpers

    function _withdrawETH(address recipient, uint256 amount) internal {
        require(address(this).balance >= amount, "insufficient ETH");
        (bool ok,) = recipient.call{value: amount}("");
        require(ok, "ETH transfer failed");
        emit ETHWithdrawn(recipient, amount);
    }

    function _withdrawERC20(address token, address recipient, uint256 amount) internal {
        IERC20(token).safeTransfer(recipient, amount);
        emit ERC20Withdrawn(token, recipient, amount);
    }

    // View helpers

    function isPanicking(PoolId id) external view returns (bool) {
        return block.timestamp < _states[id].panicExpiry;
    }

    function getProposal(uint256 id) external view returns (Proposal memory) {
        return proposals[id];
    }

    function ethBalance() external view returns (uint256) {
        return address(this).balance;
    }

    // Hook permissions

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize:              false,
            afterInitialize:               true,
            beforeAddLiquidity:            false,
            afterAddLiquidity:             false,
            beforeRemoveLiquidity:         false,
            afterRemoveLiquidity:          false,
            beforeSwap:                    true,
            afterSwap:                     false,
            beforeDonate:                  false,
            afterDonate:                   false,
            beforeSwapReturnDelta:         false,
            afterSwapReturnDelta:          false,
            afterAddLiquidityReturnDelta:  false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // Hook lifecycle

    function afterInitialize(
        address,
        PoolKey calldata key,
        uint160,
        int24 tick
    ) external override onlyPoolManager returns (bytes4) {
        PoolId poolId = key.toId();
        PoolState storage state = _states[poolId];
        state.referenceTick = tick;
        state.panicExpiry   = 0;
        state.initialized   = true;
        return IHooks.afterInitialize.selector;
    }

    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        bytes calldata
    ) external override onlyPoolManager notPaused returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId poolId = key.toId();
        PoolState storage state = _states[poolId];

        (, int24 currentTick,,) = poolManager.getSlot0(poolId);

        if (block.timestamp < state.panicExpiry) {
            return _returnFee(panicFee);
        }

        if (state.panicExpiry != 0) {
            emit PanicExpired(poolId, currentTick);
            state.referenceTick = currentTick;
            state.panicExpiry   = 0;
            return _returnFee(minFee);
        }

        int24 delta = currentTick > state.referenceTick
            ? currentTick - state.referenceTick
            : state.referenceTick - currentTick;

        if (delta >= tickThreshold) {
            state.panicExpiry = block.timestamp + panicDuration;
            emit PanicActivated(poolId, currentTick, state.referenceTick, state.panicExpiry);
            return _returnFee(panicFee);
        }

        return _returnFee(minFee);
    }

    // Internal

    function _returnFee(uint24 fee) internal pure returns (bytes4, BeforeSwapDelta, uint24) {
        return (
            IHooks.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            fee | LPFeeLibrary.OVERRIDE_FEE_FLAG
        );
    }

    // IHooks stubs

    function beforeInitialize(address, PoolKey calldata, uint160)
        external view override onlyPoolManager returns (bytes4)
    { return IHooks.beforeInitialize.selector; }

    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external view override onlyPoolManager returns (bytes4)
    { return IHooks.beforeAddLiquidity.selector; }

    function afterAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        external view override onlyPoolManager returns (bytes4, BalanceDelta)
    { return (IHooks.afterAddLiquidity.selector, BalanceDelta.wrap(0)); }

    function beforeRemoveLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external view override onlyPoolManager returns (bytes4)
    { return IHooks.beforeRemoveLiquidity.selector; }

    function afterRemoveLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        external view override onlyPoolManager returns (bytes4, BalanceDelta)
    { return (IHooks.afterRemoveLiquidity.selector, BalanceDelta.wrap(0)); }

    function afterSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        external view override onlyPoolManager returns (bytes4, int128)
    { return (IHooks.afterSwap.selector, 0); }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external view override onlyPoolManager returns (bytes4)
    { return IHooks.beforeDonate.selector; }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external view override onlyPoolManager returns (bytes4)
    { return IHooks.afterDonate.selector; }
}