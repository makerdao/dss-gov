// Copyright (C) 2020 Maker Ecosystem Growth Holdings, INC.
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
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

import "ds-test/test.sol";
import { DSToken } from "ds-token/token.sol";

import { DssGov } from "./DssGov.sol";

import { GovExec } from "./GovExec.sol";

import { GovMom } from "./GovMom.sol";

interface Hevm {
    function warp(uint256) external;
    function roll(uint256) external;
}

contract GovUser {
    DssGov gov;

    constructor(DssGov gov_) public {
        gov = gov_;
    }

    function doTransferFrom(DSToken token, address from, address to,
                            uint256 amount)
        public
        returns (bool)
    {
        return token.transferFrom(from, to, amount);
    }

    function doTransfer(DSToken token, address to, uint256 amount)
        public
        returns (bool)
    {
        return token.transfer(to, amount);
    }

    function doApprove(DSToken token, address recipient, uint256 amount)
        public
        returns (bool)
    {
        return token.approve(recipient, amount);
    }

    function doAllowance(DSToken token, address owner, address spender)
        public view
        returns (uint256)
    {
        return token.allowance(owner, spender);
    }

    function doPing() public {
        gov.ping();
    }

    function doLock(uint256 wad) public {
        gov.lock(wad);
    }

    function doFree(uint256 wad) public {
        gov.free(wad);
    }

    function doDelegate(address owner, address to) public {
        gov.delegate(owner, to);
    }

    function doPropose(address exec, address action) public returns (uint256 id) {
        id = gov.propose(exec, action);
    }

    function doVote(uint256 proposal, uint256 sId, uint256 wad) public {
        gov.vote(proposal, sId, wad);
    }
}

contract ActionProposal {
    System immutable system;

    constructor(address system_) public {
        system = System(system_);
    }

    function execute() public {
        system.testAccess();
    }
}

contract ActionDrop {
    GovMom immutable mom;
    uint256 immutable proposal;

    constructor(address mom_, uint256 proposal_) public {
        mom = GovMom(mom_);
        proposal = proposal_;
    }

    function execute() public {
        mom.drop(proposal);
    }
}

contract System {
    mapping (address => uint256) public wards;
    function rely(address usr) external auth {wards[usr] = 1; }
    function deny(address usr) external auth {wards[usr] = 0; }
    modifier auth {
        require(wards[msg.sender] == 1, "System/not-authorized");
        _;
    }
    uint256 public executed;

    constructor() public {
        wards[msg.sender] = 1;
    }

    function testAccess() public auth {
        executed = 1;
    }
}

