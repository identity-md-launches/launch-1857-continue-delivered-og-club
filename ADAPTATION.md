# OG Club launch adaptation

The requested scope is delayed furniture-minter grants and recording box rolls
independently of delivery. No deployment, broadcast, dependency, build-configuration
or payment-token change was made. Constructors and the existing five-field
`purchases(uint256)` ABI remain compatible with the supplied factory requirements.

## Revision of 2026-10-15: the two remaining owner-trust gaps

Continuation from the accepted tree at `3cf22eb`, which passed **111 tests**
locally with the verifier seed (the assignment text says 122; the count in the
tree is 111). Both imported findings were reproduced before anything changed:
the two pinned proofs, copied to disposable `test/scratch/`, failed on the
original source exactly as reported (`owner minted the capped piece with no
notice ... 1 != 0`; `second grant took effect immediately with no 7-day notice`;
`re-grant of the revoked box took effect immediately`) and pass on the revised
tree. Every other behaviour is unchanged.

| Files | Change | Requirement / reproduced finding |
| --- | --- | --- |
| `src/OGClubBox.sol` | Fifth constructor argument `seasonNotice_` stored in `uint256 public immutable seasonNotice`; the constructor reverts with `InvalidSeasonNotice(notice, maximum)` above the new `MAX_SEASON_NOTICE` (30 days). `createSeason` reverts with `SeasonOpensTooSoon(opensAt, earliest)` unless `opensAt >= block.timestamp + seasonNotice`, checked right after the existing parameter checks so their errors still surface first. Seasons stay immutable; `closeSeason` and `cancelSeason` are untouched. With a notice of 0 a season may open in the creating block, but a backdated `opensAt` is now refused (it was equivalent to opening at once). | Launch rule 1; audit `aff3932d52a6` (medium), reproduced. |
| `src/OGClubFurniture.sol` | `bool public bootstrapped`. `grantMinter` takes the immediate path only while the flag is clear, and sets it there; every later grant is a `MINTER_DELAY` proposal whatever `totalSupply()` is, including a re-grant of the revoked box. A reverted grant (zero address, non-owner) does not spend the bootstrap. `activateMinter`, `cancelMinter`, `revokeMinter` and `mintBatch` are unchanged. | Launch rule 2; audit `3561810c070a` (medium), reproduced. |
| `script/Deploy.s.sol` | Reads `SEASON_NOTICE` and passes it as the fifth argument; `deploy(token, vault, owner, seasonNotice)`. | Both constructors must still be deployable by the script and the factory. |
| `launch.json` | Fifth `OGClubBox` argument `"0"` (test-network notice); notes rewritten for the one-bootstrap grant rule, the season notice and the new post-deploy order. Keys and note length (under 4,000 characters) unchanged. | Audit `21bbf96efece` (info): the manifest and notes went stale with the fixes; the assignment asks for the update explicitly. |
| `test/SeasonNotice.t.sol` (new) | Box with a seven-day notice: revert one second short of the notice and at `opensAt = 0`, success at exactly `now + notice`, a fuzzed boundary at arbitrary creation times, other parameter errors still first, the audit scenario (the owner cannot create an instant 1-wei season with a near-certain capped piece, cannot buy from the announced one before its notice, and holds nothing until it opens), close and cancel as before, immutable terms. | Tests requested for rule 1. |
| `test/Deployment.t.sol` | Constructor and script calls pass the notice; new test: 30 days accepted, 30 days + 1 and `uint256.max` refused through the constructor and the script, `seasonNotice()` readable, no setter. | Constructor bound, script and immutability. |
| `test/Seasons.t.sol` | `test_CreateValidation` uses `opensAt = 1000` (the current timestamp) instead of a past `opensAt`, so each call still hits the error it was written for. New `test_ZeroNoticeSeasonOpensAtOnce`: with notice 0 a season opening in the creating block sells and opens as before, and only a past `opensAt` is refused. `test_BuyRequiresTheBoxToBeAnAuthorizedMinter` now re-grants through the seven-day proposal and buys from a fresh season after it. | Rule 1 with notice 0 "behaves as today"; rule 2. |
| `test/EdgeCases.t.sol` | The fuzzed round-trip bounds `opensAt` at or after the current timestamp. | Rule 1. |
| `test/OGClubFurniture.t.sol` | `test_FreshGrantsAreImmediateAndEmitTheFullMinterList` (several immediate grants) replaced by `test_OnlyTheFirstGrantIsImmediateEvenBeforeAnyMint`. New: a rejected grant does not spend the bootstrap; re-granting the revoked first minter waits with zero supply, through cancel and re-proposal; fuzz: every grant after the first waits seven days whatever the addresses and elapsed time. | Tests requested for rule 2. |
| `test/DeliveryEdges.t.sol`, `test/Delivery.t.sol`, `test/helpers/BoxTestBase.sol` | `test_ImmediateGrantStaysOpenWhileOnlyUndeliveredRollsExist` (old rule) replaced by `test_SecondGrantWaitsEvenWhileOnlyUndeliveredRollsExist`: sales started, a roll stored, `totalSupply() == 0`, a new minter and the box both wait seven days, and the stored roll delivers after activation. `test_ZeroAmountMintsLeaveSupplyZeroAndGrantsImmediate` became `...ButGrantsStillWait`. Every re-grant of the revoked box in these files goes through the new `regrantBox()` helper, which asserts the proposal, warps seven days and activates. `deployBox(token)` gives the payment-token tests a second box over its own furniture, since a second box on the shared furniture would no longer be immediate. | Rule 2: re-granting a revoked box waits, opens during the delay store their rolls. |
| `test/MinterLifecycleInvariant.t.sol` | The handler's `grant` no longer branches on supply: it asserts `bootstrapped()` and treats every grant as a proposal; `immediateGrants` became `grantsAfterBootstrap`. Seeding proposes candidate A before any delivery (previously an immediate grant) and activates it after the seven-day warp. The invariant asserts the flag stays set. | Rule 2 in the stateful suite. |
| `test/Payments.t.sol`, `test/MultiActorInvariant.t.sol` | Pass the fifth constructor argument (0). | Constructor change. |
| `README.md` | Owner powers: the season-notice rule (replacing the per-season trust assumption) and the one-bootstrap grant rule; constructor table, script variables, local-check seed; post-deploy steps: grant the box first, create each season at least `seasonNotice` before it opens. | Requested README changes. |

