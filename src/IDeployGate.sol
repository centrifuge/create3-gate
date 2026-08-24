// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.4;

interface IDeployGate {
    event SetDelegate(address indexed validator, address indexed delegatee, bool isValid);
    event RevokeAll(address indexed validator, uint256 term);
    event Deploy(
        address indexed validator, bytes32 indexed id, uint256 term, uint256 nonce, bytes32 salt, address indexed target
    );
    event Validate(
        address indexed validator,
        bytes32 indexed id,
        uint256 indexed nonce,
        uint256 term,
        bytes32[] salts,
        bytes32[] initCodeHashes,
        address[] executors
    );

    error NotValidator();
    error NotExecutor();
    error LengthMismatch();
    error NotValidated(bytes32 salt);
    error DuplicateSalt(bytes32 salt);
    /// @dev The salt is already spent: something stands at the address it names
    error ProxyDeploymentFailed();
    /// @dev The init code did not leave a contract behind, having reverted or returned nothing
    error ContractDeploymentFailed();

    //----------------------------------------------------------------------------------------------
    // Validation
    //----------------------------------------------------------------------------------------------

    /// @notice Lets `delegatee` commit in the caller's namespace, or stops it. Always the caller's own: a
    ///         delegate cannot name further delegates, and cannot take the namespace from the account it is
    ///         named after, which is the one thing addresses derive from.
    /// @dev    A delegate is trusted while it holds the delegation: what it commits is committed, and
    ///         stopping it reaches only what it would commit next. A key found to have leaked is therefore
    ///         two calls rather than one, since what it already committed — under ids the validator may
    ///         never have seen — goes with `revokeAll`. This one comes first: `revokeAll` opens a term, and
    ///         an account still holding the delegation commits in it as it did in the last.
    function setDelegate(address delegatee, bool isValid) external;

    /// @notice Ends the caller's current term, which makes everything committed in it undeployable at once,
    ///         whatever id holds it and whoever committed it. The namespace reads as empty afterwards and
    ///         commits again as it did, since a term bounds what a commitment grants and never an address:
    ///         the salts stay unspent, so what was going to be deployed still can be.
    /// @dev    This is what contains a leaked delegate key. Revoking the delegate stops it committing again;
    ///         this reaches what it committed while it held the delegation, without the validator first
    ///         having to find which ids that was. Do the revocations first, in the same transaction where
    ///         one is available: this ends a term and opens the next, and a delegate still holding the
    ///         delegation can commit in the new one, which would put back what this call took away.
    function revokeAll() external;

    /// @notice Commits what each salt may deploy, in what order, and who may deploy it. Committing under an
    ///         id that already holds one replaces it whole, so whatever it does not mention becomes
    ///         undeployable and committing nothing revokes it; committing under a fresh id leaves every
    ///         other commitment alone, which is how a validator keeps several of them in flight at once.
    /// @param  validator Namespace to commit in, which is what the addresses derive from alongside the salt.
    ///         The caller has to be it, or one of its delegates
    /// @param  id Which of the validator's commitments this is. Any 32 bytes, chosen by the caller. It scopes
    ///         permission only: two commitments naming the same salt still point at the same address, and
    ///         whichever deploys first takes it
    /// @param  salts Salt of each contract, in deployment order. Any 32 bytes: the CREATE3 salt is derived
    /// @param  initCodeHashes Hash of the creation code, including constructor arguments, of each contract
    /// @param  executors Accounts allowed to deploy this commitment, and nothing else. None of them has to be
    ///         the validator, and none gains any privilege beyond deploying exactly what is committed here
    function validate(
        address validator,
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
    /// @param  validator Namespace the contract was committed in, which is what its address derives from
    /// @param  id Commitment the contract was committed under, which is what holds its position
    /// @param  salt Salt of the contract, as committed
    /// @param  initCode Creation code, including constructor arguments, of the contract
    /// @return target Address of the deployed contract
    function deploy(address validator, bytes32 id, bytes32 salt, bytes calldata initCode)
        external
        returns (address target);

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @notice Generation of a commitment, which committing under the same id again replaces whole. It keeps
    ///         counting across a revocation, so what identifies a generation in the log is the term and the
    ///         nonce together: the nonce alone repeats nothing, but says nothing about which term holds it
    function nonce(address validator, bytes32 id) external view returns (uint256);

    /// @notice How many contracts of a commitment have been deployed, and so which comes next. One cursor per
    ///         commitment, which is what lets several of them be in flight without interleaving
    function deployed(address validator, bytes32 id) external view returns (uint256);

    /// @notice Whether `who` may commit in `validator`'s namespace on its behalf
    function isDelegate(address validator, address who) external view returns (bool);

    /// @notice Which term of `validator`'s namespace is current. Everything a commitment grants is keyed by
    ///         it, so `revokeAll` moving it is what leaves the earlier ones holding nothing
    function term(address validator) external view returns (uint256);

    /// @notice Whether `who` may deploy what a commitment holds, under its live generation
    function isExecutor(address validator, bytes32 id, address who) external view returns (bool);

    /// @notice What `salt` carries under a commitment's live generation, or zero when it carries nothing
    function validated(address validator, bytes32 id, bytes32 salt) external view returns (bytes32);

    /// @notice What a commitment's grants hang off: the namespace, the term it was made in, and the id. The
    ///         term is in it so that ending one leaves every commitment made under it holding nothing,
    ///         without the gate having to walk ids it was never told about
    function scopeOf(address validator, bytes32 id) external view returns (bytes32);

    /// @notice What a salt carries once committed, which a caller reproduces to deploy it
    function commitment(bytes32 initCodeHash, uint256 index) external pure returns (bytes32);

    /// @notice CREATE3 salt that `validator` deploys `salt` under, which is the whole of what separates one
    ///         namespace from the next: 32 bytes, none of them spent on anything else. Nothing chain-specific
    ///         goes into it, so a namespace is the same set of addresses on every chain. The commitment id is
    ///         not in it either: where a contract lands does not depend on which commitment authorised it.
    function namespaceSalt(address validator, bytes32 salt) external pure returns (bytes32);

    /// @notice Address `salt` deploys to in `validator`'s namespace, whether or not it has been deployed yet
    function addressOf(address validator, bytes32 salt) external view returns (address);
}
