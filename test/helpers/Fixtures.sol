// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Only the WORKERS timestamp interface is simulated; no NFT implementation is supplied.
contract WorkersStub {
    uint256 public timestamp;
    uint256 public mode;

    function configure(uint256 timestamp_, uint256 mode_) external {
        timestamp = timestamp_;
        mode = mode_;
    }

    fallback() external {
        uint256 m = mode;
        if (m == 1) revert("WORKERS unavailable");
        if (m == 2) {
            assembly ("memory-safe") {
                mstore(0, 1)
                return(0, 31)
            }
        }
        if (m == 3) {
            assembly ("memory-safe") {
                invalid()
            }
        }
        if (m == 4) timestamp = 1; // Fails under STATICCALL.
        uint256 t = timestamp;
        assembly ("memory-safe") {
            mstore(0, t)
            return(0, 32)
        }
    }
}

contract PairStub is ERC20 {
    bool public rejectTransfers;
    address public reenter;
    bool public reentrySucceeded;
    bool public reentryAttempted;

    constructor() ERC20("Test IMD", "IMD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setRejectTransfers(bool reject) external {
        rejectTransfers = reject;
    }

    function setReenter(address target) external {
        reenter = target;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (rejectTransfers) return false;
        if (reenter != address(0)) {
            reentryAttempted = true;
            (reentrySucceeded,) = reenter.call(abi.encodeWithSignature("sweep()"));
        }
        return super.transfer(to, amount);
    }
}

contract RejectNative {
    receive() external payable {
        revert("no native currency");
    }
}