Results on the revised tree with the verifier seed
`0xd7cbf984d9643a3a39694e4c2b43fdd2684bdc6f7f33900f61d9d2eb94626e58`:
**123 permanent tests passed, zero failed or skipped** (126 with the two proofs
in disposable `test/scratch/`). `forge build` and `forge fmt --check` pass. The
protected factory and owner probes were read; they need verifier-generated
inputs and were not executed here. No deployment was performed.

## Changes and reasons

| Files | Change | Requirement / reproduced finding |
| --- | --- | --- |
| `src/OGClubFurniture.sol` | Replaced `setMinter` with owner-only `grantMinter`, `cancelMinter`, `revokeMinter`, and permissionless `activateMinter`. Grants are immediate only at zero total supply; otherwise activation requires seven days. Added `pendingMinters`, proposal/cancellation events, and explicit missing/early proposal errors. Immediate grants and activations both emit `MinterSet`. Revoke clears proposals immediately. Re-proposing restarts the delay; cancellation leaves an already-active permission intact. | Requested change 1; audit `c74ac643813b`. Prevent immediate authorization of new arbitrary minting after the collection exists. |
| `src/OGClubBox.sol` | `open` reserves caps and records `BoxOpened` before attempting delivery in `try/catch`. Successful minting sets delivery status and emits `Delivered`; failure stores ordered IDs and emits `DeliveryFailed`. Added permissionless `deliver`, buyer-only `deliverTo`, `delivered` and `getStoredItems`. Retry effects precede minting and roll back on failure. Successful retries clear stored IDs. All four purchase/delivery entry points share the reentrancy guard. | Requested change 2; audits `e0a50d6e49b9`, `460e31d87310`, `5926736c3fa8`. Preserve a recorded roll through revocation, receiver rejection, cap depletion and expiry, and allow a non-receiver buyer to redirect it. |
| `src/OGClubBox.sol` | Delivery status shares the existing `opened` storage slot. The purchase getter keeps its old return values. Only failed initial deliveries allocate stored ID arrays. The initial mint always receives exactly the named `OPEN_MINT_GAS_LIMIT` of 1,000,000; the box keeps the now-public `DELIVERY_RESERVE_GAS` of 300,000 for up to ten cold ID slots, the array length and failure-path overhead. Retries have no fixed gas cap. | Requested normal-path storage constraint; the gas-exhaustion warning in audit `5926736c3fa8`. A receiver must not exhaust the caller's ability to save its roll. |
| `src/OGClubBox.sol` (revision) | `open` reverts with `InsufficientGas(required, available)` when fewer than `OPEN_DELIVERY_GAS` (mint budget plus reserve, 1,300,000) gas remain at the delivery step. The revert undoes the whole call, so a short caller changes nothing. Previously the mint was given `min(limit, gasleft - reserve)` and a starved mint was caught as a delivery failure. | Review finding `a01cf2893652`: with the old forwarding rule, `eth_estimateGas` and any opener attaching roughly 1.0-1.5x the measured gas landed a healthy EOA buyer on the `DeliveryFailed` path, writing the stored-items array the brief says the normal path must never add and letting a stranger choose the buyer's path. A short gas limit is now a caller precondition, so "open must not revert because of delivery" still holds and every succeeding open forwards the full mint budget. |
| `test/OpenGas.t.sol`, `test/Delivery.t.sol` | New tests: the measured gas, 1.5x of it and 600,000 all revert with `InsufficientGas` and leave the purchase untouched; the lowest succeeding gas limit (an estimate) delivers and stores nothing for every count; at that exact boundary a receiver that burns the whole mint budget or returns a huge revert payload still gets its ten distinct IDs stored; the published constants are consistent. The hostile-receiver test no longer hard-codes a 1.2M limit, which the new precondition rejects for a 32-entry ten-pack. | Review finding `a01cf2893652`; its supplied proof passes on the revised tree. |
| `test/OGClubFurniture.t.sol`, `test/FurnitureInvariant.t.sol` | Test initial grants/events, exact seven-day boundary, early and missing activation, arbitrary activators, cancellation, immediate revoke, proposal deletion/replacement, role access and removal of the old selector. Keep ownership, transfer, metadata and royalty checks. | Requested furniture tests and audit `c74ac643813b`. |
| `test/Opening.t.sol`, `test/EdgeCases.t.sol`, `test/FixedOdds.t.sol`, `test/Delivery.t.sol`, `test/helpers/Adversaries.sol` | Replace old rollback expectations with recorded-roll and retry expectations. Cover revoked minter through reveal expiry and delayed restoration, non-receiver redirection, first-attempt-only rejection, retry failure/atomicity, single/batch callback reentrancy, at-most-once delivery, undelivered cap reservation, capped-piece owner mint attempts, zero/duplicate IDs, unopened expiry and receivers that exhaust gas or return large revert data. | All requested box tests and audits `e0a50d6e49b9`, `460e31d87310`, `c74ac643813b`, `5926736c3fa8`, `b2396477958b`. |
| `test/BoxInvariant.t.sol`, `test/MultiActorInvariant.t.sol`, `test/helpers/BoxTestBase.sol` | Check reserved per-item counts equal delivered supply plus stored undelivered IDs. Stateful actions reject, retry and redirect deliveries, verify immutable recorded-roll hashes, and count successful deliveries independently. Retain cap, payment-conservation, zero box-token balance and one-time opening checks. Successful normal opens must be delivered with no stored items. | Requested invariants; audit `b2396477958b`. |
| Other affected test fixtures (`test/Payments.t.sol`, `test/Seasons.t.sol`, shared setup and invariant setup) | Replace old minter API calls with grants/revokes. Their existing payment, season, selection and ownership expectations remain intact. | API migration required by requested change 1. |
| `README.md` | Document opening versus delivery, all new views/events and role operations, notice-period limitations, gas limits, preserved expiry, permissionless retries, buyer redirection, and `grantMinter(box)` immediately after deployment before any mint. Correct the overly broad claim that every pending ten-pack can only get worse: its existing guaranteed-tenth-pick rule remains state-dependent until opening. Revision: document the `InsufficientGas` precondition, the published gas constants and measured minimum limits, that `totalSupply()` counts delivered furniture only so undelivered rolls do not arm the minter delay, and that a new season may reuse a previously capped piece ID as a per-season trust assumption on the box owner. | Requested README changes; audits `5926736c3fa8` and `b59f42caf97d`; review findings `a01cf2893652`, `3657507a218b`, `c4bb910a089f`. |

