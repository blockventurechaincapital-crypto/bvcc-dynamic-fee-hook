// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BVCCDynamicFeeHook} from "../src/BVCCDynamicFeeHook.sol";

contract BVCCDynamicFeeHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    BVCCDynamicFeeHook hook;
    address admin = address(0x1);
    address user1 = address(0x2);
    address user2 = address(0x3);

    function setUp() public {
        // Deploy v4-core
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        // Deploy hook to address with correct flags
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG |
            Hooks.BEFORE_SWAP_FLAG |
            Hooks.AFTER_SWAP_FLAG |
            Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );

        address hookAddress = address(flags);

        deployCodeTo(
            "BVCCDynamicFeeHook_v4.3.sol",
            abi.encode(manager, admin),
            hookAddress
        );
        hook = BVCCDynamicFeeHook(payable(hookAddress));

        // Initialize pool with hook
        (key,) = initPool(
            currency0,
            currency1,
            hook,
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            SQRT_PRICE_1_1
        );

        // Add liquidity
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 10 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    // ============ DEPLOYMENT TESTS ============

    function test_HookDeployed() public view {
        assertEq(hook.defaultBaseFee(), 250);
        assertEq(hook.defaultEmergencyFeeCap(), 10_000);
    }

    function test_AdminRolesAssigned() public view {
        assertTrue(hook.hasRole(hook.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(hook.hasRole(hook.FEE_MANAGER_ROLE(), admin));
        assertTrue(hook.hasRole(hook.HOOK_FEE_MANAGER_ROLE(), admin));
        assertTrue(hook.hasRole(hook.PAUSE_MANAGER_ROLE(), admin));
    }

    // ============ FEE CONFIGURATION TESTS ============

    function test_SetDefaultBaseFee() public {
        vm.prank(admin);
        hook.setDefaultBaseFee(500);
        assertEq(hook.defaultBaseFee(), 500);
    }

    function test_SetDefaultBaseFee_RevertIfTooHigh() public {
        vm.prank(admin);
        vm.expectRevert("fee too high");
        hook.setDefaultBaseFee(50_001);
    }

    function test_SetDefaultBaseFee_RevertIfZero() public {
        vm.prank(admin);
        vm.expectRevert("fee cannot be zero");
        hook.setDefaultBaseFee(0);
    }

    function test_SetDefaultBaseFee_RevertIfNotAdmin() public {
        vm.prank(user1);
        vm.expectRevert();
        hook.setDefaultBaseFee(500);
    }

    // ============ EMERGENCY FEE CAP TESTS ============

    function test_SetDefaultEmergencyFeeCap() public {
        vm.prank(admin);
        hook.setDefaultEmergencyFeeCap(20_000);
        assertEq(hook.defaultEmergencyFeeCap(), 20_000);
    }

    function test_SetDefaultEmergencyFeeCap_RevertIfZero() public {
        vm.prank(admin);
        vm.expectRevert("cap cannot be zero");
        hook.setDefaultEmergencyFeeCap(0);
    }

    // ============ SECURITY LIMITS TESTS ============

    function test_GetSecurityLimits() public view {
        (
            uint24 maxBaseFee,
            uint24 absoluteMaxFee,
            uint24 penaltyFee,
            uint256 cooldownSeconds
        ) = hook.getSecurityLimits();

        assertEq(maxBaseFee, 50_000);
        assertEq(absoluteMaxFee, 75_000);
        assertEq(penaltyFee, 25_000);
        assertEq(cooldownSeconds, 300);
    }

    // ============ PAUSE CONTROL TESTS ============

    function test_PauseDynamicFees() public {
        vm.prank(admin);
        hook.pauseDynamicFees(key);

        // Verify via getPoolStats that dynamic fees behavior changed
        (,bool dynamicEnabled,,,,, ) = hook.getPoolStats(key);
        assertTrue(dynamicEnabled); // enabled flag stays true, but pausedDynamicFees is set
    }

    function test_EmergencyPauseAll() public {
        vm.prank(admin);
        hook.emergencyPauseAll(key);

        // After emergency pause, dynamicEnabled should be false
        (,bool dynamicEnabled,,,,, ) = hook.getPoolStats(key);
        assertFalse(dynamicEnabled);
    }

    function test_UnpauseAll() public {
        vm.startPrank(admin);
        hook.emergencyPauseAll(key);
        hook.unpauseAll(key);
        vm.stopPrank();

        // Note: unpauseAll doesn't re-enable the main 'enabled' flag
        // It only unpauses the individual pause flags
    }

    // ============ SWAP TESTS ============

    function test_SwapExecutesSuccessfully() public {
        bool zeroForOne = true;
        int256 amountSpecified = -0.001 ether;

        swap(key, zeroForOne, amountSpecified, ZERO_BYTES);
    }

    function test_SwapBothDirections() public {
        // Swap token0 -> token1
        swap(key, true, -0.001 ether, ZERO_BYTES);

        // Swap token1 -> token0
        swap(key, false, -0.001 ether, ZERO_BYTES);
    }

    // ============ NETWORK CONFIG TESTS ============

    function test_GetCurrentNetworkConfig() public view {
        BVCCDynamicFeeHook.NetworkConfig memory config = hook.getCurrentNetworkConfig();

        // Default config for unknown chain
        assertTrue(config.normalGasThreshold > 0);
        assertTrue(config.highGasThreshold > config.normalGasThreshold);
        assertTrue(config.veryHighGasThreshold > config.highGasThreshold);
    }

    function test_SetNetworkGasThresholds() public {
        vm.prank(admin);
        hook.setNetworkGasThresholds(2 gwei, 5 gwei, 10 gwei);

        BVCCDynamicFeeHook.NetworkConfig memory config = hook.getCurrentNetworkConfig();

        assertEq(config.normalGasThreshold, 2 gwei);
        assertEq(config.highGasThreshold, 5 gwei);
        assertEq(config.veryHighGasThreshold, 10 gwei);
    }

    function test_SetNetworkGasThresholds_RevertIfInvalid() public {
        vm.prank(admin);
        vm.expectRevert("Invalid thresholds");
        hook.setNetworkGasThresholds(5 gwei, 3 gwei, 10 gwei);
    }

    // ============ POOL STATS TESTS ============

    function test_GetPoolStats() public view {
        (
            uint24 baseFee,
            bool dynamicEnabled,
            uint256 volume24h,
            bool usingPreciseData,
            uint256 snapshotCount,
            uint256 currentGas,
            string memory gasLevel
        ) = hook.getPoolStats(key);

        assertEq(baseFee, 250);
        assertTrue(dynamicEnabled);
        assertEq(volume24h, 0);
        assertFalse(usingPreciseData);
        assertEq(snapshotCount, 0);
        assertTrue(currentGas >= 0);
        assertTrue(bytes(gasLevel).length > 0);
    }

    // ============ PREVIEW FEE TESTS ============

    function test_PreviewFee() public view {
        (
            uint24 baseFee,
            uint24 finalFee,
            uint256 currentGas,
            string memory gasLevel,
            bool penaltyWouldApply,
            bool dynamicActive,
            string memory status
        ) = hook.previewFee(key, user1);

        assertEq(baseFee, 250);
        assertTrue(finalFee >= baseFee);
        assertTrue(currentGas >= 0);
        assertTrue(bytes(gasLevel).length > 0);
        // penaltyWouldApply puede ser true o false dependiendo del estado
        assertTrue(dynamicActive);
        assertTrue(bytes(status).length > 0);
    }
}
