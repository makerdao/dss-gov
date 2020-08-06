pragma solidity ^0.6.7;

contract Scheduler {
    address immutable public owner;

    mapping (address => uint256) public time;

    modifier onlyOwner {
        require(msg.sender == owner, "DssExecMom/only-owner");
        _;
    }

    constructor() public {
        owner = msg.sender;
    }

    function setAction(address action_, uint256 time_) external onlyOwner {
        time[action_] = time_;
    }
}

contract DssExec {
    // As they are immutable can not be changed in the delegatecall
    address   immutable public owner;
    uint256   immutable public tic;
    Scheduler immutable public scheduler;

    modifier onlyOwner {
        require(msg.sender == owner, "DssExecMom/only-owner");
        _;
    }

    function add(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require((z = x + y) >= x);
    }

    constructor(address owner_, uint256 tic_) public {
        owner = owner_;
        tic = tic_;
        // If tic == 0 then Scheduler will not be used
        scheduler = tic_ > 0 ? new Scheduler() : Scheduler(address(0));
    }

    function plot(address action) external onlyOwner {
        if (tic > 0) {
            require(scheduler.time(action) == 0, "DssExec/action-already-plotted");
            scheduler.setAction(action, add(block.timestamp, tic));
        }
    }

    function drop(address action) external onlyOwner {
        if (tic > 0) {
            scheduler.setAction(action, 0);
        }
    }

    function exec(address action) external onlyOwner {
        if (tic > 0) {
            uint256 time = scheduler.time(action);
            require(time != 0,   "DssExec/not-plotted");
            require(now >= time, "DssExec/not-delay-passed");

            scheduler.setAction(action, 0);
        }

        bool ok;
        (ok, ) = action.delegatecall(abi.encodeWithSignature("execute()"));
        require(ok, "DssExec/delegatecall-error");
    }
}
