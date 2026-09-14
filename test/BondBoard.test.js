const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("BondBoard", function () {
  let bb, owner, issuer, alice, bob, carol;
  const P = ethers.parseEther("10");
  const R = ethers.parseEther("11"); // 10% coupon
  const MATURITY = 30 * 24 * 60 * 60;
  const CBPS = 5000; // 50%
  const COLL = (P * 5000n) / 10000n;

  beforeEach(async () => {
    [owner, issuer, alice, bob, carol] = await ethers.getSigners();
    const F = await ethers.getContractFactory("BondBoard");
    bb = await F.deploy();
    await bb.waitForDeployment();
  });

  async function issue() {
    await bb.connect(issuer).issueBond(P, R, MATURITY, CBPS, { value: COLL });
    return 1n;
  }

  it("issueBond validates collateral and ratios", async () => {
    await expect(bb.connect(issuer).issueBond(P, R, MATURITY, CBPS, { value: COLL - 1n }))
      .to.be.revertedWith("wrong collateral");
    await expect(bb.connect(issuer).issueBond(P, P, MATURITY, CBPS, { value: COLL }))
      .to.be.revertedWith("repay<=principal");
    await expect(bb.connect(issuer).issueBond(P, R, 60, CBPS, { value: COLL }))
      .to.be.revertedWith("bad maturity");
    await expect(bb.connect(issuer).issueBond(P, R, MATURITY, 500, { value: 0 }))
      .to.be.revertedWith("bad collateral");
    await bb.connect(issuer).issueBond(P, R, MATURITY, CBPS, { value: COLL });
    expect(await bb.bondCount()).to.equal(1n);
  });

  it("fundBond accumulates and refunds overflow", async () => {
    const id = await issue();
    await bb.connect(alice).fundBond(id, { value: ethers.parseEther("6") });
    const balBefore = await ethers.provider.getBalance(bob.address);
    const tx = await bb.connect(bob).fundBond(id, { value: ethers.parseEther("10") });
    const rc = await tx.wait();
    const gas = rc.gasUsed * rc.gasPrice;
    const balAfter = await ethers.provider.getBalance(bob.address);
    // bob only funds 4 ETH (fills remainder), 6 refunded
    expect(balBefore - balAfter - gas).to.equal(ethers.parseEther("4"));
    const b = await bb.getBond(id);
    expect(b[4]).to.equal(P);
    expect(b[7]).to.equal(1); // Funded
  });

  it("drawPrincipal requires Funded and issuer, deducts fee", async () => {
    const id = await issue();
    await expect(bb.connect(issuer).drawPrincipal(id)).to.be.revertedWith("not funded");
    await bb.connect(alice).fundBond(id, { value: P });
    await expect(bb.connect(alice).drawPrincipal(id)).to.be.revertedWith("not issuer");
    const before = await ethers.provider.getBalance(issuer.address);
    const tx = await bb.connect(issuer).drawPrincipal(id);
    const rc = await tx.wait();
    const gas = rc.gasUsed * rc.gasPrice;
    const after = await ethers.provider.getBalance(issuer.address);
    const fee = (P * 50n) / 10000n;
    expect(after - before + gas).to.equal(P - fee);
    expect(await bb.accruedFees()).to.equal(fee);
  });

  it("repayBond marks Repaid, releases collateral", async () => {
    const id = await issue();
    await bb.connect(alice).fundBond(id, { value: P });
    await bb.connect(issuer).drawPrincipal(id);
    await expect(bb.connect(alice).repayBond(id, { value: R })).to.be.revertedWith("not issuer");
    await expect(bb.connect(issuer).repayBond(id, { value: R - 1n })).to.be.revertedWith("wrong amount");
    const before = await ethers.provider.getBalance(issuer.address);
    const tx = await bb.connect(issuer).repayBond(id, { value: R });
    const rc = await tx.wait();
    const gas = rc.gasUsed * rc.gasPrice;
    const after = await ethers.provider.getBalance(issuer.address);
    // net: paid R, got back COLL
    expect(before - after - gas).to.equal(R - COLL);
    const b = await bb.getBond(id);
    expect(b[7]).to.equal(3);
  });

  it("funders claim repayment pro-rata", async () => {
    const id = await issue();
    await bb.connect(alice).fundBond(id, { value: ethers.parseEther("7") });
    await bb.connect(bob).fundBond(id, { value: ethers.parseEther("3") });
    await bb.connect(issuer).drawPrincipal(id);
    await bb.connect(issuer).repayBond(id, { value: R });

    const aB = await ethers.provider.getBalance(alice.address);
    const tx = await bb.connect(alice).claimRepayment(id);
    const rc = await tx.wait();
    const g = rc.gasUsed * rc.gasPrice;
    const aA = await ethers.provider.getBalance(alice.address);
    // alice owed 7/10 * 11 = 7.7
    expect(aA - aB + g).to.equal(ethers.parseEther("7.7"));

    await bb.connect(bob).claimRepayment(id);
    await expect(bb.connect(alice).claimRepayment(id)).to.be.revertedWith("claimed");
  });

  it("seizeCollateral requires maturity + grace elapsed", async () => {
    const id = await issue();
    await bb.connect(alice).fundBond(id, { value: P });
    await bb.connect(issuer).drawPrincipal(id);
    await expect(bb.seizeCollateral(id)).to.be.revertedWith("grace not over");
    await time.increase(MATURITY + 7 * 24 * 60 * 60 + 1);
    await bb.connect(carol).seizeCollateral(id);
    const b = await bb.getBond(id);
    expect(b[7]).to.equal(4);
  });

  it("claimCollateral pro-rata after default", async () => {
    const id = await issue();
    await bb.connect(alice).fundBond(id, { value: ethers.parseEther("4") });
    await bb.connect(bob).fundBond(id, { value: ethers.parseEther("6") });
    await bb.connect(issuer).drawPrincipal(id);
    await time.increase(MATURITY + 7 * 24 * 60 * 60 + 1);
    await bb.seizeCollateral(id);

    const aB = await ethers.provider.getBalance(alice.address);
    const tx = await bb.connect(alice).claimCollateral(id);
    const rc = await tx.wait();
    const g = rc.gasUsed * rc.gasPrice;
    const aA = await ethers.provider.getBalance(alice.address);
    // 4/10 * 5 = 2 ETH
    expect(aA - aB + g).to.equal(ethers.parseEther("2"));
  });

  it("cancelBond refunds funders and collateral", async () => {
    const id = await issue();
    await bb.connect(alice).fundBond(id, { value: ethers.parseEther("3") });
    const aB = await ethers.provider.getBalance(alice.address);
    const iB = await ethers.provider.getBalance(issuer.address);
    const tx = await bb.connect(issuer).cancelBond(id);
    const rc = await tx.wait();
    const g = rc.gasUsed * rc.gasPrice;
    const aA = await ethers.provider.getBalance(alice.address);
    const iA = await ethers.provider.getBalance(issuer.address);
    expect(aA - aB).to.equal(ethers.parseEther("3"));
    expect(iA - iB + g).to.equal(COLL);
    const b = await bb.getBond(id);
    expect(b[7]).to.equal(5);
  });

  it("only issuer can drawPrincipal / repay / cancel", async () => {
    const id = await issue();
    await bb.connect(alice).fundBond(id, { value: P });
    await expect(bb.connect(carol).drawPrincipal(id)).to.be.revertedWith("not issuer");
    await bb.connect(issuer).drawPrincipal(id);
    await expect(bb.connect(carol).repayBond(id, { value: R })).to.be.revertedWith("not issuer");
    await expect(bb.connect(carol).cancelBond(id)).to.be.revertedWith("not issuer");
  });

  it("non-funder cannot claim", async () => {
    const id = await issue();
    await bb.connect(alice).fundBond(id, { value: P });
    await bb.connect(issuer).drawPrincipal(id);
    await bb.connect(issuer).repayBond(id, { value: R });
    await expect(bb.connect(carol).claimRepayment(id)).to.be.revertedWith("not funder");
  });

  it("double claim rejected", async () => {
    const id = await issue();
    await bb.connect(alice).fundBond(id, { value: P });
    await bb.connect(issuer).drawPrincipal(id);
    await bb.connect(issuer).repayBond(id, { value: R });
    await bb.connect(alice).claimRepayment(id);
    await expect(bb.connect(alice).claimRepayment(id)).to.be.revertedWith("claimed");
  });

  it("cannot cancel once funded fully", async () => {
    const id = await issue();
    await bb.connect(alice).fundBond(id, { value: P });
    await expect(bb.connect(issuer).cancelBond(id)).to.be.revertedWith("not open");
  });

  it("issuer history tracks repaid and defaulted", async () => {
    const id = await issue();
    await bb.connect(alice).fundBond(id, { value: P });
    await bb.connect(issuer).drawPrincipal(id);
    await bb.connect(issuer).repayBond(id, { value: R });
    const h = await bb.getIssuerHistory(issuer.address);
    expect(h[1]).to.equal(1n);
    expect(h[2]).to.equal(0n);
  });

  it("withdraw fees works", async () => {
    const id = await issue();
    await bb.connect(alice).fundBond(id, { value: P });
    await bb.connect(issuer).drawPrincipal(id);
    const fee = (P * 50n) / 10000n;
    expect(await bb.accruedFees()).to.equal(fee);
    await bb.withdrawFees(owner.address);
    expect(await bb.accruedFees()).to.equal(0n);
  });

  it("getFunderPositions lists bonds funded", async () => {
    const id = await issue();
    await bb.connect(alice).fundBond(id, { value: ethers.parseEther("1") });
    const pos = await bb.getFunderPositions(alice.address);
    expect(pos.length).to.equal(1);
    expect(pos[0]).to.equal(id);
  });
});
