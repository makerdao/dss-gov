// SPDX-License-Identifier: AGPL-3.0-or-later

/// RevokableNFT.sol

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

// An NFT which allows authed users to be able to revoke the token.
// Follows the ERC721 standard.
contract RevokableNFT {

    /*** Events ***/
    event Rely(address indexed usr);
    event Deny(address indexed usr);

    /*** Auth ***/
    function rely(address usr) external auth { wards[usr] = 1; emit Rely(usr); }
    function deny(address usr) external auth { wards[usr] = 0; emit Deny(usr); }
    modifier auth { require(wards[msg.sender] == 1, "RevokableNFT/not-authorized"); _; }

    constructor(string name_, string symbol_) {
        // Authorize msg.sender
        wards[msg.sender] = 1;

        // Emit event
        emit Rely(msg.sender);
    }

}
