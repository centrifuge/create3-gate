# create3-gate

A chain-agnostic, ownerless gate that splits CREATE3 deployment in two: an account commits what should be
deployed, and executors deploy that and nothing else.

## What it is for

Deploying a protocol from a single key means that key decides, one transaction at a time, what code lands at
which address. Nothing about the deployment is agreed to up front, so nothing about it can be reviewed up
front: reviewing means watching it happen. And the key that signs it is the key every address derives from, so
it cannot be a cold one, and it cannot be shared between two people without both of them being able to deploy
whatever they like.

The other half of the problem is arithmetic. The deployment this gate was built for is 56 contracts across
eleven mainnets: 616 transactions, each signed by the deploying account, so 616 device confirmations on a
hardware wallet, or 616 proposals behind a multisig. A ceremony nobody can realistically get through is one that ends up
being done by a hot key instead, which is how the account every address derives from becomes the least protected
one in the deployment. Authorising a deployment wants a cold key signing once; sending it wants a warm key
signing hundreds of times. One account cannot be both.

The `DeployGate` splits that in two.

| Phase | Who signs | What it does | Transactions |
|---|---|---|---|
| Commit | the **account** the namespace is named after, or one of its **delegates** | commits the `(salt, init code hash)` of every contract, in order, and names who may deploy them | **1 per chain**, whatever the contract count |
| Deploy | any **executor** the commitment named | deploys the committed contracts, one at a time, and nothing else | one per contract |

What comes out of that:

- **The deployment is agreed to before it exists.** One transaction a multisig can sign, one log a reviewer can
  read back, and nothing deployed until the phase after it, so a commitment found to be wrong costs a
  re-commitment rather than a redeployment.
- **The trusted account signs once per chain**, whatever the contract count: eleven signatures rather than
  616, with an executor key that can only produce what was committed sending the rest. That is what makes a
  hardware wallet or a Safe a realistic account to name a namespace after.
- **The two phases have to agree.** The deploy phase rebuilds each init code from scratch and has to land on
  exactly what was committed, so anything phase-dependent in a constructor argument (`msg.sender` is the
  classic) aborts with `NotCommitted` rather than deploying something else.
- **Addresses are the same on every chain**, enforced by the gate rather than by the script, so the eleven
  commitments are one thing to review rather than eleven.

## How it works

### Namespaces

Everything inside the gate lives in a **namespace**, which is named after the account that commits in it.
Addresses derive from the gate, the namespace and the salt, so two namespaces can neither collide nor block
each other, and one gate is safe for everyone to share. The gate itself has no roles: no owner, no admin, no
wards, and no privilege over anything it deploys.

There is no call that moves a namespace to another account. The account it is named after is what every
address derives from, so it deliberately cannot be replaced. That key is the one that has to be looked after.

### Commitments

```solidity
gate.commit(namespace, id, salts, initCodeHashes, executors);   // the account it is named after, or a delegate
gate.deploy(namespace, id, salts[0], initCodes[0]);             // any of the executors
```

A namespace can hold several commitments at once, told apart by an **id** it picks:

- Committing under an id that already holds a commitment **replaces it whole**, salts and executors alike.
  Committing nothing revokes it outright. Whatever a new commitment does not mention becomes undeployable, so
  a superseded set cannot be spent afterwards.
- Committing under a fresh id leaves every other commitment alone. Each id carries its own generation
  (`nonce`) and its own deployment cursor (`cursor`), so one commitment can be signed while another is still
  being executed.
- The id scopes permission and never an address. Two commitments naming the same salt point at the same
  contract, and whichever deploys first takes it.

### Delegates

`setDelegate(delegatee, isValid)` lets another account run the commit phase on the namespace's behalf. This is
how a cold key can be the thing every address derives from while a warmer one signs the commitment.

Delegation goes one way and one level deep: `setDelegate` always writes to the *caller's own* namespace, so a
delegate naming a delegate names it in its own, and nothing a delegate does can take the namespace away from
the account it is named after. A leaked delegate key can commit, and nothing more: it can never be walked
outwards, and it can never lock the namespace out.

A delegate is trusted for as long as it holds the delegation: what it commits is committed, and withdrawing
one delegation reaches only what that delegate would commit next, leaving what it already committed
deployable. That is how a warm key is stood down once the phase it was granted for is over. Containing a key
found to have leaked is the other case, and it is `clear()`: one call, which withdraws every delegation along
with everything any of them committed. Both the delay that bounds a delegation and `clear()` are below.

