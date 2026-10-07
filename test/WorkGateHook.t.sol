// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Work} from "../src/Work.sol";
import {WorkGateHook} from "../src/WorkGateHook.sol";
import {WorkersStub, PairStub, RejectNative} from "./helpers/Fixtures.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";

abstract contract HookFixture is Test {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    address internal constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address internal constant TREASURY = 0xc9EAFE33A510a3a3d95A94c4f85AdaF6a3EA12a0;
    address internal constant KEEPER = address(0xBEEF);
    uint160 internal constant FLAGS = 0x20C4;
    uint160 internal constant PRICE = 79228162514264337593543950336;
    uint256 internal constant OPEN = 100_000;
    bytes32 internal constant SWAP_EVENT =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");

    IPoolManager internal manager;
    Work internal work;
    WorkersStub internal workers;
    PairStub internal pair;
    WorkGateHook internal hook;
    PoolKey internal key;
    PoolSwapTest internal router;
    PoolModifyLiquidityTest internal liquidityRouter;

    function setUp() public virtual {
        vm.warp(OPEN);
        manager = IPoolManager(address(new PoolManager(address(this))));
        work = new Work();
        workers = new WorkersStub();
        PairStub implementation = new PairStub();
        // Only the fixed external pair is etched; the hook is actually constructed with CREATE2.
        vm.etch(IMD, address(implementation).code);
        pair = PairStub(IMD);
        pair.mint(address(this), 1_000_000_000 ether);
        (bytes32 salt, address predicted) = _mine(address(work), address(workers));
        hook = new WorkGateHook{salt: salt}(manager, address(work), address(workers));
        assertEq(address(hook), predicted);
        key = _key(address(work), IMD, address(hook));
        router = new PoolSwapTest(manager);
        liquidityRouter = new PoolModifyLiquidityTest(manager);
        work.approve(address(router), 100_000_000 ether);
        pair.approve(address(router), 100_000_000 ether);
        work.approve(address(liquidityRouter), 100_000_000 ether);
        pair.approve(address(liquidityRouter), 100_000_000 ether);
    }

    function _key(address a, address b, address h) internal pure returns (PoolKey memory) {
        return PoolKey(Currency.wrap(a < b ? a : b), Currency.wrap(a < b ? b : a), 12500, 60, IHooks(h));
    }

    function _mine(address t, address w) internal view returns (bytes32 salt, address predicted) {
        bytes32 initHash = keccak256(abi.encodePacked(type(WorkGateHook).creationCode, abi.encode(manager, t, w)));
        for (uint256 i; i < 1_000_000; ++i) {
            predicted = _predict(bytes32(i), initHash);
            if (uint160(predicted) & Hooks.ALL_HOOK_MASK == FLAGS) return (bytes32(i), predicted);
        }
        revert("CREATE2 search exhausted");
    }

    function _predict(bytes32 salt, bytes32 initHash) internal view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initHash)))));
    }

    function _initialize() internal {
        manager.initialize(key, PRICE);
        liquidityRouter.modifyLiquidity(key, IPoolManager.ModifyLiquidityParams(-600, 600, 10_000_000 ether, 0), "");
    }

    function _params(bool zeroForOne, int256 amount) internal pure returns (IPoolManager.SwapParams memory) {
        return IPoolManager.SwapParams(
            zeroForOne, amount, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
    }

    function _swap(bool zeroForOne, int256 amount) internal returns (BalanceDelta) {
        return router.swap(key, _params(zeroForOne, amount), PoolSwapTest.TestSettings(false, false), "");
    }

    function _hookFailure(bytes4 selector, bytes memory reason) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            selector,
            reason,
            abi.encodePacked(Hooks.HookCallFailed.selector)
        );
    }

    function _expectClosedSwap() internal {
        vm.expectRevert(
            _hookFailure(IHooks.beforeSwap.selector, abi.encodeWithSelector(WorkGateHook.TradingClosed.selector))
        );
        _swap(true, -1 ether);
        assertEq(hook.openedAt(), 0);
        assertEq(manager.balanceOf(address(hook), key.currency0.toId()), 0);
        assertEq(manager.balanceOf(address(hook), key.currency1.toId()), 0);
    }
}

