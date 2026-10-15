// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OGClubFurniture} from "../src/OGClubFurniture.sol";
import {OGClubBox} from "../src/OGClubBox.sol";

/// @notice Deployment preparation for the two application contracts; never reads a private key.
/// @dev `run` reads TOKEN, VAULT, OWNER and SEASON_NOTICE (seconds, at most 30 days; 7 days on mainnet, 0 on
///      test networks). The initial royalty recipient is OWNER.
contract Deploy is Script {
    error InvalidConfiguration();

    /// @notice Use environment-provided addresses and the operator's externally configured signer.
    function run() external returns (OGClubFurniture furniture, OGClubBox box) {
        address token = vm.envAddress("TOKEN");
        address vault = vm.envAddress("VAULT");
        address owner = vm.envAddress("OWNER");
        uint256 seasonNotice = vm.envUint("SEASON_NOTICE");
        _validate(token, vault, owner);
        vm.startBroadcast();
        (furniture, box) = deploy(token, vault, owner, seasonNotice);
        vm.stopBroadcast();
    }

    /// @notice Deploy using explicit parameters; callable in local tests without environment or broadcast.
    function deploy(address token, address vault, address owner, uint256 seasonNotice)
        public
        returns (OGClubFurniture furniture, OGClubBox box)
    {
        _validate(token, vault, owner);
        furniture = new OGClubFurniture(owner, owner);
        box = new OGClubBox(IERC20(token), furniture, vault, owner, seasonNotice);
    }

    function _validate(address token, address vault, address owner) private pure {
        if (token == address(0) || vault == address(0) || owner == address(0)) revert InvalidConfiguration();
    }
}
