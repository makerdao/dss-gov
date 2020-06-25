pragma solidity ^0.5.12;

contract TokenLike {
    function transferFrom(address, address, uint256) external;
    function transfer(address, uint256) external;
}

contract DelayLike {
    function delay() external view returns (uint256);
    function drop(address, bytes memory, uint256) external;
    function plot(address, bytes memory, uint256) external returns (uint256);
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

    // MKR gov token
    TokenLike                                                               public gov;
    // Total MKR locked
    uint256                                                                 public supply;
    // MKR locked expiration time (admin param)
    uint256                                                                 public ttl;
    // Duration of a candidate's validity in seconds (admin param)
    uint256                                                                 public end;
    // Min MKR stake for launching a vote (admin param)
    uint256                                                                 public min;
    // Min % of total locked MKR to approve a proposal (admin param)
    uint256                                                                 public post;
    // Voter => Delay => Action => Voted
    mapping(address => mapping(mapping(address => address) => uint256))     public votes;
    // Delay => Action => Amount of votes
    mapping(mapping(address => address) => uint256)                         public approvals;
    // Delay => Action => Expiration
    mapping(mapping(address => address) => uint256)                         public expirations;
    // Delay => Action => Plotted
    mapping(mapping(address => address) => uint256)                         public plotted;
    // Voter => Voting power
    mapping(address => uint256)                                             public deposits;
    // Voter => Amount of candidates voted
    mapping(address => uint256)                                             public count;
    // Last time executed
    mapping(address => uint256)                                             public last;

    // Min post value that admin can set
    uint256                                                        constant public MIN_POST = 40;
    // Max post value that admin can set
    uint256                                                        constant public MAX_POST = 60;

    // warm account and renew expiration time
    modifier warm {
        _;
        last[msg.sender] = now;
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

    function lock(uint256 wad) external warm {
        // Can't lock more MKR if msg.sender is already voting candidates
        require(count[msg.sender] == 0, "DssChief/existing-voted-candidates");
        // Pull collateral from sender's wallet
        gov.transferFrom(msg.sender, address(this), wad);
        // Increase amount deposited from sender
        deposits[msg.sender] = add(deposits[msg.sender], wad);
        // Increase total supply
        supply = add(supply, wad);
    }

    function free(address usr, uint256 wad) external warm {
        // Can't free MKR if usr is still voting candidates
        require(count[usr] == 0, "DssChief/existing-voted-candidates");
        // Verify usr is sender or their voting power is already expired
        require(
            usr == msg.sender || add(last[usr], ttl) < now,
            "DssChief/not-allowed-to-free"
        );
        // Verify is not freeing on same block where another action happened
        // (to avoid usage of flash loans)
        require(last[usr] < now, "DssChief/not-minimum-time-passed");
        // Decrease amount deposited from usr
        deposits[usr] = sub(deposits[usr], wad);
        // Decrease total supply
        supply = sub(supply, wad);
        // Push token back to usr's wallet
        gov.transfer(usr, wad);
        // Clean storage if usr is not the sender (for gas refund)
        if (usr != msg.sender) delete last[usr];
    }

    function vote(address delay, address action) external {
        // Check the whom candidate was not previously voted by msg.sender
        require(votes[msg.sender][delay][action] == 0, "DssChief/candidate-already-voted");
        // If it's the first vote for this candidate, set the expiration time
        if (expirations[delay][action] == 0) {
            // Check min is set to 0 or
            // user deposits are >= than min value + it's not launching a vote
            // on the same block where another action happened
            // (to avoid usage of flash loans)
            require(
                min == 0 || deposits[msg.sender] >= min && last[msg.sender] < now,
                "DssChief/not-minimum-amount"
            );
            // Set expiration time
            expirations[delay][action] = add(now, end);
        }
        // Mark candidate as voted by msg.sender
        votes[msg.sender][delay][action] = 1;
        // Add voting power to the candidate
        approvals[delay][action] = add(approvals[delay][action], deposits[msg.sender]);
        // Increase the voting counter from msg.sender
        count[msg.sender] = add(count[msg.sender], 1);
    }

    function undo(address usr, address delay, address action) external {
        // Check the candidate whom is actually voted by usr
        require(votes[usr][delay][action] == 1, "DssChief/candidate-not-voted");
        // Verify usr is sender or their voting power is already expired
        require(
            usr == msg.sender || add(last[usr], ttl) < now,
            "DssChief/not-allowed-to-undo"
        );
        // Mark candidate as not voted for by usr
        votes[usr][delay][action] = 0;
        // Remove voting power from the candidate
        approvals[delay][action] = sub(approvals[delay][action], deposits[usr]);
        // Decrease the voting counter from usr
        count[usr] = sub(count[usr], 1);
    }

    function plot(address delay, address action) external {
        // Generate hash delay/action
        // Check enough MKR is voting this proposal and it's not already expired
        require(approvals[delay][action] > mul(supply, post) / 100, "DssChief/not-enough-voting-power");
        require(now <= expirations[delay][action], "vote-expired");
        // Verify was not already plotted
        require(plotted[delay][action] == 0, "DssChief/action-already-plotted");
        // Plot action proposal
        plotted[delay][action] = 1;
        DelayLike(delay).plot(action, eta[delay][action]);
    }

    function drop(address delay, address action) external {
        // Check enough MKR is voting address(0) => which means Governance is in emergency mode
        require(approvals[address(0)][address(0)] > mul(supply, post) / 100, "DssChief/not-enough-voting-power");
        // Drop action proposal
        plotted[delay][action] = 0;
        DelayLike(delay).drop(action);
    }
}
