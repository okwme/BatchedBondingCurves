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
        require(balanceOf(msg.sender) >= amount, "insufficient funds to do that");
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

        // The static price is the current exact price.
        uint256 staticPrice = getPricePPM(cb.totalSupply, cb.poolBalance);

        // resultOfSell is the amount of collateral that would result if all the sales took
        // place at the current exact price instead of the bonding curve price over the span
        // of tokens that were sold.
        uint256 resultOfSell = cb.totalSellSpend.mul(staticPrice) / ppm;

        // if the collateral resulting from the sells is GREATER THAN 
        // the total amount of collateral to be spent during all buys
        // then all of the buys can be executed at that exact price
        // and the remaining sales can go back to the original bonding
        // curve scenario.
        if (resultOfSell >= cb.totalBuySpend) {

            // total number of tokens created as a result of all of the buys being executed at the
            // current exact price (tokens = collateral / price). staticPrice is in ppm, to avoid
            // overflows it has been re-arranged.
            cb.totalBuyReturn = cb.totalBuySpend.mul(ppm) / staticPrice;
            cb.buysCleared = true;

            // there are some tokens left over to be sold. these should be the difference between
            // the original total sell order, and the result of executing all of the buys
            uint256 remainingSell = cb.totalSellSpend.sub(resultOfSell);

            // now that we know how many tokens are left to be sold we can get the amount of collateral
            // generated by selling them through a normal bonding curve execution, based on the 
            // original totalSupply and poolBalance (as if the buy orders never existed and the sell
            // order was just smaller than originally thought).
            uint256 remainingSellReturn = getSell(cb.totalSupply, cb.poolBalance, remainingSell);

            // totalSellReturn becomes the result of selling out to the buy orders
            // plus the getSell() return from selling the remaining tokens
            cb.totalSellReturn = resultOfSell.add(remainingSellReturn);

            // TotalSupply doesn't need to be changed (keep it commented out). It only needs to be changed 
            // by clearSales or clearBuys scenario so that the subsequent clearSales/clearBuys
            // can correctly calculate the purchaseReturn/saleReturn.
            // cb.totalSupply = cb.totalSupply.sub(remainingSell);
            
            // poolBalance is ultimately only affected by the net difference between the buys and sells
            cb.poolBalance = cb.poolBalance.sub(remainingSellReturn);
            cb.sellsCleared = true;

        // if the collateral resulting from the sells is LESS THAN 
        // the total amount of collateral to be spent during all buys
        // then all of the sells can be executed at that exact price
        // and the remaining buys can go back to the original bonding
        // curve scenario.
        } else {

            // total amount of collateral released as a result of all of the sells being executed at the
            // current exact price (collateral =  price * token). staticPrice is in ppm, to avoid
            // overflows it has been re-arranged.
            cb.totalSellReturn = cb.totalSellSpend.mul(staticPrice) / ppm;
            cb.sellsCleared = true;

            // there is some collateral left over to be spent. this should be the difference between
            // the original total buy order, and the result of executing all of the sells
            uint256 resultOfBuy = cb.totalBuySpend.mul(ppm) / staticPrice;
            uint256 remainingBuy = cb.totalBuySpend.sub(resultOfBuy);

            // now that we know how much collateral is left to be spent we can get the amount of tokens
            // generated by spending it through a normal bonding curve execution, based on the 
            // original totalSupply and poolBalance (as if the sell orders never existed and the buy
            // order was just smaller than originally thought).
            uint256 remainingBuyReturn = getBuy(cb.totalSupply, cb.poolBalance, remainingBuy);

            // remainingBuyReturn becomes the result of buying out to the sell orders
            // plus the getBuy() return from spending the remaining collateral
            cb.totalBuyReturn = resultOfBuy.add(remainingBuyReturn);

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
        Batch storage cb = batches[batch]; // claming batch
        require(cb.cleared, "can't claim a batch that hasn't cleared");
        require(cb.sellers[sender] != 0, "already claimed this sell");
        uint256 individualSellReturn = (cb.totalSellReturn.mul(cb.sellers[sender])).div(cb.totalSellSpend);
        cb.sellers[sender] = 0;
        sender.transfer(individualSellReturn);
    }
    function claimBuy(uint256 batch, address sender) public {
        Batch storage cb = batches[batch]; // claming batch
        require(cb.cleared, "can't claim a batch that hasn't cleared");
        require(cb.buyers[sender] != 0, "already claimed this buy");
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