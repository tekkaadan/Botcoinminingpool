# BOTCOIN Mining Pool

A Solidity mining pool contract for [BOTCOIN](https://agentmoney.net) on Base. Depositors pool BOTCOIN to reach higher credit tiers, an operator runs inference to solve challenges, and rewards are distributed pro-rata.

## Architecture

```
Depositors ──deposit()──→ Pool Contract ◄──currentEpoch()──► Mining Contract
                              │                                    ▲
                              │ isValidSignature() ◄── Coordinator │
                              │                                    │
                  Operator ───┤ submitReceiptToMining() ───────────┤
                              │ claimEpochReward() ────────────────┘
                              │
              Depositors ─────┤ claimRewardShare()
                              └ withdraw()
```

**Epoch tracking** is delegated to the upstream mining contract via `IBotcoinMining`. The pool never maintains its own epoch clock.

**Rewards** are claimed per-epoch (no multi-epoch even-split approximation). Each epoch's reward is exactly the BOTCOIN received from the mining contract minus operator fee.

**Claim window** enforces token expiry — depositors must claim within `claimWindow` seconds after epoch end, or rewards are swept.

## Key Features

| Feature | Details |
|---------|---------|
| EIP-1271 | Operator signs, pool validates via `isValidSignature()` |
| Epoch delegation | Reads `currentEpoch()` + `getEpochEndTime()` from mining contract |
| Tier aggregation | Pooled deposits determine credit tier (25M/50M/100M) |
| Single-epoch claims | Proportional by design — no even-split hack |
| Grace period | Operator claims immediately; anyone after grace period |
| Claim window | Depositor rewards expire if unclaimed |
| Selector validation | Only whitelisted function selector can be forwarded |

## Quick Start

```bash
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Clone and install deps
git clone <repo>
cd botcoin-mining-pool
forge install OpenZeppelin/openzeppelin-contracts
forge install foundry-rs/forge-std

# Run tests
forge test -vvv

# Run fuzz tests with more iterations
forge test --fuzz-runs 10000 -vvv
```

## Test Suite

36 tests covering:

- **Epoch delegation**: `currentEpoch()` and `epochEndTime()` read from mining contract
- **Deposit lifecycle**: basic, multi-depositor, additive, future epoch, reverts
- **Withdrawal**: after epoch end, reverts during active, double-withdraw, no deposit
- **Tier thresholds**: 0/1/2/3, aggregate deposits
- **EIP-1271**: valid operator sig, invalid signer, wrong length, empty
- **Receipt submission**: operator-only, forward to mining, revert on failure
- **Reward claims**: operator immediate, anyone after grace, invalid selector, calldata too short, before epoch ends, double claim, after window
- **Pro-rata distribution**: 60/40 split, batch claims, preview
- **Claim window**: open/closed, sweep expired, revert before expiry
- **Operator management**: two-step transfer, fee update, fee cap, fee withdrawal
- **Admin**: claim window update, grace period update
- **Full lifecycle**: deposit → mine → claim → distribute → withdraw
- **Fuzz**: deposit/withdraw roundtrip, reward distribution sum invariant, tier thresholds

## Operator Client

The TypeScript client in `client/` drives the mining loop against the real coordinator:

```typescript
import { PoolOperatorClient } from './pool-operator-client';

const client = new PoolOperatorClient({
  bankrApiKey: process.env.BANKR_API_KEY!,
  poolContractAddress: '0xYOUR_POOL_CONTRACT',
  solveFn: async (challenge) => {
    // Your LLM solve logic here
    return artifactString;
  },
});

await client.initialize();
await client.runMiningLoop();
```

## Contracts

| Contract | Description |
|----------|-------------|
| `src/BotcoinMiningPool.sol` | Main pool contract |
| `src/interfaces/IBotcoinMining.sol` | Mining contract interface |

## Addresses (Base Mainnet)

| Contract | Address |
|----------|---------|
| BOTCOIN Token | `0xA601877977340862Ca67f816eb079958E5bd0BA3` |
| Mining Contract | `0xd572e61e1b627d4105832c815ccd722b5bad9233` |
| Coordinator API | `https://coordinator.agentmoney.net` |

## IBotcoinMining Interface

The pool reads epoch data from the mining contract. If the deployed mining contract uses different function names, update `IBotcoinMining.sol` to match:

```solidity
interface IBotcoinMining {
    function currentEpoch() external view returns (uint256);
    function getEpochEndTime(uint256 epochId) external view returns (uint256);
    function minerEpochCredits(address miner, uint256 epochId) external view returns (uint256);
    function totalEpochCredits(uint256 epochId) external view returns (uint256);
}
```

If the mining contract's view function names differ (e.g., `epoch()` instead of `currentEpoch()`), deploy a thin adapter contract that implements `IBotcoinMining` and delegates to the real contract.

## License

MIT
