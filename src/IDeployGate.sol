// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.4;

interface IDeployGate {
    /// @dev What a namespace holds beside its commitments: the term everything in it hangs off, which `clear`
    ///      moves, and the delay its delegates commit under
    struct Namespace {
        uint64 term;
        uint64 delay;
    }

    /// @dev What an id holds: the generation of the commitment standing under it, how many of that
    ///      commitment's contracts have been deployed, and the moment the whole of it becomes deployable
    struct Commitment {
        uint64 nonce;
        uint64 cursor;
        uint64 deployableAt;
    }

    event SetDelegate(address indexed namespace, address indexed delegatee, bool isValid);
    event SetDelay(address indexed namespace, uint64 seconds_);
    event Clear(address indexed namespace, uint64 term);
    event Deploy(
        address indexed namespace, bytes32 indexed id, uint64 term, uint64 nonce, bytes32 salt, address indexed target
    );
    event Commit(
        address indexed namespace,
        bytes32 indexed id,
        uint64 indexed nonce,
        uint64 term,
        uint64 deployableAt,
        bytes32[] salts,
        bytes32[] initCodeHashes,
        address[] executors
    );

    /// @dev The caller is neither the account the namespace is named after nor one of its delegates
    error NotAuthorized();
    /// @dev The caller is not one of the executors the commitment named
    error NotExecutor();
    /// @dev A salt without an init code hash, or an init code hash without a salt
    error LengthMismatch();
    /// @dev The salt carries nothing at the position the commitment has reached, or carries other init code
    error NotCommitted(bytes32 salt);
    /// @dev One commitment naming the same salt twice, which would leave one entry behind two positions
    error DuplicateSalt(bytes32 salt);
    /// @dev The delay the commitment was made under has not passed yet
    error NotYetDeployable(uint64 deployableAt);
    /// @dev The salt is already spent: something stands at the address it names
    error ProxyDeploymentFailed();
    /// @dev The init code did not leave a contract behind, having reverted or returned nothing
    error ContractDeploymentFailed();

    //----------------------------------------------------------------------------------------------
    // Committing
    //----------------------------------------------------------------------------------------------

    /// @notice Commits which contracts may be deployed in `namespace`, in what order, and by whom. One
    ///         transaction whatever the contract count.
    /// @dev    Committing under an id that already holds a commitment replaces it whole, so whatever the new
    ///         one does not mention stops being deployable, and committing nothing revokes it. Committing
    ///         under a fresh id leaves every other commitment alone, which is how several are kept in flight
    ///         at once. What a delegate commits is not deployable until the namespace's delay has passed.
    /// @param  namespace Namespace to commit in, which the addresses derive from alongside the salt. The
    ///         caller has to be the account it is named after, or one of its delegates
    /// @param  id Which of the namespace's commitments this is. Any 32 bytes, chosen by the caller. It scopes
    ///         permission only: two commitments naming the same salt point at the same address, and whichever
    ///         deploys first takes it
    /// @param  salts Salt of each contract, in deployment order. Any 32 bytes: the CREATE3 salt is derived
    /// @param  initCodeHashes Hash of the creation code, including constructor arguments, of each contract
    /// @param  executors Accounts allowed to deploy this commitment, and nothing else. None of them has to be
    ///         the account the namespace is named after, and none gains any privilege beyond deploying
    ///         exactly what is committed here
    function commit(
        address namespace,
        bytes32 id,
        bytes32[] calldata salts,
        bytes32[] calldata initCodeHashes,
        address[] calldata executors
    ) external;

    /// @notice Lets `delegatee` commit in the caller's namespace, or stops it.
    /// @dev    Always the caller's own namespace, so a delegate naming a delegate names it in its own, and
    ///         nothing a delegate does can take a namespace from the account it is named after.
    ///
    ///         A delegate is trusted while it holds the delegation: what it commits is committed, and
    ///         withdrawing the delegation reaches only what it would commit next, leaving what it already
    ///         committed deployable. `setDelay` is what bounds that trust, and `clear` is what withdraws
    ///         every delegation at once, along with everything they committed.
    ///
    ///         Set the delay before granting the delegation, not after. A commitment takes the delay the
    ///         namespace had at the moment it was made, so a delegate granted while the delay is zero can
    ///         commit something deployable at once, and setting a delay afterwards does not reach it.
    ///
    ///         What the delay bounds is what a delegate can deploy, never what it can undo. Committing
    ///         under an id replaces what stands there in the same block, so a delegate can cancel the
    ///         namespace's own commitments as fast as they are made, and keep doing it until the delegation
    ///         is withdrawn. Nothing is lost by that: the salts stay unspent and committing again is a
    ///         signature, but a deployment in progress does not finish while it is going on.
    function setDelegate(address delegatee, bool isValid) external;

