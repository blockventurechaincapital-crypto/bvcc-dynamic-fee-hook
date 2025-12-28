// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BaseHook} from "@uniswap/v4-periphery/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {AccessControl} from "@openzeppelin/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/utils/ReentrancyGuard.sol";

/**
 * @title BVCC Dynamic Fee Hook V4.3
 * @author BlockVenture Chain Capital
 * @notice Advanced anti-bot hook for Uniswap v4 with intelligent fee dynamics
 * @dev Implements dynamic fees based on volatility, volume, and gas conditions
 */
contract BVCCDynamicFeeHook is BaseHook, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    bytes32 public constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");
    bytes32 public constant HOOK_FEE_MANAGER_ROLE = keccak256("HOOK_FEE_MANAGER_ROLE");
    bytes32 public constant PAUSE_MANAGER_ROLE = keccak256("PAUSE_MANAGER_ROLE");

    uint24 public constant REPEAT_PENALTY_FEE = 25_000;
    uint256 public constant COOLDOWN_SECONDS = 300;
    uint256 public constant HOOK_FEE_UNITS = 1;
    uint256 public constant HOOK_FEE_DENOMINATOR = 10_000;
    uint24 public constant MAX_BASE_FEE = 50_000;
    uint24 public constant ABSOLUTE_MAX_FEE = 75_000;
    uint256 public constant SNAPSHOT_INTERVAL = 900;
    uint256 public constant HOUR_SECONDS = 3600;
    uint256 public constant VOLUME_THRESHOLD_FOR_PRECISE_DATA = 20_000e18;
    uint256 public constant LITE_MODE_TRACKING_INTERVAL = 21600;

    struct NetworkConfig {
        uint256 normalGasThreshold;
        uint256 highGasThreshold;
        uint256 veryHighGasThreshold;
        uint24 highGasMultiplier;
        uint24 veryHighGasMultiplier;
        uint24 extremeGasMultiplier;
        bool isConfigured;
    }

    struct PoolDynamicConfig {
        bool enabled;
        bool pausedDynamicFees;
        bool pausedAntiBot;
        bool pausedHookFee;
        bool pausedEmergencyFees;
        uint16 volLowThreshold;
        uint16 volHighThreshold;
        uint16 volExtremeThreshold;
        uint16 volLowMultiplier;
        uint16 volNormalMultiplier;
        uint16 volHighMultiplier;
        uint16 volExtremeMultiplier;
        uint16 volumeVeryLowRatio;
        uint16 volumeLowRatio;
        uint16 volumeHighRatio;
        uint16 volumeVeryHighRatio;
        uint16 volumeVeryLowMultiplier;
        uint16 volumeLowMultiplier;
        uint16 volumeNormalMultiplier;
        uint16 volumeHighMultiplier;
        uint16 volumeVeryHighMultiplier;
    }

    struct PriceSnapshot {
        uint160 sqrtPriceX96;
        uint256 timestamp;
    }

    struct VolumeData {
        uint256 currentHourVolume;
        uint256 hourlyVolumes24h;
        uint256 lastHourTimestamp;
        uint8 hoursRecorded;
    }

    uint24 public defaultBaseFee = 250;
    uint24 public defaultEmergencyFeeCap = 10_000; // 1% default cap for emergency fees

    mapping(uint256 => NetworkConfig) public networkConfigs;
    mapping(PoolId => uint24) public poolBaseFees;
    mapping(PoolId => uint24) public poolEmergencyFeeCap; // v4.3: Per-pool emergency fee cap
    mapping(PoolId => PoolDynamicConfig) public dynamicConfigs;
    mapping(PoolId => mapping(address => uint256)) public lastSwapTimestamp;
    mapping(PoolId => PriceSnapshot[]) public priceHistory;
    mapping(PoolId => VolumeData) public poolVolumes;
    mapping(PoolId => uint256) public lastLiteModeTracking;

    uint256 public lastGasPriceCheck;
    uint256 public currentGasPrice;

    event DefaultBaseFeeUpdated(uint24 oldFee, uint24 newFee);
    event DefaultEmergencyFeeCapUpdated(uint24 oldCap, uint24 newCap);
    event PoolBaseFeeSet(PoolId indexed poolId, uint24 baseFee);
    event PoolEmergencyFeeCapSet(PoolId indexed poolId, uint24 cap);
    event PenaltyFeeApplied(PoolId indexed poolId, address indexed user, uint24 totalFee);
    event HookFeesWithdrawn(address indexed token, address indexed to, uint256 amount);
    event NativeFeesWithdrawn(address indexed to, uint256 amount);
    event PoolDynamicConfigInitialized(PoolId indexed poolId);
    event FeeCalculated(PoolId indexed poolId, address indexed user, uint24 baseFee, uint24 finalFee, uint256 gasPrice, string gasLevel, bool penaltyApplied, string strategy);
    event EmergencyFeeActivated(PoolId indexed poolId, uint256 gasPrice, string level, uint24 appliedFee);
    event EmergencyFeeCapped(PoolId indexed poolId, uint24 calculatedFee, uint24 cappedFee);
    event CircuitBreakerTriggered(PoolId indexed poolId, uint24 attemptedFee, uint24 cappedFee);
    event NetworkConfigUpdated(uint256 indexed chainId);
    event PoolDynamicFeesPaused(PoolId indexed poolId);
    event PoolDynamicFeesUnpaused(PoolId indexed poolId);
    event PoolAntiBotPaused(PoolId indexed poolId);
    event PoolAntiBotUnpaused(PoolId indexed poolId);
    event PoolHookFeePaused(PoolId indexed poolId);
    event PoolHookFeeUnpaused(PoolId indexed poolId);
    event PoolEmergencyFeesPaused(PoolId indexed poolId);
    event PoolEmergencyFeesUnpaused(PoolId indexed poolId);

    constructor(IPoolManager _poolManager, address admin) BaseHook(_poolManager) {
        require(admin != address(0), "Invalid admin address");
        require(address(_poolManager) != address(0), "Invalid pool manager");

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(FEE_MANAGER_ROLE, admin);
        _grantRole(HOOK_FEE_MANAGER_ROLE, admin);
        _grantRole(PAUSE_MANAGER_ROLE, admin);

        _configureNetwork();
    }

    /// @notice Allows contract to receive native tokens (ETH/BNB)
    receive() external payable {}

    function _configureNetwork() internal {
        uint256 chainId = block.chainid;

        // v4.3: New multipliers aligned with max dynamic fees (vol 4x * volume 1.4x = 5.6x)
        // High: 5.6x (56000), Very High: 6.5x (65000), Extreme: 7.5x (75000)

        if (chainId == 56) {
            // BSC Mainnet
            networkConfigs[chainId] = NetworkConfig({
                normalGasThreshold: 1.5 gwei,
                highGasThreshold: 3 gwei,
                veryHighGasThreshold: 8 gwei,
                highGasMultiplier: 56000,
                veryHighGasMultiplier: 65000,
                extremeGasMultiplier: 75000,
                isConfigured: true
            });
        } else if (chainId == 42161) {
            // Arbitrum
            networkConfigs[chainId] = NetworkConfig({
                normalGasThreshold: 0.5 gwei,
                highGasThreshold: 1 gwei,
                veryHighGasThreshold: 3 gwei,
                highGasMultiplier: 56000,
                veryHighGasMultiplier: 65000,
                extremeGasMultiplier: 75000,
                isConfigured: true
            });
        } else if (chainId == 8453) {
            // Base
            networkConfigs[chainId] = NetworkConfig({
                normalGasThreshold: 0.8 gwei,
                highGasThreshold: 2 gwei,
                veryHighGasThreshold: 5 gwei,
                highGasMultiplier: 56000,
                veryHighGasMultiplier: 65000,
                extremeGasMultiplier: 75000,
                isConfigured: true
            });
        } else if (chainId == 10) {
            // Optimism
            networkConfigs[chainId] = NetworkConfig({
                normalGasThreshold: 0.3 gwei,
                highGasThreshold: 1 gwei,
                veryHighGasThreshold: 3 gwei,
                highGasMultiplier: 56000,
                veryHighGasMultiplier: 65000,
                extremeGasMultiplier: 75000,
                isConfigured: true
            });
        } else if (chainId == 137) {
            // Polygon
            networkConfigs[chainId] = NetworkConfig({
                normalGasThreshold: 50 gwei,
                highGasThreshold: 100 gwei,
                veryHighGasThreshold: 200 gwei,
                highGasMultiplier: 56000,
                veryHighGasMultiplier: 65000,
                extremeGasMultiplier: 75000,
                isConfigured: true
            });
        } else if (chainId == 1) {
            // Ethereum Mainnet
            networkConfigs[chainId] = NetworkConfig({
                normalGasThreshold: 7 gwei,
                highGasThreshold: 12 gwei,
                veryHighGasThreshold: 20 gwei,
                highGasMultiplier: 56000,
                veryHighGasMultiplier: 65000,
                extremeGasMultiplier: 75000,
                isConfigured: true
            });
        } else {
            // Default for unknown networks
            networkConfigs[chainId] = NetworkConfig({
                normalGasThreshold: 5 gwei,
                highGasThreshold: 10 gwei,
                veryHighGasThreshold: 20 gwei,
                highGasMultiplier: 56000,
                veryHighGasMultiplier: 65000,
                extremeGasMultiplier: 75000,
                isConfigured: false
            });
        }
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice Auto-initialize dynamic config when pool is created
    function _afterInitialize(address, PoolKey calldata key, uint160, int24) internal override returns (bytes4) {
        PoolId poolId = key.toId();

        dynamicConfigs[poolId] = PoolDynamicConfig({
            enabled: true,
            pausedDynamicFees: false,
            pausedAntiBot: false,
            pausedHookFee: false,
            pausedEmergencyFees: false,
            volLowThreshold: 30,
            volHighThreshold: 100,
            volExtremeThreshold: 200,
            volLowMultiplier: 8000,
            volNormalMultiplier: 10000,
            volHighMultiplier: 20000,
            volExtremeMultiplier: 40000,
            volumeVeryLowRatio: 5000,
            volumeLowRatio: 8000,
            volumeHighRatio: 15000,
            volumeVeryHighRatio: 30000,
            volumeVeryLowMultiplier: 8000,
            volumeLowMultiplier: 9000,
            volumeNormalMultiplier: 10000,
            volumeHighMultiplier: 12000,
            volumeVeryHighMultiplier: 14000
        });

        emit PoolDynamicConfigInitialized(poolId);

        return IHooks.afterInitialize.selector;
    }

    /// @notice Get the emergency fee cap for a pool
    /// @dev Returns pool-specific cap if set, otherwise default cap
    function _getEmergencyFeeCap(PoolId poolId) internal view returns (uint24) {
        uint24 poolCap = poolEmergencyFeeCap[poolId];
        return poolCap > 0 ? poolCap : defaultEmergencyFeeCap;
    }

    /// @notice Apply emergency fee cap
    /// @dev v4.3: Caps emergency fees to prevent excessive fees on high base fee pools
    function _applyEmergencyFeeCap(PoolId poolId, uint24 fee) internal returns (uint24) {
        uint24 cap = _getEmergencyFeeCap(poolId);
        if (fee > cap) {
            emit EmergencyFeeCapped(poolId, fee, cap);
            return cap;
        }
        return fee;
    }

    function _calculateFeeByGasLevel(PoolId poolId, uint24 baseFee) internal returns (uint24 finalFee, string memory gasLevel, string memory strategy) {
        NetworkConfig memory netConfig = networkConfigs[block.chainid];
        PoolDynamicConfig memory config = dynamicConfigs[poolId];

        uint256 gasPrice = tx.gasprice;

        if (block.timestamp - lastGasPriceCheck >= 60) {
            currentGasPrice = gasPrice;
            lastGasPriceCheck = block.timestamp;
        }

        bool emergencyPaused = config.pausedEmergencyFees;

        if (gasPrice <= netConfig.normalGasThreshold) {
            gasLevel = "NORMAL";

            if (config.enabled && !config.pausedDynamicFees) {
                finalFee = _calculateDynamicFee(poolId, baseFee);
                strategy = "Dynamic fees (volatility + volume)";

                VolumeData memory volumeData = poolVolumes[poolId];
                uint256 volume24h = volumeData.hourlyVolumes24h + volumeData.currentHourVolume;

                if (volume24h >= VOLUME_THRESHOLD_FOR_PRECISE_DATA) {
                    _updatePriceSnapshotIfNeeded(poolId);
                }
            } else {
                finalFee = baseFee;
                strategy = config.pausedDynamicFees ? "Base fee (dynamic paused)" : "Base fee (dynamic disabled)";
            }

            finalFee = _applyCircuitBreaker(poolId, finalFee);
            return (finalFee, gasLevel, strategy);
        }

        if (emergencyPaused) {
            gasLevel = gasPrice <= netConfig.highGasThreshold ? "HIGH" :
                       gasPrice <= netConfig.veryHighGasThreshold ? "VERY_HIGH" : "EXTREME";
            finalFee = _applyCircuitBreaker(poolId, baseFee);
            return (finalFee, gasLevel, "Base fee (emergency paused)");
        }

        // Get pool-specific or network default multipliers
        if (gasPrice <= netConfig.highGasThreshold) {
            gasLevel = "HIGH";
            strategy = "Emergency fee (high gas activity)";

            uint256 emergencyFee = (uint256(baseFee) * netConfig.highGasMultiplier) / 10000;
            finalFee = _applyEmergencyFeeCap(poolId, uint24(emergencyFee));
            finalFee = _applyCircuitBreaker(poolId, finalFee);

            emit EmergencyFeeActivated(poolId, gasPrice, gasLevel, finalFee);
            return (finalFee, gasLevel, strategy);
        }

        if (gasPrice <= netConfig.veryHighGasThreshold) {
            gasLevel = "VERY_HIGH";
            strategy = "Emergency fee (pump/dump likely)";

            uint256 emergencyFee = (uint256(baseFee) * netConfig.veryHighGasMultiplier) / 10000;
            finalFee = _applyEmergencyFeeCap(poolId, uint24(emergencyFee));
            finalFee = _applyCircuitBreaker(poolId, finalFee);

            emit EmergencyFeeActivated(poolId, gasPrice, gasLevel, finalFee);
            return (finalFee, gasLevel, strategy);
        }

        // EXTREME gas level
        gasLevel = "EXTREME";
        strategy = "Emergency fee (bot war detected)";

        uint256 emergencyFee = (uint256(baseFee) * netConfig.extremeGasMultiplier) / 10000;
        finalFee = _applyEmergencyFeeCap(poolId, uint24(emergencyFee));
        finalFee = _applyCircuitBreaker(poolId, finalFee);

        emit EmergencyFeeActivated(poolId, gasPrice, gasLevel, finalFee);
        return (finalFee, gasLevel, strategy);
    }

    function _applyCircuitBreaker(PoolId poolId, uint24 fee) internal returns (uint24) {
        if (fee > ABSOLUTE_MAX_FEE) {
            emit CircuitBreakerTriggered(poolId, fee, ABSOLUTE_MAX_FEE);
            return ABSOLUTE_MAX_FEE;
        }
        return fee;
    }

    function _calculateDynamicFee(PoolId poolId, uint24 baseFee) internal view returns (uint24) {
        PoolDynamicConfig memory config = dynamicConfigs[poolId];

        uint16 volMultiplier = _calculateVolatilityMultiplier(poolId, config);
        uint16 volumeMultiplier = _calculateVolumeMultiplier(poolId, config);

        uint256 totalMultiplier = (uint256(volMultiplier) * uint256(volumeMultiplier)) / 10000;
        uint256 finalFee = (uint256(baseFee) * totalMultiplier) / 10000;

        if (finalFee > MAX_BASE_FEE) {
            finalFee = MAX_BASE_FEE;
        }

        return uint24(finalFee);
    }

    function _calculateVolatilityMultiplier(PoolId poolId, PoolDynamicConfig memory config) internal view returns (uint16) {
        PriceSnapshot[] memory snapshots = priceHistory[poolId];
        uint160 currentPrice = _getCurrentPrice(poolId);
        uint256 volatility;

        if (snapshots.length >= 4) {
            uint256 vol15min = _calculateVolatility(currentPrice, snapshots[snapshots.length - 1].sqrtPriceX96);
            uint256 vol1h = _calculateVolatility(currentPrice, snapshots[0].sqrtPriceX96);
            volatility = (vol15min + vol1h) / 2;
        } else if (snapshots.length > 0) {
            volatility = _calculateVolatility(currentPrice, snapshots[snapshots.length - 1].sqrtPriceX96);
        } else {
            return config.volNormalMultiplier;
        }

        if (volatility < config.volLowThreshold) {
            return config.volLowMultiplier;
        } else if (volatility < config.volHighThreshold) {
            return config.volNormalMultiplier;
        } else if (volatility < config.volExtremeThreshold) {
            return config.volHighMultiplier;
        } else {
            return config.volExtremeMultiplier;
        }
    }

    function _calculateVolumeMultiplier(PoolId poolId, PoolDynamicConfig memory config) internal view returns (uint16) {
        VolumeData memory volumeData = poolVolumes[poolId];

        if (volumeData.hoursRecorded < 6) {
            return config.volumeNormalMultiplier;
        }

        uint256 avg24h = volumeData.hourlyVolumes24h / uint256(volumeData.hoursRecorded);

        if (avg24h == 0) {
            return config.volumeNormalMultiplier;
        }

        uint256 volumeRatio = (volumeData.currentHourVolume * 10000) / avg24h;

        if (volumeRatio < config.volumeVeryLowRatio) {
            return config.volumeVeryLowMultiplier;
        } else if (volumeRatio < config.volumeLowRatio) {
            return config.volumeLowMultiplier;
        } else if (volumeRatio < config.volumeHighRatio) {
            return config.volumeNormalMultiplier;
        } else if (volumeRatio < config.volumeVeryHighRatio) {
            return config.volumeHighMultiplier;
        } else {
            return config.volumeVeryHighMultiplier;
        }
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        address user = tx.origin;
        PoolId poolId = key.toId();

        uint24 baseFee = poolBaseFees[poolId];
        if (baseFee == 0) {
            baseFee = defaultBaseFee;
        }

        (uint24 finalFee, string memory gasLevel, string memory strategy) = _calculateFeeByGasLevel(poolId, baseFee);

        PoolDynamicConfig memory config = dynamicConfigs[poolId];
        bool penaltyApplied = false;

        if (!config.pausedAntiBot) {
            if (block.timestamp - lastSwapTimestamp[poolId][user] < COOLDOWN_SECONDS) {
                uint24 feeWithPenalty = finalFee + REPEAT_PENALTY_FEE;
                if (feeWithPenalty > ABSOLUTE_MAX_FEE) {
                    feeWithPenalty = ABSOLUTE_MAX_FEE;
                    emit CircuitBreakerTriggered(poolId, finalFee + REPEAT_PENALTY_FEE, ABSOLUTE_MAX_FEE);
                }
                finalFee = feeWithPenalty;
                penaltyApplied = true;
                emit PenaltyFeeApplied(poolId, user, finalFee);
            }
        }

        LPFeeLibrary.validate(finalFee);

        lastSwapTimestamp[poolId][user] = block.timestamp;

        emit FeeCalculated(poolId, user, baseFee, finalFee, tx.gasprice, gasLevel, penaltyApplied, strategy);

        uint24 overriddenFee = finalFee | LPFeeLibrary.OVERRIDE_FEE_FLAG;

        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, overriddenFee);
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata) internal override returns (bytes4, int128) {
        PoolId poolId = key.toId();
        PoolDynamicConfig memory config = dynamicConfigs[poolId];

        if (config.pausedHookFee) {
            return (BaseHook.afterSwap.selector, 0);
        }

        bool outputIsToken0 = params.zeroForOne ? false : true;
        int256 outputAmount = outputIsToken0 ? delta.amount0() : delta.amount1();

        if (outputAmount <= 0) {
            return (BaseHook.afterSwap.selector, 0);
        }

        uint256 feeAmount = (uint256(outputAmount) * HOOK_FEE_UNITS) / HOOK_FEE_DENOMINATOR;

        if (feeAmount == 0) {
            return (BaseHook.afterSwap.selector, 0);
        }

        require(feeAmount <= ((uint256(1) << 127) - 1), "fee too large");

        bool isExactIn = (params.amountSpecified < 0);
        Currency feeCurrency;

        if (isExactIn) {
            feeCurrency = outputIsToken0 ? key.currency0 : key.currency1;
        } else {
            bool inputIsToken0 = params.zeroForOne ? true : false;
            feeCurrency = inputIsToken0 ? key.currency0 : key.currency1;
        }

        NetworkConfig memory netConfig = networkConfigs[block.chainid];

        if (tx.gasprice <= netConfig.veryHighGasThreshold) {
            VolumeData memory volumeData = poolVolumes[poolId];
            uint256 volume24h = volumeData.hourlyVolumes24h + volumeData.currentHourVolume;

            if (volume24h >= VOLUME_THRESHOLD_FOR_PRECISE_DATA) {
                _updateVolumeTracking(poolId, uint256(outputAmount));
            } else {
                if (block.timestamp - lastLiteModeTracking[poolId] >= LITE_MODE_TRACKING_INTERVAL) {
                    lastLiteModeTracking[poolId] = block.timestamp;
                    _updateVolumeTracking(poolId, uint256(outputAmount));
                }
            }
        }

        poolManager.take(feeCurrency, address(this), feeAmount);

        return (BaseHook.afterSwap.selector, int128(int256(feeAmount)));
    }

    function _getCurrentPrice(PoolId poolId) internal view returns (uint160) {
        (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(poolId);
        return sqrtPriceX96;
    }

    function _calculateVolatility(uint160 currentPrice, uint160 historicPrice) internal pure returns (uint256) {
        if (historicPrice == 0) return 0;

        uint256 priceDiff = currentPrice > historicPrice ? currentPrice - historicPrice : historicPrice - currentPrice;

        return (priceDiff * 10000) / historicPrice;
    }

    function _updatePriceSnapshotIfNeeded(PoolId poolId) internal {
        PriceSnapshot[] storage snapshots = priceHistory[poolId];

        if (snapshots.length > 0) {
            if (block.timestamp - snapshots[snapshots.length - 1].timestamp < SNAPSHOT_INTERVAL) {
                return;
            }
        }

        uint160 currentPrice = _getCurrentPrice(poolId);

        if (snapshots.length >= 4) {
            for (uint i = 0; i < 3; i++) {
                snapshots[i] = snapshots[i + 1];
            }
            snapshots[3] = PriceSnapshot({sqrtPriceX96: currentPrice, timestamp: block.timestamp});
        } else {
            snapshots.push(PriceSnapshot({sqrtPriceX96: currentPrice, timestamp: block.timestamp}));
        }
    }

    function _updateVolumeTracking(PoolId poolId, uint256 swapAmount) internal {
        VolumeData storage volumeData = poolVolumes[poolId];

        if (block.timestamp - volumeData.lastHourTimestamp >= HOUR_SECONDS) {
            volumeData.hourlyVolumes24h += volumeData.currentHourVolume;
            volumeData.currentHourVolume = 0;
            volumeData.lastHourTimestamp = block.timestamp;

            if (volumeData.hoursRecorded < 24) {
                volumeData.hoursRecorded++;
            } else {
                volumeData.hourlyVolumes24h = (volumeData.hourlyVolumes24h * 23) / 24;
            }
        }

        volumeData.currentHourVolume += swapAmount;
    }

    // ============ FEE MANAGEMENT ============

    function setDefaultBaseFee(uint24 newFee) external onlyRole(FEE_MANAGER_ROLE) {
        require(newFee <= MAX_BASE_FEE, "fee too high");
        require(newFee > 0, "fee cannot be zero");
        uint24 old = defaultBaseFee;
        defaultBaseFee = newFee;
        emit DefaultBaseFeeUpdated(old, newFee);
    }

    function setPoolBaseFee(PoolKey calldata key, uint24 baseFee) external onlyRole(FEE_MANAGER_ROLE) {
        require(baseFee <= MAX_BASE_FEE, "fee too high");
        PoolId poolId = key.toId();
        poolBaseFees[poolId] = baseFee;
        emit PoolBaseFeeSet(poolId, baseFee);
    }

    function resetPoolBaseFee(PoolKey calldata key) external onlyRole(FEE_MANAGER_ROLE) {
        PoolId poolId = key.toId();
        poolBaseFees[poolId] = 0;
        emit PoolBaseFeeSet(poolId, 0);
    }

    // ============ v4.3: EMERGENCY FEE CAP MANAGEMENT ============

    /// @notice Set default emergency fee cap for all pools
    /// @param newCap New default cap in basis points (e.g., 10000 = 1%)
    function setDefaultEmergencyFeeCap(uint24 newCap) external onlyRole(FEE_MANAGER_ROLE) {
        require(newCap > 0, "cap cannot be zero");
        require(newCap <= ABSOLUTE_MAX_FEE, "cap exceeds absolute max");
        uint24 old = defaultEmergencyFeeCap;
        defaultEmergencyFeeCap = newCap;
        emit DefaultEmergencyFeeCapUpdated(old, newCap);
    }

    /// @notice Set emergency fee cap for a specific pool
    /// @param key Pool key
    /// @param cap Cap in basis points (0 = use default)
    function setPoolEmergencyFeeCap(PoolKey calldata key, uint24 cap) external onlyRole(FEE_MANAGER_ROLE) {
        require(cap <= ABSOLUTE_MAX_FEE, "cap exceeds absolute max");
        PoolId poolId = key.toId();
        poolEmergencyFeeCap[poolId] = cap;
        emit PoolEmergencyFeeCapSet(poolId, cap);
    }

    /// @notice Reset pool emergency fee cap to use default
    function resetPoolEmergencyFeeCap(PoolKey calldata key) external onlyRole(FEE_MANAGER_ROLE) {
        PoolId poolId = key.toId();
        poolEmergencyFeeCap[poolId] = 0;
        emit PoolEmergencyFeeCapSet(poolId, 0);
    }

    /// @notice Get the effective emergency fee cap for a pool
    function getPoolEmergencyFeeCap(PoolKey calldata key) external view returns (uint24) {
        PoolId poolId = key.toId();
        return _getEmergencyFeeCap(poolId);
    }

    // ============ POOL CONFIG ============

    /// @notice Manual initialization for pools created before v4.2
    function initializePoolDynamicConfig(PoolKey calldata key) external onlyRole(FEE_MANAGER_ROLE) {
        PoolId poolId = key.toId();

        dynamicConfigs[poolId] = PoolDynamicConfig({
            enabled: true,
            pausedDynamicFees: false,
            pausedAntiBot: false,
            pausedHookFee: false,
            pausedEmergencyFees: false,
            volLowThreshold: 30,
            volHighThreshold: 100,
            volExtremeThreshold: 200,
            volLowMultiplier: 8000,
            volNormalMultiplier: 10000,
            volHighMultiplier: 20000,
            volExtremeMultiplier: 40000,
            volumeVeryLowRatio: 5000,
            volumeLowRatio: 8000,
            volumeHighRatio: 15000,
            volumeVeryHighRatio: 30000,
            volumeVeryLowMultiplier: 8000,
            volumeLowMultiplier: 9000,
            volumeNormalMultiplier: 10000,
            volumeHighMultiplier: 12000,
            volumeVeryHighMultiplier: 14000
        });

        emit PoolDynamicConfigInitialized(poolId);
    }

    function setPoolDynamicFeesEnabled(PoolKey calldata key, bool enabled) external onlyRole(FEE_MANAGER_ROLE) {
        PoolId poolId = key.toId();
        dynamicConfigs[poolId].enabled = enabled;
    }

    // ============ PAUSE CONTROLS ============

    function pauseDynamicFees(PoolKey calldata key) external onlyRole(PAUSE_MANAGER_ROLE) {
        PoolId poolId = key.toId();
        dynamicConfigs[poolId].pausedDynamicFees = true;
        emit PoolDynamicFeesPaused(poolId);
    }

    function unpauseDynamicFees(PoolKey calldata key) external onlyRole(PAUSE_MANAGER_ROLE) {
        PoolId poolId = key.toId();
        dynamicConfigs[poolId].pausedDynamicFees = false;
        emit PoolDynamicFeesUnpaused(poolId);
    }

    function pauseAntiBot(PoolKey calldata key) external onlyRole(PAUSE_MANAGER_ROLE) {
        PoolId poolId = key.toId();
        dynamicConfigs[poolId].pausedAntiBot = true;
        emit PoolAntiBotPaused(poolId);
    }

    function unpauseAntiBot(PoolKey calldata key) external onlyRole(PAUSE_MANAGER_ROLE) {
        PoolId poolId = key.toId();
        dynamicConfigs[poolId].pausedAntiBot = false;
        emit PoolAntiBotUnpaused(poolId);
    }

    function pauseHookFee(PoolKey calldata key) external onlyRole(PAUSE_MANAGER_ROLE) {
        PoolId poolId = key.toId();
        dynamicConfigs[poolId].pausedHookFee = true;
        emit PoolHookFeePaused(poolId);
    }

    function unpauseHookFee(PoolKey calldata key) external onlyRole(PAUSE_MANAGER_ROLE) {
        PoolId poolId = key.toId();
        dynamicConfigs[poolId].pausedHookFee = false;
        emit PoolHookFeeUnpaused(poolId);
    }

    function pauseEmergencyFees(PoolKey calldata key) external onlyRole(PAUSE_MANAGER_ROLE) {
        PoolId poolId = key.toId();
        dynamicConfigs[poolId].pausedEmergencyFees = true;
        emit PoolEmergencyFeesPaused(poolId);
    }

    function unpauseEmergencyFees(PoolKey calldata key) external onlyRole(PAUSE_MANAGER_ROLE) {
        PoolId poolId = key.toId();
        dynamicConfigs[poolId].pausedEmergencyFees = false;
        emit PoolEmergencyFeesUnpaused(poolId);
    }

    function emergencyPauseAll(PoolKey calldata key) external onlyRole(PAUSE_MANAGER_ROLE) {
        PoolId poolId = key.toId();
        dynamicConfigs[poolId].pausedDynamicFees = true;
        dynamicConfigs[poolId].pausedAntiBot = true;
        dynamicConfigs[poolId].pausedHookFee = true;
        dynamicConfigs[poolId].pausedEmergencyFees = true;
        dynamicConfigs[poolId].enabled = false;

        emit PoolDynamicFeesPaused(poolId);
        emit PoolAntiBotPaused(poolId);
        emit PoolHookFeePaused(poolId);
        emit PoolEmergencyFeesPaused(poolId);
    }

    function unpauseAll(PoolKey calldata key) external onlyRole(PAUSE_MANAGER_ROLE) {
        PoolId poolId = key.toId();
        dynamicConfigs[poolId].pausedDynamicFees = false;
        dynamicConfigs[poolId].pausedAntiBot = false;
        dynamicConfigs[poolId].pausedHookFee = false;
        dynamicConfigs[poolId].pausedEmergencyFees = false;

        emit PoolDynamicFeesUnpaused(poolId);
        emit PoolAntiBotUnpaused(poolId);
        emit PoolHookFeeUnpaused(poolId);
        emit PoolEmergencyFeesUnpaused(poolId);
    }

    // ============ NETWORK CONFIG ============

    function setNetworkGasThresholds(uint256 normalThreshold, uint256 highThreshold, uint256 veryHighThreshold) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(normalThreshold < highThreshold, "Invalid thresholds");
        require(highThreshold < veryHighThreshold, "Invalid thresholds");

        uint256 chainId = block.chainid;
        NetworkConfig storage config = networkConfigs[chainId];

        config.normalGasThreshold = normalThreshold;
        config.highGasThreshold = highThreshold;
        config.veryHighGasThreshold = veryHighThreshold;

        emit NetworkConfigUpdated(chainId);
    }

    function setEmergencyMultipliers(uint24 highMultiplier, uint24 veryHighMultiplier, uint24 extremeMultiplier) external onlyRole(FEE_MANAGER_ROLE) {
        require(highMultiplier >= 10000, "Min 1x");
        require(veryHighMultiplier > highMultiplier, "Must be increasing");
        require(extremeMultiplier > veryHighMultiplier, "Must be increasing");
        require(extremeMultiplier <= 100000, "Max 10x");

        uint256 chainId = block.chainid;
        NetworkConfig storage config = networkConfigs[chainId];

        config.highGasMultiplier = highMultiplier;
        config.veryHighGasMultiplier = veryHighMultiplier;
        config.extremeGasMultiplier = extremeMultiplier;

        emit NetworkConfigUpdated(chainId);
    }

    // ============ WITHDRAWALS ============

    function withdrawHookFees(address token, address to, uint256 amount) external onlyRole(HOOK_FEE_MANAGER_ROLE) nonReentrant {
        require(token != address(0), "Use withdrawNative for native token");
        require(to != address(0), "Invalid recipient address");
        require(amount > 0, "Amount must be > 0");

        uint256 balance = IERC20(token).balanceOf(address(this));
        require(balance >= amount, "Insufficient balance");

        IERC20(token).safeTransfer(to, amount);
        emit HookFeesWithdrawn(token, to, amount);
    }

    function withdrawNative(address to, uint256 amount) external onlyRole(HOOK_FEE_MANAGER_ROLE) nonReentrant {
        require(to != address(0), "Invalid recipient address");
        require(amount > 0, "Amount must be > 0");
        require(address(this).balance >= amount, "Insufficient native balance");

        (bool success, ) = to.call{value: amount}("");
        require(success, "Native transfer failed");

        emit NativeFeesWithdrawn(to, amount);
    }

    // ============ VIEW FUNCTIONS ============

    function getPoolBaseFee(PoolKey calldata key) external view returns (uint24) {
        PoolId poolId = key.toId();
        uint24 fee = poolBaseFees[poolId];
        return fee == 0 ? defaultBaseFee : fee;
    }

    function previewFee(PoolKey calldata key, address user) external view returns (uint24 baseFee, uint24 finalFee, uint256 currentGas, string memory gasLevel, bool penaltyWouldApply, bool dynamicActive, string memory status) {
        PoolId poolId = key.toId();
        PoolDynamicConfig memory config = dynamicConfigs[poolId];
        NetworkConfig memory netConfig = networkConfigs[block.chainid];
        uint24 emergencyCap = _getEmergencyFeeCap(poolId);

        baseFee = poolBaseFees[poolId];
        if (baseFee == 0) {
            baseFee = defaultBaseFee;
        }

        currentGas = tx.gasprice;

        if (currentGas <= netConfig.normalGasThreshold) {
            gasLevel = "NORMAL";
            dynamicActive = config.enabled && !config.pausedDynamicFees;

            if (dynamicActive) {
                finalFee = _calculateDynamicFee(poolId, baseFee);
                status = "Dynamic fees active";
            } else {
                finalFee = baseFee;
                status = config.pausedDynamicFees ? "Dynamic fees paused" : "Dynamic fees disabled";
            }
        } else if (currentGas <= netConfig.highGasThreshold) {
            gasLevel = "HIGH";
            dynamicActive = false;

            if (config.pausedEmergencyFees) {
                finalFee = baseFee;
                status = "Emergency fees paused";
            } else {
                uint24 calcFee = uint24((uint256(baseFee) * netConfig.highGasMultiplier) / 10000);
                finalFee = calcFee > emergencyCap ? emergencyCap : calcFee;
                status = calcFee > emergencyCap ? "Emergency fee [CAPPED]" : "Emergency fee";
            }
        } else if (currentGas <= netConfig.veryHighGasThreshold) {
            gasLevel = "VERY_HIGH";
            dynamicActive = false;

            if (config.pausedEmergencyFees) {
                finalFee = baseFee;
                status = "Emergency fees paused";
            } else {
                uint24 calcFee = uint24((uint256(baseFee) * netConfig.veryHighGasMultiplier) / 10000);
                finalFee = calcFee > emergencyCap ? emergencyCap : calcFee;
                status = calcFee > emergencyCap ? "Emergency fee [CAPPED]" : "Emergency fee";
            }
        } else {
            gasLevel = "EXTREME";
            dynamicActive = false;

            if (config.pausedEmergencyFees) {
                finalFee = baseFee;
                status = "Emergency fees paused";
            } else {
                uint24 calcFee = uint24((uint256(baseFee) * netConfig.extremeGasMultiplier) / 10000);
                finalFee = calcFee > emergencyCap ? emergencyCap : calcFee;
                status = calcFee > emergencyCap ? "Emergency fee [CAPPED]" : "Emergency fee";
            }
        }

        if (finalFee > ABSOLUTE_MAX_FEE) {
            finalFee = ABSOLUTE_MAX_FEE;
            status = string(abi.encodePacked(status, " [CIRCUIT BREAKER]"));
        }

        penaltyWouldApply = !config.pausedAntiBot && (block.timestamp - lastSwapTimestamp[poolId][user] < COOLDOWN_SECONDS);

        if (penaltyWouldApply) {
            uint24 feeWithPenalty = finalFee + REPEAT_PENALTY_FEE;
            if (feeWithPenalty > ABSOLUTE_MAX_FEE) {
                finalFee = ABSOLUTE_MAX_FEE;
                status = string(abi.encodePacked(status, " + Anti-bot penalty [CAPPED]"));
            } else {
                finalFee = feeWithPenalty;
                status = string(abi.encodePacked(status, " + Anti-bot penalty"));
            }
        }

        return (baseFee, finalFee, currentGas, gasLevel, penaltyWouldApply, dynamicActive, status);
    }

    function getPoolStats(PoolKey calldata key) external view returns (uint24 baseFee, bool dynamicEnabled, uint256 volume24h, bool usingPreciseData, uint256 snapshotCount, uint256 currentGas, string memory gasLevel) {
        PoolId poolId = key.toId();
        PoolDynamicConfig memory config = dynamicConfigs[poolId];
        NetworkConfig memory netConfig = networkConfigs[block.chainid];

        baseFee = poolBaseFees[poolId];
        if (baseFee == 0) {
            baseFee = defaultBaseFee;
        }

        VolumeData memory volumeData = poolVolumes[poolId];
        volume24h = volumeData.hourlyVolumes24h + volumeData.currentHourVolume;

        usingPreciseData = volume24h >= VOLUME_THRESHOLD_FOR_PRECISE_DATA;
        snapshotCount = priceHistory[poolId].length;

        currentGas = tx.gasprice;

        if (currentGas <= netConfig.normalGasThreshold) {
            gasLevel = "NORMAL";
        } else if (currentGas <= netConfig.highGasThreshold) {
            gasLevel = "HIGH";
        } else if (currentGas <= netConfig.veryHighGasThreshold) {
            gasLevel = "VERY_HIGH";
        } else {
            gasLevel = "EXTREME";
        }

        return (baseFee, config.enabled, volume24h, usingPreciseData, snapshotCount, currentGas, gasLevel);
    }

    function getCurrentNetworkConfig() external view returns (NetworkConfig memory) {
        return networkConfigs[block.chainid];
    }

    function getSecurityLimits() external pure returns (uint24 maxBaseFee, uint24 absoluteMaxFee, uint24 penaltyFee, uint256 cooldownSeconds) {
        return (MAX_BASE_FEE, ABSOLUTE_MAX_FEE, REPEAT_PENALTY_FEE, COOLDOWN_SECONDS);
    }

    function getNativeBalance() external view returns (uint256) {
        return address(this).balance;
    }
}
