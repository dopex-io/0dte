const { expect } = require("chai");
const { ethers, network } = require("hardhat");
const { BigNumber } = ethers;

describe("0dte", function() {
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

  before(async () => {
    signers = await ethers.getSigners();
    owner = signers[0];

    // Users
    user0 = signers[1];
    user1 = signers[2];
    user2 = signers[3];
    user3 = signers[4];
  });

  it("should deploy 0dte", async function() {
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
    const Zdte = await ethers.getContractFactory("0dte");
    zdte = await Zdte.deploy(
      weth.address,
      usdc.address,
      optionPricing.address,
      volatilityOracle.address,
      priceOracle.address,
      "0xE592427A0AEce92De3Edee1F18E0157C05861564" // UNI V3 ROUTER
    );

    console.log("deployed 0dte:", zdte.address);
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
      await weth.connect(b50).transfer(user.address, ethers.utils.parseEther("10.0"));
      await usdc.connect(bf5).transfer(user.address, "10000000000");

      await b50.sendTransaction({
        to: user.address,
        value: ethers.utils.parseEther("10.0")
      });
    });
  });

  it("user 0 deposits", async function() {
    await usdc.connect(user0).approve(zdte.address, "10000000000");
    await weth.connect(user0).approve(zdte.address, ethers.utils.parseEther("10.0"));

    await expect(zdte.connect(user0).deposit(true, "100000000000000000000000"))
    .to.be.revertedWith("ERC20: transfer amount exceeds balance");

    await zdte.connect(user0).deposit(true, "10000000000");
    await zdte.connect(user0).deposit(false, ethers.utils.parseEther("10.0"));
  });

  it("user 0 withdraws half", async function() {
    const zdteLpAddress = await zdte.connect(user0).quoteLp();
    quoteLp = await ethers.getContractAt("contracts/interface/IERC20.sol:IERC20", zdteLpAddress);
    const balance = await quoteLp.balanceOf(user0.address);
    expect(balance).to.eq("10000000000");

    // Allowance is required
    await quoteLp.connect(user0).approve(zdte.address, "1000000000000000000000000000000000");

    await expect(zdte.connect(user0).withdraw(true, "10000000000000"))
      .to.be.revertedWith('Not enough available assets to satisfy withdrawal');

    const startQuoteBalance = await usdc.balanceOf(user0.address);
    await zdte.connect(user0).withdraw(true, balance.div(2));
    const endQuoteBalance = await usdc.balanceOf(user0.address);

    const quoteOut = endQuoteBalance.sub(startQuoteBalance);
    expect(quoteOut).to.eq("5000000000");
  });

  it("user 1 opens long call position", async function() {
  });

  it("user 1 opens long put position", async function() {
  });

  it("user 1 closes profitable long call position", async function() {
  });

  it("user 1 closes unprofitable long put position", async function() {
  });

  it("user 0 withdraws profitable LP position", async function() {
  });

  it("user 0 cannot withdraw more than available assets from LP ", async function() {
  });

});