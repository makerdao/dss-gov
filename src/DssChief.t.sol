pragma solidity ^0.6.7;

import "ds-test/test.sol";
import { DSToken } from "ds-token/token.sol";

import { DssChief } from "./DssChief.sol";

import { ChiefExec } from "./ChiefExec.sol";

import { ChiefMom } from "./ChiefMom.sol";

interface Hevm {
    function warp(uint256) external;
    function roll(uint256) external;
}

contract ChiefUser {
    DssChief chief;

    constructor(DssChief chief_) public {
        chief = chief_;
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
        chief.ping();
    }

    function doLock(uint256 wad) public {
        chief.lock(wad);
    }

    function doFree(uint256 wad) public {
        chief.free(wad);
    }

    function doDelegate(address usr) public {
        chief.delegate(usr);
    }

    function doPropose(address exec, address action) public returns (uint256 id) {
        id = chief.propose(exec, action);
    }

    function doVote(uint256 proposal, uint256 wad, uint256 sId) public {
        chief.vote(proposal, wad, sId);
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
    ChiefMom immutable mom;
    uint256 immutable proposal;

    constructor(address mom_, uint256 proposal_) public {
        mom = ChiefMom(mom_);
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

contract DssChiefTest is DSTest {
    uint256 constant user1InitialBalance = 350000 ether;
    uint256 constant user2InitialBalance = 250000 ether;
    uint256 constant user3InitialBalance = 200000 ether;

    Hevm hevm;

    DssChief chief;
    address exec0;
    address exec12;
    address mom;
    DSToken gov;

    ChiefUser user1;
    ChiefUser user2;
    ChiefUser user3;

    System system; // Mocked System to authed via chief

    address action1;
    address action2;
    address action3;

    uint256 actualBlock;

    function setUp() public {
        // init hevm
        hevm = Hevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
        hevm.warp(0);

        gov = new DSToken("GOV");
        gov.mint(1000000 ether);

        // Chief set up
        chief = new DssChief(address(gov));
        chief.file("depositLifetime", 30 days);
        chief.file("proposalLifetime", 7 days);
        chief.file("threshold", 50); // 50%
        chief.file("gasStakeAmt", 50); // 50 slots of storage

        exec12 = address(new ChiefExec(address(chief), 12 hours));
        exec0 = address(new ChiefExec(address(chief), 0));
        mom = address(new ChiefMom(exec0, address(chief)));

        chief.rely(exec12);
        chief.rely(mom);
        //

        system = new System();
        system.rely(exec12);

        user1 = new ChiefUser(chief);
        user2 = new ChiefUser(chief);
        user3 = new ChiefUser(chief);

        action1 = address(new ActionProposal(address(system)));
        action2 = address(new ActionProposal(address(system)));
        action3 = address(new ActionProposal(address(system)));

        gov.transfer(address(user1), user1InitialBalance);
        gov.transfer(address(user2), user2InitialBalance);
        gov.transfer(address(user3), user3InitialBalance);

        user3.doApprove(gov, address(chief), uint256(-1));
        user2.doApprove(gov, address(chief),  uint256(-1));
        user1.doApprove(gov, address(chief),  uint256(-1));

        hevm.warp(1599683711);
        hevm.roll(actualBlock = 10829728);
    }

    function _warp(uint256 nBlocks) internal {
        actualBlock += nBlocks;
        hevm.roll(actualBlock);
        hevm.warp(now + nBlocks * 15);
    }

    function test_lock_debits_user() public {
        assertEq(gov.balanceOf(address(user1)), user1InitialBalance);

        uint256 lockedAmt = user1InitialBalance / 10;
        user1.doApprove(gov, address(chief), lockedAmt);
        user1.doLock(lockedAmt);

        assertEq(gov.balanceOf(address(user1)), user1InitialBalance - lockedAmt);
    }

    function test_free() public {
        uint256 user1LockedAmt = user1InitialBalance / 2;
        user1.doApprove(gov, address(chief), user1LockedAmt);
        user1.doLock(user1LockedAmt);
        assertEq(gov.balanceOf(address(user1)), user1InitialBalance - user1LockedAmt);
        hevm.warp(1);
        user1.doFree(user1LockedAmt);
        assertEq(gov.balanceOf(address(user1)), user1InitialBalance);
    }

    function test_delegate() public {
        assertEq(chief.delegates(address(user1)), address(0));
        assertEq(chief.rights(address(user2)), 0);
        user1.doLock(user1InitialBalance);
        user1.doDelegate(address(user2));
        assertEq(chief.delegates(address(user1)), address(user2));
        assertEq(chief.rights(address(user2)), user1InitialBalance);
    }

    function test_snapshot() public {
        uint256 originalBlockNumber = block.number;

        assertEq(chief.numSnapshots(address(user1)), 0);

        user1.doLock(user1InitialBalance);

        _warp(1);
        user1.doPing();

        uint256 num = chief.numSnapshots(address(user1));
        assertEq(chief.numSnapshots(address(user1)), num);
        (uint256 fromBlock, uint256 rights) = chief.snapshots(address(user1), num);
        assertEq(fromBlock, originalBlockNumber + 1);
        assertEq(rights, 0);

        _warp(1);
        user1.doDelegate(address(user1));

        num = chief.numSnapshots(address(user1));
        assertEq(chief.numSnapshots(address(user1)), 2);
        (fromBlock, rights) = chief.snapshots(address(user1), num);
        assertEq(fromBlock, originalBlockNumber + 2);
        assertEq(rights, user1InitialBalance);
    }

    function test_ping() public {
        user1.doLock(user1InitialBalance);
        user1.doDelegate(address(user1));
        assertEq(chief.active(address(user1)), 0);
        assertEq(chief.totActive(), 0);
        user1.doPing();
        assertEq(chief.active(address(user1)), 1);
        assertEq(chief.totActive(), user1InitialBalance);
    }

    function test_clear() public {
        user1.doLock(user1InitialBalance);
        user1.doDelegate(address(user1));
        user1.doPing();
        assertEq(chief.active(address(user1)), 1);
        assertEq(chief.totActive(), user1InitialBalance);
        _warp(chief.depositLifetime() / 15 + 1);
        chief.clear(address(user1));
        assertEq(chief.active(address(user1)), 0);
        assertEq(chief.totActive(), 0);
    }

    function _tryLaunch() internal returns (bool ok) {
        (ok,) = address(chief).call(abi.encodeWithSignature("launch()"));
    }

    function test_launch() public {
        assertEq(chief.live(), 0);
        assertTrue(!_tryLaunch());
        user1.doLock(75000 ether);
        assertTrue(!_tryLaunch());
        user2.doLock(25000 ether);
        assertTrue(!_tryLaunch());
        user1.doPing();
        user1.doDelegate(address(user1));
        assertTrue(!_tryLaunch());
        user2.doPing();
        user2.doDelegate(address(user2));
        assertTrue(_tryLaunch());
    }

    function _launch() internal {
        user1.doLock(100000 ether);
        user1.doPing();
        user1.doDelegate(address(user1));
        chief.launch();
        user1.doFree(100000 ether);
    }

    function test_propose() public {
        _launch();
        user2.doPropose(exec12, action1);
    }

    function test_voting_unvoting() public {
        _launch();

        uint user1LockedAmt = user1InitialBalance / 2;
        user1.doLock(user1LockedAmt);

        _warp(1);

        uint256 proposal1 = user1.doPropose(exec12, action1);
        uint256 proposal2 = user2.doPropose(exec12, action2);
        uint256 proposal3 = user3.doPropose(exec12, action3);

        (,,,,, uint256 totVotes1,) = chief.proposals(proposal1);
        (,,,,, uint256 totVotes2,) = chief.proposals(proposal2);
        (,,,,, uint256 totVotes3,) = chief.proposals(proposal3);
        assertEq(totVotes1, 0);
        assertEq(totVotes2, 0);
        assertEq(totVotes3, 0);

        // Vote will full rights on proposal 1
        user1.doVote(proposal1, user1LockedAmt, chief.numSnapshots(address(user1)));
        (,,,,, totVotes1,) = chief.proposals(proposal1);
        (,,,,, totVotes2,) = chief.proposals(proposal2);
        (,,,,, totVotes3,) = chief.proposals(proposal3);
        assertEq(totVotes1, user1LockedAmt);
        assertEq(totVotes2, 0);
        assertEq(totVotes3, 0);

        // Vote will full rights on proposal 2
        user1.doVote(proposal2, user1LockedAmt, chief.numSnapshots(address(user1)));
        (,,,,, totVotes1,) = chief.proposals(proposal1);
        (,,,,, totVotes2,) = chief.proposals(proposal2);
        (,,,,, totVotes3,) = chief.proposals(proposal3);
        assertEq(totVotes1, user1LockedAmt);
        assertEq(totVotes2, user1LockedAmt);
        assertEq(totVotes3, 0);

        // Vote will full rights on proposal 3
        user1.doVote(proposal3, user1LockedAmt, chief.numSnapshots(address(user1)));
        (,,,,, totVotes1,) = chief.proposals(proposal1);
        (,,,,, totVotes2,) = chief.proposals(proposal2);
        (,,,,, totVotes3,) = chief.proposals(proposal3);
        assertEq(totVotes1, user1LockedAmt);
        assertEq(totVotes2, user1LockedAmt);
        assertEq(totVotes3, user1LockedAmt);

        // Remove all votes from proposal 1
        user1.doVote(proposal1, 0, chief.numSnapshots(address(user1)));
        (,,,,, totVotes1,) = chief.proposals(proposal1);
        (,,,,, totVotes2,) = chief.proposals(proposal2);
        (,,,,, totVotes3,) = chief.proposals(proposal3);
        assertEq(totVotes1, 0);
        assertEq(totVotes2, user1LockedAmt);
        assertEq(totVotes3, user1LockedAmt);

        // Remove all votes from proposal 2
        user1.doVote(proposal2, 0, chief.numSnapshots(address(user1)));
        (,,,,, totVotes1,) = chief.proposals(proposal1);
        (,,,,, totVotes2,) = chief.proposals(proposal2);
        (,,,,, totVotes3,) = chief.proposals(proposal3);
        assertEq(totVotes1, 0);
        assertEq(totVotes2, 0);
        assertEq(totVotes3, user1LockedAmt);

        // Remove half of voting rights from proposal 3
        user1.doVote(proposal3, user1LockedAmt / 2, chief.numSnapshots(address(user1)));
        (,,,,, totVotes1,) = chief.proposals(proposal1);
        (,,,,, totVotes2,) = chief.proposals(proposal2);
        (,,,,, totVotes3,) = chief.proposals(proposal3);
        assertEq(totVotes1, 0);
        assertEq(totVotes2, 0);
        assertEq(totVotes3, user1LockedAmt / 2);
    }

    function test_system_execution() public {
        _launch();

        user1.doLock(user1InitialBalance);
        _warp(1);

        uint256 proposal = user1.doPropose(exec12, action1);
        (,,,,,, uint256 status) = chief.proposals(proposal);
        assertEq(status, chief.PROPOSAL_PENDING());

        user1.doVote(proposal, user1InitialBalance, chief.numSnapshots(address(user1)));

        chief.plot(proposal);
        (,,,,,, status) = chief.proposals(proposal);
        assertEq(status, chief.PROPOSAL_SCHEDULED());
        assertEq(system.executed(), 0);

        _warp(12 hours / 15 + 1);
        chief.exec(proposal);
        (,,,,,, status) = chief.proposals(proposal);
        assertEq(status, chief.PROPOSAL_EXECUTED());
    }

    function testFail_system_execution_not_delay() public {
        _launch();

        user1.doLock(user1InitialBalance);
        _warp(1);

        uint256 proposal = user1.doPropose(exec12, action1);
        user1.doVote(proposal, user1InitialBalance, chief.numSnapshots(address(user1)));

        chief.plot(proposal);
        chief.exec(proposal);
    }

    function testFail_system_execution_not_plotted() public {
        _launch();

        user1.doLock(user1InitialBalance);
        _warp(1);

        uint256 proposal = user1.doPropose(exec12, action1);
        user1.doVote(proposal, user1InitialBalance, chief.numSnapshots(address(user1)));

        chief.exec(proposal);
    }

    function test_drop() public {
        _launch();

        user1.doLock(user1InitialBalance);
        _warp(1);

        uint256 proposal = user1.doPropose(exec12, action1);

        user1.doVote(proposal, user1InitialBalance, chief.numSnapshots(address(user1)));

        chief.plot(proposal);
        (,,,,,, uint256 status) = chief.proposals(proposal);
        assertEq(status, chief.PROPOSAL_SCHEDULED());

        uint256 proposalDrop = user2.doPropose(exec0, address(new ActionDrop(mom, proposal)));
        _warp(1);

        user1.doVote(proposalDrop, user1InitialBalance, chief.numSnapshots(address(user1)));

        chief.plot(proposalDrop);
        chief.exec(proposalDrop);

        (,,,,,, status) = chief.proposals(proposal);
        assertEq(status, chief.PROPOSAL_CANCELLED());
    }

    function test_set_threshold() public {
        for (uint256 i = chief.MIN_THRESHOLD(); i <= chief.MAX_THRESHOLD(); i++) {
            chief.file("threshold", i);
        }
    }

    function testFail_set_threshold_under_boundary() public {
        chief.file("threshold", chief.MIN_THRESHOLD() - 1);
    }

    function testFail_set_threshold_over_boundary() public {
        chief.file("threshold", chief.MAX_THRESHOLD() + 1);
    }

    function test_mint() public {
        assertEq(chief.gasStorageLength(), 0);
        user1.doPing();
        assertEq(chief.gasStorageLength(), 50);
        user2.doPing();
        assertEq(chief.gasStorageLength(), 100);
        user3.doPing();
        assertEq(chief.gasStorageLength(), 150);

        for(uint256 i = 0; i < 150; i++) {
            assertEq(chief.gasStorage(i), 1);
        }
    }

    function test_burn() public {
        user1.doPing();
        user2.doPing();
        user3.doPing();
        assertEq(chief.gasStorageLength(), 150);
        _warp(chief.depositLifetime() / 15 + 1);

        chief.clear(address(user3));
        assertEq(chief.gasStorageLength(), 100);

        for(uint256 i = 0; i < 100; i++) {
            assertEq(chief.gasStorage(i), 1);
        }
        // for(uint256 i = 100; i < 150; i++) {
        //     assertEq(chief.gasStorage(i), 0);
        // }
    }

    function test_mint_burn_different_amounts() public {
        assertEq(chief.gasStorageLength(), 0);
        user1.doPing();
        assertEq(chief.gasStorageLength(), 50);
        user2.doPing();
        assertEq(chief.gasStorageLength(), 100);

        chief.file("gasStakeAmt", 30);

        user3.doPing();
        assertEq(chief.gasStorageLength(), 130);

        _warp(chief.depositLifetime() / 15 + 1);

        chief.clear(address(user2));
        assertEq(chief.gasStorageLength(), 80);

        chief.clear(address(user3));
        assertEq(chief.gasStorageLength(), 50);

        chief.clear(address(user1));
        assertEq(chief.gasStorageLength(), 0);
    }
}
