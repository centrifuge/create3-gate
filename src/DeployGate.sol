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
    struct Namespace {
        uint64 term;
        uint64 delay;
    }

    mapping(address namespace => Namespace) internal _namespaces;
    mapping(address namespace => mapping(uint64 term => mapping(address who => bool))) internal _isDelegate;

    // Commitments
    struct Commitment {
        uint64 nonce;
        uint64 deployed;
        uint64 deployableAt;
    }

    mapping(address namespace => mapping(bytes32 id => Commitment)) internal _commitments;
    mapping(bytes32 scope => mapping(uint64 nonce => mapping(address who => bool))) internal _executor;
    mapping(bytes32 scope => mapping(uint64 nonce => mapping(bytes32 salt => bytes32 hash))) internal _committed;

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

        (uint64 current, uint64 startsAt, uint64 currentTerm) = _open(namespace, id, salts, initCodeHashes, executors);

        emit Commit(namespace, id, current, currentTerm, startsAt, salts, initCodeHashes, executors);
    }

    function _open(
        address namespace,
        bytes32 id,
        bytes32[] calldata salts,
        bytes32[] calldata initCodeHashes,
        address[] calldata executors
    ) internal returns (uint64 current, uint64 startsAt, uint64 currentTerm) {
        currentTerm = _namespaces[namespace].term;

        // A namespace's own commitment is deployable at once and a delegate's waits, which is the window in
        // which one nobody meant to make can still be cleared
        startsAt = msg.sender == namespace ? 0 : _namespaces[namespace].delay;
        if (startsAt != 0) startsAt += uint64(block.timestamp);

        Commitment storage commitment_ = _commitments[namespace][id];
        current = ++commitment_.nonce;
        commitment_.deployed = 0;
        commitment_.deployableAt = startsAt;

        bytes32 scope = _scopeOf(namespace, currentTerm, id);

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
        _isDelegate[msg.sender][_namespaces[msg.sender].term][delegatee] = isValid;
        emit SetDelegate(msg.sender, delegatee, isValid);
    }

    /// @inheritdoc IDeployGate
    function setDelay(uint64 seconds_) external {
        _namespaces[msg.sender].delay = seconds_;
        emit SetDelay(msg.sender, seconds_);
    }

    /// @inheritdoc IDeployGate
    function clear() external {
        // Delegations hang off the term as much as commitments do, so ending it is the whole of the call
        uint256 current = ++_namespaces[msg.sender].term;

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
        Commitment storage commitment_ = _commitments[namespace][id];
        uint64 currentTerm = _namespaces[namespace].term;
        bytes32 scope = _scopeOf(namespace, currentTerm, id);
        uint64 current = commitment_.nonce;
        require(_executor[scope][current][msg.sender], NotExecutor());

        uint64 startsAt = commitment_.deployableAt;
        require(block.timestamp >= startsAt, NotYetDeployable(startsAt));

        bytes32 expected = commitment(keccak256(initCode), commitment_.deployed);
        require(_committed[scope][current][salt] == expected, NotCommitted(salt));

        delete _committed[scope][current][salt];
        ++commitment_.deployed;

        target = Create3.deploy(namespaceSalt(namespace, salt), initCode);
        emit Deploy(namespace, id, currentTerm, current, salt, target);
    }

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IDeployGate
    function term(address namespace) external view returns (uint64) {
        return _namespaces[namespace].term;
    }

    /// @inheritdoc IDeployGate
    function delay(address namespace) external view returns (uint64) {
        return _namespaces[namespace].delay;
    }

    /// @inheritdoc IDeployGate
    function nonce(address namespace, bytes32 id) external view returns (uint64) {
        return _commitments[namespace][id].nonce;
    }

    /// @inheritdoc IDeployGate
    function deployed(address namespace, bytes32 id) external view returns (uint64) {
        return _commitments[namespace][id].deployed;
    }

    /// @inheritdoc IDeployGate
    function isDelegate(address namespace, address who) public view returns (bool) {
        return _isDelegate[namespace][_namespaces[namespace].term][who];
    }

    /// @inheritdoc IDeployGate
    function isExecutor(address namespace, bytes32 id, address who) external view returns (bool) {
        return _executor[scopeOf(namespace, id)][_commitments[namespace][id].nonce][who];
    }

    /// @inheritdoc IDeployGate
    function committed(address namespace, bytes32 id, bytes32 salt) external view returns (bytes32) {
        return _committed[scopeOf(namespace, id)][_commitments[namespace][id].nonce][salt];
    }

    /// @inheritdoc IDeployGate
    function deployableAt(address namespace, bytes32 id) external view returns (uint64) {
        return _commitments[namespace][id].deployableAt;
    }

    /// @inheritdoc IDeployGate
    function scopeOf(address namespace, bytes32 id) public view returns (bytes32) {
        return _scopeOf(namespace, _namespaces[namespace].term, id);
    }

    function _scopeOf(address namespace, uint64 term_, bytes32 id) internal pure returns (bytes32) {
        return keccak256(abi.encode(namespace, term_, id));
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
