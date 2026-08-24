// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Create3} from "./Create3.sol";
import {IDeployGate} from "./IDeployGate.sol";

/// @title  DeployGate
/// @notice Deploys a set of contracts through CREATE3 in two steps: a namespace commits what may be
///         deployed, where, in what order and by whom, and any of the executors it named then deploys it.
///         Committing is one transaction whatever the contract count, and an executor gains no privilege
///         beyond deploying exactly what was committed.
///
/// @dev    One gate serves everyone: it takes no constructor arguments, holds no privilege of its own, and
///         holds none over anything it deploys, so it is the same contract at the same address on every
///         chain and whoever finds a chain without one deploys it themselves.
///
///         That rests on the gate being deployed through CREATE2, where the address covers the init code,
///         and not through CREATE3, where it does not: a CREATE3 gate address would be code anyone could
///         choose, and this contract's code is the whole of its authority.
contract DeployGate is IDeployGate {
    // Namespaces
    mapping(address namespace => uint256) public term;
    mapping(address namespace => uint256) public delay;
    mapping(address namespace => mapping(uint256 term => mapping(address who => bool))) internal _isDelegate;

    // Commitments
    mapping(address namespace => mapping(bytes32 id => uint256)) public nonce;
    mapping(address namespace => mapping(bytes32 id => uint256)) public deployed;
    mapping(bytes32 scope => mapping(uint256 nonce => uint256)) internal _deployableAt;
    mapping(bytes32 scope => mapping(uint256 nonce => mapping(address who => bool))) internal _executor;
    mapping(bytes32 scope => mapping(uint256 nonce => mapping(bytes32 salt => bytes32 hash))) internal _committed;

    //----------------------------------------------------------------------------------------------
    // Committing
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IDeployGate
    function commit(
        address namespace,
        bytes32 id,
        bytes32[] calldata salts,
        bytes32[] calldata initCodeHashes,
        address[] calldata executors
    ) external {
        require(msg.sender == namespace || isDelegate(namespace, msg.sender), NotAuthorized());
        require(salts.length == initCodeHashes.length, LengthMismatch());

        uint256 current = ++nonce[namespace][id];
        uint256 startsAt = _open(namespace, id, current, salts, initCodeHashes, executors);

        // One event for the whole commitment, so that it can be read back from a single log. It carries the
        // generation it opens, term and nonce together, which is what everything it grants is keyed by:
        // without them a reader has to count the commitments that came before to know which of them the gate
        // still enforces, and cannot tell a commitment a clearance has since emptied from a live one. The
        // moment it becomes deployable is here too, so that a monitor watching for what nobody meant to
        // commit reads the deadline it has to act by out of the same entry
        emit Commit(namespace, id, current, term[namespace], startsAt, salts, initCodeHashes, executors);
    }

    /// @dev Everything the commitment writes, kept out of `commit` so that what it logs still fits on the
    ///      stack beside it
    function _open(
        address namespace,
        bytes32 id,
        uint256 current,
        bytes32[] calldata salts,
        bytes32[] calldata initCodeHashes,
        address[] calldata executors
    ) internal returns (uint256 startsAt) {
        bytes32 scope = scopeOf(namespace, id);
        deployed[namespace][id] = 0;

        // What a namespace commits itself is deployable at once, and what it commits through a delegate
        // waits: the delay is the window in which a commitment nobody meant to make can still be cleared,
        // and a namespace needs none against itself. Zero is left unwritten, which is also what a commitment
        // made before the namespace had a delay reads as
        startsAt = msg.sender == namespace ? 0 : delay[namespace];
        if (startsAt != 0) {
            startsAt += block.timestamp;
            _deployableAt[scope][current] = startsAt;
        }

        for (uint256 i; i < executors.length; i++) {
            _executor[scope][current][executors[i]] = true;
        }

        for (uint256 i; i < salts.length; i++) {
            // A repeat would leave one entry behind two positions in the log, so what it says would stop
            // being what is enforceable, and only one of the two would be reachable
            require(_committed[scope][current][salts[i]] == 0, DuplicateSalt(salts[i]));

            _committed[scope][current][salts[i]] = commitment(initCodeHashes[i], i);
        }
    }

    /// @inheritdoc IDeployGate
    function setDelegate(address delegatee, bool isValid) external {
        _isDelegate[msg.sender][term[msg.sender]][delegatee] = isValid;
        emit SetDelegate(msg.sender, delegatee, isValid);
    }

    /// @inheritdoc IDeployGate
    function setDelay(uint256 seconds_) external {
        delay[msg.sender] = seconds_;
        emit SetDelay(msg.sender, seconds_);
    }

    /// @inheritdoc IDeployGate
    function clear() external {
        // Everything the namespace holds hangs off the term, delegations as much as commitments, so ending
        // the term is the whole of it: one write, whatever is in there and whoever put it there, and nothing
        // to enumerate first
        uint256 current = ++term[msg.sender];

        emit Clear(msg.sender, current);
    }

    //----------------------------------------------------------------------------------------------
    // Deployment
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IDeployGate
    function deploy(address namespace, bytes32 id, bytes32 salt, bytes calldata initCode)
        external
        returns (address target)
    {
        bytes32 scope = scopeOf(namespace, id);
        uint256 current = nonce[namespace][id];
        require(_executor[scope][current][msg.sender], NotExecutor());

        uint256 startsAt = _deployableAt[scope][current];
        require(block.timestamp >= startsAt, NotYetDeployable(startsAt));

        bytes32 expected = commitment(keccak256(initCode), deployed[namespace][id]);
        require(_committed[scope][current][salt] == expected, NotCommitted(salt));

        delete _committed[scope][current][salt];
        ++deployed[namespace][id];

        target = Create3.deploy(namespaceSalt(namespace, salt), initCode);
        emit Deploy(namespace, id, term[namespace], current, salt, target);
    }

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IDeployGate
    function isDelegate(address namespace, address who) public view returns (bool) {
        return _isDelegate[namespace][term[namespace]][who];
    }

    /// @inheritdoc IDeployGate
    function isExecutor(address namespace, bytes32 id, address who) external view returns (bool) {
        return _executor[scopeOf(namespace, id)][nonce[namespace][id]][who];
    }

    /// @inheritdoc IDeployGate
    function committed(address namespace, bytes32 id, bytes32 salt) external view returns (bytes32) {
        return _committed[scopeOf(namespace, id)][nonce[namespace][id]][salt];
    }

    /// @inheritdoc IDeployGate
    function deployableAt(address namespace, bytes32 id) external view returns (uint256) {
        return _deployableAt[scopeOf(namespace, id)][nonce[namespace][id]];
    }

    /// @inheritdoc IDeployGate
    function scopeOf(address namespace, bytes32 id) public view returns (bytes32) {
        return keccak256(abi.encode(namespace, term[namespace], id));
    }

    /// @inheritdoc IDeployGate
    function commitment(bytes32 initCodeHash, uint256 index) public pure returns (bytes32) {
        return keccak256(abi.encode(initCodeHash, index));
    }

    /// @inheritdoc IDeployGate
    function namespaceSalt(address namespace, bytes32 salt) public pure returns (bytes32) {
        return keccak256(abi.encode(namespace, salt));
    }

    /// @inheritdoc IDeployGate
    function addressOf(address namespace, bytes32 salt) external view returns (address) {
        return Create3.addressOf(namespaceSalt(namespace, salt), address(this));
    }
}
