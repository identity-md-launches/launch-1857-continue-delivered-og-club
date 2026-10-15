// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BoxTestBase} from "./helpers/BoxTestBase.sol";
import {FeeToken, NoReturnToken, FalseReturnToken, ReentrantToken} from "./helpers/Adversaries.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {OGClubBox} from "../src/OGClubBox.sol";

contract PaymentsTest is BoxTestBase {
    event BoxesBought(
        uint256 indexed purchaseId,
        address indexed buyer,
        uint256 indexed seasonId,
        uint256 count,
        uint256 targetBlock,
        uint256 burnAmt,
        uint256 vaultAmt
    );

    function test_ExactSplitsAndEvents() public {
        uint256[5] memory prices = [uint256(1), 7, 101, 123456789, 1 ether];
        uint256[5] memory rates = [uint256(0), 1, 3333, 9999, 10_000];
        for (uint256 i; i < prices.length; ++i) {
            for (uint256 j; j < rates.length; ++j) {
                uint256 season = box.createSeason(prices[i], 1000, 100_000, rates[j], 1, defaultEntries());
                uint256 count = j + 1;
                uint256 total = prices[i] * count;
                uint256 burnAmount = total * rates[j] / 10_000;
                uint256 beforeBuyer = token.balanceOf(buyer);
                uint256 beforeBurn = token.balanceOf(box.BURN_ADDRESS());
                uint256 beforeVault = token.balanceOf(vault);
                vm.expectEmit(true, true, true, true, address(box));
                emit BoxesBought(
                    box.purchaseCount() + 1, buyer, season, count, block.number + 3, burnAmount, total - burnAmount
                );
                vm.prank(buyer);
                uint256 purchase = box.buy(season, count);
                assertEq(token.balanceOf(buyer), beforeBuyer - total);
                assertEq(token.balanceOf(box.BURN_ADDRESS()), beforeBurn + burnAmount);
                assertEq(token.balanceOf(vault), beforeVault + total - burnAmount);
                assertEq(token.balanceOf(address(box)), 0);
                (address storedBuyer, uint256 storedSeason, uint256 storedCount, uint256 targetBlock, bool opened) =
                    box.purchases(purchase);
                assertEq(storedBuyer, buyer);
                assertEq(storedSeason, season);
                assertEq(storedCount, count);
                assertEq(targetBlock, block.number + 3);
                assertFalse(opened);
            }
        }
    }

    function testFuzz_SplitConservesPayment(uint128 price, uint16 bps, uint8 count) public {
        price = uint128(bound(price, 1, type(uint128).max));
        bps = uint16(bound(bps, 0, 10_000));
        count = uint8(bound(count, 1, 10));
        uint256 season = box.createSeason(price, 1000, 100_000, bps, 1, defaultEntries());
        uint256 total = uint256(price) * count;
        token.mint(buyer, total);
        uint256 beforeBuyer = token.balanceOf(buyer);
        vm.prank(buyer);
        box.buy(season, count);
        uint256 burnAmount = total * bps / 10_000;
        assertEq(token.balanceOf(box.BURN_ADDRESS()), burnAmount);
        assertEq(token.balanceOf(vault), total - burnAmount);
        assertEq(token.balanceOf(buyer), beforeBuyer - total);
        assertEq(token.balanceOf(address(box)), 0);
    }

    function test_FeeOnEitherLegRevertsBothTransfers() public {
        for (uint256 i; i < 2; ++i) {
            FeeToken feeToken = new FeeToken(i == 0 ? box.BURN_ADDRESS() : vault);
            OGClubBox feeBox = deployBox(feeToken);
            uint256 season = feeBox.createSeason(10_000, 1000, 100_000, 3000, 1, defaultEntries());
            feeToken.mint(buyer, 10_000);
            vm.prank(buyer);
            feeToken.approve(address(feeBox), 10_000);
            vm.prank(buyer);
            vm.expectPartialRevert(OGClubBox.ShortTransfer.selector);
            feeBox.buy(season, 1);
            assertEq(feeToken.balanceOf(buyer), 10_000);
            assertEq(feeToken.balanceOf(vault), 0);
            assertEq(feeToken.balanceOf(box.BURN_ADDRESS()), 0);
            assertEq(feeToken.balanceOf(address(feeBox)), 0);
            assertEq(feeBox.purchaseCount(), 0);
            assertEq(feeToken.allowance(buyer, address(feeBox)), 10_000);
        }
    }

    function test_InsufficientAllowanceRollsBackFirstLeg() public {
        vm.prank(buyer);
        token.approve(address(box), 50); // Burn leg succeeds, then vault leg fails.
        uint256 beforeBuyer = token.balanceOf(buyer);
        vm.prank(buyer);
        vm.expectRevert();
        box.buy(seasonId, 1);
        assertEq(token.balanceOf(buyer), beforeBuyer);
        assertEq(token.balanceOf(vault), 0);
        assertEq(token.balanceOf(box.BURN_ADDRESS()), 0);
        assertEq(box.purchaseCount(), 0);
        assertEq(token.allowance(buyer, address(box)), 50);
    }

    function test_NoReturnTokenSupported() public {
        NoReturnToken noReturn = new NoReturnToken();
        OGClubBox other = deployBox(IERC20(address(noReturn)));
        uint256 season = other.createSeason(101, 1000, 100_000, 3333, 1, defaultEntries());
        noReturn.mint(buyer, 101);
        vm.prank(buyer);
        noReturn.approve(address(other), 101);
        vm.prank(buyer);
        other.buy(season, 1);
        assertEq(noReturn.balanceOf(box.BURN_ADDRESS()), 33);
        assertEq(noReturn.balanceOf(vault), 68);
        assertEq(noReturn.balanceOf(address(other)), 0);
    }

    function test_FalseReturnTokenRejected() public {
        FalseReturnToken bad = new FalseReturnToken();
        OGClubBox other = deployBox(bad);
        uint256 season = other.createSeason(101, 1000, 100_000, 0, 1, defaultEntries());
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(bad)));
        other.buy(season, 1);
        assertEq(other.purchaseCount(), 0);
    }

    function test_TokenCallbackCannotReenter() public {
        ReentrantToken callback = new ReentrantToken();
        OGClubBox other = deployBox(callback);
        uint256 season = other.createSeason(101, 1000, 100_000, 3333, 1, defaultEntries());
        callback.configure(other, season);
        callback.mint(buyer, 101);
        vm.prank(buyer);
        callback.approve(address(other), 101);
        vm.prank(buyer);
        other.buy(season, 1);
        assertEq(callback.attempts(), 2);
        assertFalse(callback.buySucceeded());
        assertFalse(callback.openSucceeded());
        assertEq(other.purchaseCount(), 1);
    }

    function test_ChangingVaultAndSameRecipient() public {
        address nextVault = makeAddr("next vault");
        box.setVault(nextVault);
        buy(1);
        assertEq(token.balanceOf(vault), 0);
        assertEq(token.balanceOf(nextVault), 68);
        box.setVault(box.BURN_ADDRESS());
        uint256 burnBefore = token.balanceOf(box.BURN_ADDRESS());
        buy(1);
        assertEq(token.balanceOf(box.BURN_ADDRESS()), burnBefore + 101);
        assertEq(token.balanceOf(address(box)), 0);
    }

    function test_VaultCanBuyAndOnlyPartsWithTheBurnShare() public {
        token.mint(vault, 1_000);
        vm.prank(vault);
        token.approve(address(box), type(uint256).max);
        uint256 burnBefore = token.balanceOf(box.BURN_ADDRESS());
        vm.prank(vault);
        uint256 purchase = box.buy(seasonId, 1); // price 101 at 3333 bps: 33 burned, 68 vault-to-vault
        assertEq(token.balanceOf(vault), 1_000 - 33);
        assertEq(token.balanceOf(box.BURN_ADDRESS()), burnBefore + 33);
        assertEq(token.balanceOf(address(box)), 0);
        (address storedBuyer,, uint256 storedCount,,) = box.purchases(purchase);
        assertEq(storedBuyer, vault);
        assertEq(storedCount, 1);
        // A self-transfer that loses tokens is still refused.
        FeeToken feeToken = new FeeToken(vault);
        OGClubBox feeBox = deployBox(feeToken);
        uint256 season = feeBox.createSeason(10_000, 1000, 100_000, 3000, 1, defaultEntries());
        feeToken.mint(vault, 10_000);
        vm.prank(vault);
        feeToken.approve(address(feeBox), 10_000);
        vm.prank(vault);
        vm.expectRevert(abi.encodeWithSelector(OGClubBox.ShortTransfer.selector, vault, 0, 0));
        feeBox.buy(season, 1);
        assertEq(feeToken.balanceOf(vault), 10_000);
        assertEq(feeBox.purchaseCount(), 0);
    }

    function test_VaultCannotBeBoxOrZero() public {
        vm.expectRevert(OGClubBox.InvalidAddress.selector);
        box.setVault(address(0));
        vm.expectRevert(OGClubBox.InvalidAddress.selector);
        box.setVault(address(box));
    }

    function test_PriceMultiplicationOverflowHasCustomError() public {
        uint256 season = box.createSeason(type(uint256).max, 1000, 100_000, 10_000, 1, defaultEntries());
        vm.expectRevert(OGClubBox.PaymentOverflow.selector);
        box.buy(season, 2);
    }
}