contract DssGovTest is DSTest {
    uint256 constant user1InitialBalance = 350000 ether;
    uint256 constant user2InitialBalance = 250000 ether;
    uint256 constant user3InitialBalance = 200000 ether;

    Hevm hevm;

    DssGov gov;
    address exec0;
    address exec12;
    address mom;
    DSToken govToken;

    GovUser user1;
    GovUser user2;
    GovUser user3;

    System system; // Mocked System to authed via gov

    address action1;
    address action2;
    address action3;

    uint256 actualBlock;

    function setUp() public {
        // init hevm
        hevm = Hevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
        hevm.warp(0);

        govToken = new DSToken("GOV");
        govToken.mint(1000000 ether);

        // Gov set up
        gov = new DssGov(address(govToken));
        gov.file("rightsLifetime", 30 days);
        gov.file("delegationLifetime", 90 days);
        gov.file("proposalLifetime", 7 days);
        gov.file("threshold", 50); // 50%
        gov.file("gasStakeAmt", 50); // 50 slots of storage
        gov.file("minGovStake", 1000 ether);
        gov.file("maxProposerAmount", 3);

        exec12 = address(new GovExec(address(gov), 12 hours));
        exec0 = address(new GovExec(address(gov), 0));
        mom = address(new GovMom(exec0, address(gov)));

        gov.rely(exec12);
        gov.rely(mom);
        //

        system = new System();
        system.rely(exec12);

        user1 = new GovUser(gov);
        user2 = new GovUser(gov);
        user3 = new GovUser(gov);

        action1 = address(new ActionProposal(address(system)));
        action2 = address(new ActionProposal(address(system)));
        action3 = address(new ActionProposal(address(system)));

        govToken.transfer(address(user1), user1InitialBalance);
        govToken.transfer(address(user2), user2InitialBalance);
        govToken.transfer(address(user3), user3InitialBalance);

        user3.doApprove(govToken, address(gov), uint256(-1));
        user2.doApprove(govToken, address(gov),  uint256(-1));
        user1.doApprove(govToken, address(gov),  uint256(-1));

        hevm.warp(1599683711);
        hevm.roll(actualBlock = 10829728);
    }

    function _warp(uint256 nBlocks) internal {
        actualBlock += nBlocks;
        hevm.roll(actualBlock);
        hevm.warp(now + nBlocks * 15);
    }

    function test_lock_debits_user() public {
        assertEq(govToken.balanceOf(address(user1)), user1InitialBalance);

        uint256 lockedAmt = user1InitialBalance / 10;
        user1.doApprove(govToken, address(gov), lockedAmt);
        user1.doLock(lockedAmt);

        assertEq(govToken.balanceOf(address(user1)), user1InitialBalance - lockedAmt);
    }

    function test_free() public {
        uint256 user1LockedAmt = user1InitialBalance / 2;
        user1.doApprove(govToken, address(gov), user1LockedAmt);
        user1.doLock(user1LockedAmt);
        assertEq(govToken.balanceOf(address(user1)), user1InitialBalance - user1LockedAmt);
        hevm.warp(1);
        user1.doFree(user1LockedAmt);
        assertEq(govToken.balanceOf(address(user1)), user1InitialBalance);
    }

    function test_delegate() public {
        assertEq(gov.delegates(address(user1)), address(0));
        assertEq(gov.rights(address(user2)), 0);
        user1.doLock(user1InitialBalance);
        user1.doDelegate(address(user1), address(user2));
        assertEq(gov.delegates(address(user1)), address(user2));
        assertEq(gov.rights(address(user2)), user1InitialBalance);
    }

    function test_remove_delegation_delegated() public {
        user1.doDelegate(address(user1), address(user2));
        user2.doDelegate(address(user1), address(0));
    }

    function testFail_change_delegation_delegated() public {
        user1.doDelegate(address(user1), address(user2));
        user2.doDelegate(address(user1), address(1));
    }

    function test_remove_delegation_inactivity() public {
        user1.doDelegate(address(user1), address(user2));
        _warp(gov.delegationLifetime() / 15 + 1);
        gov.delegate(address(user1), address(0));
    }

    function testFail_remove_delegation_inactivity() public {
        user1.doDelegate(address(user1), address(user2));
        _warp(gov.delegationLifetime() / 15 - 1);
        gov.delegate(address(user1), address(0));
    }

    function testFail_change_delegation_inactivity() public {
        user1.doDelegate(address(user1), address(user2));
        _warp(gov.delegationLifetime() / 15 + 1);
        user2.doDelegate(address(user1), address(1));
    }

    function test_snapshot() public {
        uint256 originalBlockNumber = block.number;

        assertEq(gov.numSnapshots(address(user1)), 0);

        user1.doLock(user1InitialBalance);

        _warp(1);
        user1.doPing();

        uint256 num = gov.numSnapshots(address(user1));
        assertEq(gov.numSnapshots(address(user1)), num);
        (uint256 fromBlock, uint256 rights) = gov.snapshots(address(user1), num);
        assertEq(fromBlock, originalBlockNumber + 1);
        assertEq(rights, 0);

        _warp(1);
        user1.doDelegate(address(user1), address(user1));

        num = gov.numSnapshots(address(user1));
        assertEq(gov.numSnapshots(address(user1)), 2);
        (fromBlock, rights) = gov.snapshots(address(user1), num);
        assertEq(fromBlock, originalBlockNumber + 2);
        assertEq(rights, user1InitialBalance);
    }

    function test_ping() public {
        user1.doLock(user1InitialBalance);
        user1.doDelegate(address(user1), address(user1));
        assertEq(gov.active(address(user1)), 0);
        assertEq(gov.totActive(), 0);
        user1.doPing();
        assertEq(gov.active(address(user1)), 1);
        assertEq(gov.totActive(), user1InitialBalance);
    }

    function test_clear() public {
        user1.doLock(user1InitialBalance);
        user1.doDelegate(address(user1), address(user1));
        user1.doPing();
        assertEq(gov.active(address(user1)), 1);
        assertEq(gov.totActive(), user1InitialBalance);
        _warp(gov.rightsLifetime() / 15 + 1);
        gov.clear(address(user1));
        assertEq(gov.active(address(user1)), 0);
        assertEq(gov.totActive(), 0);
    }

    function _tryLaunch() internal returns (bool ok) {
        (ok,) = address(gov).call(abi.encodeWithSignature("launch()"));
    }

    function test_launch() public {
        assertEq(gov.live(), 0);
        assertTrue(!_tryLaunch());
        user1.doLock(75000 ether);
        assertTrue(!_tryLaunch());
        user2.doLock(25000 ether);
        assertTrue(!_tryLaunch());
        user1.doPing();
        user1.doDelegate(address(user1), address(user1));
        assertTrue(!_tryLaunch());
        user2.doPing();
        user2.doDelegate(address(user2), address(user2));
        assertTrue(_tryLaunch());
    }

    function _launch() internal {
        user1.doLock(100000 ether);
        user1.doPing();
        user1.doDelegate(address(user1), address(user1));
        gov.launch();
        user1.doFree(100000 ether);
    }

    function test_propose() public {
        _launch();
        user2.doLock(1000 ether);
        user2.doPropose(exec12, action1);
    }

    function testFail_propose_not_min_mkr() public {
        _launch();
        user2.doLock(999 ether);
        user2.doPropose(exec12, action1);
    }

    function test_voting_unvoting() public {
        _launch();

        uint user1LockedAmt = user1InitialBalance / 2;
        uint user2LockedAmt = user2InitialBalance / 2;
        uint user3LockedAmt = user3InitialBalance / 2;
        user1.doLock(user1LockedAmt);
        user2.doLock(user2LockedAmt);
        user3.doLock(user3LockedAmt);

        _warp(1);

        uint256 proposal1 = user1.doPropose(exec12, action1);
        uint256 proposal2 = user2.doPropose(exec12, action2);
        uint256 proposal3 = user3.doPropose(exec12, action3);

        (,,,,, uint256 totVotes1,) = gov.proposals(proposal1);
        (,,,,, uint256 totVotes2,) = gov.proposals(proposal2);
        (,,,,, uint256 totVotes3,) = gov.proposals(proposal3);
        assertEq(totVotes1, 0);
        assertEq(totVotes2, 0);
        assertEq(totVotes3, 0);

        // Vote will full rights on proposal 1
        user1.doVote(proposal1, gov.numSnapshots(address(user1)), user1LockedAmt);
        (,,,,, totVotes1,) = gov.proposals(proposal1);
        (,,,,, totVotes2,) = gov.proposals(proposal2);
        (,,,,, totVotes3,) = gov.proposals(proposal3);
        assertEq(totVotes1, user1LockedAmt);
        assertEq(totVotes2, 0);
        assertEq(totVotes3, 0);

        // Vote will full rights on proposal 2
        user1.doVote(proposal2, gov.numSnapshots(address(user1)), user1LockedAmt);
        (,,,,, totVotes1,) = gov.proposals(proposal1);
        (,,,,, totVotes2,) = gov.proposals(proposal2);
        (,,,,, totVotes3,) = gov.proposals(proposal3);
        assertEq(totVotes1, user1LockedAmt);
        assertEq(totVotes2, user1LockedAmt);
        assertEq(totVotes3, 0);

        // Vote will full rights on proposal 3
        user1.doVote(proposal3, gov.numSnapshots(address(user1)), user1LockedAmt);
        (,,,,, totVotes1,) = gov.proposals(proposal1);
        (,,,,, totVotes2,) = gov.proposals(proposal2);
        (,,,,, totVotes3,) = gov.proposals(proposal3);
        assertEq(totVotes1, user1LockedAmt);
        assertEq(totVotes2, user1LockedAmt);
        assertEq(totVotes3, user1LockedAmt);

        // Remove all votes from proposal 1
        user1.doVote(proposal1, gov.numSnapshots(address(user1)), 0);
        (,,,,, totVotes1,) = gov.proposals(proposal1);
        (,,,,, totVotes2,) = gov.proposals(proposal2);
        (,,,,, totVotes3,) = gov.proposals(proposal3);
        assertEq(totVotes1, 0);
        assertEq(totVotes2, user1LockedAmt);
        assertEq(totVotes3, user1LockedAmt);

        // Remove all votes from proposal 2
        user1.doVote(proposal2, gov.numSnapshots(address(user1)), 0);
        (,,,,, totVotes1,) = gov.proposals(proposal1);
        (,,,,, totVotes2,) = gov.proposals(proposal2);
        (,,,,, totVotes3,) = gov.proposals(proposal3);
        assertEq(totVotes1, 0);
        assertEq(totVotes2, 0);
        assertEq(totVotes3, user1LockedAmt);

        // Remove half of voting rights from proposal 3
        user1.doVote(proposal3, gov.numSnapshots(address(user1)), user1LockedAmt / 2);
        (,,,,, totVotes1,) = gov.proposals(proposal1);
        (,,,,, totVotes2,) = gov.proposals(proposal2);
        (,,,,, totVotes3,) = gov.proposals(proposal3);
        assertEq(totVotes1, 0);
        assertEq(totVotes2, 0);
        assertEq(totVotes3, user1LockedAmt / 2);
    }

    function test_system_execution() public {
        _launch();

        user1.doLock(user1InitialBalance);
        _warp(1);

        uint256 proposal = user1.doPropose(exec12, action1);
        (,,,,,, uint256 status) = gov.proposals(proposal);
        assertEq(status, gov.PROPOSAL_PENDING());

        user1.doVote(proposal, gov.numSnapshots(address(user1)), user1InitialBalance);

        gov.plot(proposal);
        (,,,,,, status) = gov.proposals(proposal);
        assertEq(status, gov.PROPOSAL_SCHEDULED());
        assertEq(system.executed(), 0);

        _warp(12 hours / 15 + 1);
        gov.exec(proposal);
        (,,,,,, status) = gov.proposals(proposal);
        assertEq(status, gov.PROPOSAL_EXECUTED());
    }

    function testFail_system_execution_not_delay() public {
        _launch();

        user1.doLock(user1InitialBalance);
        _warp(1);

        uint256 proposal = user1.doPropose(exec12, action1);
        user1.doVote(proposal, gov.numSnapshots(address(user1)), user1InitialBalance);

        gov.plot(proposal);
        gov.exec(proposal);
    }

    function testFail_system_execution_not_plotted() public {
        _launch();

        user1.doLock(user1InitialBalance);
        _warp(1);

        uint256 proposal = user1.doPropose(exec12, action1);
        user1.doVote(proposal, gov.numSnapshots(address(user1)), user1InitialBalance);

        gov.exec(proposal);
    }

    function test_drop() public {
        _launch();

        user1.doLock(user1InitialBalance);
        _warp(1);

        uint256 proposal = user1.doPropose(exec12, action1);

        user1.doVote(proposal, gov.numSnapshots(address(user1)), user1InitialBalance);

        gov.plot(proposal);
        (,,,,,, uint256 status) = gov.proposals(proposal);
        assertEq(status, gov.PROPOSAL_SCHEDULED());

        user2.doLock(user2InitialBalance);
        uint256 proposalDrop = user2.doPropose(exec0, address(new ActionDrop(mom, proposal)));

        user1.doVote(proposalDrop, gov.numSnapshots(address(user1)), user3InitialBalance);

        gov.plot(proposalDrop);
        gov.exec(proposalDrop);

        (,,,,,, status) = gov.proposals(proposal);
        assertEq(status, gov.PROPOSAL_CANCELLED());
    }

    function test_set_threshold() public {
        for (uint256 i = gov.MIN_THRESHOLD(); i <= gov.MAX_THRESHOLD(); i++) {
            gov.file("threshold", i);
        }
    }

    function testFail_set_threshold_under_boundary() public {
        gov.file("threshold", gov.MIN_THRESHOLD() - 1);
    }

    function testFail_set_threshold_over_boundary() public {
        gov.file("threshold", gov.MAX_THRESHOLD() + 1);
    }

    function test_mint_ping() public {
        assertEq(gov.gasOwners(address(user1), "delegated"), 0);
        assertEq(gov.gasOwners(address(user1), "delegated"), 0);
        assertEq(gov.gasOwners(address(user3), "delegated"), 0);
        assertEq(gov.gasStorageLength(), 0);
        user1.doPing();
        assertEq(gov.gasOwners(address(user1), "delegated"), 50);
        assertEq(gov.gasStorageLength(), 50);
        user2.doPing();
        assertEq(gov.gasOwners(address(user2), "delegated"), 50);
        assertEq(gov.gasStorageLength(), 100);
        user3.doPing();
        assertEq(gov.gasOwners(address(user3), "delegated"), 50);
        assertEq(gov.gasStorageLength(), 150);

        for(uint256 i = 0; i < 150; i++) {
            assertEq(gov.gasStorage(i), 1);
        }
    }

    function test_burn_clear() public {
        user1.doPing();
        user2.doPing();
        user3.doPing();
        assertEq(gov.gasStorageLength(), 150);
        _warp(gov.rightsLifetime() / 15 + 1);

        assertEq(gov.gasOwners(address(user3), "delegated"), 50);
        gov.clear(address(user3));
        assertEq(gov.gasOwners(address(user3), "delegated"), 0);
        assertEq(gov.gasStorageLength(), 100);

        for(uint256 i = 0; i < 100; i++) {
            assertEq(gov.gasStorage(i), 1);
        }
        // for(uint256 i = 100; i < 150; i++) {
        //     assertEq(gov.gasStorage(i), 0);
        // }
    }

    function test_mint_delegation() public {
        assertEq(gov.gasOwners(address(user1), "owner"), 0);
        assertEq(gov.gasOwners(address(user1), "owner"), 0);
        assertEq(gov.gasOwners(address(user3), "owner"), 0);
        assertEq(gov.gasStorageLength(), 0);
        user1.doDelegate(address(user1), address(user1));
        assertEq(gov.gasOwners(address(user1), "owner"), 50);
        assertEq(gov.gasStorageLength(), 50);
        user2.doDelegate(address(user2), address(user2));
        assertEq(gov.gasOwners(address(user2), "owner"), 50);
        assertEq(gov.gasStorageLength(), 100);
        user3.doDelegate(address(user3), address(user3));
        assertEq(gov.gasOwners(address(user3), "owner"), 50);
        assertEq(gov.gasStorageLength(), 150);

        for(uint256 i = 0; i < 150; i++) {
            assertEq(gov.gasStorage(i), 1);
        }
    }

    function test_burn_delegation() public {
        user1.doDelegate(address(user1), address(user1));
        user2.doDelegate(address(user2), address(user2));
        user3.doDelegate(address(user3), address(user3));
        assertEq(gov.gasStorageLength(), 150);
        _warp(gov.delegationLifetime() / 15 + 1);

        assertEq(gov.gasOwners(address(user3), "owner"), 50);
        gov.delegate(address(user3), address(0));
        assertEq(gov.gasOwners(address(user3), "owner"), 0);
        assertEq(gov.gasStorageLength(), 100);

        for(uint256 i = 0; i < 100; i++) {
            assertEq(gov.gasStorage(i), 1);
        }
        // for(uint256 i = 100; i < 150; i++) {
        //     assertEq(gov.gasStorage(i), 0);
        // }
    }

    function test_mint_burn_different_amounts() public {
        assertEq(gov.gasStorageLength(), 0);
        user1.doPing();
        assertEq(gov.gasStorageLength(), 50);
        user2.doPing();
        assertEq(gov.gasStorageLength(), 100);

        gov.file("gasStakeAmt", 30);

        user3.doPing();
        assertEq(gov.gasStorageLength(), 130);

        _warp(gov.rightsLifetime() / 15 + 1);

        gov.clear(address(user2));
        assertEq(gov.gasStorageLength(), 80);

        gov.clear(address(user3));
        assertEq(gov.gasStorageLength(), 50);

        gov.clear(address(user1));
        assertEq(gov.gasStorageLength(), 0);
    }

    function test_proposer_propose() public {
        _launch();
        gov.addProposer(address(user3));
        user3.doPropose(exec12, action1);
        user3.doPropose(exec12, action1);
        user3.doPropose(exec12, action1);
    }

    function testFail_proposer_propose_max_exceed() public {
        _launch();
        gov.addProposer(address(user3));
        user3.doPropose(exec12, action1);
        user3.doPropose(exec12, action1);
        user3.doPropose(exec12, action1);
        user3.doPropose(exec12, action1);
    }

    function test_proposer_propose_two_days() public {
        _launch();
        gov.addProposer(address(user3));
        user3.doPropose(exec12, action1);
        user3.doPropose(exec12, action1);
        user3.doPropose(exec12, action1);
        _warp(1 days / 15 + 1);
        user3.doPropose(exec12, action1);
        user3.doPropose(exec12, action1);
        user3.doPropose(exec12, action1);
    }
}
