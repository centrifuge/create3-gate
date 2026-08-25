// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";

import {DeployGate} from "../src/DeployGate.sol";
import {IDeployGate} from "../src/IDeployGate.sol";
import {DeployGateScript} from "../script/DeployGateScript.sol";
import {DEPLOY_GATE_ADDRESS, DEPLOY_GATE_EXTCODEHASH} from "../script/DeployGate.d.sol";
import {Target, initCodeFor} from "./Target.sol";

/// @dev The consumer entry point, exercised the way a deployment script uses it. Nothing here compiles
///      DeployGate.sol for the deployment itself: the constants are the whole of what it deploys from, which
///      is what a vendoring repository relies on.
contract DeployGateScriptTest is Test, DeployGateScript {
    address immutable EXECUTOR = makeAddr("executor");
    bytes32 constant ID = bytes32(uint256(1));

    /// @dev `setUpDeployGate` is internal, so it needs a frame of its own for a revert to be expectable
    function callSetUpDeployGate() external {
        setUpDeployGate();
    }

    /// @dev A chain with no gate gets one, at the address the constant names
    function testSetUpDeployGateDeploysAMissingGate() public {
        if (vm.isContext(VmSafe.ForgeContext.Coverage)) return;

        assertEq(DEPLOY_GATE_ADDRESS.code.length, 0, "should start without a gate");
        assertFalse(isDeployGateDeployed());

        setUpDeployGate();

        assertTrue(isDeployGateDeployed(), "the gate should be there");
        assertEq(DEPLOY_GATE_ADDRESS.codehash, DEPLOY_GATE_EXTCODEHASH);
    }

    /// @dev Running it again on a chain that already has one is a check, not a second deployment
    function testSetUpDeployGateIsIdempotent() public {
        if (vm.isContext(VmSafe.ForgeContext.Coverage)) return;

        setUpDeployGate();
        bytes32 first = DEPLOY_GATE_ADDRESS.codehash;

        setUpDeployGate();

        assertEq(DEPLOY_GATE_ADDRESS.codehash, first, "should not have redeployed");
    }

    /// @dev The one case no run can work around: a chain deriving addresses its own way, where the constant
    ///      stops standing for the gate. Refused rather than deployed around
    function testSetUpDeployGateRejectsForeignCode() public {
        vm.etch(DEPLOY_GATE_ADDRESS, hex"6001");

        assertFalse(isDeployGateDeployed());

        vm.expectRevert("Not the DeployGate: unexpected code at that address");
        this.callSetUpDeployGate();
    }

    /// @dev The gate the constants produce is the gate the source describes
    function testTheDeployedGateMatchesTheSource() public {
        if (vm.isContext(VmSafe.ForgeContext.Coverage)) return;

        setUpDeployGate();

        assertEq(DEPLOY_GATE_ADDRESS.codehash, keccak256(type(DeployGate).runtimeCode));
    }

    /// @dev End to end through the vendored constants: the gate a consumer brings up validates and deploys
    function testTheDeployedGateWorks() public {
        if (vm.isContext(VmSafe.ForgeContext.Coverage)) return;

        setUpDeployGate();
        IDeployGate gate = IDeployGate(DEPLOY_GATE_ADDRESS);

        bytes32[] memory salts = new bytes32[](1);
        bytes32[] memory hashes = new bytes32[](1);
        address[] memory executors = new address[](1);
        bytes memory initCode = initCodeFor(11);
        salts[0] = bytes32(uint256(1));
        hashes[0] = keccak256(initCode);
        executors[0] = EXECUTOR;

        gate.commit(address(this), ID, salts, hashes, executors);

        address predicted = gate.addressOf(address(this), salts[0]);

        vm.prank(EXECUTOR);
        address target = gate.deploy(address(this), ID, salts[0], initCode);

        assertEq(target, predicted, "should land where the gate said");
        assertEq(Target(target).value(), 11);
    }
}
