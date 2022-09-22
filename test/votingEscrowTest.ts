import "module-alias/register";

import { expect } from "chai";
import { ethers, waffle, network } from "hardhat";
import { createSnapshot, restoreSnapshot } from "./helpers/snapshots";
import {
  Blocklist,
  MockERC20,
  MockSmartWallet,
  DelegatedVotingEscrow,
} from "../typechain";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/dist/src/signer-with-address";
import { advanceBlocks } from "./helpers/time";
import { BigNumber } from "@ethersproject/contracts/node_modules/@ethersproject/bignumber";
import { Signer, utils } from "ethers";
import { increaseTime, increaseTimeTo } from "./helpers/time2";
import { assertBNClosePercent } from "./helpers/assertions";
import { ONE_WEEK } from "./helpers/constants";

const { provider } = waffle;

describe("VotingEscrow Tests", function () {
  let ve: DelegatedVotingEscrow;
  let blocklist: Blocklist;
  let fdtMock: MockERC20;
  let contract: MockSmartWallet;
  let contract2: MockSmartWallet; // ADD TEST FOR 0 BALANCES
  let contract3: MockSmartWallet;
  let admin: SignerWithAddress;
  let treasury: SignerWithAddress;
  const maxPenalty = utils.parseEther("1");
  const name = "veFDT";
  const symbol = "veFDT";
  let alice: SignerWithAddress;
  let bob: SignerWithAddress;
  let charlie: SignerWithAddress;
  let david: SignerWithAddress;
  let eve: SignerWithAddress;
  const initialFDTuserBal = utils.parseEther("1000");
  const lockAmount = utils.parseEther("100");
  let tx;
  const MAX = ethers.constants.MaxUint256;
  const ZERO_ADDRESS = ethers.constants.AddressZero;
  const WEEK = 7 * 86400;
  const MAXTIME = 365 * 86400;

  let signers: SignerWithAddress[];

  async function getBlock() {
    return (await ethers.provider.getBlock("latest")).number;
  }
  async function getTimestamp() {
    return (await ethers.provider.getBlock("latest")).timestamp;
  }

  before(async function () {
    await createSnapshot(provider);

    signers = await ethers.getSigners();
    [admin, alice, bob, charlie, david, eve, treasury] = signers;

    // Deploy FDT contract
    const fdtMockDeployer = await ethers.getContractFactory("MockERC20", admin);
    fdtMock = await fdtMockDeployer.deploy("FiatDAO", "FDT", admin.address);

    // mint FDT tokens
    await fdtMock.mint(alice.address, initialFDTuserBal);
    await fdtMock.mint(bob.address, initialFDTuserBal);
    await fdtMock.mint(charlie.address, initialFDTuserBal);
    await fdtMock.mint(david.address, initialFDTuserBal);
    await fdtMock.mint(eve.address, initialFDTuserBal);

    // Deploy VE contract
    const veDeployer = await ethers.getContractFactory(
      "DelegatedVotingEscrow",
      admin
    );
    ve = await veDeployer.deploy(
      admin.address,
      treasury.address,
      fdtMock.address,
      "veFDT",
      "veFDT"
    );

    // Deploy Blocklist
    const blocklistDeployer = await ethers.getContractFactory(
      "Blocklist",
      admin
    );

    blocklist = await blocklistDeployer.deploy(admin.address, ve.address);

    //add Blocklist address to VotingEscrow
    await ve.updateBlocklist(blocklist.address);
    // approve VE contract on FDT
    await fdtMock.setAllowance(alice.address, ve.address, MAX);
    await fdtMock.setAllowance(bob.address, ve.address, MAX);
    await fdtMock.setAllowance(charlie.address, ve.address, MAX);
    await fdtMock.setAllowance(david.address, ve.address, MAX);
    await fdtMock.setAllowance(eve.address, ve.address, MAX);

    // Deploy malicious contracts
    const contractDeployer = await ethers.getContractFactory(
      "MockSmartWallet",
      admin
    );
    contract = await contractDeployer.deploy(fdtMock.address);
    await fdtMock.mint(contract.address, initialFDTuserBal);

    contract2 = await contractDeployer.deploy(fdtMock.address);
    await fdtMock.mint(contract2.address, initialFDTuserBal);

    contract3 = await contractDeployer.deploy(fdtMock.address);
    await fdtMock.mint(contract3.address, initialFDTuserBal);
  });
  after(async () => {
    await restoreSnapshot(provider);
  });

  describe("Deployment", async () => {
    it("Initialized properly", async () => {
      expect(await ve.owner()).to.equal(admin.address);

      expect(await ve.name()).to.equal(name);

      expect(await ve.symbol()).to.equal(symbol);

      expect(await ve.penaltyRecipient()).to.equal(treasury.address);

      expect(await ve.penaltyAccumulated()).to.equal(0);

      expect(await ve.totalSupply()).to.equal(0);

      expect(await ve.maxPenalty()).to.equal(maxPenalty);

      expect(await fdtMock.balanceOf(alice.address)).to.equal(
        initialFDTuserBal
      );

      expect(await fdtMock.balanceOf(bob.address)).to.equal(initialFDTuserBal);
    });
  });

  describe("Blocklist checker", async () => {
    it("Blocklist EOA fails", async () => {
      await createSnapshot(provider);

      expect(await blocklist.isBlocked(alice.address)).to.equal(false);
      expect(await blocklist.isBlocked(bob.address)).to.equal(false);

      tx = blocklist.blockContract(alice.address);
      await expect(tx).to.be.revertedWith("Only contracts");
    });

    it("Blocklist contract succeeds", async () => {
      const lockTime = 4 * WEEK + (await getTimestamp());

      expect(await blocklist.isBlocked(contract.address)).to.equal(false);
      await contract.createLock(ve.address, lockAmount, lockTime);

      await blocklist.blockContract(contract2.address);
      expect(await blocklist.isBlocked(contract2.address)).to.equal(true);
    });

    it("Only owner can blocklist", async () => {
      tx = blocklist.connect(bob).blockContract(contract.address);
      await expect(tx).to.be.revertedWith("Only manager");

      await restoreSnapshot(provider);
    });
  });

  describe("EOA flow", async () => {
    it("Alice and Bob lock FDT in ve", async () => {
      await createSnapshot(provider);
      const lockTime = 4 * WEEK + (await getTimestamp());

      await ve.connect(alice).createLock(lockAmount, lockTime);

      await ve.connect(bob).createLock(lockAmount, lockTime);
    });

    it("Alice and Bob attempt to withdraw before lock end, fail", async () => {
      tx = ve.connect(alice).withdraw();
      await expect(tx).to.be.revertedWith("Lock not expired");

      tx = ve.connect(bob).withdraw();
      await expect(tx).to.be.revertedWith("Lock not expired");
    });

    it("Alice attempts to quit lock, succeeds with penalty", async () => {
      // Increase time to 2 weeks to lock end
      await increaseTimeTo((await ve.lockEnd(alice.address)).sub(WEEK * 2));
      await ve.connect(alice).quitLock();

      // Penalty is ~ 3.84% (2/52*100)
      assertBNClosePercent(
        await fdtMock.balanceOf(alice.address),
        initialFDTuserBal.sub(lockAmount.mul(2).div(MAXTIME)),
        "0.4"
      );
    });

    it("Check accumulated penalty and collect", async () => {
      const lockAmount = utils.parseEther("100");
      expect(await ve.penaltyAccumulated()).gt(0);

      const penaltyAccumulated = await ve.penaltyAccumulated();

      await ve.collectPenalty();

      expect(await ve.penaltyAccumulated()).to.equal(0);

      expect(await fdtMock.balanceOf(treasury.address)).to.equal(
        penaltyAccumulated
      );
    });

    it("Bob increase his unlock time", async () => {
      const lockTime = 10 * WEEK + (await getTimestamp());
      await ve.connect(bob).increaseUnlockTime(lockTime);
    });

    it("Alice locks again after locked expired, succeed", async () => {
      await increaseTime(5 * WEEK);
      const lockTime = 4 * WEEK + (await getTimestamp());
      await ve.connect(alice).createLock(lockAmount, lockTime);
    });

    it("Admin unlocks ve contracts", async () => {
      tx = ve.connect(alice).withdraw();
      await expect(tx).to.be.revertedWith("Lock not expired");

      await ve.unlock();

      expect(await ve.maxPenalty()).to.equal(0);
    });

    it("Alice and Bob attempt to quit lock, succeeds without penalty", async () => {
      await ve.connect(alice).quitLock();
      assertBNClosePercent(
        await fdtMock.balanceOf(alice.address),
        initialFDTuserBal.sub(lockAmount.mul(2).div(MAXTIME)),
        "0.4"
      );

      await ve.connect(bob).quitLock();
      expect(await fdtMock.balanceOf(bob.address)).to.equal(initialFDTuserBal); // because bob did not quit lock previously but deposited twice

      expect(await ve.penaltyAccumulated()).to.equal(0);

      await restoreSnapshot(provider);
    });
  });

  describe("Malicious contracts flow", async () => {
    it("2 contracts lock FDT in ve", async () => {
      await createSnapshot(provider);

      const lockTime = 4 * WEEK + (await getTimestamp());

      // contract 1
      await contract.createLock(ve.address, lockAmount, lockTime);
      expect(await ve.balanceOf(contract.address)).not.eq(0);
      expect(await ve.balanceOfAt(contract.address, await getBlock())).not.eq(
        0
      );

      // contract 2
      await contract2.createLock(ve.address, lockAmount, lockTime);
      expect(await ve.balanceOf(contract2.address)).not.eq(0);
      expect(await ve.balanceOfAt(contract2.address, await getBlock())).not.eq(
        0
      );
    });

    it("Blocklisted contract CANNOT increase amount of tokens", async () => {
      // = await Deployer.deploy(ve.address);
      await blocklist.blockContract(contract.address);
      expect(await fdtMock.balanceOf(contract.address)).to.equal(
        initialFDTuserBal.sub(lockAmount)
      );

      await expect(
        contract.increaseAmount(ve.address, lockAmount)
      ).to.be.revertedWith("Blocked contract");

      expect(await fdtMock.balanceOf(contract.address)).to.equal(
        initialFDTuserBal.sub(lockAmount)
      );
    });

    it("Blocklisted contract CANNOT increase locked time", async () => {
      expect(await fdtMock.balanceOf(contract.address)).to.equal(
        initialFDTuserBal.sub(lockAmount)
      );

      await expect(
        contract.increaseUnlockTime(
          ve.address,
          (await getTimestamp()) + 10 * WEEK
        )
      ).to.be.revertedWith("Blocked contract");

      expect(await fdtMock.balanceOf(contract.address)).to.equal(
        initialFDTuserBal.sub(lockAmount)
      );
    });

    it("Blocklisted contract can quit lock", async () => {
      await increaseTime(ONE_WEEK);
      expect(await fdtMock.balanceOf(contract.address)).to.equal(
        initialFDTuserBal.sub(lockAmount)
      );

      await contract.quitLock(ve.address);

      assertBNClosePercent(
        await fdtMock.balanceOf(contract.address),
        initialFDTuserBal.sub(lockAmount.mul(2 * WEEK).div(MAXTIME)),
        "0.5"
      );
      // expect(await fdtMock.balanceOf(contract.address)).to.equal(
      //   initialFDTuserBal.sub(lockAmount.div(2))
      // );
    });

    it("Admin unlocks ve contracts", async () => {
      await ve.unlock();

      expect(await ve.maxPenalty()).to.equal(0);
    });

    it("Allowed contract can quit lock without penalty", async () => {
      // not blocklisted contract
      await contract2.quitLock(ve.address);
      expect(await fdtMock.balanceOf(contract2.address)).to.equal(
        initialFDTuserBal
      );

      await restoreSnapshot(provider);
    });
  });

  describe("Blocked contracts undelegation", async () => {
    it("2contracts lock FDT in ve", async () => {
      await createSnapshot(provider);

      const lockTime = 4 * WEEK + (await getTimestamp());
      const lockTime2 = 2 * WEEK + (await getTimestamp());
      // contract 1
      await contract.createLock(ve.address, lockAmount, lockTime);
      expect(await ve.balanceOf(contract.address)).not.eq(0);
      expect(await ve.balanceOfAt(contract.address, await getBlock())).not.eq(
        0
      );

      // contract 2
      await contract2.createLock(ve.address, lockAmount, lockTime);
      expect(await ve.balanceOf(contract2.address)).not.eq(0);
      expect(await ve.balanceOfAt(contract2.address, await getBlock())).not.eq(
        0
      );
      // contract 3
      await contract3.createLock(ve.address, lockAmount, lockTime);
      expect(await ve.balanceOf(contract3.address)).not.eq(0);
      expect(await ve.balanceOfAt(contract3.address, await getBlock())).not.eq(
        0
      );
    });

    it("Admin blocklists malicious contracts", async () => {
      // contract 2 delegates first
      await contract2.delegate(ve.address, contract.address);
      await blocklist.blockContract(contract2.address);
    });

    it("Blocked contract gets UNDELEGATED", async () => {
      await contract.delegate(ve.address, contract3.address);
      expect((await ve.locked(contract.address)).delegatee).to.equal(
        contract3.address
      );
      await blocklist.blockContract(contract.address);
      expect((await ve.locked(contract.address)).delegatee).to.equal(
        contract.address
      );
    });

    it("CANNOT delegate to a blocked Contract", async () => {
      // contract 3  cannot delegate to contract
      await expect(
        contract3.delegate(ve.address, contract.address)
      ).to.be.revertedWith("Blocked contract");
      await blocklist.blockContract(contract2.address);
    });

    it("Blocked contract CANNOT delegate to another user", async () => {
      //contract 3 is not blocked
      expect(await blocklist.isBlocked(contract3.address)).to.equal(false);
      // contract 1 is blocked
      await expect(
        contract.delegate(ve.address, contract3.address)
      ).to.be.revertedWith("Blocked contract");
    });

    it("Blocked contract is already undelegated", async () => {
      expect((await ve.locked(contract.address)).delegatee).to.equal(
        contract.address
      );
      // contract 1 is blocked
      await expect(
        contract.delegate(ve.address, contract.address)
      ).to.be.revertedWith("Blocked contract");
    });

    it("Blocklisted contract CANNOT increase amount of tokens", async () => {
      expect(await fdtMock.balanceOf(contract.address)).to.equal(
        initialFDTuserBal.sub(lockAmount)
      );

      await expect(
        contract.increaseAmount(ve.address, lockAmount)
      ).to.be.revertedWith("Blocked contract");

      expect(await fdtMock.balanceOf(contract.address)).to.equal(
        initialFDTuserBal.sub(lockAmount)
      );
    });

    it("Blocklisted contract CANNOT increase locked time", async () => {
      expect(await fdtMock.balanceOf(contract.address)).to.equal(
        initialFDTuserBal.sub(lockAmount)
      );

      await expect(
        contract.increaseUnlockTime(
          ve.address,
          (await getTimestamp()) + 10 * WEEK
        )
      ).to.be.revertedWith("Blocked contract");

      expect(await fdtMock.balanceOf(contract.address)).to.equal(
        initialFDTuserBal.sub(lockAmount)
      );
    });

    it("Blocklisted contract can quit lock", async () => {
      await increaseTime(ONE_WEEK);
      expect(await fdtMock.balanceOf(contract.address)).to.equal(
        initialFDTuserBal.sub(lockAmount)
      );

      await contract.quitLock(ve.address);

      assertBNClosePercent(
        await fdtMock.balanceOf(contract.address),
        initialFDTuserBal.sub(lockAmount.mul(2 * WEEK).div(MAXTIME)),
        "0.5"
      );
    });
    it("Blocked contracts can withdraw", async () => {
      await increaseTime(ONE_WEEK.mul(10));
      // blocked contract can still
      await contract2.withdraw(ve.address);

      await restoreSnapshot(provider);
    });
  });

  describe("Delegation flow", async () => {
    it("Alice creates a lock", async () => {
      await createSnapshot(provider);

      const lockTime = 4 * WEEK + (await getTimestamp());

      await ve.connect(alice).createLock(lockAmount, lockTime);

      const block = await getBlock();
      expect(await ve.balanceOfAt(alice.address, block)).to.above(0);
      expect(await ve.balanceOfAt(bob.address, block)).to.equal(0);
    });

    it("Bob creates a lock, Alice delegates to Bob", async () => {
      const lockTime = 5 * WEEK + (await getTimestamp());

      // pre lock balances
      let block = await getBlock();
      expect(await ve.balanceOfAt(alice.address, block)).to.above(0);
      expect(await ve.balanceOfAt(bob.address, block)).to.equal(0);

      // bob creates lock
      await ve.connect(bob).createLock(lockAmount, lockTime);

      block = await getBlock();
      const preBalance = await ve.balanceOfAt(bob.address, block);
      expect(preBalance).to.above(0);

      // alice delegates
      await ve.connect(alice).delegate(bob.address);

      // post lock balances
      block = await getBlock();
      expect(await ve.balanceOfAt(alice.address, block)).to.equal(0);
      expect(await ve.balanceOfAt(bob.address, block)).to.above(preBalance);
    });

    it("Bob extends his lock beyond Alice's lock, succeeds", async () => {
      const lockTime = 6 * WEEK + (await getTimestamp());

      // pre delegation balances
      let block = await getBlock();
      expect(await ve.balanceOfAt(alice.address, block)).to.equal(0);
      const preBalance = await ve.balanceOfAt(bob.address, block);
      expect(preBalance).to.above(0);

      // Bob extends lock
      await ve.connect(bob).increaseUnlockTime(lockTime);
      block = await getBlock();
      expect(await ve.balanceOfAt(alice.address, block)).to.equal(0);
      expect(await ve.balanceOfAt(bob.address, block)).to.above(preBalance);
    });

    it("Contract creates a lock, Bob delegates to contract", async () => {
      const lockTime = 7 * WEEK + (await getTimestamp());

      // create lock
      await contract.createLock(ve.address, lockAmount, lockTime);
      let block = await getBlock();
      expect(await ve.balanceOfAt(contract.address, block)).to.above(0);

      // delegate to contract
      await ve.connect(bob).delegate(contract.address);
      block = await getBlock();
      expect(await ve.balanceOfAt(alice.address, block)).to.equal(0);
      expect(await ve.balanceOfAt(bob.address, block)).to.above(0);
      expect(await ve.balanceOfAt(contract.address, block)).to.above(0);
    });

    it("Alice re-delegates to contract", async () => {
      let block = await getBlock();
      expect(await ve.balanceOfAt(alice.address, block)).to.equal(0);
      expect(await ve.balanceOfAt(bob.address, block)).to.above(0);

      // re-delegation to contract
      await ve.connect(alice).delegate(contract.address);
      block = await getBlock();
      expect(await ve.balanceOfAt(alice.address, block)).to.equal(0);
      expect(await ve.balanceOfAt(bob.address, block)).to.equal(0);
      expect(await ve.balanceOfAt(contract.address, block)).to.above(0);
    });

    it("Alice extends her lock", async () => {
      const lockTime = 8 * WEEK + (await getTimestamp());
      await ve.connect(alice).increaseUnlockTime(lockTime);

      const block = await getBlock();
      // expect(await ve.lockEnd(alice.address)).to.equal(
      //   Math.trunc(lockTime / WEEK) * WEEK
      // );
    });

    it("Alice's lock ends after Contract's, Alice can delegate back to herself", async () => {
      // pre undelegation
      let block = await getBlock();
      const balance_before_contract = await ve.balanceOfAt(
        contract.address,
        block
      );
      expect(balance_before_contract).to.above(0);

      // undelegate
      await ve.connect(alice).delegate(alice.address);

      // post undelegation
      block = await getBlock();
      expect(await ve.balanceOfAt(alice.address, block)).to.above(0);
      expect(await ve.balanceOfAt(bob.address, block)).to.equal(0);
      expect(await ve.balanceOfAt(contract.address, block)).to.above(0);
    });

    it("Alice's lock is not delegated, Alice can quit", async () => {
      // pre quit
      let block = await getBlock();
      expect(await fdtMock.balanceOf(alice.address)).to.equal(
        initialFDTuserBal.sub(lockAmount)
      );
      expect(await ve.balanceOfAt(alice.address, block)).to.above(0);
      expect(await ve.balanceOfAt(bob.address, block)).to.equal(0);
      expect(await ve.balanceOfAt(contract.address, block)).to.above(0);

      // alice quits
      await ve.connect(alice).quitLock();

      // post quit
      block = await getBlock();

      assertBNClosePercent(
        await fdtMock.balanceOf(alice.address),
        initialFDTuserBal.sub(lockAmount.mul(7 * WEEK).div(MAXTIME)),
        "0.5"
      );
      expect(await ve.balanceOfAt(alice.address, block)).to.equal(0);
      expect(await ve.balanceOfAt(bob.address, block)).to.equal(0);
      expect(await ve.balanceOfAt(contract.address, block)).to.above(0);
    });

    it("Bob's lock is delegated, Bob cannot quit", async () => {
      // pre quit
      let block = await getBlock();
      expect(await fdtMock.balanceOf(bob.address)).to.equal(
        initialFDTuserBal.sub(lockAmount)
      );
      expect(await ve.balanceOfAt(bob.address, block)).to.equal(0);

      // Bob attempts to quit
      tx = ve.connect(bob).quitLock();
      await expect(tx).to.be.revertedWith("Lock delegated");

      // post quit
      block = await getBlock();
      expect(await fdtMock.balanceOf(bob.address)).to.equal(
        initialFDTuserBal.sub(lockAmount)
      );
      expect(await ve.balanceOfAt(bob.address, block)).to.equal(0);
    });

    it("Bob extends lock and undelegates", async () => {
      // pre undelegation
      let block = await getBlock();
      expect(await ve.balanceOfAt(bob.address, block)).to.equal(0);
      const preBalance = await ve.balanceOfAt(contract.address, block);
      expect(preBalance).to.above(0);

      // Bob extends and undelegates
      await ve
        .connect(bob)
        .increaseUnlockTime(7 * WEEK + (await getTimestamp()));
      await ve.connect(bob).delegate(bob.address);

      // post undelegation
      block = await getBlock();
      expect(await ve.balanceOfAt(bob.address, block)).to.above(0);
      const postBalance = await ve.balanceOfAt(contract.address, block);
      expect(postBalance).to.above(0);
      expect(postBalance).to.below(preBalance);
    });

    it("Bob's lock is not delegated, Bob can quit", async () => {
      // pre quit
      let block = await getBlock();
      expect(await fdtMock.balanceOf(bob.address)).to.equal(
        initialFDTuserBal.sub(lockAmount)
      );
      expect(await ve.balanceOfAt(bob.address, block)).to.above(0);

      // alice quits
      await ve.connect(bob).quitLock();

      // post quit
      block = await getBlock();
      assertBNClosePercent(
        await fdtMock.balanceOf(bob.address),
        initialFDTuserBal.sub(lockAmount.mul(6 * WEEK).div(MAXTIME)),
        "0.5"
      );
      expect(await ve.balanceOfAt(bob.address, block)).to.equal(0);
    });

    it("Contract extends lock beyond Bob's lock, ", async () => {
      const lockTimeContract = 30 * WEEK + (await getTimestamp());
      await contract.increaseUnlockTime(ve.address, lockTimeContract);

      await increaseTime(8 * WEEK);
      // pre delegation
      const block = await getBlock();
      assertBNClosePercent(
        await fdtMock.balanceOf(bob.address),
        initialFDTuserBal.sub(lockAmount.mul(7 * WEEK).div(MAXTIME)),
        "0.5"
      );
      expect(await ve.balanceOfAt(bob.address, block)).to.equal(0);
    });

    it("Bob attempts to lock again, succeeds, Bob can delegate to contract", async () => {
      const lockTime = 10 * WEEK + (await getTimestamp());
      // bob creates a new lock
      await ve.connect(bob).createLock(lockAmount, lockTime);

      let block = await getBlock();
      const preBalance = await ve.balanceOfAt(contract.address, block);
      expect(preBalance).to.above(0);

      await ve.connect(bob).delegate(contract.address);

      // post delegation
      block = await getBlock();
      assertBNClosePercent(
        await fdtMock.balanceOf(bob.address),
        initialFDTuserBal
          .sub(lockAmount.mul(7 * WEEK).div(MAXTIME))
          .sub(lockAmount),
        "0.5"
      );
      expect(await ve.balanceOfAt(bob.address, block)).to.equal(0);
      const postBalance = await ve.balanceOfAt(contract.address, block);
      expect(postBalance).to.above(preBalance);
      // const block = await getBlock();
      // expect(await ve.lockEnd(contract.address)).to.equal(
      //   Math.trunc(lockTime / WEEK) * WEEK
      // );
    });

    it("Contract's lock is not delegated, contract can quit and but lose delegated balance", async () => {
      // pre quit
      let block = await getBlock();
      expect(await fdtMock.balanceOf(contract.address)).to.equal(
        initialFDTuserBal.sub(lockAmount)
      );
      const preBalance = await ve.balanceOfAt(contract.address, block);
      expect(preBalance).to.above(0);

      // contract quits
      await contract.quitLock(ve.address);

      // post quit
      block = await getBlock();

      // Contract locked for 30 weeks, then we advanced 8 weeks
      assertBNClosePercent(
        await fdtMock.balanceOf(contract.address),
        initialFDTuserBal.sub(lockAmount.mul(21 * WEEK).div(MAXTIME)),
        "0.5"
      );
      const postBalance = await ve.balanceOfAt(contract.address, block);
      expect(postBalance).to.equal(0);
      expect(postBalance).to.below(preBalance);
      expect(await ve.balanceOfAt(bob.address, block)).to.equal(0);
    });

    it("Bob's lock ends before Contract's, Bob can still delegate back to himself", async () => {
      // pre undelegation
      let block = await getBlock();
      expect(await ve.balanceOfAt(bob.address, block)).to.equal(0);
      expect(await ve.balanceOfAt(contract.address, block)).to.equal(0);

      // undelegate
      await ve.connect(bob).delegate(bob.address);

      // post undelegation
      block = await getBlock();
      expect(await ve.balanceOfAt(bob.address, block)).to.above(0);
      expect(await ve.balanceOfAt(contract.address, block)).to.equal(0);

      await restoreSnapshot(provider);
    });
  });

  describe("Quitlock flow", async () => {
    it("Alice, Bob, Charlie, David and Eve lock FDT in ve", async () => {
      await createSnapshot(provider);
      // MAXTIME => 1 year
      const lockTime1 = MAXTIME + (await getTimestamp());
      const lockTime2 = MAXTIME / 2 + (await getTimestamp());

      // 1 year lock
      await ve.connect(alice).createLock(lockAmount, lockTime1);
      await ve.connect(bob).createLock(lockAmount, lockTime1);
      await ve.connect(charlie).createLock(lockAmount, lockTime1);

      // 6 month lock
      await ve.connect(david).createLock(lockAmount, lockTime2);
      await ve.connect(eve).createLock(lockAmount, lockTime2);
    });

    it("Alice and David quitlocks after ~3 months", async () => {
      await increaseTime(ONE_WEEK.mul(13));
      await ve.connect(alice).quitLock();
      // Alice would have ~39 weeks left
      assertBNClosePercent(
        await fdtMock.balanceOf(alice.address),
        initialFDTuserBal.sub(lockAmount.mul(ONE_WEEK.mul(39)).div(MAXTIME)),
        "0.5"
      );
      // David would have ~13 weeks left
      await ve.connect(david).quitLock();
      assertBNClosePercent(
        await fdtMock.balanceOf(david.address),
        initialFDTuserBal.sub(lockAmount.mul(ONE_WEEK.mul(13)).div(MAXTIME)),
        "0.5"
      );
    });

    it("Bob and Eve quitlocks after ~ 4 months", async () => {
      await increaseTime(ONE_WEEK.mul(4));
      await ve.connect(bob).quitLock();
      // Bob would have ~35 weeks left
      assertBNClosePercent(
        await fdtMock.balanceOf(bob.address),
        initialFDTuserBal.sub(lockAmount.mul(ONE_WEEK.mul(35)).div(MAXTIME)),
        "0.5"
      );
      // David would have ~9 weeks left
      await ve.connect(eve).quitLock();
      assertBNClosePercent(
        await fdtMock.balanceOf(eve.address),
        initialFDTuserBal.sub(lockAmount.mul(ONE_WEEK.mul(9)).div(MAXTIME)),
        "0.5"
      );
    });

    it("Charlie quitlocks after ~ 9 months", async () => {
      await increaseTime(ONE_WEEK.mul(21));
      await ve.connect(charlie).quitLock();
      // Charlie would have ~14 weeks left
      assertBNClosePercent(
        await fdtMock.balanceOf(charlie.address),
        initialFDTuserBal.sub(lockAmount.mul(ONE_WEEK.mul(14)).div(MAXTIME)),
        "0.5"
      );
    });

    it("Alice locks again, then penalty is taken away,she withdraws without penalty", async () => {
      const aliceBalBefore = await fdtMock.balanceOf(alice.address);
      await ve
        .connect(alice)
        .createLock(lockAmount, (await getTimestamp()) + MAXTIME);
      await ve.unlock();
      await ve.connect(alice).quitLock();
      expect(await fdtMock.balanceOf(alice.address)).to.equal(aliceBalBefore);
    });
  });
});
