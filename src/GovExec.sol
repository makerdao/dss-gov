// SPDX-License-Identifier: AGPL-3.0-or-later

/// GovExec.sol

// Copyright (C) 2020 Maker Ecosystem Growth Holdings, INC.
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

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
