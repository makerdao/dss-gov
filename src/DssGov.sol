// SPDX-License-Identifier: AGPL-3.0-or-later

/// DssGov.sol

// Copyright (C) 2020 Maker Ecosystem Growth Holdings, INC.
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

pragma solidity ^0.6.11;

interface TokenLike {
    function transferFrom(address, address, uint256) external;
    function transfer(address, uint256) external;
}

interface MintableTokenLike {
    function mint(address, uint256) external;
    function burn(address, uint256) external;
}

interface ExecLike {
    function delay() external view returns (uint256);
    function drop(address) external;
    function exec(address) external;
    function plot(address) external;
}

contract DssGov {

    /*** Structs ***/
    struct Proposal {
        uint256 blockNum;
        uint256 end;
        address exec;
        address action;
        uint256 totActive;
        uint256 totVotes;
        uint256 status;
        mapping(address => uint256) votes;
    }

    struct User {
        uint256                      deposit;            // MKR deposited
        address                      delegate;           // Delegated User
        uint256                      rights;             // Voting rights
        uint256                      active;             // 1 if User is active, otherwise 0
        uint256                      lastActivity;       // Last activity time
        uint256                      proposalUnlockTime; // Time to be able to free MKR or make a new proposal after making a proposal
        uint256                      voteUnlockTime;     // Time to be able to free MKR after voting
        uint256                      numSnapshots;       // Amount of snapshots
        mapping(uint256 => Snapshot) snapshots;          // Index => Snapshot
        mapping(bytes32 => uint256)  gasOwners;          // Source => Gas staked
    }

    struct Proposer {
        uint256 allowed;  // Allowed to propose without MKR deposit
        uint256 lastDay;  // Day of last proposal
        uint256 count;    // Number of proposals per day
    }

    struct Snapshot {
        uint256 fromBlock;
        uint256 rights;
    }

    /*** Storage ***/
    mapping(address => uint256)  public           wards;         // Authorized addresses
    uint256                      public           live;          // System liveness
    TokenLike                    public immutable govToken;      // MKR gov token
    MintableTokenLike            public immutable iouToken;      // IOU token
    uint256[]                    public           gasStorage;    // Gas storage reserve
    uint256                      public           totActive;     // Total active MKR
    uint256                      public           numProposals;  // Amount of Proposals
    mapping(uint256 => Proposal) public           proposals;     // Proposal Id => Proposal Info
    mapping(address => Proposer) public           proposers;     // Proposer Address => Proposer Info
    mapping(address => User)     public           users;         // User Address => User Info

    /*** Governance Params */
    uint256 public rightsLifetime;       // Delegated rights lifetime without activity of the delegated
    uint256 public delegationLifetime;   // Lifetime of delegation without activity of the MKR owner
    uint256 public proposalLockDuration; // Min time after making a proposal for a second one or freeing MKR
    uint256 public voteLockDuration;     // Min time after making a vote for freeing MKR
    uint256 public proposalLifetime;     // Duration of a proposal's validity
    uint256 public minGovStake;          // Min MKR stake for launching a vote
    uint256 public threshold;            // Min % of total locked MKR to approve a proposal
    uint256 public gasStakeAmt;          // Amount of gas to stake when executing ping
    uint256 public maxProposerAmount;    // Max amount of proposals that a proposer can do per calendar day

    /*** Getters */
    function votes(uint256 id, address usr)      external view returns (uint256) { return proposals[id].votes[usr];  }
    function gasOwners(address usr, bytes32 src) external view returns (uint256) { return users[usr].gasOwners[src]; }
    function gasStorageLength()                  external view returns (uint256) { return gasStorage.length; }
    function snapshots(address usr, uint256 num) external view returns (uint256, uint256) {
        return (users[usr].snapshots[num].fromBlock, users[usr].snapshots[num].rights);
    }

    /*** Constants */
    uint256 constant public LAUNCH_THRESHOLD   = 100000 ether;  // Min amount of totalActive MKR to launch the system
    uint256 constant public MIN_THRESHOLD      = 40;            // Min threshold value that admin can set
    uint256 constant public MAX_THRESHOLD      = 60;            // Max threshold value that admin can set
    uint256 constant public PROPOSAL_PENDING   = 0;             // New proposal created (being voted)
    uint256 constant public PROPOSAL_SCHEDULED = 1;             // Proposal scheduled for being executed
    uint256 constant public PROPOSAL_EXECUTED  = 2;             // Proposal already executed
    uint256 constant public PROPOSAL_CANCELLED = 3;             // Proposal cancelled

    /*** Events ***/
    event Rely(address indexed usr);
    event Deny(address indexed usr);
    event File(bytes32 indexed what, uint256 data);
    event AddProposer(address indexed usr);
    event RemoveProposer(address indexed usr);
    event MintGas(bytes32 indexed src, address indexed usr, uint256 amt);
    event BurnGas(bytes32 indexed src, address indexed usr, uint256 amt);
    event Delegate(address indexed owner, address indexed newDelegate);
    event Lock(address indexed usr, uint256 wad);
    event Free(address indexed usr, uint256 wad);
    event Clear(address indexed usr);
    event Ping(address indexed usr);
    event UpdateTotalActive(uint256 wad);
    event Launch();
    event Propose(address indexed exec, address indexed action, uint256 indexed id);
    event Vote(uint256 indexed id, uint256 indexed snapshotIndex, uint256 wad);
    event Plot(uint256 indexed id);
    event Exec(uint256 indexed id);
    event Drop(uint256 indexed id);

    /*** Modifiers ***/
    modifier auth {
        require(wards[msg.sender] == 1, "DssGov/not-authorized");
        _;
    }
    modifier warm {
        _;
        users[msg.sender].lastActivity = block.timestamp;
    }

    /*** Safe Math ***/
    function _add(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require((z = x + y) >= x);
    }
    function _sub(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require((z = x - y) <= x);
    }
    function _mul(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require(y == 0 || (z = x * y) / y == x);
    }
    function _max(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = x > y ? x : y;
    }

    /*** Internal Functions ***/
    function _save(address usr, uint256 wad) internal {
        uint256 num = users[usr].numSnapshots;
        if (num > 0 && users[usr].snapshots[num].fromBlock == block.number) {
            users[usr].snapshots[num].rights = wad;
        } else {
            users[usr].numSnapshots = num = _add(num, 1);
            users[usr].snapshots[num] = Snapshot(block.number, wad);
        }
    }

    function _mint(bytes32 src, address usr) internal {
        uint256 amt = gasStakeAmt;
        for (uint256 i = 0; i < amt; i++) {
            gasStorage.push(1);
        }
        users[usr].gasOwners[src] = amt;
        emit MintGas(src, usr, amt);
    }

    function _burn(bytes32 src, address usr) internal {
        uint256 l = gasStorage.length;
        uint256 amt = users[usr].gasOwners[src];
        for (uint256 i = 1; i <= amt; i++) {
            delete gasStorage[l - i]; // TODO: Verify if this is necessary
            gasStorage.pop();
        }
        users[usr].gasOwners[src] = 0;
        emit BurnGas(src, usr, amt);
    }

    function _getUserRights(address usr, uint256 index, uint256 blockNum) internal view returns (uint256 amount) {
        uint256 num = users[usr].numSnapshots;
        require(num >= index, "DssGov/not-existing-index");
        Snapshot memory snapshot = users[usr].snapshots[index];
        require(snapshot.fromBlock < blockNum, "DssGov/not-correct-snapshot-1"); // "<" protects for flash loans on voting
        require(index == num || users[usr].snapshots[index + 1].fromBlock > blockNum, "DssGov/not-correct-snapshot-2");

        amount = snapshot.rights;
    }


    /*** Constructor ***/
    constructor(address govToken_, address iouToken_) public {
        // Assign gov and iou tokens
        govToken = TokenLike(govToken_);
        iouToken = MintableTokenLike(iouToken_);

        // Authorize msg.sender
        wards[msg.sender] = 1;

        // Emit event
        emit Rely(msg.sender);
    }


    /*** External Functions ***/
    function rely(address usr) external auth {
        // Authorize usr
        wards[usr] = 1;

        // Emit event
        emit Rely(usr);
    }

    function deny(address usr) external auth {
        // Unauthorize usr
        wards[usr] = 0;

        // Emit event
        emit Deny(usr);
    }

    function file(bytes32 what, uint256 data) external auth {
        // Update parameter
        if (what == "rightsLifetime") rightsLifetime = data;
        else if (what == "delegationLifetime") delegationLifetime = data;
        else if (what == "proposalLockDuration") proposalLockDuration = data; // TODO: Define if we want to place a safe max time
        else if (what == "voteLockDuration") voteLockDuration = data;
        else if (what == "proposalLifetime") proposalLifetime = data;
        else if (what == "minGovStake") minGovStake = data;
        else if (what == "gasStakeAmt") gasStakeAmt = data;
        else if (what == "maxProposerAmount") maxProposerAmount = data;
        else if (what == "threshold") {
            require(data >= MIN_THRESHOLD && data <= MAX_THRESHOLD, "DssGov/threshold-not-safe-range");
            threshold = data;
        }
        else revert("DssGov/file-unrecognized-param");

        // Emit event
        emit File(what, data);
    }

    function addProposer(address usr) external auth {
        // Add new proposer address
        proposers[usr].allowed = 1;

        // Emit event
        emit AddProposer(usr);
    }

    function removeProposer(address usr) external auth {
        // Remove existing proposer address
        proposers[usr].allowed = 0;

        // Emit event
        emit RemoveProposer(usr);
    }

    function delegate(address owner, address newDelegated) external warm {
        // Get actual delegated address
        address oldDelegated = users[owner].delegate;
        // Verify it is not trying to set again the actual address
        require(newDelegated != oldDelegated, "DssGov/already-delegated");

        // Verify if the user is authorized to execute this change in delegation
        require(
            owner == msg.sender || // Owners can always change their own MKR delegation
            oldDelegated == msg.sender && newDelegated == address(0) || // Delegated users can always remove delegations to themselves
            _add(users[owner].lastActivity, delegationLifetime) < block.timestamp && newDelegated == address(0), // If there is inactivity anyone can remove delegations
            "DssGov/not-authorized-delegation"
        );

        // Set new delegated address
        users[owner].delegate = newDelegated;

        // Get owner's deposits
        uint256 deposit = users[owner].deposit;

        // Check if old and new delegated addresses are active
        bool activeOld = oldDelegated != address(0) && users[oldDelegated].active == 1;
        bool activeNew = newDelegated != address(0) && users[newDelegated].active == 1;

        // If both are active or inactive, do nothing. Otherwise update the totActive MKR and emit event
        if (activeOld && !activeNew) {
            totActive = _sub(totActive, deposit);
            emit UpdateTotalActive(totActive);
        } else if (!activeOld && activeNew) {
            totActive = _add(totActive, deposit);
            emit UpdateTotalActive(totActive);
        }

        // If already existed a delegated address
        if (oldDelegated != address(0)) {
            // Copy the vote lock to the user
            users[owner].voteUnlockTime = _max(users[owner].voteUnlockTime, users[oldDelegated].voteUnlockTime);
            // Remove owner's voting rights from old delegate
            users[oldDelegated].rights = _sub(users[oldDelegated].rights, deposit);
            // If active, save snapshot
            if(activeOld) {
                _save(oldDelegated, users[oldDelegated].rights);
            }
        } else {
            _mint("owner", owner);
        }

        // If setting to some delegated address
        if (newDelegated != address(0)) {
            // Add owner's voting rights to those of the new delegate
            users[newDelegated].rights = _add(users[newDelegated].rights, deposit);
            // If active, save snapshot
            if(activeNew) {
                _save(newDelegated, users[newDelegated].rights);
            }
        } else {
            _burn("owner", owner);
        }

        // Emit event
        emit Delegate(owner, newDelegated);
    }

    function lock(uint256 wad) external warm {
        // Pull MKR from sender's wallet
        govToken.transferFrom(msg.sender, address(this), wad);

        // Mint IOU tokens for the sender
        iouToken.mint(msg.sender, wad);

        // Increase amount deposited from sender
        users[msg.sender].deposit = _add(users[msg.sender].deposit, wad);

        // Get actual delegated address
        address delegated = users[msg.sender].delegate;

        // If there is some delegated address
        if (delegated != address(0)) {
            users[delegated].rights = _add(users[delegated].rights, wad);
            if (users[delegated].active == 1) {
                // Save user's snapshot
                _save(delegated, users[delegated].rights);
                // Update total active and emit event
                totActive = _add(totActive, wad);
                emit UpdateTotalActive(totActive);
            }
        }

        // Emit event
        emit Lock(msg.sender, wad);
    }

    function free(uint256 wad) external warm {
        // Check if user has not made recently a proposal
        require(users[msg.sender].proposalUnlockTime <= block.timestamp, "DssGov/user-locked");

        // Check if user has not voted recently
        require(users[msg.sender].voteUnlockTime <= block.timestamp, "DssGov/user-locked");

        // Burn the sender's IOU tokens
        iouToken.burn(msg.sender, wad);

        // Decrease amount deposited from user
        users[msg.sender].deposit = _sub(users[msg.sender].deposit, wad);

        // Get actual delegated address
        address delegated = users[msg.sender].delegate;

        // If there is some delegated address
        if (delegated != address(0)) {
            // Check if delegate has not voted recently
            require(users[delegated].voteUnlockTime <= block.timestamp, "DssGov/user-locked");

            users[delegated].rights = _sub(users[delegated].rights, wad);
            if (users[delegated].active == 1) {
                // Save user's snapshot
                _save(delegated, users[delegated].rights);
                // Update total active and emit event
                totActive = _sub(totActive, wad);
                emit UpdateTotalActive(totActive);
            }
        }

        // Push MKR back to user's wallet
        govToken.transfer(msg.sender, wad);

        // Emit event
        emit Free(msg.sender, wad);
    }

    function clear(address usr) external {
        // If already inactive return
        if  (users[usr].active == 0) return;

        // Check the delegated has not made any recent action
        require(_add(users[usr].lastActivity, rightsLifetime) < block.timestamp, "DssGov/not-allowed-to-clear");

        // Mark user as inactive
        users[usr].active = 0;

        // Remove the amount from the total active MKR and emit event
        uint256 r = users[usr].rights;
        totActive = _sub(totActive, r);
        emit UpdateTotalActive(totActive);

        // Save snapshot
        _save(usr, 0);

        // Burn gas storage reserve (refund for caller)
        _burn("delegated", usr);

        // Emit event
        emit Clear(usr);
    }

    function ping() external warm {
        // If already active return
        if (users[msg.sender].active == 1) return;

        // Mark the user as active
        users[msg.sender].active = 1;

        // Add the amount from the total active MKR and emit event
        uint256 r = users[msg.sender].rights;
        totActive = _add(totActive, r);
        emit UpdateTotalActive(totActive);

        // Save snapshot
        _save(msg.sender, r);

        // Mint gas storage reserve
        _mint("delegated", msg.sender);

        // Emit event
        emit Ping(msg.sender);
    }

    function launch() external warm {
        // Check system hasn't already been launched
        require(live == 0, "DssGov/already-launched");

        // Check totalActive MKR has passed the min Setup Threshold
        require(totActive >= LAUNCH_THRESHOLD, "DssGov/not-minimum");

        // Launch system
        live = 1;

        // Emit event
        emit Launch();
    }

    function propose(address exec, address action) external warm returns (uint256) {
        // Check system is live
        require(live == 1, "DssGov/not-launched");

        if (proposers[msg.sender].allowed == 1) { // If it is a proposer account
            // Get amount of proposals made by the proposer the last day
            uint256 lastDay = proposers[msg.sender].lastDay;
            uint256 count   = proposers[msg.sender].count;
            // Get today value
            uint256 today = block.timestamp / 1 days;
            // Get amount of proposals made today
            count = lastDay == today ? count : 0;
            // Check proposer hasn't already reached the maximum per day
            require(count < maxProposerAmount, "DssGov/max-amount-proposals-proposer"); // Max amount of proposals that a proposer can do per calendar day
            // Increment amount of proposals made
            proposers[msg.sender].lastDay = today;
            proposers[msg.sender].count = _add(count, 1);
        } else { // If not a proposer account
            // Check user has at least the min amount of MKR for creating a proposal
            uint256 deposit = users[msg.sender].deposit;
            require(deposit >= minGovStake, "DssGov/not-minimum-amount");

            // Check user has not made another proposal recently
            require(users[msg.sender].proposalUnlockTime <= block.timestamp, "DssGov/user-locked");

            // Update locked time
            users[msg.sender].proposalUnlockTime = _add(block.timestamp, proposalLockDuration);
        }

        // Add new proposal
        numProposals = _add(numProposals, 1);
        proposals[numProposals] = Proposal({
                blockNum: block.number,
                end: _add(block.timestamp, proposalLifetime),
                exec: exec,
                action: action,
                totActive: totActive,
                totVotes: 0,
                status: 0
        });

        // Emit event
        emit Propose(exec, action, numProposals);

        return numProposals;
    }

    function vote(uint256 id, uint256 snapshotIndex, uint256 wad) external warm {
        // Verify it hasn't been already plotted, not executed nor removed
        require(proposals[id].status == PROPOSAL_PENDING, "DssGov/wrong-status");
        // Verify proposal is not expired
        require(proposals[id].end >= block.timestamp, "DssGov/proposal-expired");
        // Verify amount for voting is lower or equal than voting rights
        require(wad <= _getUserRights(msg.sender, snapshotIndex, proposals[id].blockNum), "DssGov/amount-exceeds-rights");

        // Update locked time
        users[msg.sender].voteUnlockTime = _max(users[msg.sender].voteUnlockTime, _add(block.timestamp, voteLockDuration));

        uint256 prev = proposals[id].votes[msg.sender];
        // Update voting rights used by the user
        proposals[id].votes[msg.sender] = wad;
        // Update total votes to the proposal
        proposals[id].totVotes = _add(_sub(proposals[id].totVotes, prev), wad);

        emit Vote(id, snapshotIndex, wad);
    }

    function plot(uint256 id) external warm {
        // Verify it hasn't been already plotted or removed
        require(proposals[id].status == PROPOSAL_PENDING, "DssGov/wrong-status");
        // Verify proposal is not expired
        require(block.timestamp <= proposals[id].end, "DssGov/vote-expired");
        // Verify enough MKR is voting this proposal
        require(proposals[id].totVotes > _mul(proposals[id].totActive, threshold) / 100, "DssGov/not-enough-votes");

        // Plot action proposal
        proposals[id].status = PROPOSAL_SCHEDULED;
        ExecLike(proposals[id].exec).plot(proposals[id].action);

        // Emit event
        emit Plot(id);
    }

    function exec(uint256 id) external warm {
        // Verify it has been already plotted, but not executed or removed
        require(proposals[id].status == PROPOSAL_SCHEDULED, "DssGov/wrong-status");

        // Execute action proposal
        proposals[id].status = PROPOSAL_EXECUTED;
        ExecLike(proposals[id].exec).exec(proposals[id].action);

        // Emit event
        emit Exec(id);
    }

    function drop(uint256 id) external auth {
        // Verify it hasn't been already cancelled
        require(proposals[id].status < PROPOSAL_EXECUTED, "DssGov/wrong-status");

        // Drop action proposal
        proposals[id].status = PROPOSAL_CANCELLED;
        ExecLike(proposals[id].exec).drop(proposals[id].action);

        // Emit event
        emit Drop(id);
    }
}
