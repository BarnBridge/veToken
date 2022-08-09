# veFDT
A solidity implementation of Curve's voting-escrow with additional features outlined below.

**Lock delegation**
Users may delegate ther lock to another user whereby they give the delegatee control over their lock expiration and balance (i.e. voting power). Both users, the delegator and the delegatee, need to have an active lock in place at the time of delegation. Moreover, the delegatee's lock expiration needs to be longer than the delegator's.

**Lock quitting**
A non-expired lock may be quitted by the lock owner anytime. The lock cannot be delegated at the time of quitting and the quitter pays a penalty proportional to the remaining lock duration.

**Optimistic SmartWallet approval**
*SmartWallets* (i.e. contracts) can create a lock without being approved first. However, the veFDT owner maintains a Blocklist where SmartWallets may be blocked from further interacting with the system. The Blocklist only allows the owner to block contracts but not EOAs. Blocked SmartWallets may still undelegate (if delegated prior to the blocking) and quit their lock (by paying the penalty) or withdraw once the lock expired.

# 🏄 Quickstart

```bash
npm install
```
```bash
npm run build
```
```bash
npm run test
```

**Note:** We use hardhat and Alchemy web3 provider in order to test against Ethereum mainnet state. Make sure to configure an Alchemy API endpoint with a valid key before running the `test` script:

```bash
export ALCHEMY_MAINNET_API_KEY=[ALCHEMY_KEY]
```

# Voting-escrow math
The veFDT contract implements the same checkpoint mathematics than the original Curve VotingEscrow.vy contract. The new features leverage this math in order to void or redirect (i.e. delegate) a lock's virtual balance. More details about how the various lock operations interact with Curve's checkpoint math can be found [here](./CheckpointMath.md).

# Source
- Curve Finance: Original concept and implementation in Vyper [Source](https://github.com/curvefi/curve-dao-contracts/blob/master/contracts/VotingEscrow.vy)
- mStable: Forking Curve's Vyper contract and porting to Solidity including math tests [Source](https://github.com/mstable/mStable-contracts/blob/master/contracts/governance/IncentivisedVotingLockup.sol)    
