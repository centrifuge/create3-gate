# create3-gate

Deploy a set of contracts to the same addresses on every chain, with a hot key that can only deploy exactly
what a cold key approved.

The gate splits a deployment into two phases, signed by two different keys:

| Phase | Key | Signs | What it can do |
|---|---|---|---|
| `commit` | the cold one, which every address derives from | once per chain, whatever the contract count | says what may be deployed, in what order, and by whom |
| `deploy` | a hot one, named in the commitment | once per contract | deploys exactly that, and nothing else |

The cold key never sends a deployment. The hot key can never deploy anything the cold key did not commit to,
at any address other than the committed one, or in any other order. So it can live in CI.

The bigger the deployment, the more this matters, since a commitment is one transaction whatever the contract
count. Centrifuge Protocol, the deployment it was built for, is 56 contracts across eleven chains, so 616
deployments in total. Deployed the usual way, all 616 are signed by the key every address derives from. Through
the gate, that key signs 11 commitments and nothing else, and the 616 sends come from a key that cannot change
what they deploy.

## Use it

```solidity
import {DeployGateScript} from "create3-gate/script/DeployGateScript.sol";
import {DEPLOY_GATE_ADDRESS} from "create3-gate/script/DeployGate.d.sol";
import {IDeployGate} from "create3-gate/src/IDeployGate.sol";

contract MyDeployer is DeployGateScript {
    IDeployGate gate = IDeployGate(DEPLOY_GATE_ADDRESS);

    address constant NAMESPACE = 0x...; // the cold account, which every address derives from
    address constant EXECUTOR = 0x...; // the hot key that sends the deployments
    bytes32 constant ID = "v1";

    // Both phases build the deployment here, so they cannot drift apart
    function contracts() internal view returns (bytes32[] memory salts, bytes[] memory initCodes) {
        salts = new bytes32[](2);
        initCodes = new bytes[](2);

        salts[0] = "Root";
        initCodes[0] = type(Root).creationCode;

        salts[1] = "Gateway";
        initCodes[1] = abi.encodePacked(type(Gateway).creationCode, abi.encode(gate.addressOf(NAMESPACE, "Root")));
    }

    // Signed by the cold key, once per chain
    function commit() public {
        (bytes32[] memory salts, bytes[] memory initCodes) = contracts();

        bytes32[] memory hashes = new bytes32[](initCodes.length);
        for (uint256 i; i < initCodes.length; i++) {
            hashes[i] = keccak256(initCodes[i]);
        }

        address[] memory executors = new address[](1);
        executors[0] = EXECUTOR;

        vm.startBroadcast();
        setUpDeployGate();
        gate.commit(NAMESPACE, ID, salts, hashes, executors);
        vm.stopBroadcast();
    }

    // Signed by the hot key, in a separate run
    function deploy() public {
        (bytes32[] memory salts, bytes[] memory initCodes) = contracts();

        vm.startBroadcast();
        setUpDeployGate();
        for (uint256 i; i < salts.length; i++) {
            gate.deploy(NAMESPACE, ID, salts[i], initCodes[i]);
        }
        vm.stopBroadcast();
    }
}
```

```bash
forge script MyDeployer --sig 'commit()' --rpc-url $CHAIN --ledger --sender $COLD --broadcast
forge script MyDeployer --sig 'deploy()' --rpc-url $CHAIN --private-key $HOT --broadcast
```

Run the two phases as two separate commands. Rebuilding the init code in a fresh process is what proves the
deploy phase agrees with what was committed; doing both in one run gives that up.

`setUpDeployGate()` deploys the gate if the chain does not have one, and checks its code either way. Call it
inside the broadcast: `setUp()` runs outside it, so a gate deployed there would only exist in the simulation.
It needs [CreateX](https://github.com/pcaversaccio/createx) already on the chain, and etches it on a local fork
so an anvil run can rehearse the whole sequence from nothing.

## How it works

Everything the gate holds lives in a namespace, named after the account that commits in it. Addresses derive
from the gate, that account and the salt:

```
addressOf(namespace, salt)
```

Nothing chain-specific enters the derivation, so a namespace is the same set of addresses on every chain, and
`addressOf` answers before anything is deployed. Not the init code either, so a patch release lands at the same
address, and not the commitment id or the sender, so neither the approval nor the hot key affects where a
contract goes. Two namespaces can neither collide nor block each other, so one gate serves everyone.

A commitment pins three things per contract, and together they leave the executor no choices:

- the salt, so it cannot move a contract to an address of its choosing and strand the intended one,
- the init code hash, so it cannot deploy code of its own at an approved address,
- the position in the order, so it cannot deploy a contract before a dependency its constructor reads.

A constructor argument that differs between the two phases (`msg.sender` is the usual one) changes the init code
hash, and the deploy aborts with `NotCommitted` instead of deploying something else. Naming several executors
costs no more than naming one, and rotating them means committing again without the old one.

Each commitment sits under an id the caller picks:

- Committing under an id that already holds a commitment replaces it whole. Whatever the new one does not
  mention stops being deployable, and committing nothing revokes it outright.
- Committing under a fresh id leaves every other commitment alone, so one deployment can be signed while
  another is still being executed.

Two calls cover the case where a Safe signing eleven commitments is too slow. `setDelegate(delegatee, true)`
lets a second key run the commit phase, and since that key can commit anything the cold one could, `setDelay`
bounds it: what a delegate commits is not deployable until the delay has passed, which is the window in which a
commitment nobody meant to make can still be stopped. Set the delay before granting. `clear()` then empties the
namespace, every delegation and every commitment under any id, in one write, leaving the salts unspent so what
was going to be deployed still can be. Both are per chain, like every other call.

Every call is documented in full in [`src/IDeployGate.sol`](src/IDeployGate.sol).

## Installing

Add this repository as a dependency, or vendor `script/DeployGate.d.sol` and `script/DeployGateScript.sol` into
your own, the way `CreateX.d.sol` is vendored from [createx-forge](https://github.com/radeksvarz/createx-forge).
Vendoring is enough because nothing outside this repository compiles `DeployGate.sol`: the constants are bytes
and the address is fixed on chain, so no compiler settings have to match.

The gate is at `0xBA08f1fD092031C81296fC59f6539b21b38f2249` on every chain, as pinned in
`script/DeployGate.d.sol`, and anyone can put it there. It takes no constructor arguments, holds no privilege
over anything it deploys and has no owner or admin, so there is nothing to configure and no order to get right.

It is deployed through CreateX's `deployCreate2` rather than `deployCreate3`. A CREATE2 address covers the init
code, so the only contract that fits the gate's address is the gate. Changing `DeployGate.sol`, or the compiler
settings in `foundry.toml`, produces a different gate at a different address, and every address derived from it
moves.
