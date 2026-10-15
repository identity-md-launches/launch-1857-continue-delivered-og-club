// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {OGClubBox} from "../src/OGClubBox.sol";
import {OGClubFurniture} from "../src/OGClubFurniture.sol";
import {MockOG} from "../src/mocks/MockOG.sol";
import {HeaderBuilder} from "./helpers/HeaderBuilder.sol";

/// @dev A nonzero-notice campaign. Owners are also buyers, so the same sale checks cover an owner trying
///      to acquire a capped piece. All buyers accept ERC-1155s; delivery fails only when the box is revoked.
///      Ghost balances track successful calls, and every expected failure is checked by exact revert data.
contract SeasonNoticeHandler is Test {
    uint256 public constant NOTICE = 7 days;
    uint256 public constant FUNDING = 1e24;
    OGClubBox public box;
    OGClubFurniture public furniture;
    MockOG public token;
    address[3] public actors;
    address public owner;
    address public vault;

    uint256 public seasonsCreated;
    uint256 public purchasesMade;
    uint256 public paid;
    uint256 public burned;
    uint256 public itemsOpened;
    uint256 public itemsDelivered;
    uint256 public earlySeasonsRejected;
    uint256 public earlyBuysRejected;
    uint256 public storedOpens;
    bool public active = true;
    uint256 public pending;
    mapping(uint256 => uint256) public createdAt;
    mapping(uint256 => bytes32) public originalTerms;
    mapping(uint256 => bool) public closed;
    mapping(uint256 => bool) public cancelled;
    mapping(uint256 => uint256) public boughtAt;
    mapping(uint256 => bool) public opened;
    mapping(uint256 => bool) public delivered;
    mapping(uint256 => uint256[]) private rolls;
    mapping(uint256 => mapping(uint256 => uint256)) public rolledPerSeason;
    mapping(address => uint256) public spent;
    mapping(address => mapping(uint256 => uint256)) public held;
    mapping(uint256 => bytes32) private randaoByBlock;
    mapping(uint256 => bool) private headerSet;

    constructor() {
        actors[0] = makeAddr("notice owner A");
        actors[1] = makeAddr("notice owner B");
        actors[2] = makeAddr("notice customer");
        owner = actors[0];
        vault = makeAddr("notice vault");
        token = new MockOG(address(this));
        furniture = new OGClubFurniture(owner, vault);
        box = new OGClubBox(token, furniture, vault, owner, NOTICE);
        vm.prank(owner);
        furniture.grantMinter(address(box));
        for (uint256 i; i < actors.length; ++i) {
            token.mint(actors[i], FUNDING);
            vm.prank(actors[i]);
            token.approve(address(box), type(uint256).max);
        }
    }

    function _expectFailure(address target, address caller, bytes memory data, bytes memory expected) internal {
        vm.prank(caller);
        (bool ok, bytes memory reason) = target.call(data);
        assertFalse(ok, "forbidden transition succeeded");
        assertEq(reason, expected, "unexpected rejection");
    }

    function _termsHash(OGClubBox.Season memory terms, OGClubBox.Entry[] memory entries)
        internal
        pure
        returns (bytes32)
    {
        // Terminal flags may change; all economic terms must remain identical to the original inputs.
        return
            keccak256(
                abi.encode(terms.price, terms.opensAt, terms.closesAt, terms.burnBps, terms.fallbackItem, entries)
            );
    }

    function announce(uint32 offsetSeed, uint96 priceSeed, uint16 bpsSeed, uint8 capSeed) public {
        uint256 opensAt = vm.getBlockTimestamp() + bound(offsetSeed, 0, 2 * NOTICE);
        uint256 price = bound(priceSeed, 1, 1e12);
        uint256 bps = bound(bpsSeed, 0, 10_000);
        OGClubBox.Entry[] memory entries = new OGClubBox.Entry[](2);
        entries[0] = OGClubBox.Entry(0, 0, 1, 0);
        entries[1] = OGClubBox.Entry(1, 4, 99, bound(capSeed, 1, 10));
        if (opensAt < vm.getBlockTimestamp() + NOTICE) {
            _expectFailure(
                address(box),
                owner,
                abi.encodeCall(box.createSeason, (price, opensAt, opensAt + 120 days, bps, 0, entries)),
                abi.encodeWithSelector(OGClubBox.SeasonOpensTooSoon.selector, opensAt, vm.getBlockTimestamp() + NOTICE)
            );
            ++earlySeasonsRejected;
            assertEq(box.seasonCount(), seasonsCreated);
            return;
        }
        vm.prank(owner);
        uint256 season = box.createSeason(price, opensAt, opensAt + 120 days, bps, 0, entries);
        assertEq(season, ++seasonsCreated);
        createdAt[season] = vm.getBlockTimestamp();
        originalTerms[season] =
            _termsHash(OGClubBox.Season(price, opensAt, opensAt + 120 days, bps, 0, false, false), entries);
    }

    function advanceTime(uint32 secondsSeed) public {
        vm.warp(vm.getBlockTimestamp() + bound(secondsSeed, 0, 30 days));
    }

    function stopSeason(uint256 seed, bool cancel) public {
        uint256 id = seed % seasonsCreated + 1;
        bytes memory data = cancel ? abi.encodeCall(box.cancelSeason, (id)) : abi.encodeCall(box.closeSeason, (id));
        if (closed[id]) {
            _expectFailure(
                address(box), owner, data, abi.encodeWithSelector(OGClubBox.SeasonAlreadyClosed.selector, id)
            );
        } else if (cancel && vm.getBlockTimestamp() >= box.getSeason(id).opensAt) {
            _expectFailure(
                address(box), owner, data, abi.encodeWithSelector(OGClubBox.SeasonAlreadyStarted.selector, id)
            );
        } else {
            vm.prank(owner);
            if (cancel) box.cancelSeason(id);
            else box.closeSeason(id);
            closed[id] = true;
            cancelled[id] = cancel;
        }
    }

    function buy(uint8 actorSeed, uint256 seasonSeed, uint8 countSeed) public {
        address actor = actors[actorSeed % actors.length];
        uint256 season = seasonSeed % seasonsCreated + 1;
        uint256 count = bound(countSeed, 1, 10);
        OGClubBox.Season memory terms = box.getSeason(season);
        if (closed[season] || vm.getBlockTimestamp() < terms.opensAt || vm.getBlockTimestamp() >= terms.closesAt) {
            _expectFailure(
                address(box),
                actor,
                abi.encodeCall(box.buy, (season, count)),
                abi.encodeWithSelector(OGClubBox.SalesUnavailable.selector, season)
            );
            if (vm.getBlockTimestamp() < terms.opensAt) ++earlyBuysRejected;
            return;
        }
        if (!active) {
            _expectFailure(
                address(box),
                actor,
                abi.encodeCall(box.buy, (season, count)),
                abi.encodeWithSelector(OGClubBox.BoxNotMinter.selector)
            );
            return;
        }
        // A sale must have been public for the full notice, including when the owner is the buyer.
        assertGe(vm.getBlockTimestamp(), createdAt[season] + NOTICE);
        vm.prank(actor);
        uint256 purchase = box.buy(season, count);
        assertEq(purchase, ++purchasesMade);
        boughtAt[purchase] = vm.getBlockTimestamp();
        uint256 total = terms.price * count;
        paid += total;
        burned += total * terms.burnBps / 10_000;
        spent[actor] += total;
    }

    function revokeBox() public {
        vm.prank(owner);
        furniture.revokeMinter(address(box));
        active = false;
        pending = 0;
    }

    function proposeBox() public {
        vm.prank(owner);
        furniture.grantMinter(address(box));
        pending = vm.getBlockTimestamp() + 7 days;
        assertEq(furniture.minters(address(box)), active, "proposal must not grant or revoke a live role");
    }

    function activateBox() public {
        bytes memory data = abi.encodeCall(furniture.activateMinter, (address(box)));
        if (pending == 0) {
            _expectFailure(
                address(furniture),
                actors[2],
                data,
                abi.encodeWithSelector(OGClubFurniture.NoMinterProposal.selector, address(box))
            );
        } else if (vm.getBlockTimestamp() < pending) {
            _expectFailure(
                address(furniture),
                actors[2],
                data,
                abi.encodeWithSelector(OGClubFurniture.MinterDelayNotElapsed.selector, address(box), pending)
            );
        } else {
            vm.prank(actors[2]);
            furniture.activateMinter(address(box));
            active = true;
            pending = 0;
        }
    }

    function handover() public {
        address next = owner == actors[0] ? actors[1] : actors[0];
        vm.startPrank(owner);
        box.transferOwnership(next);
        furniture.transferOwnership(next);
        vm.stopPrank();
        vm.startPrank(next);
        box.acceptOwnership();
        furniture.acceptOwnership();
        vm.stopPrank();
        owner = next;
    }

    function open(uint256 seed, bytes32 entropy, bool expire) public {
        uint256 id = seed % purchasesMade + 1;
        if (opened[id]) {
            _expectFailure(
                address(box),
                actors[2],
                abi.encodeCall(box.open, (id, bytes(""))),
                abi.encodeWithSelector(OGClubBox.AlreadyOpened.selector, id)
            );
            return;
        }
        (address buyer, uint256 season, uint256 count, uint256 target,) = box.purchases(id);
        if (vm.getBlockNumber() <= target) vm.roll(target + 1);
        if (expire && vm.getBlockNumber() <= target + 256) vm.roll(target + 257);
        if (!headerSet[target]) {
            headerSet[target] = true;
            randaoByBlock[target] = entropy;
        }
        bytes memory header = HeaderBuilder.header(target, randaoByBlock[target], 7);
        if (vm.getBlockNumber() <= target + 256) vm.setBlockhash(target, keccak256(header));
        uint256[] memory ids = box.previewOpen(id, randaoByBlock[target]);
        assertEq(ids.length, count);
        vm.prank(actors[2]);
        box.open(id, header);
        rolls[id] = ids;
        opened[id] = true;
        itemsOpened += count;
        for (uint256 i; i < ids.length; ++i) {
            assertLe(ids[i], 1, "roll contains an unlisted item");
            ++rolledPerSeason[season][ids[i]];
        }
        assertEq(box.delivered(id), active);
        if (active) {
            _recordDelivery(id, buyer);
        } else {
            ++storedOpens;
            assertEq(box.getStoredItems(id), ids);
        }
    }

    function deliver(uint256 seed) public {
        uint256 id = seed % purchasesMade + 1;
        bytes memory reason;
        if (!opened[id]) reason = abi.encodeWithSelector(OGClubBox.NotOpened.selector, id);
        else if (delivered[id]) reason = abi.encodeWithSelector(OGClubBox.AlreadyDelivered.selector, id);
        else if (!active) reason = abi.encodeWithSelector(OGClubFurniture.NotMinter.selector, address(box));
        if (reason.length != 0) {
            _expectFailure(address(box), actors[2], abi.encodeCall(box.deliver, (id)), reason);
            return;
        }
        assertEq(box.getStoredItems(id), rolls[id], "retry changed the original roll");
        vm.prank(actors[2]);
        box.deliver(id);
        (address buyer,,,,) = box.purchases(id);
        _recordDelivery(id, buyer);
    }

    function _recordDelivery(uint256 id, address buyer) internal {
        assertFalse(delivered[id], "same purchase minted twice");
        delivered[id] = true;
        itemsDelivered += rolls[id].length;
        for (uint256 i; i < rolls[id].length; ++i) {
            ++held[buyer][rolls[id][i]];
        }
    }

    function checkSeasonsAndRoles() public view {
        assertEq(box.seasonNotice(), NOTICE);
        assertEq(box.owner(), owner);
        assertEq(furniture.owner(), owner);
        assertTrue(furniture.bootstrapped(), "ownership changes must not reset the one-time bootstrap");
        assertEq(furniture.minters(address(box)), active);
        assertEq(furniture.pendingMinters(address(box)), pending);
        assertEq(box.seasonCount(), seasonsCreated);
        for (uint256 s = 1; s <= seasonsCreated; ++s) {
            OGClubBox.Season memory terms = box.getSeason(s);
            OGClubBox.Entry[] memory entries = box.getEntries(s);
            assertGe(terms.opensAt, createdAt[s] + NOTICE);
            assertEq(_termsHash(terms, entries), originalTerms[s]);
            assertEq(terms.closed, closed[s]);
            assertEq(terms.cancelled, cancelled[s]);
            assertLe(box.minted(s, 1), entries[1].cap);
            for (uint256 item; item < 2; ++item) {
                assertEq(box.minted(s, item), rolledPerSeason[s][item]);
            }
        }
    }

    function checkPaymentsAndDelivery() public view {
        assertEq(box.purchaseCount(), purchasesMade);
        assertEq(token.balanceOf(address(box)), 0);
        assertEq(token.balanceOf(box.BURN_ADDRESS()), burned);
        assertEq(token.balanceOf(vault), paid - burned);
        uint256 totalSpent;
        uint256[2] memory totalHeld;
        for (uint256 a; a < actors.length; ++a) {
            assertEq(token.balanceOf(actors[a]), FUNDING - spent[actors[a]]);
            totalSpent += spent[actors[a]];
            for (uint256 item; item < 2; ++item) {
                assertEq(furniture.balanceOf(actors[a], item), held[actors[a]][item]);
                totalHeld[item] += held[actors[a]][item];
            }
        }
        assertEq(totalSpent, paid);
        uint256[2] memory reserved;
        for (uint256 id = 1; id <= purchasesMade; ++id) {
            (, uint256 season, uint256 count,, bool isOpened) = box.purchases(id);
            OGClubBox.Season memory terms = box.getSeason(season);
            assertGe(boughtAt[id], createdAt[season] + NOTICE);
            assertGe(boughtAt[id], terms.opensAt);
            assertLt(boughtAt[id], terms.closesAt);
            assertEq(isOpened, opened[id]);
            assertEq(box.delivered(id), delivered[id]);
            uint256[] memory stored = box.getStoredItems(id);
            if (opened[id] && !delivered[id]) {
                assertEq(stored.length, count);
                assertEq(stored, rolls[id]);
                for (uint256 i; i < stored.length; ++i) {
                    ++reserved[stored[i]];
                }
            } else {
                assertEq(stored.length, 0);
            }
        }
        uint256 openedTotal;
        for (uint256 item; item < 2; ++item) {
            uint256 rolled;
            for (uint256 s = 1; s <= seasonsCreated; ++s) {
                rolled += rolledPerSeason[s][item];
            }
            assertEq(furniture.totalSupply(item), totalHeld[item]);
            assertEq(rolled, totalHeld[item] + reserved[item], "opened items != delivered + stored");
            openedTotal += rolled;
        }
        assertEq(openedTotal, itemsOpened);
        assertEq(furniture.totalSupply(), itemsDelivered);
        assertEq(itemsOpened, itemsDelivered + reserved[0] + reserved[1]);
    }

    /// @dev Not a fuzz target. After each random sequence, prove that restoring authorization settles every
    ///      paid purchase, even if its season was closed or the reveal expired. Stored rolls cannot change.
    function settleAll() external {
        if (!active) {
            if (pending == 0) proposeBox();
            if (vm.getBlockTimestamp() < pending) vm.warp(pending);
            activateBox();
        }
        for (uint256 i; i < purchasesMade; ++i) {
            if (!opened[i + 1]) open(i, keccak256(abi.encode(i)), false);
            if (!delivered[i + 1]) deliver(i);
            assertTrue(box.delivered(i + 1));
        }
        checkSeasonsAndRoles();
        checkPaymentsAndDelivery();
        assertEq(itemsOpened, itemsDelivered);
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 80
/// forge-config: default.invariant.fail-on-revert = true
contract SeasonNoticeInvariantTest is Test {
    SeasonNoticeHandler internal handler;

    function setUp() public {
        vm.warp(1_000_000);
        vm.roll(100);
        handler = new SeasonNoticeHandler();
        // Seed the precise zero-supply vulnerability: a paid ten-pack, a revoked and re-proposed box,
        // and an opened roll that cannot be delivered yet. No item has ever been minted at this point.
        handler.announce(0, 1, 3333, 1);
        handler.announce(7 days, 101, 3333, 1);
        handler.buy(0, 0, 10);
        handler.advanceTime(7 days);
        handler.buy(0, 0, 10);
        handler.revokeBox();
        handler.proposeBox();
        handler.activateBox();
        handler.open(0, keccak256("notice invariant seed"), false);
        handler.deliver(0);
        assertEq(handler.furniture().totalSupply(), 0);
        assertGt(handler.earlySeasonsRejected(), 0);
        assertGt(handler.earlyBuysRejected(), 0);
        assertGt(handler.storedOpens(), 0);
        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = SeasonNoticeHandler.announce.selector;
        selectors[1] = SeasonNoticeHandler.advanceTime.selector;
        selectors[2] = SeasonNoticeHandler.stopSeason.selector;
        selectors[3] = SeasonNoticeHandler.buy.selector;
        selectors[4] = SeasonNoticeHandler.revokeBox.selector;
        selectors[5] = SeasonNoticeHandler.proposeBox.selector;
        selectors[6] = SeasonNoticeHandler.activateBox.selector;
        selectors[7] = SeasonNoticeHandler.handover.selector;
        selectors[8] = SeasonNoticeHandler.open.selector;
        selectors[9] = SeasonNoticeHandler.deliver.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_NoticeTermsAndBootstrapSurviveEveryOwnerAction() public view {
        handler.checkSeasonsAndRoles();
    }

    function invariant_EveryPaymentAndReservedItemIsAccountedFor() public view {
        handler.checkPaymentsAndDelivery();
    }

    function afterInvariant() public {
        handler.settleAll();
    }
}
