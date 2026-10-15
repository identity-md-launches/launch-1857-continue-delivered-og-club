// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BoxTestBase} from "./helpers/BoxTestBase.sol";
import {HostileDeliveryBuyer, ReentrantBuyer, RetryOnlyBuyer} from "./helpers/Adversaries.sol";
import {OGClubBox} from "../src/OGClubBox.sol";
import {OGClubFurniture} from "../src/OGClubFurniture.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract DeliveryTest is BoxTestBase {
    event Delivered(uint256 indexed purchaseId, address indexed to);
    event DeliveryFailed(uint256 indexed purchaseId);

    function test_DeliveryChecksUnknownUnopenedAndAlreadyDelivered() public {
        vm.expectRevert(abi.encodeWithSelector(OGClubBox.UnknownPurchase.selector, 0));
        box.deliver(0);
        uint256 purchase = buy(1);
        vm.expectRevert(abi.encodeWithSelector(OGClubBox.NotOpened.selector, purchase));
        box.deliver(purchase);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(OGClubBox.NotOpened.selector, purchase));
        box.deliverTo(purchase, buyer);
        bytes memory header = ready(purchase, keccak256("delivered once"));
        vm.expectEmit(true, true, false, true, address(box));
        emit Delivered(purchase, buyer);
        box.open(purchase, header);
        assertTrue(box.delivered(purchase));
        assertEq(box.getStoredItems(purchase).length, 0);
        vm.expectRevert(abi.encodeWithSelector(OGClubBox.AlreadyDelivered.selector, purchase));
        box.deliver(purchase);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(OGClubBox.AlreadyDelivered.selector, purchase));
        box.deliverTo(purchase, stranger);
        assertFalse(box.delivered(0));
        assertEq(box.getStoredItems(0).length, 0);
        assertEq(furniture.totalSupply(), 1);
    }

    function testFuzz_FirstDeliveryRejectionThenAnyoneCanRetryOnlyOnce(uint8 count) public {
        count = uint8(bound(count, 1, 10));
        RetryOnlyBuyer receiver = new RetryOnlyBuyer();
        token.mint(address(receiver), 10_000);
        uint256 purchase = receiver.buy(box, token, seasonId, count);
        bytes32 randao = keccak256("first delivery only");
        bytes memory header = ready(purchase, randao);
        uint256[] memory expected = box.previewOpen(purchase, randao);
        vm.expectEmit(true, false, false, true, address(box));
        emit DeliveryFailed(purchase);
        box.open(purchase, header);
        assertFalse(box.delivered(purchase));
        assertEq(box.getStoredItems(purchase), expected);
        assertEq(receiver.accepted(), 0);
        vm.prank(stranger);
        box.deliver(purchase);
        assertTrue(box.delivered(purchase));
        assertEq(receiver.accepted(), 1);
        for (uint256 id = 1; id <= 3; ++id) {
            uint256 received;
            for (uint256 i; i < expected.length; ++i) {
                if (expected[i] == id) ++received;
            }
            assertEq(furniture.balanceOf(address(receiver), id), received);
        }
        vm.expectRevert(abi.encodeWithSelector(OGClubBox.AlreadyDelivered.selector, purchase));
        box.deliver(purchase);
        assertEq(receiver.accepted(), 1);
        assertEq(furniture.totalSupply(), count);
    }

    function test_ExpiredUnopenedPurchaseStillRecordsOnlyFallbacksWhenDeliveryFails() public {
        uint256 purchase = buy(10);
        furniture.revokeMinter(address(box));
        vm.roll(target(purchase) + 257);
        uint256[] memory expected = box.previewOpen(purchase, bytes32(0));
        vm.recordLogs();
        box.open(purchase, "ignored");
        checkOpenLogs(purchase, expected, bytes32(0), true);
        assertEq(box.getStoredItems(purchase), expected);
        for (uint256 i; i < expected.length; ++i) {
            assertEq(expected[i], 1);
        }
        assertEq(box.minted(seasonId, 1), 10);
        // Re-authorizing the box is a seven-day proposal even though nothing has been minted yet.
        regrantBox();
        box.deliver(purchase);
        assertEq(furniture.balanceOf(buyer, 1), 10);
        assertTrue(box.delivered(purchase));
    }

    function test_OwnerCannotMintCappedPieceWithinSevenDaysOfProposal() public {
        OGClubBox.Entry[] memory entries = new OGClubBox.Entry[](2);
        entries[0] = OGClubBox.Entry(1, 0, 1, 0);
        entries[1] = OGClubBox.Entry(2, 4, 1, 1);
        seasonId = box.createSeason(1, 1000, 100_000, 0, 1, entries);
        uint256 purchase = buy(10);
        box.open(purchase, ready(purchase, keccak256("capped")));
        assertEq(box.minted(seasonId, 2), 1);
        assertEq(furniture.totalSupply(2), 1);
        furniture.grantMinter(address(this));
        uint256 deadline = furniture.pendingMinters(address(this));
        uint256[] memory ids = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        ids[0] = 2;
        amounts[0] = 100;
        vm.expectRevert(abi.encodeWithSelector(OGClubFurniture.NotMinter.selector, address(this)));
        furniture.mintBatch(buyer, ids, amounts);
        vm.warp(deadline - 1);
        vm.expectRevert(abi.encodeWithSelector(OGClubFurniture.MinterDelayNotElapsed.selector, address(this), deadline));
        furniture.activateMinter(address(this));
        vm.expectRevert(abi.encodeWithSelector(OGClubFurniture.NotMinter.selector, address(this)));
        furniture.mintBatch(buyer, ids, amounts);
        assertEq(furniture.totalSupply(2), 1);
    }

    function test_RedirectedDeliveryRejectsReentryAndMarksDeliveredBeforeCallback() public {
        ReentrantBuyer receiver = new ReentrantBuyer(box, token, seasonId);
        token.mint(address(receiver), 10_000);
        uint256 purchase = receiver.buy(1);
        bytes memory header = ready(purchase, keccak256("redirect reentry"));
        receiver.configure(header, true);
        box.open(purchase, header);
        receiver.configure(header, false);
        vm.prank(address(receiver));
        box.deliverTo(purchase, address(receiver));
        assertTrue(receiver.sawOpened());
        assertTrue(receiver.sawDelivered());
        assertFalse(receiver.openSucceeded());
        assertFalse(receiver.otherOpenSucceeded());
        assertFalse(receiver.buySucceeded());
        assertFalse(receiver.deliverSucceeded());
        assertFalse(receiver.deliverToSucceeded());
        assertFalse(receiver.otherDeliverSucceeded());
        assertEq(receiver.deliverError(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(receiver.deliverToError(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(furniture.totalSupply(), 1);
    }

    function test_HostileReceiverCannotVetoTenDistinctRolledItems() public {
        // Ten distinct nonzero IDs is the most expensive failure path to store.
        OGClubBox.Entry[] memory entries = new OGClubBox.Entry[](32);
        for (uint256 i; i < entries.length; ++i) {
            entries[i] = OGClubBox.Entry(i + 1, i == 0 ? 0 : 2, 1, 0);
        }
        seasonId = box.createSeason(1, 1000, 100_000, 0, 1, entries);
        HostileDeliveryBuyer receiver = new HostileDeliveryBuyer();
        token.mint(address(receiver), 100);
        for (uint8 mode = 1; mode <= 2; ++mode) {
            uint256 purchase = receiver.buy(box, token, seasonId, 10);
            bytes32 randao = distinctRandao(purchase);
            bytes memory header = ready(purchase, randao);
            uint256[] memory expected = box.previewOpen(purchase, randao);
            receiver.setMode(mode);
            vm.expectEmit(true, false, false, true, address(box));
            emit DeliveryFailed(purchase);
            // OpenGas.t.sol checks the reserve at the exact gas boundary; this checks the receiver cannot veto.
            box.open(purchase, header);
            (,,,, bool opened) = box.purchases(purchase);
            assertTrue(opened);
            assertFalse(box.delivered(purchase));
            assertEq(box.getStoredItems(purchase), expected);
            assertEq(furniture.totalSupply(), (mode - 1) * 10);
            vm.roll(target(purchase) + 300);
            receiver.deliverTo(box, purchase, buyer);
            assertTrue(box.delivered(purchase));
            assertEq(box.getStoredItems(purchase).length, 0);
            for (uint256 id = 1; id <= 32; ++id) {
                assertEq(furniture.balanceOf(buyer, id), box.minted(seasonId, id));
            }
        }
        assertEq(furniture.totalSupply(), 20);
    }

    function distinctRandao(uint256 purchase) internal view returns (bytes32 randao) {
        for (uint256 n; n < 10_000; ++n) {
            randao = keccak256(abi.encode("distinct delivery", n));
            uint256 seen;
            bool distinct = true;
            for (uint256 i; i < 10; ++i) {
                uint256 seed = uint256(keccak256(abi.encode(randao, block.chainid, address(box), purchase, i)));
                uint256 id = i == 9 ? 2 + seed % 31 : 1 + seed % 32;
                if (seen & (1 << id) != 0) {
                    distinct = false;
                    break;
                }
                seen |= 1 << id;
            }
            if (distinct) return randao;
        }
        revert("no distinct roll found");
    }

    function test_ZeroItemIdAndDuplicateStoredItemsDeliverExactlyOnce() public {
        OGClubBox.Entry[] memory entries = new OGClubBox.Entry[](1);
        entries[0] = OGClubBox.Entry(0, 0, 1, 0);
        seasonId = box.createSeason(1, 1000, 100_000, 0, 0, entries);
        uint256 purchase = buy(10);
        furniture.revokeMinter(address(box));
        box.open(purchase, ready(purchase, bytes32(0)));
        assertEq(box.getStoredItems(purchase), new uint256[](10));
        regrantBox();
        box.deliver(purchase);
        assertEq(furniture.balanceOf(buyer, 0), 10);
        assertEq(box.minted(seasonId, 0), 10);
        vm.expectRevert(abi.encodeWithSelector(OGClubBox.AlreadyDelivered.selector, purchase));
        box.deliver(purchase);
    }
}