    /// @notice Sets how long a commitment made by one of the caller's delegates waits before it can be
    ///         deployed. What the caller commits itself never waits.
    /// @dev    The delay bounds the privilege a namespace hands out and not the one it holds, which is why a
    ///         delegate calling this sets the delay of its own namespace and not of the one it commits in.
    ///
    ///         A commitment carries the moment it becomes deployable, so this reaches commitments made after
    ///         it and never those that already stand, a delegate's included: `clear` is what reaches those.
    ///         Set it before granting a delegation rather than after, or the first thing that delegation
    ///         commits is deployable at once.
    ///
    ///         Pick it against how long the account behind the namespace takes to sign a `clear` on every
    ///         chain it has a namespace on, since a term is per chain and so is the containment, and against
    ///         a monitor that is actually watching `Commit` events. A window nobody watches or can act
    ///         inside buys nothing. There is no cap: a delay large enough to overflow the timestamp makes
    ///         every delegate commitment revert, and the useful range is hours.
    function setDelay(uint64 seconds_) external;

    /// @notice Empties the caller's namespace: every delegation it granted, and every commitment made in it
    ///         by anyone under any id, in one write.
    /// @dev    Nothing has to be enumerated first, which is the point: a delegate picks its own ids, so after
    ///         a leaked key the ids to replace are not the ids anyone knows to look for.
    ///
    ///         Addresses are untouched. The salts stay unspent, so what was going to be deployed still can
    ///         be, and anything already deployed stands. Committing again works as it did, in the term this
    ///         opens, and the generation of an id keeps counting across it, so no two commitments under one
    ///         id are ever logged as the same one.
    ///
    ///         Always the caller's own namespace, like `setDelegate` and `setDelay`.
    function clear() external;

    //----------------------------------------------------------------------------------------------
    // Deployment
    //----------------------------------------------------------------------------------------------

    /// @notice Deploys the next contract of a commitment, and consumes it.
    /// @dev    Reverts until the commitment's `deployableAt` has passed, and reverts unless the init code
    ///         hashes to what the commitment holds at the position it has reached.
    ///
    ///         The cursor moves before the init code runs, so what the order binds is the order the
    ///         deployments were invoked in and not the order their constructors finished: a constructor
    ///         reaching an executor can have the next contract of the same commitment deployed inside it.
    /// @param  namespace Namespace the contract was committed in, which is what its address derives from
    /// @param  id Commitment the contract was committed under, which is what holds its position
    /// @param  salt Salt of the contract, as committed
    /// @param  initCode Creation code, including constructor arguments, of the contract
    /// @return target Address of the deployed contract
    function deploy(address namespace, bytes32 id, bytes32 salt, bytes calldata initCode)
        external
        returns (address target);

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @notice What `namespace` holds: the term everything in it hangs off, which `clear` moves, and the
    ///         delay its delegates commit under
    function namespaces(address namespace) external view returns (uint64 term, uint64 delay);

    /// @notice What `id` holds in `namespace`: the generation of the commitment standing under it, which
    ///         committing again replaces and which keeps counting across a `clear`; how many of that
    ///         commitment's contracts have been deployed, and so which one comes next; and the moment the
    ///         whole of it becomes deployable, zero when it already is
    function commitments(address namespace, bytes32 id)
        external
        view
        returns (uint64 nonce, uint64 cursor, uint64 deployableAt);

    /// @notice Whether `who` may commit in `namespace`, in the term it is in now
    function isDelegate(address namespace, address who) external view returns (bool);

    /// @notice Whether `who` may deploy what the commitment standing under `id` holds
    function isExecutor(address namespace, bytes32 id, address who) external view returns (bool);

    /// @notice What `salt` carries under the commitment standing under `id`, or zero when it carries nothing
    function committed(address namespace, bytes32 id, bytes32 salt) external view returns (bytes32);

    /// @notice What a salt carries once committed: the hash of its init code, bound to its position in the
    ///         order. An executor reproduces this to deploy
    function commitment(bytes32 initCodeHash, uint256 index) external pure returns (bytes32);

    /// @notice CREATE3 salt that `namespace` deploys `salt` under, which is the whole of what separates one
    ///         namespace from the next: 32 bytes, none of them spent on anything else. Nothing chain-specific
    ///         goes into it, so a namespace is the same set of addresses on every chain. The commitment id is
    ///         not in it either: where a contract lands does not depend on which commitment authorised it
    function namespaceSalt(address namespace, bytes32 salt) external pure returns (bytes32);

    /// @notice Address `salt` deploys to in `namespace`, whether or not it has been deployed yet
    function addressOf(address namespace, bytes32 salt) external view returns (address);
}
