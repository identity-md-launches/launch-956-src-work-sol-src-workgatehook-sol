// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {WorkGateHook} from "src/WorkGateHook.sol";
import {HookFixture} from "./WorkGateHook.t.sol";
import {WorkersStub} from "./helpers/Fixtures.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";

contract ForcedHookDonation {
    constructor(address payable recipient) payable {
        selfdestruct(recipient);
    }
}

contract WorkGateHandler is Test {
    address public constant TREASURY = 0xc9EAFE33A510a3a3d95A94c4f85AdaF6a3EA12a0;
    bytes32 internal constant SWAP_EVENT =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    address[3] public actors = [address(0xA11CE), address(0xB0B), address(0xCA401)];
    IPoolManager public immutable manager;
    WorkGateHook public immutable hook;
    WorkersStub public immutable workers;
    PoolSwapTest public immutable router;
    PoolModifyLiquidityTest public immutable liquidityRouter;
    PoolKey internal key;

    // Fees come from trader debits relative to the manager's pre-hook Swap event,
    // never from the claim balances that the conservation invariant checks.
    uint256[2] public fees;
    uint256[2] public donations;
    uint256 public nativeDonations;
    uint256 public expectedStandingFee = 200;
    uint256 public nftTimestamp;
    uint256 public nftMode;
    uint256 public latchedAt;
    uint256 public successfulSwaps;
    uint256 public closedSwaps;

    constructor(
        WorkGateHook hook_,
        WorkersStub workers_,
        PoolKey memory key_,
        PoolSwapTest router_,
        PoolModifyLiquidityTest liquidityRouter_
    ) {
        hook = hook_;
        manager = hook_.poolManager();
        workers = workers_;
        key = key_;
        router = router_;
        liquidityRouter = liquidityRouter_;
    }

    function expectedOpenAt() public view returns (uint256) {
        if (latchedAt != 0) return latchedAt;
        return nftMode == 0 && nftTimestamp <= block.timestamp ? nftTimestamp : 0;
    }

    function configureWorkers(uint256 choice, uint256 age) public {
        choice %= 7;
        nftMode = choice >= 3 ? choice - 2 : 0;
        if (choice == 0) nftTimestamp = 0;
        else if (choice == 1) nftTimestamp = block.timestamp + bound(age, 1, 900);
        else nftTimestamp = block.timestamp - bound(age, 0, 1800);
        workers.configure(nftTimestamp, nftMode);
    }

    function advanceTime(uint256 elapsed) public {
        uint256 previous = hook.feeNow();
        vm.warp(block.timestamp + bound(elapsed, 0, 300));
        // Advancing time cannot raise the fee while standingFee is unchanged.
        assertLe(hook.feeNow(), previous);
    }

    function setFee(uint256 fee) public {
        fee = bound(fee, 0, 1000);
        vm.prank(TREASURY);
        hook.setStandingFee(fee);
        expectedStandingFee = fee;
    }

    function rejectFee(uint256 actorSeed, uint256 fee, bool treasuryCaller) public {
        address caller = actors[actorSeed % 3];
        if (treasuryCaller) {
            caller = TREASURY;
            fee = bound(fee, 1001, type(uint256).max);
        }
        vm.prank(caller);
        vm.expectRevert();
        hook.setStandingFee(fee);
        assertEq(hook.standingFee(), expectedStandingFee);
    }

    function swap(uint256 actorSeed, uint256 quantity, bool zeroForOne, bool exactInput) public {
        // At depth 64 even one-sided trading stays inside the funded range.
        // The bound includes dust and one wei; larger partial fills have separate tests.
        uint256 amount = bound(quantity, 1, 100 ether);
        _swap(actors[actorSeed % 3], zeroForOne, exactInput ? -int256(amount) : int256(amount));
    }

    function roundTrip(uint256 actorSeed, uint256 quantity, bool zeroForOne) public {
        address actor = actors[actorSeed % 3];
        uint256 amount = bound(quantity, 1000, 100 ether);
        Currency input = zeroForOne ? key.currency0 : key.currency1;
        Currency output = zeroForOne ? key.currency1 : key.currency0;
        uint256 beforeInput = input.balanceOf(actor);
        uint256 beforeOutput = output.balanceOf(actor);
        BalanceDelta first = _swap(actor, zeroForOne, -int256(amount));
        if (expectedOpenAt() == 0) return; // The failed closed swap was asserted in _swap.
        int128 received = zeroForOne ? first.amount1() : first.amount0();
        assertGt(int256(received), 0);
        _swap(actor, !zeroForOne, -int256(received));
        assertLt(input.balanceOf(actor), beforeInput, "round trip created value");
        assertEq(output.balanceOf(actor), beforeOutput, "round trip must spend only received output");
    }

    function donate(uint256 actorSeed, uint256 quantity, bool currency1) public {
        uint256 index = currency1 ? 1 : 0;
        Currency currency = currency1 ? key.currency1 : key.currency0;
        uint256 amount = bound(quantity, 0, 100 ether);
        vm.prank(actors[actorSeed % 3]);
        assertTrue(IERC20(Currency.unwrap(currency)).transfer(address(hook), amount));
        donations[index] += amount;
    }

    function donateNative(uint256 quantity) public {
        uint256 amount = bound(quantity, 0, 0.01 ether);
        new ForcedHookDonation{value: amount}(payable(address(hook)));
        nativeDonations += amount;
    }

    function sweep(uint256 actorSeed) public {
        address actor = actors[actorSeed % 3];
        uint256 before0 = key.currency0.balanceOf(actor);
        uint256 before1 = key.currency1.balanceOf(actor);
        vm.prank(actor);
        hook.sweep();
        _assertFullyPaid();
        vm.prank(actor);
        hook.sweep();
        _assertFullyPaid();
        assertEq(key.currency0.balanceOf(actor), before0, "sweeper receives no fee");
        assertEq(key.currency1.balanceOf(actor), before1, "sweeper receives no fee");
    }

    function liquidityRoundTrip(uint256 actorSeed, uint256 quantity) public {
        address actor = actors[actorSeed % 3];
        int256 amount = int256(bound(quantity, 1 ether, 1000 ether));
        uint256 before0 = key.currency0.balanceOf(actor);
        uint256 before1 = key.currency1.balanceOf(actor);
        uint256 claims0 = manager.balanceOf(address(hook), key.currency0.toId());
        uint256 claims1 = manager.balanceOf(address(hook), key.currency1.toId());
        // A separate position starts and ends empty: no pre-existing LP fees to collect.
        bytes32 salt = bytes32(uint256(uint160(actor)));
        vm.startPrank(actor);
        liquidityRouter.modifyLiquidity(key, IPoolManager.ModifyLiquidityParams(-600, 600, amount, salt), "");
        liquidityRouter.modifyLiquidity(key, IPoolManager.ModifyLiquidityParams(-600, 600, -amount, salt), "");
        vm.stopPrank();
        assertLe(key.currency0.balanceOf(actor), before0);
        assertLe(key.currency1.balanceOf(actor), before1);
        assertEq(manager.balanceOf(address(hook), key.currency0.toId()), claims0);
        assertEq(manager.balanceOf(address(hook), key.currency1.toId()), claims1);
    }

    function _swap(address actor, bool direction, int256 amount) internal returns (BalanceDelta result) {
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams(
            direction, amount, direction ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
        uint256 openAt = expectedOpenAt();
        if (openAt == 0) {
            vm.prank(actor);
            vm.expectRevert(
                abi.encodeWithSelector(
                    CustomRevert.WrappedError.selector,
                    address(hook),
                    IHooks.beforeSwap.selector,
                    abi.encodeWithSelector(WorkGateHook.TradingClosed.selector),
                    abi.encodePacked(Hooks.HookCallFailed.selector)
                )
            );
            router.swap(key, params, PoolSwapTest.TestSettings(false, false), "");
            ++closedSwaps;
            return BalanceDelta.wrap(0);
        }
        uint256 before0 = key.currency0.balanceOf(actor);
        uint256 before1 = key.currency1.balanceOf(actor);
        uint256 feeBps = hook.feeNow();
        vm.recordLogs();
        vm.prank(actor);
        result = router.swap(key, params, PoolSwapTest.TestSettings(false, false), "");
        BalanceDelta gross = _grossDelta();
        int256 actual0 = int256(key.currency0.balanceOf(actor)) - int256(before0);
        int256 actual1 = int256(key.currency1.balanceOf(actor)) - int256(before1);
        assertEq(actual0, int256(result.amount0()));
        assertEq(actual1, int256(result.amount1()));
        _accountFee(0, gross.amount0(), actual0, amount < 0, feeBps);
        _accountFee(1, gross.amount1(), actual1, amount < 0, feeBps);
        if (latchedAt == 0) latchedAt = openAt;
        ++successfulSwaps;
    }

    function _accountFee(uint256 index, int256 gross, int256 net, bool exactInput, uint256 feeBps) internal {
        int256 charged = gross - net;
        assertGe(charged, 0, "hook cannot credit trader out of reserves");
        // Exact input charges the positive output; exact output charges the negative input.
        bool feeCurrency = exactInput ? gross > 0 : gross < 0;
        if (!feeCurrency) {
            assertEq(charged, 0, "specified side must not pay a hook fee");
        } else {
            uint256 magnitude = uint256(gross < 0 ? -gross : gross);
            // Bound rounding error instead of copying afterSwap's division expression.
            uint256 numerator = magnitude * feeBps;
            assertLe(uint256(charged) * 10_000, numerator);
            assertLt(numerator, (uint256(charged) + 1) * 10_000);
        }
        fees[index] += uint256(charged);
    }

    function _grossDelta() internal returns (BalanceDelta delta) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 matches;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(manager) && logs[i].topics.length > 0 && logs[i].topics[0] == SWAP_EVENT) {
                assertEq(logs[i].topics[1], PoolId.unwrap(key.toId()));
                (int128 a0, int128 a1,,,,) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                delta = toBalanceDelta(a0, a1);
                ++matches;
            }
        }
        assertEq(matches, 1, "one real pool swap must occur");
    }

    function _assertFullyPaid() internal view {
        assertEq(key.currency0.balanceOf(TREASURY), fees[0] + donations[0]);
        assertEq(key.currency1.balanceOf(TREASURY), fees[1] + donations[1]);
        assertEq(TREASURY.balance, nativeDonations);
        assertEq(manager.balanceOf(address(hook), key.currency0.toId()), 0);
        assertEq(manager.balanceOf(address(hook), key.currency1.toId()), 0);
        assertEq(key.currency0.balanceOf(address(hook)), 0);
        assertEq(key.currency1.balanceOf(address(hook)), 0);
        assertEq(address(hook).balance, 0);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract WorkGateInvariantTest is HookFixture {
    using TransientStateLibrary for IPoolManager;
    using StateLibrary for IPoolManager;
    WorkGateHandler internal handler;

    function setUp() public override {
        super.setUp();
        _initialize();
        handler = new WorkGateHandler(hook, workers, key, router, liquidityRouter);
        vm.deal(address(handler), 100 ether);
        assertEq(TREASURY.balance, 0);
        for (uint256 i; i < 3; ++i) {
            address actor = handler.actors(i);
            work.transfer(actor, 1_000_000 ether);
            pair.transfer(actor, 1_000_000 ether);
            vm.startPrank(actor);
            work.approve(address(router), type(uint256).max);
            pair.approve(address(router), type(uint256).max);
            work.approve(address(liquidityRouter), type(uint256).max);
            pair.approve(address(liquidityRouter), type(uint256).max);
            vm.stopPrank();
        }
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = handler.swap.selector;
        selectors[1] = handler.roundTrip.selector;
        selectors[2] = handler.donate.selector;
        selectors[3] = handler.donateNative.selector;
        selectors[4] = handler.sweep.selector;
        selectors[5] = handler.advanceTime.selector;
        selectors[6] = handler.configureWorkers.selector;
        selectors[7] = handler.setFee.selector;
        selectors[8] = handler.rejectFee.selector;
        selectors[9] = handler.liquidityRoundTrip.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariantFeesRemainBackedAndAllValueIsConserved() public view {
        for (uint256 i; i < 2; ++i) {
            Currency currency = i == 0 ? key.currency0 : key.currency1;
            uint256 claims = manager.balanceOf(address(hook), currency.toId());
            assertEq(
                claims + currency.balanceOf(address(hook)) + currency.balanceOf(TREASURY),
                handler.fees(i) + handler.donations(i),
                "treasury entitlement must equal collected fees plus donations"
            );
            assertLe(claims, currency.balanceOf(address(manager)), "claims must be redeemable");
            uint256 sum = currency.balanceOf(address(this)) + currency.balanceOf(address(manager))
                + currency.balanceOf(address(hook)) + currency.balanceOf(TREASURY);
            for (uint256 j; j < 3; ++j) {
                sum += currency.balanceOf(handler.actors(j));
            }
            assertEq(sum, 1_000_000_000 ether, "ERC20 supply must stay in the tracked holders");
            assertEq(IERC20(Currency.unwrap(currency)).totalSupply(), 1_000_000_000 ether);
            assertEq(currency.balanceOf(address(router)), 0);
            assertEq(currency.balanceOf(address(liquidityRouter)), 0);
            assertEq(manager.currencyDelta(address(hook), currency), 0);
        }
        assertEq(address(hook).balance + TREASURY.balance, handler.nativeDonations());
        assertEq(address(handler).balance + address(hook).balance + TREASURY.balance, 100 ether);
        assertFalse(manager.isUnlocked());
        assertEq(manager.getNonzeroDeltaCount(), 0);
    }

    function invariantGateAndFeeFollowNftTimeAndAuthorizedUpdates() public view {
        assertTrue(hook.initialized());
        assertEq(hook.openedAt(), handler.latchedAt());
        uint256 openAt = handler.expectedOpenAt();
        assertEq(hook.tradingOpenAt(), openAt);
        assertEq(hook.tradingOpen(), openAt != 0);
        uint256 standing = handler.expectedStandingFee();
        assertEq(hook.standingFee(), standing);
        assertLe(standing, 1000);
        uint256 fee = hook.feeNow();
        if (openAt == 0) {
            assertEq(fee, 5000);
        } else {
            uint256 elapsed = block.timestamp - openAt;
            if (elapsed >= 900) {
                assertEq(fee, standing);
            } else {
                // Linear interpolation of the specification's endpoints, within one basis point.
                uint256 numerator = 5000 * (900 - elapsed) + standing * elapsed;
                assertLe(fee * 900, numerator);
                assertLt(numerator, (fee + 1) * 900);
            }
        }
        assertEq(manager.getLiquidity(key.toId()), 10_000_000 ether);
    }

    function afterInvariant() public {
        // Liveness: every sequence, including one with no random sweep, can pay in full.
        handler.sweep(0);
        invariantFeesRemainBackedAndAllValueIsConserved();
        invariantGateAndFeeFollowNftTimeAndAuthorizedUpdates();
    }

    function testHandlerLifecycleExercisesAllSwapModesAndBothTreasuryCurrencies() public {
        handler.swap(0, 1 ether, true, true); // Closed, with an asserted callback error.
        handler.configureWorkers(2, 0);
        handler.swap(0, 10 ether, true, true);
        handler.swap(1, 10 ether, false, true);
        handler.swap(2, 10 ether, true, false);
        handler.swap(0, 10 ether, false, false);
        handler.configureWorkers(3, 0); // Dependency outage after the time was latched.
        handler.roundTrip(1, 1 ether, true);
        handler.liquidityRoundTrip(2, 10 ether);
        handler.donate(0, 1 ether, false);
        handler.donate(1, 1 ether, true);
        handler.donateNative(0.01 ether);
        handler.rejectFee(2, 1001, true);
        handler.rejectFee(0, 200, false);
        handler.setFee(1000);
        handler.advanceTime(300);
        handler.advanceTime(300);
        handler.advanceTime(300);
        handler.swap(2, 1 ether, true, false);
        assertGt(handler.fees(0), 0);
        assertGt(handler.fees(1), 0);
        assertEq(handler.closedSwaps(), 1);
        assertEq(handler.successfulSwaps(), 7);
        invariantFeesRemainBackedAndAllValueIsConserved();
        invariantGateAndFeeFollowNftTimeAndAuthorizedUpdates();
        afterInvariant();
    }
}
