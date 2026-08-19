// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @title  Create3
/// @notice CREATE3 in the gate itself: a CREATE2 proxy whose only job is to CREATE the payload, so the
///         resulting address covers the deployer and the salt but not the init code.
library Create3 {
    bytes internal constant PROXY_INIT_CODE = hex"67363d3d37363d34f03d5260086018f3";
    bytes32 internal constant PROXY_INIT_CODE_HASH = 0x21c35dbe1b344a2488cf3321d6ce542f8e9f305544ff09e4993a62319a497c1f;

    error ProxyDeploymentFailed();
    error ContractDeploymentFailed();

    /// @notice Deploys `initCode` at the address `salt` names for this contract.
    function deploy(bytes32 salt, bytes memory initCode) internal returns (address target) {
        target = addressOf(salt, address(this));

        bytes memory proxyInitCode = PROXY_INIT_CODE;
        address proxy;
        assembly ("memory-safe") {
            proxy := create2(0, add(proxyInitCode, 0x20), mload(proxyInitCode), salt)
        }
        require(proxy != address(0), ProxyDeploymentFailed());

        // The proxy CREATEs whatever it is called with, and reports nothing back, so the deployment is
        // checked by looking at the address it had to land on
        (bool ok,) = proxy.call(initCode);
        require(ok && target.code.length != 0, ContractDeploymentFailed());
    }

    /// @notice Address `salt` deploys to for `deployer`, whether or not it has been deployed yet.
    function addressOf(bytes32 salt, address deployer) internal pure returns (address target) {
        address proxy =
            address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", deployer, salt, PROXY_INIT_CODE_HASH)))));

        // 0xd6 = RLP list of 21 bytes, 0x94 = RLP string of 20 bytes, 0x01 = the proxy's first nonce
        target = address(uint160(uint256(keccak256(abi.encodePacked(hex"d694", proxy, hex"01")))));
    }
}
