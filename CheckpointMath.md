# veFDT Checkpoint Math

## Definitions

owner:=locked[msg.sender]
delegatee:=locked[owner.delegatee]

## Lock operations

### Create Lock

Action details:

| Action | require | update | checkpoint |
| --- | --- | --- | --- |
| createLock<br>V:=value<br>T:=unlockTime | V>0<br>owner.amount==0<br>T>owner.end<br>T>block.t<br>T≤block.t+MAXTIME | owner.amount=V<br>owner.end=T<br>owner.delegated+=V<br>owner.delegatee=msg.sender | msg.sender |

Checkpoint details:

| Lock | amount | end |
| --- | --- | --- |
| old | 0 | 0 |
| new | owner.delegated+V | T |

Notes:

- assertion T>owner.end is required due to potential lock quitters (can only relock with longer lock)
- owner.delegated may be non-zero because of delegated voting power
- oldLock.end checkpoint input is set to 0 (would be non-zero for quitted locks) in order to not mess with checkpoint math (technically, it shouldn’t be a problem if and only if _oldLocked.end < block.timestamp < _newLocked.end but we want to be safe here)
- oldLock.delegated checkpoint input is set to 0 (would be non-zero if delegations received) in order to not mess with checkpoint math (technically, it shouldn’t be a problem because user slope and bias are only non-zero if both oldLock.end>block.timestamp & oldLock.delegated>0)
- Voting power of delegators is instantiated again if delegator recreates lock

### increaseAmount

Action details:

| Action | require | update | checkpoint |
| --- | --- | --- | --- |
| increaseAmount<br>V:=value | V>0<br>owner.amount>0<br>owner.end>block.t<br>delegatee.amount>0<br>delegatee.end>block.t | owner.amount+=V<br>delegatee.delegated+=V | owner.delegatee |

Checkpoint details:

| Lock | amount | end |
| --- | --- | --- |
| old | delegatee.amount | delegatee.end |
| new | delegatee.amount+V | delegatee.end |

Notes:

- delegatee.amount>0 & delegatee.end>block.t ensures that owner undelegates first, if delegatee has no active lock in place

### increaseUnlockTime

Action details:

| Action | require | update | checkpoint |
| --- | --- | --- | --- |
| increaseUnlockTime<br>T:=unlockTime | owner.amount>0<br>if(owner.delegatee==msg.sender)owner.end>block.t<br>T>owner.end<br>T≤block.t+MAXTIME | owner.end=T | if(owner.delegatee==msg.sender) msg.sender |

Checkpoint details:

| Lock | amount | end |
| --- | --- | --- |
| old | owner.delegated | owner.end |
| new | owner.delegated | T |

Notes:

- No checkpoint if lock is delegated because delegatee’s lock governs voting power
- If lock delegated, unlockTime can be increased even if lock is expired as no checkpoint is created

### withdraw

Action details:

| Action | require | update | checkpoint |
| --- | --- | --- | --- |
| withdraw | owner.delegatee==msg.sender<br>owner.amount>0<br>owner.end≤block.t| owner.amount=0<br>owner.end=0<br>owner.delegated-=owner.amount<br>owner.delegatee=address(0) | msg.sender |

Checkpoint details:

| Lock | amount | end |
| --- | --- | --- |
| old | owner.delegated | owner.end |
| new | 0 | 0 |

Notes:

- Can only withdraw if self-delegated
- delegators can undelegate post-withdraw (requires longer lock than delegatee)
- owner.delegated is reduced by owner.amount and NOT reset to 0 so that undelegation of potential delegators doesn’t result in underflow or reduce owners voting power if the lock is recreated after a withdrawal with delegations
- newLock.delegated checkpoint input is set to 0 (would be non-zero if delegations received) in order to not mess with checkpoint math (technically, it shouldn’t be a problem because user slope and bias are only non-zero if both newLock.end>block.timestamp & newLock.delegated>0)
- Because of previous point, voting power of delegators is effectively voided if a delegatee’s lock expires

### quitLock

Action details:

| Action | require | update | checkpoint |
| --- | --- | --- | --- |
| quitLock | owner.amount>0<br>owner.end>block.t<br>owner.delegatee==msg.sender | owner.amount=0<br>owner.delegated-=owner.amount<br>owner.delegatee=address(0) | msg.sender |

Checkpoint details:

| Lock | amount | end |
| --- | --- | --- |
| old | owner.delegated | owner.end |
| new | 0 | 0 |

Notes: 

- Can only withdraw if self-delegated
- delegators can undelegate post-withdraw (requires longer lock than delegatee)
- owner.end>block.t is for UX only
- owner.end is not updated in a quitLock action as the lock may be inherited by delegators
- owner.delegated is reduced by owner.amount and NOT reset to 0 so that undelegation of potential delegators doesn’t result in underflow or reduce owners voting power if the lock is recreated after a quitLock with delegations
- newLock.end checkpoint input is set to 0 because checkpoint math is messed up otherwise (newSlopeDelta = oldSlopeDelta)
- newLock.delegated checkpoint input is set to 0 (would be non-zero if delegations received) in order to not mess with checkpoint math (technically, it shouldn’t be a problem because user slope and bias are only non-zero if both newLock.end>block.timestamp & newLock.delegated>0)
- Because of previous point, voting power of delegators is effectively voided if a delegatee’s lock expires

### Delegate

Definitions:

- from = locked[owner.delegatee]
- to = locked[D]

Action details:

| Action | require | update | checkpoint |
| --- | --- | --- | --- |
| delegate<br>D:=new delegatee | owner.amount>0<br>owner.delegatee≠D<br>to.amount>0<br>to.end>block.t<br>to.end > from.end | owner.delegatee=D<br>from.delegated-=owner.amount<br>to.delegated+=owner.amount | if(from.amount>0) { from }<br>D


Checkpoint details:

| Lock | amount | end |
| --- | --- | --- |
| from |  |  |
| old | from.delegated | from.end |
| new | from.delegated-owner.amount | from.end |
| to |  |  |
| old | to.delegated | to.end |
| new | to.delegated+owner.amount | to.end |

Notes:

- Can only delegate an existing lock, i.e. owner.amount>0
- Can only delegate to an existing, active lock, i.e. to.amount>0 & to.end>block.t
- Can only delegate to a longer lock, i.e. to.end>from.end
- Checkpoint for old delegatee only needed if lock still exists (has not been withdrawn/quitted), i.e. from.amount>0
- New delegatee checkpoint is mathematically equivalent to increaseAmount checkpoint
- Old delegatee checkpoint math is untested in Curve’s implementation as 0 < new.amount < old.amount (in Curve only 0=new.amount < old.amount is used in a withdraw checkpoint). However, Curve’s checkpoint math can handle this because userOldPoint and userNewPoint slope and bias are simply computed based on old.amount and new.amount and voting power decay is linear.
