# Work / WORK

This Foundry project preserves the supplied `Work` and `WorkGateHook` contract logic. `launch.json` preserves the requested launch values and adds the required string `notes`, addressing the previous manifest validation failure.

## Build and tests

```sh
forge build
forge test
forge fmt --check
```

The compiler is pinned to Solidity **0.8.26**, with Cancun, optimizer enabled at 200 runs, `via_ir = true`, and `bytecode_hash = "none"`. All Solidity dependencies are ordinary files under `lib/`; there are no submodules, package-install steps, RPC calls, environment-variable requirements, FFI, or filesystem cheatcodes in the tests. Foundry and the pinned compiler must already be available to an offline verifier.

| Dependency | Pinned version | Location |
| --- | --- | --- |
| Uniswap v4-core | v4.0.0 | `lib/v4-core` |
| OpenZeppelin Contracts | v5.0.2 | `lib/openzeppelin-contracts` |
| forge-std | v1.9.6 | `lib/forge-std` |
| Solmate | v4-core's pinned commit `4b47a19038b798b4a33d9749d25e570443520647` | `lib/solmate` |

Full commit IDs, source URLs, downloaded archive hashes, and per-file SHA-256 hashes are in `dependencies.lock.json`. Vendored trees contain the upstream source directories, licenses, and basic package metadata; v4-core also includes `test/utils/CurrencySettler.sol` used by its test routers. Upstream automation and git metadata are excluded. Dependency source is not reformatted.

Tests deploy the actual v4.0.0 `PoolManager` and upstream liquidity/swap test routers. Each fixture really deploys the hook with CREATE2 at a mined address; it does not etch the hook or mock manager accounting. Only the fixed IMD address and WORKERS timestamp interface use local substitutes. The routers are test utilities, not production routers.

Coverage includes token supply/transfers/allowances; valid and rejected constructor/initialization inputs; callback authorization; standing-fee authorization and bounds; closed, future, reverting, short-return, gas-failing, and state-writing WORKERS responses; timestamp caching and rollback; fee boundaries; exact-input/output swaps in both directions; dust rounding; balance conservation; claim redemption; permissionless, repeated, failed, and reentrant sweeps. Fuzz cases exercise fee bounds, monotonicity, ERC-20 transfers, and actual swap accounting. Fee assertions use the real manager's pre-hook `Swap` event and compare it with settled user balances and minted claims.

## Deployment parameters

| Parameter | Value |
| --- | --- |
| Token | `Work`, name `Work`, symbol `WORK`, 18 decimals |
| Initial supply | `1_000_000_000 ether` = `10^27` base units, all minted to the token constructor's caller |
| Hook | `WorkGateHook(IPoolManager m, address t, address w)` |
| `m` | Actual PoolManager for the deployment chain; resolved from `$poolManager` |
| `t` | Newly deployed WORK token; resolved from `$token` |
| `w` | Existing WORKERS NFT: `0x363860179149628b6fd73b7e05a6cd102de3a72a` |
| Pair / IMD | `0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127` |
| Treasury / sole fee administrator | `0xc9eafe33a510a3a3d95a94c4f85adaf6a3ea12a0` |
| Pool LP fee | `12500` millionths = 1.25% |
| Tick spacing | `60` |
| Initial sqrt price X96 | `79228162514264337593543950336` = `2^96` |
| CREATE2 hook permission bits | `uint160(hookAddress) & 0x3fff == 0x20c4` |

Enabled flags are `beforeInitialize` (`0x2000`), `beforeSwap` (`0x0080`), `afterSwap` (`0x0040`), and `afterSwapReturnDelta` (`0x0004`). The constructor validates these address bits; there is no separate `getHookPermissions()` function in the supplied source. The third constructor argument is the NFT, not the treasury.

The deployer must choose the target chain and its PoolManager, confirm Cancun/transient-storage support, verify the fixed IMD and WORKERS contracts on that chain, and check WORKERS' `tradingOpenAt()` interface and authority over it. No target chain or RPC was supplied, so these external addresses have **not** been verified onchain. This is ordinary EVM bytecode, not a zkSync Era build.

Deployment sequence:

