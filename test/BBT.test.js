var BatchBondedToken = artifacts.require('./BatchBondedToken')
var BigNumber = require('bignumber.js')
let gasPrice = 1000000000 // 1GWEI

let _ = '        '

let bbtOpts = {
  name: "Big Batch Token",
  symbol: "BBT",
  decimals: 18,
  batchBlocks: 50,
  reserveRatio: 500000, // 0.5 ie linear curve
  virtualSupply: 1000,
  virtualBalance: 1000,
}

contract('BatchBondedToken', async function(accounts) {
  let bbt

  before(done => {
    ;(async () => {
      try {
        var totalGas = new BigNumber(0)

        // Deploy BatchBondedToken.sol
        bbt = await BatchBondedToken.new(
          bbtOpts.name,
          bbtOpts.symbol,
          bbtOpts.decimals,
          bbtOpts.batchBlocks,
          bbtOpts.reserveRatio,
          bbtOpts.virtualSupply,
          bbtOpts.virtualBalance,
        )
        var tx = await web3.eth.getTransactionReceipt(bbt.transactionHash)
        totalGas = totalGas.plus(tx.gasUsed)
        console.log(_ + tx.gasUsed + ' - Deploy BatchBondedToken')
        bbt = await BatchBondedToken.deployed()

        console.log(_ + '-----------------------')
        console.log(_ + totalGas.toFormat(0) + ' - Total Gas')
        done()
      } catch (error) {
        console.error(error)
        done(false)
      }
    })()
  })

  describe('BatchBondedToken.sol', function() {
    it('calcs current batch', async function() {
      const getBatch = (blockNumber, batchBlocks) => {
        return Math.floor(blockNumber / batchBlocks) * batchBlocks
      }
      let bNum = await getBlockNumber()
      let bBlocks = await bbt.batchBlocks()
      let expectCb = getBatch(bNum, bBlocks.toNumber())
      let cb = await bbt.currentBatch()
      assert(
        expectCb === cb.toNumber(),
        'it is the expected current batch'
      )
    })
    it('does an initial buys', async function() {
      const addBuys = howMany => {
        let buys = []
        for (let i = 0; i < howMany; i++) {
          let recip = accounts[i%10]
          let value = web3.utils.toWei('0.1', 'ether')
          buys.push(
            bbt.addBuy(recip, {
              from: recip,
              value,
            })
          )
        }
        return buys
      }
      // add one to test gas
      let addBuyTx = await bbt.addBuy(accounts[0],
        {
          from: accounts[0],
          value: web3.utils.toWei('0.5', 'ether'),
        }
      )
      console.log(_ + addBuyTx.receipt.gasUsed + ' - .addBuy() gas used')
      // now add a bunch
      await Promise.all(addBuys(15));

      // clear this batch w/ 16 buy orders
      let wc = await bbt.waitingClear()
      let cb = await bbt.currentBatch()
      await increaseBlocks(50)
      assert(
        wc.toNumber() === cb.toNumber(),
        'there must be a batch waiting to be cleared',
      )
      await bbt.clearBatch()
      wc = await bbt.waitingClear()
      assert(
        wc.toNumber() === 0,
        'no longer a batch to be cleared',
      )

      let batch = await bbt.batches(cb);
      let {
        init,
        buysCleared,
        sellsCleared,
        cleared,
        poolBalance,
        totalSupply,
        totalBuySpend,
        totalBuyReturn,
        totalSellSpend,
        totalSellReturn,
      } = batch

      assert(init, 'should be init')
      assert(buysCleared, 'we just cleared it')
      assert(!sellsCleared, 'false because no sells')
      assert(cleared, 'we cleared')

      // did a hard calculation, should change to compute
      let totalSpent = web3.utils.toWei('2', 'ether')
      let expectedPb = totalSpent.toString()
      assert(
        poolBalance.toString() === expectedPb,
        'pool balance should be the total spend'
      )
      
      assert(
        totalBuySpend.toString() === totalSpent,
        'total spent on buys is the total spent'
      )

      assert(
        totalBuyReturn.toNumber() > 0,
        'bought some tokens'
      )

      // We need decimal support to get this
      // console.log(totalBuyReturn.toString())
      // console.log(totalBuySpend.toString())
      // let computedPrice = totalBuyReturn.div(totalBuySpend)
      // console.log(computedPrice)

      assert(
        totalSellSpend.toString() === '0',
        'no sell spend'
      )
      assert(
        totalSellReturn.toString() === '0',
        'no sell return'
      )

      // all tokens minted to the BBT
      const beforeSup = await bbt.balanceOf(bbt.address);
      assert(
        beforeSup.toString() === totalBuyReturn.toString(),
        'all tokens minted to contract'
      )

      const claimTx = await bbt.claimBuy(cb, accounts[0]);
      console.log(_ + claimTx.receipt.gasUsed + ' - .claimBuy() gas used')

      // claim all buys
      await Promise.all(
        accounts.map((acc, idx) => {
          if (idx === 0) return;
          return bbt.claimBuy(cb, acc);
        })
      )

      const afterSup = await bbt.balanceOf(bbt.address)
        // console.log(afterSup.toString())
      assert(
        afterSup.toNumber() < 10, // dust
        'all tokens have been distributed'
      )
    })
  })
})

function getBlockNumber() {
  return new Promise((resolve, reject) => {
    web3.eth.getBlockNumber((error, result) => {
      if (error) reject(error)
      resolve(result)
    })
  })
}

function increaseBlocks(blocks) {
  return new Promise((resolve, reject) => {
    increaseBlock().then(() => {
      blocks -= 1
      if (blocks == 0) {
        resolve()
      } else {
        increaseBlocks(blocks).then(resolve)
      }
    })
  })
}

function increaseBlock() {
  return new Promise((resolve, reject) => {
    web3._provider.send(
      {
        jsonrpc: '2.0',
        method: 'evm_mine',
        id: 12345
      },
      (err, result) => {
        if (err) reject(err)
        resolve(result)
      }
    )
  })
}

function decodeEventString(hexVal) {
  return hexVal
    .match(/.{1,2}/g)
    .map(a =>
      a
        .toLowerCase()
        .split('')
        .reduce(
          (result, ch) => result * 16 + '0123456789abcdefgh'.indexOf(ch),
          0
        )
    )
    .map(a => String.fromCharCode(a))
    .join('')
}
