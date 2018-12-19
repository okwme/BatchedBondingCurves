var Sample = artifacts.require('./Sample.sol')
let _ = '        '

module.exports = (deployer, helper, accounts) => {

  deployer.then(async () => {
    try {
      // Deploy Sample.sol
      await deployer.deploy(Sample)
      let sample = await Sample.deployed()
      console.log(_ + 'Sample deployed at: ' + sample.address)

    } catch (error) {
      console.log(error)
    }
  })
}
