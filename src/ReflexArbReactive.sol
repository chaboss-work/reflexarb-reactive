// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { AbstractReactive } from "reactive-lib-omni/src/base/AbstractReactive.sol";
import { ISystemContract } from "reactive-lib-omni/src/interfaces/ISystemContract.sol";

/// @notice Reactive contract on Reactive Network (Omni). Watches `Sync` events of two pools on the
///         origin chain, mirrors their reserves, and the moment their prices drift more than
///         `thresholdBps` apart it asks Reactive to call `onGap` on the executor back on the origin chain.
///         Keep `thresholdBps` above the two-pool fee band (2 x 0.3% = ~60 bps): inside the band an
///         arbitrage cannot pay for itself, and the executor would only skip.
contract ReflexArbReactive is AbstractReactive {
    uint256 public constant SYNC_TOPIC = uint256(keccak256("Sync(uint112,uint112)"));
    uint256 public constant EXECUTED_TOPIC =
        uint256(keccak256("ArbExecuted(uint256,uint256,uint256,uint256,bool,uint256,uint256,uint256,uint256)"));
    uint256 public constant SKIPPED_TOPIC = uint256(keccak256("ArbSkipped(uint256,uint256,uint256,string)"));
    uint64 public constant CALLBACK_GAS = 700_000;

    address public immutable owner;
    uint256 public immutable originChainId;
    address public immutable poolA;
    address public immutable poolB;

    address public executor;
    uint256 public thresholdBps;
    /// Timers are in seconds, not origin blocks: Base Sepolia makes a block every 200 ms, so block
    /// counts there are a poor clock. On Omni, `react()` runs inside a regular Reactive Network
    /// block (about one per second), so `block.timestamp` here is wall-clock time.
    uint256 public cooldownSec;

    uint256 public a0;
    uint256 public a1;
    uint256 public b0;
    uint256 public b1;
    uint256 public seq;
    uint256 public lastTriggerAt; // Reactive Network timestamp of the last trigger
    uint256 public lastTriggerOriginBlock; // origin block of the Sync that caused it (for the record)
    /// One arbitrage in flight at a time: the arb itself moves both pools in one transaction, and the
    /// first of its two Sync events would otherwise look like a fresh gap against the stale second pool.
    bool public inFlight;
    uint256 public timeoutSec = 60; // covers reverted or lost callbacks

    event ReservesSeen(address indexed pool, uint256 originBlock, uint256 reserve0, uint256 reserve1, uint256 gapBps);
    event GapDetected(uint256 indexed seq, uint256 originBlock, uint256 originTxHash, uint256 gapBps, uint256 detectedAt);
    event ConfigChanged(address executor, uint256 thresholdBps, uint256 cooldownSec);
    event LoopClosed(uint256 indexed seq, bool executed, uint256 originBlock, uint256 execBlock, uint256 closedAt);

    error NotOwner();

    constructor(uint256 originChainId_, address poolA_, address poolB_, uint256 thresholdBps_, uint256 cooldownSec_)
        payable
    {
        owner = msg.sender;
        originChainId = originChainId_;
        poolA = poolA_;
        poolB = poolB_;
        thresholdBps = thresholdBps_;
        cooldownSec = cooldownSec_;
        SYSTEM.subscribe(originChainId_, poolA_, SYNC_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        SYSTEM.subscribe(originChainId_, poolB_, SYNC_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    function configure(address executor_, uint256 thresholdBps_, uint256 cooldownSec_) external {
        if (msg.sender != owner) revert NotOwner();
        if (executor_ != executor && executor_ != address(0)) {
            SYSTEM.subscribe(originChainId, executor_, EXECUTED_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
            SYSTEM.subscribe(originChainId, executor_, SKIPPED_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        }
        executor = executor_;
        thresholdBps = thresholdBps_;
        cooldownSec = cooldownSec_;
        emit ConfigChanged(executor_, thresholdBps_, cooldownSec_);
    }

    function setTimeoutSec(uint256 timeoutSec_) external {
        if (msg.sender != owner) revert NotOwner();
        timeoutSec = timeoutSec_;
    }

    function react(LogRecord calldata log_) external onlySystem {
        if (log_.chainId != originChainId) return;
        if (log_.contractAddress == executor && (log_.topic0 == EXECUTED_TOPIC || log_.topic0 == SKIPPED_TOPIC)) {
            // both events start with (originBlock, execBlock) after the indexed seq
            (uint256 originBlock, uint256 execBlock) = abi.decode(log_.data, (uint256, uint256));
            inFlight = false;
            emit LoopClosed(log_.topic1, log_.topic0 == EXECUTED_TOPIC, originBlock, execBlock, block.timestamp);
            return;
        }
        if (log_.topic0 != SYNC_TOPIC) return;
        (uint256 r0, uint256 r1) = abi.decode(log_.data, (uint256, uint256));
        if (log_.contractAddress == poolA) {
            (a0, a1) = (r0, r1);
        } else if (log_.contractAddress == poolB) {
            (b0, b1) = (r0, r1);
        } else {
            return;
        }
        uint256 gap = gapBps();
        emit ReservesSeen(log_.contractAddress, log_.blockNumber, r0, r1, gap);
        if (executor == address(0) || gap < thresholdBps) return;
        if (lastTriggerAt != 0 && block.timestamp < lastTriggerAt + cooldownSec) return;
        if (inFlight && block.timestamp < lastTriggerAt + timeoutSec) return;

        inFlight = true;
        lastTriggerAt = block.timestamp;
        lastTriggerOriginBlock = log_.blockNumber;
        seq += 1;
        emit GapDetected(seq, log_.blockNumber, log_.txHash, gap, block.timestamp);
        bytes memory payload = abi.encodeWithSignature(
            "onGap(address,uint256,uint256,uint256)", address(0), seq, log_.blockNumber, gap
        );
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: originChainId,
                recipient: executor,
                gasLimit: CALLBACK_GAS,
                payload: payload
            })
        );
    }

    function gapBps() public view returns (uint256) {
        if (a0 == 0 || b0 == 0) return 0;
        uint256 x = a1 * b0;
        uint256 y = b1 * a0;
        uint256 lo = x < y ? x : y;
        if (lo == 0) return 0;
        return ((x > y ? x - y : y - x) * 10_000) / lo;
    }

    /// @notice Pay outstanding system debt from this contract's lREACT/REACT balance.
    function coverDebt() external {
        _coverDebt();
    }

    /// @notice Recover unused gas money, e.g. before replacing this contract with a new version.
    function withdraw(uint256 amount) external {
        if (msg.sender != owner) revert NotOwner();
        (bool ok,) = payable(owner).call{ value: amount }("");
        require(ok, "withdraw failed");
    }
}
