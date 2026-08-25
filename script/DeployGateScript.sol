// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.4;

import {DEPLOY_GATE_SALT, DEPLOY_GATE_ADDRESS, DEPLOY_GATE_BYTECODE, DEPLOY_GATE_EXTCODEHASH} from "./DeployGate.d.sol";

import {CreateXScript} from "createx-forge/script/CreateXScript.sol";

/// @title  DeployGateScript
/// @notice Makes sure a chain has its DeployGate, for the scripts that deploy through one. To be inherited by
///         a deployment script, the way CreateXScript is.
///
/// @dev    The same shape as CreateXScript, one level up and for the same reason: the gate is a fixed address
///         a script needs to already be there, so a script makes sure of it rather than depending on someone
///         having run something first. Unlike CreateX it can always be put there, on any chain and by anyone,
///         so the only case to bail out on is foreign code at the address, which no run can work around
///         and which this refuses to continue past.
///
///         It deploys from DEPLOY_GATE_BYTECODE rather than from the contract, so a repository that vendors
///         this file and DeployGate.d.sol needs nothing else of the gate: no source, no dependency on it.
abstract contract DeployGateScript is CreateXScript {
    /// @notice Deploys the DeployGate when the chain does not have one, and checks it when it does
    /// @dev    Deliberately not a `setUp()` modifier, as CreateXScript offers for CreateX: `setUp()` runs
    ///         outside the broadcast, so a gate deployed there would only ever exist in the simulation. Call
    ///         it where the phase is broadcast, and a missing gate is deployed for real as the transaction
    ///         before the phase's own.
    function setUpDeployGate() internal {
        setUpCreateXFactory();

        if (DEPLOY_GATE_ADDRESS.code.length == 0) {
            CreateX.deployCreate2(DEPLOY_GATE_SALT, DEPLOY_GATE_BYTECODE);
        }

        // A chain that derives addresses its own way is where the constant stops standing for the gate
        require(isDeployGateDeployed(), "Not the DeployGate: unexpected code at that address");

        vm.label(DEPLOY_GATE_ADDRESS, "DeployGate");
    }

    /// @notice Whether the gate is where it belongs, running the code it is supposed to run
    function isDeployGateDeployed() internal view returns (bool) {
        return DEPLOY_GATE_ADDRESS.codehash == DEPLOY_GATE_EXTCODEHASH;
    }
}
