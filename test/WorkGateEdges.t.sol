// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {HookFixture} from "./WorkGateHook.t.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

contract WorkGateEdgesTest is HookFixture {
    using StateLibrary for IPoolManager;

    function setUp() public override {
        super.setUp();
        _initialize();
        workers.configure(OPEN, 0);
    }

    function testZeroSwapCannotLatchOpeningOrCreateClaims() public {
        vm.expectRevert(IPoolManager.SwapAmountCannotBeZero.selector);
        _swap(true, 0);
        _assertUnchangedAfterRejectedSwap();
    }

    function testInvalidPriceLimitRollsBackFirstSwapOpening() public {
        vm.expectRevert(abi.encodeWithSelector(Pool.PriceLimitAlreadyExceeded.selector, PRICE, PRICE));
        router.swap(key, IPoolManager.SwapParams(true, -1 ether, PRICE), PoolSwapTest.TestSettings(false, false), "");
        _assertUnchangedAfterRejectedSwap();
        _swap(true, -1 ether);
        assertEq(hook.openedAt(), OPEN, "a reverted first swap must not prevent retry");
    }

    function _assertUnchangedAfterRejectedSwap() internal view {
        assertEq(hook.openedAt(), 0);
        assertEq(manager.balanceOf(address(hook), key.currency0.toId()), 0);
        assertEq(manager.balanceOf(address(hook), key.currency1.toId()), 0);
        (uint160 price,,,) = manager.getSlot0(key.toId());
        assertEq(price, PRICE);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzPartialFillFeesUseExecutedAmountDuringRamp(
        bool direction,
        bool exactInput,
        uint256 quantity,
        uint256 elapsed,
        uint256 standing
    ) public {
        quantity = bound(quantity, 100_000 ether, 10_000_000 ether);
        elapsed = bound(elapsed, 0, 1800);
        standing = bound(standing, 0, 1000);
        vm.prank(TREASURY);
        hook.setStandingFee(standing);
        vm.warp(OPEN + elapsed);
        uint256 fee = hook.feeNow();
        if (elapsed >= 900) {
            assertEq(fee, standing);
        } else {
            uint256 interpolated = 5000 * (900 - elapsed) + standing * elapsed;
            assertLe(fee * 900, interpolated);
            assertLt(interpolated, (fee + 1) * 900);
        }
        // A 60-tick price limit only consumes about 30,000 tokens at this liquidity.
        _checkPartialFill(direction, exactInput ? -int256(quantity) : int256(quantity));
    }

    function testMaximumExactInputStopsAtPriceLimit() public {
        _checkPartialFill(true, -type(int256).max);
    }

    function testMaximumExactOutputStopsAtPriceLimit() public {
        _checkPartialFill(false, type(int256).max);
    }

    function _checkPartialFill(bool direction, int256 amount) internal {
        uint160 limit = TickMath.getSqrtPriceAtTick(direction ? int24(-60) : int24(60));
        uint256 before0 = key.currency0.balanceOf(address(this));
        uint256 before1 = key.currency1.balanceOf(address(this));
        uint256 claims0 = manager.balanceOf(address(hook), key.currency0.toId());
        uint256 claims1 = manager.balanceOf(address(hook), key.currency1.toId());
        vm.recordLogs();
        BalanceDelta net = router.swap(
            key, IPoolManager.SwapParams(direction, amount, limit), PoolSwapTest.TestSettings(false, false), ""
        );
        BalanceDelta raw = _rawDelta();
        (uint160 price,,,) = manager.getSlot0(key.toId());
        assertEq(price, limit);
        bool exactInput = amount < 0;
        int256 rawInput = direction ? int256(raw.amount0()) : int256(raw.amount1());
        int256 rawOutput = direction ? int256(raw.amount1()) : int256(raw.amount0());
        assertLt(rawInput, 0);
        assertGt(rawOutput, 0);
        if (exactInput) assertGt(rawInput, amount, "must leave input unspent");
        else assertLt(rawOutput, amount, "must be a partial exact-output fill");
        assertEq(int256(key.currency0.balanceOf(address(this))) - int256(before0), int256(net.amount0()));
        assertEq(int256(key.currency1.balanceOf(address(this))) - int256(before1), int256(net.amount1()));
        uint256 fee0 = _checkFee(raw.amount0(), net.amount0(), exactInput);
        uint256 fee1 = _checkFee(raw.amount1(), net.amount1(), exactInput);
        assertEq(manager.balanceOf(address(hook), key.currency0.toId()) - claims0, fee0);
        assertEq(manager.balanceOf(address(hook), key.currency1.toId()) - claims1, fee1);
        hook.sweep();
        assertEq(key.currency0.balanceOf(TREASURY), fee0);
        assertEq(key.currency1.balanceOf(TREASURY), fee1);
    }

    function _checkFee(int256 gross, int256 net, bool exactInput) internal view returns (uint256 charged) {
        assertGe(gross - net, 0);
        charged = uint256(gross - net);
        if (exactInput ? gross < 0 : gross > 0) {
            assertEq(charged, 0);
        } else {
            uint256 magnitude = uint256(gross < 0 ? -gross : gross);
            uint256 numerator = magnitude * hook.feeNow();
            assertLe(charged * 10_000, numerator);
            assertLt(numerator, (charged + 1) * 10_000);
        }
    }

    function _rawDelta() internal returns (BalanceDelta delta) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(manager) && logs[i].topics.length > 0 && logs[i].topics[0] == SWAP_EVENT) {
                (int128 a0, int128 a1,,,,) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                delta = toBalanceDelta(a0, a1);
                ++count;
            }
        }
        assertEq(count, 1);
    }

    function testAllLiquidityCanExitWhileTradingClosedAndPoolCanBeReused() public {
        workers.configure(0, 0);
        liquidityRouter.modifyLiquidity(key, IPoolManager.ModifyLiquidityParams(-600, 600, -10_000_000 ether, 0), "");
        assertEq(manager.getLiquidity(key.toId()), 0);
        assertEq(hook.openedAt(), 0);
        assertFalse(hook.tradingOpen());
        assertLe(work.balanceOf(address(manager)), 1);
        assertLe(pair.balanceOf(address(manager)), 1);
        liquidityRouter.modifyLiquidity(key, IPoolManager.ModifyLiquidityParams(-600, 600, 10_000_000 ether, 0), "");
        workers.configure(OPEN, 0);
        _swap(true, -1 ether);
        assertEq(hook.openedAt(), OPEN);
    }

    function testFeeClaimsRemainRedeemableAfterAllLiquidityIsRemoved() public {
        _swap(true, -10 ether);
        _swap(false, -10 ether);
        uint256 claims0 = manager.balanceOf(address(hook), key.currency0.toId());
        uint256 claims1 = manager.balanceOf(address(hook), key.currency1.toId());
        assertGt(claims0, 0);
        assertGt(claims1, 0);
        liquidityRouter.modifyLiquidity(key, IPoolManager.ModifyLiquidityParams(-600, 600, -10_000_000 ether, 0), "");
        assertEq(manager.getLiquidity(key.toId()), 0);
        assertGe(key.currency0.balanceOf(address(manager)), claims0);
        assertGe(key.currency1.balanceOf(address(manager)), claims1);
        vm.prank(KEEPER);
        hook.sweep();
        assertEq(key.currency0.balanceOf(TREASURY), claims0);
        assertEq(key.currency1.balanceOf(TREASURY), claims1);
        assertEq(manager.balanceOf(address(hook), key.currency0.toId()), 0);
        assertEq(manager.balanceOf(address(hook), key.currency1.toId()), 0);
    }
}
