// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.4;

interface IDeployGate {
    event SetDelegate(address indexed namespace, address indexed delegatee, bool isValid);
    event SetDelay(address indexed namespace, uint64 seconds_);
    event Clear(address indexed namespace, uint256 term);
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

    error NotAuthorized();
    error NotExecutor();
    error LengthMismatch();
    error NotCommitted(bytes32 salt);
    error DuplicateSalt(bytes32 salt);
    /// @dev The delay a delegate's commitment was made under has not passed yet
    error NotYetDeployable(uint64 deployableAt);
    /// @dev The salt is already spent: something stands at the address it names
    error ProxyDeploymentFailed();
    /// @dev The init code did not leave a contract behind, having reverted or returned nothing
    error ContractDeploymentFailed();

    //----------------------------------------------------------------------------------------------
    // Committing
    //----------------------------------------------------------------------------------------------

    /// @notice Lets `delegatee` commit in the caller's namespace, or stops it. Always the caller's own: a
    ///         delegate cannot name further delegates, and cannot take the namespace from the account it is
    ///         named after, which is the one thing addresses derive from.
    /// @dev    A delegate is trusted while it holds the delegation: what it commits is committed, and
    ///         stopping it reaches only what it would commit next. What bounds that trust is `setDelay`:
    ///         a delegate's commitment is not deployable until the delay has passed, so a commitment the
    ///         namespace did not mean to make can still be cleared when it is seen. Granting a delegate
    ///         with no delay set is granting a key that can spend any unspent address in the namespace at
    ///         a moment of its own choosing, with nothing in between.
    ///
    ///         Withdrawing one delegation leaves the rest of the namespace as it was, commitments included,
    ///         which is how a warm key is stood down once the phase it was granted for is over. `clear`
    ///         is the other end of that: it withdraws every delegation at once, along with everything they
    ///         committed.
    function setDelegate(address delegatee, bool isValid) external;

    /// @notice Sets how long a commitment made by one of the caller's delegates waits before it can be
    ///         deployed. What the caller commits itself never waits: the delay bounds the privilege it hands
    ///         out and not the one it holds, which is also why a delegate calling this sets its own
    ///         namespace's delay and not the namespace it commits in.
    /// @dev    Takes effect for commitments made after it, and reaches none that already stand: a commitment
    ///         carries the moment it becomes deployable, so lowering the delay does not release what is
    ///         waiting and raising it does not hold back what is not. `clear` is what reaches those.
    ///
    ///         Pick it against how long the namespace takes to sign a `clear`, since that is what the window
    ///         is for: a delay shorter than its own response time buys nothing, and one that assumes nobody
    ///         is watching for `Commit` events buys nothing either.
    function setDelay(uint64 seconds_) external;

    /// @notice Empties the caller's namespace: every delegation it granted, and every commitment made in it
    ///         by anyone under any id, in one write. Nothing has to be enumerated first, which is the point
    ///         — a delegate picks its own ids, so after a leaked key the ids to replace are not the ids the
    ///         namespace knows.
    /// @dev    What it does not touch is addresses. The salts stay unspent, so what was going to be deployed
    ///         still can be, and anything already deployed stands. Committing again works as it did, in the
    ///         term this opens; the generation of an id keeps counting across it, so no two commitments under
    ///         one id are ever logged as the same one.
    ///
    ///         Always the caller's own namespace, like `setDelegate` and `setDelay`: a delegate calling it
    ///         empties its own and reaches nothing of the namespace it commits in.
    function clear() external;

    /// @notice Commits what each salt may deploy, in what order, and who may deploy it. Committing under an
    ///         id that already holds one replaces it whole, so whatever it does not mention becomes
    ///         undeployable and committing nothing revokes it; committing under a fresh id leaves every
    ///         other commitment alone, which is how several of them are kept in flight at once.
    /// @param  namespace Namespace to commit in, which is what the addresses derive from alongside the salt.
    ///         The caller has to be the account it is named after, or one of its delegates
    /// @param  id Which of the namespace's commitments this is. Any 32 bytes, chosen by the caller. It scopes
    ///         permission only: two commitments naming the same salt still point at the same address, and
    ///         whichever deploys first takes it
    /// @param  salts Salt of each contract, in deployment order. Any 32 bytes: the CREATE3 salt is derived
    /// @param  initCodeHashes Hash of the creation code, including constructor arguments, of each contract
    /// @param  executors Accounts allowed to deploy this commitment, and nothing else. None of them has to be
    ///         the namespace, and none gains any privilege beyond deploying exactly what is committed here
    function commit(
        address namespace,
        bytes32 id,
        bytes32[] calldata salts,
        bytes32[] calldata initCodeHashes,
        address[] calldata executors
    ) external;

    //----------------------------------------------------------------------------------------------
    // Deployment
    //----------------------------------------------------------------------------------------------

    /// @notice Deploys the next contract of a commitment, and consumes it.
    /// @dev    The cursor moves before the init code runs, so what the order binds is the order the
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

    /// @notice When a commitment becomes deployable, or zero when it already is. Set from the namespace's
    ///         delay at the moment a delegate commits, and never for what the namespace commits itself
    function deployableAt(address namespace, bytes32 id) external view returns (uint64);

    /// @notice How long a commitment made by one of `namespace`'s delegates waits before it is deployable
    function delay(address namespace) external view returns (uint64);

    /// @notice Generation of a commitment, which committing under the same id again replaces whole. It keeps
    ///         counting across a clearance, so what identifies a generation in the log is the term and the
    ///         nonce together: the nonce alone repeats nothing, but says nothing about which term holds it
    function nonce(address namespace, bytes32 id) external view returns (uint64);

    /// @notice How many contracts of a commitment have been deployed, and so which comes next. One cursor per
    ///         commitment, which is what lets several of them be in flight without interleaving
    function deployed(address namespace, bytes32 id) external view returns (uint64);

    /// @notice Whether `who` may commit in `namespace` on its behalf, in the term the namespace is in now
    function isDelegate(address namespace, address who) external view returns (bool);

    /// @notice Which term `namespace` is in. Everything it holds is keyed by it, so `clear` moving it is what
    ///         leaves the delegations and commitments of the term before holding nothing
    function term(address namespace) external view returns (uint64);

    /// @notice Whether `who` may deploy what a commitment holds, under its live generation
    function isExecutor(address namespace, bytes32 id, address who) external view returns (bool);

    /// @notice What `salt` carries under a commitment's live generation, or zero when it carries nothing
    function committed(address namespace, bytes32 id, bytes32 salt) external view returns (bytes32);

    /// @notice What a commitment's grants hang off: the namespace, the term it was made in, and the id. The
    ///         term is in it so that ending one leaves every commitment made under it holding nothing,
    ///         without the gate having to walk ids it was never told about
    function scopeOf(address namespace, bytes32 id) external view returns (bytes32);

    /// @notice What a salt carries once committed, which a caller reproduces to deploy it
    function commitment(bytes32 initCodeHash, uint256 index) external pure returns (bytes32);

    /// @notice CREATE3 salt that `namespace` deploys `salt` under, which is the whole of what separates one
    ///         namespace from the next: 32 bytes, none of them spent on anything else. Nothing chain-specific
    ///         goes into it, so a namespace is the same set of addresses on every chain. The commitment id is
    ///         not in it either: where a contract lands does not depend on which commitment authorised it.
    function namespaceSalt(address namespace, bytes32 salt) external pure returns (bytes32);

    /// @notice Address `salt` deploys to in `namespace`, whether or not it has been deployed yet
    function addressOf(address namespace, bytes32 salt) external view returns (address);
}
