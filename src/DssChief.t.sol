pragma solidity ^0.5.12;

import "ds-test/test.sol";
import { DSAuth, DSAuthority, DSToken } from "ds-token/token.sol";

import { DssChief } from "./DssChief.sol";

contract Hevm {
    function warp(uint) public;
}

contract ChiefUser {
    DssChief chief;

    constructor(DssChief chief_) public {
        chief = chief_;
    }

    function doTransferFrom(DSToken token, address from, address to,
                            uint amount)
        public
        returns (bool)
    {
        return token.transferFrom(from, to, amount);
    }

    function doTransfer(DSToken token, address to, uint amount)
        public
        returns (bool)
    {
        return token.transfer(to, amount);
    }

    function doApprove(DSToken token, address recipient, uint amount)
        public
        returns (bool)
    {
        return token.approve(recipient, amount);
    }

    function doAllowance(DSToken token, address owner, address spender)
        public view
        returns (uint)
    {
        return token.allowance(owner, spender);
    }

    function doVote(address whom) public {
        chief.vote(whom);
    }

    function doUndo(ChiefUser usr, address whom) public {
        chief.undo(address(usr), whom);
    }

    function doLock(uint wad) public {
        chief.lock(wad);
    }

    function doFree(ChiefUser usr, uint wad) public {
        chief.free(address(usr), wad);
    }
}

contract CandidateUser {
    System sys;

    constructor(System sys_) public {
        sys = sys_;
    }

    function doSysTest() public {
        sys.test();
    }
}

contract System is DSAuth {
    function test() public auth {}
}

