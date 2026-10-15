// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {OGClubFurniture} from "../../src/OGClubFurniture.sol";
import {OGClubBox} from "../../src/OGClubBox.sol";
import {MockOG} from "../../src/mocks/MockOG.sol";
import {HeaderBuilder} from "./HeaderBuilder.sol";

abstract contract BoxTestBase is Test, ERC1155Holder {
    MockOG internal token;
    OGClubFurniture internal furniture;
    OGClubBox internal box;
    address internal buyer;
    address internal stranger;
    address internal vault;
    uint256 internal seasonId;
    bytes32 internal constant OPENED_TOPIC = keccak256("BoxOpened(uint256,uint256,uint256,uint8,bytes32,bool)");

    function setUp() public virtual {
        vm.roll(100);
        vm.warp(1000);
        buyer = makeAddr("buyer");
        stranger = makeAddr("stranger");
        vault = makeAddr("vault");
        token = new MockOG(address(this));
        furniture = new OGClubFurniture(address(this), vault);
        // Season notice 0, as on the test network: seasons may open in the block they are created.
        box = new OGClubBox(token, furniture, vault, address(this), 0);
        furniture.grantMinter(address(box)); // The one immediate grant, right after deployment.
        token.mint(buyer, 1_000_000 ether);
        vm.prank(buyer);
        token.approve(address(box), type(uint256).max);
        seasonId = box.createSeason(101, 1000, 100_000, 3333, 1, defaultEntries());
    }

    /// @dev A second box over its own furniture, for tests that only exercise a different payment token.
    ///      It cannot share `furniture`: only the first grant there was immediate, so a second box would
    ///      wait seven days for activation.
    function deployBox(IERC20 token_) internal returns (OGClubBox other) {
        OGClubFurniture otherFurniture = new OGClubFurniture(address(this), vault);
        other = new OGClubBox(token_, otherFurniture, vault, address(this), 0);
        otherFurniture.grantMinter(address(other));
    }

    /// @dev Re-authorize the box after a revoke: the bootstrap grant is spent, so this is a seven-day proposal.
    function regrantBox() internal {
        furniture.grantMinter(address(box));
        assertFalse(furniture.minters(address(box)), "a re-grant must not be immediate");
        assertEq(furniture.pendingMinters(address(box)), block.timestamp + furniture.MINTER_DELAY());
        vm.warp(block.timestamp + furniture.MINTER_DELAY());
        vm.prank(stranger);
        furniture.activateMinter(address(box));
        assertTrue(furniture.minters(address(box)));
    }

    function defaultEntries() internal pure returns (OGClubBox.Entry[] memory entries) {
        entries = new OGClubBox.Entry[](3);
        entries[0] = OGClubBox.Entry(1, 0, 60, 0);
        entries[1] = OGClubBox.Entry(2, 1, 30, 4);
        entries[2] = OGClubBox.Entry(3, 2, 10, 3);
    }

    function buy(uint256 count) internal returns (uint256 purchaseId) {
        vm.prank(buyer);
        return box.buy(seasonId, count);
    }

    function target(uint256 purchaseId) internal view returns (uint256 targetBlock) {
        (,,, targetBlock,) = box.purchases(purchaseId);
    }

    function ready(uint256 purchaseId, bytes32 randao) internal returns (bytes memory header) {
        uint256 targetBlock = target(purchaseId);
        vm.roll(targetBlock + 1);
        header = HeaderBuilder.header(targetBlock, randao, 7);
        vm.setBlockhash(targetBlock, keccak256(header));
    }

    function assertOpenMatches(uint256 purchaseId, bytes32 randao, bytes memory header, bool expired) internal {
        (address recipient, uint256 season, uint256 count,,) = box.purchases(purchaseId);
        uint256[] memory expected = box.previewOpen(purchaseId, randao);
        OGClubBox.Entry[] memory entries = box.getEntries(season);
        uint256[] memory balances = new uint256[](entries.length);
        uint256[] memory mintedBefore = new uint256[](entries.length);
        for (uint256 i; i < entries.length; ++i) {
            balances[i] = furniture.balanceOf(recipient, entries[i].itemId);
            mintedBefore[i] = box.minted(season, entries[i].itemId);
        }
        vm.recordLogs();
        vm.prank(stranger);
        box.open(purchaseId, header);
        checkOpenLogs(purchaseId, expected, randao, expired);
        for (uint256 i; i < entries.length; ++i) {
            uint256 received;
            for (uint256 j; j < count; ++j) {
                if (expected[j] == entries[i].itemId) ++received;
            }
            assertEq(furniture.balanceOf(recipient, entries[i].itemId), balances[i] + received);
            assertEq(box.minted(season, entries[i].itemId), mintedBefore[i] + received);
            if (entries[i].cap != 0) assertLe(box.minted(season, entries[i].itemId), entries[i].cap);
        }
        (,,,, bool opened) = box.purchases(purchaseId);
        assertTrue(opened);
        assertTrue(box.delivered(purchaseId));
        assertEq(box.getStoredItems(purchaseId).length, 0);
        assertEq(token.balanceOf(address(box)), 0);
    }

    struct OpenLog {
        uint256 index;
        uint256 itemId;
        uint8 tier;
        bytes32 randao;
        bool expired;
    }

    function checkOpenLogs(uint256 purchaseId, uint256[] memory expected, bytes32 randao, bool expired) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (, uint256 season,,,) = box.purchases(purchaseId);
        OGClubBox.Entry[] memory entries = box.getEntries(season);
        uint256 openedEvents;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(box) && logs[i].topics[0] == OPENED_TOPIC) {
                assertEq(uint256(logs[i].topics[1]), purchaseId);
                OpenLog memory eventData = abi.decode(logs[i].data, (OpenLog));
                assertEq(eventData.index, openedEvents++);
                assertEq(eventData.itemId, expected[eventData.index]);
                assertEq(eventData.randao, expired ? bytes32(0) : randao);
                assertEq(eventData.expired, expired);
                for (uint256 j; j < entries.length; ++j) {
                    if (entries[j].itemId == eventData.itemId) assertEq(eventData.tier, entries[j].tier);
                }
            }
        }
        assertEq(openedEvents, expected.length);
    }
}
