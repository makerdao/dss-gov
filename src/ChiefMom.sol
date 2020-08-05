pragma solidity ^0.6.7;

interface ChiefLike {
    function drop(uint256) external;
}

contract ChiefMom {
    // --- Auth ---
    mapping (address => uint256)    public wards;
    function rely(address usr)      external auth { wards[usr] = 1; }
    function deny(address usr)      external auth { wards[usr] = 0; }
    modifier auth {
        require(wards[msg.sender] == 1, "DssChief/not-authorized");
        _;
    }

    ChiefLike chief;

    constructor(address chief_) public {
        chief = ChiefLike(chief_);
        wards[msg.sender] = 1;
    }

    function drop(uint256 id) external auth {
        chief.drop(id);
    }
}
