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

import "zeppelin-solidity/token/ERC721/ERC721.sol";
import "zeppelin-solidity/utils/ReentrancyGuard.sol";

interface ITokenRevokedReceiver {
    function onTokenRevoked(address token, uint256 tokenId) external;
}

// An NFT which allows authed users to be able to revoke the token at any time.
// Uses the ERC721 standard.
contract RevokableNFT is ERC721, ReentrancyGuard {

    using SafeMath for uint256;
    using Address for address;

    /*** Events ***/
    event Rely(address indexed usr);
    event Deny(address indexed usr);
    event File(bytes32 indexed what, uint256 data);
    event Mint(address indexed usr, uint256 id, uint256 value);
    event Revoke(address indexed usr, uint256 id, uint256 value);

    /*** Auth ***/
    mapping(address => uint256) public wards;
    function rely(address usr) external auth { wards[usr] = 1; emit Rely(usr); }
    function deny(address usr) external auth { wards[usr] = 0; emit Deny(usr); }
    modifier auth { require(wards[msg.sender] == 1, "RevokableNFT/not-authorized"); _; }

    uint256 public revokeGasLimit;                      // The gas limit for calling onRevokeToken()
    mapping(uint256 => uint256) public tokenValue;      // Token ID => Token Value
    mapping(address => uint256) public addressValue;    // Address => Total Token Value

    constructor(string memory name_, string memory symbol_) ERC721(name_, symbol_) public {
        // Authorize msg.sender
        wards[msg.sender] = 1;

        // Emit event
        emit Rely(msg.sender);
    }

    function file(bytes32 what, uint256 data) external auth {
        if (what == "revokeGasLimit") revokeGasLimit = data;
        else revert("RevokableNFT/file-unrecognized-param");

        // Emit event
        emit File(what, data);
    }

    function mint(address usr, uint256 value) external auth returns (uint256 tokenId) {
       tokenId = 123;   // TODO generate id

        tokenValue[tokenId] = value;
        _mint(usr, tokenId);

        emit Mint(usr, tokenId, value);
    }

    function revoke(uint256 tokenId) external auth nonReentrant {
        address owner = ownerOf(tokenId);

        // Before revoking notify the owner that this token is about to be revoked
        // This is optional for the owner to be able to handle this
        _callOnTokenRevoked(owner, tokenId);

        _burn(tokenId);
        delete tokenValue[tokenId];
    }

    function _callOnTokenRevoked(address owner, uint256 tokenId) private returns (bool) {
        // EOAs do not have code
        if (!owner.isContract()) {
            return true;
        }

        // Set a fixed gas limit to prevent blocking this transaction with infinite gas exhaustion
        owner.call{ gas: revokeGasLimit }(abi.encodeWithSelector(
            ITokenRevokedReceiver(owner).onTokenRevoked.selector,
            address(this),
            tokenId
        ));
    }

    function _beforeTokenTransfer(address from, address to, uint256 tokenId) internal override {
        // Keep value accounting up to date
        uint256 value = tokenValue[tokenId];
        if (from != address(0)) {
            addressValue[from] = addressValue[from].sub(value);
        }
        if (to != address(0)) {
            addressValue[to] = addressValue[to].add(value);
        }
    }

}