contract HookConfigurationTest is HookFixture {
    using StateLibrary for IPoolManager;

    event StandingFee(uint256 fee);

    function testCreate2PermissionsAndConfiguration() public view {
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, FLAGS);
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(hook.token(), address(work));
        assertEq(hook.workers(), address(workers));
        assertEq(hook.B(), TREASURY);
        assertEq(hook.IMD(), IMD);
        assertEq(hook.standingFee(), 200);
        assertFalse(hook.initialized());
    }

    function testRejectsWrongCreate2Flags() public {
        bytes32 initHash = keccak256(
            abi.encodePacked(type(WorkGateHook).creationCode, abi.encode(manager, address(work), address(workers)))
        );
        bytes32 salt;
        address predicted = _predict(salt, initHash);
        if (uint160(predicted) & Hooks.ALL_HOOK_MASK == FLAGS) {
            salt = bytes32(uint256(1));
            predicted = _predict(salt, initHash);
        }
        assertTrue(uint160(predicted) & Hooks.ALL_HOOK_MASK != FLAGS);
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
        new WorkGateHook{salt: salt}(manager, address(work), address(workers));
    }

    function testConstructorRejectsPairAsToken() public {
        vm.expectRevert();
        new WorkGateHook(manager, IMD, address(workers));
    }

    function testConstructorRejectsWorkersWithoutCode() public {
        vm.expectRevert();
        new WorkGateHook(manager, address(work), address(0x1234));
    }

    function testInitializeThroughRealPoolManagerOnlyOnce() public {
        vm.prank(KEEPER); // Initialization itself is permissionless.
        assertEq(manager.initialize(key, PRICE), 0);
        assertTrue(hook.initialized());
        (uint160 price, int24 tick,, uint24 fee) = manager.getSlot0(key.toId());
        assertEq(price, PRICE);
        assertEq(tick, 0);
        assertEq(fee, 12500);
        vm.expectRevert(_hookFailure(IHooks.beforeInitialize.selector, ""));
        manager.initialize(key, PRICE);
    }

    function testCannotInitializePredictedHookBeforeDeployment() public {
        Work other = new Work();
        (bytes32 salt, address predicted) = _mine(address(other), address(workers));
        PoolKey memory futureKey = _key(address(other), IMD, predicted);
        assertEq(predicted.code.length, 0);
        vm.expectRevert(Hooks.InvalidHookResponse.selector);
        manager.initialize(futureKey, PRICE);
        WorkGateHook deployed = new WorkGateHook{salt: salt}(manager, address(other), address(workers));
        assertEq(address(deployed), predicted);
        manager.initialize(futureKey, PRICE);
        assertTrue(deployed.initialized());
    }

    function testInitializerCanChoosePriceSoFactoryMustInitializeAtomically() public {
        uint160 otherPrice = TickMath.getSqrtPriceAtTick(60);
        vm.prank(KEEPER);
        manager.initialize(key, otherPrice);
        (uint160 price,,,) = manager.getSlot0(key.toId());
        assertEq(price, otherPrice);
        vm.expectRevert(_hookFailure(IHooks.beforeInitialize.selector, ""));
        manager.initialize(key, PRICE);
    }

    function testInitializationAcceptsEitherTokenOrdering() public {
        // Fresh hooks with actual WORK deployments on both sides of the fixed IMD address.
        bool seenLower;
        bool seenHigher;
        for (uint256 i; i < 64 && !(seenLower && seenHigher); ++i) {
            Work other = new Work();
            bool lower = address(other) < IMD;
            if ((lower && seenLower) || (!lower && seenHigher)) continue;
            (bytes32 salt,) = _mine(address(other), address(workers));
            WorkGateHook h = new WorkGateHook{salt: salt}(manager, address(other), address(workers));
            manager.initialize(_key(address(other), IMD, address(h)), PRICE);
            assertTrue(h.initialized());
            if (lower) seenLower = true;
            else seenHigher = true;
        }
        assertTrue(seenLower && seenHigher);
    }

    function testRejectsWrongPair() public {
        PoolKey memory bad = _key(address(work), address(0x1234), address(hook));
        _rejectInitialization(bad);
    }

    function testRejectsWrongToken() public {
        _rejectInitialization(_key(address(0x1234), IMD, address(hook)));
    }

    function testRejectsWrongFeeAndDynamicFee() public {
        PoolKey memory bad = key;
        bad.fee = 3000;
        _rejectInitialization(bad);
        bad.fee = 0;
        _rejectInitialization(bad);
        bad.fee = 0x800000;
        _rejectInitialization(bad);
    }

    function testRejectsWrongTickSpacing() public {
        PoolKey memory bad = key;
        bad.tickSpacing = 10;
        _rejectInitialization(bad);
    }

    function testRejectsMismatchedHookKey() public {
        PoolKey memory bad = key;
        bad.hooks = IHooks(address(0));
        vm.prank(address(manager));
        vm.expectRevert();
        hook.beforeInitialize(address(this), bad, PRICE);
        assertFalse(hook.initialized());
    }

    function _rejectInitialization(PoolKey memory bad) internal {
        vm.expectRevert(_hookFailure(IHooks.beforeInitialize.selector, ""));
        manager.initialize(bad, PRICE);
        assertFalse(hook.initialized());
        assertEq(hook.openedAt(), 0);
    }

    function testAllCallbacksRejectUnauthorizedCaller() public {
        vm.startPrank(KEEPER);
        vm.expectRevert();
        hook.beforeInitialize(KEEPER, key, PRICE);
        vm.expectRevert();
        hook.beforeSwap(KEEPER, key, _params(true, -1 ether), "");
        vm.expectRevert();
        hook.afterSwap(KEEPER, key, _params(true, -1 ether), BalanceDelta.wrap(0), "");
        vm.expectRevert();
        hook.unlockCallback("");
        vm.stopPrank();
        assertFalse(hook.initialized());
        assertEq(hook.openedAt(), 0);
    }

    function testOnlyTreasuryMaySetFee() public {
        vm.prank(KEEPER);
        vm.expectRevert();
        hook.setStandingFee(300);
        vm.expectRevert();
        hook.setStandingFee(300); // Deployer has no special role.
        assertEq(hook.standingFee(), 200);
    }

    function testFuzzTreasuryFeeBoundsAndEvent(uint256 fee) public {
        fee = bound(fee, 0, 1000);
        vm.expectEmit(false, false, false, true, address(hook));
        emit StandingFee(fee);
        vm.prank(TREASURY);
        hook.setStandingFee(fee);
        assertEq(hook.standingFee(), fee);
    }

    function testRejectsFeeAboveTenPercent() public {
        vm.startPrank(TREASURY);
        vm.expectRevert();
        hook.setStandingFee(1001);
        vm.expectRevert();
        hook.setStandingFee(type(uint256).max);
        vm.stopPrank();
        assertEq(hook.standingFee(), 200);
    }
}

