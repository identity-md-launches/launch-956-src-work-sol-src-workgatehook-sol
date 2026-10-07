// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Work} from "src/Work.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/// @dev All supply starts with actor 0. No balance or storage cheatcodes are used.
contract WorkHandler is Test {
    Work public immutable work;
    address[3] public actors = [address(0xA11CE), address(0xB0B), address(0xCA401)];
    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;

    constructor(Work work_) {
        work = work_;
        expectedBalance[actors[0]] = 1_000_000_000 ether;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) public {
        address from = actors[fromSeed % 3];
        address to = actors[toSeed % 3];
        amount = bound(amount, 0, expectedBalance[from]);
        vm.prank(from);
        assertTrue(work.transfer(to, amount));
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) public {
        address owner = actors[ownerSeed % 3];
        address spender = actors[spenderSeed % 3];
        // Unbounded: exercise zero, overwrites and maximum/infinite approvals.
        vm.prank(owner);
        assertTrue(work.approve(spender, amount));
        expectedAllowance[owner][spender] = amount;
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount) public {
        address owner = actors[ownerSeed % 3];
        address spender = actors[spenderSeed % 3];
        address to = actors[toSeed % 3];
        uint256 allowance = expectedAllowance[owner][spender];
        uint256 balance = expectedBalance[owner];
        amount = bound(amount, 0, allowance < balance ? allowance : balance);
        vm.prank(spender);
        assertTrue(work.transferFrom(owner, to, amount));
        expectedBalance[owner] -= amount;
        expectedBalance[to] += amount;
        if (allowance != type(uint256).max) expectedAllowance[owner][spender] -= amount;
    }

    function rejectOverdraw(uint256 ownerSeed) public {
        address owner = actors[ownerSeed % 3];
        uint256 balance = expectedBalance[owner];
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, balance, balance + 1)
        );
        work.transfer(actors[(ownerSeed % 3 + 1) % 3], balance + 1);
    }

    function rejectUnapprovedSpend(uint256 ownerSeed, uint256 amount) public {
        address owner = actors[ownerSeed % 3];
        address spender = actors[(ownerSeed % 3 + 1) % 3];
        vm.prank(owner);
        work.approve(spender, 0);
        expectedAllowance[owner][spender] = 0;
        amount = bound(amount, 1, type(uint256).max);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, amount));
        work.transferFrom(owner, spender, amount);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract WorkInvariantTest is Test {
    Work internal work;
    WorkHandler internal handler;

    function setUp() public {
        work = new Work();
        handler = new WorkHandler(work);
        work.transfer(handler.actors(0), work.totalSupply());
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.approve.selector;
        selectors[2] = handler.transferFrom.selector;
        selectors[3] = handler.rejectOverdraw.selector;
        selectors[4] = handler.rejectUnapprovedSpend.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariantFixedSupplyAndBalancesMatchIndependentLedger() public view {
        uint256 sum;
        for (uint256 i; i < 3; ++i) {
            address actor = handler.actors(i);
            uint256 balance = work.balanceOf(actor);
            assertEq(balance, handler.expectedBalance(actor), "actor balance differs from transfer ledger");
            sum += balance;
            for (uint256 j; j < 3; ++j) {
                address spender = handler.actors(j);
                assertEq(work.allowance(actor, spender), handler.expectedAllowance(actor, spender));
            }
        }
        assertEq(work.totalSupply(), 1_000_000_000 ether);
        assertEq(sum, work.totalSupply());
        assertEq(work.balanceOf(address(0)), 0);
        assertEq(work.balanceOf(address(this)), 0);
        assertEq(work.balanceOf(address(handler)), 0);
    }

    function testZeroOneFullSupplyAndSelfTransfer() public {
        handler.transfer(0, 1, 0);
        invariantFixedSupplyAndBalancesMatchIndependentLedger();
        handler.transfer(0, 1, 1);
        handler.transfer(1, 1, 1);
        handler.transfer(1, 0, 1);
        handler.transfer(0, 1, 1_000_000_000 ether);
        handler.transfer(1, 1, 1_000_000_000 ether);
        invariantFixedSupplyAndBalancesMatchIndependentLedger();
        handler.rejectOverdraw(0);
        handler.rejectOverdraw(1);
        invariantFixedSupplyAndBalancesMatchIndependentLedger();
    }

    function testInfiniteAllowanceThenRevocationAndFiniteExhaustion() public {
        handler.approve(0, 1, type(uint256).max);
        handler.transferFrom(0, 1, 2, 1_000_000_000 ether);
        invariantFixedSupplyAndBalancesMatchIndependentLedger();
        handler.transfer(2, 0, 1_000_000_000 ether);
        handler.rejectUnapprovedSpend(0, 1);
        handler.approve(0, 1, 1);
        handler.transferFrom(0, 1, 2, 1);
        invariantFixedSupplyAndBalancesMatchIndependentLedger();
    }
}
