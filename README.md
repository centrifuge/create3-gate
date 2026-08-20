# create3-gate

A chain-agnostic, ownerless gate that splits CREATE3 deployment into a validator who commits what should be
deployed and executors who can deploy only that.

## What it is for

Deploying a protocol from a single key means that key decides, one transaction at a time, what code lands at
which address. Nothing about the deployment is agreed to up front, so nothing about it can be reviewed up
front: reviewing means watching it happen. And the key that signs it is the key every address derives from, so
it cannot be a cold one, and it cannot be shared between two people without both of them being able to deploy
whatever they like.

The other half of the problem is arithmetic. The deployment this gate was built for is 56 contracts across
eleven mainnets — 616 transactions, each signed by the deploying account: 616 device confirmations on a hardware
wallet, or 616 proposals behind a multisig. A ceremony nobody can realistically get through is one that ends up
being done by a hot key instead, which is how the account every address derives from becomes the least protected
one in the deployment. Authorising a deployment wants a cold key signing once; sending it wants a warm key
signing hundreds of times. One account cannot be both.

The `DeployGate` splits that in two.

| Phase | Who signs | What it does | Transactions |
|---|---|---|---|
| Validate | the **validator**, or one of its **delegates** | commits the `(salt, init code hash)` of every contract, in order, and names who may deploy them | **1 per chain**, whatever the contract count |
| Deploy | any **executor** the commitment named | deploys the committed contracts, one at a time, and nothing else | one per contract |

What comes out of that:

- **The deployment is agreed to before it exists.** One transaction a multisig can sign, one log a reviewer can
  read back, and nothing deployed until the phase after it — so a commitment found to be wrong costs a
  re-validation rather than a redeployment.
- **The trusted account signs once per chain**, whatever the contract count: eleven signatures rather than 616,
  with an executor key that can only produce what was committed sending the rest. That is what makes a hardware
  wallet or a Safe a realistic validator.
- **The two phases have to agree.** The deploy phase rebuilds each init code from scratch and has to land on
  exactly what was committed, so anything phase-dependent in a constructor argument (`msg.sender` is the
  classic) aborts with `NotValidated` rather than deploying something else.
- **Addresses are the same on every chain**, enforced by the gate rather than by the script, so the eleven
  commitments are one thing to review rather than eleven.

## How it works

### Namespaces

Everything inside the gate lives in a **namespace**, named after an account — the **validator**. Addresses
derive from the gate, the namespace and the salt, so two namespaces can neither collide nor block each other,
and one gate is safe for everyone to share. The gate itself has no roles: no owner, no admin, no wards, and no
privilege over anything it deploys.

There is no call that moves a namespace to another account. The validator is what every address derives from,
so it deliberately cannot be replaced — that key is the one that has to be looked after.

### Commitments

```solidity
gate.validate(validator, id, salts, initCodeHashes, executors);   // the validator, or a delegate
gate.deploy(validator, id, salts[0], initCodes[0]);               // any of the executors
```

A validator can hold several commitments at once, told apart by an **id** it picks:

- Committing under an id that already holds a commitment **replaces it whole** — salts and executors alike.
  Committing nothing revokes it outright. Whatever a new commitment does not mention becomes undeployable, so
  a superseded set cannot be spent afterwards.
- Committing under a fresh id leaves every other commitment alone. Each id carries its own generation
  (`nonce`) and its own deployment cursor (`deployed`), so one commitment can be signed while another is still
  being executed.
- The id scopes permission and never an address. Two commitments naming the same salt point at the same
  contract, and whichever deploys first takes it.

### Delegates

`setDelegate(delegatee, isValid)` lets another account run the validate phase on the validator's behalf. This
is how a cold validator can be the thing addresses derive from while a warmer key signs the commitment.

Delegation goes one way and one level deep: `setDelegate` always writes to the *caller's own* namespace, so a
delegate naming a delegate names it in its own, and nothing a delegate does can take the namespace away from
the account it is named after. A leaked delegate key can commit, and is revoked in one call; it can never be
walked outwards, and it can never lock the validator out.