contract HookGateTest is HookFixture {
    using StateLibrary for IPoolManager;

    function testClosedAndFutureTimestampRejectSwaps() public {
        _initialize(); // Liquidity is allowed before trading opens.
        assertFalse(hook.tradingOpen());
        assertEq(hook.feeNow(), 5000);
        _expectClosedSwap();
        workers.configure(OPEN + 1, 0);
        assertEq(hook.tradingOpenAt(), 0);
        _expectClosedSwap();
        vm.warp(OPEN + 1);
        _swap(true, -1 ether);
        assertEq(hook.openedAt(), OPEN + 1);
        assertEq(hook.feeNow(), 5000);
    }

    function testWorkersFailureModesFailClosed() public {
        _initialize();
        for (uint256 mode = 1; mode <= 4; ++mode) {
            workers.configure(OPEN, mode);
            assertEq(hook.tradingOpenAt(), 0);
            assertFalse(hook.tradingOpen());
            _expectClosedSwap();
        }
        workers.configure(OPEN, 0);
        _swap(true, -1 ether);
        assertEq(hook.openedAt(), OPEN);
    }

    function testFeeScheduleBoundaries() public {
        workers.configure(OPEN, 0);
        assertEq(hook.feeNow(), 5000);
        vm.warp(OPEN + 1);
        assertEq(hook.feeNow(), 4994);
        vm.warp(OPEN + 450);
        assertEq(hook.feeNow(), 2600);
        vm.warp(OPEN + 899);
        assertEq(hook.feeNow(), 205);
        vm.warp(OPEN + 900);
        assertEq(hook.feeNow(), 200);
        vm.warp(OPEN + 90 days);
        assertEq(hook.feeNow(), 200);
    }

    function testStandingFeeUpdatesAlsoChangeActiveRamp() public {
        workers.configure(OPEN, 0);
        vm.warp(OPEN + 450);
        vm.prank(TREASURY);
        hook.setStandingFee(1000);
        assertEq(hook.feeNow(), 3000);
        vm.prank(TREASURY);
        hook.setStandingFee(0);
        assertEq(hook.feeNow(), 2500);
        vm.warp(OPEN + 900);
        assertEq(hook.feeNow(), 0);
    }

    function testFuzzFeeIsMonotoneAndBounded(uint256 standing, uint256 elapsed) public {
        standing = bound(standing, 0, 1000);
        elapsed = bound(elapsed, 0, 1800);
        workers.configure(OPEN, 0);
        vm.prank(TREASURY);
        hook.setStandingFee(standing);
        vm.warp(OPEN + elapsed);
        uint256 fee = hook.feeNow();
        assertGe(fee, standing);
        assertLe(fee, 5000);
        vm.warp(OPEN + elapsed + 1);
        assertLe(hook.feeNow(), fee);
        if (elapsed >= 900) assertEq(fee, standing);
    }

    function testViewsDoNotLatchButFirstSuccessfulSwapDoes() public {
        _initialize();
        workers.configure(OPEN, 0);
        assertTrue(hook.tradingOpen());
        assertEq(hook.openedAt(), 0);
        workers.configure(0, 0);
        assertFalse(hook.tradingOpen());
        workers.configure(OPEN, 0);
        _swap(true, -1 ether);
        assertEq(hook.openedAt(), OPEN);
        workers.configure(OPEN + 1000, 1);
        vm.warp(OPEN + 900);
        assertTrue(hook.tradingOpen());
        assertEq(hook.tradingOpenAt(), OPEN);
        assertEq(hook.feeNow(), 200);
        _swap(false, -1 ether);
    }

    function testLateFirstSwapUsesNftTimeInsteadOfFirstSwapTime() public {
        _initialize();
        workers.configure(OPEN, 0);
        vm.warp(OPEN + 1000);
        _swap(true, -1 ether);
        assertEq(hook.openedAt(), OPEN);
        assertEq(hook.feeNow(), 200);
    }

    function testSettlementFailureRollsBackLatchClaimsAndPool() public {
        _initialize();
        workers.configure(OPEN, 0);
        work.approve(address(router), 0);
        (uint160 priceBefore,,,) = manager.getSlot0(key.toId());
        bool workIs0 = Currency.unwrap(key.currency0) == address(work);
        vm.expectRevert();
        _swap(workIs0, -1 ether);
        assertEq(hook.openedAt(), 0);
        assertEq(manager.balanceOf(address(hook), key.currency0.toId()), 0);
        assertEq(manager.balanceOf(address(hook), key.currency1.toId()), 0);
        (uint160 priceAfter,,,) = manager.getSlot0(key.toId());
        assertEq(priceAfter, priceBefore);
    }
}

