const { expect } = require("chai");
const { ethers, network } = require("hardhat");
const { BigNumber } = ethers;

describe("Zdte", function () {
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
    await network.provider.send("evm_setNextBlockTimestamp", [
      nextDayTimestamp,
    ]);
    await network.provider.send("evm_mine");
  };

  const getNextExpiryTimestamp = () => {
    const nextNoon = new Date();
    if (nextNoon.getHours() >= 12) nextNoon.setDate(nextNoon.getDate() + 1);
    nextNoon.setHours(12, 0, 0, 0);
    return (nextNoon.getTime() / 1000).toString();
  };

  before(async () => {
    signers = await ethers.getSigners();
    owner = signers[0];

    // Users
    user0 = signers[1];
    user1 = signers[2];
    user2 = signers[3];
    user3 = signers[4];
  });

  it("should deploy Zdte", async function () {
    // Set timestamp
    await network.provider.send("evm_setNextBlockTimestamp", [
      Math.floor(Date.now() / 1000),
    ]);
    await network.provider.send("evm_mine");

    // USDC
    usdc = await ethers.getContractAt(
      "contracts/interface/IERC20.sol:IERC20",
      "0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8"
    );
    // WETH
    weth = await ethers.getContractAt(
      "contracts/interface/IERC20.sol:IERC20",
      "0x82aF49447D8a07e3bd95BD0d56f35241523fBab1"
    );
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
      "0xB50F58D50e30dFdAAD01B1C6bcC4Ccb0DB55db13",
      "5000000000", // Strike increment => 50 * 1e8
      "10", // Max OTM % => 10%
      getNextExpiryTimestamp(),
      "ETH-USD-ZDTE"
    );

    console.log("deployed Zdte:", zdte.address);
  });

  it("distribute funds to user0, user1, user2 and user3", async function () {
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

    [user0, user1, user2, user3].map(async (user) => {
      await weth.connect(b50).transfer(user.address, initialBaseDeposit);
      await usdc.connect(bf5).transfer(user.address, initialQuoteDeposit);

      await b50.sendTransaction({
        to: user.address,
        value: ethers.utils.parseEther("10.0"),
      });
    });
  });

  it("user 0 deposits", async function () {
    await usdc.connect(user0).approve(zdte.address, initialQuoteDeposit);
    await weth.connect(user0).approve(zdte.address, initialBaseDeposit);

    await expect(
      zdte.connect(user0).deposit(true, "100000000000000000000000")
    ).to.be.revertedWith("ERC20: transfer amount exceeds balance");

    await zdte.connect(user0).deposit(true, initialQuoteDeposit);
    await zdte.connect(user0).deposit(false, initialBaseDeposit);
  });

  it("user 0 withdraws half", async function () {
    const quoteLpAddress = await zdte.connect(user0).quoteLp();
    quoteLp = await ethers.getContractAt(
      "contracts/token/ZdteLP.sol:ZdteLP",
      quoteLpAddress
    );

    const baseLpAddress = await zdte.connect(user0).baseLp();
    baseLp = await ethers.getContractAt(
      "contracts/token/ZdteLP.sol:ZdteLP",
      baseLpAddress
    );

    const balance = await quoteLp.balanceOf(user0.address);
    expect(balance).to.eq("100000000000");

    // Allowance is required
    await quoteLp
      .connect(user0)
      .approve(zdte.address, "1000000000000000000000000000000000");
    await baseLp
      .connect(user0)
      .approve(zdte.address, "1000000000000000000000000000000000");

    await timeTravelOneDay();

    const startQuoteBalance = await usdc.balanceOf(user0.address);
    await zdte.connect(user0).withdraw(true, balance.div(2));
    const endQuoteBalance = await usdc.balanceOf(user0.address);

    const quoteOut = endQuoteBalance.sub(startQuoteBalance);
    expect(quoteOut).to.eq("50000000000");
  });

  it("user 1 opens profitable spread call position", async function () {
    await priceOracle.updateUnderlyingPrice("160000000000"); // $1600
    const startQuoteBalance = await usdc.balanceOf(user1.address);
    console.log("Start quote balance:", startQuoteBalance.toString());

    await usdc.connect(user1).approve(zdte.address, "10000000000");
    await zdte
      .connect(user1)
      .spreadOptionPosition(false, "1000000", "160000000000", "170000000000"); // 1 $1600 long strike, $1700 short strike

    await priceOracle.updateUnderlyingPrice("165000000000"); // $1650
    await timeTravelOneDay();
    // await zdte.connect(user1).expireSpreadOptionPosition(7);
  });

  it("user 1 opens profitable spread put position", async function () {
    await priceOracle.updateUnderlyingPrice("160000000000"); // $1600
    const startQuoteBalance = await usdc.balanceOf(user1.address);
    console.log("Start quote balance:", startQuoteBalance.toString());

    await usdc.connect(user1).approve(zdte.address, "10000000000");
    await zdte
      .connect(user1)
      .spreadOptionPosition(
        true,
        "10000000000000000",
        "160000000000",
        "150000000000"
      ); // 1 $1600 long strike, $1500 short strike

    await priceOracle.updateUnderlyingPrice("155000000000"); // $1550
    await timeTravelOneDay();
    // await zdte.connect(user1).expireSpreadOptionPosition(8);
  });

  it("user 1 cannot open put spread option position with invalid strike", async function () {
    await priceOracle.updateUnderlyingPrice("160000000000"); // $1600
    const startQuoteBalance = await usdc.balanceOf(user1.address);
    console.log("Start quote balance:", startQuoteBalance.toString());

    await usdc.connect(user1).approve(zdte.address, "10000000000");
    await expect(
      zdte
        .connect(user1)
        .spreadOptionPosition(
          true,
          "1000000000000000000",
          "140000000000",
          "150000000000"
        )
    ).to.be.revertedWith("Invalid long strike");
  });

  it("user 1 cannot open call spread option position with invalid strike", async function () {
    await priceOracle.updateUnderlyingPrice("160000000000"); // $1600
    const startQuoteBalance = await usdc.balanceOf(user1.address);
    console.log("Start quote balance:", startQuoteBalance.toString());

    await usdc.connect(user1).approve(zdte.address, "10000000000");
    await expect(
      zdte
        .connect(user1)
        .spreadOptionPosition(
          false,
          "1000000000000000000",
          "160000000000",
          "150000000000"
        )
    ).to.be.revertedWith("Invalid long strike");
  });
});
