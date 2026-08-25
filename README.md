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

The bigger the deployment, the more this saves, since committing is one transaction whatever the contract count.
Centrifuge Protocol, the deployment it was built for, is 56 contracts. On eleven chains that is 616 deployments,
signed by a hot key, behind 11 cold signatures. Sign 616 of them from a cold wallet instead and the deployment
gets done with a hot key anyway.

## Use it

```solidity
import {DeployGateScript} from "create3-gate/script/DeployGateScript.sol";
import {DEPLOY_GATE_ADDRESS} from "create3-gate/script/DeployGate.d.sol";
import {IDeployGate} from "create3-gate/src/IDeployGate.sol";

contract MyDeployer is DeployGateScript {
    IDeployGate gate = IDeployGate(DEPLOY_GATE_ADDRESS);

    address constant NAMESPACE = 0x...;         // the cold account: every address below derives from it
    address constant EXECUTOR = 0x...;          // the hot key that sends the deployments
    bytes32 constant ID = "v1";                 // names this commitment, so several can be in flight

    function salts() internal pure returns (bytes32[] memory s) {
        s = new bytes32[](2);
        s[0] = "Root";
        s[1] = "Gateway";
    }

    // Phase 1, signed by the cold key, one transaction per chain
    function commit() public {
        vm.startBroadcast();
        setUpDeployGate();

        bytes32[] memory hashes = new bytes32[](2);
        hashes[0] = keccak256(initCodeForRoot());
        hashes[1] = keccak256(initCodeForGateway(gate.addressOf(NAMESPACE, "Root")));

        address[] memory executors = new address[](1);
        executors[0] = EXECUTOR;

        gate.commit(NAMESPACE, ID, salts(), hashes, executors);
        vm.stopBroadcast();
    }

    // Phase 2, signed by the hot key, in a separate run
    function deploy() public {
        vm.startBroadcast();
        setUpDeployGate();

        gate.deploy(NAMESPACE, ID, "Root", initCodeForRoot());
        gate.deploy(NAMESPACE, ID, "Gateway", initCodeForGateway(gate.addressOf(NAMESPACE, "Root")));

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

## The addresses you get

```
addressOf(namespace, salt)
```

Nothing chain-specific goes into the derivation, so one namespace is the same set of addresses on every chain,
and `addressOf` answers before anything is deployed. A constructor can take the address of a contract that has
not been deployed yet, on a chain where nothing has been deployed at all.

Addresses derive from the gate, the account the namespace is named after, and the salt. Not from the init code,
so a patch release lands at the same address; not from the commitment id, so where a contract goes never
depends on which commitment authorised it; and not from the deployer of the transaction, so the hot key is
free to change.

Two namespaces can neither collide nor block each other, which is why one gate is safe for everyone to share.
The gate has no owner, no admin and no privilege over anything it deploys.

## What the hot key can do

A commitment pins three things per contract, and together they leave the executor no choices:

- the salt, so it cannot move a contract to an address of its choosing and strand the intended one,
- the init code hash, so it cannot deploy code of its own at an approved address,
- the position in the order, so it cannot deploy a contract before a dependency it reads in its
  constructor exists.

A constructor argument that differs between the two phases (`msg.sender` is the usual one) changes the init
code hash, and the deploy aborts with `NotCommitted` instead of deploying something else.

Naming several executors costs no more than naming one. Executors belong to the commitment, so rotating them
means committing again without the old one.

## Committing again, and delegating

- Committing under an id that already holds a commitment replaces it whole. Whatever the new one does not
  mention stops being deployable, and committing nothing revokes it outright.
- Committing under a fresh id leaves every other commitment alone, so one deployment can be signed while
  another is still being executed.
- `setDelegate(delegatee, true)` lets a second key run the commit phase, for when a Safe signing eleven
  commitments is too slow. A delegate can commit anything the cold key could, so it is bounded by
  `setDelay(seconds)`: what a delegate commits is not deployable until the delay has passed, which is the
  window in which a commitment nobody meant to make can still be stopped. Set the delay before granting.
- `clear()` empties the caller's namespace: every delegation, and every commitment made under any id, in one
  write. The salts stay unspent, so what was going to be deployed still can be. It is per chain, like every
  other call.

## Installing

Add this repository as a dependency, or vendor `script/DeployGate.d.sol` and `script/DeployGateScript.sol` into
your own, the way `CreateX.d.sol` is vendored from [createx-forge](https://github.com/radeksvarz/createx-forge).
Vendoring is enough because nothing outside this repository compiles `DeployGate.sol`: the constants are bytes
and the address is fixed on chain, so no compiler settings have to match.

The gate is at `0xBA08f1fD092031C81296fC59f6539b21b38f2249` on every chain, as pinned in
`script/DeployGate.d.sol`, and anyone can put it there. It takes no constructor arguments and grants its
deployer nothing, so there is nothing to configure and no order to get right.

It is deployed through CreateX's `deployCreate2` rather than `deployCreate3`. A CREATE2 address covers the init
code, so the only contract that fits the gate's address is the gate. Changing `DeployGate.sol`, or the settings it is compiled with, produces a different gate at a different
address, and every address derived from it moves.

## Reference

Every call is documented in full in [`src/IDeployGate.sol`](src/IDeployGate.sol).

```
src/DeployGate.sol          the gate
src/Create3.sol             the CREATE3 derivation it deploys through
src/IDeployGate.sol         its interface, and where each call is documented
script/DeployGate.d.sol     salt, address, extcodehash and creation code: what a consumer holds the gate by
script/DeployGateScript.sol brings the gate up in a forge script or test, as CreateXScript does for CreateX
```

## Why it exists

Deploying from a single key means the key decides, one transaction at a time, what code lands where. Nothing is
agreed up front, so reviewing the deployment means watching it happen. That key is also the one every address
derives from, so it cannot be cold, and two people cannot share it without both being able to deploy anything
they like.

Authorising a deployment suits a cold key signing once. Sending it needs a key signing hundreds of times. The
gate lets one account do the first and another do the second.

## Development

```bash
forge build
forge test
forge fmt
```

`foundry.toml` pins the compiler settings the gate's bytecode was derived from. Changing them moves the
constants in `script/DeployGate.d.sol`, and with them every address the gate would ever produce.
