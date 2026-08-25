# create3-gate

Deterministic CREATE3 deployments across chains, authorised by one key and sent by another.

Deploying Centrifuge Protocol takes 56 contracts on eleven chains: 616 transactions, each signed by the account
every deployed address derives from. That account cannot be a cold one if it has to sign 616 times, and it
cannot be shared without everyone holding it being able to deploy whatever they like.

The gate splits the deployment in two. A cold key commits what may be deployed, one transaction per chain
independent of the contract count, so eleven signatures rather than 616. A hot key then sends all 616
deployments, and can produce nothing but what was committed: the same init code, at the same addresses, in the
same order, or it reverts.

| Phase | Key | Signs | What it can do |
|---|---|---|---|
| `commit` | the cold one, which every address derives from | once per chain, independent of the contract count | says what may be deployed, in what order, and by whom |
| `deploy` | a hot one, named in the commitment | once per contract | deploys exactly that, and nothing else |

The cold key never sends a deployment, and the hot key can live in CI. Addresses are the same on every chain,
and `addressOf(namespace, salt)` answers before anything has been deployed.

## Use it

```solidity
contract MyDeployer is DeployGateScript {
    IDeployGate gate = IDeployGate(DEPLOY_GATE_ADDRESS);

    address constant NAMESPACE = 0x...; // the cold account, which every address derives from
    bytes32 constant ID = "v1";         // names this commitment, so several can be in flight

    // Both phases build the deployment here, so the two cannot drift apart. A constructor argument can be
    // the address of a contract that has not been deployed yet, on this chain or on any other
    function contracts() internal view returns (bytes32[] memory salts, bytes[] memory initCodes) {
        salts[0] = "Root";
        initCodes[0] = type(Root).creationCode;

        salts[1] = "Gateway";
        initCodes[1] = abi.encodePacked(type(Gateway).creationCode, abi.encode(gate.addressOf(NAMESPACE, "Root")));
    }

    // Signed by the cold key, once per chain
    function commit() public {
        (bytes32[] memory salts, bytes[] memory initCodes) = contracts();

        vm.startBroadcast();
        setUpDeployGate();
        gate.commit(NAMESPACE, ID, salts, hashesOf(initCodes), executors);
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

A commitment pins three things per contract, and an executor can change none of them:

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

`setDelegate(delegatee, true)` lets a second key run the commit phase, for when signing every commitment from
the cold account is impractical. A delegate can commit anything the cold key could, so `setDelay` bounds it:
what a delegate commits is not deployable until the delay has passed, which is the window in which a commitment
nobody meant to make can still be stopped. Set the delay before granting. `clear()` empties the namespace,
every delegation and every commitment under any id, in one write, leaving the salts unspent so what was going
to be deployed still can be. Both are per chain, like every other call.

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

## License

Business Source License 1.1, as declared in every source file. It converts to GPL v3.0 or later five years
after publication, and the additional use grants are listed at [license.centrifuge.io](https://license.centrifuge.io).
