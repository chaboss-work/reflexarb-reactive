// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { AbstractCallback } from "reactive-lib-omni/src/base/AbstractCallback.sol";
import { IPayable } from "reactive-lib-omni/src/interfaces/IPayable.sol";
import { MiniPool, IERC20Min } from "./MiniPool.sol";

/// @notice Callback contract on the origin chain. Reactive Network calls `onGap` when the reactive
///         contract sees the two pools drift apart. It closes the gap with its own inventory:
///         buy the asset where it is cheap, sell it where it is dear, keep the difference.
contract ReflexArbExecutor is AbstractCallback {
    uint256 internal constant G = 9970; // 1 - 0.3% pool fee, in 1e4

    MiniPool public immutable poolA;
    MiniPool public immutable poolB;
    address public immutable token0;
    address public immutable token1;
    address public immutable owner;

    uint256 public executed;
    uint256 public totalProfit1; // profit accumulated in token1 units

    event ArbExecuted(
        uint256 indexed seq,
        uint256 originBlock,
        uint256 execBlock,
        uint256 execTimestamp,
        bool buyInB,
        uint256 amountIn1,
        uint256 profit1,
        uint256 gapBeforeBps,
        uint256 gapAfterBps
    );
    event ArbSkipped(uint256 indexed seq, uint256 originBlock, uint256 execBlock, string reason);

    error NotOwner();

    constructor(IPayable callbackProxy_, address reactive_, MiniPool poolA_, MiniPool poolB_)
        payable
        AbstractCallback(callbackProxy_, reactive_)
    {
        poolA = poolA_;
        poolB = poolB_;
        token0 = poolA_.token0();
        token1 = poolA_.token1();
        owner = msg.sender;
        IERC20Min(token1).approve(address(poolA_), type(uint256).max);
        IERC20Min(token1).approve(address(poolB_), type(uint256).max);
        IERC20Min(token0).approve(address(poolA_), type(uint256).max);
        IERC20Min(token0).approve(address(poolB_), type(uint256).max);
    }

    /// @param reactive_ overwritten by Reactive Network with the requesting reactive contract
    function onGap(address reactive_, uint256 seq, uint256 originBlock, uint256 gapBps_)
        external
        onlyServiceProvider
        onlyCallbackSender(reactive_)
    {
        _close(seq, originBlock, gapBps_);
    }

    /// @notice Same logic without Reactive, for local tests and manual comparison runs.
    function closeManually(uint256 seq) external {
        if (msg.sender != owner) revert NotOwner();
        _close(seq, block.number, currentGapBps());
    }

    function currentGapBps() public view returns (uint256) {
        (uint112 a0, uint112 a1) = poolA.getReserves();
        (uint112 b0, uint112 b1) = poolB.getReserves();
        return gapBps(a0, a1, b0, b1);
    }

    /// @notice |pA - pB| / min(pA, pB) in basis points, with p = reserve1 / reserve0.
    function gapBps(uint256 a0, uint256 a1, uint256 b0, uint256 b1) public pure returns (uint256) {
        if (a0 == 0 || b0 == 0) return 0;
        uint256 x = a1 * b0; // pA scaled by a0*b0
        uint256 y = b1 * a0; // pB scaled by a0*b0
        uint256 lo = x < y ? x : y;
        if (lo == 0) return 0;
        return ((x > y ? x - y : y - x) * 10_000) / lo;
    }

    /// @notice Optimal token1 input for the path token1 -(pool in)-> token0 -(pool out)-> token1.
    /// @dev Closed form for two constant-product pools with the same fee:
    ///      Ea = rIn1 * rOut0 / (rOut0 + g*rIn0),  Eb = g * rIn0 * rOut1 / (rOut0 + g*rIn0),
    ///      x* = (sqrt(Ea * Eb * g) - Ea) / g
    function optimalIn(uint256 inPool1, uint256 inPool0, uint256 outPool0, uint256 outPool1) public pure returns (uint256) {
        uint256 denom = outPool0 * 10_000 + G * inPool0;
        uint256 ea = (inPool1 * outPool0 * 10_000) / denom;
        uint256 eb = (G * inPool0 * outPool1) / denom;
        uint256 root = _sqrt((ea * eb * G) / 10_000);
        if (root <= ea) return 0;
        return ((root - ea) * 10_000) / G;
    }

    function _close(uint256 seq, uint256 originBlock, uint256 gapBefore) internal {
        (uint112 a0, uint112 a1) = poolA.getReserves();
        (uint112 b0, uint112 b1) = poolB.getReserves();
        // token0 is cheaper (in token1) where reserve1/reserve0 is lower: buy token0 there.
        bool buyInB = uint256(a1) * b0 > uint256(b1) * a0;
        (MiniPool cheap, MiniPool dear) = buyInB ? (poolB, poolA) : (poolA, poolB);
        uint256 amountIn = buyInB ? optimalIn(b1, b0, a0, a1) : optimalIn(a1, a0, b0, b1);
        uint256 inventory = IERC20Min(token1).balanceOf(address(this));
        if (amountIn > inventory) amountIn = inventory;
        if (amountIn == 0) {
            emit ArbSkipped(seq, originBlock, block.number, "no profitable size");
            return;
        }
        uint256 got0 = cheap.swapExactIn(token1, amountIn, 0, address(this));
        uint256 back1 = dear.swapExactIn(token0, got0, 0, address(this));
        if (back1 <= amountIn) {
            // gap already closed by someone else: revert the whole callback so we lose nothing but gas
            revert("unprofitable");
        }
        uint256 profit = back1 - amountIn;
        executed += 1;
        totalProfit1 += profit;
        emit ArbExecuted(seq, originBlock, block.number, block.timestamp, buyInB, amountIn, profit, gapBefore, currentGapBps());
    }

    /// @notice Settle any debt with the callback proxy from this contract's ETH balance.
    function coverDebt() external {
        _coverDebt();
    }

    function withdraw(address token, uint256 amount) external {
        if (msg.sender != owner) revert NotOwner();
        IERC20Min(token).transfer(owner, amount);
    }

    /// @notice Recover unused callback gas money, e.g. before replacing this contract.
    function withdrawNative(uint256 amount) external {
        if (msg.sender != owner) revert NotOwner();
        (bool ok,) = payable(owner).call{ value: amount }("");
        require(ok, "withdraw failed");
    }

    function _sqrt(uint256 x) internal pure returns (uint256 z) {
        if (x == 0) return 0;
        z = x;
        uint256 y = (x >> 1) + 1;
        while (y < z) {
            z = y;
            y = (x / y + y) >> 1;
        }
    }
}
