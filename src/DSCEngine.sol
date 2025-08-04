// SPDX-License-Identifier: MIT
// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// internal & private view & pure functions
// external & public view & pure functions

pragma solidity ^0.8.20;

import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "lib/chainlink-brownie-contracts/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "src/libraries/OracleLib.sol";

/**
 * @title DSCEngine
 * @author Patrick Collins
 *
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg at all times.
 * This is a stablecoin with the properties:
 * - Exogenously Collateralized
 * - Dollar Pegged
 * - Algorithmically Stable
 *
 * It is similar to DAI if DAI had no governance, no fees, and was backed by only WETH and WBTC.
 *
 * Our DSC system should always be "overcollateralized". At no point, should the value of
 * all collateral < the $ backed value of all the DSC.
 *
 * @notice This contract is the core of the Decentralized Stablecoin system. It handles all the logic
 * for minting and redeeming DSC, as well as depositing and withdrawing collateral.
 * @notice This contract is based on the MakerDAO DSS system
 * @notice For heading <====================X====================> and below ___________________________________________
 */

contract DSCEngine is ReentrancyGuard {

    /*<==================== Errors ====================>*/
    /*__________________________________________________*/
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceAddressesMustBeSameLength();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreacksHealthFactor(uint256 HealthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();
    error DSCEngine__TokenNotAllowed(address token);
    error DSCEngine__TnsufficientBalance(amount);

    /*<==================== Types ====================>*/
    /*_________________________________________________*/
    using OracleLib for AggregatorV3Interface;

    /*<==================== State Variables ====================>*/
    /*___________________________________________________________*/
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% overCollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; // This means a 10% bonus

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDSCMinted) private s_DSCMinted;
    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    /*<==================== Events ====================>*/
    /*__________________________________________________*/
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(address indexed redeemedFrom, address indexed redeeemedTo, address indexed token, uint256 amount);

    /*<==================== Modifiers ====================>*/
    /*_____________________________________________________*/
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        // if the given token is not has our pricefeed then revert. this means not allow random token.
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__TokenNotAllowed(token);
        }
        _;
    }

    /*<==================== Functions ====================>*/
    /*_____________________________________________________*/
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceAddressesMustBeSameLength();
        }
        
        // Example ETH/USD, BTC/USD, etc.
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
       
    }

    /*<==================== External Functions ====================>*/
    /*______________________________________________________________*/
    /**
    * @param tokenCollateralAddress: The ERC20 token address of the collateral you're depositing
    * @param amountCollateral: The amount of collateral you're depositing
    * @param amountDscToMint: The amount of DSC you want to mint
    * @notice This function will deposit your collateral and mint DSC in one transaction
    */
    function depositeCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    )  external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }
    
    /**
    * @param tokenCollateralAddress: The ERC20 token address of the collateral you're withdrawing
    * @param amountCollateral: The amount of collateral you're withdrawing
    * @param amountDscToBurn: The amount of DSC you want to burn
    * @notice This function will withdraw your collateral and burn DSC in one transaction
    */
    function redeemCollateralForDsc(
        address tokenCollateralAddress, 
        uint256 amountCollateral, 
        uint256 amountDscToBurn
    ) external {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
        // readeem collateral already checks health factor
    }

    /**
    * @param collateral: The ERC20 token address of the collateral you're using to make the protocol solvent again.
    * This is collateral that you're going to take from the user who is insolvent.
    * In return, you have to burn your DSC to pay off their debt, but you don't pay off your own.
    * @param user: The user who is insolvent. They have to have a _healthFactor below MIN_HEALTH_FACTOR
    * @param debtToCover: The amount of DSC you want to burn to cover the user's debt.
    *
    * @notice  You can partially liquidate a user.
    * @notice  You will get a 10% LIQUIDATION_BONUS for taking the users funds.
    * @notice  This function working assumes that the protocol will be roughly 150% overcollateralized in order for this to work.
    * @notice  A known bug would be if the protocol was only 100% collateralized, we wouldn't be able to liquidate anyone.
    * For example, if the price of the collateral plummeted before anyone could be liquidated.
    */
    function liquidate(address collateral, address user, uint256 debtToCover) external moreThanZero(debtToCover) nonReentrant {
        //need to check health factor of the user
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }
        // we want to burn their DSC "debt"
        // and take their collateral
        // bad user: $140 ETH and $100 DSC
        // debtToCover = $100
        // $100 of DSC = ??? ETH
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        // And give them a 10% bonus
        // So we are giving the liquidator $110 of WETH for 100 DSC
        // We should implement a feature to liquidate in the event the protocol is insolvent
        // And sweep extra amounts into a treasury

        // 0.05 * 0.1 = 0.055
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS / LIQUIDATION_PRECISION);
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral( user, msg.sender, collateral, totalCollateralToRedeem);
        //we need to burnDsc
        _burnDsc(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);
        // This conditional should never hit, but just in case
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /*<==================== Public Functions ====================>*/
    /*____________________________________________________________*/
    /**
    * @notice follows CEI
    * @param tokenCollateralAddress: The ERC20 token address of the collateral you're depositing
    * @param collateralAmount: The amount of collateral you're depositing
    * @notice This function will deposit your collateral and mint DSC in one transaction
    */
    function depositCollateral(address tokenCollateralAddress, uint256 collateralAmount)
        public
        moreThanZero(collateralAmount)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += collateralAmount;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, collateralAmount);
        bool succes = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), collateralAmount);
        if (!succes) {
            revert  DSCEngine__TransferFailed();
        }
    }

    function mintDsc(uint256 amountDSCToMint) public moreThanZero(amountDSCToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDSCToMint;
        // if they minted too much
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDSCToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDsc(uint256 amount) public moreThanZero(amount) {
        _burnDsc(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender); // We don't even this 
    }

    /**
    * @param tokenCollateralAddress: The ERC20 token address of the collateral you're redeeming
    * @param amountCollateral: The amount of collateral you're redeeming
    * @notice This function will redeem your collateral.
    * @notice If you have DSC minted, you will not be able to redeem until you burn your DSC
    */
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral) public moreThanZero(amountCollateral) nonReentrant {
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /*<==================== Internal Functions ====================>*/
    /*______________________________________________________________*/
    function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 amountCollateral) internal {
        if (amountCollateral > s_collateralDeposited[from][tokenCollateralAddress]) {
            revert DSCEngine__TnsufficientBalance(s_collateralDeposited[from][tokenCollateralAddress]);
        }
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if(!success) {
            revert DSCEngine__TransferFailed();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /*<==================== Private Functions ====================>*/
    /*_____________________________________________________________*/
    /**
    * @dev Low-level internal function, do not call unless the function calling it is checking for health factors being broken 
    */
    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
        s_DSCMinted[onBehalfOf] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        if(!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }

    /*<==================== Private and Internal View Pure Functions ====================>*/
    /*_______________________________________________________________________________*/
    function _getAccountInformation(address user) internal view returns(uint256 totalDscMinted, uint256 collateralValurInUsd) {
        totalDscMinted = s_DSCMinted[user];
        collateralValurInUsd = getAccountCollateralValue(user);
        return (totalDscMinted, collateralValurInUsd);
    }

    /**
    * @dev returns how close to liquidation a user is.
    * If a user below 1, then they can get liquidated.
    */
    function _healthFactor(address user) internal view returns(uint256) {
        // total dsc minted
        // total collateral value
        (uint256 totalDscMinted, uint256 cllateralValueInUsd) = _getAccountInformation(user);
        uint256 healthFactor = _calculateHealthFactor(totalDscMinted, cllateralValueInUsd);
        return healthFactor;
    }

    // checks health factor, do they have enough collateral.
    // revert if they don't.
    function _revertIfHealthFactorIsBroken(address user) internal view {
       uint256 userHealthFactor = _healthFactor(user);
       if (userHealthFactor < MIN_HEALTH_FACTOR) {
        revert DSCEngine__BreacksHealthFactor(userHealthFactor);
       }
    }

    function _getUsdValue(address token, uint256 amount) private view returns(uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price, , ,) = priceFeed.staleCheckLatestRoundData();
        // 1 ETH = 1000
        // the returned value fron CL will be 1000 * 1e18
        // Most USD pairs have 8 decimals, so we will just pretend they all do
        // We want to have everything in terms of WEI, so we add 10 zeros at the end
        return((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    function _calculateHealthFactor(
        uint256 totalDscMinted,
        uint256 collateralValueInUsd
    )
        internal
        pure
        returns (uint256)
    {
        if (totalDscMinted == 0) return type(uint256).max;
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold / totalDscMinted);
    }

    /*<==================== Public and External View Pure Functions ====================>*/
    /*______________________________________________________________________________*/
    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        // 2000/ETH. 100 DSC/2000 ETH price = 0.05 ETH
        // ($10e18 * 1e18) / (2000e8 * 1e10) = 0.05e18
        /**lets calculate-
        * Without PRECISION- $100e18 / 2000e18 = 0.05 which is same to 100 / 2000 = 0.05 but we need to have it with 18 decimals
        * then adding 1e18 fix the issue.we need to multiply the 1e18 to survive.
        */
        return ((usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION));
    }

    function getAccountCollateralValue(address user) public view returns(uint256 totalCollateralValueInUsd) {
        //Loop through each collateral token, get the amount they have deposited, and map it to the price to get the USD value.
        for(uint256 i = 0; i <  s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += _getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    function getUsdValue(address token, uint256 amount) external view returns (uint256) {
        return _getUsdValue(token, amount); // Return in wei (e18)
    }

    function getAccountInformation(address user) external view returns(uint256 totalDscMinted, uint256 collateralValurInUsd) {
        (totalDscMinted, collateralValurInUsd) = _getAccountInformation(user);
        return (totalDscMinted, collateralValurInUsd);
    }

    function getCalculatedHealthFactor(uint256 totalDscMinted, uint256 cllateralValueInUsd) external pure returns(uint256 healthFactor) {
        healthFactor = _calculateHealthFactor(totalDscMinted, cllateralValueInUsd);
        return healthFactor;
    }

    function getHealthFactor(address user) external view returns(uint256 healthFactor) {
        healthFactor = _healthFactor(user);
        return healthFactor;
    }

    function getCollateralTokens() external view returns(address[] memory) {
        return s_collateralTokens;
    }

    function getCollateralBalanceOfUser(address user, address collateralAddress) external view returns(uint256) {
        return s_collateralDeposited[user][collateralAddress];
    }

    function getCollateralPriceFeed(address token) external view returns(address) {
        return  s_priceFeeds[token];
    }

}
