const { expect } = require("chai");
const { ethers, network } = require("hardhat");
const { BigNumber } = ethers;

describe("Zdte", function() {
  let signers;
  let owner;

  let usdc;
  let weth;
  let quoteLp;
  let baseLp;
  let priceOracle;
  let volatilityOracle;
  let optionPricing;
  let zdte;
  let b50;
  let bf5;
  let initialBaseDeposit = ethers.utils.parseEther("20.0");
  let initialQuoteDeposit = 100000000000;

  const timeTravelOneDay = async () => {
    const blockNumber = await ethers.provider.getBlockNumber();
    const block = await ethers.provider.getBlock(blockNumber);
    const timestamp = block.timestamp;
    const nextDayTimestamp = timestamp + 86400;
    await network.provider.send("evm_setNextBlockTimestamp", [nextDayTimestamp]);
    await network.provider.send("evm_mine");
  }

  const getNextExpiryTimestamp = () => {
    const nextNoon = new Date();
    if (nextNoon.getHours() >= 12) 
      nextNoon.setDate(nextNoon.getDate() + 1);
    nextNoon.setHours(12, 0, 0, 0);
    return (nextNoon.getTime() / 1000).toString();
  }

  before(async () => {
    signers = await ethers.getSigners();
    owner = signers[0];

    // Users
    user0 = signers[1];
    user1 = signers[2];
    user2 = signers[3];
    user3 = signers[4];
  });

  it("should deploy Zdte", async function() {
    // Set timestamp
    await network.provider.send("evm_setNextBlockTimestamp", [Math.floor(Date.now() / 1000)]);
    await network.provider.send("evm_mine");

    // USDC
    usdc = await ethers.getContractAt("contracts/interface/IERC20.sol:IERC20", "0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8");
    // WETH
    weth = await ethers.getContractAt("contracts/interface/IERC20.sol:IERC20", "0x82aF49447D8a07e3bd95BD0d56f35241523fBab1");
    // Price oracle
    const PriceOracle = await ethers.getContractFactory("MockPriceOracle");
    priceOracle = await PriceOracle.deploy();
    // Volatility oracle
    const VolatilityOracle = await ethers.getContractFactory(
      "MockVolatilityOracle"
    );
    volatilityOracle = await VolatilityOracle.deploy();
    // Option pricing
    const OptionPricing = await ethers.getContractFactory("MockOptionPricing");
    optionPricing = await OptionPricing.deploy();

    // Option scalp
    const Zdte = await ethers.getContractFactory("Zdte");
    zdte = await Zdte.deploy(
      weth.address,
      usdc.address,
      optionPricing.address,
      volatilityOracle.address,
      priceOracle.address,
      "0xE592427A0AEce92De3Edee1F18E0157C05861564", // UNI V3 ROUTER
      "5000000000", // Strike increment => 50 * 1e8
      "10", // Max OTM % => 10%
      getNextExpiryTimestamp()
    );

    console.log("deployed Zdte:", zdte.address);
  });

  it("distribute funds to user0, user1, user2 and user3", async function() {
    // Transfer USDC and WETH to our address from another impersonated address
    await network.provider.request({
      method: "hardhat_impersonateAccount",
      params: ["0xB50F58D50e30dFdAAD01B1C6bcC4Ccb0DB55db13"],
    });

    await network.provider.request({
      method: "hardhat_impersonateAccount",
      params: ["0x9bf54297d9270730192a83EF583fF703599D9F18"],
    });

    b50 = await ethers.provider.getSigner(
      "0xB50F58D50e30dFdAAD01B1C6bcC4Ccb0DB55db13"
    );

    bf5 = await ethers.provider.getSigner(
      "0x9bf54297d9270730192a83EF583fF703599D9F18"
    );

    [user0, user1, user2, user3].map(async user => {
      await weth.connect(b50).transfer(user.address, initialBaseDeposit);
      await usdc.connect(bf5).transfer(user.address, initialQuoteDeposit);

      await b50.sendTransaction({
        to: user.address,
        value: ethers.utils.parseEther("10.0")
      });
    });
  });

  it("user 0 deposits", async function() {
    await usdc.connect(user0).approve(zdte.address, initialQuoteDeposit);
    await weth.connect(user0).approve(zdte.address, initialBaseDeposit);

    await expect(zdte.connect(user0).deposit(true, "100000000000000000000000"))
    .to.be.revertedWith("ERC20: transfer amount exceeds balance");

    await zdte.connect(user0).deposit(true, initialQuoteDeposit);
    await zdte.connect(user0).deposit(false, initialBaseDeposit);
  });

  it("user 0 withdraws half", async function() {
    const quoteLpAddress = await zdte.connect(user0).quoteLp();
    quoteLp = await ethers.getContractAt("contracts/token/ZdteLP.sol:ZdteLP", quoteLpAddress);

    const baseLpAddress = await zdte.connect(user0).baseLp();
    baseLp = await ethers.getContractAt("contracts/token/ZdteLP.sol:ZdteLP", baseLpAddress);

    const balance = await quoteLp.balanceOf(user0.address);
    expect(balance).to.eq("100000000000");

    // Allowance is required
    await quoteLp.connect(user0).approve(zdte.address, "1000000000000000000000000000000000");
    await baseLp.connect(user0).approve(zdte.address, "1000000000000000000000000000000000");

    await expect(zdte.connect(user0).withdraw(true, "10000000000000"))
      .to.be.revertedWith('Not enough available assets to satisfy withdrawal');

    const startQuoteBalance = await usdc.balanceOf(user0.address);
    await zdte.connect(user0).withdraw(true, balance.div(2));
    const endQuoteBalance = await usdc.balanceOf(user0.address);

    const quoteOut = endQuoteBalance.sub(startQuoteBalance);
    expect(quoteOut).to.eq("50000000000");
  });
  

  it("user 1 opens profitable long call position", async function() {
    await priceOracle.updateUnderlyingPrice("160000000000"); // $1600
    const startQuoteBalance = await usdc.balanceOf(user1.address);
    console.log('Start quote balance:', startQuoteBalance.toString());

    await usdc.connect(user1).approve(zdte.address, "10000000000");
    await zdte.connect(user1).longOptionPosition(
      false, 
      "1000000000000000000",
      "160000000000", 
    ); // 1 $1600 call option

    let preExpireBaseBalance = await weth.balanceOf(user1.address);

    await priceOracle.updateUnderlyingPrice("165000000000"); // $1650
    await timeTravelOneDay();
    await zdte.connect(user1).expireLongOptionPosition(0);

    quoteBalance = await usdc.balanceOf(user1.address);
    baseBalance = await weth.balanceOf(user1.address);
    let pnl = baseBalance.sub(preExpireBaseBalance);

    expect(pnl.mul("165000000000").div("1000000000000000000")).equals("4999999999");
  });

  it("user 1 opens profitable long put position", async function() {
    await priceOracle.updateUnderlyingPrice("160000000000"); // $1600
    const startQuoteBalance = await usdc.balanceOf(user1.address);
    console.log('Start quote balance:', startQuoteBalance.toString());

    await usdc.connect(user1).approve(zdte.address, "10000000000");
    await zdte.connect(user1).longOptionPosition(
      true, 
      "1000000000000000000",
      "160000000000", 
    ); // 1 $1600 put option

    let preExpireQuoteBalance = await usdc.balanceOf(user1.address);

    await priceOracle.updateUnderlyingPrice("155000000000"); // $1550
    await timeTravelOneDay();
    await zdte.connect(user1).expireLongOptionPosition(1);

    let postExpireQuoteBalance = await usdc.balanceOf(user1.address);
    let pnl = postExpireQuoteBalance.sub(preExpireQuoteBalance);

    expect(pnl.div("1000000")).equals("50");
  });

  it("user 0 withdraws profitable quote LP position", async function() {
    await priceOracle.updateUnderlyingPrice("160000000000"); // $1600
    const startQuoteBalance = await usdc.balanceOf(user1.address);
    console.log('Start quote balance:', startQuoteBalance.toString());

    await usdc.connect(user1).approve(zdte.address, "10000000000");
    await zdte.connect(user1).longOptionPosition(
      true, 
      "10000000000000000000",
      "160000000000", 
    ); // 10 $1600 put option
    await timeTravelOneDay();
    await zdte.connect(user1).expireLongOptionPosition(2);

    await zdte.connect(user0).withdraw(true, (await quoteLp.balanceOf(user0.address)));
    const postWithdrawQuoteBalance = (await usdc.balanceOf(user0.address)).toNumber();
    
    expect(postWithdrawQuoteBalance).gt(initialQuoteDeposit);
  });

  it("user 0 cannot withdraw more than available assets from quote LP ", async function() {
    await usdc.connect(user0).approve(zdte.address, initialQuoteDeposit);
    await zdte.connect(user0).deposit(true, initialQuoteDeposit);

    await usdc.connect(user1).approve(zdte.address, "10000000000");
    await zdte.connect(user1).longOptionPosition(
      true, 
      "1000000000000000000",
      "160000000000", 
    ); // 1 $1600 put option

    await expect(
      zdte.connect(user0).withdraw(true, await quoteLp.balanceOf(user0.address))
    ).to.be.revertedWith("Not enough available assets to satisfy withdrawal");
  });

  it("user 0 withdraws profitable base LP position", async function() {
    await priceOracle.updateUnderlyingPrice("160000000000"); // $1600

    await usdc.connect(user1).approve(zdte.address, "10000000000");

    await zdte.connect(user1).longOptionPosition(
      false, 
      "10000000000000000000",
      "160000000000", 
    ); // 5 $1600 call option
    await timeTravelOneDay();
    await zdte.connect(user1).expireLongOptionPosition(3);
    await zdte.connect(user1).expireLongOptionPosition(4);

    await zdte.connect(user0).withdraw(false, (await baseLp.balanceOf(user0.address)));
    const postWithdrawBaseBalance = await weth.balanceOf(user0.address);
    
    expect(postWithdrawBaseBalance.gt(initialBaseDeposit)).equals(true);
  });

  it("user 0 cannot withdraw more than available assets from base LP ", async function() {
    await weth.connect(user0).approve(zdte.address, initialBaseDeposit);
    await zdte.connect(user0).deposit(false, initialBaseDeposit);

    await weth.connect(user1).approve(zdte.address, initialBaseDeposit);
    await zdte.connect(user1).longOptionPosition(
      false, 
      "1000000000000000000",
      "160000000000", 
    ); // 1 $1600 call option

    await expect(
      zdte.connect(user0).withdraw(false, await baseLp.balanceOf(user0.address))
    ).to.be.revertedWith("Not enough available assets to satisfy withdrawal");
  });

  it("user 1 cannot open long option position with invalid strike", async function() {
    await priceOracle.updateUnderlyingPrice("160000000000"); // $1600
    const startQuoteBalance = await usdc.balanceOf(user1.address);
    console.log('Start quote balance:', startQuoteBalance.toString());

    await usdc.connect(user1).approve(zdte.address, "10000000000");
    await expect(zdte.connect(user1).longOptionPosition(
      true, 
      "1000000000000000000",
      "140000000000", 
    )).to.be.revertedWith("Invalid strike"); // 1 $1400 put option - >10% away from mark price
  });

  it("user 1 cannot expire position prior to expiry", async function() {
    await priceOracle.updateUnderlyingPrice("160000000000"); // $1600
    const startQuoteBalance = await usdc.balanceOf(user1.address);
    console.log('Start quote balance:', startQuoteBalance.toString());

    await usdc.connect(user1).approve(zdte.address, "10000000000");
    await zdte.connect(user1).longOptionPosition(
      true, 
      "1000000000000000000",
      "150000000000", 
    ); // 1 $1500 put option
    await expect(zdte.connect(user1).expireLongOptionPosition(6)).to.be.revertedWith("Position must be past expiry time");
  });

});