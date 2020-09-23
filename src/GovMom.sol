pragma solidity ^0.6.7;

interface GovLike {
    function drop(uint256) external;
}

contract GovMom {
    address   immutable public owner;
    GovLike immutable public gov;

    modifier onlyOwner { require(msg.sender == owner, "GovMom/only-owner"); _;}

    constructor(address owner_, address gov_) public {
        owner = owner_;
        gov = GovLike(gov_);
    }

    function drop(uint256 id) external onlyOwner {
        gov.drop(id);
    }
}
