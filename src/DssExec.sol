pragma solidity ^0.6.7;

contract DssExec {
    // --- Auth ---
    mapping (address => uint256)    public wards;
    function rely(address usr)      external wait { wards[usr] = 1; }
    function deny(address usr)      external wait { wards[usr] = 0; }
    modifier auth {
        require(wards[msg.sender] == 1, "DssDelay/not-authorized");
        _;
    }
    modifier wait {
        require(msg.sender == address(this), "DssDelay/undelayed-call");
        _;
    }

    uint256 public tic;
    mapping (address => uint256) public plan;

    function add(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require((z = x + y) >= x);
    }

    function file(bytes32 what, uint256 data) public wait {
        if (what == "tic") tic = data;
        else revert("DssChief/file-unrecognized-param");
    }

    constructor(uint256 tic_) public {
        tic = tic_;
        wards[msg.sender] = 1;
    }

    function plot(address action) external auth {
        plan[action] = add(now, tic);
    }

    function drop(address action) external auth {
        plan[action] = 0;
    }

    function exec(address action) external auth {
        require(plan[action] != 0,   "DssDelay/not-plotted");
        require(now >= plan[action], "DssDelay/not-delay-passed");

        plan[action] = 0;
        bool ok;
        (ok, ) = action.delegatecall(abi.encodeWithSignature("execute()"));
        require(ok, "DssDelay/delegatecall-error");
    }
}
