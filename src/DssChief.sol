pragma solidity ^0.6.7;

interface TokenLike {
    function transferFrom(address, address, uint256) external;
    function transfer(address, uint256) external;
}

interface ExecLike {
    function delay() external view returns (uint256);
    function drop(address) external;
    function exec(address) external returns (uint256);
    function plot(address) external returns (uint256);
}

contract DssChief {
    // --- Auth ---
    mapping (address => uint256)    public wards;
    function rely(address usr)      external auth { wards[usr] = 1; }
    function deny(address usr)      external auth { wards[usr] = 0; }
    modifier auth {
        require(wards[msg.sender] == 1, "DssChief/not-authorized");
        _;
    }

    struct Proposal {
        uint256 blockNum;
        uint256 end;
        address exec;
        address action;
        uint256 totActive;
        uint256 rights;
        mapping(address => uint256) votes;
        uint256 status;
    }

    struct Snapshot {
        uint256 fromBlock;
        uint256 rights;
    }

    TokenLike                                        public gov;           // MKR gov token
    uint256                                          public ttl;           // MKR locked expiration time (admin param)
    uint256                                          public end;           // Duration of a candidate's validity in seconds (admin param)
    uint256                                          public min;           // Min MKR stake for launching a vote (admin param)
    uint256                                          public post;          // Min % of total locked MKR to approve a proposal (admin param)
    mapping(address => uint256)                      public deposits;      // User => MKR deposited
    uint256                                          public totActive;     // Total active MKR
    mapping(address => uint256)                      public active;        // User => Active MKR (Yes/No)
    mapping(address => uint256)                      public last;          // Last time executed
    uint256                                          public proposalsNum;  // Amount of Proposals
    mapping(uint256 => Proposal)                     public proposals;     // List of proposals
    mapping(address => uint256)                      public snapshotsNum;  // User => Amount of snapshots
    mapping(address => mapping(uint256 => Snapshot)) public snapshots;     // User => Index => Snapshot

    uint256                                 constant public MIN_POST = 40; // Min post value that admin can set
    uint256                                 constant public MAX_POST = 60; // Max post value that admin can set

    modifier warm {
        _;
        last[msg.sender] = block.timestamp;
    }

    function add(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require((z = x + y) >= x);
    }

    function sub(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require((z = x - y) <= x);
    }

    function mul(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require(y == 0 || (z = x * y) / y == x);
    }

    constructor(address gov_) public {
        gov = TokenLike(gov_);
        wards[msg.sender] = 1;
    }

    function file(bytes32 what, uint256 data) public auth {
        if (what == "ttl") ttl = data;
        else if (what == "end") end = data;
        else if (what == "min") min = data;
        else if (what == "post") {
            require(data >= MIN_POST && data <= MAX_POST, "DssChief/post-not-safe-range");
            post = data;
        }
        else revert("DssChief/file-unrecognized-param");
    }

    function _save(address user, uint256 wad) internal {
        uint256 num = snapshotsNum[user];

        if (num > 0 && snapshots[user][num].fromBlock == block.number) {
            snapshots[user][num].rights = wad;
        } else {
            num = snapshotsNum[user] = add(snapshotsNum[user], 1);
            snapshots[user][num] = Snapshot(block.number, wad);
        }
    }

    function lock(uint256 wad) external warm {
        // Pull collateral from sender's wallet
        gov.transferFrom(msg.sender, address(this), wad);

        // Increase amount deposited from sender
        uint256 deposit = add(deposits[msg.sender], wad);
        deposits[msg.sender] = deposit;

        // Update active MKR that counts for passing proposals
        if (active[msg.sender] == 1) {
            totActive = add(totActive, wad);
        } else {
            active[msg.sender] = 1;
            totActive = add(totActive, deposit);
        }

        // Save snapshot
        _save(msg.sender, deposit);
    }

    function free(uint256 wad) external warm {
        // Verify is not freeing on same block which another action previously happened
        // (to avoid usage of flash loans)
        require(last[msg.sender] < block.timestamp, "DssChief/not-minimum-time-passed");

        // Decrease amount deposited from user
        uint256 deposit = sub(deposits[msg.sender], wad);
        deposits[msg.sender] = deposit;

        // Update active MKR that counts for passing proposals
        if (active[msg.sender] == 1) {
            totActive = sub(totActive, wad);
        } else {
            active[msg.sender] = 1;
            totActive = add(totActive, deposit);
        }

        // Save snapshot
        _save(msg.sender, deposit);

        // Push token back to user's wallet
        gov.transfer(msg.sender, wad);
    }

    function ping() external warm {
        require(active[msg.sender] == 0, "DssChief/user-already-active");
        uint256 deposit = deposits[msg.sender];

        totActive = add(totActive, deposit);
        active[msg.sender] = 1;

        // Save snapshot
        _save(msg.sender, deposit);
    }

    function clear(address usr) external {
        require(add(last[usr], ttl) < block.timestamp, "DssChief/not-allowed-to-clear");
        require(active[usr] == 1, "DssChief/user-already-cleared");

        totActive = sub(totActive, deposits[usr]);
        active[usr] = 0;

        // Save snapshot
        _save(usr, 0);
    }

    function propose(address exec, address action) external warm returns (uint256) {
        uint256 deposit = deposits[msg.sender];
        require(deposit >= min, "DssChief/not-minimum-amount");

        // TODO: Allow only one active proposal per user and add some time lock in free for withdrawing the MKR
        // after making a proposal

        // Reactive locked MKR if was inactive
        if (active[msg.sender] == 0) {
            totActive = add(totActive, deposit);
            active[msg.sender] = 1;
            // Save snapshot
            _save(msg.sender, deposit);
        }

        // Add new proposal
        proposalsNum = add(proposalsNum, 1);
        proposals[proposalsNum] = Proposal({
                blockNum: block.number,
                end: add(block.timestamp, end),
                exec: exec,
                action: action,
                totActive: totActive,
                rights: 0,
                status: 0
        });

        return proposalsNum;
    }

    function _getUserRights(address usr, uint256 index, uint256 blockNum) internal view returns (uint256 rights) {
        uint256 num = snapshotsNum[usr];
        require(num >= index, "DssChief/not-existing-index");
        Snapshot memory snapshot = snapshots[usr][index];
        require(snapshot.fromBlock <= blockNum, "DssChief/not-correct-snapshot-1");
        require(index == num || snapshots[usr][index + 1].fromBlock > blockNum, "DssChief/not-correct-snapshot-2");

        rights = snapshot.rights;
    }

    function vote(uint256 id, uint256 wad, uint256 sIndex) external warm {
        // Verify it hasn't been already plotted, not executed nor removed
        require(proposals[id].status == 0, "DssChief/wrong-status");
        // Verify proposal is not expired
        require(proposals[id].end >= block.timestamp, "DssChief/proposal-expired");
        // Verify amount for voting is lower or equal than voting rights
        require(wad <= _getUserRights(msg.sender, sIndex, proposals[id].blockNum), "DssChief/amount-exceeds-rights");

        uint256 prev = proposals[id].votes[msg.sender];
        // Update voting rights used by the user
        proposals[id].votes[msg.sender] = wad;
        // Update voting rights to the proposal
        proposals[id].rights = add(sub(proposals[id].rights, prev), wad);
    }

    function plot(uint256 id) external warm {
        // Verify it hasn't been already plotted or removed
        require(proposals[id].status == 0, "DssChief/wrong-status");
        // Verify proposal is not expired
        require(block.timestamp <= proposals[id].end, "DssChief/vote-expired");
        // Verify enough MKR is voting this proposal
        require(proposals[id].rights > mul(proposals[id].totActive, post) / 100, "DssChief/not-enough-voting-rights");

        // Plot action proposal
        proposals[id].status = 1;
        ExecLike(proposals[id].exec).plot(proposals[id].action);
    }

    function exec(uint256 id) external warm {
        // Verify it has been already plotted, but not executed or removed
        require(proposals[id].status == 1, "DssChief/wrong-status");

        // Execute action proposal
        proposals[id].status = 2;
        ExecLike(proposals[id].exec).exec(proposals[id].action);
    }

    function drop(uint256 id) external auth {
        // Verify it hasn't been already removed
        require(proposals[id].status < 3, "DssChief/wrong-status");

        // Drop action proposal
        proposals[id].status = 3;
        ExecLike(proposals[id].exec).drop(proposals[id].action);
    }
}
