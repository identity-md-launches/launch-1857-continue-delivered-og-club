// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {OGClubBox} from "../src/OGClubBox.sol";
import {OGClubFurniture} from "../src/OGClubFurniture.sol";
import {MockOG} from "../src/mocks/MockOG.sol";
import {HeaderBuilder} from "./helpers/HeaderBuilder.sol";

/// @dev Plain EOA-like actor that can hold ERC-1155 tokens.
contract Actor is ERC1155Holder {}

/// @dev Drives the box with several buyers, several seasons (some created mid-run), vault changes,
///      closing and cancelling, expiry, and open attempts in random order by random callers.
///      Every action either succeeds and updates ghosts, or is proven to revert with the expected error.
contract MultiActorHandler is Test {
    OGClubBox public box;
    OGClubFurniture public furniture;
    MockOG public token;
    address public owner;
    address[] public actors;
    address[] public vaults;
    uint256 public constant FUNDING = 1e30;
    uint256 public constant MAX_SEASONS = 8;
    uint256 public constant MAX_ITEM = 12;

    // Ghost accounting.
    mapping(address recipient => uint256 amount) public ghostReceived;
    mapping(address actor => uint256 amount) public ghostSpent;
    mapping(uint256 seasonId => mapping(uint256 itemId => uint256 count)) public ghostMinted;
    mapping(address actor => mapping(uint256 itemId => uint256 count)) public ghostHeld;
    mapping(uint256 purchaseId => bool) public ghostOpened;
    mapping(uint256 seasonId => bool) public ghostClosed;
    mapping(uint256 seasonId => bytes32) public ghostTerms;
    mapping(uint256 => bytes32) internal randaoByBlock;
    mapping(uint256 => bool) internal hasRandao;
    uint256 public itemsOpened;
    uint256 public opens;
    uint256 public expiredOpens;
    uint256 public guaranteedChecks;
    uint256 public rejectedBuys;
    uint256 public rejectedOpens;
    uint256 public rejectedOwnerCalls;

    constructor(OGClubBox box_, OGClubFurniture furniture_, MockOG token_, address owner_) {
        box = box_;
        furniture = furniture_;
        token = token_;
        owner = owner_;
        for (uint256 i; i < 3; ++i) {
            address actor = address(new Actor());
            actors.push(actor);
            token.mint(actor, FUNDING);
            vm.prank(actor);
            token.approve(address(box), type(uint256).max);
        }
        vaults.push(box.vault());
        vaults.push(makeAddr("second vault"));
    }

    function recordSeason(uint256 seasonId) public {
        ghostTerms[seasonId] = keccak256(abi.encode(box.getSeason(seasonId), box.getEntries(seasonId)));
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function vaultCount() external view returns (uint256) {
        return vaults.length;
    }

    // ------------------------------------------------------------------ buyers

    function buy(uint8 actorSeed, uint8 seasonSeed, uint8 countSeed) external {
        address actor = actors[actorSeed % actors.length];
        uint256 seasonId = uint256(seasonSeed) % (box.seasonCount() + 1); // may be 0 (unknown)
        uint256 count = bound(countSeed, 0, 12); // may be out of range
        bytes memory expected = _expectedBuyError(seasonId, count);
        if (expected.length != 0) {
            vm.prank(actor);
            (bool ok, bytes memory reason) = address(box).call(abi.encodeCall(box.buy, (seasonId, count)));
            assertFalse(ok, "buy should have reverted");
            assertEq(reason, expected, "unexpected buy error");
            ++rejectedBuys;
            return;
        }
        _recordPayment(actor, seasonId, count);
        uint256 before = box.purchaseCount();
        vm.prank(actor);
        uint256 id = box.buy(seasonId, count);
        assertEq(id, before + 1);
        _checkStoredPurchase(id, actor, seasonId, count);
    }

    function _recordPayment(address actor, uint256 seasonId, uint256 count) internal {
        OGClubBox.Season memory season = box.getSeason(seasonId);
        uint256 total = season.price * count;
        uint256 burnAmt = total * season.burnBps / 10_000;
        ghostSpent[actor] += total;
        ghostReceived[box.BURN_ADDRESS()] += burnAmt;
        ghostReceived[box.vault()] += total - burnAmt;
    }

    function _checkStoredPurchase(uint256 id, address actor, uint256 seasonId, uint256 count) internal view {
        (address storedBuyer, uint256 storedSeason, uint256 storedCount, uint256 targetBlock, bool opened) =
            box.purchases(id);
        assertEq(storedBuyer, actor);
        assertEq(storedSeason, seasonId);
        assertEq(storedCount, count);
        assertEq(targetBlock, block.number + 3);
        assertFalse(opened);
    }

    function _expectedBuyError(uint256 seasonId, uint256 count) internal view returns (bytes memory) {
        if (seasonId == 0 || seasonId > box.seasonCount()) {
            return abi.encodeWithSelector(OGClubBox.UnknownSeason.selector, seasonId);
        }
        if (count == 0 || count > 10) return abi.encodeWithSelector(OGClubBox.InvalidCount.selector);
        if (box.paused()) return abi.encodeWithSelector(OGClubBox.BuyingPaused.selector);
        OGClubBox.Season memory season = box.getSeason(seasonId);
        if (season.closed || block.timestamp < season.opensAt || block.timestamp >= season.closesAt) {
            return abi.encodeWithSelector(OGClubBox.SalesUnavailable.selector, seasonId);
        }
        return "";
    }

    struct OpenCtx {
        address caller;
        uint256 purchaseId;
        address buyer;
        uint256 seasonId;
        uint256 count;
        uint256 targetBlock;
        bool expired;
        bytes32 randao;
        bytes header;
    }

    function open(uint8 callerSeed, uint256 purchaseSeed, bytes32 entropy, bool expire) external {
        OpenCtx memory ctx;
        ctx.caller = callerSeed % 4 == 3 ? makeAddr("stranger") : actors[callerSeed % actors.length];
        ctx.purchaseId = box.purchaseCount() == 0 ? 0 : purchaseSeed % (box.purchaseCount() + 1);
        if (ctx.purchaseId == 0) {
            _expectOpenRevert(ctx.caller, 0, "", abi.encodeWithSelector(OGClubBox.UnknownPurchase.selector, 0));
            return;
        }
        bool opened;
        (ctx.buyer, ctx.seasonId, ctx.count, ctx.targetBlock, opened) = box.purchases(ctx.purchaseId);
        if (opened) {
            _expectOpenRevert(
                ctx.caller, ctx.purchaseId, "", abi.encodeWithSelector(OGClubBox.AlreadyOpened.selector, ctx.purchaseId)
            );
            return;
        }
        if (block.number <= ctx.targetBlock) {
            // Too early: proven to revert, then advance to the first valid block.
            _expectOpenRevert(
                ctx.caller,
                ctx.purchaseId,
                "",
                abi.encodeWithSelector(OGClubBox.TargetBlockNotPassed.selector, ctx.targetBlock)
            );
            vm.roll(ctx.targetBlock + 1);
        }
        if (expire && block.number <= ctx.targetBlock + 256) vm.roll(ctx.targetBlock + 257);
        ctx.expired = block.number > ctx.targetBlock + 256;
        if (!hasRandao[ctx.targetBlock]) {
            hasRandao[ctx.targetBlock] = true;
            randaoByBlock[ctx.targetBlock] = entropy;
        }
        ctx.randao = randaoByBlock[ctx.targetBlock];
        ctx.header = HeaderBuilder.header(ctx.targetBlock, ctx.randao, 3);
        if (!ctx.expired) {
            vm.setBlockhash(ctx.targetBlock, keccak256(ctx.header));
            // A wrong header is rejected before any state changes.
            _expectOpenRevert(
                ctx.caller,
                ctx.purchaseId,
                HeaderBuilder.header(ctx.targetBlock + 1, ctx.randao, 3),
                abi.encodeWithSelector(OGClubBox.HeaderHashMismatch.selector)
            );
            --rejectedOpens; // not a distinct rejected call for the statistics
        }
        _executeOpen(ctx);
    }

    function _expectOpenRevert(address caller, uint256 purchaseId, bytes memory header, bytes memory expected)
        internal
    {
        vm.prank(caller);
        (bool ok, bytes memory reason) = address(box).call(abi.encodeCall(box.open, (purchaseId, header)));
        assertFalse(ok, "open should have reverted");
        assertEq(reason, expected, "unexpected open error");
        ++rejectedOpens;
    }

    function _executeOpen(OpenCtx memory ctx) internal {
        uint256[] memory preview = box.previewOpen(ctx.purchaseId, ctx.randao);
        assertEq(preview.length, ctx.count);
        _checkPreviewAgainstRules(
            ctx.seasonId,
            box.getEntries(ctx.seasonId),
            preview,
            ctx.expired,
            box.getSeason(ctx.seasonId).fallbackItem,
            ctx.count
        );

        uint256[] memory balancesBefore = new uint256[](MAX_ITEM + 1);
        for (uint256 id; id <= MAX_ITEM; ++id) {
            balancesBefore[id] = furniture.balanceOf(ctx.buyer, id);
        }
        vm.prank(ctx.caller);
        box.open(ctx.purchaseId, ctx.expired ? bytes("ignored") : ctx.header);

        for (uint256 i; i < ctx.count; ++i) {
            ++ghostMinted[ctx.seasonId][preview[i]];
            ++ghostHeld[ctx.buyer][preview[i]];
        }
        for (uint256 id; id <= MAX_ITEM; ++id) {
            uint256 received;
            for (uint256 i; i < ctx.count; ++i) {
                if (preview[i] == id) ++received;
            }
            assertEq(furniture.balanceOf(ctx.buyer, id), balancesBefore[id] + received, "open differs from preview");
        }
        (,,,, bool opened) = box.purchases(ctx.purchaseId);
        assertTrue(opened);
        ghostOpened[ctx.purchaseId] = true;
        itemsOpened += ctx.count;
        ++opens;
        if (ctx.expired) ++expiredOpens;
    }

    function _checkPreviewAgainstRules(
        uint256 seasonId,
        OGClubBox.Entry[] memory entries,
        uint256[] memory preview,
        bool expired,
        uint256 fallbackItem,
        uint256 count
    ) internal {
        uint256[] memory running = new uint256[](entries.length);
        for (uint256 j; j < entries.length; ++j) {
            running[j] = box.minted(seasonId, entries[j].itemId);
        }
        for (uint256 i; i < count; ++i) {
            if (expired) {
                assertEq(preview[i], fallbackItem, "expired box must be the fallback");
                continue;
            }
            bool found;
            for (uint256 j; j < entries.length; ++j) {
                if (entries[j].itemId != preview[i]) continue;
                found = true;
                if (entries[j].cap != 0) assertLt(running[j], entries[j].cap, "sold-out item rolled");
                if (count == 10 && i == 9) {
                    bool rareLeft;
                    for (uint256 k; k < entries.length; ++k) {
                        if (entries[k].tier >= 2 && (entries[k].cap == 0 || running[k] < entries[k].cap)) {
                            rareLeft = true;
                        }
                    }
                    if (rareLeft) {
                        assertGe(entries[j].tier, 2, "box 9 must be rare while one is available");
                        ++guaranteedChecks;
                    }
                }
                ++running[j];
            }
            assertTrue(found, "rolled an item that is not in the season");
        }
    }

    // ------------------------------------------------------------------ time

    function advanceBlocks(uint16 blocks) external {
        vm.roll(block.number + bound(blocks, 1, 300));
    }

    function warp(uint32 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 1, 20_000));
    }

    // ------------------------------------------------------------------ owner

    function closeSeason(uint8 seasonSeed) external {
        uint256 seasonId = uint256(seasonSeed) % (box.seasonCount() + 1);
        bytes memory expected;
        if (seasonId == 0) {
            expected = abi.encodeWithSelector(OGClubBox.UnknownSeason.selector, seasonId);
        } else if (box.getSeason(seasonId).closed) {
            expected = abi.encodeWithSelector(OGClubBox.SeasonAlreadyClosed.selector, seasonId);
        }
        vm.prank(owner);
        (bool ok, bytes memory reason) = address(box).call(abi.encodeCall(box.closeSeason, (seasonId)));
        if (expected.length != 0) {
            assertFalse(ok);
            assertEq(reason, expected);
            ++rejectedOwnerCalls;
            return;
        }
        assertTrue(ok);
        ghostClosed[seasonId] = true;
        assertTrue(box.getSeason(seasonId).closed);
    }

    function cancelSeason(uint8 seasonSeed) external {
        uint256 seasonId = uint256(seasonSeed) % (box.seasonCount() + 1);
        bytes memory expected;
        if (seasonId == 0) {
            expected = abi.encodeWithSelector(OGClubBox.UnknownSeason.selector, seasonId);
        } else {
            OGClubBox.Season memory season = box.getSeason(seasonId);
            if (season.closed) {
                expected = abi.encodeWithSelector(OGClubBox.SeasonAlreadyClosed.selector, seasonId);
            } else if (block.timestamp >= season.opensAt) {
                expected = abi.encodeWithSelector(OGClubBox.SeasonAlreadyStarted.selector, seasonId);
            }
        }
        vm.prank(owner);
        (bool ok, bytes memory reason) = address(box).call(abi.encodeCall(box.cancelSeason, (seasonId)));
        if (expected.length != 0) {
            assertFalse(ok);
            assertEq(reason, expected);
            ++rejectedOwnerCalls;
            return;
        }
        assertTrue(ok);
        ghostClosed[seasonId] = true;
        OGClubBox.Season memory after_ = box.getSeason(seasonId);
        assertTrue(after_.closed && after_.cancelled);
    }

    function setPaused(bool value) external {
        vm.prank(owner);
        box.setPaused(value);
        assertEq(box.paused(), value);
    }

    function setVault(uint8 vaultSeed) external {
        address next = vaults[vaultSeed % vaults.length];
        vm.prank(owner);
        box.setVault(next);
        assertEq(box.vault(), next);
    }

    function createSeason(
        uint64 price,
        uint16 delay,
        uint16 duration,
        uint16 burnBps,
        uint8 entryCount,
        bytes32 entropy
    ) external {
        if (box.seasonCount() >= MAX_SEASONS) return;
        price = uint64(bound(price, 1, 1e12));
        burnBps = uint16(bound(burnBps, 0, 10_000));
        entryCount = uint8(bound(entryCount, 1, 6));
        OGClubBox.Entry[] memory entries = new OGClubBox.Entry[](entryCount);
        for (uint256 i; i < entryCount; ++i) {
            bytes32 r = keccak256(abi.encode(entropy, i));
            entries[i] = OGClubBox.Entry({
                itemId: 1 + (uint256(r) % MAX_ITEM + i) % MAX_ITEM,
                tier: uint8(uint256(r >> 16) % 5),
                weight: uint256(r >> 32) % 100 + 1,
                cap: uint256(r >> 64) % 6
            });
            for (uint256 j; j < i; ++j) {
                if (entries[j].itemId == entries[i].itemId) {
                    entries[i].itemId = 0; // mark duplicate
                }
            }
        }
        // Compact duplicates away by renumbering them into unused ids.
        for (uint256 i; i < entryCount; ++i) {
            if (entries[i].itemId != 0) continue;
            for (uint256 candidate = 1; candidate <= MAX_ITEM; ++candidate) {
                bool used;
                for (uint256 j; j < entryCount; ++j) {
                    if (entries[j].itemId == candidate) used = true;
                }
                if (!used) {
                    entries[i].itemId = candidate;
                    break;
                }
            }
        }
        entries[0].tier = 0;
        entries[0].cap = 0;
        uint256 opensAt = block.timestamp + bound(delay, 0, 5000);
        uint256 closesAt = opensAt + bound(duration, 1, 50_000);
        vm.prank(owner);
        uint256 seasonId = box.createSeason(price, opensAt, closesAt, burnBps, entries[0].itemId, entries);
        recordSeason(seasonId);
    }

    function strangerCannotAdminister(uint8 which) external {
        address stranger = makeAddr("stranger");
        bytes memory call_;
        uint256 w = which % 5;
        if (w == 0) call_ = abi.encodeCall(box.closeSeason, (1));
        else if (w == 1) call_ = abi.encodeCall(box.cancelSeason, (1));
        else if (w == 2) call_ = abi.encodeCall(box.setPaused, (!box.paused()));
        else if (w == 3) call_ = abi.encodeCall(box.setVault, (stranger));
        else call_ = abi.encodeCall(box.transferOwnership, (stranger));
        vm.prank(stranger);
        (bool ok,) = address(box).call(call_);
        assertFalse(ok, "stranger administered the box");
        ++rejectedOwnerCalls;
    }
}

