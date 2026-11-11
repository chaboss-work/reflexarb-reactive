// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";
import { IReactive } from "reactive-lib-omni/src/interfaces/IReactive.sol";
import { IPayable } from "reactive-lib-omni/src/interfaces/IPayable.sol";
import { ISystemContract } from "reactive-lib-omni/src/interfaces/ISystemContract.sol";
import { MiniToken } from "../src/MiniToken.sol";
import { MiniPool } from "../src/MiniPool.sol";
import { ReflexArbExecutor } from "../src/ReflexArbExecutor.sol";
import { ReflexArbReactive } from "../src/ReflexArbReactive.sol";

/// Stands in for Reactive Network's system contract at 0x8888…8888.
contract MockSystem {
    uint256 public subscriptions;
    uint256 public callbacks;
    ISystemContract.CallbackConfiguration_V_1_0 internal last;

    function subscribe(uint256, address, uint256, uint256, uint256, uint256) external {
        subscriptions += 1;
    }

    function requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0 memory c) external {
        callbacks += 1;
        last = c;
    }

    function lastCallback() external view returns (uint256 chainId, address recipient, uint64 gasLimit, bytes memory payload) {
        return (last.chainId, last.recipient, last.gasLimit, last.payload);
    }

    function debt(address) external pure returns (uint256) {
        return 0;
    }

    receive() external payable {}
}

/// Stands in for the callback proxy on the origin chain.
contract MockProxy {
    function debt(address) external pure returns (uint256) {
        return 0;
    }

    function deliver(address target, bytes memory payload) external {
        (bool ok, bytes memory ret) = target.call(payload);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }

    receive() external payable {}
}