Revoking an **executor** key works the other way round, because executors belong to the commitment rather than
sitting beside it: commit again without it, which replaces the set whole.

### Delays

A delegate holds the warm key, and a warm key is the one that gets taken. What it can do with it is bounded by
`setDelay(seconds)`:

```solidity
gate.setDelay(6 hours);           // the namespace, for the delegates it grants
```

A commitment made by a delegate is not deployable until the delay has passed. One made by the account itself
never waits, since the delay bounds the privilege a namespace hands out and not the one it holds. `setDelay`
writes to the caller's own namespace like everything else, so a delegate cannot shorten the window it is
committing under.

Without it, a delegation is a key that can spend any unspent address in the namespace at a moment of its own
choosing, in a single transaction that commits and deploys together. That matters here more than it would
elsewhere, because the addresses this gate reserves are the same on every chain: a salt spent on one chain and
unspent on the other ten is the normal state of a deployment in progress, and anyone holding the delegate key
can put its own code at those ten addresses the moment it sees the first one. There is no window to react in,
which is what the delay creates and `clear()` then uses.

Two things follow from the delay being carried by the commitment rather than read at deploy time:

- **Changing it reaches what comes after it**, never what already stands. Lowering the delay does not release
  a commitment that is waiting, and raising it does not hold back one that is not.
- **The window is only as useful as the response inside it.** Pick the delay against how long the account
  takes to sign a `clear()`, and against a monitor that is actually watching `Commit` events. The log
  carries the moment each commitment becomes deployable, so there is nothing to recompute. A namespace with no
  delegates needs no delay, and that is the default.

### Why the executors need no trust

A committed `(salt, init code hash)` pair leaves an executor no freedom. The salt fully determines the CREATE3
address and the hash fully determines the code, so an executor can only put the intended code at the intended
address, or revert. Authorizing several therefore costs no more trust than authorizing one.

Three things all have to be committed for that to hold:

- **The init code**, or an executor could deploy code of its own at a committed address.
- **The salt**, or an executor could deploy committed code at an address of its choosing, consume the
  commitment, and strand the intended address.
- **The order**, which is the one thing left for it to choose, and it is not inert: a constructor reading a
  dependency the deployment itself wires would see a different value depending on when it ran, and bake it
  into its runtime code. A commitment binds each contract to its position, `commitment(initCodeHash, index)`,
  and the gate keeps a cursor per commitment, so a contract deployed out of turn reverts rather than landing
  early.

### Emptying a namespace

Replacing a commitment revokes what it held, but that is per id, and a delegate picks its own ids: after a
leaked delegate key, the ids to replace are not all ids the namespace knows. `clear()` is the call that does
not need to know them, and it is what the delay leaves room for: a delay with nothing to do in the window is a
delay for nothing, and a revocation with no window is one racing a transaction that has already happened.

Everything a namespace holds hangs off the **term** it was in at the time, its delegations as much as its
commitments. `clear()` ends that term, so in one write every commitment made in it stops being deployable and
every delegation granted in it stops being one. Nothing has to be enumerated first, and nothing is recovered by
finding it later: the namespace reads as empty afterwards, which is what the call is named after.

A term bounds what a commitment grants and never an address:

- **The salts stay unspent.** Killing a commitment that was going to deploy at an address leaves that address
  free, so what the namespace meant to put there still can be.
- **Committing again works as it did**, in the term the clearance opened. The generation of an id keeps
  counting across it, so no two commitments under one id are ever the same generation in the log.
- **It is the caller's own namespace**, like `setDelegate` and `setDelay`: a delegate calling `clear` empties
  its own and reaches nothing of the namespace it commits in.
- **Granting again works too.** A delegation made after the clearance lands in the term it opened, so resuming
  is one call and never a revival of what was cleared.

### Addresses

The gate performs CREATE3 itself: a CREATE2 proxy, deployed by the gate, whose only job is to `CREATE` the
contract. The address therefore derives from the gate and from a salt of the gate's own making:

```
namespaceSalt(namespace, salt) = keccak256(namespace, salt)
```

Three things follow from that:

- **The deployer is the gate**, and CREATE2 scopes the proxy to whoever deploys it, so no address the gate
  hands out is reachable from outside it. Handing the same salt to CreateX, or to any other deployer, lands
  somewhere else.