## Imported audit reproduction

The unchanged tree passed **81 tests**, not the 89 mentioned in the assignment,
with the supplied verifier seed. Before changing production code, the three pinned
proofs were copied to disposable `test/scratch/` and executed:

- `e0a50d6e49b9`: reproduced. The revoked-minter proof failed with
  `honest roll was lost: 0 != 3`. The same proof now passes; permanent tests also
  exercise restoration after existing supply triggers the seven-day delay.
- `460e31d87310`: reproduced. The non-receiver proof failed because `open` reverted
  and the paid roll was unrecoverable. The same proof now passes; permanent tests
  verify failed retries and buyer-only redirection after expiry.
- `c74ac643813b`: reproduced. The owner proof failed because it minted a capped
  piece past its cap without delay. The same proof now passes, supplemented by a
  real box cap and activation-boundary tests.
- `5926736c3fa8`: reproduced independently using a rejecting ten-pack buyer whose
  tenth selection was a cap-one Rare. Rejecting the first opening, opening a
  competing purchase, then accepting upgraded the tenth piece to Epic/Legendary.
  The permanent regression now reserves the Rare on the first opening, leaves the
  competing pick with fallback, and delivers exactly the original ten IDs.
  Gas-exhaustion and large-revert-data tests cover the reported catch-path concern.
