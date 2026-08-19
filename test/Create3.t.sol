// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {Create3} from "../src/Create3.sol";
import {Target, initCodeFor} from "./Target.sol";
import {IDeployGate} from "../src/IDeployGate.sol";

contract Reverting {
    constructor() {
        revert("no");
    }
}

/// @dev The library is internal, so it is exercised through a contract that deploys as the gate would
contract Deployer {
    function deploy(bytes32 salt, bytes memory initCode) external payable returns (address) {
        return Create3.deploy(salt, initCode);
    }

    function addressOf(bytes32 salt) external view returns (address) {
        return Create3.addressOf(salt, address(this));
    }
}

contract Create3Test is Test {
    Deployer deployer;

    function setUp() public {
        deployer = new Deployer();
    }

    // The proxy

    /// @dev The init code is the 16 bytes every CREATE3 implementation shares, and the hash is a constant so
    ///      the derivation can be pure. It has to stay the hash of the init code
    function testProxyInitCodeHashMatchesTheInitCode() public pure {
        assertEq(keccak256(Create3.PROXY_INIT_CODE), Create3.PROXY_INIT_CODE_HASH);
    }

    // Deployment

    function testDeploy() public {
        bytes32 salt = keccak256("a");
        address predicted = deployer.addressOf(salt);

        address target = deployer.deploy(salt, initCodeFor(7));

        assertEq(target, predicted, "should land where addressOf said");
        assertEq(Target(target).value(), 7, "constructor arguments should be honoured");
        assertTrue(target.code.length != 0);
    }

    /// @dev The proxy is what CREATEs the payload, so that is what a constructor sees, not the deployer
    function testConstructorSeesTheProxy() public {
        address target = deployer.deploy(keccak256("b"), initCodeFor(1));

        address seen = Target(target).DEPLOYER();
        assertTrue(seen != address(deployer), "the deployer is not the immediate creator");
        assertTrue(seen != address(0));
    }

    function testDeployLargeInitCode() public {
        bytes memory padded = abi.encodePacked(initCodeFor(3), new bytes(20_000));

        address target = deployer.deploy(keccak256("big"), padded);

        assertEq(Target(target).value(), 3);
    }

    // Failure

    /// @dev The salt is spent on the proxy, so the second attempt cannot even get that far
    function testDeployTwiceWithTheSameSaltReverts() public {
        bytes32 salt = keccak256("c");
        deployer.deploy(salt, initCodeFor(1));

        vm.expectRevert(IDeployGate.ProxyDeploymentFailed.selector);
        deployer.deploy(salt, initCodeFor(1));
    }

    /// @dev The proxy reports nothing back, so a constructor that reverts is caught by the address being
    ///      empty rather than by the call failing
    function testRevertingConstructorReverts() public {
        vm.expectRevert(IDeployGate.ContractDeploymentFailed.selector);
        deployer.deploy(keccak256("d"), type(Reverting).creationCode);
    }

    /// @dev Empty init code CREATEs an account with no code, which is not a deployment
    function testEmptyInitCodeReverts() public {
        vm.expectRevert(IDeployGate.ContractDeploymentFailed.selector);
        deployer.deploy(keccak256("e"), "");
    }

    /// @dev A failed deployment leaves the salt spendable, since the proxy was never created
    function testSaltSurvivesAFailedDeployment() public {
        bytes32 salt = keccak256("f");

        vm.expectRevert(IDeployGate.ContractDeploymentFailed.selector);
        deployer.deploy(salt, type(Reverting).creationCode);

        assertEq(Target(deployer.deploy(salt, initCodeFor(9))).value(), 9);
    }

    /// @dev Nothing is forwarded: the proxy is created with no value and called with none, so ether cannot
    ///      end up stranded in either it or the contract it creates
    function testDeployForwardsNoValue() public {
        bytes32 salt = keccak256("v");
        address proxy = vm.computeCreate2Address(salt, Create3.PROXY_INIT_CODE_HASH, address(deployer));

        address target = deployer.deploy{value: 1 ether}(salt, initCodeFor(1));

        assertEq(proxy.balance, 0, "the proxy should hold nothing");
        assertEq(target.balance, 0, "and neither should the contract");
        assertEq(address(deployer).balance, 1 ether, "the value stays with the caller");
    }

    // The address

    /// @dev CREATE2 scopes the proxy to whoever deploys it, which is the whole of the access control
    function testAddressDependsOnTheDeployer() public {
        Deployer other = new Deployer();
        bytes32 salt = keccak256("h");

        assertTrue(deployer.addressOf(salt) != other.addressOf(salt));
    }

    /// @dev Nothing chain-specific enters the derivation
    function testAddressIsTheSameOnEveryChain() public {
        bytes32 salt = keccak256("i");
        address here = deployer.addressOf(salt);

        vm.chainId(block.chainid + 1);

        assertEq(deployer.addressOf(salt), here);
    }

    /// @dev The derivation restated through Foundry rather than through the library: CREATE2 for the proxy,
    ///      then its first nonce for the payload
    function testAddressMatchesTheDerivation() public view {
        bytes32 salt = keccak256("j");
        address proxy = vm.computeCreate2Address(salt, Create3.PROXY_INIT_CODE_HASH, address(deployer));

        assertEq(deployer.addressOf(salt), vm.computeCreateAddress(proxy, 1));
    }

    /// @dev The whole 32 bytes reach the address: no part of the salt is spent or ignored
    function testEveryByteOfTheSaltReachesTheAddress(uint8 index) public view {
        index = uint8(bound(index, 0, 31));
        bytes32 salt = keccak256("k");

        bytes32 flipped = salt ^ bytes32(uint256(1) << (uint256(index) * 8));

        assertTrue(deployer.addressOf(salt) != deployer.addressOf(flipped), "a salt byte was ignored");
    }

    function testDistinctSaltsGiveDistinctAddresses(bytes32 a, bytes32 b) public view {
        vm.assume(a != b);

        assertTrue(deployer.addressOf(a) != deployer.addressOf(b));
    }

    /// @dev Predicted before the fact and landed on after it, for arbitrary salts
    function testDeployMatchesAddressOf(bytes32 salt, uint256 value) public {
        address predicted = deployer.addressOf(salt);

        assertEq(deployer.deploy(salt, initCodeFor(value)), predicted);
        assertEq(Target(predicted).value(), value);
    }
}
