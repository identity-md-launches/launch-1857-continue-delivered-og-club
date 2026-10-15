// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BoxTestBase} from "./helpers/BoxTestBase.sol";
import {HeaderBuilder} from "./helpers/HeaderBuilder.sol";
import {OGClubBox} from "../src/OGClubBox.sol";
import {OGClubFurniture} from "../src/OGClubFurniture.sol";
import {MockOG} from "../src/mocks/MockOG.sol";

/// @dev Interleaves the furniture's minter lifecycle (grant, activate, cancel, revoke, direct mints by
///      other minters) with the box's buy / open / deliver flow. The handler is itself the buyer and can
///      reject deliveries. Every action either succeeds and updates ghosts or is proven to revert with the
///      expected error, so the run never discards a call.
contract MinterLifecycleHandler is Test, ERC1155Holder {
    OGClubBox public box;
    OGClubFurniture public furniture;
    MockOG public token;
    address public owner;
    uint256 public season;
    address public stranger = makeAddr("lifecycle stranger");
    address public redirect = makeAddr("lifecycle redirect");
    address[] public subjects; // box plus candidate minters
    uint256 public constant ITEMS = 3;

    // Ghost minter state.
    mapping(address => bool) public ghostActive;
    mapping(address => uint256) public ghostPending;
    mapping(address => uint256) public ghostProposedAt;
    bool public anythingMinted;
    uint256 public grantsAfterBootstrap;
    uint256 public delayedActivations;
    uint256 public earlyActivationRejections;
    uint256 public strangerRejections;
    uint256 public directMints;
    uint256 public buysRejectedWhileRevoked;
    mapping(uint256 id => uint256) public ghostDirect;

    // Ghost purchase state.
    mapping(uint256 => bytes32) public recordedRoll;
    mapping(uint256 => uint256) public deliveryCount;
    mapping(uint256 => uint256) internal randaoOf;
    mapping(uint256 => bool) internal hasRandao;
    uint256 public itemsOpened;
    uint256 public itemsDelivered;
    uint256 public paid;
    uint256 public burned;
    uint256 public failedOpens;
    uint256 public failedRetries;
    bool public rejectDelivery;

    constructor(OGClubBox box_, OGClubFurniture furniture_, MockOG token_, address owner_, uint256 season_) {
        box = box_;
        furniture = furniture_;
        token = token_;
        owner = owner_;
        season = season_;
        token.approve(address(box), type(uint256).max);
        subjects.push(address(box));
        subjects.push(makeAddr("candidate A"));
        subjects.push(makeAddr("candidate B"));
        ghostActive[address(box)] = true; // the one bootstrap grant, made in setUp right after deployment
    }

    function subjectCount() external view returns (uint256) {
        return subjects.length;
    }

    function _subject(uint8 seed) internal view returns (address) {
        return subjects[seed % subjects.length];
    }

    function _caller(uint8 seed) internal view returns (address) {
        uint256 w = seed % 4;
        if (w == 0) return owner;
        if (w == 1) return stranger;
        return subjects[w - 1];
    }

    // ------------------------------------------------------------------ minter lifecycle

    /// @dev The bootstrap grant was spent before the handler existed, so every grant here is a proposal,
    ///      whatever the supply: zero (nothing delivered yet) or not.
    function grant(uint8 who) external {
        address minter = _subject(who);
        bool wasActive = ghostActive[minter];
        assertTrue(furniture.bootstrapped(), "the box grant in setUp must have spent the bootstrap");
        vm.prank(owner);
        furniture.grantMinter(minter);
        assertTrue(furniture.bootstrapped());
        ghostPending[minter] = block.timestamp + 7 days;
        ghostProposedAt[minter] = block.timestamp;
        assertEq(ghostActive[minter], wasActive, "a proposal must not change the live role");
        ++grantsAfterBootstrap;
        _checkMinter(minter);
    }

    function activate(uint8 who, uint8 callerSeed) external {
        address minter = _subject(who);
        address caller = _caller(callerSeed);
        uint256 pending = ghostPending[minter];
        vm.prank(caller);
        (bool ok, bytes memory reason) = address(furniture).call(abi.encodeCall(furniture.activateMinter, (minter)));
        if (pending == 0) {
            assertFalse(ok);
            assertEq(reason, abi.encodeWithSelector(OGClubFurniture.NoMinterProposal.selector, minter));
        } else if (block.timestamp < pending) {
            assertFalse(ok);
            assertEq(reason, abi.encodeWithSelector(OGClubFurniture.MinterDelayNotElapsed.selector, minter, pending));
            ++earlyActivationRejections;
        } else {
            assertTrue(ok, "anyone may activate once the delay has elapsed");
            assertGe(block.timestamp, ghostProposedAt[minter] + 7 days, "activated before seven days");
            ghostActive[minter] = true;
            ghostPending[minter] = 0;
            ++delayedActivations;
        }
        _checkMinter(minter);
    }

    function cancel(uint8 who) external {
        address minter = _subject(who);
        bool wasActive = ghostActive[minter];
        vm.prank(owner);
        if (ghostPending[minter] == 0) {
            vm.expectRevert(abi.encodeWithSelector(OGClubFurniture.NoMinterProposal.selector, minter));
            furniture.cancelMinter(minter);
        } else {
            furniture.cancelMinter(minter);
            ghostPending[minter] = 0;
        }
        assertEq(ghostActive[minter], wasActive);
        _checkMinter(minter);
    }

    function revoke(uint8 who) external {
        address minter = _subject(who);
        vm.prank(owner);
        furniture.revokeMinter(minter);
        ghostActive[minter] = false;
        ghostPending[minter] = 0;
        _checkMinter(minter);
    }

    function strangerCannotAdminister(uint8 who, uint8 which, uint8 callerSeed) external {
        address minter = _subject(who);
        address caller = _caller(callerSeed);
        if (caller == owner) caller = stranger;
        bytes memory call_;
        uint256 w = which % 3;
        if (w == 0) call_ = abi.encodeCall(furniture.grantMinter, (minter));
        else if (w == 1) call_ = abi.encodeCall(furniture.cancelMinter, (minter));
        else call_ = abi.encodeCall(furniture.revokeMinter, (minter));
        vm.prank(caller);
        (bool ok, bytes memory reason) = address(furniture).call(call_);
        assertFalse(ok);
        assertEq(reason, abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        ++strangerRejections;
        _checkMinter(minter);
    }

    /// @dev A candidate (never the box) tries to mint directly; only a live role may.
    function directMint(uint8 who, uint8 idSeed, uint8 amountSeed) external {
        address minter = subjects[1 + who % (subjects.length - 1)];
        uint256[] memory ids = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        ids[0] = 1 + idSeed % ITEMS;
        amounts[0] = bound(amountSeed, 1, 5);
        vm.prank(minter);
        (bool ok, bytes memory reason) =
            address(furniture).call(abi.encodeCall(furniture.mintBatch, (minter, ids, amounts)));
        if (!ghostActive[minter]) {
            assertFalse(ok, "an inactive minter minted");
            assertEq(reason, abi.encodeWithSelector(OGClubFurniture.NotMinter.selector, minter));
            return;
        }
        assertTrue(ok);
        ghostDirect[ids[0]] += amounts[0];
        anythingMinted = true;
        ++directMints;
    }

    // ------------------------------------------------------------------ time

    function warp(uint32 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 1, 4 days));
    }

    function advance(uint16 blocks) external {
        vm.roll(block.number + bound(blocks, 1, 300));
    }

    // ------------------------------------------------------------------ box flow

    function buy(uint8 countSeed) external {
        uint256 count = bound(countSeed, 1, 10);
        OGClubBox.Season memory terms = box.getSeason(season);
        if (!ghostActive[address(box)]) {
            vm.expectRevert(OGClubBox.BoxNotMinter.selector);
            box.buy(season, count);
            ++buysRejectedWhileRevoked;
            return;
        }
        box.buy(season, count);
        uint256 total = terms.price * count;
        paid += total;
        burned += total * terms.burnBps / 10_000;
    }

    function setRejectDelivery(bool value) external {
        rejectDelivery = value;
    }

    function open(uint256 selector, bytes32 entropy) external {
        if (box.purchaseCount() == 0) return;
        uint256 id = selector % box.purchaseCount() + 1;
        (,, uint256 count, uint256 targetBlock, bool opened) = box.purchases(id);
        if (opened) {
            vm.expectRevert(abi.encodeWithSelector(OGClubBox.AlreadyOpened.selector, id));
            box.open(id, "");
            return;
        }
        if (block.number <= targetBlock) vm.roll(targetBlock + 1);
        if (!hasRandao[targetBlock]) {
            hasRandao[targetBlock] = true;
            randaoOf[targetBlock] = uint256(entropy);
        }
        bytes32 randao = bytes32(randaoOf[targetBlock]);
        bytes memory header = HeaderBuilder.header(targetBlock, randao, 7);
        if (block.number - targetBlock <= 256) vm.setBlockhash(targetBlock, keccak256(header));
        uint256[] memory preview = box.previewOpen(id, randao);
        uint256[ITEMS] memory before;
        for (uint256 i; i < ITEMS; ++i) {
            before[i] = furniture.balanceOf(address(this), i + 1);
        }
        bool expectSuccess = ghostActive[address(box)] && !rejectDelivery;
        vm.prank(stranger);
        box.open(id, header);
        recordedRoll[id] = keccak256(abi.encode(preview));
        itemsOpened += count;
        assertEq(box.delivered(id), expectSuccess, "delivery outcome disagrees with the minter role");
        if (expectSuccess) {
            ++deliveryCount[id];
            itemsDelivered += count;
            anythingMinted = true;
            assertEq(box.getStoredItems(id).length, 0);
        } else {
            ++failedOpens;
            assertEq(box.getStoredItems(id), preview);
        }
        for (uint256 i; i < ITEMS; ++i) {
            uint256 expected;
            for (uint256 j; j < preview.length; ++j) {
                if (preview[j] == i + 1) ++expected;
            }
            assertEq(furniture.balanceOf(address(this), i + 1), before[i] + (expectSuccess ? expected : 0));
        }
        assertLe(box.minted(season, 2), 4);
        assertLe(box.minted(season, 3), 3);
    }

    function deliver(uint256 selector, bool redirectIt, uint8 callerSeed) external {
        if (box.purchaseCount() == 0) return;
        uint256 id = selector % box.purchaseCount() + 1;
        (,, uint256 count,, bool opened) = box.purchases(id);
        bool wasDelivered = box.delivered(id);
        uint256[] memory stored = box.getStoredItems(id);
        address to = redirectIt ? redirect : address(this);
        bytes memory call_ = redirectIt ? abi.encodeCall(box.deliverTo, (id, to)) : abi.encodeCall(box.deliver, (id));
        if (!redirectIt) vm.prank(_caller(callerSeed));
        (bool ok, bytes memory reason) = address(box).call(call_);
        if (!opened) {
            assertFalse(ok);
            assertEq(reason, abi.encodeWithSelector(OGClubBox.NotOpened.selector, id));
        } else if (wasDelivered) {
            assertFalse(ok);
            assertEq(reason, abi.encodeWithSelector(OGClubBox.AlreadyDelivered.selector, id));
        } else if (!ghostActive[address(box)]) {
            assertFalse(ok, "delivered while the box was not a minter");
            assertEq(reason, abi.encodeWithSelector(OGClubFurniture.NotMinter.selector, address(box)));
            ++failedRetries;
        } else if (rejectDelivery && !redirectIt) {
            assertFalse(ok);
            ++failedRetries;
        } else {
            assertTrue(ok, "retry should have delivered");
            assertEq(stored.length, count);
            assertEq(keccak256(abi.encode(stored)), recordedRoll[id], "delivered items differ from the roll");
            ++deliveryCount[id];
            itemsDelivered += count;
            anythingMinted = true;
        }
        if (!ok) {
            assertEq(box.delivered(id), wasDelivered);
            assertEq(box.getStoredItems(id), stored);
        } else {
            assertTrue(box.delivered(id));
            assertEq(box.getStoredItems(id).length, 0);
        }
    }

    // ------------------------------------------------------------------ receiver hooks

    function onERC1155Received(address, address, uint256, uint256, bytes memory) public view override returns (bytes4) {
        require(!rejectDelivery, "receiver rejects");
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] memory, uint256[] memory, bytes memory)
        public
        view
        override
        returns (bytes4)
    {
        require(!rejectDelivery, "receiver rejects");
        return this.onERC1155BatchReceived.selector;
    }

    function _checkMinter(address minter) internal view {
        assertEq(furniture.minters(minter), ghostActive[minter], "live role disagrees with ghost");
        assertEq(furniture.pendingMinters(minter), ghostPending[minter], "pending time disagrees with ghost");
    }
}