1. Verify the external contracts and treasury's ability to receive both ERC-20 currencies and native currency. Check that IMD has compatible, non-rebasing, non-fee-on-transfer ERC-20 behavior.
2. Deploy `Work` with no arguments. The launch factory receives the entire supply and is responsible for distribution and liquidity provisioning.
3. Form hook init code as `type(WorkGateHook).creationCode` followed by `abi.encode(poolManager, token, workers)`. Using the actual CREATE2 deployer, search salts until the resulting address has the required bits. The address is the low 20 bytes of `keccak256(0xff ++ deployer ++ salt ++ keccak256(initCode))`. Changing any constructor argument, deployer, salt, compiler setting, or bytecode requires recomputing the address. Tests include this calculation and an actual deployment.
4. Deploy the hook and initialize the pool atomically through the launch factory. Sort the two currencies by numerical address, use this hook, fee `12500`, tick spacing `60`, and the manifest's sqrt price. An address with no deployed hook cannot pass the enabled initialization callback. Once deployed, however, **anyone** can initialize a matching pool; the hook does not restrict the initializer or check the initial price. A non-atomic sequence risks an unwanted price being initialized first. The hook accepts only one successful initialization.
5. Supply the chosen liquidity and token distribution through the launch infrastructure. Those amounts and ranges are not specified by this assignment. The initial price is 1:1 in raw units; its human-unit interpretation depends on IMD's verified decimals and sorted token order.
6. Verify deployed source/bytecode and the final PoolKey before opening the user interface. No deployments, signatures, wallet operations, or broadcasts are performed by this project.

The supplied constructor requires WORK to differ from IMD and WORKERS to contain code. It does not otherwise validate the manager or token. Correct nonzero contract arguments are the deployer's responsibility.

## Trading and fees

WORK is a standard fixed-supply ERC-20, without minting after construction, owner, transfer tax, blocklist, pause, or upgrade functions. The gate applies to swaps through this hook's pool; ERC-20 transfers, liquidity changes, and other markets are not gated.

Before the first successful swap, the hook makes a static call to WORKERS with a 50,000 gas budget. A zero timestamp, future timestamp, call failure, or return shorter than 32 bytes keeps trading closed. At the exact nonzero opening timestamp, swaps are allowed and the hook fee is 50%. The first successful swap caches the NFT timestamp as `openedAt`. Subsequent WORKERS changes cannot close trading or restart the clock. A failed transaction rolls back that cache. View calls alone do not cache it; a first swap arriving late uses the NFT timestamp, not its own arrival time.

Fees use basis points. With `s = standingFee` and elapsed seconds `e` since the NFT opening:

```text
at opening:       5000
0 < e < 900:      s + floor((5000 - s) * (900 - e) / 900)
e >= 900:         s
```

The default standing fee is `200` (2%). At 450 seconds the default fee is 26%; at 899 seconds it is 2.05%; at 900 seconds it is 2%. `feeNow()` returns 50% while closed, but swaps still revert. Time is measured with `block.timestamp`, not block numbers.

The hook charges `floor(abs(unspecifiedCurrencyDelta) * feeBps / 10_000)` in the swap's **unspecified currency**: output for exact-input swaps, input for exact-output swaps. Thus exact-input users receive less output, and exact-output users pay extra input. Both directions are covered. This fee is in addition to the pool's 1.25% LP fee and rounds down to base units. Routers must quote and enforce slippage limits on the final amounts including hook fees. Extreme deltas remain subject to the supplied Solidity checked arithmetic; there is no alternative overflow policy.

## Administration and collection

Only the fixed treasury can call `setStandingFee(f)`, with `0 <= f <= 1000` (0–10%), emitting `StandingFee(f)`. Changes apply immediately, including changing the endpoint of an active 15-minute ramp. There is no timelock or separate admin, and no authority to change treasury, token, manager, WORKERS, pool parameters, or implementation. There is no upgrade mechanism.

Each hook fee mints a currency-denominated ERC-6909 claim to the hook inside PoolManager. Any account may call `sweep()`; the caller receives no reward. Sweep unlocks the manager, burns both currencies' claims, and sends the underlying assets directly to the fixed treasury. It then forwards any directly held IMD, WORK, and native currency to that same treasury. The hook has no payable receive function, but forced native currency can still be swept. It does not rescue arbitrary other tokens or arbitrary other manager claim IDs.

An operator or treasury keeper must monitor claim balances and pay gas to trigger sweep when useful. No autonomous scheduler is included. Empty and repeated sweeps are supported. A failed transfer reverts the whole transaction, preserving claims for retry; even failure of the final native transfer reverses earlier claim redemption. A treasury unable to receive forced native currency can therefore block all sweeps until it can receive it. Nested sweep attempts during manager redemption fail because the manager is already unlocked. Compatible pair and treasury behavior remain deployment assumptions.

WORKERS is an external trust dependency until the opening time is cached. Its timestamp must be truthful and its return data reasonably sized: the supplied static call limits execution gas but does not impose an explicit return-data-size cap. Ownership/upgrades of that separate NFT contract, if any, are outside this project's control.

Build/test results are local checks, not a security audit. The supplied contract logic is retained even where Forge lint flags generic concerns such as unchecked constructor addresses, timestamp dependence, external calls, and casts. Independent adversarial review and external-contract verification remain release responsibilities. Slither, Mythril, and a live-chain fork are not part of these tests.
