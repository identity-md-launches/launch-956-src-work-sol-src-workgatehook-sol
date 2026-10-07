# Additional WORK coverage

These tests extend the existing suite and reuse its real v4 PoolManager, upstream
test routers, and CREATE2 hook deployment. No new dependencies are required.

| File | Properties |
| --- | --- |
| `WorkInvariant.t.sol` | Fixed supply, balances and allowances match an independent three-actor transfer ledger; overdrafts and unapproved spending revert. Deterministic cases cover zero, one wei, full supply, self-transfers, maximum approvals, revocation and allowance exhaustion. |
| `WorkGateInvariant.t.sol` | All trader-paid fees and direct donations remain either redeemable hook assets or treasury receipts; token and native value are conserved; no unsettled manager debt remains; opening time stays latched; only authorized fee changes affect the schedule. |
| `WorkGateEdges.t.sol` | Partial fills charge on executed amounts; signed-maximum requests stop at price limits; zero and invalid-limit swaps roll back; all liquidity can exit before trading opens; fee claims remain redeemable after all liquidity leaves. |

Both stateful suites run **256 sequences of 64 calls per invariant** with unexpected
reverts treated as failures. Only explicitly selected handler actions are targeted.
The hook handler mixes exact-input/output swaps in both directions, swap round
trips, liquidity round trips, token/native donations, repeated permissionless
sweeps, clock advances, WORKERS failures/recovery, and valid/invalid fee updates.
Every sequence ends with a sweep asserting full payment of independently tracked
treasury entitlements. The deterministic handler lifecycle test ensures every
action and all four swap modes are exercised even outside randomized campaigns.

Fee ghosts are derived from settled trader balance changes relative to the real
PoolManager's pre-hook `Swap` event. They do not read the hook claim balances as
their accounting oracle. Fee rounding and the time ramp are checked against
interval bounds. The token ledger is seeded with the fixed initial supply and
updated only by successful transfers; no storage manipulation funds WORK actors.

The random swap amounts are bounded to keep 64-call sequences within funded
liquidity and actor balances. Separate partial-fill tests cover large and maximum
requests; the partial-fill/ramp property runs **1,000 fuzz cases**. Donations of
native currency use a contract created and self-destructed in the same transaction,
so the forced-transfer path runs under Cancun rules.

Run from the repository root with `forge build` and `forge test`. All run counts
are inline in the Solidity files and require no configuration changes. Build
artifacts may optionally be redirected with `--out test/scratch/out --cache-path
test/scratch/cache`; no delivered test imports or otherwise depends on scratch.

The fixed IMD token and WORKERS interface retain the existing local stand-ins.
Live-chain behavior of those addresses is unverified: a fork against the intended
chain, once provided, is still needed to validate those external contracts. The
PoolManager itself is real, runs locally, and does not require an RPC.