- `b2396477958b`: confirmed by baseline test execution and inspection: the existing
  suite treated non-receiver loss and delivery rollback as expected. Those tests
  and supply invariants have been updated, with the missing recovery scenarios added.
- `b59f42caf97d`: confirmed as configuration/trust information, not a defect. The
  deployment tests show the box initially lacks mint permission, buys reject it,
  and any account can mint `MockOG`. The constructors already use explicit owner
  arguments and do not call dependencies. The explicit task retains post-deploy
  authorization and the existing Sepolia mock. No constructor redesign or new token
  was needed. `MockOG` remains testnet-only and carries no scarcity guarantee.

## Revision after independent review

- `a01cf2893652` (medium): reproduced. The supplied proof failed on the accepted
  tree with "open succeeded with 1.5x the measured gas but silently took the
  DeliveryFailed path". Fixed as described above; the proof and the new
  `test/OpenGas.t.sol` pass. The check sits at the delivery step rather than at
  the top of `open` so that it is exact for every season size: a fixed top-level
  constant would have to over-approximate the roll's cost (about 235k gas for a
  three-entry ten-pack, about 940k for a 32-entry ten-pack). A revert at that
  point undoes every effect of the call, so nothing is recorded for a short caller.
- `c4bb910a089f` (low, advisory): the behaviour reproduces but is the project's
  documented per-season cap design, which the brief asks to keep unchanged, and
  the requested guarantee is about `grantMinter` on the furniture, which the
  permanent test covers. Closing it would need a scope decision (a season-creation
  notice period, rejecting reused capped IDs, or collection-level caps). Not
  changed; documented in the README as a trust assumption on the box owner.
- `3657507a218b` (low, advisory): the behaviour reproduces and is the brief's
  literal condition ("while nothing has ever been minted, `totalSupply() == 0`").
  Arming the delay on the first grant or on any active minter would change that
  stated rule and make a corrective second grant before the first mint wait seven
  days. Not changed; the README now states that supply counts delivered furniture
  only and that undelivered rolls do not arm the delay.
- `7a9836e0aa3f` (info, advisory): pre-existing ten-pack re-roll behaviour the
  brief asks to keep, already documented in the README as state-dependent. Not
  changed.

No reported application finding was left unreproduced. The delay is a notice
period, not a global furniture cap: existing minters, initially granted minters,
and newly activated minters retain the requested unrestricted mint interface.
Recorded delivery can remain pending if mint permission is never restored or the
buyer cannot receive and cannot call `deliverTo`. An unopened purchase still
expires to fallback after the original 256-block window.

The existing `launch.json` was not edited: manifest preparation belongs to the
subsequent step. Its legacy post-deploy note should use the README's new
`grantMinter(box)` instructions. No signer or deployment input is needed to build
or test this change.

## Validation

- `forge build` using the repository's unchanged Foundry configuration.
- `FOUNDRY_FUZZ_SEED=0x5fbefb26c0c2c1788540f6d50945b685a8eec10a4788d431c33daee28f75b7c5 forge test`.
- `forge fmt --check` after formatting.
- The three supplied proofs also pass locally in disposable `test/scratch/`;
  delivered regressions live in the permanent test files listed above.
- Local deployment tests exercise explicit constructor owners, absent dependencies,
  runtime size/opcode restrictions, and initial authorization requirements. The
  supplied protected deployment/ownership tests were read; their factory harness
  needs verifier-generated deployment inputs and was not executed here.

Final results after the revision: **99 permanent tests passed, zero failed or
skipped**, using the supplied verifier seed, excluding disposable `test/scratch/`.
With the review proof for `a01cf2893652` copied there, **101 tests** passed; the
three earlier audit proofs passed before the first submission. `forge build`,
`forge fmt --check` and `git diff --check` passed. Runtime sizes are 11,811 bytes
for OGClubBox, 8,949 for OGClubFurniture and 1,851 for MockOG, below EIP-170.
Foundry's nonfatal lint messages include timestamp comparisons and post-call
status/events; the seven-day timestamp rule and guarded delivery transitions
are intentional and covered by boundary/reentrancy tests.

No Slither, Mythril, external-chain simulation or deployment was performed.
