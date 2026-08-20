// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @dev What the tests deploy. Records its creator as well as its argument, since a CREATE3 payload is
///      created by the proxy rather than by whoever asked for it, and that is worth being able to see.
contract Target {
    uint256 public value;
    address public immutable DEPLOYER;

    constructor(uint256 value_) {
        value = value_;
        DEPLOYER = msg.sender;
    }
}

function initCodeFor(uint256 value) pure returns (bytes memory) {
    return abi.encodePacked(type(Target).creationCode, abi.encode(value));
}
