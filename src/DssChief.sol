pragma solidity ^0.5.12;

import { DSAuth, DSAuthority } from "ds-auth/auth.sol";

contract TokenLike {
    function transferFrom(address, address, uint256) external;
    function transfer(address, uint256) external;
}

contract DssChief is DSAuth, DSAuthority {
    TokenLike                                           public gov;         // MKR gov token
    uint256                                             public supply;      // Total MKR locked
    uint256                                             public ttl;         // MKR locked expiration time (admin param)
    uint256                                             public end;         // Duration of a candidate's validity in seconds (admin param)
    mapping(address => mapping(address => uint256))     public votes;       // Voter => Candidate => Voted
    mapping(address => uint256)                         public approvals;   // Candidate => Amount of votes
    mapping(address => uint256)                         public candidates;  // Candidate => Expiration
    mapping(address => uint256)                         public deposits;    // Voter => Voting power
    mapping(address => uint256)                         public count;       // Voter => Amount of candidates voted
    mapping(address => uint256)                         public last;        // Last time executed

    function add(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require((z = x + y) >= x);
    }

    function sub(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require((z = x - y) <= x);
    }

    constructor(address gov_) public {
        gov = TokenLike(gov_);
    }

    function file(bytes32 what, uint256 data) public auth {
        if (what == "ttl") ttl = data;
        else if (what == "end") end = data;
        else revert("DssChief/file-unrecognized-param");
    }

    function lock(uint256 wad) external {
        // Can't lock more MKR if msg.sender is already voting candidates
        require(count[msg.sender] == 0, "DssChief/existing-voted-candidates");
        // Pull collateral from sender's wallet
        gov.transferFrom(msg.sender, address(this), wad);
        // Increase amount deposited from sender
        deposits[msg.sender] = add(deposits[msg.sender], wad);
        // Increase total supply
        supply = add(supply, wad);
        // Signal this account has been active and renew expiration time
        last[msg.sender] = now;
    }

    function free(address usr, uint256 wad) external {
        // Can't free MKR if usr is still voting candidates
        require(count[usr] == 0, "DssChief/existing-voted-candidates");
        // Verify usr is sender or their voting power is already expired
        require(usr == msg.sender || add(last[usr], ttl) < now, "DssChief/not-allowed-to-free");
        // Verify is not freeing on same block where another action happened (to avoid usage of flash loans)
        require(last[usr] < now, "DssChief/not-minimum-time-passed");
        // Decrease amount deposited from usr
        deposits[usr] = sub(deposits[usr], wad);
        // Decrease total supply
        supply = sub(supply, wad);
        // Push token back to usr's wallet
        gov.transfer(usr, wad);
        // Clean storage if usr is not the sender (for gas refund)
        if (usr != msg.sender) delete last[usr];
        // Signal this account has been active and renew expiration time
        last[msg.sender] = now;
    }

    function vote(address whom) external {
        // Check the whom candidate was not previously voted by msg.sender
        require(votes[msg.sender][whom] == 0, "DssChief/candidate-already-voted");
        // If it's the first vote for this candidate, set the expiration time
        if (candidates[whom] == 0) {
            candidates[whom] = add(now, end);
        }
        // Mark candidate as voted by msg.sender
        votes[msg.sender][whom] = 1;
        // Add voting power to the candidate
        approvals[whom] = add(approvals[whom], deposits[msg.sender]);
        // Increase the voting counter from msg.sender
        count[msg.sender] = add(count[msg.sender], 1);
        // Signal this account has been active and renew expiration time
        last[msg.sender] = now;
    }

    function undo(address usr, address whom) external {
        // Check the candidate whom is actually voted by usr
        require(votes[usr][whom] == 1, "DssChief/candidate-not-voted");
        // Verify usr is sender or their voting power is already expired
        require(usr == msg.sender || add(last[usr], ttl) < now, "DssChief/not-allowed-to-undo");
        // Mark candidate as not voted for by usr
        votes[usr][whom] = 0;
        // Remove voting power from the candidate
        approvals[whom] = sub(approvals[whom], deposits[usr]);
        // Decrease the voting counter from usr
        count[usr] = sub(count[usr], 1);
        // Signal this account has been active and renew expiration time
        last[msg.sender] = now;
    }

    function canCall(address caller, address, bytes4) public view returns (bool ok) {
        ok = approvals[caller] > supply / 2 && now <= candidates[caller];
    }
}
