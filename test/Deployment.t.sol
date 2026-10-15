// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {OGClubBox} from "../src/OGClubBox.sol";
import {OGClubFurniture} from "../src/OGClubFurniture.sol";
import {MockOG} from "../src/mocks/MockOG.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract DeploymentTest is Test {
    function test_DeployExplicitParametersNoEnvironment() public {
        address owner = makeAddr("launch owner");
        address vault = makeAddr("launch vault");
        address token = makeAddr("configured token without deployed code");
        Deploy script = new Deploy();
        (OGClubFurniture furniture, OGClubBox box) = script.deploy(token, vault, owner, 7 days);
        assertEq(furniture.owner(), owner);
        assertEq(box.owner(), owner);
        assertEq(address(box.token()), token);
        assertEq(address(box.furniture()), address(furniture));
        assertEq(box.vault(), vault);
        assertEq(box.seasonNotice(), 7 days);
        assertFalse(furniture.minters(address(box)));
        assertFalse(furniture.bootstrapped());
        (address receiver, uint256 amount) = furniture.royaltyInfo(1, 10_000);
        assertEq(receiver, owner);
        assertEq(amount, 500);
        checkRuntime(address(furniture).code);
        checkRuntime(address(box).code);
    }

    function checkRuntime(bytes memory code) internal pure {
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden runtime opcode");
        }
    }

    function test_ConstructorsDoNotCallDependencies() public {
        address owner = makeAddr("owner");
        address token = makeAddr("absent token");
        address furniture = makeAddr("absent furniture");
        OGClubBox box = new OGClubBox(IERC20(token), OGClubFurniture(furniture), owner, owner, 0);
        assertEq(box.owner(), owner);
        assertEq(address(box.furniture()), furniture);
    }

    function test_InvalidConstructorAddresses() public {
        OGClubFurniture furniture = new OGClubFurniture(address(this), address(this));
        MockOG token = new MockOG(address(this));
        vm.expectRevert(OGClubBox.InvalidAddress.selector);
        new OGClubBox(IERC20(address(0)), furniture, address(this), address(this), 0);
        vm.expectRevert(OGClubBox.InvalidAddress.selector);
        new OGClubBox(token, OGClubFurniture(address(0)), address(this), address(this), 0);
        vm.expectRevert(OGClubBox.InvalidAddress.selector);
        new OGClubBox(token, furniture, address(0), address(this), 0);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new OGClubBox(token, furniture, address(this), address(0), 0);
        Deploy script = new Deploy();
        vm.expectRevert(Deploy.InvalidConfiguration.selector);
        script.deploy(address(0), address(this), address(this), 0);
        vm.expectRevert(Deploy.InvalidConfiguration.selector);
        script.deploy(address(token), address(0), address(this), 0);
        vm.expectRevert(Deploy.InvalidConfiguration.selector);
        script.deploy(address(token), address(this), address(0), 0);
    }

    /// @dev The season notice is fixed at construction and bounded by MAX_SEASON_NOTICE (30 days): the bound
    ///      itself is accepted, one second more is refused, through the constructor and through the script.
    function test_SeasonNoticeIsImmutableAndAtMostThirtyDays() public {
        OGClubFurniture furniture = new OGClubFurniture(address(this), address(this));
        MockOG token = new MockOG(address(this));
        uint256 maximum = 30 days;
        OGClubBox widest = new OGClubBox(token, furniture, address(this), address(this), maximum);
        assertEq(widest.MAX_SEASON_NOTICE(), maximum);
        assertEq(widest.seasonNotice(), maximum);
        vm.expectRevert(abi.encodeWithSelector(OGClubBox.InvalidSeasonNotice.selector, maximum + 1, maximum));
        new OGClubBox(token, furniture, address(this), address(this), maximum + 1);
        vm.expectRevert(abi.encodeWithSelector(OGClubBox.InvalidSeasonNotice.selector, type(uint256).max, maximum));
        new OGClubBox(token, furniture, address(this), address(this), type(uint256).max);
        Deploy script = new Deploy();
        vm.expectRevert(abi.encodeWithSelector(OGClubBox.InvalidSeasonNotice.selector, maximum + 1, maximum));
        script.deploy(address(token), address(this), address(this), maximum + 1);
        (, OGClubBox none) = script.deploy(address(token), address(this), address(this), 0);
        assertEq(none.seasonNotice(), 0);
        // No setter exists: the notice cannot be changed after deployment.
        (bool ok,) = address(none).call(abi.encodeWithSignature("setSeasonNotice(uint256)", 1));
        assertFalse(ok);
        assertEq(none.seasonNotice(), 0);
    }

    function test_MockSupplySymbolDecimalsAndPublicMint() public {
        address recipient = makeAddr("explicit initial recipient");
        MockOG token = new MockOG(recipient);
        assertEq(token.symbol(), "mockog");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1_000_000_000_000 ether);
        assertEq(token.balanceOf(recipient), token.totalSupply());
        assertEq(token.balanceOf(address(this)), 0);
        vm.prank(makeAddr("any minter"));
        token.mint(recipient, 7 ether);
        assertEq(token.totalSupply(), 1_000_000_000_007 ether);
    }
}
