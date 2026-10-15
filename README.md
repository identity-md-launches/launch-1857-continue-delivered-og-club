# OG Club furniture and boxes

This is a Foundry project for two non-upgradeable application contracts. It does
not deploy anything as part of a build or test. Solidity is pinned to 0.8.26, the
source accepts ^0.8.24, and OpenZeppelin Contracts 5.0.2 and forge-std 1.9.7 are
vendored as ordinary files. See [VENDOR.md](VENDOR.md) for versions and licenses.

`OGClubFurniture` is the ERC-1155 collection, named **OG Club Furniture**, symbol
**OGFURNI**. A token ID is a furniture piece ID. It tracks supply per ID and across
the collection, and reports ERC-2981 royalties.

`OGClubBox` sells boxes using an ERC-20. Season IDs and purchase IDs start at 1.
An item ID can be zero. Several seasons can sell at the same time.

## How a box is decided

1. The owner creates a season with a price, opening and closing timestamps, a
   burn percentage, a Common fallback piece, and 1–32 distinct entries. Each entry
   has an item ID, tier, positive weight and cap. Tiers 0–4 mean Common, Uncommon,
   Rare, Epic and Legendary. A zero cap means unlimited. The fallback must be an
   unlimited Common entry.
2. A buyer approves the box contract to spend the payment token and calls
   `buy(seasonId, count)`, with 1–10 boxes. Sales start at `opensAt` inclusive and
   end at `closesAt` exclusive. The purchase commits to `block.number + 3` and
   records the buyer and count. There is no buyer-supplied secret or seed.
3. After that target block, anyone can submit its full RLP execution header to
   `open(purchaseId, header)`. The contract checks that its Keccak hash equals
   `blockhash(targetBlock)`, decodes field 8 as the target number, and reads field
   13, `mixHash`, as **prevRandao**. Trailing fields are accepted, including those
   added by Shanghai, Cancun and Prague. The header hash authenticates the data;
   it is not used as the random seed.
