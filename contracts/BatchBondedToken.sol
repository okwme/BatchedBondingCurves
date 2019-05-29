pragma solidity ^0.4.23;

import "../node_modules/zeppelin-solidity/contracts/token/ERC20/StandardToken.sol";
import "../node_modules/zeppelin-solidity/contracts/math/SafeMath.sol";
import "./BancorContracts/converter/BancorFormula.sol";

contract BatchBondedToken is StandardToken, BancorFormula {
    using SafeMath for uint256;

    enum Category {Matching, BetterForBuyers, BetterForSellers}

    string public name;
    string public symbol;
    uint8 public decimals;

    uint32 public reserveRatio;  // aka connector weight, represented in parts per million (1-1000000)
    uint32 public ppm = 1000000;
    uint256 public virtualSupply;
    uint256 public virtualBalance;

    uint256 public poolBalance;

    Category public category;
    uint256 public waitingClear;
    uint256 public batchBlocks;
    struct Batch {
        bool init;
        bool buysCleared;
        bool sellsCleared;
        bool cleared;

        uint256 poolBalance;
        uint256 totalSupply;
        
        uint256 totalBuySpend;
        uint256 totalBuyReturn;

        uint256 totalSellSpend;
        uint256 totalSellReturn;

        mapping (address => uint256) buyers;
        mapping (address => uint256) sellers;
    }
    mapping (uint256 => Batch) public batches;
    mapping (address => uint256[]) public addressToBlocks;

    event Mint(address indexed to, uint256 amount);
    event Burn(address indexed burner, uint256 amount);
    event Buy(address indexed to, uint256 poolBalance, uint tokenSupply, uint256 amountTokens, uint256 totalCostEth);
    event Sell(address indexed from, uint256 poolBalance, uint tokenSupply, uint256 amountTokens, uint256 returnedEth);

    constructor (
        string _name,
        string _symbol,
        uint8 _decimals,
        Category _category, 
        uint256 _batchBlocks,
        uint32 _reserveRatio,
        uint256 _virtualSupply,
        uint256 _virtualBalance) public {
            
        name = _name;
        symbol = _symbol;
        decimals = _decimals;

        category = _category;
        batchBlocks = _batchBlocks;

        reserveRatio = _reserveRatio;
        virtualSupply = _virtualSupply;
        virtualBalance = _virtualBalance;
    }

    function() public payable {}
    function currentBatch() public view returns(uint cb) {
        cb = (block.number / batchBlocks) * batchBlocks;
    }
    function getUserBlocks(address user) public view returns (uint256[]) {
        return addressToBlocks[user];
    }
    function getUserBlocksLength(address user) public view returns (uint256) {
        return addressToBlocks[user].length;
    }  
    function getUserBlocksByIndex(address user, uint256 index) public view returns (uint256) {
        return addressToBlocks[user][index];
    }
    function isUserBuyerByBlock(address user, uint256 index) public view returns (bool) {
        return batches[index].buyers[user] > 0;
    }
    function isUserSellerByBlock(address user, uint256 index) public view returns (bool) {
        return batches[index].sellers[user] > 0;
    }
    function getPolynomial() public view returns(uint256) {
        return uint256(ppm / reserveRatio).sub(1);
    }
    // returns in parts per million
    function getSlopePPM(uint256 _totalSupply) public view returns(uint256) {
        return _totalSupply.mul(ppm).mul(ppm) / (uint256(reserveRatio).mul(_totalSupply) ** (ppm / reserveRatio));
    } 
    // returns in parts per million
    function getPricePPM(uint256 _totalSupply, uint256 _poolBalance) public view returns(uint256) {
        return uint256(ppm).mul(_poolBalance) / _totalSupply.mul(reserveRatio);
        // return getSlope(_totalSupply, _poolBalance).mul(_totalSupply ** getPolynomial()) / ppm;
    }
    function getBuy(uint256 _totalSupply, uint256 _poolBalance, uint256 buyValue) public view returns(uint256) {
        return calculatePurchaseReturn(
            safeAdd(_totalSupply, virtualSupply),
            safeAdd(_poolBalance, virtualBalance),
            reserveRatio,
            buyValue);
    }
    function getSell(uint256 _totalSupply, uint256 _poolBalance, uint256 sellAmount) public view returns(uint256) {
        return calculateSaleReturn(
            safeAdd(_totalSupply, virtualSupply),
            safeAdd(_poolBalance, virtualBalance),
            reserveRatio,
            sellAmount);
    }
    // totalSupply remains the same
    // balance remains the same (although collateral has been collected)
    function addBuy(address sender) public payable returns(bool) {
        uint256 batch = currentBatch();
        Batch storage cb = batches[batch]; // currentBatch
        if (!cb.init) {
            initBatch(batch);
        }
        cb.totalBuySpend = cb.totalBuySpend.add(msg.value);
        if (cb.buyers[sender] == 0) {
            addressToBlocks[sender].push(batch);
        }
        cb.buyers[sender] = cb.buyers[sender].add(msg.value);
        return true;
    }
    // totalSupply is decremented
    // balance remains the same
    function addSell(uint256 amount) public returns(bool) {
        require(balanceOf(msg.sender) >= amount, "insufficient funds for sell order");
        uint256 batch = currentBatch();
        Batch storage cb = batches[batch]; // currentBatch
        if (!cb.init) {
            initBatch(batch);
        }
        cb.totalSellSpend = cb.totalSellSpend.add(amount);
        if (cb.sellers[msg.sender] == 0) {
            addressToBlocks[msg.sender].push(batch);
        }
        cb.sellers[msg.sender] = cb.sellers[msg.sender].add(amount);
        require(_burn(msg.sender, amount), "burn must succeed");
        return true;
    }
    function initBatch(uint256 batch) internal {
        clearBatch();
        batches[batch].poolBalance = poolBalance;
        batches[batch].totalSupply = totalSupply_;
        batches[batch].init = true;
        waitingClear = batch;
    }
    function clearBatch() public {
        if (waitingClear == 0) return;
        require(waitingClear > currentBatch(), "Can't clear an active batch");
        Batch storage cb = batches[waitingClear]; // clearing batch
        if (cb.cleared) return;
        if (category == Category.Matching) {
            clearMatching();
        } else if (category == Category.BetterForBuyers) {
            clearSales();
            clearBuys();
        } else if (category == Category.BetterForSellers) {
            clearBuys();
            clearSales();
        } else {
            revert("Impossibru");
        }
   
        poolBalance = cb.poolBalance;

        // The totalSupply was decremented when _burns took place as the sell orders came in. Now
        // the totalSupply needs to be incremented by totalBuyReturn, the resulting tokens are 
        // held by this contract until collected by the buyers.
        require(_mint(this, cb.totalBuyReturn), "minting new tokens to be held until buyers collect must succeed");
        cb.cleared = true;
        waitingClear = 0;
    }
    function clearMatching() internal {
        Batch storage cb = batches[waitingClear]; // clearing batch

        // the static price is the current exact price in collateral
        // per token according to the initial state of the batch
        uint256 staticPrice = getPricePPM(cb.totalSupply, cb.poolBalance);

        // We want to find out if there are more buy orders or more sell orders.
        // To do this we check the result of all sells and all buys at the current
        // exact price. If the result of sells is larger than the pending buys, there are more sells.
        // If the result of buys is larger than the pending sells, there are more buys.
        // Of course we don't really need to check both, if one is true then the other is false.
        uint256 resultOfSell = cb.totalSellSpend.mul(staticPrice) / ppm;

        // We check if the result of the sells was more than the bending buys to determine
        // if there were more sells than buys. If that is the case we will execute all pending buy
        // orders at the current exact price, because there is at least one sell order for each buy.
        // The remaining sell orders will be executed using the traditional bonding curve.
        // The final sell price will be a combination of the exact price and the bonding curve price.
        // Further down we will do the opposite if there are more buys than sells.

        // if more sells than buys
        if (resultOfSell >= cb.totalBuySpend) {

            // totalBuyReturn is the number of tokens bought as a result of all buy orders combined at the
            // current exact price. We have already determined that this number is less than the
            // total amount of tokens to be sold.
            // tokens = totalBuySpend / staticPrice. staticPrice is in PPM, to avoid
            // rounding errors it has been re-arranged with PPM as a numerator
            cb.totalBuyReturn = cb.totalBuySpend.mul(ppm) / staticPrice;
            cb.buysCleared = true;

            // we know there should be some tokens left over to be sold with the curve.
            // these should be the difference between the original total sell order
            // and the result of executing all of the buys.
            uint256 remainingSell = cb.totalSellSpend.sub(cb.totalBuyReturn);

            // now that we know how many tokens are left to be sold we can get the amount of collateral
            // generated by selling them through a normal bonding curve execution, based on the
            // original totalSupply and poolBalance (as if the buy orders never existed and the sell
            // order was just smaller than originally thought).
            uint256 remainingSellReturn = getSell(cb.totalSupply, cb.poolBalance, remainingSell);

            // the total result of all sells is the original amount of buys which were matched, plus the remaining
            // sells which were executed with the bonding curve
            cb.totalSellReturn = cb.totalBuySpend.add(remainingSellReturn);

            // TotalSupply doesn't need to be changed (keep it commented out). It only needs to be changed 
            // by clearSales or clearBuys scenario so that the subsequent clearSales/clearBuys
            // can correctly calculate the purchaseReturn/saleReturn.
            // cb.totalSupply = cb.totalSupply.sub(remainingSell);
            
            // poolBalance is ultimately only affected by the net difference between the buys and sells
            cb.poolBalance = cb.poolBalance.sub(remainingSellReturn);
            cb.sellsCleared = true;

        // more buys than sells
        } else {

            // Now in this scenario there were more buys than sells. That means that resultOfSell that we
            // calculated earlier is the total result of sell.
            cb.totalSellReturn = resultOfSell;
            cb.sellsCleared = true;

            // there is some collateral left over to be spent as buy orders. this should be the difference between
            // the original total buy order, and the result of executing all of the sells.
            uint256 remainingBuy = cb.totalBuySpend.sub(resultOfSell);

            // now that we know how much collateral is left to be spent we can get the amount of tokens
            // generated by spending it through a normal bonding curve execution, based on the
            // original totalSupply and poolBalance (as if the sell orders never existed and the buy
            // order was just smaller than originally thought).
            uint256 remainingBuyReturn = getBuy(cb.totalSupply, cb.poolBalance, remainingBuy);

            // remainingBuyReturn becomes the combintation of all the sell orders
            // plus the resulting tokens from the remaining buy orders
            cb.totalBuyReturn = cb.totalSellSpend.add(remainingBuyReturn);

            // TotalSupply doesn't need to be changed (keep it commented out). It only needs to be changed 
            // by clearSales or clearBuys scenario so that the subsequent clearSales/clearBuys
            // can correctly calculate the purchaseReturn/saleReturn.
            // cb.totalSupply = cb.totalSupply.add(remainingBuyReturn);
            
            // poolBalance is ultimately only affected by the net difference between the buys and sells
            cb.poolBalance = cb.poolBalance.add(remainingBuyReturn);
            cb.buysCleared = true;
        }
    }
    function clearSales() internal {
        Batch storage cb = batches[waitingClear]; // clearing batch
        if (!cb.sellsCleared) {
            cb.totalSellReturn = getSell(cb.totalSupply, cb.poolBalance, cb.totalSellSpend);
            cb.totalSupply = cb.totalSupply.sub(cb.totalSellSpend);
            cb.poolBalance = cb.poolBalance.sub(cb.totalSellReturn);
            cb.sellsCleared = true;
        }
    }
    function clearBuys() internal {
        Batch storage cb = batches[waitingClear]; // clearing batch
        if (!cb.buysCleared) {
            cb.totalBuyReturn = getBuy(cb.totalSupply, cb.poolBalance, cb.totalBuySpend);
            cb.totalSupply = cb.totalSupply.add(cb.totalBuyReturn);
            cb.poolBalance = cb.poolBalance.add(cb.totalBuySpend);
            cb.buysCleared = true;
        }
    }
    function claimSell(uint256 batch, address sender) public {
        Batch storage cb = batches[batch]; // claiming batch
        require(cb.cleared, "can't claim a batch that hasn't cleared");
        require(cb.sellers[sender] != 0, "this address has no sell to claim");
        uint256 individualSellReturn = (cb.totalSellReturn.mul(cb.sellers[sender])).div(cb.totalSellSpend);
        cb.sellers[sender] = 0;
        sender.transfer(individualSellReturn);
    }
    function claimBuy(uint256 batch, address sender) public {
        Batch storage cb = batches[batch]; // claiming batch
        require(cb.cleared, "can't claim a batch that hasn't cleared");
        require(cb.buyers[sender] != 0, "this address has no buy to claim");
        uint256 individualBuyReturn = (cb.buyers[sender].mul(cb.totalBuyReturn)).div(cb.totalBuySpend);
        cb.buyers[sender] = 0;
        require(_burn(this, individualBuyReturn), "burn must succeed to close claim");
        require(_mint(sender, individualBuyReturn), "mint must succeed to close claim");
    }

    // /**
    // * @dev buy Buy tokens for Eth
    // * @param sender The recepient of bought tokens
    // */
    // function buy(address sender) public payable returns(bool) {
    //     require(msg.value > 0, "Msg.value must be greater than 0");
    //     uint256 tokens = getBuy(totalSupply_, poolBalance, msg.value);
    //     require(tokens > 0, "Buy must be greater than 0");
    //     require(_mint(sender, tokens), "mint must succeed");

    //     poolBalance = poolBalance.add(msg.value);
    //     emit Buy(sender, poolBalance, totalSupply_, tokens, msg.value);
    //     return true;
    // }

    // /**
    // * @dev sell Sell tokens for Eth
    // * @param sellAmount The amount of tokens to sell
    // */
    // function sell(uint256 sellAmount) public returns(bool) {
    //     require(sellAmount > 0, "sell amount must be greater than 0");
    //     require(balanceOf(msg.sender) >= sellAmount, "sell amount must be less than or equal to sellser's balance");

    //     uint256 saleReturn = getSell(totalSupply_, poolBalance, sellAmount);

    //     require(saleReturn > 0, "Sale must be greater than 0");
    //     require(saleReturn <= poolBalance, "Sale must be less than pool balance");
    //     require(_burn(msg.sender, sellAmount), "burn must suceed");
    //     poolBalance = poolBalance.sub(saleReturn);

    //     msg.sender.transfer(saleReturn);

    //     emit Sell(msg.sender, poolBalance, totalSupply_, sellAmount, saleReturn);
    //     return true;
    // }


    /// @dev                Mint new tokens with ether
    /// @param numTokens    The number of tokens you want to mint
    function _mint(address minter, uint256 numTokens) internal returns(bool){
        totalSupply_ = totalSupply_.add(numTokens);
        balances[minter] = balances[minter].add(numTokens);
        emit Mint(minter, numTokens);
        return true;
    }

    /// @dev                Burn tokens to receive ether
    /// @param burner         The number of tokens that you want to burn
    /// @param numTokens    The number of tokens that you want to burn
    function _burn(address burner, uint256 numTokens) internal returns(bool) {
        totalSupply_ = totalSupply_.sub(numTokens);
        balances[burner] = balances[burner].sub(numTokens);
        emit Burn(burner, numTokens);
        return true;
    }

}
