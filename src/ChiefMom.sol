pragma solidity ^0.6.7;

interface ChiefLike {
    function drop(uint256) external;
}

contract ChiefMom {
    address   immutable public owner;
    ChiefLike immutable public chief;

    modifier onlyOwner { require(msg.sender == owner, "ChiefMom/only-owner"); _;}

    constructor(address owner_, address chief_) public {
        owner = owner_;
        chief = ChiefLike(chief_);
    }

    function drop(uint256 id) external onlyOwner {
        chief.drop(id);
    }
}
