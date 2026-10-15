// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC1155Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {OGClubFurniture} from "../src/OGClubFurniture.sol";

contract FurnitureTest is Test {
    OGClubFurniture internal furniture;
    address internal minter = makeAddr("minter");
    address internal buyer = makeAddr("buyer");
    address internal recipient = makeAddr("royalty recipient");

    function setUp() public {
        furniture = new OGClubFurniture(address(this), recipient);
    }

    function arrays() internal pure returns (uint256[] memory ids, uint256[] memory amounts) {
        ids = new uint256[](3);
        amounts = new uint256[](3);
        ids[0] = 1;
        ids[1] = 2;
        ids[2] = 1;
        amounts[0] = 4;
        amounts[1] = 3;
        amounts[2] = 2;
    }

    function test_IdentityInterfacesMintAndSupply() public {
        assertEq(furniture.name(), "OG Club Furniture");
        assertEq(furniture.symbol(), "OGFURNI");
        assertTrue(furniture.supportsInterface(0xd9b67a26)); // ERC-1155
        assertTrue(furniture.supportsInterface(0x0e89341c)); // Metadata
        assertTrue(furniture.supportsInterface(0x2a55205a)); // ERC-2981
        assertTrue(furniture.supportsInterface(0x01ffc9a7)); // ERC-165
        assertFalse(furniture.supportsInterface(0xffffffff));
        (uint256[] memory ids, uint256[] memory amounts) = arrays();
        vm.expectRevert(abi.encodeWithSelector(OGClubFurniture.NotMinter.selector, address(this)));
        furniture.mintBatch(buyer, ids, amounts);
        furniture.grantMinter(minter);
        vm.prank(minter);
        furniture.mintBatch(buyer, ids, amounts);
        assertEq(furniture.balanceOf(buyer, 1), 6);
        assertEq(furniture.balanceOf(buyer, 2), 3);
        assertEq(furniture.totalSupply(1), 6);
        assertEq(furniture.totalSupply(), 9);
        assertTrue(furniture.exists(1));
        assertFalse(furniture.exists(42));
        furniture.revokeMinter(minter);
        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(OGClubFurniture.NotMinter.selector, minter));
        furniture.mintBatch(buyer, ids, amounts);
    }

    function test_MetadataFreezesPermanently() public {
        assertEq(furniture.uri(0), "0.json");
        furniture.setBaseURI("ipfs://content/");
        assertEq(furniture.uri(123456), "ipfs://content/123456.json");
        furniture.freezeMetadata();
        assertTrue(furniture.metadataFrozen());
        vm.expectRevert(OGClubFurniture.MetadataFrozen.selector);
        furniture.setBaseURI("changed/");
        vm.expectRevert(OGClubFurniture.MetadataFrozen.selector);
        furniture.freezeMetadata();
    }

    function test_RoyaltyDefaultAndLimits() public {
        (address receiver, uint256 amount) = furniture.royaltyInfo(888, 10_000);
        assertEq(receiver, recipient);
        assertEq(amount, 500);
        furniture.setRoyalty(buyer, 1000);
        (receiver, amount) = furniture.royaltyInfo(1, 101);
        assertEq(receiver, buyer);
        assertEq(amount, 10);
        vm.expectRevert(abi.encodeWithSelector(OGClubFurniture.RoyaltyTooHigh.selector, uint96(1001)));
        furniture.setRoyalty(buyer, 1001);
        vm.expectRevert(OGClubFurniture.ZeroAddress.selector);
        furniture.setRoyalty(address(0), 0);
        furniture.setRoyalty(buyer, 0);
        (, amount) = furniture.royaltyInfo(1, 10_000);
        assertEq(amount, 0);
    }

    function test_NoOwnerSeizureOrBurn() public {
        (uint256[] memory ids, uint256[] memory amounts) = arrays();
        furniture.grantMinter(minter);
        vm.prank(minter);
        furniture.mintBatch(buyer, ids, amounts);
        vm.expectRevert(
            abi.encodeWithSelector(IERC1155Errors.ERC1155MissingApprovalForAll.selector, address(this), buyer)
        );
        furniture.safeTransferFrom(buyer, address(this), 1, 1, "");
        vm.expectRevert(
            abi.encodeWithSelector(IERC1155Errors.ERC1155MissingApprovalForAll.selector, address(this), buyer)
        );
        furniture.safeBatchTransferFrom(buyer, recipient, ids, amounts, "");
        (bool success,) = address(furniture).call(abi.encodeWithSignature("burn(address,uint256,uint256)", buyer, 1, 1));
        assertFalse(success);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IERC1155Errors.ERC1155InvalidReceiver.selector, address(0)));
        furniture.safeTransferFrom(buyer, address(0), 1, 1, "");
        vm.prank(buyer);
        furniture.safeTransferFrom(buyer, recipient, 1, 2, "");
        assertEq(furniture.balanceOf(recipient, 1), 2);
        assertEq(furniture.totalSupply(1), 6);
    }

    function test_AllOwnerFunctionsProtected() public {
        bytes[] memory calls = new bytes[](8);
        calls[0] = abi.encodeCall(furniture.grantMinter, (minter));
        calls[1] = abi.encodeCall(furniture.setBaseURI, ("x/"));
        calls[2] = abi.encodeCall(furniture.freezeMetadata, ());
        calls[3] = abi.encodeCall(furniture.setRoyalty, (buyer, 100));
        calls[4] = abi.encodeCall(furniture.transferOwnership, (buyer));
        calls[5] = abi.encodeCall(furniture.renounceOwnership, ());
        calls[6] = abi.encodeCall(furniture.cancelMinter, (minter));
        calls[7] = abi.encodeCall(furniture.revokeMinter, (minter));
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(buyer);
            (bool success, bytes memory reason) = address(furniture).call(calls[i]);
            assertFalse(success);
            assertEq(reason, abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, buyer));
        }
    }

    function test_OwnershipTwoStepAndRenounce() public {
        furniture.transferOwnership(buyer);
        assertEq(furniture.owner(), address(this));
        assertEq(furniture.pendingOwner(), buyer);
        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, minter));
        furniture.acceptOwnership();
        vm.prank(buyer);
        furniture.acceptOwnership();
        assertEq(furniture.owner(), buyer);
        assertEq(furniture.pendingOwner(), address(0));
        vm.prank(buyer);
        furniture.setBaseURI("new-owner/");
        vm.prank(buyer);
        furniture.renounceOwnership();
        assertEq(furniture.owner(), address(0));
    }

    function test_InvalidAddressesAndBatchLengths() public {
        vm.expectRevert(OGClubFurniture.ZeroAddress.selector);
        new OGClubFurniture(address(this), address(0));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new OGClubFurniture(address(0), recipient);
        vm.expectRevert(OGClubFurniture.ZeroAddress.selector);
        furniture.grantMinter(address(0));
        furniture.grantMinter(address(this));
        vm.expectRevert(abi.encodeWithSelector(IERC1155Errors.ERC1155InvalidArrayLength.selector, 1, 0));
        furniture.mintBatch(buyer, new uint256[](1), new uint256[](0));
    }
    event MinterSet(address indexed minter, bool allowed);
    event MinterProposed(address indexed minter, uint256 activatesAt);
    event MinterProposalCancelled(address indexed minter);

    function firstMint() internal {
        furniture.grantMinter(minter);
        (uint256[] memory ids, uint256[] memory amounts) = arrays();
        vm.prank(minter);
        furniture.mintBatch(buyer, ids, amounts);
    }

    /// @dev Exactly one grant is ever immediate: the first. The next grants are seven-day proposals even though
    ///      nothing has been minted, and activating them is the only way they become minters.
    function test_OnlyTheFirstGrantIsImmediateEvenBeforeAnyMint() public {
        assertFalse(furniture.bootstrapped());
        vm.expectEmit(true, false, false, true, address(furniture));
        emit MinterSet(minter, true);
        furniture.grantMinter(minter);
        assertTrue(furniture.bootstrapped());
        assertTrue(furniture.minters(minter));
        assertEq(furniture.pendingMinters(minter), 0);
        assertEq(furniture.totalSupply(), 0);

        address[2] memory later = [buyer, recipient];
        uint256 activatesAt = block.timestamp + 7 days;
        for (uint256 i; i < later.length; ++i) {
            vm.expectEmit(true, false, false, true, address(furniture));
            emit MinterProposed(later[i], activatesAt);
            furniture.grantMinter(later[i]);
            assertFalse(furniture.minters(later[i]), "a second grant must not be immediate");
            assertEq(furniture.pendingMinters(later[i]), activatesAt);
        }
        assertEq(furniture.totalSupply(), 0);
        (uint256[] memory ids, uint256[] memory amounts) = arrays();
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(OGClubFurniture.NotMinter.selector, buyer));
        furniture.mintBatch(buyer, ids, amounts);
        vm.warp(activatesAt);
        vm.prank(recipient);
        furniture.activateMinter(buyer);
        vm.prank(buyer);
        furniture.mintBatch(buyer, ids, amounts);
        assertEq(furniture.totalSupply(), 9);
        assertTrue(furniture.bootstrapped());
    }

    /// @dev A grant that reverts does not spend the bootstrap; the first successful one does, whoever it names.
    function test_RejectedGrantDoesNotSpendTheBootstrap() public {
        vm.expectRevert(OGClubFurniture.ZeroAddress.selector);
        furniture.grantMinter(address(0));
        assertFalse(furniture.bootstrapped());
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, buyer));
        furniture.grantMinter(buyer);
        assertFalse(furniture.bootstrapped());
        furniture.grantMinter(recipient);
        assertTrue(furniture.bootstrapped());
        assertTrue(furniture.minters(recipient));
    }

    /// @dev Revoking the first minter and granting it again waits the full delay, with supply still zero;
    ///      cancel and revoke behave on that proposal exactly as on any other, and the flag never clears.
    function test_RegrantingTheRevokedFirstMinterWaitsWithZeroSupply() public {
        furniture.grantMinter(minter);
        furniture.revokeMinter(minter);
        assertFalse(furniture.minters(minter));
        assertEq(furniture.totalSupply(), 0);
        assertTrue(furniture.bootstrapped());
        uint256 activatesAt = block.timestamp + 7 days;
        vm.expectEmit(true, false, false, true, address(furniture));
        emit MinterProposed(minter, activatesAt);
        furniture.grantMinter(minter);
        assertFalse(furniture.minters(minter), "re-grant of the revoked first minter took effect immediately");
        assertEq(furniture.pendingMinters(minter), activatesAt);
        vm.warp(activatesAt - 1);
        vm.expectRevert(abi.encodeWithSelector(OGClubFurniture.MinterDelayNotElapsed.selector, minter, activatesAt));
        furniture.activateMinter(minter);
        furniture.cancelMinter(minter);
        assertEq(furniture.pendingMinters(minter), 0);
        furniture.grantMinter(minter);
        assertEq(furniture.pendingMinters(minter), block.timestamp + 7 days);
        vm.warp(block.timestamp + 7 days);
        vm.prank(buyer);
        furniture.activateMinter(minter);
        assertTrue(furniture.minters(minter));
        (uint256[] memory ids, uint256[] memory amounts) = arrays();
        vm.prank(minter);
        furniture.mintBatch(buyer, ids, amounts);
        assertEq(furniture.totalSupply(), 9);
    }

    /// @dev Whatever the supply (zero, or after zero-amount mints), only the first grant is immediate.
    function testFuzz_EveryGrantAfterTheFirstWaitsSevenDays(address first, address second, uint32 elapsed) public {
        vm.assume(first != address(0) && second != address(0));
        furniture.grantMinter(first);
        assertTrue(furniture.minters(first));
        vm.warp(block.timestamp + elapsed);
        furniture.grantMinter(second);
        assertEq(furniture.minters(second), first == second, "a later grant changed the live role");
        assertEq(furniture.pendingMinters(second), block.timestamp + 7 days);
        assertEq(furniture.totalSupply(), 0);
    }

    function testFuzz_AfterFirstMintMustWaitAndAnyoneCanActivate(uint32 elapsed) public {
        firstMint();
        assertEq(furniture.MINTER_DELAY(), 7 days);
        uint256 proposedAt = block.timestamp;
        uint256 activatesAt = proposedAt + 7 days;
        vm.expectEmit(true, false, false, true, address(furniture));
        emit MinterProposed(recipient, activatesAt);
        furniture.grantMinter(recipient);
        assertFalse(furniture.minters(recipient));
        assertEq(furniture.pendingMinters(recipient), activatesAt);
        vm.warp(proposedAt + bound(elapsed, 0, 7 days - 1));
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(OGClubFurniture.MinterDelayNotElapsed.selector, recipient, activatesAt));
        furniture.activateMinter(recipient);
        (uint256[] memory ids, uint256[] memory amounts) = arrays();
        vm.prank(recipient);
        vm.expectRevert(abi.encodeWithSelector(OGClubFurniture.NotMinter.selector, recipient));
        furniture.mintBatch(buyer, ids, amounts);
        vm.warp(activatesAt);
        // Elapsed time alone is insufficient: the public activation must occur.
        vm.prank(recipient);
        vm.expectRevert(abi.encodeWithSelector(OGClubFurniture.NotMinter.selector, recipient));
        furniture.mintBatch(buyer, ids, amounts);
        vm.expectEmit(true, false, false, true, address(furniture));
        emit MinterSet(recipient, true);
        vm.prank(buyer);
        furniture.activateMinter(recipient);
        assertTrue(furniture.minters(recipient));
        assertEq(furniture.pendingMinters(recipient), 0);
        vm.prank(recipient);
        furniture.mintBatch(buyer, ids, amounts);
        assertEq(furniture.totalSupply(), 18);
        vm.expectRevert(abi.encodeWithSelector(OGClubFurniture.NoMinterProposal.selector, recipient));
        furniture.activateMinter(recipient);
    }

    function test_CancelStopsActivationEvenAfterDeadline() public {
        firstMint();
        furniture.grantMinter(recipient);
        vm.warp(block.timestamp + 8 days);
        vm.expectEmit(true, false, false, true, address(furniture));
        emit MinterProposalCancelled(recipient);
        furniture.cancelMinter(recipient);
        assertEq(furniture.pendingMinters(recipient), 0);
        assertFalse(furniture.minters(recipient));
        vm.expectRevert(abi.encodeWithSelector(OGClubFurniture.NoMinterProposal.selector, recipient));
        furniture.activateMinter(recipient);
        vm.expectRevert(abi.encodeWithSelector(OGClubFurniture.NoMinterProposal.selector, recipient));
        furniture.cancelMinter(recipient);
    }

    function test_RevokeIsImmediateClearsProposalsAndRegrantWaitsAgain() public {
        firstMint();
        furniture.grantMinter(minter); // Already active; a proposal does not revoke it.
        assertTrue(furniture.minters(minter));
        assertGt(furniture.pendingMinters(minter), 0);
        vm.expectEmit(true, false, false, true, address(furniture));
        emit MinterSet(minter, false);
        furniture.revokeMinter(minter);
        assertFalse(furniture.minters(minter));
        assertEq(furniture.pendingMinters(minter), 0);
        (uint256[] memory ids, uint256[] memory amounts) = arrays();
        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(OGClubFurniture.NotMinter.selector, minter));
        furniture.mintBatch(buyer, ids, amounts);
        vm.warp(block.timestamp + 8 days);
        vm.expectRevert(abi.encodeWithSelector(OGClubFurniture.NoMinterProposal.selector, minter));
        furniture.activateMinter(minter);
        furniture.grantMinter(minter);
        assertFalse(furniture.minters(minter));
        assertEq(furniture.pendingMinters(minter), block.timestamp + 7 days);
        furniture.revokeMinter(minter); // Revoking a pending-only account also removes its proposal.
        assertEq(furniture.pendingMinters(minter), 0);
    }

    function test_ReproposalRestartsDelayAndCancelDoesNotRevokeExistingRole() public {
        firstMint();
        furniture.grantMinter(recipient);
        uint256 oldDeadline = furniture.pendingMinters(recipient);
        vm.warp(oldDeadline - 1);
        furniture.grantMinter(recipient);
        uint256 newDeadline = furniture.pendingMinters(recipient);
        assertEq(newDeadline, block.timestamp + 7 days);
        vm.warp(oldDeadline);
        vm.expectRevert(abi.encodeWithSelector(OGClubFurniture.MinterDelayNotElapsed.selector, recipient, newDeadline));
        furniture.activateMinter(recipient);
        furniture.grantMinter(minter);
        furniture.cancelMinter(minter);
        assertTrue(furniture.minters(minter));
    }

    function test_ZeroAddressesAndLegacyMinterSelectorCannotGrant() public {
        firstMint();
        vm.expectRevert(OGClubFurniture.ZeroAddress.selector);
        furniture.grantMinter(address(0));
        vm.expectRevert(OGClubFurniture.ZeroAddress.selector);
        furniture.revokeMinter(address(0));
        vm.expectRevert(abi.encodeWithSelector(OGClubFurniture.NoMinterProposal.selector, address(0)));
        furniture.activateMinter(address(0));
        (bool ok,) = address(furniture).call(abi.encodeWithSignature("setMinter(address,bool)", recipient, true));
        assertFalse(ok);
        assertFalse(furniture.minters(recipient));
    }
}