contract DssChiefTest is DSTest {
    uint256 constant user1InitialBalance = 350 ether;
    uint256 constant user2InitialBalance = 250 ether;
    uint256 constant user3InitialBalance = 200 ether;

    Hevm hevm;

    DssChief chief;
    DSToken gov;

    ChiefUser user1;
    ChiefUser user2;
    ChiefUser user3;

    address candidate1;
    address candidate2;
    address candidate3;

    System sys; // Mocked System to authed via chief

    function setUp() public {
        // init hevm
        hevm = Hevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
        hevm.warp(0);

        gov = new DSToken("GOV");
        gov.mint(1000 ether);

        chief = new DssChief(address(gov));
        chief.file("ttl", 100);
        chief.file("end", 200);

        sys = new System();
        sys.setAuthority(DSAuthority(address(chief)));

        user1 = new ChiefUser(chief);
        user2 = new ChiefUser(chief);
        user3 = new ChiefUser(chief);

        candidate1 = address(new CandidateUser(sys));
        candidate2 = address(new CandidateUser(sys));
        candidate3 = address(new CandidateUser(sys));

        gov.transfer(address(user1), user1InitialBalance);
        gov.transfer(address(user2), user2InitialBalance);
        gov.transfer(address(user3), user3InitialBalance);

        user3.doApprove(gov, address(chief), uint(-1));
        user2.doApprove(gov, address(chief),  uint(-1));
        user1.doApprove(gov, address(chief),  uint(-1));
    }

    function test_lock_debits_user() public {
        assertEq(gov.balanceOf(address(user1)), user1InitialBalance);

        uint lockedAmt = user1InitialBalance / 10;
        user1.doApprove(gov, address(chief), lockedAmt);
        user1.doLock(lockedAmt);

        assertEq(gov.balanceOf(address(user1)), user1InitialBalance - lockedAmt);
    }

    function test_free() public {
        uint user1LockedAmt = user1InitialBalance / 2;
        user1.doApprove(gov, address(chief), user1LockedAmt);
        user1.doLock(user1LockedAmt);
        assertEq(gov.balanceOf(address(user1)), user1InitialBalance - user1LockedAmt);
        hevm.warp(1);
        user1.doFree(user1, user1LockedAmt);
        assertEq(gov.balanceOf(address(user1)), user1InitialBalance);
    }

    function testFail_free_same_time() public {
        uint user1LockedAmt = user1InitialBalance / 2;
        user1.doApprove(gov, address(chief), user1LockedAmt);
        user1.doLock(user1LockedAmt);
        user1.doFree(user1, user1LockedAmt);
    }

    function test_voting_unvoting() public {
        uint user1LockedAmt = user1InitialBalance / 2;
        user1.doLock(user1LockedAmt);

        assertEq(chief.count(address(user1)), 0);
        assertEq(chief.approvals(candidate1), 0);
        assertEq(chief.approvals(candidate2), 0);
        assertEq(chief.approvals(candidate3), 0);

        user1.doVote(candidate1);
        assertEq(chief.count(address(user1)), 1);
        assertEq(chief.approvals(candidate1), user1LockedAmt);
        assertEq(chief.approvals(candidate2), 0);
        assertEq(chief.approvals(candidate3), 0);

        user1.doVote(candidate2);
        assertEq(chief.count(address(user1)), 2);
        assertEq(chief.approvals(candidate1), user1LockedAmt);
        assertEq(chief.approvals(candidate2), user1LockedAmt);
        assertEq(chief.approvals(candidate3), 0);

        user1.doVote(candidate3);
        assertEq(chief.count(address(user1)), 3);
        assertEq(chief.approvals(candidate1), user1LockedAmt);
        assertEq(chief.approvals(candidate2), user1LockedAmt);
        assertEq(chief.approvals(candidate3), user1LockedAmt);

        user1.doUndo(user1, candidate1);
        assertEq(chief.count(address(user1)), 2);
        assertEq(chief.approvals(candidate1), 0);
        assertEq(chief.approvals(candidate2), user1LockedAmt);
        assertEq(chief.approvals(candidate3), user1LockedAmt);

        user1.doUndo(user1, candidate2);
        assertEq(chief.count(address(user1)), 1);
        assertEq(chief.approvals(candidate1), 0);
        assertEq(chief.approvals(candidate2), 0);
        assertEq(chief.approvals(candidate3), user1LockedAmt);

        user1.doUndo(user1, candidate3);
        assertEq(chief.count(address(user1)), 0);
        assertEq(chief.approvals(candidate1), 0);
        assertEq(chief.approvals(candidate2), 0);
        assertEq(chief.approvals(candidate3), 0);

        hevm.warp(1);
        user1.doFree(user1, user1LockedAmt);
    }

    function testFail_lock_when_voting() public {
        uint user1LockedAmt = user1InitialBalance / 2;
        user1.doLock(user1LockedAmt);

        user1.doVote(candidate1);

        hevm.warp(1);
        user1.doLock(1);
    }

    function testFail_free_when_voting() public {
        uint user1LockedAmt = user1InitialBalance / 2;
        user1.doLock(user1LockedAmt);

        user1.doVote(candidate1);

        hevm.warp(1);
        user1.doFree(user1, 1);
    }

    function test_basic_lift_sys_test() public {
        user2.doLock(user2InitialBalance);

        user2.doVote(candidate1);
        CandidateUser(candidate1).doSysTest();
    }

    function testFail_sys_test_not_elected() public {
        CandidateUser(candidate1).doSysTest();
    }

    function _trySysTest(address usr) internal returns (bool ok) {
        (ok,) = address(usr).call(abi.encodeWithSignature("doSysTest()"));
    }

    function test_lift() public {
        user3.doLock(user3InitialBalance);
        user2.doLock(user2InitialBalance);
        user1.doLock(user1InitialBalance);

        user1.doVote(candidate1);
        user2.doVote(candidate2);
        user3.doVote(candidate3);
        assertEq(chief.approvals(candidate1), 350 ether);
        assertEq(chief.approvals(candidate2), 250 ether);
        assertEq(chief.approvals(candidate3), 200 ether);
        assertTrue(!_trySysTest(candidate1)); // candidate1 ~ 43% => can't execute

        user3.doUndo(user3, candidate3);
        user3.doVote(candidate2);
        assertEq(chief.approvals(candidate1), 350 ether);
        assertEq(chief.approvals(candidate2), 450 ether);
        assertEq(chief.approvals(candidate3), 0);
        assertTrue(_trySysTest(candidate2)); // candidate2 ~ 56% => can execute

        user3.doUndo(user3, candidate2);
        hevm.warp(1);
        user3.doFree(user3, 100 ether);
        user3.doVote(candidate2);
        assertEq(chief.approvals(candidate1), 350 ether);
        assertEq(chief.approvals(candidate2), 350 ether);
        assertEq(chief.approvals(candidate3), 0);
        assertTrue(!_trySysTest(candidate2)); // candidate2 = 50% => can't execute

        user3.doUndo(user3, candidate2);
        user3.doLock(1);
        user3.doVote(candidate2);
        assertEq(chief.approvals(candidate1), 350 ether);
        assertEq(chief.approvals(candidate2), 350 ether + 1);
        assertEq(chief.approvals(candidate3), 0);
        assertTrue(_trySysTest(candidate2)); // candidate2 > 50% => can execute

        hevm.warp(200);
        assertTrue(_trySysTest(candidate2)); // candidate2 => still can execute

        hevm.warp(201);
        assertTrue(!_trySysTest(candidate2)); // candidate2 => can't execute as it is expired
    }

    function test_undo_other_user() public {
        user3.doVote(candidate1);
        hevm.warp(chief.ttl() + 1);
        user1.doUndo(user3, candidate1);
    }

    function testFail_undo_other_user() public {
        user3.doVote(candidate1);
        hevm.warp(chief.ttl());
        user1.doUndo(user3, candidate1);
    }

    function test_free_other_user() public {
        user3.doLock(user3InitialBalance);
        hevm.warp(chief.ttl() + 1);
        user1.doFree(user3, user3InitialBalance);
    }

    function testFail_free_other_user_not_time_passed() public {
        user3.doLock(user3InitialBalance);
        hevm.warp(chief.ttl());
        user1.doFree(user3, user3InitialBalance);
    }

    function test_min_first_vote() public {
        chief.file("min", 50);
        user3.doLock(50);
        assertEq(chief.deposits(address(user3)), 50);
        user3.doVote(candidate1);
        user2.doLock(49);
        assertEq(chief.deposits(address(user2)), 49);
        user2.doVote(candidate1);
    }

    function testFail_min_first_vote() public {
        chief.file("min", 50);
        user3.doLock(49);
        user3.doVote(candidate1);
    }
}