/// forge-config: default.invariant.runs = 96
/// forge-config: default.invariant.depth = 80
contract MultiActorInvariantTest is Test {
    MockOG internal token;
    OGClubFurniture internal furniture;
    OGClubBox internal box;
    MultiActorHandler internal handler;
    address internal vault = makeAddr("vault");

    function setUp() public {
        vm.roll(100);
        vm.warp(1000);
        token = new MockOG(address(this));
        furniture = new OGClubFurniture(address(this), vault);
        box = new OGClubBox(token, furniture, vault, address(this), 0);
        furniture.grantMinter(address(box));
        handler = new MultiActorHandler(box, furniture, token, address(this));

        OGClubBox.Entry[] memory a = new OGClubBox.Entry[](3);
        a[0] = OGClubBox.Entry(1, 0, 60, 0);
        a[1] = OGClubBox.Entry(2, 1, 30, 4);
        a[2] = OGClubBox.Entry(3, 2, 10, 3);
        handler.recordSeason(box.createSeason(101, 1000, 100_000, 3333, 1, a));

        OGClubBox.Entry[] memory b = new OGClubBox.Entry[](5);
        b[0] = OGClubBox.Entry(4, 0, 50, 0);
        b[1] = OGClubBox.Entry(5, 1, 25, 0);
        b[2] = OGClubBox.Entry(6, 2, 15, 5);
        b[3] = OGClubBox.Entry(7, 3, 7, 2);
        b[4] = OGClubBox.Entry(8, 4, 3, 1);
        handler.recordSeason(box.createSeason(7, 1000, 100_000, 10_000, 4, b));

        OGClubBox.Entry[] memory c = new OGClubBox.Entry[](2);
        c[0] = OGClubBox.Entry(1, 0, 1, 0);
        c[1] = OGClubBox.Entry(9, 4, 1e18, 1);
        handler.recordSeason(box.createSeason(1e18, 3000, 4000, 0, 1, c)); // opens later; cancellable for a while

        // Never vacuous: one live purchase and one expired purchase are opened before fuzzing starts.
        handler.buy(0, 1, 10);
        handler.buy(1, 2, 10);
        handler.open(3, 1, keccak256("live"), false);
        handler.open(0, 2, keccak256("expired"), true);

        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = MultiActorHandler.buy.selector;
        selectors[1] = MultiActorHandler.buy.selector;
        selectors[2] = MultiActorHandler.open.selector;
        selectors[3] = MultiActorHandler.open.selector;
        selectors[4] = MultiActorHandler.advanceBlocks.selector;
        selectors[5] = MultiActorHandler.warp.selector;
        selectors[6] = MultiActorHandler.closeSeason.selector;
        selectors[7] = MultiActorHandler.cancelSeason.selector;
        selectors[8] = MultiActorHandler.setPaused.selector;
        selectors[9] = MultiActorHandler.setVault.selector;
        selectors[10] = MultiActorHandler.createSeason.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        bytes4[] memory more = new bytes4[](1);
        more[0] = MultiActorHandler.strangerCannotAdminister.selector;
        targetSelector(FuzzSelector(address(handler), more));
        targetContract(address(handler));
    }

    function invariant_BoxNeverHoldsTheToken() public view {
        assertEq(token.balanceOf(address(box)), 0);
    }

    function invariant_EveryTokenPaidIsAccountedToBurnOrAVault() public view {
        uint256 spent;
        for (uint256 i; i < handler.actorCount(); ++i) {
            address actor = handler.actors(i);
            assertEq(token.balanceOf(actor), handler.FUNDING() - handler.ghostSpent(actor));
            spent += handler.ghostSpent(actor);
        }
        uint256 received = token.balanceOf(box.BURN_ADDRESS());
        assertEq(received, handler.ghostReceived(box.BURN_ADDRESS()));
        for (uint256 i; i < handler.vaultCount(); ++i) {
            address v = handler.vaults(i);
            assertEq(token.balanceOf(v), handler.ghostReceived(v));
            received += token.balanceOf(v);
        }
        assertEq(received, spent, "payments leaked or were created");
    }

    function invariant_MintedNeverExceedsCapAndMatchesSupply() public view {
        uint256[] memory perItem = new uint256[](handler.MAX_ITEM() + 1);
        uint256 total;
        for (uint256 s = 1; s <= box.seasonCount(); ++s) {
            OGClubBox.Entry[] memory entries = box.getEntries(s);
            for (uint256 j; j < entries.length; ++j) {
                uint256 m = box.minted(s, entries[j].itemId);
                if (entries[j].cap != 0) assertLe(m, entries[j].cap, "cap exceeded");
                assertEq(m, handler.ghostMinted(s, entries[j].itemId), "minted counter drifted from ghost");
                perItem[entries[j].itemId] += m;
                total += m;
            }
        }
        for (uint256 id; id <= handler.MAX_ITEM(); ++id) {
            assertEq(furniture.totalSupply(id), perItem[id], "furniture supply differs from box accounting");
            uint256 held;
            for (uint256 i; i < handler.actorCount(); ++i) {
                address actor = handler.actors(i);
                assertEq(furniture.balanceOf(actor, id), handler.ghostHeld(actor, id));
                held += furniture.balanceOf(actor, id);
            }
            assertEq(held, perItem[id], "items minted to someone other than a buyer");
        }
        assertEq(total, handler.itemsOpened());
        assertEq(furniture.totalSupply(), total);
    }

    function invariant_PurchasesOpenOnceAndFinishedStatesNeverReopen() public view {
        uint256 openedCount;
        for (uint256 id = 1; id <= box.purchaseCount(); ++id) {
            (address buyer,, uint256 count,, bool opened) = box.purchases(id);
            assertTrue(buyer != address(0));
            assertTrue(count >= 1 && count <= 10);
            assertEq(opened, handler.ghostOpened(id), "opened flag drifted");
            if (opened) ++openedCount;
            // This handler uses EOAs exclusively, so every opening delivers immediately.
            assertEq(box.delivered(id), opened);
            assertEq(box.getStoredItems(id).length, 0);
        }
        assertEq(openedCount, handler.opens());
        for (uint256 s = 1; s <= box.seasonCount(); ++s) {
            OGClubBox.Season memory season = box.getSeason(s);
            assertEq(season.closed, handler.ghostClosed(s), "a closed season reopened or closed itself");
            if (season.cancelled) assertTrue(season.closed);
            assertEq(
                keccak256(abi.encode(_termsOnly(season), box.getEntries(s))), handler.ghostTerms(s), "terms changed"
            );
        }
    }

    /// @dev Terms were recorded at creation, when both flags were false.
    function _termsOnly(OGClubBox.Season memory season) internal pure returns (OGClubBox.Season memory) {
        season.closed = false;
        season.cancelled = false;
        return season;
    }

    function invariant_HandlerExercisedFailurePathsAndGuarantee() public view {
        assertGt(handler.opens(), 0);
        assertGt(handler.expiredOpens(), 0);
        assertGt(handler.guaranteedChecks(), 0);
    }
}
