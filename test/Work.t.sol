// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Work} from "../src/Work.sol";

contract WorkTest is Test {
    Work internal token;
    address internal constant USER = address(0xA11CE);

    function setUp() public {
        token = new Work();
    }

    function testMetadataAndFixedSupply() public view {
        assertEq(token.name(), "Work");
        assertEq(token.symbol(), "WORK");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(address(this)), token.totalSupply());
    }

    function testFuzzTransferConservesSupply(uint256 amount) public {
        amount = bound(amount, 0, token.totalSupply());
        assertTrue(token.transfer(USER, amount));
        assertEq(token.balanceOf(USER), amount);
        assertEq(token.balanceOf(address(this)) + token.balanceOf(USER), token.totalSupply());
        vm.prank(USER);
        assertTrue(token.transfer(address(this), amount));
        assertEq(token.balanceOf(address(this)), 1_000_000_000 ether);
    }

    function testApprovalAndTransferFrom() public {
        token.approve(USER, 3 ether);
        vm.prank(USER);
        token.transferFrom(address(this), USER, 2 ether);
        assertEq(token.allowance(address(this), USER), 1 ether);
        assertEq(token.balanceOf(USER), 2 ether);
        vm.prank(USER);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, USER, 1 ether, 2 ether)
        );
        token.transferFrom(address(this), USER, 2 ether);
    }

    function testRejectsOverdrawAndZeroRecipient() public {
        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, USER, 0, 1));
        token.transfer(address(this), 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
    }
}
