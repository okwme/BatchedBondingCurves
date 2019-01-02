var BatchBondedToken = artifacts.require('./BatchBondedToken.sol')
let _ = '        '

let bbtOpts = {
  name: "Big Batch Token",
  symbol: "BBT",
  decimals: 18,
  batchBlocks: 50,
  reserveRatio: 500000, // 0.5 ie linear curve
  virtualSupply: 10,
  virtualBalance: 10,
}

module.exports = (deployer, helper, accounts) => {

  deployer.then(async () => {
    try {
      // Deploy BatchBondedToken.sol
      await deployer.deploy(
        BatchBondedToken,
        bbtOpts.name,
        bbtOpts.symbol,
        bbtOpts.decimals,
        bbtOpts.batchBlocks,
        bbtOpts.reserveRatio,
        bbtOpts.virtualSupply,
        bbtOpts.virtualBalance,  
      )
      let bbt = await BatchBondedToken.deployed()
      console.log(_ + 'BatchBondedToken deployed at: ' + bbt.address)

    } catch (error) {
      console.log(error)
    }
  })
}
