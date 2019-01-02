pragma solidity ^0.4.23;

import "../node_modules/zeppelin-solidity/contracts/token/ERC20/StandardToken.sol";
import "../node_modules/zeppelin-solidity/contracts/math/SafeMath.sol";
import "./BancorContracts/converter/BancorFormula.sol";

contract BatchBondedToken is StandardToken, BancorFormula {
    using SafeMath for uint256;

    string public name;
    string public symbol;
    uint8 public decimals;

    uint32 public reserveRatio;  // represented in ppm, 1-1000000
    uint32 public ppm = 1000000;
    uint256 public virtualSupply;
    uint256 public virtualBalance;

    uint256 public poolBalance;

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
        uint256 _batchBlocks,
        uint32 _reserveRatio,
        uint256 _virtualSupply,
        uint256 _virtualBalance) public {
            
        name = _name;
        symbol = _symbol;
        decimals = _decimals;

        batchBlocks = _batchBlocks;

        reserveRatio = _reserveRatio;
        virtualSupply = _virtualSupply;
        virtualBalance = _virtualBalance;
    }

    function() public payable {}
    function currentBatch() public view returns(uint cb) {
        cb = (block.number / batchBlocks) * batchBlocks;
    }
    function getBuySellBlocks(address buyerSeller) public view returns (uint256[]) {
        return addressToBlocks[buyerSeller];
    }
    function getBuySellBlocksByIndex(address buyerSeller, uint256 index) public view returns (uint256) {
        return addressToBlocks[buyerSeller][index];
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
        Batch storage cb = batches[waitingClear]; // clearing batch
        if (cb.cleared) return;
        clearSales();
        clearBuys();
        poolBalance = cb.poolBalance;
        // totalSupply_ = cb.totalSupply;
        require(_mint(this, cb.totalBuyReturn), "minting new tokens to be held until buyers collect must succeed");
        cb.cleared = true;
        waitingClear = 0;
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