/// forge-config: default.invariant.runs = 96
/// forge-config: default.invariant.depth = 80
contract MinterLifecycleInvariantTest is BoxTestBase {
    MinterLifecycleHandler internal handler;

    function setUp() public override {
        super.setUp();
        // A season that never closes by time, so years of warping keep sales open.
        uint256 season = box.createSeason(101, 1000, type(uint256).max, 3333, 1, defaultEntries());
        handler = new MinterLifecycleHandler(box, furniture, token, address(this), season);
        token.mint(address(handler), 1_000_000 ether);
        // Seed every regime once so no invariant is vacuous: a proposal made while nothing is delivered, a
        // delivered open (first mint), a revoked box with a stored roll, a delayed proposal that activates,
        // and a rejected retry.
        handler.grant(1); // candidate A: a proposal, not immediate, although nothing is minted yet
        handler.activate(1, 1); // too early: rejected
        handler.buy(10);
        handler.open(0, keccak256("lifecycle seed")); // purchase 1 delivered: first mint
        handler.revoke(0);
        handler.buy(3); // rejected: the box is not a minter
        handler.grant(0); // delayed proposal for the re-granted box
        handler.activate(0, 1); // too early: rejected
        vm.warp(block.timestamp + 7 days);
        handler.activate(0, 1); // a stranger activates at the deadline
        handler.activate(1, 2); // candidate A's older proposal is ready too
        handler.buy(3); // purchase 2
        handler.setRejectDelivery(true);
        handler.open(1, keccak256("rejected seed")); // purchase 2 stored
        handler.deliver(1, false, 1); // retry still rejected
        handler.setRejectDelivery(false);
        handler.strangerCannotAdminister(1, 0, 1);
        handler.directMint(0, 0, 1); // candidate A mints directly
        bytes4[] memory selectors = new bytes4[](14);
        selectors[0] = MinterLifecycleHandler.grant.selector;
        selectors[1] = MinterLifecycleHandler.activate.selector;
        selectors[2] = MinterLifecycleHandler.cancel.selector;
        selectors[3] = MinterLifecycleHandler.revoke.selector;
        selectors[4] = MinterLifecycleHandler.strangerCannotAdminister.selector;
        selectors[5] = MinterLifecycleHandler.directMint.selector;
        selectors[6] = MinterLifecycleHandler.warp.selector;
        selectors[7] = MinterLifecycleHandler.advance.selector;
        selectors[8] = MinterLifecycleHandler.buy.selector;
        selectors[9] = MinterLifecycleHandler.setRejectDelivery.selector;
        selectors[10] = MinterLifecycleHandler.open.selector;
        selectors[11] = MinterLifecycleHandler.deliver.selector;
        selectors[12] = MinterLifecycleHandler.open.selector;
        selectors[13] = MinterLifecycleHandler.deliver.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_MinterRolesMatchGhostsAndNeverActivateEarly() public view {
        for (uint256 i; i < handler.subjectCount(); ++i) {
            address subject = handler.subjects(i);
            assertEq(furniture.minters(subject), handler.ghostActive(subject));
            assertEq(furniture.pendingMinters(subject), handler.ghostPending(subject));
            // A pending proposal always points at least seven days past when it was made.
            if (furniture.pendingMinters(subject) != 0) {
                assertEq(furniture.pendingMinters(subject), handler.ghostProposedAt(subject) + 7 days);
            }
        }
        assertFalse(furniture.minters(handler.stranger()));
        assertEq(furniture.pendingMinters(handler.stranger()), 0);
        assertFalse(furniture.minters(address(this)));
        assertTrue(handler.anythingMinted());
        assertEq(furniture.totalSupply() != 0, handler.anythingMinted());
        // The bootstrap is spent once and never comes back; every later grant was a proposal.
        assertTrue(furniture.bootstrapped());
        // Exercised regimes.
        assertGt(handler.grantsAfterBootstrap(), 0);
        assertGt(handler.delayedActivations(), 0);
        assertGt(handler.strangerRejections(), 0);
        assertGt(handler.directMints(), 0);
    }

    function invariant_MintedPerItemEqualsDeliveredSupplyPlusStoredMinusDirectMints() public view {
        uint256[4] memory storedPerItem;
        uint256 storedTotal;
        for (uint256 id = 1; id <= box.purchaseCount(); ++id) {
            uint256[] memory stored = box.getStoredItems(id);
            if (stored.length != 0) {
                assertFalse(box.delivered(id));
                assertEq(keccak256(abi.encode(stored)), handler.recordedRoll(id));
            }
            for (uint256 i; i < stored.length; ++i) {
                ++storedPerItem[stored[i]];
            }
            storedTotal += stored.length;
        }
        uint256 total;
        for (uint256 item = 1; item <= handler.ITEMS(); ++item) {
            uint256 viaBox = furniture.totalSupply(item) - handler.ghostDirect(item);
            assertEq(box.minted(handler.season(), item), viaBox + storedPerItem[item], "minted != delivered + stored");
            assertEq(
                furniture.totalSupply(item),
                furniture.balanceOf(address(handler), item) + furniture.balanceOf(handler.redirect(), item)
                    + furniture.balanceOf(handler.subjects(1), item) + furniture.balanceOf(handler.subjects(2), item)
            );
            if (item == 2) assertLe(box.minted(handler.season(), item), 4);
            if (item == 3) assertLe(box.minted(handler.season(), item), 3);
            total += box.minted(handler.season(), item);
        }
        assertEq(total, handler.itemsOpened());
        assertEq(total, handler.itemsDelivered() + storedTotal);
    }

    function invariant_EachPurchaseDeliveredAtMostOnceAndOnlyAfterOpening() public view {
        for (uint256 id = 1; id <= box.purchaseCount(); ++id) {
            (,, uint256 count,, bool opened) = box.purchases(id);
            bool delivered = box.delivered(id);
            assertLe(handler.deliveryCount(id), 1);
            assertEq(handler.deliveryCount(id), delivered ? 1 : 0);
            if (delivered) assertTrue(opened);
            assertEq(box.getStoredItems(id).length, opened && !delivered ? count : 0);
        }
        assertGt(handler.failedOpens(), 0);
        assertGt(handler.failedRetries(), 0);
    }

    function invariant_BoxHoldsNothingAndPaymentsAreConserved() public view {
        assertEq(token.balanceOf(address(box)), 0);
        for (uint256 item; item <= handler.ITEMS() + 1; ++item) {
            assertEq(furniture.balanceOf(address(box), item), 0);
            assertEq(furniture.balanceOf(address(furniture), item), 0);
        }
        assertEq(token.balanceOf(box.BURN_ADDRESS()), handler.burned());
        assertEq(token.balanceOf(vault), handler.paid() - handler.burned());
        assertEq(token.balanceOf(address(handler)), 1_000_000 ether - handler.paid());
    }
}
