//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title Vesting contract interface
/// @notice Vesting schedule that save client information
/// @dev Explain to a developer any extra details
interface IVesting {
    function createVestingSchedule(
        address _beneficiary,
        uint256 _cliff,
        uint256 _duration,
        uint256 _slicePeriodSeconds,
        bool _revocable,
        uint256 _amount
    ) external;

    
    function getVestingSchedulesCountByBeneficiary(address _beneficiary)
        external
        view
        returns (uint256);

    function getVestingScheduleByAddressAndIndex(address holder, uint256 index)
        external
        view
        returns (VestingSchedule memory);

    function addTotalAmount(uint256 _amount, bytes32 _scheduleId) external;

    function computeVestingScheduleIdForAddressAndIndex(address holder, uint256 index) external pure returns(bytes32);

    
    struct VestingSchedule {
        bool initialized;
        // beneficiary of tokens after they are released
        address beneficiary;
        // cliff period in seconds
        uint256 cliff;
        // duration of the vesting period in seconds
        uint256 duration;
        // duration of a slice period for the vesting in seconds
        uint256 slicePeriodSeconds;
        // whether or not the vesting is revocable
        bool revocable;
        // total amount of tokens to be released at the end of the vesting
        uint256 amountTotal;
        // amount of tokens released
        uint256 released;
        // whether or not the vesting has been revoked
        bool revoked;
        // address of the contract that create schedule
        address creator;
    }
}

/// @title Roles interface
/// @dev ROles interface that allows the contract to administrate roles.
interface IRoles {
    function hasRole(bytes32 role, address account)
        external
        view
        returns (bool);

    function getHashRole(string calldata _roleName) external view returns (bytes32);
}

/// @title Oracle Interface
/// @dev Oracle interface that connect the contract to get real prices.
interface IOracle {
    function latestRoundData()
    external
    view
    returns (
      uint80 roundId,
      int256 answer,
      uint256 startedAt,
      uint256 updatedAt,
      uint80 answeredInRound
    );
    function decimals()
    external
    view
    returns (uint256 decimals);
}

/// @title UniswapInterface 
/// @dev Uniswap Interface that connect main contract with Swap functions
 interface UniswapV2Router02 {
     function swapExactETHForTokens(uint amountOutMin, address[] calldata path, address to, uint deadline)
        external
        payable
        returns (uint[] memory amounts);
}

/// @title ERC20 interface
/// @dev ERC20 interface, used to call ERC20 functions. 
 interface ERC20 {
     function transfer(address to, uint value) external returns (bool);
     function balanceOf(address owner) external view returns (uint);
     function decimals() external view returns(uint256);
}