- **Nothing chain-specific enters the derivation**, so a namespace is the same set of addresses on every
  chain.
- **The salt is a whole 32 bytes.** Nothing is spent on a guardian or a redeploy flag, so what separates two
  namespaces, and two salts within one, is the full width of a hash rather than a truncation of it.

`addressOf(namespace, salt)` computes the result, deployed or not.

CREATE3 addresses ignore the init code, which is what keeps an address still when a patch release changes a
contract, and exactly why the commitment has to bind the init code hash separately.

### The gate's own address

The gate is at one address on every chain, `0xBF0D16caAC535Ce58762281A86Af7461657D4296` as pinned in
`script/DeployGate.d.sol`, and **anyone** can put it there. It
takes no constructor arguments and grants its deployer nothing, so there is nothing to configure and no order
to get right: the first run that needs a gate deploys it, the way a deployment makes sure CreateX is there.

It is deployed through CreateX's `deployCreate2`, not `deployCreate3`, which is what makes that safe: a CREATE2
address covers the init code, so the only contract that fits the gate's address is the gate, and this
contract's code is the whole of its authority. The salt is zero throughout, the one combination CreateX derives
from the salt alone, so the address is the same everywhere. It needs
[CreateX](https://github.com/pcaversaccio/createx) at `0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed` on the chain
for that one transaction, and for nothing after it: the deployments the gate goes on to make use its own
CREATE3.

The gate's code is, by the same derivation, effectively frozen: changing `DeployGate.sol`, or the settings it is
compiled with, produces a different gate at a different address, and every address derived from it moves.

## Layout

```
src/DeployGate.sol          the gate
src/Create3.sol             the CREATE3 derivation it deploys through
src/IDeployGate.sol         its interface, and where each call is documented in full
script/DeployGate.d.sol     salt, address, extcodehash and creation code: what a consumer holds the gate by
script/DeployGateScript.sol brings the gate up in a forge script or test, as CreateXScript does for CreateX
test/DeployGate.t.sol       behaviour, plus the check that keeps DeployGate.d.sol honest
```

The split between `src/` and `script/` mirrors [createx-forge](https://github.com/radeksvarz/createx-forge),
and for the same reason: a repository deploying *through* the gate needs the gate's address and bytecode, not
its source.

## Using it

A deployment script inherits `DeployGateScript` and calls `setUpDeployGate()`, which deploys the gate when the
chain has none and checks its code either way. Call it inside the broadcast: `setUp()` runs outside it, so a
gate deployed there would only ever exist in the simulation.

```solidity
import {DeployGateScript} from "create3-gate/script/DeployGateScript.sol";
import {DEPLOY_GATE_ADDRESS} from "create3-gate/script/DeployGate.d.sol";
import {IDeployGate} from "create3-gate/src/IDeployGate.sol";

contract MyDeployer is DeployGateScript {
    IDeployGate gate = IDeployGate(DEPLOY_GATE_ADDRESS);

    function commit() public {
        vm.startBroadcast();

        setUpDeployGate();
        gate.commit(namespace, id, salts, initCodeHashes, executors);

        vm.stopBroadcast();
    }

    function deploy() public {
        vm.startBroadcast();
        setUpDeployGate();

        for (uint256 i; i < salts.length; i++) {
            gate.deploy(namespace, id, salts[i], initCodes[i]);
        }

        vm.stopBroadcast();
    }
}
```

CreateX itself has to be on the chain already: `setUpDeployGate` etches it on a local chain (id 31337) and
refuses to continue anywhere else, which is what lets an anvil fork rehearse the whole sequence from nothing.

Either add this repository as a dependency, or **vendor `script/DeployGate.d.sol`** into the consuming
repository, the way `CreateX.d.sol` is vendored from createx-forge. Vendoring is enough because nothing outside
this repository ever compiles `DeployGate.sol`: the constants are bytes and the address is fixed on chain, so no
compiler settings have to match.

Keep the two phases in separate runs. Rebuilding the init code in a fresh process is what proves the deploy
phase agrees with what was committed; running both in one gives that up.

## Development

```bash
forge build
forge test
forge fmt
```

`foundry.toml` pins the compiler settings the gate's bytecode was derived from. Changing them, or the contract,
moves the constants in `script/DeployGate.d.sol`, and with them every address the gate would ever produce, so it
is a decision rather than a chore.
