// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {OGClubFurniture} from "../src/OGClubFurniture.sol";
import {OGClubBox} from "../src/OGClubBox.sol";
import {MockOG} from "../src/mocks/MockOG.sol";
import {HeaderBuilder} from "./helpers/HeaderBuilder.sol";

/// @notice The season notice: a box deployed with a nonzero `seasonNotice` refuses any season that opens
///         before `block.timestamp + seasonNotice`, so the owner cannot rig an instant season to mint a
///         capped piece without public notice. Everything else about seasons is unchanged.
contract SeasonNoticeTest is Test, ERC1155Holder {
    uint256 internal constant NOTICE = 7 days;
    uint256 internal constant CAPPED_ID = 3;

    MockOG internal token;
    OGClubFurniture internal furniture;
    OGClubBox internal box;
    address internal vault = makeAddr("vault");
    address internal buyer = makeAddr("buyer");
    address internal stranger = makeAddr("stranger");

    event SeasonCreated(
        uint256 indexed seasonId,
        uint256 price,
        uint256 opensAt,
        uint256 closesAt,
        uint256 burnBps,
        uint256 fallbackItem
    );

    function setUp() public {
        vm.roll(100);
        vm.warp(1_000_000);
        token = new MockOG(address(this));
        furniture = new OGClubFurniture(address(this), vault);
        box = new OGClubBox(token, furniture, vault, address(this), NOTICE);
        furniture.grantMinter(address(box)); // The one immediate grant, right after deployment.
        token.approve(address(box), type(uint256).max);
        token.mint(buyer, 1_000_000 ether);
        vm.prank(buyer);
        token.approve(address(box), type(uint256).max);
    }

    function entries() internal pure returns (OGClubBox.Entry[] memory list) {
        list = new OGClubBox.Entry[](3);
        list[0] = OGClubBox.Entry(1, 0, 60, 0);
        list[1] = OGClubBox.Entry(2, 1, 30, 4);
        list[2] = OGClubBox.Entry(CAPPED_ID, 4, 10, 1);
    }

    function test_NoticeIsExposedAndImmutable() public view {
        assertEq(box.seasonNotice(), NOTICE);
        assertEq(box.MAX_SEASON_NOTICE(), 30 days);
    }

    /// @dev One second short of the notice reverts with the earliest allowed opening; exactly the notice succeeds.
    function test_CreateSeasonRevertsBeforeTheNoticeAndSucceedsExactlyAtIt() public {
        uint256 now_ = block.timestamp;
        uint256 earliest = now_ + NOTICE;
        vm.expectRevert(abi.encodeWithSelector(OGClubBox.SeasonOpensTooSoon.selector, now_, earliest));
        box.createSeason(1, now_, now_ + 30 days, 0, 1, entries());
        vm.expectRevert(abi.encodeWithSelector(OGClubBox.SeasonOpensTooSoon.selector, earliest - 1, earliest));
        box.createSeason(1, earliest - 1, now_ + 30 days, 0, 1, entries());
        vm.expectRevert(abi.encodeWithSelector(OGClubBox.SeasonOpensTooSoon.selector, 0, earliest));
        box.createSeason(1, 0, now_ + 30 days, 0, 1, entries());
        assertEq(box.seasonCount(), 0);

        vm.expectEmit(true, false, false, true, address(box));
        emit SeasonCreated(1, 1, earliest, now_ + 30 days, 0, 1);
        uint256 season = box.createSeason(1, earliest, now_ + 30 days, 0, 1, entries());
        assertEq(season, 1);
        OGClubBox.Season memory terms = box.getSeason(season);
        assertEq(terms.opensAt, earliest);
        assertEq(terms.closesAt, now_ + 30 days);
        assertFalse(terms.closed);
        // Not for sale until it opens; for sale from the first second of its window.
        vm.warp(earliest - 1);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(OGClubBox.SalesUnavailable.selector, season));
        box.buy(season, 1);
        vm.warp(earliest);
        vm.prank(buyer);
        box.buy(season, 1);
        assertEq(box.purchaseCount(), 1);
    }

    /// @dev The notice is measured from the moment of creation, whatever that moment is.
    function testFuzz_NoticeBoundaryIsExactAtAnyTime(uint64 createdAt, uint32 early) public {
        createdAt = uint64(bound(createdAt, 1, type(uint64).max - 60 days));
        early = uint32(bound(early, 1, NOTICE));
        vm.warp(createdAt);
        uint256 earliest = uint256(createdAt) + NOTICE;
        vm.expectRevert(abi.encodeWithSelector(OGClubBox.SeasonOpensTooSoon.selector, earliest - early, earliest));
        box.createSeason(1, earliest - early, earliest + 1 days, 0, 1, entries());
        uint256 season = box.createSeason(1, earliest, earliest + 1 days, 0, 1, entries());
        assertEq(box.getSeason(season).opensAt, earliest);
        uint256 later = box.createSeason(1, earliest + early, earliest + early + 1, 0, 1, entries());
        assertEq(box.getSeason(later).opensAt, earliest + early);
    }

    /// @dev The notice is checked after the other parameter checks, so their errors still surface first.
    function test_OtherParameterErrorsStillComeFirst() public {
        uint256 now_ = block.timestamp;
        vm.expectRevert(OGClubBox.InvalidEntryCount.selector);
        box.createSeason(1, now_, now_ + 1, 0, 1, new OGClubBox.Entry[](0));
        vm.expectRevert(OGClubBox.InvalidSeasonParameters.selector);
        box.createSeason(0, now_, now_ + 1, 0, 1, entries());
        vm.expectRevert(OGClubBox.InvalidSeasonParameters.selector);
        box.createSeason(1, now_ + NOTICE, now_ + NOTICE, 0, 1, entries());
        vm.expectRevert(OGClubBox.InvalidSeasonParameters.selector);
        box.createSeason(1, now_, now_ + 1, 10_001, 1, entries());
        // A season that respects the notice is still subject to every entry rule.
        OGClubBox.Entry[] memory bad = entries();
        bad[0].tier = 1;
        vm.expectRevert(OGClubBox.InvalidFallback.selector);
        box.createSeason(1, now_ + NOTICE, now_ + 30 days, 0, 1, bad);
    }

    /// @dev The audit scenario. Season 1 sells the capped piece honestly. The owner then tries a 1-wei season
    ///      in which the capped piece is near-certain: it cannot open before the notice, and the owner cannot
    ///      buy from it, open anything or hold the piece until the notice has passed. Once it has, the season
    ///      sells like any other, with its terms public for the whole notice.
    function test_OwnerCannotMintCappedPieceThroughANewSeasonBeforeItsNotice() public {
        uint256 now_ = block.timestamp;
        uint256 honest = box.createSeason(100 ether, now_ + NOTICE, now_ + 60 days, 0, 1, entries());
        assertEq(honest, 1);

        OGClubBox.Entry[] memory rigged = new OGClubBox.Entry[](2);
        rigged[0] = OGClubBox.Entry(1, 0, 1, 0);
        rigged[1] = OGClubBox.Entry(CAPPED_ID, 4, (1 << 128) - 1, 1);
        vm.expectRevert(abi.encodeWithSelector(OGClubBox.SeasonOpensTooSoon.selector, now_, now_ + NOTICE));
        box.createSeason(1, now_, now_ + 1 days, 0, 1, rigged);
        vm.expectRevert(abi.encodeWithSelector(OGClubBox.SeasonOpensTooSoon.selector, now_ + NOTICE - 1, now_ + NOTICE));
        box.createSeason(1, now_ + NOTICE - 1, now_ + 1 days + NOTICE, 0, 1, rigged);
        assertEq(box.seasonCount(), 1);

        // The best the owner can do is announce it: it opens no earlier than the notice from now.
        uint256 riggedSeason = box.createSeason(1, now_ + NOTICE, now_ + NOTICE + 1 days, 0, 1, rigged);
        assertEq(riggedSeason, 2);
        for (uint256 offset; offset < NOTICE; offset += 1 days) {
            vm.warp(now_ + offset);
            vm.expectRevert(abi.encodeWithSelector(OGClubBox.SalesUnavailable.selector, riggedSeason));
            box.buy(riggedSeason, 1);
        }
        vm.warp(now_ + NOTICE - 1);
        vm.expectRevert(abi.encodeWithSelector(OGClubBox.SalesUnavailable.selector, riggedSeason));
        box.buy(riggedSeason, 1);
        assertEq(box.purchaseCount(), 0);
        assertEq(furniture.balanceOf(address(this), CAPPED_ID), 0);
        assertEq(furniture.totalSupply(), 0);
        // A season that has not opened can still be cancelled, exactly as before.
        box.cancelSeason(riggedSeason);
        assertTrue(box.getSeason(riggedSeason).cancelled);

        // After the notice the honest season sells normally and the box mints as a minter.
        vm.warp(now_ + NOTICE);
        vm.prank(buyer);
        uint256 purchase = box.buy(honest, 1);
        (,,, uint256 targetBlock,) = box.purchases(purchase);
        vm.roll(targetBlock + 1);
        bytes memory header = HeaderBuilder.header(targetBlock, keccak256("after notice"), 7);
        vm.setBlockhash(targetBlock, keccak256(header));
        vm.prank(stranger);
        box.open(purchase, header);
        assertTrue(box.delivered(purchase));
        assertEq(furniture.totalSupply(), 1);
    }

    /// @dev closeSeason and cancelSeason are untouched by the notice: close works before and after opening,
    ///      cancel only before opening, and a closed or cancelled season stays terminal.
    function test_CloseAndCancelWorkAsBefore() public {
        uint256 now_ = block.timestamp;
        uint256 first = box.createSeason(1, now_ + NOTICE, now_ + 60 days, 0, 1, entries());
        uint256 second = box.createSeason(1, now_ + NOTICE, now_ + 60 days, 0, 1, entries());
        uint256 third = box.createSeason(1, now_ + NOTICE, now_ + 60 days, 0, 1, entries());
        box.closeSeason(first); // Closing before the opening is allowed.
        assertTrue(box.getSeason(first).closed);
        assertFalse(box.getSeason(first).cancelled);
        vm.expectRevert(abi.encodeWithSelector(OGClubBox.SeasonAlreadyClosed.selector, first));
        box.cancelSeason(first);
        box.cancelSeason(second);
        assertTrue(box.getSeason(second).closed);
        assertTrue(box.getSeason(second).cancelled);
        vm.expectRevert(abi.encodeWithSelector(OGClubBox.SeasonAlreadyClosed.selector, second));
        box.closeSeason(second);
        vm.warp(now_ + NOTICE);
        vm.expectRevert(abi.encodeWithSelector(OGClubBox.SeasonAlreadyStarted.selector, third));
        box.cancelSeason(third);
        vm.prank(buyer);
        box.buy(third, 1);
        box.closeSeason(third);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(OGClubBox.SalesUnavailable.selector, third));
        box.buy(third, 1);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(OGClubBox.SalesUnavailable.selector, first));
        box.buy(first, 1);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(OGClubBox.SalesUnavailable.selector, second));
        box.buy(second, 1);
    }

    /// @dev Season terms stay immutable: nothing on the box can move opensAt once a season exists.
    function test_SeasonTermsRemainImmutable() public {
        uint256 now_ = block.timestamp;
        uint256 season = box.createSeason(1, now_ + NOTICE, now_ + 60 days, 0, 1, entries());
        bytes32 before = keccak256(abi.encode(box.getSeason(season), box.getEntries(season)));
        (bool ok,) = address(box).call(abi.encodeWithSignature("setSeasonOpensAt(uint256,uint256)", season, now_));
        assertFalse(ok);
        box.setPaused(true);
        box.setPaused(false);
        box.setVault(stranger);
        vm.warp(now_ + 30 days);
        assertEq(before, keccak256(abi.encode(box.getSeason(season), box.getEntries(season))));
    }
}
