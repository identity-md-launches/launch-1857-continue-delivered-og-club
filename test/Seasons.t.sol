// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BoxTestBase} from "./helpers/BoxTestBase.sol";
import {OGClubBox} from "../src/OGClubBox.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract SeasonsTest is BoxTestBase {
    function test_BuyWindowCountPauseAndClose() public {
        vm.warp(999);
        vm.expectRevert(abi.encodeWithSelector(OGClubBox.SalesUnavailable.selector, seasonId));
        buy(1);
        vm.warp(1000);
        buy(1);
        vm.expectRevert(OGClubBox.InvalidCount.selector);
        buy(0);
        vm.expectRevert(OGClubBox.InvalidCount.selector);
        buy(11);
        box.setPaused(true);
        vm.expectRevert(OGClubBox.BuyingPaused.selector);
        buy(1);
        box.setPaused(false);
        vm.warp(99_999);
        buy(1);
        vm.warp(100_000);
        vm.expectRevert(abi.encodeWithSelector(OGClubBox.SalesUnavailable.selector, seasonId));
        buy(1);
        vm.warp(100_001);
        vm.expectRevert(abi.encodeWithSelector(OGClubBox.SalesUnavailable.selector, seasonId));
        buy(1);
        vm.warp(1000);
        box.closeSeason(seasonId);
        vm.expectRevert(abi.encodeWithSelector(OGClubBox.SalesUnavailable.selector, seasonId));
        buy(1);
        vm.expectRevert(abi.encodeWithSelector(OGClubBox.SeasonAlreadyClosed.selector, seasonId));
        box.closeSeason(seasonId);
    }

    function test_UnknownSeasonCannotBeUsed() public {
        for (uint256 id; id <= 2; id += 2) {
            bytes memory err = abi.encodeWithSelector(OGClubBox.UnknownSeason.selector, id);
            vm.expectRevert(err);
            box.buy(id, 1);
            vm.expectRevert(err);
            box.closeSeason(id);
            vm.expectRevert(err);
            box.cancelSeason(id);
            vm.expectRevert(err);
            box.getSeason(id);
            vm.expectRevert(err);
            box.getEntries(id);
        }
    }

    function test_CreateValidation() public {
        OGClubBox.Entry[] memory entries = defaultEntries();
        vm.expectRevert(OGClubBox.InvalidEntryCount.selector);
        box.createSeason(1, 1000, 2000, 0, 1, new OGClubBox.Entry[](0));
        vm.expectRevert(OGClubBox.InvalidEntryCount.selector);
        box.createSeason(1, 1000, 2000, 0, 1, new OGClubBox.Entry[](33));
        vm.expectRevert(OGClubBox.InvalidSeasonParameters.selector);
        box.createSeason(0, 1000, 2000, 0, 1, entries);
        vm.expectRevert(OGClubBox.InvalidSeasonParameters.selector);
        box.createSeason(1, 2000, 2000, 0, 1, entries);
        vm.expectRevert(OGClubBox.InvalidSeasonParameters.selector);
        box.createSeason(1, 3000, 2000, 0, 1, entries);
        vm.expectRevert(OGClubBox.InvalidSeasonParameters.selector);
        box.createSeason(1, 1000, 2000, 10_001, 1, entries);
        entries[1].tier = 5;
        vm.expectRevert(abi.encodeWithSelector(OGClubBox.InvalidEntry.selector, 1));
        box.createSeason(1, 1000, 2000, 0, 1, entries);
        entries = defaultEntries();
        entries[1].weight = 0;
        vm.expectRevert(abi.encodeWithSelector(OGClubBox.InvalidEntry.selector, 1));
        box.createSeason(1, 1000, 2000, 0, 1, entries);
        entries = defaultEntries();
        entries[1].itemId = 1;
        vm.expectRevert(abi.encodeWithSelector(OGClubBox.DuplicateItem.selector, 1));
        box.createSeason(1, 1000, 2000, 0, 1, entries);
        entries = defaultEntries();
        vm.expectRevert(OGClubBox.InvalidFallback.selector);
        box.createSeason(1, 1000, 2000, 0, 99, entries);
        entries[0].cap = 1;
        vm.expectRevert(OGClubBox.InvalidFallback.selector);
        box.createSeason(1, 1000, 2000, 0, 1, entries);
        entries[1].cap = 0; // An unlimited non-fallback does not make a capped fallback valid.
        vm.expectRevert(OGClubBox.InvalidFallback.selector);
        box.createSeason(1, 1000, 2000, 0, 1, entries);
        entries = defaultEntries();
        entries[0].tier = 1;
        vm.expectRevert(OGClubBox.InvalidFallback.selector);
        box.createSeason(1, 1000, 2000, 0, 1, entries);
        entries = defaultEntries();
        entries[0].weight = type(uint256).max;
        vm.expectRevert(OGClubBox.WeightOverflow.selector);
        box.createSeason(1, 1000, 2000, 0, 1, entries);
        entries[0].weight = box.MAX_TOTAL_WEIGHT(); // Plus the other two weights exceeds the bound.
        vm.expectRevert(OGClubBox.WeightOverflow.selector);
        box.createSeason(1, 1000, 2000, 0, 1, entries);
        assertEq(box.seasonCount(), 1);
        entries[0].weight = box.MAX_TOTAL_WEIGHT() - 40; // Sums to exactly the bound.
        uint256 wide = box.createSeason(1, 1000, 100_000, 0, 1, entries);
        assertEq(box.seasonCount(), 2);
        vm.prank(buyer);
        uint256 purchase = box.buy(wide, 10);
        bytes32 randao = keccak256("widest weights");
        bytes memory header = ready(purchase, randao);
        assertOpenMatches(purchase, randao, header, false);
    }

    function test_BuyRequiresTheBoxToBeAnAuthorizedMinter() public {
        furniture.revokeMinter(address(box));
        uint256 beforeBuyer = token.balanceOf(buyer);
        vm.expectRevert(OGClubBox.BoxNotMinter.selector);
        buy(1);
        assertEq(token.balanceOf(buyer), beforeBuyer);
        assertEq(token.balanceOf(vault), 0);
        assertEq(token.balanceOf(box.BURN_ADDRESS()), 0);
        assertEq(box.purchaseCount(), 0);
        // The bootstrap grant was spent at deployment: re-granting the box is a seven-day proposal.
        regrantBox();
        uint256 reopened = box.createSeason(101, block.timestamp, block.timestamp + 1 days, 3333, 1, defaultEntries());
        vm.prank(buyer);
        box.buy(reopened, 1);
        assertEq(box.purchaseCount(), 1);
    }

    /// @dev Season notice 0 (the test-network value): a season may open in the very block it is created and
    ///      sells at once, exactly as before the notice existed; only a backdated opensAt is refused.
    function test_ZeroNoticeSeasonOpensAtOnce() public {
        assertEq(box.seasonNotice(), 0);
        uint256 now_ = block.timestamp;
        vm.expectRevert(abi.encodeWithSelector(OGClubBox.SeasonOpensTooSoon.selector, now_ - 1, now_));
        box.createSeason(1, now_ - 1, now_ + 1 days, 0, 1, defaultEntries());
        uint256 instant = box.createSeason(1, now_, now_ + 1 days, 0, 1, defaultEntries());
        assertEq(box.getSeason(instant).opensAt, now_);
        vm.prank(buyer);
        uint256 purchase = box.buy(instant, 10);
        bytes32 randao = keccak256("zero notice");
        bytes memory header = ready(purchase, randao);
        assertOpenMatches(purchase, randao, header, false);
    }

    function test_MaximumEntryCountAndIdZeroSupported() public {
        OGClubBox.Entry[] memory entries = new OGClubBox.Entry[](32);
        for (uint256 i; i < 32; ++i) {
            entries[i] = OGClubBox.Entry(i, uint8(i % 5), i + 1, 0);
        }
        uint256 id = box.createSeason(1, 1000, 100_000, 0, 0, entries);
        assertEq(box.getEntries(id).length, 32);
        vm.prank(buyer);
        uint256 purchase = box.buy(id, 10);
        bytes32 randao = keccak256("32 entries");
        bytes memory header = ready(purchase, randao);
        assertOpenMatches(purchase, randao, header, false);
    }

    function test_CancelOnlyBeforeOpeningAndTerminal() public {
        uint256 next = box.createSeason(1, 2000, 3000, 0, 1, defaultEntries());
        box.cancelSeason(next);
        OGClubBox.Season memory cancelled = box.getSeason(next);
        assertTrue(cancelled.closed);
        assertTrue(cancelled.cancelled);
        vm.expectRevert(abi.encodeWithSelector(OGClubBox.SeasonAlreadyClosed.selector, next));
        box.cancelSeason(next);
        vm.expectRevert(abi.encodeWithSelector(OGClubBox.SeasonAlreadyClosed.selector, next));
        box.closeSeason(next);
        vm.warp(2000);
        vm.expectRevert(abi.encodeWithSelector(OGClubBox.SalesUnavailable.selector, next));
        box.buy(next, 1);
        vm.expectRevert(abi.encodeWithSelector(OGClubBox.SeasonAlreadyStarted.selector, seasonId));
        box.cancelSeason(seasonId);
        uint256 later = box.createSeason(1, 3000, 4000, 0, 1, defaultEntries());
        vm.warp(3000);
        vm.expectRevert(abi.encodeWithSelector(OGClubBox.SeasonAlreadyStarted.selector, later));
        box.cancelSeason(later);
    }

    function test_OverlappingSeasonsIndependentAndTermsUnchanged() public {
        uint256 second = box.createSeason(27, 1000, 2000, 1000, 1, defaultEntries());
        bytes32 beforeTerms = keccak256(abi.encode(box.getSeason(seasonId), box.getEntries(seasonId)));
        uint256 firstPurchase = buy(10);
        vm.prank(buyer);
        uint256 secondPurchase = box.buy(second, 10);
        bytes32 randao = keccak256("overlap");
        bytes memory header = ready(firstPurchase, randao);
        assertOpenMatches(firstPurchase, randao, header, false);
        assertOpenMatches(secondPurchase, randao, header, false);
        assertEq(beforeTerms, keccak256(abi.encode(box.getSeason(seasonId), box.getEntries(seasonId))));
        uint256 capCount = box.minted(seasonId, 3) + box.minted(second, 3);
        assertEq(furniture.totalSupply(3), capCount);
        box.closeSeason(seasonId);
        vm.prank(buyer);
        box.buy(second, 1);
    }

    function test_AllOwnerFunctionsProtected() public {
        bytes[] memory calls = new bytes[](7);
        calls[0] = abi.encodeCall(box.createSeason, (1, 1000, 2000, 0, 1, defaultEntries()));
        calls[1] = abi.encodeCall(box.closeSeason, (seasonId));
        calls[2] = abi.encodeCall(box.cancelSeason, (seasonId));
        calls[3] = abi.encodeCall(box.setPaused, (true));
        calls[4] = abi.encodeCall(box.setVault, (buyer));
        calls[5] = abi.encodeCall(box.transferOwnership, (buyer));
        calls[6] = abi.encodeCall(box.renounceOwnership, ());
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(stranger);
            (bool success, bytes memory reason) = address(box).call(calls[i]);
            assertFalse(success);
            assertEq(reason, abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        }
    }

    function test_OwnershipRequiresAcceptanceAndCanCancelPending() public {
        box.transferOwnership(buyer);
        assertEq(box.owner(), address(this));
        assertEq(box.pendingOwner(), buyer);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, buyer));
        box.setPaused(true);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        box.acceptOwnership();
        box.transferOwnership(address(0));
        assertEq(box.owner(), address(this));
        assertEq(box.pendingOwner(), address(0));
        box.transferOwnership(buyer);
        vm.prank(buyer);
        box.acceptOwnership();
        assertEq(box.owner(), buyer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        box.setPaused(true);
        vm.prank(buyer);
        box.setPaused(true);
        assertTrue(box.paused());
        vm.prank(buyer);
        box.renounceOwnership();
        assertEq(box.owner(), address(0));
    }
}