Revoking an **executor** key works the other way round, because executors belong to the commitment rather than
sitting beside it: commit again without it, which replaces the set whole.

### Why the executors need no trust

A committed `(salt, init code hash)` pair leaves an executor no freedom. The salt fully determines the CREATE3
address and the hash fully determines the code, so an executor can only put the intended code at the intended
address, or revert. Authorizing several therefore costs no more trust than authorizing one.

Three things all have to be committed for that to hold:

- **The init code**, or an executor could deploy code of its own at a validated address.
- **The salt**, or an executor could deploy validated code at an address of its choosing, consume the
  validation, and strand the intended address.
- **The order**, which is the one thing left for it to choose, and it is not inert: a constructor reading a
  dependency the deployment itself wires would see a different value depending on when it ran, and bake it
  into its runtime code. A commitment binds each contract to its position — `commitment(initCodeHash, index)`
  — and the gate keeps a cursor per commitment, so a contract deployed out of turn reverts rather than landing
  early.

### Addresses

CreateX derives a CREATE3 address from its caller and the salt. The caller is the gate, and the gate builds its
own CreateX salt from whatever 32 bytes a script passes it:

```
createXSalt(validator, salt) = bytes20(gate) ‖ 0x00 ‖ bytes11(keccak256(validator, salt))
```

Both halves of that are load-bearing:

- The first 20 bytes name the gate as CreateX's **salt guardian**, which is what makes CreateX scope the
  address to the gate. No address the gate hands out is reachable from outside it, whatever salt somebody
  passes CreateX directly — and a script cannot ask for a salt naming a different guardian, which would put
  the address somewhere anyone could take it.
- The 21st byte is CreateX's cross-chain redeploy protection, which would fold the chain id into the address.
  Held at zero, so **a namespace is the same set of addresses on every chain**.

That leaves 11 bytes carrying `keccak256(validator, salt)`, which is what separates two namespaces — and two
salts within one — from each other. `addressOf(validator, salt)` computes the result, deployed or not.

CREATE3 addresses ignore the init code, which is what keeps an address still when a patch release changes a
contract — and exactly why the commitment has to bind the init code hash separately.

### The gate's own address

The gate is at `0x6A7E0000Df5b2C00101da4700317128f07ad8BeA` on every chain, and **anyone** can put it there. It
takes no constructor arguments and grants its deployer nothing, so there is nothing to configure and no order
to get right: the first run that needs a gate deploys it, the way a deployment makes sure CreateX is there.

It is deployed through CreateX's `deployCreate2`, not `deployCreate3`, which is what makes that safe: a CREATE2
address covers the init code, so the only contract that fits the gate's address is the gate — and this
contract's code is the whole of its authority. The salt is zero in every byte CreateX reads, the one combination
CreateX derives from the salt alone, so the address is the same everywhere. It needs
[CreateX](https://github.com/pcaversaccio/createx) at `0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed` on the chain.

The gate's code is, by the same derivation, effectively frozen: changing `DeployGate.sol`, or the settings it is
compiled with, produces a different gate at a different address, and every address derived from it moves.

## Layout

```
src/DeployGate.sol          the gate
src/IDeployGate.sol         its interface, and where each call is documented in full
script/DeployGate.d.sol     salt, address, extcodehash and creation code — what a consumer holds the gate by
script/DeployGateScript.sol brings the gate up in a forge script or test, as CreateXScript does for CreateX
test/DeployGate.t.sol       behaviour, plus the checks that keep DeployGate.d.sol honest
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

    function validate() public {
        vm.startBroadcast();

        setUpDeployGate();
        gate.validate(validator, id, salts, initCodeHashes, executors);

        vm.stopBroadcast();
    }

    function execute() public {
        vm.startBroadcast();
        setUpDeployGate();

        for (uint256 i; i < salts.length; i++) {
            gate.deploy(validator, id, salts[i], initCodes[i]);
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
moves the constants in `script/DeployGate.d.sol` — and with them every address the gate would ever produce, so it
is a decision rather than a chore.
