// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.3;

import {
    ReentrancyGuard
} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import { IERC20 } from "./interfaces/IERC20.sol";
import { IVotingEscrow } from "./interfaces/IVotingEscrow.sol";
import { IBlocklist } from "./interfaces/IBlocklist.sol";

/// @title  VotingEscrow
/// @author Curve Finance (MIT) - original concept and implementation in Vyper
///           (see https://github.com/curvefi/curve-dao-contracts/blob/master/contracts/VotingEscrow.vy)
///         mStable (AGPL) - forking Curve's Vyper contract and porting to Solidity
///           (see https://github.com/mstable/mStable-contracts/blob/master/contracts/governance/IncentivisedVotingLockup.sol)
///         FIAT DAO (AGPL) - this version
/// @notice Plain Curve VotingEscrow mechanics with following adjustments:
///            1) Delegation of lock and voting power
///            2) Quit an existing lock and pay a penalty
///            3) Whitelisting of SmartWallets outside the VotingEscrow
///            4) Reduced pointHistory array size and, as a result, lifetime of the contract
///            5) Removed public deposit_for and Aragon compatibility (no use case)
contract VotingEscrow is IVotingEscrow, ReentrancyGuard {
    // Shared Events
    event Deposit(
        address indexed provider,
        uint256 value,
        uint256 locktime,
        LockAction indexed action,
        uint256 ts
    );
    event Withdraw(
        address indexed provider,
        uint256 value,
        LockAction indexed action,
        uint256 ts
    );
    event TransferOwnership(address owner);
    event UpdateBlocklist(address blocklist);
    event UpdatePenaltyRecipient(address recipient);
    event CollectPenalty(uint256 amount, address recipient);
    event Unlock();

    // Shared global state
    IERC20 public immutable token;
    uint256 public constant WEEK = 7 days;
    uint256 public constant MAXTIME = 365 days;
    uint256 public constant MULTIPLIER = 1e18;
    address public owner;
    address public penaltyRecipient; // receives collected penalty payments
    uint256 public maxPenalty = 1e18; // penalty for quitters with MAXTIME remaining lock
    uint256 public penaltyAccumulated; // accumulated and unwithdrawn penalty payments
    address public blocklist;

    // Lock state
    uint256 public globalEpoch;
    Point[1000000000000000000] public pointHistory; // 1e9 * userPointHistory-length, so sufficient for 1e9 users
    mapping(address => Point[1000000000]) public userPointHistory;
    mapping(address => uint256) public userPointEpoch;
    mapping(uint256 => int128) public slopeChanges;
    mapping(address => LockedBalance) public locked;

    // Voting token
    string public name;
    string public symbol;
    uint256 public decimals;

    // Structs
    struct Point {
        int128 bias;
        int128 slope;
        uint256 ts;
        uint256 blk;
    }
    struct LockedBalance {
        int128 amount;
        int128 delegated;
        uint96 end;
        address delegatee;
    }

    // Miscellaneous
    enum LockAction {
        CREATE,
        INCREASE_AMOUNT,
        INCREASE_AMOUNT_AND_DELEGATION,
        INCREASE_TIME,
        WITHDRAW,
        QUIT,
        DELEGATE,
        UNDELEGATE
    }

    /// @notice Initializes state
    /// @param _owner The owner is able to update `owner`, `penaltyRecipient` and `penaltyRate`
    /// @param _penaltyRecipient The recipient of penalty paid by lock quitters
    /// @param _token The token locked in order to obtain voting power
    /// @param _name The name of the voting token
    /// @param _symbol The symbol of the voting token
    constructor(
        address _owner,
        address _penaltyRecipient,
        address _token,
        string memory _name,
        string memory _symbol
    ) {
        token = IERC20(_token);
        pointHistory[0] = Point({
            bias: int128(0),
            slope: int128(0),
            ts: block.timestamp,
            blk: block.number
        });

        decimals = IERC20(_token).decimals();
        require(decimals <= 18, "Exceeds max decimals");

        name = _name;
        symbol = _symbol;
        owner = _owner;
        penaltyRecipient = _penaltyRecipient;
    }

    modifier checkBlocklist() {
        require(
            !IBlocklist(blocklist).isBlocked(msg.sender),
            "Blocked contract"
        );
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    /// ~~~~~~~~~~~~~~~~~~~~~~~~~~~ ///
    ///       Owner Functions       ///
    /// ~~~~~~~~~~~~~~~~~~~~~~~~~~~ ///

    /// @notice Transfers ownership to a new owner
    /// @param _addr The new owner
    /// @dev Owner should always be a timelock contract
    function transferOwnership(address _addr) external onlyOwner {
        owner = _addr;
        emit TransferOwnership(_addr);
    }

    /// @notice Updates the blocklist contract
    function updateBlocklist(address _addr) external onlyOwner {
        blocklist = _addr;
        emit UpdateBlocklist(_addr);
    }

    /// @notice Updates the recipient of the accumulated penalty paid by quitters
    function updatePenaltyRecipient(address _addr) external onlyOwner {
        penaltyRecipient = _addr;
        emit UpdatePenaltyRecipient(_addr);
    }

    /// @notice Removes quitlock penalty by setting it to zero
    /// @dev This is an irreversible action
    function unlock() external onlyOwner {
        maxPenalty = 0;
        emit Unlock();
    }

    /// @notice Forces an undelegation of virtual balance for a blocked locker
    /// @dev Can only be called by the Blocklist contract (as part of a block)
    /// @dev This is an irreversible action
    function forceUndelegate(address _addr) external override {
        require(msg.sender == blocklist, "Only Blocklist");
        LockedBalance memory locked_ = locked[_addr];
        address delegatee = locked_.delegatee;
        int128 value = locked_.amount;

        if (delegatee != _addr && value > 0) {
            LockedBalance memory fromLocked;
            locked_.delegatee = _addr;
            fromLocked = locked[delegatee];
            _delegate(delegatee, fromLocked, value, LockAction.UNDELEGATE);
            _delegate(_addr, locked_, value, LockAction.DELEGATE);
        }
    }

    /// ~~~~~~~~~~~~~~~~~~~~~~~~~~~ ///
    ///       LOCK MANAGEMENT       ///
    /// ~~~~~~~~~~~~~~~~~~~~~~~~~~~ ///

    /// @notice Returns a user's lock expiration
    /// @param _addr The address of the user
    /// @return Expiration of the user's lock
    function lockEnd(address _addr) external view returns (uint256) {
        return locked[_addr].end;
    }

    /// @notice Returns the last available user point for a user
    /// @param _addr User address
    /// @return bias i.e. y
    /// @return slope i.e. linear gradient
    /// @return ts i.e. time point was logged
    function getLastUserPoint(address _addr)
        external
        view
        returns (
            int128 bias,
            int128 slope,
            uint256 ts
        )
    {
        uint256 uepoch = userPointEpoch[_addr];
        if (uepoch == 0) {
            return (0, 0, 0);
        }
        Point memory point = userPointHistory[_addr][uepoch];
        return (point.bias, point.slope, point.ts);
    }

    /// @notice Records a checkpoint of both individual and global slope
    /// @param _addr User address, or address(0) for only global
    /// @param _oldLocked Old amount that user had locked, or null for global
    /// @param _newLocked new amount that user has locked, or null for global
    function _checkpoint(
        address _addr,
        LockedBalance memory _oldLocked,
        LockedBalance memory _newLocked
    ) internal {
        Point memory userOldPoint;
        Point memory userNewPoint;
        int128 oldSlopeDelta = 0;
        int128 newSlopeDelta = 0;
        uint256 epoch = globalEpoch;

        if (_addr != address(0)) {
            // Calculate slopes and biases
            // Kept at zero when they have to
            if (_oldLocked.end > block.timestamp && _oldLocked.delegated > 0) {
                userOldPoint.slope =
                    _oldLocked.delegated /
                    int128(int256(MAXTIME));
                userOldPoint.bias =
                    userOldPoint.slope *
                    int128(int256(_oldLocked.end - block.timestamp));
            }
            if (_newLocked.end > block.timestamp && _newLocked.delegated > 0) {
                userNewPoint.slope =
                    _newLocked.delegated /
                    int128(int256(MAXTIME));
                userNewPoint.bias =
                    userNewPoint.slope *
                    int128(int256(_newLocked.end - block.timestamp));
            }

            // Moved from bottom final if statement to resolve stack too deep err
            // start {
            // Now handle user history
            uint256 uEpoch = userPointEpoch[_addr];
            if (uEpoch == 0) {
                userPointHistory[_addr][uEpoch + 1] = userOldPoint;
            }

            userPointEpoch[_addr] = uEpoch + 1;
            userNewPoint.ts = block.timestamp;
            userNewPoint.blk = block.number;
            userPointHistory[_addr][uEpoch + 1] = userNewPoint;

            // } end

            // Read values of scheduled changes in the slope
            // oldLocked.end can be in the past and in the future
            // newLocked.end can ONLY by in the FUTURE unless everything expired: than zeros
            oldSlopeDelta = slopeChanges[_oldLocked.end];
            if (_newLocked.end != 0) {
                if (_newLocked.end == _oldLocked.end) {
                    newSlopeDelta = oldSlopeDelta;
                } else {
                    newSlopeDelta = slopeChanges[_newLocked.end];
                }
            }
        }

        Point memory lastPoint =
            Point({
                bias: 0,
                slope: 0,
                ts: block.timestamp,
                blk: block.number
            });
        if (epoch > 0) {
            lastPoint = pointHistory[epoch];
        }
        uint256 lastCheckpoint = lastPoint.ts;

        // initialLastPoint is used for extrapolation to calculate block number
        // (approximately, for *At methods) and save them
        // as we cannot figure that out exactly from inside the contract
        Point memory initialLastPoint =
            Point({ bias: 0, slope: 0, ts: lastPoint.ts, blk: lastPoint.blk });
        uint256 blockSlope = 0; // dblock/dt
        if (block.timestamp > lastPoint.ts) {
            blockSlope =
                (MULTIPLIER * (block.number - lastPoint.blk)) /
                (block.timestamp - lastPoint.ts);
        }
        // If last point is already recorded in this block, slope=0
        // But that's ok b/c we know the block in such case

        // Go over weeks to fill history and calculate what the current point is
        uint256 iterativeTime = _floorToWeek(lastCheckpoint);
        for (uint256 i; i < 255; ) {
            // Hopefully it won't happen that this won't get used in 5 years!
            // If it does, users will be able to withdraw but vote weight will be broken
            iterativeTime = iterativeTime + WEEK;
            int128 dSlope = 0;
            if (iterativeTime > block.timestamp) {
                iterativeTime = block.timestamp;
            } else {
                dSlope = slopeChanges[iterativeTime];
            }
            int128 biasDelta =
                lastPoint.slope *
                    int128(int256((iterativeTime - lastCheckpoint)));
            lastPoint.bias = lastPoint.bias - biasDelta;
            lastPoint.slope = lastPoint.slope + dSlope;
            // This can happen
            if (lastPoint.bias < 0) {
                lastPoint.bias = 0;
            }
            // This cannot happen - just in case
            if (lastPoint.slope < 0) {
                lastPoint.slope = 0;
            }
            lastCheckpoint = iterativeTime;
            lastPoint.ts = iterativeTime;
            lastPoint.blk =
                initialLastPoint.blk +
                (blockSlope * (iterativeTime - initialLastPoint.ts)) /
                MULTIPLIER;

            // when epoch is incremented, we either push here or after slopes updated below
            epoch = epoch + 1;
            if (iterativeTime == block.timestamp) {
                lastPoint.blk = block.number;
                break;
            } else {
                pointHistory[epoch] = lastPoint;
            }
            unchecked { ++i; }
        }

        globalEpoch = epoch;
        // Now pointHistory is filled until t=now

        if (_addr != address(0)) {
            // If last point was in this block, the slope change has been applied already
            // But in such case we have 0 slope(s)
            lastPoint.slope =
                lastPoint.slope +
                userNewPoint.slope -
                userOldPoint.slope;
            lastPoint.bias =
                lastPoint.bias +
                userNewPoint.bias -
                userOldPoint.bias;
            if (lastPoint.slope < 0) {
                lastPoint.slope = 0;
            }
            if (lastPoint.bias < 0) {
                lastPoint.bias = 0;
            }
        }

        // Record the changed point into history
        pointHistory[epoch] = lastPoint;

        if (_addr != address(0)) {
            // Schedule the slope changes (slope is going down)
            // We subtract new_user_slope from [new_locked.end]
            // and add old_user_slope to [old_locked.end]
            if (_oldLocked.end > block.timestamp) {
                // oldSlopeDelta was <something> - userOldPoint.slope, so we cancel that
                oldSlopeDelta = oldSlopeDelta + userOldPoint.slope;
                if (_newLocked.end == _oldLocked.end) {
                    oldSlopeDelta = oldSlopeDelta - userNewPoint.slope; // It was a new deposit, not extension
                }
                slopeChanges[_oldLocked.end] = oldSlopeDelta;
            }
            if (_newLocked.end > block.timestamp) {
                if (_newLocked.end > _oldLocked.end) {
                    newSlopeDelta = newSlopeDelta - userNewPoint.slope; // old slope disappeared at this point
                    slopeChanges[_newLocked.end] = newSlopeDelta;
                }
                // else: we recorded it already in oldSlopeDelta
            }
        }
    }

    /// @notice Public function to trigger global checkpoint
    function checkpoint() external {
        LockedBalance memory empty;
        _checkpoint(address(0), empty, empty);
    }

    // See IVotingEscrow for documentation
    function createLock(uint256 _value, uint256 _unlockTime)
        external
        override
        nonReentrant
        checkBlocklist
    {
        uint256 unlock_time = _floorToWeek(_unlockTime); // Locktime is rounded down to weeks
        LockedBalance memory locked_ = locked[msg.sender];
        // Validate inputs
        require(_value != 0, "Only non zero amount");
        require(locked_.amount == 0, "Lock exists");
        require(unlock_time >= locked_.end, "Only increase lock end"); // from using quitLock, user should increaseAmount instead
        require(unlock_time > block.timestamp, "Only future lock end");
        require(unlock_time <= block.timestamp + MAXTIME, "Exceeds maxtime");
        // Update lock and voting power (checkpoint)
        locked_.amount = locked_.amount + int128(int256(_value));
        locked_.end = uint96(unlock_time);
        locked_.delegated = locked_.delegated + int128(int256(_value));
        locked_.delegatee = msg.sender;
        locked[msg.sender] = locked_;
        _checkpoint(msg.sender, LockedBalance(0, 0, 0, address(0)), locked_);
        // Deposit locked tokens
        require(
            token.transferFrom(msg.sender, address(this), _value),
            "Transfer failed"
        );
        emit Deposit(
            msg.sender,
            _value,
            unlock_time,
            LockAction.CREATE,
            block.timestamp
        );
    }

    // See IVotingEscrow for documentation
    // @dev A lock is active until both lock.amount==0 and lock.end<=block.timestamp
    function increaseAmount(uint256 _value)
        external
        override
        nonReentrant
        checkBlocklist
    {
        LockedBalance memory locked_ = locked[msg.sender];
        // Validate inputs
        require(_value != 0, "Only non zero amount");
        require(locked_.amount > 0, "No lock");
        require(locked_.end > block.timestamp, "Lock expired");
        // Update lock
        address delegatee = locked_.delegatee;
        uint256 unlockTime = locked_.end;
        LockAction action = LockAction.INCREASE_AMOUNT;
        LockedBalance memory newLocked;
        if (delegatee == msg.sender) {
            // Undelegated lock
            action = LockAction.INCREASE_AMOUNT_AND_DELEGATION;
            newLocked = _copyLock(locked_);
            newLocked.amount = newLocked.amount + int128(int256(_value));
            newLocked.delegated = newLocked.delegated + int128(int256(_value));
            locked[msg.sender] = newLocked;
        } else {
            // Delegated lock, update sender's lock first
            locked_.amount = locked_.amount + int128(int256(_value));
            locked[msg.sender] = locked_;
            // Then, update delegatee's lock and voting power (checkpoint)
            locked_ = locked[delegatee];
            require(locked_.amount > 0, "Delegatee has no lock");
            require(locked_.end > block.timestamp, "Delegatee lock expired");
            newLocked = _copyLock(locked_);
            newLocked.delegated = newLocked.delegated + int128(int256(_value));
            locked[delegatee] = newLocked;
            emit Deposit(
                delegatee,
                _value,
                newLocked.end,
                LockAction.DELEGATE,
                block.timestamp
            );
        }
        // Checkpoint only for delegatee
        _checkpoint(delegatee, locked_, newLocked);
        // Deposit locked tokens
        require(
            token.transferFrom(msg.sender, address(this), _value),
            "Transfer failed"
        );
        emit Deposit(msg.sender, _value, unlockTime, action, block.timestamp);
    }

    // See IVotingEscrow for documentation
    function increaseUnlockTime(uint256 _unlockTime)
        external
        override
        nonReentrant
        checkBlocklist
    {
        LockedBalance memory locked_ = locked[msg.sender];
        uint256 unlock_time = _floorToWeek(_unlockTime); // Locktime is rounded down to weeks
        // Validate inputs
        require(locked_.amount > 0, "No lock");
        require(unlock_time > locked_.end, "Only increase lock end");
        require(unlock_time <= block.timestamp + MAXTIME, "Exceeds maxtime");
        // Update lock
        uint256 oldUnlockTime = locked_.end;
        locked_.end = uint96(unlock_time);
        locked[msg.sender] = locked_;
        if (locked_.delegatee == msg.sender) {
            // Undelegated lock
            require(oldUnlockTime > block.timestamp, "Lock expired");
            LockedBalance memory oldLocked = _copyLock(locked_);
            oldLocked.end = uint96(unlock_time);
            _checkpoint(msg.sender, oldLocked, locked_);
        }
        emit Deposit(
            msg.sender,
            0,
            unlock_time,
            LockAction.INCREASE_TIME,
            block.timestamp
        );
    }

    // See IVotingEscrow for documentation
    function withdraw() external override nonReentrant {
        LockedBalance memory locked_ = locked[msg.sender];
        // Validate inputs
        require(locked_.amount > 0, "No lock");
        require(locked_.end <= block.timestamp, "Lock not expired");
        require(locked_.delegatee == msg.sender, "Lock delegated");
        // Update lock
        uint256 value = uint256(uint128(locked_.amount));
        LockedBalance memory newLocked = _copyLock(locked_);
        newLocked.amount = 0;
        newLocked.end = 0;
        newLocked.delegated = newLocked.delegated - int128(int256(value));
        newLocked.delegatee = address(0);
        locked[msg.sender] = newLocked;
        newLocked.delegated = 0;
        // oldLocked can have either expired <= timestamp or zero end
        // currentLock has only 0 end
        // Both can have >= 0 amount
        _checkpoint(msg.sender, locked_, newLocked);
        // Send back deposited tokens
        require(token.transfer(msg.sender, value), "Transfer failed");
        emit Withdraw(msg.sender, value, LockAction.WITHDRAW, block.timestamp);
    }

    /// ~~~~~~~~~~~~~~~~~~~~~~~~~~ ///
    ///         DELEGATION         ///
    /// ~~~~~~~~~~~~~~~~~~~~~~~~~~ ///

    // See IVotingEscrow for documentation
    function delegate(address _addr)
        external
        override
        nonReentrant
        checkBlocklist
    {
        LockedBalance memory locked_ = locked[msg.sender];
        // Validate inputs
        require(!IBlocklist(blocklist).isBlocked(_addr), "Blocked contract");
        require(locked_.amount > 0, "No lock");
        require(locked_.delegatee != _addr, "Already delegated");
        // Update locks
        int128 value = locked_.amount;
        address delegatee = locked_.delegatee;
        LockedBalance memory fromLocked;
        LockedBalance memory toLocked;
        locked_.delegatee = _addr;
        if (delegatee == msg.sender) {
            // Delegate
            fromLocked = locked_;
            toLocked = locked[_addr];
        } else if (_addr == msg.sender) {
            // Undelegate
            fromLocked = locked[delegatee];
            toLocked = locked_;
        } else {
            // Re-delegate
            fromLocked = locked[delegatee];
            toLocked = locked[_addr];
            // Update owner lock if not involved in delegation
            locked[msg.sender] = locked_;
        }
        require(toLocked.amount > 0, "Delegatee has no lock");
        require(toLocked.end > block.timestamp, "Delegatee lock expired");
        require(toLocked.end >= fromLocked.end, "Only delegate to longer lock");
        _delegate(delegatee, fromLocked, value, LockAction.UNDELEGATE);
        _delegate(_addr, toLocked, value, LockAction.DELEGATE);
    }

    // Delegates from/to lock and voting power
    function _delegate(
        address addr,
        LockedBalance memory _locked,
        int128 value,
        LockAction action
    ) internal {
        LockedBalance memory newLocked = _copyLock(_locked);
        if (action == LockAction.DELEGATE) {
            newLocked.delegated = newLocked.delegated + value;
            emit Deposit(
                addr,
                uint256(int256(value)),
                newLocked.end,
                action,
                block.timestamp
            );
        } else {
            newLocked.delegated = newLocked.delegated - value;
            emit Withdraw(
                addr,
                uint256(int256(value)),
                action,
                block.timestamp
            );
        }
        locked[addr] = newLocked;
        if (newLocked.amount > 0) {
            // Only if lock (from lock) hasn't been withdrawn/quitted
            _checkpoint(addr, _locked, newLocked);
        }
    }

    /// ~~~~~~~~~~~~~~~~~~~~~~~~~~ ///
    ///         QUIT LOCK          ///
    /// ~~~~~~~~~~~~~~~~~~~~~~~~~~ ///

    // See IVotingEscrow for documentation
    function quitLock() external override nonReentrant {
        LockedBalance memory locked_ = locked[msg.sender];
        // Validate inputs
        require(locked_.amount > 0, "No lock");
        require(locked_.end > block.timestamp, "Lock expired");
        require(locked_.delegatee == msg.sender, "Lock delegated");
        // Update lock
        uint256 value = uint256(uint128(locked_.amount));
        LockedBalance memory newLocked = _copyLock(locked_);
        newLocked.amount = 0;
        newLocked.delegated -= int128(int256(value));
        newLocked.delegatee = address(0);
        locked[msg.sender] = newLocked;
        newLocked.end = 0;
        newLocked.delegated = 0;
        // oldLocked can have either expired <= timestamp or zero end
        // currentLock has only 0 end
        // Both can have >= 0 amount
        _checkpoint(msg.sender, locked_, newLocked);
        // apply penalty
        uint256 penaltyRate = _calculatePenaltyRate(locked_.end);
        uint256 penaltyAmount = (value * penaltyRate) / 1e18; // quitlock_penalty is in 18 decimals precision
        penaltyAccumulated = penaltyAccumulated + penaltyAmount;
        uint256 remainingAmount = value - penaltyAmount;
        // Send back remaining tokens
        require(token.transfer(msg.sender, remainingAmount), "Transfer failed");
        emit Withdraw(msg.sender, value, LockAction.QUIT, block.timestamp);
    }

    // Calculate penalty rate (decreasing linearly)
    function _calculatePenaltyRate(uint256 end)
        internal
        view
        returns (uint256)
    {
        // We know that end > block.timestamp because expired locks cannot be quitted
        return ((end - block.timestamp) * maxPenalty) / MAXTIME;
    }

    /// @notice Collect accumulated penalty from quitters
    /// @dev Everyone can collect but penalty is sent to `penaltyRecipient`
    function collectPenalty() external {
        uint256 amount = penaltyAccumulated;
        penaltyAccumulated = 0;
        address recipient = penaltyRecipient;
        require(token.transfer(recipient, amount), "Transfer failed");
        emit CollectPenalty(amount, recipient);
    }

    /// ~~~~~~~~~~~~~~~~~~~~~~~~~~ ///
    ///            GETTERS         ///
    /// ~~~~~~~~~~~~~~~~~~~~~~~~~~ ///

    // Creates a copy of a lock
    function _copyLock(LockedBalance memory _locked)
        internal
        pure
        returns (LockedBalance memory)
    {
        return
            LockedBalance({
                amount: _locked.amount,
                end: _locked.end,
                delegatee: _locked.delegatee,
                delegated: _locked.delegated
            });
    }

    // @dev Floors a timestamp to the nearest weekly increment
    // @param _t Timestamp to floor
    function _floorToWeek(uint256 _t) internal pure returns (uint256) {
        return (_t / WEEK) * WEEK;
    }

    // @dev Uses binarysearch to find the most recent point history preceeding block
    // @param _block Find the most recent point history before this block
    // @param _maxEpoch Do not search pointHistories past this index
    function _findBlockEpoch(uint256 _block, uint256 _maxEpoch)
        internal
        view
        returns (uint256)
    {
        // Binary search
        uint256 min = 0;
        uint256 max = _maxEpoch;
        // Will be always enough for 128-bit numbers
        for (uint256 i; i < 128; ) {
            if (min >= max) break;
            uint256 mid = (min + max + 1) / 2;
            if (pointHistory[mid].blk <= _block) {
                min = mid;
            } else {
                max = mid - 1;
            }
            unchecked { ++i; }
        }
        return min;
    }

    // @dev Uses binarysearch to find the most recent user point history preceeding block
    // @param _addr User for which to search
    // @param _block Find the most recent point history before this block
    function _findUserBlockEpoch(address _addr, uint256 _block)
        internal
        view
        returns (uint256)
    {
        uint256 min = 0;
        uint256 max = userPointEpoch[_addr];
        for (uint256 i; i < 128; ) {
            if (min >= max) {
                break;
            }
            uint256 mid = (min + max + 1) / 2;
            if (userPointHistory[_addr][mid].blk <= _block) {
                min = mid;
            } else {
                max = mid - 1;
            }
            unchecked { ++i; }
        }
        return min;
    }

    // See IVotingEscrow for documentation
    function balanceOf(address _owner) public view override returns (uint256) {
        uint256 epoch = userPointEpoch[_owner];
        if (epoch == 0) {
            return 0;
        }
        Point memory lastPoint = userPointHistory[_owner][epoch];
        lastPoint.bias =
            lastPoint.bias -
            (lastPoint.slope * int128(int256(block.timestamp - lastPoint.ts)));
        if (lastPoint.bias < 0) {
            lastPoint.bias = 0;
        }
        return uint256(uint128(lastPoint.bias));
    }

    // See IVotingEscrow for documentation
    function balanceOfAt(address _owner, uint256 _blockNumber)
        public
        view
        override
        returns (uint256)
    {
        require(_blockNumber <= block.number, "Only past block number");

        // Get most recent user Point to block
        uint256 userEpoch = _findUserBlockEpoch(_owner, _blockNumber);
        if (userEpoch == 0) {
            return 0;
        }
        Point memory upoint = userPointHistory[_owner][userEpoch];

        // Get most recent global Point to block
        uint256 maxEpoch = globalEpoch;
        uint256 epoch = _findBlockEpoch(_blockNumber, maxEpoch);
        Point memory point0 = pointHistory[epoch];

        // Calculate delta (block & time) between user Point and target block
        // Allowing us to calculate the average seconds per block between
        // the two points
        uint256 dBlock = 0;
        uint256 dTime = 0;
        if (epoch < maxEpoch) {
            Point memory point1 = pointHistory[epoch + 1];
            dBlock = point1.blk - point0.blk;
            dTime = point1.ts - point0.ts;
        } else {
            dBlock = block.number - point0.blk;
            dTime = block.timestamp - point0.ts;
        }
        // (Deterministically) Estimate the time at which block _blockNumber was mined
        uint256 blockTime = point0.ts;
        if (dBlock != 0) {
            blockTime =
                blockTime +
                ((dTime * (_blockNumber - point0.blk)) / dBlock);
        }
        // Current Bias = most recent bias - (slope * time since update)
        upoint.bias =
            upoint.bias -
            (upoint.slope * int128(int256(blockTime - upoint.ts)));
        if (upoint.bias >= 0) {
            return uint256(uint128(upoint.bias));
        } else {
            return 0;
        }
    }

    /// @notice Calculate total supply of voting power at a given time _t
    /// @param _point Most recent point before time _t
    /// @param _t Time at which to calculate supply
    /// @return totalSupply at given point in time
    function _supplyAt(Point memory _point, uint256 _t)
        internal
        view
        returns (uint256)
    {
        Point memory lastPoint = _point;
        // Floor the timestamp to weekly interval
        uint256 iterativeTime = _floorToWeek(lastPoint.ts);
        // Iterate through all weeks between _point & _t to account for slope changes
        for (uint256 i; i < 255; ) {
            iterativeTime = iterativeTime + WEEK;
            int128 dSlope = 0;
            // If week end is after timestamp, then truncate & leave dSlope to 0
            if (iterativeTime > _t) {
                iterativeTime = _t;
            }
            // else get most recent slope change
            else {
                dSlope = slopeChanges[iterativeTime];
            }

            lastPoint.bias =
                lastPoint.bias -
                (lastPoint.slope *
                    int128(int256(iterativeTime - lastPoint.ts)));
            if (iterativeTime == _t) {
                break;
            }
            lastPoint.slope = lastPoint.slope + dSlope;
            lastPoint.ts = iterativeTime;

            unchecked { ++i; }
        }

        if (lastPoint.bias < 0) {
            lastPoint.bias = 0;
        }
        return uint256(uint128(lastPoint.bias));
    }

    // See IVotingEscrow for documentation
    function totalSupply() public view override returns (uint256) {
        uint256 epoch_ = globalEpoch;
        Point memory lastPoint = pointHistory[epoch_];
        return _supplyAt(lastPoint, block.timestamp);
    }

    // See IVotingEscrow for documentation
    function totalSupplyAt(uint256 _blockNumber)
        public
        view
        override
        returns (uint256)
    {
        require(_blockNumber <= block.number, "Only past block number");

        uint256 epoch = globalEpoch;
        uint256 targetEpoch = _findBlockEpoch(_blockNumber, epoch);

        Point memory point = pointHistory[targetEpoch];

        // If point.blk > _blockNumber that means we got the initial epoch & contract did not yet exist
        if (point.blk > _blockNumber) {
            return 0;
        }

        uint256 dTime = 0;
        if (targetEpoch < epoch) {
            Point memory pointNext = pointHistory[targetEpoch + 1];
            if (point.blk != pointNext.blk) {
                dTime =
                    ((_blockNumber - point.blk) * (pointNext.ts - point.ts)) /
                    (pointNext.blk - point.blk);
            }
        } else if (point.blk != block.number) {
            dTime =
                ((_blockNumber - point.blk) * (block.timestamp - point.ts)) /
                (block.number - point.blk);
        }
        // Now dTime contains info on how far are we beyond point
        return _supplyAt(point, point.ts + dTime);
    }
}
