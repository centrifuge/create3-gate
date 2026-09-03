# create3-gate

Deterministic CREATE3 deployments across chains, authorised by one key and sent by another.

A multi-chain deployment is signed transaction by transaction by the account every deployed address derives
from. Fifty contracts across ten chains is five hundred transactions from that one account, which is more than
a cold key can realistically sign, and sharing it means everyone holding it can deploy whatever they like.

The gate splits that in two. A cold key commits what may be deployed, one transaction per chain independent of
the contract count. A hot key then sends every deployment, and can produce nothing but what was committed: the
same init code, at the same addresses, in the same order, or it reverts.

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
nobody meant to make can still be stopped. Set the delay before granting. `clear(namespace)` empties it, every
delegation and every commitment under any id, in one write, leaving the salts unspent so what was going to be
deployed still can be. The delegates can clear as well as the namespace, so acting inside the window is a warm
signature rather than a cold one; a delegate that clears revokes itself along with everything else, and the
delay survives, so a clearance is no way around it. Both are per chain, like every other call.

Every call is documented in full in [`src/IDeployGate.sol`](src/IDeployGate.sol).

## Installing

Add this repository as a dependency, or vendor `script/DeployGate.d.sol` and `script/DeployGateScript.sol`, the
way `CreateX.d.sol` is vendored from [createx-forge](https://github.com/radeksvarz/createx-forge). Nothing
outside this repository compiles `DeployGate.sol`, so no compiler settings have to match.

The gate takes no constructor arguments and has no owner, so there is nothing to configure. It is deployed
through CreateX's `deployCreate2` rather than `deployCreate3`: a CREATE2 address covers the init code, so the
only contract that fits the gate's address is the gate. Changing `DeployGate.sol`, or the compiler settings in
`foundry.toml`, produces a different gate at a different address, and every address derived from it moves.

It compiles for London, so it runs on chains several forks behind. What it does need is standard address
derivation: a chain that computes `CREATE2` or `CREATE` addresses its own way, as the zkStack chains do, is out
of scope, and `setUpDeployGate` fails the run there rather than deploying into the unknown.

## Deployments

`0x6A7E000000007f5bB2913f18AfCfe1B402ce1e4A`, the same address on all 52, listed machine-readably in
[`deployments/deployments.json`](deployments/deployments.json).

| Chain | Chain ID | Explorer |
|---|---|---|
| Ethereum | `1` | [etherscan.io](https://etherscan.io/address/0x6A7E000000007f5bB2913f18AfCfe1B402ce1e4A) |
| Optimism | `10` | [optimistic.etherscan.io](https://optimistic.etherscan.io/address/0x6A7E000000007f5bB2913f18AfCfe1B402ce1e4A) |
| XDC | `50` | [xdcscan.com](https://xdcscan.com/address/0x6A7E000000007f5bB2913f18AfCfe1B402ce1e4A) |
| BNB Smart Chain | `56` | [bscscan.com](https://bscscan.com/address/0x6A7E000000007f5bB2913f18AfCfe1B402ce1e4A) |
| Gnosis | `100` | [gnosisscan.io](https://gnosisscan.io/address/0x6A7E000000007f5bB2913f18AfCfe1B402ce1e4A) |
| Fuse | `122` | [explorer.fuse.io](https://explorer.fuse.io/address/0x6A7E000000007f5bB2913f18AfCfe1B402ce1e4A) |
| Unichain | `130` | [uniscan.xyz](https://uniscan.xyz/address/0x6A7E000000007f5bB2913f18AfCfe1B402ce1e4A) |
| Polygon | `137` | [polygonscan.com](https://polygonscan.com/address/0x6A7E000000007f5bB2913f18AfCfe1B402ce1e4A) |
| Monad | `143` | [monadscan.com](https://monadscan.com/address/0x6A7E000000007f5bB2913f18AfCfe1B402ce1e4A) |
| Sonic | `146` | [sonicscan.org](https://sonicscan.org/address/0x6A7E000000007f5bB2913f18AfCfe1B402ce1e4A) |
| Hashkey | `177` | [hsk.blockscout.com](https://hsk.blockscout.com/address/0x6A7E000000007f5bB2913f18AfCfe1B402ce1e4A) |
| X Layer | `196` | [www.oklink.com/xlayer](https://www.oklink.com/xlayer/address/0x6A7E000000007f5bB2913f18AfCfe1B402ce1e4A) |
| opBNB | `204` | [opbnb.bscscan.com](https://opbnb.bscscan.com/address/0x6A7E000000007f5bB2913f18AfCfe1B402ce1e4A) |
| Fraxtal | `252` | [fraxscan.com](https://fraxscan.com/address/0x6A7E000000007f5bB2913f18AfCfe1B402ce1e4A) |
| WorldChain | `480` | [worldscan.org](https://worldscan.org/address/0x6A7E000000007f5bB2913f18AfCfe1B402ce1e4A) |
| Stable | `988` | [stablescan.xyz](https://stablescan.xyz/address/0x6A7E000000007f5bB2913f18AfCfe1B402ce1e4A) |
| HyperEVM | `999` | [hyperevmscan.io](https://hyperevmscan.io/address/0x6A7E000000007f5bB2913f18AfCfe1B402ce1e4A) |
| Lisk | `1135` | [blockscout.lisk.com](https://blockscout.lisk.com/address/0x6A7E000000007f5bB2913f18AfCfe1B402ce1e4A) |
| Story | `1514` | [datanetscan.io](https://datanetscan.io/address/0x6A7E000000007f5bB2913f18AfCfe1B402ce1e4A) |
| Gravity | `1625` | [explorer.gravity.xyz](https://explorer.gravity.xyz/address/0x6A7E000000007f5bB2913f18AfCfe1B402ce1e4A) |
| Pharos | `1672` | [www.pharosscan.xyz](https://www.pharosscan.xyz/address/0x6A7E000000007f5bB2913f18AfCfe1B402ce1e4A) |
| Metal | `1750` | [explorer.metall2.com](https://explorer.metall2.com/address/0x6A7E000000007f5bB2913f18AfCfe1B402ce1e4A) |
| Injective | `1776` | [blockscout.injective.network](https://blockscout.injective.network/address/0x6A7E000000007f5bB2913f18AfCfe1B402ce1e4A) |
| Kava | `2222` | [kavascan.com](https://kavascan.com/address/0x6A7E000000007f5bB2913f18AfCfe1B402ce1e4A) |
| GOAT | `2345` | [explorer.goat.network](https://explorer.goat.network/address/0x6A7E000000007f5bB2913f18AfCfe1B402ce1e4A) |
| Morph | `2818` | [explorer.morphl2.io](https://explorer.morphl2.io/address/0x6A7E000000007f5bB2913f18AfCfe1B402ce1e4A) |
| Peaq | `3338` | [peaq.subscan.io](https://peaq.subscan.io/address/0x6A7E000000007f5bB2913f18AfCfe1B402ce1e4A) |
| MegaETH | `4326` | [mega.etherscan.io](https://mega.etherscan.io/address/0x6A7E000000007f5bB2913f18AfCfe1B402ce1e4A) |
| Robinhood | `4663` | [robinscan.io](https://robinscan.io/address/0x6A7E000000007f5bB2913f18AfCfe1B402ce1e4A) |
| Superseed | `5330` | [explorer.superseed.xyz](https://explorer.superseed.xyz/address/0x6A7E000000007f5bB2913f18AfCfe1B402ce1e4A) |
| Kaia | `8217` | [kaiascope.com](https://kaiascope.com/address/0x6A7E000000007f5bB2913f18AfCfe1B402ce1e4A) |
| Base | `8453` | [basescan.org](https://basescan.org/address/0x6A7E000000007f5bB2913f18AfCfe1B402ce1e4A) |
| Plasma | `9745` | [plasmascan.to](https://plasmascan.to/address/0x6A7E000000007f5bB2913f18AfCfe1B402ce1e4A) |
| Immutable zkEVM | `13371` | [explorer.immutable.com](https://explorer.immutable.com/address/0x6A7E000000007f5bB2913f18AfCfe1B402ce1e4A) |
| 0G | `16661` | [chainscan.0g.ai](https://chainscan.0g.ai/address/0x6A7E000000007f5bB2913f18AfCfe1B402ce1e4A) |
| ApeChain | `33139` | [apescan.io](https://apescan.io/address/0x6A7E000000007f5bB2913f18AfCfe1B402ce1e4A) |
| Mode | `34443` | [explorer.mode.network](https://explorer.mode.network/address/0x6A7E000000007f5bB2913f18AfCfe1B402ce1e4A) |
| Arbitrum One | `42161` | [arbiscan.io](https://arbiscan.io/address/0x6A7E000000007f5bB2913f18AfCfe1B402ce1e4A) |
| Arbitrum Nova | `42170` | [nova-explorer.arbitrum.io](https://nova-explorer.arbitrum.io/address/0x6A7E000000007f5bB2913f18AfCfe1B402ce1e4A) |
| Celo | `42220` | [celoscan.io](https://celoscan.io/address/0x6A7E000000007f5bB2913f18AfCfe1B402ce1e4A) |
| Etherlink | `42793` | [explorer.etherlink.com](https://explorer.etherlink.com/address/0x6A7E000000007f5bB2913f18AfCfe1B402ce1e4A) |
| Hemi | `43111` | [explorer.hemi.xyz](https://explorer.hemi.xyz/address/0x6A7E000000007f5bB2913f18AfCfe1B402ce1e4A) |
| Avalanche C-Chain | `43114` | [snowtrace.io](https://snowtrace.io/address/0x6A7E000000007f5bB2913f18AfCfe1B402ce1e4A) |
| Linea | `59144` | [lineascan.build](https://lineascan.build/address/0x6A7E000000007f5bB2913f18AfCfe1B402ce1e4A) |
| BOB | `60808` | [explorer.gobob.xyz](https://explorer.gobob.xyz/address/0x6A7E000000007f5bB2913f18AfCfe1B402ce1e4A) |
| Berachain | `80094` | [berascan.com](https://berascan.com/address/0x6A7E000000007f5bB2913f18AfCfe1B402ce1e4A) |
| Blast | `81457` | [blastscan.io](https://blastscan.io/address/0x6A7E000000007f5bB2913f18AfCfe1B402ce1e4A) |
| Plume | `98866` | [explorer.plume.org](https://explorer.plume.org/address/0x6A7E000000007f5bB2913f18AfCfe1B402ce1e4A) |
| Katana | `747474` | [katanascan.com](https://katanascan.com/address/0x6A7E000000007f5bB2913f18AfCfe1B402ce1e4A) |
| XRPL EVM | `1440000` | [explorer.xrplevm.org](https://explorer.xrplevm.org/address/0x6A7E000000007f5bB2913f18AfCfe1B402ce1e4A) |
| Jovay | `5734951` | [explorer.jovay.io/l2](https://explorer.jovay.io/l2/address/0x6A7E000000007f5bB2913f18AfCfe1B402ce1e4A) |
| Zora | `7777777` | [explorer.zora.energy](https://explorer.zora.energy/address/0x6A7E000000007f5bB2913f18AfCfe1B402ce1e4A) |

### Putting it on a chain that has none

The gate takes no arguments and grants its deployer nothing, so this needs no permission and no coordination:

```console
cast send 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed \
  "deployCreate2(bytes32,bytes)" $DEPLOY_GATE_SALT $DEPLOY_GATE_BYTECODE \
  --private-key $PK --rpc-url $RPC
```

Both constants are in [`script/DeployGate.d.sol`](script/DeployGate.d.sol); no source and no compiler settings
are involved. It costs about 1.12M gas.

## Audits

The reports are in [`audits/`](audits).

| Auditor | Team | Report |
|---|---|---|
| Burra Security | Alex Filippov, fuzious, Taridoku | [2026-08-burraSec.pdf](audits/2026-08-burraSec.pdf) |
| Sherlock | 0x52 | [2026-09-Sherlock.pdf](audits/2026-09-Sherlock.pdf) |

## License

MIT, see [LICENSE](LICENSE).
