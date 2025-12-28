# BVCC Dynamic Fee Hook v4.3

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.26-blue.svg)](https://soliditylang.org/)
[![Uniswap v4](https://img.shields.io/badge/Uniswap-v4-ff007a.svg)](https://uniswap.org/)

Professional-grade Uniswap v4 hook for liquidity provider protection. Automatically increases fees during bot attacks (gas-based detection), adjusts dynamically to volatility and volume conditions, penalizes rapid-fire swaps, and caps fees with circuit breakers.

## 🚀 Deployed Networks

| Network | Hook Address | Status |
|---------|--------------|--------|
| BSC Mainnet | `0x8a36d8408F5285c3F81509947bc187b3c0eFD0C4` | ✅ Live |
| Ethereum | `0xF9CED7D0F5292aF02385410Eda5B7570b10b50c4` | ✅ Live |
| Arbitrum | `0x2097d7329389264a1542Ad50802bB0DE84a650c4` | ✅ Live |
| Base | `0x2c56c1302B6224B2bB1906c46F554622e12F10C4` | ✅ Live |

## ✨ Features

### 📊 Dynamic Fee System
When gas is normal, calculates fees based on:
- 15-minute and 1-hour volatility windows
- Current volume relative to 24h rolling average
- Multipliers combine: 0.8x to 5.6x range

### 🤖 Anti-Bot Mechanism
- **5-minute cooldown** between swaps per user
- **+2.5% penalty** for rapid-fire swaps
- Per-pool tracking with granular pause controls

### 🔒 Security Features
- **Circuit breaker**: 7.5% absolute maximum fee cap
- **Emergency fee cap**: Configurable per-pool (default 1%)
- **Role-based access control**: Separate admin, fee manager, pause manager roles
- **Reentrancy protection**: All withdrawal functions protected

## 📋 Technical Specifications

| Parameter | Value |
|-----------|-------|
| Base Fee (default) | 0.025% |
| Hook Fee | 0.01% |
| Max Base Fee | 5% |
| Absolute Max Fee | 7.5% |
| Anti-Bot Penalty | 2.5% |
| Cooldown Period | 5 minutes |
| Volume Threshold | $20,000 |


### 🛡️ Gas-Based Emergency Fees
Monitors network gas prices and automatically increases fees when bot activity spikes:

| Gas Level | Condition | Action |
|-----------|-----------|--------|
| Normal | Low gas | Dynamic fees active |  1% Max
| High | Elevated activity | 5.6x multiplier |  1% Max
| Very High | Heavy congestion | 6.5x multiplier | 1% Max
| Extreme | Bot war detected | 7.5x multiplier | 1% Max

## 🔧 Installation
```bash
# Clone the repository
git clone https://github.com/blockventurechaincapital-crypto/bvcc-dynamic-fee-hook.git
cd bvcc-dynamic-fee-hook

# Install dependencies
forge install

# Build
forge build --use 0.8.26

# Run tests
forge test --use 0.8.26
```

## 🧪 Testing
```bash
# Run all tests
forge test --use 0.8.26 -vvv

# Run specific test
forge test --match-contract BVCCDynamicFeeHookTest --use 0.8.26 -vvv

# Gas report
forge test --use 0.8.26 --gas-report
```

### Test Coverage

| Category | Tests | Status |
|----------|-------|--------|
| Deployment | 2 | ✅ |
| Fee Configuration | 4 | ✅ |
| Emergency Fee Cap | 2 | ✅ |
| Security Limits | 1 | ✅ |
| Pause Controls | 3 | ✅ |
| Swap Execution | 2 | ✅ |
| Network Config | 3 | ✅ |
| Pool Stats | 1 | ✅ |
| Preview Fee | 1 | ✅ |

## 🏗️ Architecture

### Hook Permissions
```solidity
Hooks.Permissions({
    beforeInitialize: false,
    afterInitialize: true,      // Auto-initialize dynamic config
    beforeAddLiquidity: false,
    afterAddLiquidity: false,
    beforeRemoveLiquidity: false,
    afterRemoveLiquidity: false,
    beforeSwap: true,           // Calculate and apply dynamic fees
    afterSwap: true,            // Collect hook fees, update tracking
    beforeDonate: false,
    afterDonate: false,
    beforeSwapReturnDelta: false,
    afterSwapReturnDelta: true  // Take hook fee from output
})
```

### Access Control Roles

| Role | Permissions |
|------|-------------|
| `DEFAULT_ADMIN_ROLE` | Grant/revoke roles, set gas thresholds |
| `FEE_MANAGER_ROLE` | Configure base fees, emergency caps, multipliers |
| `HOOK_FEE_MANAGER_ROLE` | Withdraw accumulated hook fees |
| `PAUSE_MANAGER_ROLE` | Pause/unpause individual features or all |

## 📖 Usage

### Deploy a Pool with BVCC Hook

1. Go to [Uniswap v4 Pool Creation](https://app.uniswap.org/positions/create)
2. Select your network and tokens
3. Enable "Custom Hook" and enter the hook address for your network
4. **Important**: Enable "Dynamic Fee" toggle
5. Set your price range and add liquidity

### Key Functions
```solidity
// Preview fee before swap
function previewFee(PoolKey key, address user) external view returns (
    uint24 baseFee,
    uint24 finalFee,
    uint256 currentGas,
    string memory gasLevel,
    bool penaltyWouldApply,
    bool dynamicActive,
    string memory status
);

// Get pool statistics
function getPoolStats(PoolKey key) external view returns (
    uint24 baseFee,
    bool dynamicEnabled,
    uint256 volume24h,
    bool usingPreciseData,
    uint256 snapshotCount,
    uint256 currentGas,
    string memory gasLevel
);

// Emergency controls
function emergencyPauseAll(PoolKey key) external;
function unpauseAll(PoolKey key) external;
```

## 🔐 Security

- **Audited**: Internal security review completed via Slither
- **Immutable limits**: Circuit breaker values are hardcoded constants
- **Multi-sig recommended**: Use multi-sig for admin roles in production
- **Tested**: Comprehensive test suite with 19 passing tests

### Known Considerations

1. Gas-based detection may have false positives during network congestion
2. Anti-bot cooldown affects legitimate high-frequency traders
3. Dynamic fees require sufficient volume history (6+ hours) for accuracy

## 📄 License

MIT License - see [LICENSE](LICENSE) for details.

## 🤝 Contributing

Contributions are welcome! Please open an issue or submit a pull request.

## 📞 Contact

- **Email**: Contact@blockventurechaincapital.com
- **Website**: [blockventurechaincapital.com](https://blockventurechaincapital.com/BVCC-hook.html)
- **GitHub**: [@blockventurechaincapital-crypto](https://github.com/blockventurechaincapital-crypto)

---

**Built by [BlockVenture Chain Capital](https://blockventurechaincapital.com)** | Part of the BVCC research stack