contract ReflexArbTest is Test {
    address constant SYSTEM = 0x8888888888888888888888888888888888888888;
    uint256 constant ORIGIN = 84532;
    bytes32 constant SYNC = keccak256("Sync(uint112,uint112)");

    MiniToken t0;
    MiniToken t1;
    MiniPool poolA;
    MiniPool poolB;
    MockProxy proxy;
    ReflexArbReactive rc;
    ReflexArbExecutor ex;
    address trader = address(0xBEEF);

    function setUp() public {
        vm.etch(SYSTEM, address(new MockSystem()).code);
        t0 = new MiniToken("Token Zero", "T0");
        t1 = new MiniToken("Token One", "T1");
        poolA = new MiniPool(address(t0), address(t1));
        poolB = new MiniPool(address(t0), address(t1));
        _seed(poolA, 1_000e18, 3_000e18);
        _seed(poolB, 1_000e18, 3_000e18);

        proxy = new MockProxy();
        rc = new ReflexArbReactive(ORIGIN, address(poolA), address(poolB), 80, 0);
        ex = new ReflexArbExecutor(IPayable(payable(address(proxy))), address(rc), poolA, poolB);
        rc.configure(address(ex), 80, 0);
        t1.mint(address(ex), 1_000e18);

        t1.mint(trader, 10_000e18);
        vm.prank(trader);
        t1.approve(address(poolA), type(uint256).max);
    }

    function _seed(MiniPool p, uint256 x, uint256 y) internal {
        t0.mint(address(this), x);
        t1.mint(address(this), y);
        t0.approve(address(p), x);
        t1.approve(address(p), y);
        p.addLiquidity(x, y);
    }

    function _syncLog(MiniPool p, uint256 blockNumber) internal view returns (IReactive.LogRecord memory log_) {
        (uint112 r0, uint112 r1) = p.getReserves();
        log_ = IReactive.LogRecord({
            chainId: ORIGIN,
            contractAddress: address(p),
            topic0: uint256(SYNC),
            topic1: 0,
            topic2: 0,
            topic3: 0,
            data: abi.encode(uint256(r0), uint256(r1)),
            blockNumber: blockNumber,
            opCode: 1,
            blockHash: 0,
            txHash: uint256(keccak256(abi.encode(blockNumber))),
            logIndex: 0
        });
    }

    function _react(MiniPool p, uint256 blockNumber) internal {
        IReactive.LogRecord memory log_ = _syncLog(p, blockNumber);
        vm.prank(SYSTEM);
        rc.react(log_);
    }

    /// Delivers the last requested callback like Reactive does: first argument replaced by the RC address.
    function _deliver() internal {
        (, address recipient,, bytes memory payload) = MockSystem(payable(SYSTEM)).lastCallback();
        proxy.deliver(recipient, _withSender(payload, address(rc)));
    }

    function _withSender(bytes memory payload, address sender) internal pure returns (bytes memory out) {
        out = payload;
        assembly {
            mstore(add(out, 36), sender)
        }
    }

    function _executorLog(bytes32 topic0, uint256 seq_, uint256 originBlock, uint256 execBlock, uint256 blockNumber)
        internal
        view
        returns (IReactive.LogRecord memory log_)
    {
        log_ = IReactive.LogRecord({
            chainId: ORIGIN,
            contractAddress: address(ex),
            topic0: uint256(topic0),
            topic1: seq_,
            topic2: 0,
            topic3: 0,
            data: abi.encode(originBlock, execBlock, block.timestamp, true, uint256(1), uint256(1), uint256(100), uint256(58)),
            blockNumber: blockNumber,
            opCode: 2,
            blockHash: 0,
            txHash: 0,
            logIndex: 2
        });
    }

    function _closeLoop(uint256 seq_, uint256 originBlock, uint256 blockNumber) internal {
        IReactive.LogRecord memory log_ = _executorLog(bytes32(rc.EXECUTED_TOPIC()), seq_, originBlock, blockNumber, blockNumber);
        vm.prank(SYSTEM);
        rc.react(log_);
    }

    function _shock(uint256 amount1) internal {
        vm.prank(trader);
        poolA.swapExactIn(address(t1), amount1, 0, trader); // buys T0 in pool A: pA goes up
    }

    function test_subscribesToPoolsInConstructor() public {
        MockSystem fresh = MockSystem(payable(SYSTEM));
        uint256 before = fresh.subscriptions();
        new ReflexArbReactive(ORIGIN, address(poolA), address(poolB), 80, 0);
        assertEq(fresh.subscriptions(), before + 2);
    }

    function test_noRetriggerInsideFeeBand() public {
        _react(poolB, 10);
        _shock(150e18);
        _react(poolA, 11);
        _deliver();
        // the arbitrage itself emits Sync on both pools; the residual gap (~58 bps) must not re-trigger
        _react(poolA, 12);
        _react(poolB, 12);
        assertEq(rc.seq(), 1, "in flight: no trigger on the arb's own Sync events");
        assertTrue(rc.inFlight());
        _closeLoop(1, 11, 12);
        assertFalse(rc.inFlight());
        _react(poolA, 13);
        assertEq(rc.seq(), 1, "residual gap inside the fee band does not trigger");
    }

    function test_timeoutReleasesStuckLoop() public {
        vm.warp(1_000);
        _react(poolB, 10);
        _shock(150e18);
        _react(poolA, 11); // trigger, callback never lands
        // origin block counts do not matter any more: 500 Base blocks are only ~100 s
        vm.warp(1_000 + rc.timeoutSec() - 1);
        _react(poolA, 500);
        assertEq(rc.seq(), 1, "still in flight one second before the timeout");
        vm.warp(1_000 + rc.timeoutSec());
        _react(poolA, 501);
        assertEq(rc.seq(), 2, "after the timeout the open gap triggers again");
    }

    function test_timersUseTimeNotOriginBlocks() public {
        vm.warp(1_000);
        _react(poolB, 10);
        _shock(150e18);
        _react(poolA, 11); // trigger
        // a huge jump in origin blocks within the same second must not release the in-flight lock
        _react(poolA, 11 + 1_000_000);
        assertEq(rc.seq(), 1);
        assertEq(rc.lastTriggerAt(), 1_000);
        assertEq(rc.lastTriggerOriginBlock(), 11);
    }

    function test_subscribesToExecutorEvents() public view {
        assertEq(MockSystem(payable(SYSTEM)).subscriptions(), 4);
    }

    function test_noTriggerBelowThreshold() public {
        _react(poolA, 10);
        _react(poolB, 10);
        _shock(1e18); // tiny move
        _react(poolA, 11);
        assertEq(MockSystem(payable(SYSTEM)).callbacks(), 0);
        assertEq(rc.seq(), 0);
    }

    function test_gapTriggersCallbackAndExecutorClosesIt() public {
        _react(poolB, 10);
        _shock(150e18);
        _react(poolA, 11);
        assertEq(rc.seq(), 1);
        assertEq(MockSystem(payable(SYSTEM)).callbacks(), 1);
        (uint256 chainId, address recipient, uint64 gasLimit, bytes memory payload) =
            MockSystem(payable(SYSTEM)).lastCallback();
        assertEq(chainId, ORIGIN);
        assertEq(recipient, address(ex));
        assertEq(gasLimit, rc.CALLBACK_GAS());
        assertEq(bytes4(payload), ReflexArbExecutor.onGap.selector);

        uint256 gapBefore = ex.currentGapBps();
        assertGt(gapBefore, 80);
        uint256 bal1Before = t1.balanceOf(address(ex));
        _deliver();
        uint256 gapAfter = ex.currentGapBps();
        assertLt(gapAfter, gapBefore, "gap narrowed");
        assertLe(gapAfter, 61, "gap closed into the two-fee band (2 x 30 bps)");
        assertGt(t1.balanceOf(address(ex)), bal1Before, "executor made a profit in token1");
        assertEq(ex.executed(), 1);
    }

    function test_cooldownSecondsBlockRepeatTriggers() public {
        rc.configure(address(ex), 80, 5); // 5 seconds
        vm.warp(1_000);
        _react(poolB, 10);
        _shock(150e18);
        _react(poolA, 11);
        _shock(10e18);
        _closeLoop(1, 11, 11); // pretend the callback was skipped instantly
        vm.warp(1_004);
        _react(poolA, 40); // inside the 5 s cooldown, even 29 origin blocks later
        assertEq(rc.seq(), 1);
        vm.warp(1_005);
        _react(poolA, 41); // after cooldown, gap still open
        assertEq(rc.seq(), 2);
    }

    function test_reactOnlyFromSystem() public {
        IReactive.LogRecord memory log_ = _syncLog(poolA, 1);
        vm.expectRevert();
        rc.react(log_);
    }

    function test_ignoresOtherContractsAndChains() public {
        IReactive.LogRecord memory log_ = _syncLog(poolA, 1);
        log_.contractAddress = address(0x1234);
        vm.prank(SYSTEM);
        rc.react(log_);
        log_ = _syncLog(poolA, 1);
        log_.chainId = 1;
        vm.prank(SYSTEM);
        rc.react(log_);
        assertEq(rc.a0(), 0);
    }

    function test_executorRejectsStrangers() public {
        bytes memory payload = abi.encodeWithSelector(ReflexArbExecutor.onGap.selector, address(rc), 1, 1, 100);
        vm.expectRevert();
        ex.onGap(address(rc), 1, 1, 100); // not from the proxy
        bytes memory forged = _withSender(payload, address(0xBAD));
        vm.expectRevert();
        proxy.deliver(address(ex), forged); // from the proxy, but not requested by our RC
    }

    function test_unprofitableCallbackReverts() public {
        _react(poolB, 10);
        _shock(150e18);
        _react(poolA, 11);
        // someone else closes the gap before the callback lands
        vm.prank(address(this));
        ex.closeManually(99);
        (, address recipient,, bytes memory payload) = MockSystem(payable(SYSTEM)).lastCallback();
        bytes memory fixed_ = _withSender(payload, address(rc));
        // gap now ~0: executor skips (no profitable size) instead of losing money
        proxy.deliver(recipient, fixed_);
        assertEq(ex.executed(), 1, "only the manual close executed");
    }

    function test_optimalInBeatsNeighbours() public {
        _shock(200e18);
        (uint112 a0, uint112 a1) = poolA.getReserves();
        (uint112 b0, uint112 b1) = poolB.getReserves();
        // pool A is now dear for token0 (pA > pB): buy token0 in B
        uint256 x = ex.optimalIn(b1, b0, a0, a1);
        assertGt(x, 0);
        assertGe(_profit(x, b0, b1, a0, a1), _profit((x * 9) / 10, b0, b1, a0, a1));
        assertGe(_profit(x, b0, b1, a0, a1), _profit((x * 11) / 10, b0, b1, a0, a1));
    }

    function _out(uint256 amountIn, uint256 rIn, uint256 rOut) internal pure returns (uint256) {
        uint256 inFee = amountIn * 9970;
        return (inFee * rOut) / (rIn * 10_000 + inFee);
    }

    function _profit(uint256 x, uint256 b0, uint256 b1, uint256 a0, uint256 a1) internal pure returns (int256) {
        uint256 got0 = _out(x, b1, b0);
        uint256 back1 = _out(got0, a0, a1);
        return int256(back1) - int256(x);
    }

    function test_gapMathMatchesBetweenContracts() public {
        _shock(80e18);
        _react(poolA, 1);
        _react(poolB, 1);
        assertEq(rc.gapBps(), ex.currentGapBps());
    }

    function test_ownerCanWithdrawGasMoney() public {
        vm.deal(address(rc), 1 ether);
        uint256 before = address(this).balance;
        rc.withdraw(0.4 ether);
        assertEq(address(this).balance, before + 0.4 ether);
        assertEq(address(rc).balance, 0.6 ether);
        vm.prank(trader);
        vm.expectRevert(ReflexArbReactive.NotOwner.selector);
        rc.withdraw(0.1 ether);
    }

    function test_executorOwnerCanWithdrawNative() public {
        vm.deal(address(ex), 1 ether);
        uint256 before = address(this).balance;
        ex.withdrawNative(0.25 ether);
        assertEq(address(this).balance, before + 0.25 ether);
        vm.prank(trader);
        vm.expectRevert(ReflexArbExecutor.NotOwner.selector);
        ex.withdrawNative(0.1 ether);
    }

    receive() external payable { }
}
