// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

/**
 * @title Example Swap Script for BVCC Dynamic Fee Hook
 * @notice Demonstrates how to execute swaps on pools using the BVCC Hook
 * @dev Modify the constants below for your specific pool and network
 * 
 * Usage:
 *   forge script script/ExampleSwap.s.sol --rpc-url <RPC_URL> --broadcast
 */
contract ExampleSwap is Script {
    using CurrencyLibrary for Currency;

    // ============ CONFIGURE THESE FOR YOUR NETWORK ============
    
    // BSC Mainnet
    PoolSwapTest constant SWAP_ROUTER = PoolSwapTest(0x3E1248B5F05DF9bD7f611BC258e239b351D7dA6a);
    
    // BVCC Hook addresses by network:
    // BSC:      0x8a36d8408F5285c3F81509947bc187b3c0eFD0C4
    // Ethereum: 0xF9CED7D0F5292aF02385410Eda5B7570b10b50c4
    // Arbitrum: 0x2097d7329389264a1542Ad50802bB0DE84a650c4
    // Base:     0x2c56c1302B6224B2bB1906c46F554622e12F10C4
    address constant HOOK = 0x8a36d8408F5285c3F81509947bc187b3c0eFD0C4;
    
    // Your token address (set to address(0) for native token like ETH/BNB)
    address constant TOKEN = address(0); // Change this to your token
    
    // ============ SWAP CONFIGURATION ============
    
    // true = Native -> Token, false = Token -> Native
    bool constant ZERO_FOR_ONE = true;
    
    // Amount to swap (negative = exact input, positive = exact output)
    int256 constant AMOUNT = -0.001 ether;

    function run() external {
        uint256 deployerPrivateKey = uint256(vm.envBytes32("PRIVATE_KEY"));
        address swapper = vm.addr(deployerPrivateKey);

        // Build pool key
        // Note: currency0 must be < currency1 (sorted by address)
        Currency currency0 = Currency.wrap(address(0)); // Native (BNB/ETH)
        Currency currency1 = Currency.wrap(TOKEN);
        
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 8388608, // DYNAMIC_FEE_FLAG
            tickSpacing: 60,
            hooks: IHooks(HOOK)
        });

        vm.startBroadcast(deployerPrivateKey);

        console.log("===========================================");
        console.log("BVCC Dynamic Fee Hook - Example Swap");
        console.log("===========================================");
        console.log("Hook:", HOOK);
        console.log("Swapper:", swapper);

        // Get balances before
        uint256 nativeBalanceBefore = swapper.balance;
        uint256 tokenBalanceBefore = TOKEN != address(0) ? IERC20(TOKEN).balanceOf(swapper) : 0;

        console.log("Balances BEFORE:");
        console.log("- Native:", nativeBalanceBefore);
        console.log("- Token:", tokenBalanceBefore);

        // Approve token if needed
        if (TOKEN != address(0) && !ZERO_FOR_ONE) {
            if (IERC20(TOKEN).allowance(swapper, address(SWAP_ROUTER)) < uint256(AMOUNT > 0 ? AMOUNT : -AMOUNT)) {
                console.log("Approving token...");
                IERC20(TOKEN).approve(address(SWAP_ROUTER), type(uint256).max);
            }
        }

        // Execute swap
        console.log("Executing swap...");
        
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        uint160 sqrtPriceLimit = ZERO_FOR_ONE 
            ? TickMath.MIN_SQRT_PRICE + 1 
            : TickMath.MAX_SQRT_PRICE - 1;

        SWAP_ROUTER.swap{value: ZERO_FOR_ONE ? uint256(-AMOUNT) : 0}(
            key,
            SwapParams({
                zeroForOne: ZERO_FOR_ONE,
                amountSpecified: AMOUNT,
                sqrtPriceLimitX96: sqrtPriceLimit
            }),
            testSettings,
            ""
        );

        // Get balances after
        uint256 nativeBalanceAfter = swapper.balance;
        uint256 tokenBalanceAfter = TOKEN != address(0) ? IERC20(TOKEN).balanceOf(swapper) : 0;

        console.log("===========================================");
        console.log("Balances AFTER:");
        console.log("- Native:", nativeBalanceAfter);
        console.log("- Token:", tokenBalanceAfter);
        console.log("===========================================");

        vm.stopBroadcast();
    }
}
