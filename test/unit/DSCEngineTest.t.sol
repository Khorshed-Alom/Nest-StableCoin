// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DeployDSC} from "script/DeployDSC.s.sol";
import {Test, console} from "lib/forge-std/src/Test.sol";
import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {DSCEngine} from "src/DSCEngine.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";
import {ERC20Mock} from "test/mocks/ERC20Mock.sol";


contract DSCEngineTest is Test {

    DeployDSC public deployer;
    DecentralizedStableCoin public dsc;
    DSCEngine public dsce;
    HelperConfig public config;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;
    address wbtc;

    address public USER = makeAddr("USER");
    address public ALICE = makeAddr("ALICE");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_USER_BALANCE = 10 ether;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc, ) = config.activeNetworkConfig();
        ERC20Mock(weth).mint(USER, STARTING_USER_BALANCE);
        ERC20Mock(wbtc).mint(ALICE, STARTING_USER_BALANCE);
    }

    /*<==================== Modifiers ====================>*/
    /*_____________________________________________________*/
    modifier depositedUSERCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    modifier depositedALICECollateral() {
        vm.startPrank(ALICE);
        ERC20Mock(wbtc).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(wbtc, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    // modifier depositedUSERCollateralAndMigntDsc() {
    //     vm.startPrank(USER);
    //     ERC20Mock(weth).mint(USER, STARTING_USER_BALANCE);
    //     ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
    //     dsce.depositeCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountDsc);
    //     vm.stopPrank();
    // }

    /*<==================== Constructor Test ====================>*/
    /*____________________________________________________________*/
    address[] public tokenAddresses;
    address[] public priceFeedsAddresses;
    function testRevertIfTokenLengthDosentMatchPriceFeeds() public {
        tokenAddresses.push(ethUsdPriceFeed);
        priceFeedsAddresses.push(ethUsdPriceFeed);
        priceFeedsAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceAddressesMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedsAddresses, address(dsc));
    }

    /*<==================== Price Test ====================>*/
    /*______________________________________________________*/
    function testGetUsdValue() public view {
        uint256 ethAmount = 15 ether;//15e18;
        // 15ETH * 2000 usd = $30,000e18
        uint256 axpectedUsd = 30000e18;
        uint256 actualUsd = dsce.getUsdValue(weth, ethAmount);
        
        assert(axpectedUsd == actualUsd);
    }

    function testgetTokenAmountFromUsd() public view {
        // If we want $100 of WETH, $2000/WETH, that would be 0.05 WETH
        uint256 expectedWeth = 0.05 ether;
        uint256 amountWeth = dsce.getTokenAmountFromUsd(weth, 100 ether);
        assertEq(amountWeth, expectedWeth);
    }

    /*<==================== Collateral Test ====================>*/
    /*____________________________________________________________________*/
    function testIfCollateranZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock randomToken = new ERC20Mock("RANDOM", "RANDOM", USER, AMOUNT_COLLATERAL);

        vm.startPrank(USER);
        // This selected revert is reverting with token address, So, we need to ancode it with token address.
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__TokenNotAllowed.selector, address(randomToken)));
        dsce.depositCollateral(address(randomToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testCanDepositedCollateralAndGetAccountInfo() public depositedUSERCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);
        uint256 expectedDepositedAmount = dsce.getTokenAmountFromUsd(weth, collateralValueInUsd);
        uint256 depositedCollateralValue = 20000e18; // 1 ether = 2000e18, 10 ether = 20000e18

        assertEq(totalDscMinted, 0);
        assertEq(expectedDepositedAmount, AMOUNT_COLLATERAL);
        assertEq(collateralValueInUsd, depositedCollateralValue);
    }

    function testDepositeCollateralAndMintDsc() public depositedUSERCollateral depositedALICECollateral {
        uint256 amountDsc = 1000;
        uint256 wethExpectedValue = 20000e18;
        uint256 wbtcExpectedValue = 10000e18;
        // vm.startPrank(USER);
        // ERC20Mock(weth).mint(USER, STARTING_USER_BALANCE);
        // ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        // dsce.depositeCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountDsc);
        // vm.stopPrank();

        // vm.startPrank(ALICE);
        // ERC20Mock(wbtc).mint(ALICE, STARTING_USER_BALANCE);
        // ERC20Mock(wbtc).approve(address(dsce), AMOUNT_COLLATERAL);
        // dsce.depositeCollateralAndMintDsc(wbtc, AMOUNT_COLLATERAL, amountDsc);
        // vm.stopPrank();

        (uint256 totalUerDsc, uint256 wethcollateralValurInUsd) = dsce.getAccountInformation(USER);
        (uint256 totalAliceDsc, uint256 wbtccollateralValurInUsd) = dsce.getAccountInformation(ALICE);

        assertEq(totalUerDsc, amountDsc);
        assertEq(wethcollateralValurInUsd, wethExpectedValue);
        assertEq(totalUerDsc, amountDsc);
        assertEq(wbtccollateralValurInUsd, wbtcExpectedValue);

    }

    
    function testCanDepositCollateralWithoutMinting() public depositedUSERCollateral {
        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, 0);
    }

    // function testRevertsIfTransferFromFails() public {}
    // function testRevertsWithUnapprovedCollateral() public {}

    /*<==================== Health Factor Test ====================>*/
    /*______________________________________________________________*/
    function testRevertIfHealthFactorIsBad() public depositedUSERCollateral {
        vm.startPrank(USER);
        uint256 totalDscWillMinth = 10001;
        uint256 collateralValueInUsd = 20000e18;
        uint256 userHealth = dsce.getCalculatedHealthFactor(totalDscWillMinth, collateralValueInUsd);

        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreacksHealthFactor.selector, userHealth));
        dsce.mintDsc(10001); // deposited 10 ether = $20,000 , healt should broke above 10,000 dec minting
        vm.stopPrank();
    }

    function test_healthFactorCanCalculateCurrectly() public depositedUSERCollateral {
        vm.prank(USER);
        dsce.mintDsc(10000); // 10,000

        uint256 expectedHealth = 1e18;
        uint256 actualHealth = dsce.getHealthFactor(USER);

        assertEq(expectedHealth, actualHealth);
    }

    /*<==================== liquidation Test ====================>*/
    /*____________________________________________________________*/
    /*function testAnyoneCanLiquidateABadUser() public depositedUSERCollateral depositedALICECollateral {
        // Arrange
        address liquidator = address(ALICE);
        uint256 debtToCover = 15000;
        uint256 extraDsc = 5000;

        vm.prank(USER);
        dsce.mintDsc(10000);
        dsce.getBadDscMinted(USER, extraDsc);
        
        uint256 expectedLiquidatorCollateralValue = dsce.getAccountCollateralValue(USER);
        uint256 expectedLiquidatorCollateral = dsce.getTokenAmountFromUsd(weth, expectedLiquidatorCollateralValue);
        vm.prank(liquidator);
        dsce.liquidate(weth, USER, debtToCover);

        // Act
        uint256 liquidatorCollateralValue = dsce.getAccountCollateralValue(liquidator);
        uint256 liquidatorBonusCollateraValue = (expectedLiquidatorCollateralValue * 10) / 100; // 10%
        uint256 liquidatorCollateral = dsce.getTokenAmountFromUsd(weth, liquidatorCollateralValue);
        uint256 liquidatorBonusCollateral = (expectedLiquidatorCollateral * 10) / 100; // 10%

        // Assert
        assertEq(liquidatorCollateralValue, liquidatorBonusCollateraValue);
        assertEq(liquidatorCollateral, liquidatorBonusCollateral);
    }*/

    function testLiquidationRevertIfHealthIsGood() public depositedUSERCollateral depositedALICECollateral {
        // Arrange
        address liquidator = address(ALICE);
        uint256 debtToCover = 100;
        vm.prank(USER);
        dsce.mintDsc(10000);
        
        vm.prank(liquidator);
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
        dsce.liquidate(weth, USER, debtToCover);
    }

    /*<==================== Random Tests ====================>*/
    /*________________________________________________________*/
    function testcollateralTokenaddresses() public view {
        address[] memory collateral = dsce.getCollateralTokens();

        console.log("weth address", collateral[0]);
        console.log("wbtc address", collateral[1]);

        assertEq(collateral[0], weth);
        assertEq(collateral[1], wbtc);
    }
}