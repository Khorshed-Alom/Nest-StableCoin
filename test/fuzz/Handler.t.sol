// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "lib/forge-std/src/Test.sol";
import {DSCEngine} from "src/DSCEngine.sol";
import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {ERC20Mock} from "test/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "lib/chainlink-brownie-contracts/contracts/src/v0.8/tests/MockV3Aggregator.sol";

contract Handler is Test {

    DSCEngine public dsce;
    DecentralizedStableCoin public dsc;
    ERC20Mock public weth;
    ERC20Mock public wbtc;
    MockV3Aggregator public wethPriceFeed;
    MockV3Aggregator public wbtcPriceFeed;

    uint96 public constant MAX_DEPOSIT_SIZE = type(uint96).max;

    address[] usersWithCollateralDeposited;
    uint256 public mintcalled;


    constructor(DSCEngine _dscEngine,  DecentralizedStableCoin _dsc) {
        dsce = _dscEngine;
        dsc = _dsc;

        address[] memory collateralTokens = dsce.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);
        wethPriceFeed = MockV3Aggregator(dsce.getCollateralPriceFeed(address(weth)));
        wbtcPriceFeed = MockV3Aggregator(dsce.getCollateralPriceFeed(address(wbtc)));
    }

    function depositCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_SIZE);
        
        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, amountCollateral);
        collateral.approve(address(dsce), amountCollateral);

        dsce.depositCollateral(address(collateral), amountCollateral);
        vm.stopPrank();
        // might double push
        usersWithCollateralDeposited.push(msg.sender);
    }

    function mintDsc(uint256 amountDsc, uint256 adsdressSeed) public {
        if (usersWithCollateralDeposited.length == 0) {
            return;
        }
        address sender =  usersWithCollateralDeposited[adsdressSeed % usersWithCollateralDeposited.length];
        (uint256 totalDscMinted, uint256 collateralValurInUsd) = dsce.getAccountInformation(sender);

        int256 maxDscToMint = int256((collateralValurInUsd / 1e18) / 2) - int256(totalDscMinted);
        if (maxDscToMint <= 0) {
            return;
        }
        amountDsc = bound(amountDsc, 0, uint256(maxDscToMint));
        if (amountDsc == 0) {
            return;
        }
        vm.startPrank(sender);
        dsce.mintDsc(amountDsc);
        vm.stopPrank();
        mintcalled++;
    }

    function redeemCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        amountCollateral = bound(amountCollateral, 0, MAX_DEPOSIT_SIZE);
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        uint256 maxCollateralToRedeem = dsce.getCollateralBalanceOfUser(msg.sender, address(collateral));

        ( , uint256 collateralValurInUsd) = dsce.getAccountInformation(msg.sender);
        console.log("collateralValurInUsd", collateralValurInUsd);
        console.log("maxCollateralToRedeem", maxCollateralToRedeem);

        amountCollateral = bound(amountCollateral, 0, maxCollateralToRedeem);
        if (amountCollateral == 0) {
            return;
        }
        dsce.redeemCollateral(address(collateral), amountCollateral);
    }

    // Breaks our system test suite !!
    // function updateCollateralPrice(uint96 newPrice) public {
    //     int256 = int256(uint256(newPrice));
    //     wethPriceFeed.updateAnswer(newPrice);
    // }

    //helper function 
    function _getCollateralFromSeed(uint256 collateralSeed) private view returns(ERC20Mock) {
        if (collateralSeed % 2 == 0) {
            return weth;
        } else {
            return wbtc;
        }
    }
}