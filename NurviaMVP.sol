// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IAxelarCrossChain.sol";
import "./interfaces/IUniswapV2Router.sol";
import "./interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";


contract NurviaLendingPool is ERC20 {
    
    using SafeMath for uint256;
    
    IERC20 public RiskTokenizedLoan;

    address public borrower;
    address public backer;
    address public liquidityProvider;
    uint public totalSeniorPoolLiquidity;

    // AXELAR integration
    address public axelarIntegrationAddress;
    address public axelarGateway;
    
    // Chainlink integration
    AggregatorV3Interface internal priceFeed;

    // Uniswap integration
    address public uniswapRouterAddress;

    uint256 public totalSeniorPoolTokens;
    uint public SeniorPoolBalance;
    address public poolTokenAddress;
    address payable[] public activePoolAddresses;
    address public owner;
    address public nftContractAddress;
    uint public maxLeverageRatio;
    uint constant minLeverageRatio = 50;

    //Leverage model slope and intercept 
    uint constant leverageModelSlope = 50;
    uint constant leverageModelIntercept = 150;

    struct LendingPool {
        uint amount;
        uint interestRate;
        uint dueDate;
        uint repaymentSchedule;
        address juniorPool;
        bool isActive;
    }

    struct Investor {
        uint256 suppliedAmount;
        uint256 redeemedAmount;
        bool hasNFT;
    }


    uint256 public poolId;
    uint256 public tokenId;
    mapping(address => LendingPool) public lendingPools;
    LendingPool[] public borrowerPools;
    mapping(address => uint) public seniorPool;
    mapping(address => uint) public juniorPool;
    mapping(address => uint) public juniorPoolTotalSupply;
    mapping(address => uint) public seniorPoolTotalSupply;
    mapping(address => uint) public juniorPoolBalance;
    mapping(address => uint) public seniorPoolsBalance;
    mapping(address => mapping(address => uint)) public juniorPoolBalances;
    mapping(address => mapping(address => uint)) public seniorPoolBalances;
    mapping(address => bool) public juniorPoolFunded;
    mapping(address => Investor) public investors;
    mapping(address => bool) private nftOwners;
    

    event JuniorPoolFunded(address indexed funder, uint256 amount, address indexed poolAddress);
    event JuniorPoolInvestment(address poolAddress, address investor, uint amount);
    event RiskTokenizedLoanSwapped(address fromChain, address toChain, address indexed account, uint256 amount);
    event SeniorPoolLiquidityProvided(address indexed provider, uint amount);
    event SeniorPoolTokensReceived(address investor, uint256 tokensReceived);
    event SeniorPoolTokenSwapped(address indexed user, bytes32 indexed fromChain, bytes32 indexed toChain, uint256 amount, uint256 bnbAmount);
    event CapitalAllocated(address indexed poolAddress, uint256 capitalToAllocate);
    event NFTMintedToLiquidityProvider(address recipient, uint256 amount);
    event NFTMintedToBacker(address indexed backer, uint256 amount, address indexed poolAddress);
    event NFTRedeemedForBacker(address indexed backer, uint256 amount, address indexed poolAddress);
    event NFTRedeemedForLiquidityProvider(address indexed backer, uint256 amount);

    modifier onlyOwner {
        require(msg.sender == owner, "Only owner can call this function.");
        _;
    }

    modifier onlyBorrower {
        require(msg.sender == borrower, "Only Borrower can call this function.");
        _;
    }

    modifier onlyBacker {
        require(msg.sender == backer, "Only Backer can call this function.");
        _;
    }

    modifier onlyLiquidityProvider {
        require(msg.sender == liquidityProvider, "Only LiquidityProvider can call this function.");
        _;
    }


    constructor(address tokenAddress, address _nftContractAddress, address _axelarGateway, address _priceFeedAddress, address _uniswapRouterAddress, uint _maxLeverageRatio) ERC20("RiskTokenizedLoan", "RTL") {
        RiskTokenizedLoan = IERC20(tokenAddress);
        nftContractAddress = _nftContractAddress;
        axelarGateway = _axelarGateway;
        priceFeed = AggregatorV3Interface(_priceFeedAddress);
        uniswapRouterAddress = _uniswapRouterAddress;
        maxLeverageRatio = _maxLeverageRatio;
        tokenId = 0;
    }

    /*For Borrower*/

    // Set the borrower address
    function setBorrowerAddress(address _borrower) external {
        require(borrower == address(0), "Borrower address already set");
        borrower = _borrower;
    }
    
   /**
    @dev This function creates a new lending pool with the specified parameters.
    @param poolAddress The address of the lending pool.
    @param amount The loan amount requested by the borrower.
    @param interestRate The interest rate for the loan.
    @param dueDate The due date of the loan.
    @param repaymentSchedule The repayment schedule for the loan.
    */ 

    function createLendingPool(address poolAddress, uint amount, uint interestRate, uint dueDate, uint repaymentSchedule) public onlyBorrower {
        require(msg.sender == borrower, "Only borrower can create lending pool");
        require(poolAddress != address(0), "Invalid pool address");
        require(amount > 0, "Loan amount must be greater than 0");
        require(interestRate > 0, "Interest rate must be greater than 0");
        require(dueDate > 0, "dueDate must be greater than 0");
        require(repaymentSchedule > 0, "repaymentSchedule must be greater than 0");

        LendingPool memory pool = LendingPool(amount, interestRate, dueDate, repaymentSchedule, poolAddress, true);
        lendingPools[poolAddress] = pool;
        poolId++;
        borrowerPools.push(pool);

        juniorPoolTotalSupply[poolAddress] = 0;
        juniorPoolBalance[poolAddress] = 0;
    }

    /**
    @dev This function allows the borrower to withdraw funds from the junior pool.
    @param amount The amount of funds to be withdrawn.
    @param to The address to which the funds should be transferred.
    */

   function withdrawJuniorFunds(uint amount, address to) external {
        require(juniorPoolBalance[msg.sender] >= amount, "Insufficient balance in junior pool");

        juniorPoolBalance[msg.sender] =  juniorPoolBalance[msg.sender].sub(amount);
        juniorPoolTotalSupply[msg.sender] = juniorPoolTotalSupply[msg.sender].sub(amount);

        payable(to).transfer(amount);
    }

    /**
    @dev This function returns the details of an active lending pool.
    @param _poolId The ID of the lending pool.
    @return The details of the lending pool.
    */

   function getActiveLendingPool(uint256 _poolId) public view returns (LendingPool memory) {
        require(_poolId < borrowerPools.length, "Invalid poolId");
        require(borrowerPools[_poolId].isActive, "LendingPool not active");

        LendingPool storage activePool = borrowerPools[_poolId];
        address poolAddress = activePool.juniorPool;

        uint256 updatedTotalSupply = juniorPoolTotalSupply[poolAddress];
        uint256 updatedBalance = juniorPoolBalance[poolAddress];

        if (juniorPoolBalances[activePool.juniorPool][backer] != 0) {
            updatedBalance += juniorPoolBalances[activePool.juniorPool][backer];
            updatedTotalSupply += juniorPoolBalances[activePool.juniorPool][backer];
        }

        return LendingPool(activePool.amount, activePool.interestRate, activePool.dueDate, activePool.repaymentSchedule, poolAddress, activePool.isActive);
    }

    /**
    @dev This function returns the ID of a lending pool based on its address.
    @param poolAddress The address of the lending pool.
    @return The ID of the lending pool.
    */

    function getLendingPoolId(address poolAddress) public view returns (uint256) {
        for (uint256 i = 0; i < borrowerPools.length; i++) {
            if (borrowerPools[i].juniorPool == poolAddress) {
                return i;
            }
        }
        revert("Lending pool not found");
    }

    /**
    @dev This function returns the address of a lending pool based on its ID.
    @param _poolId The ID of the lending pool.
    @return The address of the lending pool.
    */

    function getLendingPoolAddress(uint256 _poolId) public view returns (address) {
        require(_poolId < borrowerPools.length, "Invalid poolId");
        require(borrowerPools[_poolId].isActive, "LendingPool not active");
        return borrowerPools[poolId].juniorPool;
    }

    /**
    @dev This function returns an array of all active lending pools.
    @return An array of all active lending pools.
    */

    function getAllActiveLendingPools() public view returns (LendingPool[] memory) {
        uint256 count = 0;
        for (uint256 i = 0; i < borrowerPools.length; i++) {
            if (borrowerPools[i].isActive) {
                count++;
            }
        }
        LendingPool[] memory activePools = new LendingPool[](count);
        uint256 j = 0;
        for (uint256 i = 0; i < borrowerPools.length; i++) {
            if (borrowerPools[i].isActive) {
                activePools[j] = borrowerPools[i];
                j++;
            }
        }
        return activePools;
    }


    /*For Backer*/
    
    // Set the backer address
    function setBackerAddress(address _backer) external {
        require(backer == address(0), "Backer address already set");
        backer = _backer;
    }

    receive() external payable{}

   /**
    @dev This function allows a backer to lend funds to a junior pool.
    @param poolAddress The address of the junior pool.
    @param amount The amount of funds to be lent.
    */

    function lendToJuniorPool(address poolAddress, uint256 amount) external payable onlyBacker {
        require(msg.sender == backer, "Only backer can lend to junior pool");
        require(!juniorPoolFunded[poolAddress], "Backer can only lend once to junior pool");

        juniorPoolTotalSupply[poolAddress] = juniorPoolTotalSupply[poolAddress].add(amount);
        juniorPoolBalance[poolAddress] =  juniorPoolBalance[poolAddress].add(amount);

        // Mint an NFT to the backer confirming the funding of the junior pool
        Investor storage investor = investors[msg.sender];
        investor.suppliedAmount = investor.suppliedAmount.add(amount);
        investor.hasNFT = true;

        emit NFTMintedToBacker(msg.sender, amount, poolAddress);
        emit JuniorPoolFunded(msg.sender, amount, poolAddress);
    }

    /**
    @dev This function allows a backer to redeem their investment from a junior pool.
    @param amount The amount of funds to be redeemed.
    @param poolAddress The address of the pool.
    */

    function redeemBacker(uint256 amount, address poolAddress) external onlyBacker {
        Investor storage investor = investors[msg.sender];
        require(investor.hasNFT, "Investor does not have NFT");
        require(investor.suppliedAmount >= investor.redeemedAmount + amount, "Insufficient supplied amount");

        investor.redeemedAmount = investor.redeemedAmount.add(amount);
        juniorPoolBalance[poolAddress] = juniorPoolBalance[poolAddress].sub(amount);

        emit NFTRedeemedForBacker(msg.sender, amount, poolAddress);
    }

    /**
    @dev This function allows a backer to swap their risk tokenized loan from one chain to another using the AXELAR cross-chain integration.
    @param fromChain The address of the source chain where the funds are currently located.
    @param toChain The address of the target chain where the funds will be transferred.
    @param amount The amount of funds to be swapped.
    */

    function swapRiskTokenizedLoan(address fromChain, address toChain, uint amount) external {
        require(balanceOf(msg.sender) >= amount, "Insufficient balance");
        
        // Axelar cross-chain transfer function to transfer the specified amount of funds to the designated chain and destination address
        IAxelarCrossChain(axelarGateway).transferToChainAndDestination(fromChain, toChain, amount);
        
        emit RiskTokenizedLoanSwapped(fromChain, toChain, msg.sender, amount);
    }
 
    /**
    * @dev This function allows a backer to get a token representing their investment in the junior pool of a specific lending pool
    * with a specified amount.
    * @param poolAddress The address of the lending pool that the backer wants to invest in.
    * @param amount The amount of funds that the backer wants to invest in the junior pool.
    */

    function getRiskTokenizedLoan(address poolAddress, uint amount) public returns (uint) {
        require(lendingPools[poolAddress].isActive, "Lending pool is not active");
        require(amount > 0, "Invalid amount");
        require(balanceOf(msg.sender) >= amount, "Insufficient balance");

        // Retrieve the latest price data from Chainlink's price feed
        (, int price, , ,) = priceFeed.latestRoundData();
        uint currentPrice = uint(price);
        // Get the current interest rate from the lending pool
        uint interestRate = getCurrentInterestRate();

        // Calculate the share amount using the interest rate and current price
        uint share = (amount * 10**18 * currentPrice) / (juniorPoolTotalSupply[poolAddress] * interestRate);

        IAxelarCrossChain(axelarGateway).transferToChainAndDestination(address(this), poolAddress, amount);

        _mint(msg.sender, share);
        juniorPoolBalance[poolAddress] = juniorPoolBalance[poolAddress].add(amount);

        emit JuniorPoolInvestment(poolAddress, msg.sender, amount);
        return share;
    }

    /**
    @dev Internal function to retrieve the current interest rate from Chainlink's price feed.
    @return The current interest rate.
    */

    function getCurrentInterestRate() internal view returns (uint) {
        (, int price, , ,) = priceFeed.latestRoundData();
        require(price > 0, "Invalid price from Chainlink");
        return uint(price);
    }

    /**
    @dev Function to retrieve the balance of the junior pool in the underlying asset.
    @return The balance of the junior pool in the underlying asset.
    */

    function getJuniorPoolBalance() public view returns (uint) {
        ERC20 juniorPoolToken = ERC20(poolTokenAddress);
        uint juniorsPoolBalance = juniorPoolToken.balanceOf(address(this));
        
        // Retrieve the current price from the Chainlink Price Feed
        (, int price, , ,) = priceFeed.latestRoundData();
        uint currentPrice = uint(price);
        uint juniorsPoolBalanceInAsset = juniorsPoolBalance * currentPrice;
        return juniorsPoolBalanceInAsset;
    }


    /*For LiquidityProvider*/

    /**
    @dev Function to set the liquidity provider address.
    @param _liquidityProvider The address of the liquidity provider.
    */

    function setLiquidityProvider(address _liquidityProvider) external {
        require(liquidityProvider == address(0), "Liquidity Provider address already set");
        liquidityProvider = _liquidityProvider;
    }

    /**
    * @dev Allows a liquidity provider to provide liquidity to the senior pool by specifying the amount of funds
    * they want to invest.
    * @param amount The amount of funds that the liquidity provider wants to invest in the senior pool.
    */
   
    function provideLiquidityToSeniorPool(uint amount) public {
        require(amount > 0, "Invalid amount");
        require(balanceOf(msg.sender) >= amount, "Insufficient balance");
        require(transferFrom(msg.sender, address(this), amount), "Transfer failed");

        // Add liquidity to the senior pool from the liquidity provider
        seniorPool[msg.sender] = seniorPool[msg.sender].add(amount);
        totalSeniorPoolLiquidity = totalSeniorPoolLiquidity.add(amount);

        Investor storage investor = investors[msg.sender];
        investor.suppliedAmount = investor.suppliedAmount.add(amount);
        investor.hasNFT = true;

        emit NFTMintedToLiquidityProvider(msg.sender, amount);

        // Provide liquidity to the senior pool from Uniswap
        IUniswapV2Router uniswapRouter = IUniswapV2Router(uniswapRouterAddress);
        address[] memory path = new address[](2);
        path[0] = address(this); 
        path[1] = uniswapRouter.WETH(); 

        approve(uniswapRouterAddress, amount);

        uniswapRouter.swapExactTokensForETH(
            amount,
            0, 
            path,
            address(this),
            block.timestamp
        );

        emit SeniorPoolLiquidityProvided(msg.sender, amount);
    }
   
    // function to get Senior Pool Token
    function getSeniorPoolToken(address poolAddress, uint amount) public returns (uint) {
        require(amount > 0, "Invalid amount");
        require(seniorPool[msg.sender] >= amount, "Insufficient share in senior pool");

        uint tokenAmount = amount.mul(totalSeniorPoolTokens).div(totalSeniorPoolLiquidity);

        // Retrieve the latest price from the Chainlink price feed
        (, int price, , ,) = priceFeed.latestRoundData();
        uint currentPrice = uint(price);

        tokenAmount = tokenAmount.mul(currentPrice).div(1e18);
        uint interestRate = getCurrentInterestRate();
        uint seniorPoolsTotalSupply = seniorPoolTotalSupply[poolAddress];
        uint sharedTokenAmount = (amount * 10**18 * currentPrice) / (seniorPoolsTotalSupply * interestRate);

        seniorPool[msg.sender] = seniorPool[msg.sender].sub(amount);
        totalSeniorPoolLiquidity = totalSeniorPoolLiquidity.sub(amount);
        totalSeniorPoolTokens = totalSeniorPoolTokens.add(tokenAmount);

        require(transfer(msg.sender, tokenAmount), "Transfer failed");

        IAxelarCrossChain(axelarGateway).transferToChainAndDestination(address(this), poolAddress, tokenAmount);
        emit SeniorPoolTokensReceived(msg.sender, tokenAmount);
        return sharedTokenAmount;
    }

    /**
    @dev This function allows a liquidity Provider to swap senior pool tokens for BNB on a different blockchain using the AXELAR integration.
    @param fromChain The address of the source chain.
    @param toChain The address of the destination chain.
    @param amount The amount of senior pool tokens to be swapped.
    */

    function swapSeniorPoolToken(address fromChain, address toChain, uint amount) public {
        require(amount > 0, "Invalid amount");
        require(balanceOf(msg.sender) >= amount, "Insufficient senior pool tokens");

        uint bnbAmount = amount.mul(totalSeniorPoolLiquidity).div(totalSeniorPoolTokens);
        _burn(msg.sender, amount);
        totalSeniorPoolTokens = totalSeniorPoolTokens.sub(amount);
        seniorPool[msg.sender] = seniorPool[msg.sender].sub(bnbAmount);
        totalSeniorPoolLiquidity = totalSeniorPoolLiquidity.sub(bnbAmount);

        IAxelarCrossChain(axelarGateway).transferToChainAndDestination(fromChain, toChain, bnbAmount);

        emit SeniorPoolTokenSwapped(msg.sender, bytes32(uint(uint160(fromChain))), bytes32(uint(uint160(toChain))), amount, bnbAmount);
    }

    /**
    @dev This function allows the liquidity provider to redeem their supplied amount by burning their NFT.
    @param amount The amount to be redeemed.
    */

    function redeemLiquidityProvider(uint256 amount) external onlyLiquidityProvider {
        Investor storage investor = investors[msg.sender];
        require(investor.hasNFT, "Investor does not have NFT");
        require(investor.suppliedAmount >= investor.redeemedAmount + amount, "Insufficient supplied amount");

        investor.redeemedAmount = investor.redeemedAmount.add(amount);
        seniorPoolsBalance[msg.sender] =  seniorPoolsBalance[msg.sender].sub(amount);

        emit NFTRedeemedForLiquidityProvider(msg.sender, amount);
    }

    /**
    @dev This function returns the balance of the senior pool in terms of the asset value.
    @return The senior pool balance in terms of asset value.
    */

    function getSeniorPoolBalance() public view returns (uint) {
        uint seniorPoolBalance = SeniorPoolBalance;
        
        // Retrieve the current price from the Chainlink Price Feed
        (, int price, , ,) = priceFeed.latestRoundData();
        uint currentPrice = uint(price);
        
        uint seniorPoolBalanceInAsset = seniorPoolBalance * currentPrice;

        return seniorPoolBalanceInAsset;
    }

    /**
    @dev This function allows the owner to set the address of the pool token.
    @param _address The address of the pool token.
    */

    function setPoolTokenAddress(address _address) external onlyOwner {
        require(_address != address(0), "Invalid address");
        poolTokenAddress = _address;
    }

    /**
    @dev This function allows the system to automatically allocate capital across the senior pool of borrower pools according to the leverage model.
    It ensures that repayments made by borrowers first go toward paying off the senior pool, then the junior pool.
    */

    function allocateCapitalToSeniorPool(address targetChain) public {
        LendingPool[] memory activePools = getAllActiveLendingPools();

        for (uint256 i = 0; i < activePools.length; i++) {
            address payable poolAddress = payable(activePools[i].juniorPool);
            uint256 seniorPoolBalance = NurviaLendingPool(poolAddress).getSeniorPoolBalance();
            uint256 JuniorPoolBalance = NurviaLendingPool(poolAddress).getJuniorPoolBalance();
            uint256 totalCapital = seniorPoolBalance.add(JuniorPoolBalance);
            uint256 currentLeverageRatio = seniorPoolBalance.mul(100).div(totalCapital);
            uint256 targetLeverageRatio = getTargetLeverageRatio(currentLeverageRatio);
            uint256 targetSeniorPoolBalance = totalCapital.mul(targetLeverageRatio).div(100);
            uint256 capitalToAllocate = targetSeniorPoolBalance.sub(seniorPoolBalance);

            IAxelarCrossChain(axelarGateway).transferToChainAndDestination(address(this), targetChain, capitalToAllocate);

            emit CapitalAllocated(poolAddress, capitalToAllocate);
        }
    }

    /**
    @dev This function returns the target leverage ratio of a lending pool based on its current leverage ratio.
    The target leverage ratio is calculated based on the leverage model, which is a linear function of the current leverage ratio.
    The function takes into consideration the maximum and minimum leverage ratios allowed by the model.
    */
    
    function getTargetLeverageRatio(uint currentLeverageRatio) internal view returns (uint) {
        uint targetLeverageRatio = currentLeverageRatio.mul(leverageModelSlope).div(1000).add(leverageModelIntercept);

        if (targetLeverageRatio > maxLeverageRatio) {
            return maxLeverageRatio;
        } else if (targetLeverageRatio < minLeverageRatio) {  
            return minLeverageRatio;
        } else {
            return targetLeverageRatio;
        }
    }
}