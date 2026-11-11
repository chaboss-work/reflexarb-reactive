// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

interface IERC20Min {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @notice Constant-product pool (x * y = k, 0.3% fee) that emits Uniswap V2 style `Sync` events,
///         so the reactive contract can watch it exactly like a V2 pair.
contract MiniPool {
    address public immutable token0;
    address public immutable token1;
    uint112 public reserve0;
    uint112 public reserve1;

    uint256 public constant FEE_BPS = 30;

    /// Same signature as Uniswap V2: topic0 = keccak256("Sync(uint112,uint112)").
    event Sync(uint112 reserve0, uint112 reserve1);
    event Swap(address indexed sender, address indexed tokenIn, uint256 amountIn, uint256 amountOut, address indexed to);
    event Mint(address indexed provider, uint256 amount0, uint256 amount1);

    error BadToken();
    error Slippage();
    error Empty();

    constructor(address token0_, address token1_) {
        token0 = token0_;
        token1 = token1_;
    }

    function getReserves() external view returns (uint112, uint112) {
        return (reserve0, reserve1);
    }

    /// @notice Anyone can add liquidity at any ratio (demo pool, no LP shares).
    function addLiquidity(uint256 amount0, uint256 amount1) external {
        IERC20Min(token0).transferFrom(msg.sender, address(this), amount0);
        IERC20Min(token1).transferFrom(msg.sender, address(this), amount1);
        _sync();
        emit Mint(msg.sender, amount0, amount1);
    }

    function quote(address tokenIn, uint256 amountIn) public view returns (uint256 amountOut) {
        (uint256 rIn, uint256 rOut) = tokenIn == token0 ? (uint256(reserve0), uint256(reserve1)) : (uint256(reserve1), uint256(reserve0));
        if (tokenIn != token0 && tokenIn != token1) revert BadToken();
        if (rIn == 0 || rOut == 0) revert Empty();
        uint256 inWithFee = amountIn * (10_000 - FEE_BPS);
        amountOut = (inWithFee * rOut) / (rIn * 10_000 + inWithFee);
    }

    function swapExactIn(address tokenIn, uint256 amountIn, uint256 minOut, address to) external returns (uint256 amountOut) {
        amountOut = quote(tokenIn, amountIn);
        if (amountOut < minOut) revert Slippage();
        address tokenOut = tokenIn == token0 ? token1 : token0;
        IERC20Min(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        IERC20Min(tokenOut).transfer(to, amountOut);
        _sync();
        emit Swap(msg.sender, tokenIn, amountIn, amountOut, to);
    }

    function _sync() internal {
        reserve0 = uint112(IERC20Min(token0).balanceOf(address(this)));
        reserve1 = uint112(IERC20Min(token1).balanceOf(address(this)));
        emit Sync(reserve0, reserve1);
    }
}
