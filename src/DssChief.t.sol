pragma solidity ^0.5.15;

import "ds-test/test.sol";

import "./DssChief.sol";

contract DssChiefTest is DSTest {
    DssChief chief;

    function setUp() public {
        chief = new DssChief();
    }

    function testFail_basic_sanity() public {
        assertTrue(false);
    }

    function test_basic_sanity() public {
        assertTrue(true);
    }
}
