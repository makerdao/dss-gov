pragma solidity ^0.6.7;

contract GovExec {
    // As they are immutable can not be changed in the delegatecall
    address immutable public owner;
    uint256 immutable public tic;

    mapping (address => uint256) public time;

    modifier onlyOwner {
        require(msg.sender == owner, "GovExec/only-owner");
        _;
    }

    function add(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require((z = x + y) >= x);
    }

    constructor(address owner_, uint256 tic_) public {
        owner = owner_;
        tic = tic_;
    }

    function plot(address action) external onlyOwner {
        if (tic > 0) {
            require(time[action] == 0, "GovExec/action-already-plotted");
            time[action] = add(block.timestamp, tic);
        }
    }

    function drop(address action) external onlyOwner {
        if (tic > 0) {
            time[action] = 0;
        }
    }

    function exec(address action) external onlyOwner {
        if (tic > 0) {
            uint256 t = time[action];
            require(t != 0,   "GovExec/not-plotted");
            require(now >= t, "GovExec/not-delay-passed");

            time[action] = 0;
        }

        bool ok;
        (ok, ) = action.delegatecall(abi.encodeWithSignature("execute()"));
        require(ok, "GovExec/delegatecall-error");
    }
}