4. For zero-based box index `i`, the seed is exactly
   `keccak256(abi.encode(prevRandao, block.chainid, address(this), purchaseId, i))`.
   The contract takes this number modulo the season's **full original weight**
   (the sum of every entry's weight, sold out or not), then walks entries in their
   original order. The selected entry therefore depends only on the seed and the
   season terms, never on which other purchases opened first. If the selected
   entry has already sold out, that box receives the fallback piece instead.
   Block hash, timestamp, coinbase and extraData do not enter the seed. The block
   where `open` runs does not supply randomness.
5. The purchase is marked opened, its selected pieces are reserved against caps,
   and `BoxOpened` events record the roll before any delivery call. The box tries
   one `mintBatch` to the buyer. Success marks it delivered and emits
   `Delivered(purchaseId, buyer)`. Failure saves the rolled item IDs and emits
   `DeliveryFailed(purchaseId)`; it does **not** undo the opening or the cap counts.
6. For a failed delivery, anyone may call `deliver(purchaseId)` to retry to the
   buyer. Only the buyer may call `deliverTo(purchaseId, to)` to choose another
   nonzero recipient. These calls use the stored roll, require an opened,
   undelivered purchase, and deliver at most once. A failed retry reverts and
   preserves the stored items. A successful retry clears them and emits
   `Delivered(purchaseId, to)`. No header is needed and delivery has no deadline.

`buy`, `open`, `deliver` and `deliverTo` share a reentrancy guard. Retry delivery
marks the purchase delivered before minting. Only failed openings store item
arrays; successful openings use a delivery flag packed alongside `opened` in its
existing storage slot. The initial mint attempt always receives exactly
`OPEN_MINT_GAS_LIMIT = 1,000,000` gas, and the box keeps
`DELIVERY_RESERVE_GAS = 300,000` gas back for saving up to ten IDs and finishing
the opening. If fewer than `OPEN_DELIVERY_GAS = 1,300,000` gas remain when
delivery starts, `open` reverts with `InsufficientGas(required, available)` and
changes nothing. A short gas limit is therefore a caller precondition failure,
never a `DeliveryFailed`: the gas a caller attaches cannot decide whether a
healthy buyer is delivered or left with a stored roll, and `eth_estimateGas`
returns a limit above the threshold. In the test suite the lowest succeeding
limit is about 1.42M gas for one box, 1.54M for a ten-pack in a three-entry
season and 2.30M for a ten-pack in a 32-entry season; unused gas is refunded as
usual. A receiver exhausting the forwarded gas or returning a large revert
payload cannot veto an opening. Retry calls have no fixed mint gas ceiling,
allowing complex receivers to receive with more gas.

This assumes an Ethereum proof-of-stake chain with Ethereum's execution-header
and prevRandao semantics. It is not a VRF. **The validator proposing the block
before the target can withhold it to re-roll once, losing its block reward.**
Colluding proposers, censorship and chain reorganizations remain consensus-level
risks; a three-block commitment is not a finality guarantee. The field definition
and withholding limitation are described in
[EIP-4399](https://eips.ethereum.org/EIPS/eip-4399).

## Expiry, ten-packs and caps

Opening is allowed only when `block.number > targetBlock`. The normal reveal
window includes `targetBlock + 256`. Starting at `targetBlock + 257`, the header is
ignored and **every box in an unopened purchase becomes the season's fallback
piece**. An expired reveal
emits a zero prevRandao and `expired = true`. Expiry gives no new random roll and
overrides the ten-pack guarantee. There is no refund or cancellation of a paid
purchase. Anyone may pay the gas to open for the buyer, even after sales close or
while buying is paused. Once opened, the recorded roll never expires or changes,
even if delivery remains pending beyond the reveal window.

For a live ten-pack, index 9 is guaranteed Rare, Epic or Legendary while any such
entry is still available. It first selects over the full original weight of every
tier 2–4 entry, using their relative weights. Only if that selected rare has sold
out does a derived seed re-roll among the rare entries still available. If no rare
entry remains at that moment, it uses the ordinary roll. The first nine boxes may
consume the last rare entries. Smaller purchases have no tier guarantee.

Each pick updates the simulated availability before the next pick. A sold-out
entry cannot be selected again; a pick that lands on it becomes the fallback.
`minted(seasonId, itemId)` counts all opened rolls, including stored, undelivered
pieces. Retrying delivery never increments that counter or rolls again. Caps
are **per season and per item**, not global collection limits. Other seasons or
authorized furniture minters may mint the same piece ID. Weights are permanent
odds of being selected; the odds of actually receiving a capped piece fall to zero
once it sells out, and that share goes to the fallback.

For ordinary picks, another opening can only sell out the selected piece and
replace it with fallback. Capped pieces go to whoever opens first. The guaranteed
tenth pick is state-dependent: if its selected rare sells out before opening,
its re-roll among the remaining rares may have a higher or lower tier. Open
promptly; previews do not reserve inventory. Anyone can record another buyer's
roll, and rejecting delivery cannot block that recording or obtain a later
re-roll. Ordering and withholding before an opening is submitted still affect
availability; the ten-pack selection rule is unchanged.

`previewOpen(purchaseId, prevRandao)` uses the same roll function and cap accounting
as `open`. It requires an existing, unopened purchase past its target block. It
does not authenticate the supplied prevRandao, reserve pieces or change state.
For a live purchase, supply the actual target header's mixHash. Its result matches
an immediate opening against the same state; a sell-out in between can only replace
a pick with the fallback (or re-roll a guaranteed tenth box as described). After
expiry, preview ignores the supplied value and returns fallbacks.

## Payments

Prices use the payment token's smallest units; the box does not assume a decimal
count. For each purchase:

```text
total    = price * count
burnAmt  = floor(total * burnBps / 10000)
vaultAmt = total - burnAmt
```

SafeERC20 transfers each nonzero share directly from the buyer to its recipient.
The burn recipient is `0x000000000000000000000000000000000000dEaD`. This is a
transfer to the burn address, not an ERC-20 supply-reduction call. Rounding goes to
the vault. Recipient balances must increase by at least the amount sent on each
leg; otherwise the whole purchase reverts, including any first transfer. Tokens
with missing return values are supported; false-returning and fee-on-transfer
payments are rejected. Use an ordinary, trusted, non-rebasing ERC-20. A token
that lies about balances is outside that assumption.

Successful purchases leave the box's token balance unchanged at zero. The vault
cannot be the box itself. As with any address, someone can send it unsolicited
ERC-20 tokens; the box cannot prevent that and has no recovery/sweep function.
A buyer who is also a payment recipient (for example the vault wallet buying
boxes for a giveaway) pays itself on that leg; the check for that leg is only that
its balance does not fall, so a standard token passes and a token that charges a
fee on the self-transfer still reverts. A zero-value leg is skipped.

`buy` also reverts with `BoxNotMinter` unless the furniture contract currently
authorizes the box as a minter. Sales therefore start only after the
post-deployment `grantMinter(box)` step and stop automatically while that
permission is revoked. Existing purchases can still be opened and their rolls
recorded while minting is disabled.

## What the owners can and cannot do

Both applications use Ownable2Step. `transferOwnership` nominates a successor;
the successor must call `acceptOwnership` on each contract. Nominating zero
cancels a pending transfer. `renounceOwnership` permanently removes owner powers,
without clearing minter authorizations or pending minter proposals, or undoing a
paused state. Anyone may still activate an existing proposal after its deadline.

The box owner can create new seasons, irreversibly close their sales, or cancel
an unstarted season. Both closing and cancellation are terminal; a closed season
cannot subsequently be cancelled. Cancellation must occur strictly before
`opensAt`, when it has no purchases. The owner can also pause/resume purchases
and change the vault for future purchases. A season's percentage split stays
fixed, but its vault recipient follows the current vault setting. A new season
may reuse any piece ID, including one an earlier season sold with a cap, as an
uncapped entry or fallback: caps are per season.

**Seasons are announced ahead of time.** The box is deployed with an immutable
`seasonNotice` (seconds, at most `MAX_SEASON_NOTICE` = 30 days; 7 days on
mainnet, 0 on test networks), readable as `seasonNotice()`. `createSeason`
reverts with `SeasonOpensTooSoon(opensAt, earliest)` unless
`opensAt >= block.timestamp + seasonNotice`, so every season's price, odds and
caps are public for the whole notice before anyone, the owner included, can buy
from it. This closes the gap where the owner could open a 1-wei season at once
with a capped piece near-certain and mint it within four blocks, bypassing the
furniture's seven-day minter notice. With a notice of 0 a season may open in the
block it is created, but `opensAt` can never be in the past. The notice cannot
be changed after deployment. Nothing else about seasons changes: terms stay
immutable once created, and `closeSeason` and `cancelSeason` work as before.
Review each `SeasonCreated` and `SeasonEntry` event during the notice.

The box owner cannot edit an existing season's price, window, entries, tiers,
weights, caps, fallback or split; reopen a closed season; replace the token or
furniture contract; change a purchase's target or recipient; choose a reveal
seed; stop `open`, `deliver` or `deliverTo` through the buying pause; or withdraw
payment tokens. There are
no proxies or upgrade paths.

The furniture owner manages minters through these functions:

- `grantMinter(minter)`: **exactly one grant is ever immediate: the first.** The
  first successful call authorizes at once, emits `MinterSet(minter, true)` and
  sets the public `bootstrapped` flag; it is meant for the box, right after
  deployment. Every later call, whatever `totalSupply()` is, records
  `pendingMinters(minter) = block.timestamp + MINTER_DELAY` and emits
  `MinterProposed(minter, activatesAt)`. **MINTER_DELAY is seven days.**
- `activateMinter(minter)`: anyone can call at or after the proposal's timestamp;
  it clears the proposal, authorizes the minter and emits `MinterSet(minter, true)`.
  Elapsed time alone does not authorize minting.
- `cancelMinter(minter)`: owner only, clears a pending proposal and emits
  `MinterProposalCancelled(minter)`. Existing authorization is unaffected.
- `revokeMinter(minter)`: owner only, removes authorization immediately, clears
  any proposal, and emits `MinterSet(minter, false)`.

The delay does not depend on supply. Sales can start and every roll can still
be undelivered (pending opening, or stored after a `DeliveryFailed`) while
`totalSupply()` is still zero; a new minter proposed in that state waits the
full seven days all the same. Re-granting the box after a revoke also waits
seven days: purchases stay open meanwhile, `open` records and stores their
rolls, and `deliver` retries them once the box is active again. `bootstrapped`
is never cleared, so after the first grant no immediate authorization exists
again. Re-proposing restarts the full delay; proposing for an active minter
leaves its existing permission active. Activation and cancellation require a
pending proposal. `minters(minter)` remains the current authorization view, and
`pendingMinters(minter)` returns zero when nothing is pending. Index `MinterSet`
from deployment to reconstruct the full active list, including the first grant.

The furniture owner can update the metadata prefix until `freezeMetadata()`, and
set a royalty receiver and rate from 0 through 1000 basis points. Initial
royalties are 500 basis points. Royalties are a standard signal to marketplaces,
not an enforced transfer charge. Metadata is `baseURI + decimal itemId + ".json"`;
include the trailing slash in the prefix. Freezing metadata does not freeze
royalties or minters.

Ownership itself grants **no ability to move, burn or confiscate anyone's
furniture**. Holders and approved operators retain standard ERC-1155 transfers;
there is no public burn function. Authorized minters can still mint any piece in
any quantity: the delay provides public notice for new permissions, not global
collection caps. The one immediate minter (the first grant) retains its
permission until revoked. Review that first grant and every later proposal.

Revoking the box stops new sales and delays delivery, but **never changes a
recorded roll**. Continue submitting openings within 256 blocks even while the
box is revoked. Restoring the box always requires `grantMinter`, seven days,
then `activateMinter`, even if nothing has been delivered yet; outstanding
deliveries can then be retried. Delivery depends on maintaining or restoring this role;
renouncing furniture ownership after revoking the box without a pending proposal
would prevent restoration. A purchase nobody opens in time still expires to
fallbacks. The furniture and box owners may be different accounts.

Weights are bounded: a season's summed weights may not exceed `MAX_TOTAL_WEIGHT`
(2^128), which keeps the modulo reduction of the 256-bit seed unbiased to within
one part in 2^128 of the published odds.

## Deployment parameters and steps

No deployment was performed for this assignment. Constructors are nonpayable,
use static address arguments only, and do not call or require code at dependency
addresses. The deployer must verify the configured contracts on the intended
chain before enabling sales.

| Contract | Constructor parameters |
| --- | --- |
| `OGClubFurniture` | `initialOwner`, `royaltyReceiver` (both nonzero) |
| `OGClubBox` | `IERC20 token`, `OGClubFurniture furniture`, `vault`, `initialOwner` (all nonzero), `seasonNotice` (seconds, at most 30 days) |
| `MockOG` | `initialRecipient` of its initial test supply |

`seasonNotice` is 7 days on mainnet and 0 on test networks (the Sepolia manifest
passes `0`). The constructor reverts with `InvalidSeasonNotice` above 30 days.

`script/Deploy.s.sol` reads **TOKEN**, **VAULT**, **OWNER** and **SEASON_NOTICE**
from the operator's environment. It creates furniture first, then the box. It
uses OWNER as the initial royalty receiver, a documented script choice that the
furniture owner can later change. It does not deploy a mock token or create a
season. No private key is read by the script. The eventual deployer supplies
their signer through their own Foundry invocation.
`deploy(token, vault, owner, seasonNotice)` is also callable directly for
parameterized local tests, without environment variables.

After deployment, the furniture owner must:

1. **Grant the box first.** Call `furniture.grantMinter(box)` with the confirmed
   box address right after deployment, before any other grant. The first
   `grantMinter` ever is the only immediate one and sets `bootstrapped`; if any
   other address is granted first, the box becomes a seven-day proposal and
   needs `activateMinter(box)` before sales. Until authorization every `buy`
   reverts with `BoxNotMinter`.
2. Call `furniture.setBaseURI(...)` with the published metadata prefix. Check the
   files, then optionally call `freezeMetadata()`.

The box owner then creates seasons with the intended prices, windows, entries
and fallback. **Create each season at least `seasonNotice` before it opens**:
`createSeason` requires `opensAt >= block.timestamp + seasonNotice`, so with the
mainnet value a season created today can open no earlier than a week from now
(with 0, any `opensAt` from the current block's timestamp on). Confirm token
allowances, recipient balances and mint permissions
before opening sales. Keep the box's minting permission enabled for prompt
delivery. Monitor `BoxesBought`, obtain headers and submit reveals within the
256-block window even if minting is disabled. Send `open` with the estimated gas
limit; a limit below the published minimum reverts with `InsufficientGas` and
costs only the failed call. Monitor `DeliveryFailed` and retry
with `deliver`, or have the buyer call `deliverTo` if it cannot receive furniture.
Buyers or independent relayers can submit openings and ordinary retries; there
is no privileged opener or built-in keeper.

To prepare a header, fetch the target execution block with
`eth_getBlockByNumber` and encode its header fields in consensus order. The
standard-library-only helper accepts a block JSON object or JSON-RPC response:

```sh
python3 script/encode_header.py target-block.json
```

It supports execution headers through Prague. Check `cast keccak` of its output
against the block's published hash before passing the hex bytes to `open`.
Future forks that append header fields may require updating this off-chain
encoder; the contract accepts additional trailing fields already. Use the block
header itself, not the whole block or JSON encoding. A contract buyer can receive
directly if it implements the ERC-1155 receiver callbacks. Otherwise opening still
records its roll, and the buyer contract must be able to call
`deliverTo(purchaseId, recipient)` to receive at an EOA or compatible contract.
Only that buyer can authorize redirection; the box owner cannot do it for them.

`getSeason(id)` and `getEntries(id)` expose season terms. `minted(seasonId,itemId)`
and the unchanged five-field `purchases(id)` view expose purchase accounting.
`delivered(id)` reports delivery status; `getStoredItems(id)` returns the ordered
rolled IDs, including duplicates, only while a failed delivery is outstanding.
Index `SeasonCreated`, `SeasonEntry`, `BoxesBought`, `BoxOpened`, `DeliveryFailed`
and `Delivered`; no per-user purchase arrays are stored. `BoxOpened` includes
purchase ID, zero-based index, piece ID, tier, prevRandao and expiry flag; it
records the roll regardless of delivery. `Delivered` includes the actual recipient.
Administrative changes and ownership handovers also emit events.

`src/mocks/MockOG.sol` is **tests/testnets only**. Its symbol is **mockog**, it has
18 decimals, and construction mints **1,000,000,000,000 tokens** to the explicit
recipient. `mint` is public and unrestricted, so that initial supply is not a
maximum. The application deployment script expects an already chosen token.

## Local checks

With Foundry and Solidity 0.8.26 available, no dependency download is needed:

```sh
forge build
FOUNDRY_FUZZ_SEED=0xd7cbf984d9643a3a39694e4c2b43fdd2684bdc6f7f33900f61d9d2eb94626e58 forge test
forge fmt --check
```

Tests use local mocks, `vm.roll`, and `vm.setBlockhash`; no RPC, environment reads,
filesystem permissions, or FFI are required. Real mainnet headers from Shanghai,
Cancun and Prague are embedded, with their original published fields and hashes
under [test/fixtures](test/fixtures/SOURCES.md). The suite covers payment splits,
malformed headers, all sale/reveal boundaries, access control, ownership, caps,
ten-packs, delayed minter activation, rejected delivery, redirection, gas exhaustion
and reentrancy. `test/SeasonNotice.t.sol` deploys a box with a seven-day notice
and checks the exact `opensAt` boundary, that the owner cannot buy from or mint
through a new season before its notice, and that close and cancel are unchanged;
`test/OGClubFurniture.t.sol` and `test/DeliveryEdges.t.sol` check that only the
first grant is immediate, that a second grant and a re-grant of the revoked box
wait seven days while `totalSupply()` is still zero, and that opens during that
wait store their rolls. `test/OpenGas.t.sol` checks that a short gas limit reverts
without state changes, that the lowest succeeding limit always delivers, and
that the reserve stores ten distinct IDs at that exact boundary against a
receiver that burns the whole mint budget. `test/FixedOdds.t.sol` checks that
ordinary picks retain their original weight intervals, rejected delivery preserves
its roll and cap reservation, and the guaranteed tenth pick cannot be upgraded
by rejecting delivery after an opening is submitted. A statistical test samples 20,000
prevRandao values derived from fuzz entropy and checks each no-cap frequency
within one percentage point of its weight share. It suspends gas metering only
for those independent view queries. Stateful invariants check custody, payment
conservation, caps, one-time opening/delivery and preview/open equality. The
delivery invariant accounts for every reserved piece as delivered ERC-1155 supply
plus stored undelivered items, with receiver rejection and retry interleavings.

These local checks are not an independent security audit. A separate adversarial
review and verification of deployment parameters remain release responsibilities.
