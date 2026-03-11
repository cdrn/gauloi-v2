# Dispute Resolution: The Collusion Gap and Proposed Fix

## What works today

The **detection** side of dispute resolution is sound. It implements the single honest challenger model — the same security assumption as optimistic rollups.

When a maker submits fill evidence, settlement is blocked for the duration of the dispute window. During that window, any staked maker can verify the fill (a single RPC call to the destination chain) and submit a dispute if the fill is fake. The economics reinforce this: disputing a fraudulent fill is profitable (challenger gets their bond back + 25% of the maker's entire slashed stake), verification is essentially free (one RPC call), and the bond to raise a dispute is low (0.5% of fill, min 25 USDC).

You only need one honest maker watching the network to catch any fraudulent fill. This is enforced on-chain:
- `settle()` reverts until the dispute window has passed
- `dispute()` is open to any active staked maker (except the fill's maker)
- The challenger reward makes honest disputing +EV

This works. No changes needed.

## What's broken

The **resolution** side has a collusion vulnerability. When a dispute is raised, staked makers sign EIP-712 attestations (`FillAttestation`) saying whether the fill was valid or not. `resolveDispute()` accepts these signatures and resolves the dispute based on the `fillValid` boolean.

The problem is threefold:

### 1. No attestor accountability

`resolveDispute()` recovers signer addresses and checks they're active makers who aren't conflicted (not the disputed maker, not the challenger). But it doesn't record who attested or which way they voted. There is no mechanism to penalise an attestor who signed incorrectly. A maker who attests `fillValid = true` for a fraudulent fill faces zero on-chain consequences.

### 2. First-past-the-post resolution

`resolveDispute()` takes a `fillValid` boolean and signatures all attesting to that specific outcome. The first call that meets the signature threshold wins. After that, `disp.resolved = true` and no further submissions are accepted.

This means if a colluding maker submits `resolveDispute(intentId, true, [colluder_sig])` before an honest maker submits `resolveDispute(intentId, false, [honest_sig])`, the fraud succeeds. It's a race, not a consensus.

### 3. The attestor set IS the set of potential colluders

Unlike Across (which escalates to UMA tokenholders — an economically independent group), Gauloi's attestors are the same staked makers who do fills. A maker who wants to commit fraud can pre-arrange with another maker to attest `fillValid = true` in exchange for splitting the proceeds. The attestor has nothing to lose — no bond, no slashing risk, no record of their attestation.

### Concrete attack scenario

With `requiredSignatures = 1` (current v0.1):

1. Maker A submits a fraudulent fill (never actually sent tokens on chain B)
2. Someone honest disputes it
3. Maker B (colluding with A) immediately calls `resolveDispute(intentId, true, [B_signature])`
4. Dispute resolved as "fill valid" — Maker A keeps the escrowed funds + 50% of challenger's bond
5. Maker B faces no penalty
6. They split the stolen funds off-chain

With `requiredSignatures = 2/3 of N` (production target):

The attack requires a majority of staked makers to collude. Harder, but still no on-chain penalty for colluders. An honest minority can see the fraud (the fill tx verifiably doesn't exist on chain B) but can't do anything after resolution.

## The fix: detection→resolution applied twice

The core insight: the single honest challenger model works for detection. We should apply it to resolution as well, not just fill monitoring.

The current flow is:

```
Fill submitted
  → Dispute window (detection: single honest challenger ✓)
    → Attestation (resolution: majority trust, no accountability ✗)
      → Final
```

The proposed flow adds a second detection layer after resolution:

```
Fill submitted
  → Dispute window (detection: single honest challenger ✓)
    → Attestation (resolution: majority of attestors sign)
      → Resolution challenge window (detection: single honest challenger ✓)
        → Objective evidence (the fill exists on chain B, or it doesn't)
          → Final
```

### How the second layer works

After `resolveDispute()` is called, the outcome is not immediately final. A challenge window opens (e.g., 24 hours). During this window, anyone can call `challengeResolution(intentId)` if they believe the resolution was wrong.

The key difference from the first layer: the second-layer resolution doesn't need another round of attestation. It resolves to **objective truth**. A stablecoin fill either exists on chain B or it doesn't. The challenger provides evidence (the fill tx hash, the destination chain state), and the system verifies it.

For v0.1 multi-maker, this verification can still be off-chain — a second round of attestation where wrong first-round attestors are now slashable. The important thing is that first-round attestors have skin in the game.

For later versions, this verification can be made fully objective via storage proofs or native rollup bridge messaging, eliminating human judgment entirely.

### What changes in the contracts

**New state in `GauloiDisputes`:**

```solidity
// Track who attested and which way
mapping(bytes32 => address[]) public disputeAttestors;
mapping(bytes32 => bool[]) public attestorVotes;

// Resolution challenge tracking
mapping(bytes32 => uint256) public resolutionChallengeDeadline;
mapping(bytes32 => bool) public resolutionChallenged;
```

**New state transition:**

```
Disputed → Resolved → (challenge window) → Final
                    → ResolutionChallenged → FinallyResolved
```

Currently: `Disputed → Resolved` (immediate, no recourse).

**Modified `resolveDispute()`:**

```solidity
function resolveDispute(bytes32 intentId, bool fillValid, bytes[] calldata signatures) external {
    // ... existing signature verification ...

    // NEW: Record who attested and which way
    for (uint256 i = 0; i < validCount; i++) {
        disputeAttestors[intentId].push(signers[i]);
        attestorVotes[intentId].push(fillValid);
    }

    disp.resolved = true;
    disp.fillDeemedValid = fillValid;

    // NEW: Don't execute resolution immediately — start challenge window
    resolutionChallengeDeadline[intentId] = block.timestamp + RESOLUTION_CHALLENGE_WINDOW;

    emit DisputeResolved(intentId, fillValid);
}
```

**New `challengeResolution()`:**

```solidity
function challengeResolution(bytes32 intentId) external {
    require(resolutionChallengeDeadline[intentId] > 0, "no resolution to challenge");
    require(block.timestamp <= resolutionChallengeDeadline[intentId], "challenge window closed");
    require(!resolutionChallenged[intentId], "already challenged");

    // Challenger posts a bond (same as dispute bond)
    uint256 bond = calculateDisputeBond(...);
    bondToken.safeTransferFrom(msg.sender, address(this), bond);

    resolutionChallenged[intentId] = true;

    emit ResolutionChallenged(intentId, msg.sender);
}
```

**New `finalizeResolution()`:**

```solidity
function finalizeResolution(bytes32 intentId) external {
    // If challenge window passed without challenge, execute the original resolution
    require(block.timestamp > resolutionChallengeDeadline[intentId], "window still open");

    if (!resolutionChallenged[intentId]) {
        // No challenge — original resolution stands, execute it
        _executeResolution(intentId);
    }
    // If challenged, resolution must go through second-layer verification
}
```

**New: resolve the challenge (second layer):**

```solidity
function resolveChallenge(
    bytes32 intentId,
    bool originalResolutionCorrect,
    bytes[] calldata signatures
) external {
    require(resolutionChallenged[intentId], "not challenged");

    // Verify signatures (same threshold, same rules)
    // ...

    if (!originalResolutionCorrect) {
        // Original resolution was wrong — reverse it
        // Slash all attestors who signed for the wrong outcome
        for (uint256 i = 0; i < disputeAttestors[intentId].length; i++) {
            staking.slash(disputeAttestors[intentId][i], intentId);
        }
        // Execute the opposite resolution
        _executeOppositeResolution(intentId);
    } else {
        // Challenge was frivolous — slash the resolution challenger's bond
        _executeResolution(intentId);
    }
}
```

### Why this fixes the collusion problem

1. **Attestors now have skin in the game.** If they sign `fillValid = true` for a fraudulent fill, they risk their entire stake being slashed when someone challenges the resolution.

2. **The single honest challenger model applies to resolution.** Just like the first layer: you only need one honest party to notice the resolution was wrong and challenge it. The evidence is objective — the fill tx either exists on chain B or it doesn't.

3. **Collusion becomes -EV.** Two makers colluding: Maker A commits fraud ($10k fill), Maker B attests. If challenged, Maker B loses their entire stake ($10k). The colluders need to split $10k of stolen funds but risk $20k in combined stake. That's -EV even with generous assumptions about not getting caught.

4. **First-past-the-post is defused.** It doesn't matter who submits `resolveDispute` first — the challenge window gives honest parties time to review the resolution and contest it.

## Comparison with alternatives

| Approach | Trust assumption | Dependency | Complexity |
|---|---|---|---|
| Current (no accountability) | Majority of attestors honest | None | Low |
| This proposal (escalation) | Single honest challenger | None | Medium |
| UMA (Across model) | Majority of UMA tokenholders | UMA token, 48-96h votes | Medium |
| LayerZero lzRead | DVNs read state correctly | LayerZero infra | Medium |
| Native rollup bridge | Rollup fraud proofs | 7-day finality | High |
| Storage proofs | Math only | Proof libraries | High |

This proposal is the only option that achieves single-honest-challenger security for resolution without introducing an external dependency. It adds complexity (second challenge window, attestor tracking, slashing) but stays entirely within the existing contract architecture.

## Tradeoffs

**Latency.** Resolution now takes longer: attestation + challenge window + potential second round. With a 24h challenge window, worst case is ~48h from dispute to final resolution (24h attestation deadline + 24h challenge window). Compared to the current 24h max, this doubles the potential lockup time.

**Gas.** Recording attestors costs more storage. Challenging and resolving the challenge adds transactions. Marginal — disputes should be rare.

**Complexity.** More state transitions, more edge cases. But the state machine is still linear (no branching paths), and each step is simple.

**The 24h default.** `finalizeExpiredDispute` currently defaults to fill-valid after 24h with no resolution. This still works as a backstop — if nobody attests within 24h, the fill is deemed valid. The challenge window only applies when someone does attest.

## Implementation phases

**Phase 1 (multi-maker launch):** Add attestor recording to `resolveDispute()`. Add the challenge window. Resolution challenges re-use the existing attestation mechanism (second round of maker signatures, with first-round attestors excluded). This gives economic deterrence via attestor slashing.

**Phase 2 (hardening):** Make resolution challenge evidence objective. Instead of a second round of attestation, accept a proof that the fill tx does/doesn't exist on chain B. This could be a storage proof, a native bridge message, or even a simple oracle read. Eliminates human judgment from the final resolution.

**Phase 3 (endgame):** Fully trustless resolution via on-chain state verification. Storage proofs against rollup state roots posted to L1. No oracles, no attestors, no third parties. Math only.
