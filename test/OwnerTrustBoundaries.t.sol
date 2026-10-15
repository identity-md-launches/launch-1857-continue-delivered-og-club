// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {OGClubBox} from "../src/OGClubBox.sol";
import {OGClubFurniture} from "../src/OGClubFurniture.sol";
import {MockOG} from "../src/mocks/MockOG.sol";
import {HeaderBuilder} from "./helpers/HeaderBuilder.sol";

/// @notice Regression tests for the two owner notices, including ownership handovers and zero supply.
/// forge-config: default.fuzz.runs = 512
contract OwnerTrustBoundariesTest is Test {
    uint256 internal constant NOTICE = 7 days;
    address internal owner;
    address internal successor;
    address internal buyer;
    address internal vault;
    MockOG internal token;
    OGClubFurniture internal furniture;
    OGClubBox internal box;

    function setUp() public {
        vm.warp(1_000_000);
        vm.roll(100);
        owner = makeAddr("trust owner");
        successor = makeAddr("trust successor");
        buyer = makeAddr("trust buyer");
        vault = makeAddr("trust vault");
        token = new MockOG(buyer);
        furniture = new OGClubFurniture(owner, vault);
        box = new OGClubBox(token, furniture, vault, owner, NOTICE);
        vm.prank(buyer);
        token.approve(address(box), type(uint256).max);
    }

    function _entries() internal pure returns (OGClubBox.Entry[] memory entries) {
        entries = new OGClubBox.Entry[](2);
        entries[0] = OGClubBox.Entry(0, 0, 1, 0);
        entries[1] = OGClubBox.Entry(1, 4, (1 << 128) - 1, 1);
    }

    function _create(OGClubBox targetBox, uint256 opensAt) internal returns (uint256) {
        vm.prank(owner);
        return targetBox.createSeason(1, opensAt, opensAt + 90 days, 0, 0, _entries());
    }

    function _buy(uint256 season, uint256 count) internal returns (uint256) {
        vm.prank(buyer);
        return box.buy(season, count);
    }

    function _open(uint256 purchase) internal returns (uint256[] memory expected) {
        (,,, uint256 target,) = box.purchases(purchase);
        if (vm.getBlockNumber() <= target) vm.roll(target + 1);
        bytes32 randao = keccak256("trust boundary roll");
        bytes memory header = HeaderBuilder.header(target, randao, 7);
        if (vm.getBlockNumber() <= target + 256) vm.setBlockhash(target, keccak256(header));
        expected = box.previewOpen(purchase, randao);
        vm.prank(successor);
        box.open(purchase, header);
    }

    function _fundOwner() internal {
        token.mint(owner, 100);
        vm.prank(owner);
        token.approve(address(box), type(uint256).max);
    }

    function _saleWithUndeliveredPurchase() internal returns (uint256 season, uint256 purchase) {
        vm.prank(owner);
        furniture.grantMinter(address(box));
        uint256 opensAt = vm.getBlockTimestamp() + NOTICE;
        season = _create(box, opensAt);
        vm.warp(opensAt);
        purchase = _buy(season, 10);
        assertEq(furniture.totalSupply(), 0);
    }

    function _assertNoticeBoundary(uint256 notice, uint256 createdAt) internal {
        vm.warp(createdAt);
        OGClubFurniture collection = new OGClubFurniture(owner, vault);
        OGClubBox sale = new OGClubBox(token, collection, vault, owner, notice);
        vm.prank(owner);
        collection.grantMinter(address(sale));
        vm.prank(buyer);
        token.approve(address(sale), type(uint256).max);
        uint256 earliest = createdAt + notice;

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(OGClubBox.SeasonOpensTooSoon.selector, earliest - 1, earliest));
        sale.createSeason(1, earliest - 1, earliest + 1 days, 0, 0, _entries());
        assertEq(sale.seasonCount(), 0);
        uint256 season = _create(sale, earliest);
        assertEq(sale.seasonNotice(), notice);
        assertEq(sale.getSeason(season).opensAt, earliest);
        uint256 balanceBefore = token.balanceOf(buyer);
        if (notice != 0) {
            vm.warp(earliest - 1);
            vm.prank(buyer);
            vm.expectRevert(abi.encodeWithSelector(OGClubBox.SalesUnavailable.selector, season));
            sale.buy(season, 1);
            assertEq(token.balanceOf(buyer), balanceBefore);
            assertEq(sale.purchaseCount(), 0);
            assertEq(collection.totalSupply(), 0);
        }
        vm.warp(earliest);
        vm.prank(buyer);
        assertEq(sale.buy(season, 1), 1);
        assertEq(token.balanceOf(buyer), balanceBefore - 1);
        assertEq(token.balanceOf(address(sale)), 0);
    }

    function test_ZeroNoticeBoundary() public {
        _assertNoticeBoundary(0, vm.getBlockTimestamp());
    }

    function test_OneSecondNoticeBoundary() public {
        _assertNoticeBoundary(1, vm.getBlockTimestamp());
    }

    function test_ThirtyDayNoticeBoundary() public {
        _assertNoticeBoundary(30 days, vm.getBlockTimestamp());
    }

    function testFuzz_EveryAllowedNoticeEnforcesTheCreationAndSaleBoundary(uint256 noticeSeed, uint64 timeSeed) public {
        _assertNoticeBoundary(bound(noticeSeed, 0, 30 days), bound(timeSeed, 1, type(uint64).max));
    }

    function testFuzz_ConstructorRejectsEveryNoticeAboveTheMaximum(uint256 seed) public {
        uint256 notice = bound(seed, 30 days + 1, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(OGClubBox.InvalidSeasonNotice.selector, notice, 30 days));
        new OGClubBox(token, furniture, vault, owner, notice);
    }

    function test_AgedDeploymentAndCancelledSeasonCannotLendTheirNoticeToANewSeason() public {
        vm.prank(owner);
        furniture.grantMinter(address(box));
        uint256 initial = _create(box, vm.getBlockTimestamp() + NOTICE);
        vm.prank(owner);
        box.cancelSeason(initial);
        vm.warp(vm.getBlockTimestamp() + 100 days);
        uint256 now_ = vm.getBlockTimestamp();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(OGClubBox.SeasonOpensTooSoon.selector, now_, now_ + NOTICE));
        box.createSeason(1, now_, now_ + 1 days, 0, 0, _entries());
        uint256 replacement = _create(box, now_ + NOTICE);
        assertEq(replacement, 2);
        _fundOwner();
        vm.warp(now_ + NOTICE - 1);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(OGClubBox.SalesUnavailable.selector, replacement));
        box.buy(replacement, 10);
        assertEq(furniture.totalSupply(), 0);

        // After the full new notice a ten-pack must include the only rare, but cannot exceed its cap.
        vm.warp(now_ + NOTICE);
        vm.prank(owner);
        uint256 purchase = box.buy(replacement, 10);
        _open(purchase);
        assertEq(furniture.balanceOf(owner, 1), 1);
        assertEq(furniture.balanceOf(owner, 0), 9);
        assertEq(box.minted(initial, 1), 0);
        assertEq(box.minted(replacement, 1), 1);
        assertTrue(box.getSeason(initial).cancelled);
    }

    function test_BoxOwnershipHandoverPreservesExistingTermsAndRequiresFreshNotice() public {
        uint256 season = _create(box, vm.getBlockTimestamp() + NOTICE);
        bytes32 terms = keccak256(abi.encode(box.getSeason(season), box.getEntries(season)));
        vm.prank(owner);
        box.transferOwnership(successor);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(successor);
        box.acceptOwnership();
        uint256 oldOpening = box.getSeason(season).opensAt;
        uint256 earliest = vm.getBlockTimestamp() + NOTICE;
        vm.prank(successor);
        vm.expectRevert(abi.encodeWithSelector(OGClubBox.SeasonOpensTooSoon.selector, oldOpening, earliest));
        box.createSeason(1, oldOpening, earliest + 1 days, 0, 0, _entries());
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        box.createSeason(1, earliest, earliest + 1 days, 0, 0, _entries());
        vm.prank(successor);
        box.createSeason(1, earliest, earliest + 1 days, 0, 0, _entries());
        assertEq(box.seasonNotice(), NOTICE);
        assertEq(keccak256(abi.encode(box.getSeason(season), box.getEntries(season))), terms);
    }

    function test_PreBootstrapRevokeAndOwnershipChangeDoNotSpendTheFirstGrant() public {
        vm.prank(owner);
        furniture.revokeMinter(address(box));
        vm.prank(owner);
        furniture.transferOwnership(successor);
        vm.prank(successor);
        furniture.acceptOwnership();
        assertFalse(furniture.bootstrapped());
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        furniture.grantMinter(owner);
        vm.prank(successor);
        furniture.grantMinter(address(box));
        assertTrue(furniture.bootstrapped());
        assertTrue(furniture.minters(address(box)));
        assertEq(furniture.pendingMinters(address(box)), 0);
        assertEq(furniture.totalSupply(), 0);
        vm.prank(successor);
        furniture.grantMinter(successor);
        assertFalse(furniture.minters(successor));
        assertEq(furniture.pendingMinters(successor), vm.getBlockTimestamp() + 7 days);
    }

    function test_GrantingSomeoneElseFirstMakesTheBoxWaitEvenAfterItsSeasonNotice() public {
        vm.prank(owner);
        furniture.grantMinter(successor);
        uint256 season = _create(box, vm.getBlockTimestamp() + NOTICE);
        vm.warp(vm.getBlockTimestamp() + NOTICE);
        vm.prank(owner);
        furniture.grantMinter(address(box));
        uint256 deadline = vm.getBlockTimestamp() + 7 days;
        vm.prank(buyer);
        vm.expectRevert(OGClubBox.BoxNotMinter.selector);
        box.buy(season, 1);
        assertEq(box.purchaseCount(), 0);
        assertEq(token.balanceOf(vault), 0);
        assertEq(furniture.totalSupply(), 0);
        vm.warp(deadline);
        // Elapsed time is not authorization until activateMinter is called.
        vm.prank(buyer);
        vm.expectRevert(OGClubBox.BoxNotMinter.selector);
        box.buy(season, 1);
        vm.prank(buyer);
        furniture.activateMinter(address(box));
        uint256 purchase = _buy(season, 1);
        _open(purchase);
        assertTrue(box.delivered(purchase));
        assertEq(furniture.totalSupply(), 1);
    }

    function test_HandoverCannotResetBootstrapWhileSalesHaveNoDeliveredSupply() public {
        (, uint256 purchase) = _saleWithUndeliveredPurchase();
        vm.prank(owner);
        furniture.transferOwnership(successor);
        vm.prank(successor);
        furniture.acceptOwnership();
        vm.startPrank(successor);
        furniture.grantMinter(successor);
        furniture.revokeMinter(address(box));
        furniture.grantMinter(address(box));
        vm.stopPrank();
        uint256 deadline = vm.getBlockTimestamp() + 7 days;
        assertTrue(furniture.bootstrapped());
        assertFalse(furniture.minters(successor));
        assertFalse(furniture.minters(address(box)));
        assertEq(furniture.pendingMinters(successor), deadline);
        assertEq(furniture.pendingMinters(address(box)), deadline);
        uint256[] memory rolled = _open(purchase);
        assertEq(box.getStoredItems(purchase), rolled);
        assertFalse(box.delivered(purchase));
        assertEq(furniture.totalSupply(), 0);
        vm.warp(deadline - 1);
        vm.expectRevert(abi.encodeWithSelector(OGClubFurniture.MinterDelayNotElapsed.selector, address(box), deadline));
        furniture.activateMinter(address(box));
        vm.warp(deadline);
        vm.prank(buyer);
        furniture.activateMinter(address(box));
        box.deliver(purchase);
        assertEq(furniture.balanceOf(buyer, 1), 1);
        assertEq(furniture.totalSupply(), rolled.length);
        // Activating one proposal does not activate or consume the other.
        assertFalse(furniture.minters(successor));
        assertEq(furniture.pendingMinters(successor), deadline);
    }

    function test_ReproposalWithZeroSupplyRestartsDelayWithoutLosingStoredRoll() public {
        (, uint256 purchase) = _saleWithUndeliveredPurchase();
        vm.startPrank(owner);
        furniture.revokeMinter(address(box));
        furniture.grantMinter(address(box));
        vm.stopPrank();
        uint256 oldDeadline = vm.getBlockTimestamp() + 7 days;
        uint256[] memory rolled = _open(purchase);
        vm.warp(oldDeadline - 1);
        vm.prank(owner);
        furniture.grantMinter(address(box));
        uint256 newDeadline = vm.getBlockTimestamp() + 7 days;
        vm.warp(oldDeadline);
        vm.expectRevert(
            abi.encodeWithSelector(OGClubFurniture.MinterDelayNotElapsed.selector, address(box), newDeadline)
        );
        furniture.activateMinter(address(box));
        vm.expectRevert(abi.encodeWithSelector(OGClubFurniture.NotMinter.selector, address(box)));
        box.deliver(purchase);
        assertEq(box.getStoredItems(purchase), rolled);
        assertEq(furniture.totalSupply(), 0);
        vm.warp(newDeadline);
        furniture.activateMinter(address(box));
        box.deliver(purchase);
        assertTrue(box.delivered(purchase));
        assertEq(box.getStoredItems(purchase).length, 0);
        assertEq(furniture.balanceOf(buyer, 1), 1);
        assertEq(furniture.balanceOf(buyer, 0), 9);
        vm.expectRevert(abi.encodeWithSelector(OGClubBox.AlreadyDelivered.selector, purchase));
        box.deliver(purchase);
    }

    function test_RenouncingAfterRegrantStillAllowsPermissionlessActivationAndExactDelivery() public {
        (, uint256 purchase) = _saleWithUndeliveredPurchase();
        vm.startPrank(owner);
        furniture.revokeMinter(address(box));
        furniture.grantMinter(address(box));
        furniture.renounceOwnership();
        vm.stopPrank();
        uint256 deadline = vm.getBlockTimestamp() + 7 days;
        uint256[] memory rolled = _open(purchase);
        assertEq(box.getStoredItems(purchase), rolled);
        vm.warp(deadline - 1);
        vm.expectRevert(abi.encodeWithSelector(OGClubFurniture.MinterDelayNotElapsed.selector, address(box), deadline));
        furniture.activateMinter(address(box));
        vm.warp(deadline);
        vm.prank(successor);
        furniture.activateMinter(address(box));
        vm.prank(successor);
        box.deliver(purchase);
        assertEq(furniture.owner(), address(0));
        assertTrue(furniture.bootstrapped());
        assertEq(furniture.pendingMinters(address(box)), 0);
        assertEq(furniture.balanceOf(buyer, 0), 9);
        assertEq(furniture.balanceOf(buyer, 1), 1);
        assertTrue(box.delivered(purchase));
    }
}