contract HookAccountingTest is HookFixture {
    using TransientStateLibrary for IPoolManager;

    struct Balances {
        uint256 user0;
        uint256 user1;
        uint256 manager0;
        uint256 manager1;
        uint256 claims0;
        uint256 claims1;
    }

    function setUp() public override {
        super.setUp();
        _initialize();
        workers.configure(OPEN, 0);
        vm.warp(OPEN + 900);
    }

    function testExactInputBothDirectionsAtStandingFee() public {
        _checkSwap(true, -10 ether, 200);
        _checkSwap(false, -10 ether, 200);
    }

    function testExactOutputBothDirectionsAtStandingFee() public {
        _checkSwap(true, 10 ether, 200);
        _checkSwap(false, 10 ether, 200);
    }

    function testAllSwapModesAtFiftyPercent() public {
        vm.warp(OPEN);
        _checkSwap(true, -10 ether, 5000);
        _checkSwap(false, -10 ether, 5000);
        _checkSwap(true, 10 ether, 5000);
        _checkSwap(false, 10 ether, 5000);
    }

    function testAllSwapModesHalfwayThroughRamp() public {
        vm.warp(OPEN + 450);
        _checkSwap(true, -10 ether, 2600);
        _checkSwap(false, -10 ether, 2600);
        _checkSwap(true, 10 ether, 2600);
        _checkSwap(false, 10 ether, 2600);
    }

    function testZeroStandingFeeAndDustDoNotMintClaims() public {
        vm.prank(TREASURY);
        hook.setStandingFee(0);
        _checkSwap(true, -10 ether, 0);
        _checkSwap(false, 10 ether, 0);
        vm.prank(TREASURY);
        hook.setStandingFee(200);
        _checkSwap(true, -10, 200);
        _checkSwap(false, 1, 200);
        assertEq(manager.balanceOf(address(hook), key.currency0.toId()), 0);
        assertEq(manager.balanceOf(address(hook), key.currency1.toId()), 0);
    }

    function testFuzzActualSwapAccounting(bool direction, bool exactInput, uint96 quantity, uint16 fee) public {
        uint256 amount = bound(uint256(quantity), 1000, 1000 ether);
        uint256 standing = bound(uint256(fee), 0, 1000);
        vm.prank(TREASURY);
        hook.setStandingFee(standing);
        _checkSwap(direction, exactInput ? -int256(amount) : int256(amount), standing);
    }

    function _checkSwap(bool direction, int256 amount, uint256 feeBps) internal {
        Balances memory before = _balances();
        vm.recordLogs();
        BalanceDelta result = _swap(direction, amount);
        BalanceDelta raw = _rawSwapDelta();
        // The PoolManager event reports the swap BEFORE the hook's fee adjustment.
        bool feeIn1 = (amount < 0) == direction;
        int256 rawUnspecified = feeIn1 ? int256(raw.amount1()) : int256(raw.amount0());
        uint256 magnitude = uint256(rawUnspecified < 0 ? -rawUnspecified : rawUnspecified);
        uint256 fee = magnitude * feeBps / 10_000;
        assertEq(int256(result.amount0()), int256(raw.amount0()) - (feeIn1 ? int256(0) : int256(fee)));
        assertEq(int256(result.amount1()), int256(raw.amount1()) - (feeIn1 ? int256(fee) : int256(0)));
        Balances memory after_ = _balances();
        assertEq(after_.claims0 - before.claims0, feeIn1 ? 0 : fee);
        assertEq(after_.claims1 - before.claims1, feeIn1 ? fee : 0);
        assertEq(int256(after_.user0) - int256(before.user0), int256(result.amount0()));
        assertEq(int256(after_.user1) - int256(before.user1), int256(result.amount1()));
        assertEq(after_.user0 + after_.manager0, before.user0 + before.manager0);
        assertEq(after_.user1 + after_.manager1, before.user1 + before.manager1);
        assertEq(manager.currencyDelta(address(hook), key.currency0), 0);
        assertEq(manager.currencyDelta(address(hook), key.currency1), 0);
        assertEq(manager.currencyDelta(address(router), key.currency0), 0);
        assertEq(manager.currencyDelta(address(router), key.currency1), 0);
        assertEq(feeIn1 ? int256(raw.amount0()) : int256(raw.amount1()), amount);
    }

    function _balances() internal view returns (Balances memory b) {
        b.user0 = key.currency0.balanceOf(address(this));
        b.user1 = key.currency1.balanceOf(address(this));
        b.manager0 = key.currency0.balanceOf(address(manager));
        b.manager1 = key.currency1.balanceOf(address(manager));
        b.claims0 = manager.balanceOf(address(hook), key.currency0.toId());
        b.claims1 = manager.balanceOf(address(hook), key.currency1.toId());
    }

    function _rawSwapDelta() internal returns (BalanceDelta) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == SWAP_EVENT) {
                (int128 raw0, int128 raw1,,,,) =
                    abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                return toBalanceDelta(raw0, raw1);
            }
        }
        revert("PoolManager must emit the underlying swap");
    }

    function testPermissionlessSweepPaysBothCurrenciesAndDirectDonations() public {
        _swap(true, -10 ether);
        _swap(false, -10 ether);
        uint256 workClaims = manager.balanceOf(address(hook), uint160(address(work)));
        uint256 imdClaims = manager.balanceOf(address(hook), uint160(IMD));
        assertGt(workClaims, 0);
        assertGt(imdClaims, 0);
        work.transfer(address(hook), 3 ether);
        pair.transfer(address(hook), 7 ether);
        vm.deal(address(hook), 2 ether); // Forced ETH; the hook has no receive function.
        uint256 nativeBefore = TREASURY.balance;
        uint256 pmWork = work.balanceOf(address(manager));
        uint256 pmImd = pair.balanceOf(address(manager));
        vm.prank(KEEPER);
        hook.sweep();
        assertEq(work.balanceOf(TREASURY), workClaims + 3 ether);
        assertEq(pair.balanceOf(TREASURY), imdClaims + 7 ether);
        assertEq(TREASURY.balance, nativeBefore + 2 ether);
        assertEq(work.balanceOf(address(manager)), pmWork - workClaims);
        assertEq(pair.balanceOf(address(manager)), pmImd - imdClaims);
        assertEq(manager.balanceOf(address(hook), uint160(address(work))), 0);
        assertEq(manager.balanceOf(address(hook), uint160(IMD)), 0);
        assertEq(work.balanceOf(address(hook)), 0);
        assertEq(pair.balanceOf(address(hook)), 0);
        assertEq(address(hook).balance, 0);
        assertEq(work.balanceOf(KEEPER), 0);
        assertEq(pair.balanceOf(KEEPER), 0);
        vm.prank(KEEPER);
        hook.sweep();
        assertEq(work.balanceOf(TREASURY), workClaims + 3 ether);
        assertEq(pair.balanceOf(TREASURY), imdClaims + 7 ether);
    }

    function testEmptySweepSucceeds() public {
        vm.prank(KEEPER);
        hook.sweep();
        assertEq(work.balanceOf(TREASURY), 0);
        assertEq(pair.balanceOf(TREASURY), 0);
    }

    function testTokenPayoutFailurePreservesClaimsForRetry() public {
        _swap(true, -10 ether);
        _swap(false, -10 ether);
        uint256 imdClaims = manager.balanceOf(address(hook), uint160(IMD));
        uint256 workClaims = manager.balanceOf(address(hook), uint160(address(work)));
        pair.setRejectTransfers(true);
        vm.expectRevert();
        hook.sweep();
        assertEq(manager.balanceOf(address(hook), uint160(IMD)), imdClaims);
        assertEq(manager.balanceOf(address(hook), uint160(address(work))), workClaims);
        assertEq(pair.balanceOf(TREASURY), 0);
        assertEq(work.balanceOf(TREASURY), 0);
        pair.setRejectTransfers(false);
        hook.sweep();
        assertEq(pair.balanceOf(TREASURY), imdClaims);
        assertEq(work.balanceOf(TREASURY), workClaims);
    }

    function testNativePayoutFailureRevertsClaimRedemptionsToo() public {
        _swap(true, -10 ether);
        _swap(false, -10 ether);
        uint256 imdClaims = manager.balanceOf(address(hook), uint160(IMD));
        uint256 workClaims = manager.balanceOf(address(hook), uint160(address(work)));
        RejectNative reject = new RejectNative();
        vm.etch(TREASURY, address(reject).code);
        vm.deal(address(hook), 1 ether);
        vm.expectRevert();
        hook.sweep();
        assertEq(manager.balanceOf(address(hook), uint160(IMD)), imdClaims);
        assertEq(manager.balanceOf(address(hook), uint160(address(work))), workClaims);
        assertEq(pair.balanceOf(TREASURY), 0);
        assertEq(work.balanceOf(TREASURY), 0);
        assertEq(address(hook).balance, 1 ether);
        vm.etch(TREASURY, "");
        hook.sweep();
        assertEq(pair.balanceOf(TREASURY), imdClaims);
        assertEq(work.balanceOf(TREASURY), workClaims);
    }

    function testReentrantClaimSweepCannotRedeemTwice() public {
        bool imdIs0 = Currency.unwrap(key.currency0) == IMD;
        _swap(!imdIs0, -10 ether); // IMD output means IMD hook claims.
        uint256 claims = manager.balanceOf(address(hook), uint160(IMD));
        assertGt(claims, 0);
        pair.setReenter(address(hook));
        hook.sweep();
        assertTrue(pair.reentryAttempted());
        assertFalse(pair.reentrySucceeded()); // PoolManager rejects nested unlock.
        assertEq(pair.balanceOf(TREASURY), claims);
        assertEq(manager.balanceOf(address(hook), uint160(IMD)), 0);
    }
}
