pragma solidity ^0.5.12;

import { DSAuth, DSAuthority } from "ds-auth/auth.sol";

contract TokenLike {
    function transferFrom(address, address, uint256) external;
    function transfer(address, uint256) external;
}

contract DssChief is DSAuth, DSAuthority {
    TokenLike                       public gov;         // MKR gov token
    uint256                         public supply;      // Total MKR locked
    uint256                         public ttl;         // MKR locked expiration time (admin param)
    address                         public hat;         // Elected Candidate
    mapping(address => address)     public votes;       // Voter => Candidate
    mapping(address => uint256)     public approvals;   // Candidate => Amount of votes
    mapping(address => uint256)     public deposits;    // Voter => Voting power
    mapping(address => uint256)     public last;        // Last time executed

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
        else revert("DssChief/file-unrecognized-param");
    }

    function lock(uint256 wad) external {
        // Pull collateral from sender's wallet
        gov.transferFrom(msg.sender, address(this), wad);
        // Increase amount deposited from sender
        deposits[msg.sender] = add(deposits[msg.sender], wad);
        // Add new voting power to the actual voted candidate
        approvals[votes[msg.sender]] = add(approvals[votes[msg.sender]], wad);
        // Increase total supply
        supply = add(supply, wad);
        // Signal this account has been active and renew expiration time
        last[msg.sender] = now;
    }

    function free(address usr, uint256 wad) external {
        // Verify usr is sender or their voting power is already expired
        require(usr == msg.sender || add(last[usr], ttl) < now , "DssChief/not-allowed-to-free");
        // Verify is not freeing on same block where another action happened (to avoid usage of flash loans)
        require(last[usr] < now, "DssChief/not-minimum-time-passed");
        // Decrease amount deposited from usr
        deposits[usr] = sub(deposits[usr], wad);
        // Remove voting power from the actual voted candidate
        approvals[votes[usr]] = sub(approvals[votes[usr]], wad);
        // Decrease total supply
        supply = sub(supply, wad);
        // Push token back to usr's wallet
        gov.transfer(usr, wad);
        // Signal this account has been active and renew expiration time
        last[msg.sender] = now;
    }

    function vote(address whom) external {
        // Remove voting power from the actual voted candidate
        approvals[votes[msg.sender]] = sub(approvals[votes[msg.sender]], deposits[msg.sender]);
        // Vote new candidate
        votes[msg.sender] = whom;
        // Add new voting power to the new candidate
        approvals[whom] = add(approvals[whom], deposits[msg.sender]);
        // Signal this account has been active and renew expiration time
        last[msg.sender] = now;
    }

    function lift(address whom) external {
        // Verify the actual candidate has more than half of total supply of locked MKR
        require(approvals[whom] > supply / 2, "not-enough-voting-power");
        // Elect new candidate
        hat = whom;
        // Signal this account has been active and renew expiration time
        last[msg.sender] = now;
    }

    function canCall(address caller, address, bytes4) public view returns (bool ok) {
        ok = caller == hat;
    }
}
