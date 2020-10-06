pragma solidity ^0.6.7;

interface TokenLike {
    function transferFrom(address, address, uint256) external;
    function transfer(address, uint256) external;
}

interface ExecLike {
    function delay() external view returns (uint256);
    function drop(address) external;
    function exec(address) external;
    function plot(address) external;
}

contract DssGov {

    // Structs:

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

    struct Snapshot {
        uint256 fromBlock;
        uint256 rights;
    }

    struct ProposerDayAmount {
        uint256 lastDay;
        uint256 count;
    }

    // Storage variables:

    mapping(address => uint256)                      public wards;               // Authorized addresses
    uint256                                          public live;                // System liveness
    TokenLike                                        public govToken;            // MKR gov token
    uint256[]                                        public gasStorage;          // Gas storage reserve
    mapping(address => mapping(bytes32 => uint256))  public gasOwners;           // User => Source => Gas staked
    mapping(address => uint256)                      public deposits;            // User => MKR deposited
    mapping(address => address)                      public delegates;           // User => Delegated User
    mapping(address => uint256)                      public rights;              // User => Voting rights
    uint256                                          public totActive;           // Total active MKR
    mapping(address => uint256)                      public active;              // User => 1 if User is active, otherwise 0
    mapping(address => uint256)                      public lastActivity;        // User => Last activity time
    mapping(address => uint256)                      public unlockTime;          // User => Time to be able to free MKR or make a new proposal
    mapping(address => uint256)                      public proposers;           // Proposer => Allowed to propose without MKR deposit
    mapping(address => ProposerDayAmount)            public proposerDayAmounts;  // Proposer => Proposer Day Amount (last day, amount)
    uint256                                          public numProposals;        // Amount of Proposals
    mapping(uint256 => Proposal)                     public proposals;           // Proposal Id => Proposal Info
    mapping(address => uint256)                      public numSnapshots;        // User => Amount of snapshots
    mapping(address => mapping(uint256 => Snapshot)) public snapshots;           // User => Index => Snapshot
    // Admin params
    uint256                                          public rightsLifetime;      // Delegated rights lifetime without activity of the delegated
    uint256                                          public delegationLifetime;  // Lifetime of delegation without activity of the MKR owner
    uint256                                          public lockDuration;        // Min time after making a proposal for a second one or freeing MKR
    uint256                                          public proposalLifetime;    // Duration of a proposal's validity
    uint256                                          public minGovStake;         // Min MKR stake for launching a vote
    uint256                                          public threshold;           // Min % of total locked MKR to approve a proposal
    uint256                                          public gasStakeAmt;         // Amount of gas to stake when executing ping
    uint256                                          public maxProposerAmount;   // Max amount of proposals that a proposer can do per calendar day
    //


    // Extra getters:

    function getVotes(uint256 id, address usr) external view returns (uint256) { return proposals[id].votes[usr]; }
    function gasStorageLength() external view returns(uint256) { return gasStorage.length; }


    // Constants:

    uint256 constant public LAUNCH_THRESHOLD    = 100000 ether; // Min amount of totalActive MKR to launch the system
    uint256 constant public MIN_THRESHOLD       = 40;           // Min threshold value that admin can set
    uint256 constant public MAX_THRESHOLD       = 60;           // Max threshold value that admin can set
    uint256 constant public PROPOSAL_PENDING    = 0;            // New proposal created (being voted)
    uint256 constant public PROPOSAL_SCHEDULED  = 1;            // Proposal scheduled for being executed
    uint256 constant public PROPOSAL_EXECUTED   = 2;            // Proposal already executed
    uint256 constant public PROPOSAL_CANCELLED  = 3;            // Proposal cancelled


    // Modifiers:

    modifier auth {
        require(wards[msg.sender] == 1, "DssGov/not-authorized");
        _;
    }

    modifier warm {
        _;
        lastActivity[msg.sender] = block.timestamp;
    }


    // Internal functions:

    function _add(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require((z = x + y) >= x);
    }

    function _sub(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require((z = x - y) <= x);
    }

    function _mul(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require(y == 0 || (z = x * y) / y == x);
    }

    function _save(address usr, uint256 wad) internal {
        uint256 num = numSnapshots[usr];
        if (num > 0 && snapshots[usr][num].fromBlock == block.number) {
            snapshots[usr][num].rights = wad;
        } else {
            numSnapshots[usr] = num = _add(num, 1);
            snapshots[usr][num] = Snapshot(block.number, wad);
        }
    }

    function _mint(bytes32 src, address usr) internal {
        for (uint256 i = 0; i < gasStakeAmt; i++) {
            gasStorage.push(1);
        }
        gasOwners[usr][src] = gasStakeAmt;
    }

    function _burn(bytes32 src, address usr) internal {
        uint256 l = gasStorage.length;
        for (uint256 i = 1; i <= gasOwners[usr][src]; i++) {
            delete gasStorage[l - i]; // TODO: Verify if this is necessary
            gasStorage.pop();
        }
        gasOwners[usr][src] = 0;
    }

    function _getUserRights(address usr, uint256 index, uint256 blockNum) internal view returns (uint256 amount) {
        uint256 num = numSnapshots[usr];
        require(num >= index, "DssGov/not-existing-index");
        Snapshot memory snapshot = snapshots[usr][index];
        require(snapshot.fromBlock < blockNum, "DssGov/not-correct-snapshot-1"); // "<" protects for flash loans on voting
        require(index == num || snapshots[usr][index + 1].fromBlock >= blockNum, "DssGov/not-correct-snapshot-2");

        amount = snapshot.rights;
    }


    // Constructor:

    constructor(address govToken_) public {
        govToken = TokenLike(govToken_);
        wards[msg.sender] = 1;
    }


    // External functions:

    function rely(address usr) external auth {
        wards[usr] = 1;
    }

    function deny(address usr) external auth {
        wards[usr] = 0;
    }

    function file(bytes32 what, uint256 data) external auth {
        if (what == "rightsLifetime") rightsLifetime = data;
        else if (what == "delegationLifetime") delegationLifetime = data;
        else if (what == "lockDuration") lockDuration = data; // TODO: Define if we want to place a safe max time
        else if (what == "proposalLifetime") proposalLifetime = data;
        else if (what == "minGovStake") minGovStake = data;
        else if (what == "gasStakeAmt") gasStakeAmt = data;
        else if (what == "maxProposerAmount") maxProposerAmount = data;
        else if (what == "threshold") {
            require(data >= MIN_THRESHOLD && data <= MAX_THRESHOLD, "DssGov/threshold-not-safe-range");
            threshold = data;
        }
        else revert("DssGov/file-unrecognized-param");
    }

    function addProposer(address usr) external auth {
        proposers[usr] = 1;
    }

    function removeProposer(address usr) external auth {
        proposers[usr] = 0;
    }

    function delegate(address owner, address newDelegated) external warm {
        // Get actual delegated address
        address oldDelegated = delegates[owner];
        // Verify it is not trying to set again the actual address
        require(newDelegated != oldDelegated, "DssGov-already-delegated");

        // Verify if the user is authorized to execute this change in delegation
        require(
            owner == msg.sender || // Owners can always change their own MKR delegation
            oldDelegated == msg.sender && newDelegated == address(0) || // Delegated users can always remove delegations to themselves
            _add(lastActivity[owner], delegationLifetime) < block.timestamp && newDelegated == address(0), // If there is inactivity anyone can remove delegations
            "DssGov/not-authorized-delegation"
        );

        // Set new delegated address
        delegates[owner] = newDelegated;

        // Get owner's deposits
        uint256 deposit = deposits[owner];

        // Check if old and new delegated addresses are active
        bool activeOld = oldDelegated != address(0) && active[oldDelegated] == 1;
        bool activeNew = newDelegated != address(0) && active[newDelegated] == 1;

        // If both are active or inactive, do nothing. Otherwise update the totActive MKR
        if (activeOld && !activeNew) {
            totActive = _sub(totActive, deposit);
        } else if (!activeOld && activeNew) {
            totActive = _add(totActive, deposit);
        }

        // If already existed a delegated address
        if (oldDelegated != address(0)) {
            // Remove sender's deposits owner old delegated's voting rights
            rights[oldDelegated] = _sub(rights[oldDelegated], deposit);
            // If active, save snapshot
            if(activeOld) {
                _save(oldDelegated, rights[oldDelegated]);
            }
        } else {
            _mint("owner", owner);
        }

        // If setting to some delegated address
        if (newDelegated != address(0)) {
            // Add sender's deposits to the new delegated's voting rights
            rights[newDelegated] = _add(rights[newDelegated], deposit);
            // If active, save snapshot
            if(activeNew) {
                _save(newDelegated, rights[newDelegated]);
            }
        } else {
            _burn("owner", owner);
        }
    }

    function lock(uint256 wad) external warm {
        // Pull MKR from sender's wallet
        govToken.transferFrom(msg.sender, address(this), wad);

        // Increase amount deposited from sender
        deposits[msg.sender] = _add(deposits[msg.sender], wad);

        // Get actual delegated address
        address delegated = delegates[msg.sender];

        // If there is some delegated address
        if (delegated != address(0)) {
            rights[delegated] = _add(rights[delegated], wad);
            if (active[delegated] == 1) {
                _save(delegated, rights[delegated]);
                totActive = _add(totActive, wad);
            }
        }
    }

    function free(uint256 wad) external warm {
        // Check if user has not made recently a proposal
        require(unlockTime[msg.sender] <= block.timestamp, "DssGov/user-locked");

        // Decrease amount deposited from user
        deposits[msg.sender] = _sub(deposits[msg.sender], wad);

        // Get actual delegated address
        address delegated = delegates[msg.sender];

        // If there is some delegated address
        if (delegated != address(0)) {
            rights[delegated] = _sub(rights[delegated], wad);
            if (active[delegated] == 1) {
                _save(delegated, rights[delegated]);
                totActive = _sub(totActive, wad);
            }
        }

        // Push MKR back to user's wallet
        govToken.transfer(msg.sender, wad);
    }

    function clear(address usr) external {
        // If already inactive return
        if (active[usr] == 0) return;

        // Check the owner of the MKR and the delegated have not made any recent action
        require(_add(lastActivity[usr], rightsLifetime) < block.timestamp, "DssGov/not-allowed-to-clear");

        // Mark user as inactive
        active[usr] = 0;

        // Remove the amount from the total active MKR
        totActive = _sub(totActive, rights[usr]);

        // Save snapshot
        _save(usr, 0);

        // Burn gas storage reserve (refund for caller)
        _burn("delegated", usr);
    }

    function ping() external warm {
        // If already active return
        if (active[msg.sender] == 1) return;

        // Mark the user as active
        active[msg.sender] = 1;

        uint256 r = rights[msg.sender];

        // Add the amount from the total active MKR
        totActive = _add(totActive, r);

        // Save snapshot
        _save(msg.sender, r);

        // Mint gas storage reserve
        _mint("delegated", msg.sender);
    }

    function launch() external warm {
        // Check system hasn't already been launched
        require(live == 0, "DssGov/already-launched");

        // Check totalActive MKR has passed the min Setup Threshold
        require(totActive >= LAUNCH_THRESHOLD, "DssGov/not-minimum");

        // Launch system
        live = 1;
    }

    function propose(address exec, address action) external warm returns (uint256) {
        // Check system is live
        require(live == 1, "DssGov/not-launched");

        if (proposers[msg.sender] == 1) { // If it is a proposer account
            // Get amount of proposals made by the proposer the last day
            ProposerDayAmount memory day = proposerDayAmounts[msg.sender];
            // Get today value
            uint256 today = block.timestamp / 1 days;
            // Get amount of proposals made today
            uint256 count = day.lastDay == today ? day.count : 0;
            // Check proposer hasn't already reached the maximum per day
            require(count < maxProposerAmount, "DssGov/max-amount-proposals-proposer"); // Max amount of proposals that a proposer can do per calendar day
            // Increment amount of proposals made
            proposerDayAmounts[msg.sender] = ProposerDayAmount(today, _add(count, 1));
        } else { // If not a proposer account
            // Check user has at least the min amount of MKR for creating a proposal
            uint256 deposit = deposits[msg.sender];
            require(deposit >= minGovStake, "DssGov/not-minimum-amount");

            // Check user has not made another proposal recently
            require(unlockTime[msg.sender] <= block.timestamp, "DssGov/user-locked");
        }

        // Update locked time
        unlockTime[msg.sender] = _add(block.timestamp, lockDuration);

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

        return numProposals;
    }

    function vote(uint256 id, uint256 wad, uint256 sIndex) external warm {
        // Verify it hasn't been already plotted, not executed nor removed
        require(proposals[id].status == PROPOSAL_PENDING, "DssGov/wrong-status");
        // Verify proposal is not expired
        require(proposals[id].end >= block.timestamp, "DssGov/proposal-expired");
        // Verify amount for voting is lower or equal than voting rights
        require(wad <= _getUserRights(msg.sender, sIndex, proposals[id].blockNum), "DssGov/amount-exceeds-rights");

        uint256 prev = proposals[id].votes[msg.sender];
        // Update voting rights used by the user
        proposals[id].votes[msg.sender] = wad;
        // Update total votes to the proposal
        proposals[id].totVotes = _add(_sub(proposals[id].totVotes, prev), wad);
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
    }

    function exec(uint256 id) external warm {
        // Verify it has been already plotted, but not executed or removed
        require(proposals[id].status == PROPOSAL_SCHEDULED, "DssGov/wrong-status");

        // Execute action proposal
        proposals[id].status = PROPOSAL_EXECUTED;
        ExecLike(proposals[id].exec).exec(proposals[id].action);
    }

    function drop(uint256 id) external auth {
        // Verify it hasn't been already cancelled
        require(proposals[id].status < PROPOSAL_CANCELLED, "DssGov/wrong-status");

        // Drop action proposal
        proposals[id].status = PROPOSAL_CANCELLED;
        ExecLike(proposals[id].exec).drop(proposals[id].action);
    }
}
