// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";

/**
 * @title DSCEngine
 * @author 0xEmiya
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == 1 USD at all times.
 * This is a stablecoin with the properties:
 * - Exogenous Collateral: WETH & WBTC
 * - Dollar Pegged
 * - Algorithmic Stable
 *
 * It is similar to DAI if DAI had no governance, no fees, and was backed by only WETH and WBTC.
 *
 * Our DSCEngine system should always be "overcollateralized". At no point should the value of all collateral <= the
 * value of all the DSC.
 *
 * @notice This contract is the core of the Decentralized StableCoint system. It handles all the logic for minting
 * and redeeming DSC, as well as depositing and withdrawing collateral.
 * @notice This contract is based on the MakerDAO DSS system.
 */
contract DSCEngine {
    // errors
    error DSCEngine__TokenAddressesAndPriceFeedAddressesLengthsMustMatch();
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenNotAllowed();
    error DSCEngine__TransferFailed();
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorIsBroken(uint256 healthFactor);
    error DSCEngine__HealthFactorIsOK(address user);
    error DSCEngine__HealthFactorIsNotImproved();
    // state variables

    DecentralizedStableCoin private immutable i_dsc;

    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_BONUS = 5;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant FEED_PRECISION = 1e8;

    mapping(address collateralToken => address priceFeed) private s_priceFeeds;
    // @dev Amount of collateral depositd by user
    mapping(address user => mapping(address collateralToken => uint256 amount)) private s_collateralDeposited;
    // @dev Amount of DSC minted by user
    mapping(address user => uint256 amount) private s_DSCMinted;
    // @dev List of collateral tokens
    address[] private s_collateralTokens;

    // events
    event CollateralDeposited(
        address indexed user, address indexed tokenCollateralAddress, uint256 indexed amountCollateral
    );
    event CollateralRedeemed(
        address indexed from, address indexed to, address indexed tokenCollateralAddress, uint256 amountCollateral
    );
    // modifiers

    modifier moreThanZero(uint256 value) {
        if (value <= 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__TokenNotAllowed();
        }
        _;
    }

    // functions
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address _dscAddress) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesLengthsMustMatch();
        }
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(_dscAddress);
    }

    // external functions
    /**
     * @notice The function will deposit the user's collateral and mint the user's DSC in one transaction
     * @param tokenCollateralAddress The ERC20 token addresss of the collateral the user is depositing
     * @param amountCollateral The amount of collateral the user is depositing
     * @param amountDSCToMint The amount of DSC the user wants to mint
     */
    function depositCollateralAndMintDSC(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDSCToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDSC(amountDSCToMint);
    }

    /**
     * @notice The function will redeem the user's collateral and burn the user's DSC in one transaction
     * @param tokenCollateralAddress The ERC20 token addresss of the collateral the user is redeeming
     * @param amountCollateral The amount of collateral the user is redeeming
     * @param amountDSCToBurn The amount of DSC the user wants to burn
     */
    function redeemCollateralForDSC(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDSCToBurn)
        external
        moreThanZero(amountCollateral)
        moreThanZero(amountDSCToBurn)
        isAllowedToken(tokenCollateralAddress)
    {
        _burnDSC(amountDSCToBurn, msg.sender, msg.sender);
        _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);
        revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice The function will redeem the user's collateral
     * @param tokenCollateralAddress The ERC20 token addresss of the collateral the user is redeeming
     * @param amountCollateral The amount of collateral the user is redeeming
     */
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        external
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
    {
        _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);
        revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice This function will burn the user's DSC
     * @param amountDSCToBurn The amount of DSC the user wants to burn
     */
    function burnDSC(uint256 amountDSCToBurn) external moreThanZero(amountDSCToBurn) {
        _burnDSC(amountDSCToBurn, msg.sender, msg.sender);
        revertIfHealthFactorIsBroken(msg.sender);
    }

    function liquidate(address collateralTokenAddress, address userToBeLiquidated, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        isAllowedToken(collateralTokenAddress)
    {
        uint256 startingUserHealthFactor = _healthFactor(userToBeLiquidated);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorIsOK(userToBeLiquidated);
        }
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateralTokenAddress, debtToCover);
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;

        _redeemCollateral(
            collateralTokenAddress, tokenAmountFromDebtCovered + bonusCollateral, userToBeLiquidated, msg.sender
        );
        // of course we can't burn DSC from the user to be liquidated, we need to burn it from the liquidator
        // so we need to pass both user and msg.sender to the _burnDSC function
        _burnDSC(debtToCover, userToBeLiquidated, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(userToBeLiquidated);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorIsNotImproved();
        }
        revertIfHealthFactorIsBroken(msg.sender);
    }

    // public functions
    // https://ethereum.stackexchange.com/questions/19380/external-vs-public-best-practices

    /**
     * @notice The function to mint DSC
     * @notice the amount of DSC is in wei units.
     * @param amountDSCToMint The amount of DSC the user wants to mint
     * @dev can only mint DSC if you have enough collateral
     */
    function mintDSC(uint256 amountDSCToMint) public moreThanZero(amountDSCToMint) {
        s_DSCMinted[msg.sender] += amountDSCToMint;
        //TODO check health factor
        revertIfHealthFactorIsBroken(msg.sender);
        bool success = i_dsc.mint(msg.sender, amountDSCToMint);
        if (!success) {
            revert DSCEngine__MintFailed();
        }
    }

    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    // private functions
    function _redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral, address from, address to)
        private
    {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function _burnDSC(uint256 amountDSCToBurn, address onBehalfOf, address dscFrom) private {
        s_DSCMinted[onBehalfOf] -= amountDSCToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDSCToBurn);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDSCToBurn);
    }

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDSCMinted, uint256 collateralValueInUsd)
    {
        totalDSCMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalDSCMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        return _calculateHealthFactor(totalDSCMinted, collateralValueInUsd);
    }

    function _getUsdValue(address token, uint256 amount) private view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        // 1e8 * 1e10 / 1e18
        return (uint256(price) * amount * ADDITIONAL_FEED_PRECISION) / PRECISION;
    }

    function _calculateHealthFactor(uint256 totalDSCMinted, uint256 collateralValueInUsd)
        private
        pure
        returns (uint256)
    {
        if (totalDSCMinted == 0) {
            return type(uint256).max;
        }
        uint256 collateralThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralThreshold * PRECISION) / totalDSCMinted;
    }

    function revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorIsBroken(userHealthFactor);
        }
    }

    // external * public view & pure functions
    function calculateHealthFactor(uint256 totalDSCMinted, uint256 collateralValueInUsd)
        external
        pure
        returns (uint256)
    {
        return _calculateHealthFactor(totalDSCMinted, collateralValueInUsd);
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDSCMinted, uint256 collateralValueInUsd)
    {
        return _getAccountInformation(user);
    }

    function getUsdValue(address token, uint256 amount) external view returns (uint256) {
        return _getUsdValue(token, amount);
    }

    function getCollateralBalanceOfUser(address user, address tokenCollateralAddress) external view returns (uint256) {
        return s_collateralDeposited[user][tokenCollateralAddress];
    }

    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        for (uint256 index = 0; index < s_collateralTokens.length; index++) {
            address token = s_collateralTokens[index];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += _getUsdValue(token, amount);
        }
    }

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getFeedPrecision() external pure returns (uint256) {
        return FEED_PRECISION;
    }

    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function getLiquidationPrecision() external pure returns (uint256) {
        return LIQUIDATION_PRECISION;
    }

    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getDsc() external view returns (address) {
        return address(i_dsc);
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }
}
