// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BoxTestBase} from "./helpers/BoxTestBase.sol";
import {HeaderBuilder} from "./helpers/HeaderBuilder.sol";
import {OGClubBox} from "../src/OGClubBox.sol";
import {BlockHeader} from "../src/libraries/BlockHeader.sol";
import {IERC20Errors, IERC1155Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract HeaderHarness2 {
    function decode(bytes calldata header) external pure returns (uint256 number, bytes32 randao) {
        return BlockHeader.decode(header);
    }
}

/// @dev A buyer that is a contract without any ERC-1155 receiver hook.
contract DeafBuyer {
    function deliverTo(OGClubBox box, uint256 purchaseId, address to) external {
        box.deliverTo(purchaseId, to);
    }

    function buy(OGClubBox box, uint256 season, uint256 count) external returns (uint256) {
        return box.buy(season, count);
    }
}

/// @dev Inputs the implementation did not obviously consider: boundaries, order, identity, events.
contract EdgeCasesTest is BoxTestBase {
    event SeasonCreated(
        uint256 indexed seasonId,
        uint256 price,
        uint256 opensAt,
        uint256 closesAt,
        uint256 burnBps,
        uint256 fallbackItem
    );
    event SeasonEntry(uint256 indexed seasonId, uint256 indexed itemId, uint8 tier, uint256 weight, uint256 cap);
    event SeasonClosed(uint256 indexed seasonId);
    event SeasonCancelled(uint256 indexed seasonId);
    event PausedSet(bool paused);
    event VaultSet(address indexed previousVault, address indexed newVault);

    // ---------------------------------------------------------------- caps and seasons

    function test_CapsAreTrackedPerSeasonNotPerItem() public {
        OGClubBox.Entry[] memory entries = new OGClubBox.Entry[](2);
        entries[0] = OGClubBox.Entry(1, 0, 1, 0);
        entries[1] = OGClubBox.Entry(3, 4, 1e30, 2);
        uint256 a = box.createSeason(1, 1000, 100_000, 0, 1, entries);
        uint256 b = box.createSeason(1, 1000, 100_000, 0, 1, entries);
        bytes32 randao = keccak256("per season caps");
        for (uint256 round; round < 2; ++round) {
            vm.prank(buyer);
            uint256 pa = box.buy(a, 10);
            vm.prank(buyer);
            uint256 pb = box.buy(b, 10);
            bytes memory header = ready(pa, randao);
            assertOpenMatches(pa, randao, header, false);
            assertOpenMatches(pb, randao, header, false);
        }
        // Each season hands out its own two legendaries; the item's global supply is their sum.
        assertEq(box.minted(a, 3), 2);
        assertEq(box.minted(b, 3), 2);
        assertEq(furniture.totalSupply(3), 4);
        assertEq(furniture.balanceOf(buyer, 3), 4);
        assertEq(furniture.balanceOf(buyer, 1), 36);
    }

    function test_SingleEntrySeasonAlwaysMintsFallbackEvenInTenPack() public {
        OGClubBox.Entry[] memory entries = new OGClubBox.Entry[](1);
        entries[0] = OGClubBox.Entry(9, 0, 5, 0);
        uint256 season = box.createSeason(5, 1000, 100_000, 5000, 9, entries);
        vm.prank(buyer);
        uint256 purchase = box.buy(season, 10);
        bytes32 randao = keccak256("single entry");
        bytes memory header = ready(purchase, randao);
        uint256[] memory expected = box.previewOpen(purchase, randao);
        for (uint256 i; i < 10; ++i) {
            assertEq(expected[i], 9);
        }
        assertOpenMatches(purchase, randao, header, false);
        assertEq(furniture.balanceOf(buyer, 9), 10);
        assertEq(box.minted(season, 9), 10);
    }

    function test_TotalWeightMayEqualMaxTotalWeightButNotExceedIt() public {
        uint256 maxTotal = box.MAX_TOTAL_WEIGHT();
        assertEq(maxTotal, 1 << 128);
        OGClubBox.Entry[] memory entries = new OGClubBox.Entry[](3);
        entries[0] = OGClubBox.Entry(1, 0, maxTotal - 10, 0);
        entries[1] = OGClubBox.Entry(2, 2, 7, 0);
        entries[2] = OGClubBox.Entry(3, 4, 3, 1);
        // Summed weights of exactly MAX_TOTAL_WEIGHT are accepted and the season is fully usable.
        uint256 season = box.createSeason(1, 1000, 100_000, 0, 1, entries);
        vm.prank(buyer);
        uint256 purchase = box.buy(season, 10);
        bytes32 randao = keccak256("max weight");
        bytes memory header = ready(purchase, randao);
        uint256[] memory expected = box.previewOpen(purchase, randao);
        // Box 9 is guaranteed rare: the two rare entries share a weight of ten.
        assertTrue(expected[9] == 2 || expected[9] == 3);
        assertOpenMatches(purchase, randao, header, false);

        // One more unit of weight anywhere in the list overflows the bound.
        entries[1].weight = 8;
        vm.expectRevert(OGClubBox.WeightOverflow.selector);
        box.createSeason(1, 1000, 100_000, 0, 1, entries);

        // The bound is on the sum, so the overflow is caught at whichever entry crosses it, including the last.
        entries[1].weight = 7;
        entries[2].weight = 4;
        vm.expectRevert(OGClubBox.WeightOverflow.selector);
        box.createSeason(1, 1000, 100_000, 0, 1, entries);

        // A single entry may carry the whole bound; a single entry above it is rejected.
        OGClubBox.Entry[] memory one = new OGClubBox.Entry[](1);
        one[0] = OGClubBox.Entry(1, 0, maxTotal, 0);
        box.createSeason(1, 1000, 100_000, 0, 1, one);
        one[0].weight = maxTotal + 1;
        vm.expectRevert(OGClubBox.WeightOverflow.selector);
        box.createSeason(1, 1000, 100_000, 0, 1, one);
        one[0].weight = type(uint256).max;
        vm.expectRevert(OGClubBox.WeightOverflow.selector);
        box.createSeason(1, 1000, 100_000, 0, 1, one);
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_CreateSeasonRoundTripsTermsAndEntries(
        uint64 price,
        uint32 opensAt,
        uint32 duration,
        uint16 burnBps,
        uint8 entryCount,
        bytes32 entropy
    ) public {
        price = uint64(bound(price, 1, type(uint64).max));
        opensAt = uint32(bound(opensAt, block.timestamp, type(uint32).max)); // never before now + seasonNotice (0)
        duration = uint32(bound(duration, 1, type(uint32).max));
        burnBps = uint16(bound(burnBps, 0, 10_000));
        entryCount = uint8(bound(entryCount, 1, 32));
        OGClubBox.Entry[] memory entries = new OGClubBox.Entry[](entryCount);
        uint256 fallbackIndex = uint256(keccak256(abi.encode(entropy, "fallback"))) % entryCount;
        for (uint256 i; i < entryCount; ++i) {
            bytes32 r = keccak256(abi.encode(entropy, i));
            entries[i] = OGClubBox.Entry({
                itemId: 1000 + i,
                tier: uint8(uint256(r) % 5),
                weight: uint256(r >> 8) % 1e12 + 1,
                cap: uint256(r >> 64) % 7
            });
        }
        entries[fallbackIndex].tier = 0;
        entries[fallbackIndex].cap = 0;
        uint256 fallbackItem = entries[fallbackIndex].itemId;
        uint256 closesAt = uint256(opensAt) + duration;

        uint256 season = box.createSeason(price, opensAt, closesAt, burnBps, fallbackItem, entries);
        assertEq(season, box.seasonCount());
        OGClubBox.Season memory stored = box.getSeason(season);
        assertEq(stored.price, price);
        assertEq(stored.opensAt, opensAt);
        assertEq(stored.closesAt, closesAt);
        assertEq(stored.burnBps, burnBps);
        assertEq(stored.fallbackItem, fallbackItem);
        assertFalse(stored.closed);
        assertFalse(stored.cancelled);
        OGClubBox.Entry[] memory read = box.getEntries(season);
        assertEq(read.length, entryCount);
        for (uint256 i; i < entryCount; ++i) {
            assertEq(read[i].itemId, entries[i].itemId);
            assertEq(read[i].tier, entries[i].tier);
            assertEq(read[i].weight, entries[i].weight);
            assertEq(read[i].cap, entries[i].cap);
            assertEq(box.minted(season, entries[i].itemId), 0);
        }
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_TenPackBoxNineIsRareExactlyWhenARareRemains(bytes32 entropy, uint8 capA, uint8 capB) public {
        OGClubBox.Entry[] memory entries = new OGClubBox.Entry[](4);
        entries[0] = OGClubBox.Entry(1, 0, 50, 0);
        entries[1] = OGClubBox.Entry(2, 1, 30, 0);
        entries[2] = OGClubBox.Entry(3, 2, 40, bound(capA, 1, 6));
        entries[3] = OGClubBox.Entry(4, 4, 40, bound(capB, 1, 6));
        uint256 season = box.createSeason(1, 1000, 100_000, 0, 1, entries);
        for (uint256 round; round < 4; ++round) {
            vm.prank(buyer);
            uint256 purchase = box.buy(season, 10);
            bytes32 randao = keccak256(abi.encode(entropy, round));
            bytes memory header = ready(purchase, randao);
            uint256[] memory expected = box.previewOpen(purchase, randao);
            uint256 rareLeft;
            for (uint256 j = 2; j < 4; ++j) {
                uint256 used = box.minted(season, entries[j].itemId);
                for (uint256 i; i < 9; ++i) {
                    if (expected[i] == entries[j].itemId) ++used;
                }
                assertLe(used, entries[j].cap, "pack pre-roll exceeded a cap");
                rareLeft += entries[j].cap - used;
            }
            bool isRare = expected[9] == 3 || expected[9] == 4;
            assertEq(isRare, rareLeft > 0, "box 9 must be rare exactly when a rare is still available");
            assertOpenMatches(purchase, randao, header, false);
        }
        assertLe(box.minted(season, 3), entries[2].cap);
        assertLe(box.minted(season, 4), entries[3].cap);
    }

    function test_OpeningOrderIsFreeButCapsStillHold() public {
        OGClubBox.Entry[] memory entries = new OGClubBox.Entry[](2);
        entries[0] = OGClubBox.Entry(1, 0, 1, 0);
        entries[1] = OGClubBox.Entry(3, 4, 1e30, 1);
        uint256 season = box.createSeason(1, 1000, 100_000, 0, 1, entries);
        vm.prank(buyer);
        uint256 first = box.buy(season, 1);
        vm.prank(stranger);
        token.mint(stranger, 10);
        vm.prank(stranger);
        token.approve(address(box), 10);
        vm.prank(stranger);
        uint256 second = box.buy(season, 1);
        bytes32 randao = keccak256("ordering");
        bytes memory header = ready(first, randao);
        // Both previews, taken now, promise the single legendary; only the one opened first gets it.
        assertEq(box.previewOpen(first, randao)[0], 3);
        assertEq(box.previewOpen(second, randao)[0], 3);
        assertOpenMatches(second, randao, header, false);
        assertEq(box.previewOpen(first, randao)[0], 1);
        assertOpenMatches(first, randao, header, false);
        assertEq(box.minted(season, 3), 1);
        assertEq(furniture.balanceOf(stranger, 3), 1);
        assertEq(furniture.balanceOf(buyer, 3), 0);
        assertEq(furniture.balanceOf(buyer, 1), 1);
    }

    // ---------------------------------------------------------------- buyers and identity

    function test_BuyerCanOpenTheirOwnPurchase() public {
        uint256 purchase = buy(2);
        bytes32 randao = keccak256("self open");
        bytes memory header = ready(purchase, randao);
        uint256[] memory expected = box.previewOpen(purchase, randao);
        vm.prank(buyer);
        box.open(purchase, header);
        for (uint256 i; i < expected.length; ++i) {
            assertGt(furniture.balanceOf(buyer, expected[i]), 0);
        }
        (,,,, bool opened) = box.purchases(purchase);
        assertTrue(opened);
        assertEq(token.balanceOf(address(box)), 0);
    }

    function test_InsufficientBalanceRevertsWithoutRecordingPurchase() public {
        address poor = makeAddr("poor");
        token.mint(poor, 100); // price is 101
        vm.prank(poor);
        token.approve(address(box), type(uint256).max);
        vm.prank(poor);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, poor, 100 - 33, 68));
        box.buy(seasonId, 1);
        assertEq(box.purchaseCount(), 0);
        assertEq(token.balanceOf(poor), 100);
        assertEq(token.balanceOf(box.BURN_ADDRESS()), 0);
    }

    function test_ContractBuyerWithoutReceiverOpensAndCanRedirectDelivery() public {
        DeafBuyer deaf = new DeafBuyer();
        token.mint(address(deaf), 1000);
        vm.prank(address(deaf));
        token.approve(address(box), type(uint256).max);
        uint256 purchase = deaf.buy(box, seasonId, 3);
        assertEq(token.balanceOf(address(deaf)), 1000 - 303);
        bytes32 randao = keccak256("deaf");
        bytes memory header = ready(purchase, randao);
        uint256[] memory expected = box.previewOpen(purchase, randao);
        vm.expectEmit(true, false, false, true, address(box));
        emit DeliveryFailed(purchase);
        box.open(purchase, header);
        (,,,, bool opened) = box.purchases(purchase);
        assertTrue(opened);
        assertFalse(box.delivered(purchase));
        assertEq(furniture.totalSupply(), 0);
        assertEq(box.getStoredItems(purchase), expected);
        for (uint256 i; i < 2; ++i) {
            if (i == 1) vm.roll(target(purchase) + 300);
            vm.expectRevert(abi.encodeWithSelector(IERC1155Errors.ERC1155InvalidReceiver.selector, address(deaf)));
            box.deliver(purchase);
            assertFalse(box.delivered(purchase));
            assertEq(box.getStoredItems(purchase), expected);
        }
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(OGClubBox.NotBuyer.selector, purchase));
        box.deliverTo(purchase, stranger);
        vm.expectRevert(OGClubBox.InvalidAddress.selector);
        deaf.deliverTo(box, purchase, address(0));
        vm.expectEmit(true, true, false, true, address(box));
        emit Delivered(purchase, buyer);
        deaf.deliverTo(box, purchase, buyer);
        assertTrue(box.delivered(purchase));
        assertEq(box.getStoredItems(purchase).length, 0);
        assertEq(furniture.totalSupply(), 3);
        for (uint256 id = 1; id <= 3; ++id) {
            uint256 received;
            for (uint256 i; i < expected.length; ++i) {
                if (expected[i] == id) ++received;
            }
            assertEq(furniture.balanceOf(buyer, id), received);
            assertEq(box.minted(seasonId, id), received);
            assertEq(furniture.balanceOf(address(deaf), id), 0);
        }
        vm.expectRevert(abi.encodeWithSelector(OGClubBox.AlreadyDelivered.selector, purchase));
        deaf.deliverTo(box, purchase, buyer);
        assertEq(token.balanceOf(address(box)), 0);
    }

    event DeliveryFailed(uint256 indexed purchaseId);
    event Delivered(uint256 indexed purchaseId, address indexed to);

    function test_PurchasesInTheSameBlockShareTheTargetAndHeader() public {
        uint256 a = buy(10);
        token.mint(stranger, 10_000);
        vm.prank(stranger);
        token.approve(address(box), type(uint256).max);
        vm.prank(stranger);
        uint256 b = box.buy(seasonId, 10);
        assertEq(target(a), target(b));
        bytes32 randao = keccak256("shared block");
        bytes memory header = ready(a, randao);
        uint256[] memory previewA = box.previewOpen(a, randao);
        uint256[] memory previewB = box.previewOpen(b, randao);
        // Same randao, different purchase ids: the per-box seeds differ, so the packs are not copies.
        assertNotEq(keccak256(abi.encode(previewA)), keccak256(abi.encode(previewB)));
        assertOpenMatches(a, randao, header, false);
        assertOpenMatches(b, randao, header, false);
    }

    // ---------------------------------------------------------------- expiry boundaries

    function test_ExpiryIsMeasuredFromTargetNotFromPurchase() public {
        uint256 purchase = buy(10);
        uint256 targetBlock = target(purchase);
        bytes32 randao = keccak256("boundary");
        bytes memory header = HeaderBuilder.header(targetBlock, randao, 7);
        vm.roll(targetBlock + 256);
        vm.setBlockhash(targetBlock, keccak256(header));
        uint256[] memory live = box.previewOpen(purchase, randao);
        bool allFallback = true;
        for (uint256 i; i < live.length; ++i) {
            if (live[i] != 1) allFallback = false;
        }
        assertFalse(allFallback, "a live preview with this randao must not be all fallback");
        vm.roll(targetBlock + 257);
        live = box.previewOpen(purchase, randao);
        for (uint256 i; i < live.length; ++i) {
            assertEq(live[i], 1);
        }
        // A perfectly valid header is ignored once expired: only fallbacks and tier 0 are emitted.
        assertOpenMatches(purchase, randao, header, true);
    }

    function test_ExpiredOpenStillRespectsReentrancyAndOnlyMintsFallback() public {
        uint256 purchase = buy(10);
        vm.roll(target(purchase) + 1000);
        vm.prank(stranger);
        box.open(purchase, "");
        assertEq(furniture.balanceOf(buyer, 1), 10);
        assertEq(furniture.balanceOf(buyer, 2), 0);
        assertEq(furniture.balanceOf(buyer, 3), 0);
        assertEq(box.minted(seasonId, 1), 10);
        vm.expectRevert(abi.encodeWithSelector(OGClubBox.AlreadyOpened.selector, purchase));
        box.open(purchase, "");
    }

    // ---------------------------------------------------------------- RLP shapes

    function test_ListShapedTrailingFieldsAcceptedButListAtNumberOrMixHashRejected() public {
        HeaderHarness2 harness = new HeaderHarness2();
        bytes[] memory fields = HeaderBuilder.fields(12345, keccak256("mix"), 0);
        bytes memory nested = HeaderBuilder.list(new bytes[](2));
        // Append a list item after the fourteen standard fields.
        bytes memory payload;
        for (uint256 i; i < fields.length; ++i) {
            payload = bytes.concat(payload, HeaderBuilder.stringRLP(fields[i]));
        }
        payload = bytes.concat(payload, nested);
        bytes memory header = bytes.concat(HeaderBuilder.prefix(payload.length, 0xc0), payload);
        (uint256 number, bytes32 randao) = harness.decode(header);
        assertEq(number, 12345);
        assertEq(randao, keccak256("mix"));

        // A list where the number must be.
        payload = "";
        for (uint256 i; i < fields.length; ++i) {
            payload = bytes.concat(payload, i == 8 ? nested : HeaderBuilder.stringRLP(fields[i]));
        }
        header = bytes.concat(HeaderBuilder.prefix(payload.length, 0xc0), payload);
        vm.expectRevert(BlockHeader.InvalidHeaderFields.selector);
        harness.decode(header);

        // A 32-byte list where the mixHash must be.
        bytes[] memory thirty = new bytes[](30);
        payload = "";
        for (uint256 i; i < fields.length; ++i) {
            payload = bytes.concat(payload, i == 13 ? HeaderBuilder.list(thirty) : HeaderBuilder.stringRLP(fields[i]));
        }
        header = bytes.concat(HeaderBuilder.prefix(payload.length, 0xc0), payload);
        vm.expectRevert(BlockHeader.InvalidHeaderFields.selector);
        harness.decode(header);
    }

    function test_NumberFieldOfThirtyTwoBytesAndSingleByteAreCanonical() public {
        HeaderHarness2 harness = new HeaderHarness2();
        (uint256 number,) = harness.decode(HeaderBuilder.header(type(uint256).max, bytes32(0), 3));
        assertEq(number, type(uint256).max);
        (number,) = harness.decode(HeaderBuilder.header(0x7f, bytes32(0), 3));
        assertEq(number, 0x7f);
        (number,) = harness.decode(HeaderBuilder.header(0x80, bytes32(0), 3));
        assertEq(number, 0x80);
    }

    // ---------------------------------------------------------------- events for indexers

    function test_SeasonLifecycleEventsAreEmittedExactly() public {
        OGClubBox.Entry[] memory entries = defaultEntries();
        uint256 next = box.seasonCount() + 1;
        vm.expectEmit(true, true, true, true, address(box));
        emit SeasonCreated(next, 55, 5000, 6000, 1234, 1);
        for (uint256 i; i < entries.length; ++i) {
            vm.expectEmit(true, true, true, true, address(box));
            emit SeasonEntry(next, entries[i].itemId, entries[i].tier, entries[i].weight, entries[i].cap);
        }
        uint256 created = box.createSeason(55, 5000, 6000, 1234, 1, entries);
        assertEq(created, next);

        vm.expectEmit(true, true, true, true, address(box));
        emit SeasonCancelled(created);
        box.cancelSeason(created);

        vm.expectEmit(true, true, true, true, address(box));
        emit SeasonClosed(seasonId);
        box.closeSeason(seasonId);

        vm.expectEmit(true, true, true, true, address(box));
        emit PausedSet(true);
        box.setPaused(true);

        address next2 = makeAddr("vault 2");
        vm.expectEmit(true, true, true, true, address(box));
        emit VaultSet(vault, next2);
        box.setVault(next2);
        assertEq(box.vault(), next2);
    }

    function test_CloseIsAllowedBeforeOpeningAndCancelIsNotAfterClose() public {
        uint256 later = box.createSeason(1, 5000, 6000, 0, 1, defaultEntries());
        box.closeSeason(later);
        OGClubBox.Season memory s = box.getSeason(later);
        assertTrue(s.closed);
        assertFalse(s.cancelled);
        vm.expectRevert(abi.encodeWithSelector(OGClubBox.SeasonAlreadyClosed.selector, later));
        box.cancelSeason(later);
        vm.warp(5000);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(OGClubBox.SalesUnavailable.selector, later));
        box.buy(later, 1);
    }

    function test_PauseDoesNotBlockOwnerActionsOrViews() public {
        uint256 purchase = buy(1);
        box.setPaused(true);
        uint256 created = box.createSeason(1, 5000, 6000, 0, 1, defaultEntries());
        box.closeSeason(created);
        box.setVault(makeAddr("v"));
        bytes32 randao = keccak256("paused views");
        bytes memory header = ready(purchase, randao);
        box.previewOpen(purchase, randao);
        box.getSeason(seasonId);
        box.getEntries(seasonId);
        assertOpenMatches(purchase, randao, header, false);
        box.setPaused(false);
        buy(1);
    }
}