/// @title Etapa1
/// @dev Contract that represents the first stage of IDO.
contract Etapa1 is OwnableUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable, UUPSUpgradeable {
   
    // VARIABLES *************
    
    /// @return wallet the address of collector wallet
    address payable public wallet;

    /// @return weiRaised the total amount of wei raised
    uint256 public weiRaised;

    /// @notice Amount of usdc raised by this contract
    /// @dev Is used to check if the cap is reached
    /// @return usdcRaised
    uint256 public usdcRaised;

    /// @return openingTime the openingTime in timestamp
    uint256 public openingTime;

    /// @return closingTime the closingTime in timestamp
    uint256 public closingTime;

    /// @dev This value is setted in USD
    /// @return cap the max amount of USD that this contract can raise.
    uint256 public cap;

    /// @dev total amount of tokens sold.
    uint256 private tokenSold;
    
    /// @dev return the amount of USDC invested by an address.
    /// @return uint256
    mapping(address => uint256) public alreadyInvested;

    /// @return lockTime the lockTime in timestamp
    uint256 public lockTime;

    /// @return vestingTime the vestingTime in timestamp
    uint256 public vestingTime;

    /// @return minInvestment the minimum amount of USD to invest
    uint256 public minInvestment;

    /// @return maxInvesment the maximum amount of USD to invest
    uint256 public maxInvestment; 
    
    /// @dev Token price in USD, 
    /// @return tokenPriceUSD in weis.
    uint256 public tokenPriceUSD;
    
    /// @dev slippage percentual that 100% is 1000
    uint256 private slippagePorcentual;

    /// @return oracle address
    address public  oracleAddress; 

    /// @return TOKENADDRESS address
    address public  TOKENADDRESS; 

    /// @return MATIC address
    address public  MATIC; 
    
    /// @return ROUTER router address
    address public  ROUTER; 

    /// @dev Instance of the contract Oracle to ask prices
    IOracle private oracle;
    

    /// @notice Instance of the vesting contract
    /// @dev Used to create vesting shedules, this contract should have ICO_ADDRESS role
    /// @return vestingContract 
    IVesting public vestingContract;

    /// @notice Instance of the roles contract
    /// @dev Used to manage access control in the application 
    /// @return rolesContract 
    IRoles public rolesContract; 

    // Instance of the router contract, used to swap matic to USDC
    UniswapV2Router02 private router;

    /**
     * @dev Reverts if not in crowdsale time range.
     */
    modifier onlyWhileOpen {
        require(isOpen(), "TimedCrowdsale: not open");
        _;
    }

    // EVENTOS ***************
        /**
     * Event for token purchase logging
     * @param purchaser who paid for the tokens
     * @param beneficiary who got the tokens
     * @param value weis paid for purchase
     * @param amount amount of tokens purchased
     */
    event TokensPurchased(address indexed purchaser, address indexed beneficiary, uint256 value, uint256 amount);

    /**
     * Event for crowdsale extending
     * @param newClosingTime new closing time
     * @param prevClosingTime old closing time
     */
    event TimedCrowdsaleExtended(uint256 prevClosingTime, uint256 newClosingTime);

    
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() initializer {
       
    }

    function initialize(address payable _wallet,uint256 _openingTime, uint256 _closingTime, uint256 _cap, uint256 initialPrice,address _vestingContract, address _rolesContract) public initializer {
         require(_wallet != address(0), "Crowdsale: wallet is the zero address");
        require(_vestingContract != address(0), "Crowdsale: vesting contract is the zero address");
        require(_openingTime >= block.timestamp, "TimedCrowdsale: opening time is before current time");
        require(_closingTime > _openingTime, "TimedCrowdsale: opening time is not before closing time");
        require(_cap > 0, "CappedCrowdsale: cap is 0");
        //oracle address
        oracleAddress = 0xAB594600376Ec9fD91F8e885dADF0CE036862dE0; //matic/usd
        TOKENADDRESS = 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174; //usdc
        MATIC = 0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270; //WMATIC
        ROUTER = 0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff; //QUICKSWAP ROUTER
        vestingContract = IVesting(_vestingContract);
        rolesContract = IRoles(_rolesContract);
        tokenPriceUSD = initialPrice;
        oracle = IOracle(oracleAddress);
        router = UniswapV2Router02(ROUTER);
        cap = _cap;
        wallet = _wallet;
        openingTime = _openingTime;
        closingTime = _closingTime;
        lockTime = 15778458 seconds; //6 meses
        vestingTime = 31556916 seconds; //12 meses
        minInvestment = 2500000000000000000000;// 2.500 usd
        maxInvestment = 500000000000000000000000; // 500.000 usd
        tokenPriceUSD = 100000000000000000; //0.10 usd
        //slipagge porcentual se divide por 1000, 1 decimal, el 100% es 1000
        slippagePorcentual = 10; //1%
       
    }

    receive() external payable {}
    
    // FUNCIONES *************

    /// @dev Change the instance of the contract requested for price
    /// @param _newOracle address of the new oracle contract used
    function setOracle(address _newOracle) external onlyOwner whenPaused {
        require(_newOracle != address(0), "Address cannot be 0 address");
        oracle = IOracle(_newOracle);
    }

    /// @dev Change the token used to swap the MATIC
    /// @param _newToken address of the new token contract used
    function setToken(address _newToken) external onlyOwner whenPaused {
        require(_newToken != address(0), "Address cannot be 0 address");
        TOKENADDRESS = _newToken;
    }

    /// @dev Change the instance of the router contract
    /// @param _newRouter address of the new router contract used
    function setRouter(address _newRouter) external onlyOwner whenPaused {
        require(_newRouter != address(0), "Address cannot be 0 address");
        router = UniswapV2Router02(_newRouter);
    }

    /// @dev Change the instance of the contract that manage access controls
    /// @param _newRoles address of the new roles contract used
    function setRoles(address _newRoles) external onlyOwner whenPaused {
        require(_newRoles != address(0), "Address cannot be 0 address");
        rolesContract = IRoles(_newRoles);
    }


    /**
     * @dev the rate is variable and depends on the matic/usd price
     * @return the number of token units a buyer gets per wei.
     */
    function rate() public view returns (uint256) {
        //maticPrice in 8 decimals, shift to 18 decimals
        uint256 maticPrice = getLatestPrice() * 10**_oracleFactor(); 
        //represent the result in weis
        return maticPrice * 10**18 / tokenPriceUSD;
    }

    /**
     * @return true if the crowdsale is open, false otherwise.
     */
    function isOpen() public view returns (bool) {
        // solhint-disable-next-line not-rely-on-time
        return block.timestamp >= openingTime && block.timestamp <= closingTime;
    }

    /**
     * @dev Checks whether the period in which the crowdsale is open has already elapsed.
     * @return Whether crowdsale period has elapsed
     */
    function hasClosed() public view returns (bool) {
        // solhint-disable-next-line not-rely-on-time
        return block.timestamp > closingTime;
    }

    /**
     * @dev Checks whether the cap has been reached.
     * @return Whether the cap was reached
     */
    function capReached() public view returns (bool) {
        return this.usdcRaised() >= cap;
    }

    /// @dev Return the amount of tokens sold by this stage
    /// @return tokenSold
    function tokensSold() public view returns (uint256){
        return tokenSold;
    }

    /// @notice Set slippage percent 
    /// @dev a value of 10 = 1%; 1000 = 100%
    /// @param newSlippage should be a number in 1 to 1000 range
    function setSlippage(uint256 newSlippage) external onlyOwner {
        slippagePorcentual = newSlippage;
    }

    /// @notice Return the minimun matic that a client can invest
    /// @dev This function returns a variable value that depends in Matic/usd price
    /// @return uint256 the minInvesment represented in MATIC
    function maticMinInvestment() external view returns(uint256){
        return (minInvestment*10**8)/getLatestPrice();
    }

    /// @notice Return the maximun matic that a client can invest
    /// @dev This function returns a variable value that depends in Matic/usd price
    /// @return uint256 the maxInvesment represented in MATIC
    function maticMaxInvestment() external view returns(uint256){
        return (maxInvestment*10**8)/getLatestPrice();
    }

    /**
     * @dev low level token purchase ***DO NOT OVERRIDE***
     * This function has a non-reentrancy guard, so it shouldn't be called by
     * another `nonReentrant` function.
     * @param beneficiary Recipient of the token purchase
     */
    function buyTokens(address beneficiary) public nonReentrant whenNotPaused payable {
        uint256 weiAmount = msg.value;
        _preValidatePurchase(beneficiary, weiAmount);

        // calculate token amount to be created
        uint256 tokens = _getTokenAmount(weiAmount);

        // update state
        weiRaised += weiAmount;

        _processPurchase(beneficiary, tokens);
        emit TokensPurchased(_msgSender(), beneficiary, weiAmount, tokens);

        _updatePurchasingState(beneficiary, weiAmount);
        _postValidatePurchase(beneficiary, weiAmount);
    }

    /// @notice Function to check the current matic price
    /// @dev External call to the price feed, the return amount is represented in 8 decimals
    /// @return uint256 the price of 1 MATIC in USD
    function getLatestPrice() public view returns (uint256) {
        (
            ,
            /*uint80 roundID*/
            int256 price, /*uint startedAt*/ /*uint timeStamp*/ /*uint80 answeredInRound*/
            ,
            ,

        ) = oracle.latestRoundData();
        return uint256(price);
    }

    /**
     * @dev Validation of an incoming purchase. Use require statements to revert state when conditions are not met.
     * Use `super` in contracts that inherit from Crowdsale to extend their validations.
     * Example from CappedCrowdsale.sol's _preValidatePurchase method:
     *     super._preValidatePurchase(beneficiary, weiAmount);
     *     require(weiRaised().add(weiAmount) <= cap);
     * @param beneficiary Address performing the token purchase
     * @param weiAmount Value in wei involved in the purchase
     */
    function _preValidatePurchase(address beneficiary, uint256 weiAmount) internal onlyWhileOpen view {
        require(rolesContract.hasRole(keccak256("PRIVATE_SALE_WHITELIST"),msg.sender),"Address not whitelisted" );
        require(beneficiary != address(0), "Crowdsale: beneficiary is the zero address");
        require(weiAmount != 0, "Crowdsale: weiAmount is 0");
    }

    /**
     * @dev Executed when a purchase has been validated and is ready to be executed. Doesn't necessarily emit/send
     * tokens.
     * @param beneficiary Address receiving the tokens
     * @param tokenAmount Number of tokens to be purchased
     */
    function _processPurchase(address beneficiary, uint256 tokenAmount) internal {
        _updateScheduleAmount(beneficiary, tokenAmount);
        tokenSold += tokenAmount;
    }

    
    function _updatePurchasingState(address beneficiary, uint256 weiAmount) internal {
        uint256 maticToTokenPrice =  getLatestPrice() * 10**_oracleFactor();
        uint256 tokenOutAmount = maticToTokenPrice * weiAmount / 10**30;

        uint256 _existingContribution = alreadyInvested[beneficiary];
        uint256 _newContribution = _existingContribution + (tokenOutAmount*10**12);
        require(_newContribution >= minInvestment && _newContribution <= maxInvestment,"Investment out of bonds");
        //maticToUsdPrice in 8 decimals, shift to 18 decimals
        //usdcAmount is shifted to 6 decimals
        //Amount with a % substracted
        uint256 amountOutMin = tokenOutAmount -( (tokenOutAmount * slippagePorcentual)/1000);
        //path for the router
        address[] memory path = new address[](2);
        path[1] = TOKENADDRESS;
        path[0] = MATIC;
        //amount put is in 6 decimals
        uint256[] memory amounts = router.swapExactETHForTokens{value:weiAmount}(amountOutMin,path, wallet, block.timestamp);
        usdcRaised += amounts[1];
        alreadyInvested[beneficiary] += amounts[1] * 10**12;
        require(!this.capReached(), "The cap is exceeded");   
    }



    /**
     * @dev Validation of an executed purchase. Observe state and use revert statements to undo rollback when valid
     * conditions are not met.
     * @param beneficiary Address performing the token purchase
     * @param weiAmount Value in wei involved in the purchase
     */
    function _postValidatePurchase(address beneficiary, uint256 weiAmount) internal view {
        // solhint-disable-previous-line no-empty-blocks

    }

    /**
     * @dev Override to extend the way in which ether is converted to tokens.
     * @param weiAmount Value in wei to be converted into tokens
     * @return Number of tokens that can be purchased with the specified _weiAmount
     */
    function _getTokenAmount(uint256 weiAmount) internal view returns (uint256) {
        return weiAmount * rate() / 10**18;
    }

    //Create or update a vesting schedule depending who is the creator of the schedule
    function _updateScheduleAmount(address _beneficiary, uint256 _amount) internal  {
        uint256 beneficiaryCount = vestingContract
            .getVestingSchedulesCountByBeneficiary(_beneficiary);
        if (beneficiaryCount == 0) {
            vestingContract.createVestingSchedule(
                _beneficiary,
                lockTime,
                vestingTime,
                1,
                true,
                _amount
            );
            return;
        } else {
            for(uint i=0; i < beneficiaryCount; ++i){
                IVesting.VestingSchedule memory vesting = vestingContract.getVestingScheduleByAddressAndIndex(_beneficiary,i);
                if(vesting.creator == address(this)){
                    vestingContract.addTotalAmount(_amount,vestingContract.computeVestingScheduleIdForAddressAndIndex(_beneficiary, i));
                    return;
                }
            }
          vestingContract.createVestingSchedule(
                _beneficiary,
                lockTime,
                vestingTime,
                1,
                true,
                _amount
            );
            } 
    }

    function _extendTime(uint256 newClosingTime) internal {
        require(!hasClosed(), "TimedCrowdsale: already closed");
        // solhint-disable-next-line max-line-length
        require(newClosingTime > closingTime, "TimedCrowdsale: new closing time is before current closing time");

        emit TimedCrowdsaleExtended(closingTime, newClosingTime);
        closingTime = newClosingTime;
    }

    /**
     * @dev Extend crowdsale.
     * @param newClosingTime Crowdsale closing time
     */
    function extendTime (uint256 newClosingTime) external onlyOwner whenNotPaused {
        _extendTime(newClosingTime);
    }

    /// @dev Function to withdraw Matic from this contract
    function withdraw() external onlyOwner {
        require(address(this).balance > 0, "Contract has no balance");
        (bool success,) = msg.sender.call{value: address(this).balance}("");
        require(success, "Forward funds fail");
    }

    
    function _oracleFactor() internal view returns(uint256){
        if(oracle.decimals() == 18){
            return 0;
        } else {
            return 18 - oracle.decimals();
        }
    }

    //Funcion para pausar
    function pause() external onlyOwner whenNotPaused {
        _pause();
    }

    //Funcion para despausar
    function unpause() external onlyOwner whenPaused {
        _unpause();
    }

    /**
     *
     * @dev See {utils/UUPSUpgradeable-_authorizeUpgrade}.
     *
     * Requirements:
     *
     * - The caller must have ``role``'s admin role.
     * - The contract must be paused
     *
     */

    function _authorizeUpgrade(address _newImplementation)
        internal
        override
        whenPaused
        onlyOwner
    {}

    /**
     *
     * @dev See {utils/UUPSUpgradeable-upgradeTo}.
     *
     * Requirements:
     *
     * - The caller must have ``role``'s admin role.
     * - The contract must be paused
     *
     */

    function upgradeTo(address _newImplementation)
        external
        override
        onlyOwner
        whenPaused
    {
        _authorizeUpgrade(_newImplementation);
        _upgradeToAndCallUUPS(_newImplementation, new bytes(0), false);
    }

    /**
     *
     * @dev See {utils/UUPSUpgradeable-upgradeToAndCall}.
     *
     * Requirements:
     *
     * - The caller must have ``role``'s admin role.
     * - The contract must be paused
     *
     */

    function upgradeToAndCall(address _newImplementation, bytes memory _data)
        external
        payable
        override
        onlyOwner
        whenPaused
    {
        _authorizeUpgrade(_newImplementation);
        _upgradeToAndCallUUPS(_newImplementation, _data, true);
    }

    
}
