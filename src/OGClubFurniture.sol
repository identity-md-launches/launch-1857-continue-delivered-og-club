// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {ERC1155Supply} from "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Supply.sol";
import {ERC2981} from "@openzeppelin/contracts/token/common/ERC2981.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @title OG Club Furniture
/// @notice ERC-1155 furniture with designated minters, freezable metadata and bounded royalties.
/// @dev Ownership provides no transfer approval, confiscation or burn privilege.
contract OGClubFurniture is ERC1155, ERC1155Supply, ERC2981, Ownable2Step {
    string public constant name = "OG Club Furniture";
    string public constant symbol = "OGFURNI";
    uint96 public constant MAX_ROYALTY_BPS = 1000;
    uint256 public constant MINTER_DELAY = 7 days;

    string public baseURI;
    bool public metadataFrozen;
    /// @notice Set by the first successful grantMinter, the one immediate grant (meant for the box right after
    ///         deployment). Every later grant is a MINTER_DELAY proposal whatever the supply.
    bool public bootstrapped;
    mapping(address minter => bool allowed) public minters;
    mapping(address minter => uint256 activatesAt) public pendingMinters;

    error ZeroAddress();
    error NotMinter(address caller);
    error NoMinterProposal(address minter);
    error MinterDelayNotElapsed(address minter, uint256 activatesAt);
    error MetadataFrozen();
    error RoyaltyTooHigh(uint96 bps);

    event MinterSet(address indexed minter, bool allowed);
    event MinterProposed(address indexed minter, uint256 activatesAt);
    event MinterProposalCancelled(address indexed minter);
    event BaseURISet(string baseURI);
    event MetadataPermanentlyFrozen(string baseURI);
    event RoyaltySet(address indexed receiver, uint96 bps);

    /// @param initialOwner The account that controls minters, metadata and royalties.
    /// @param royaltyReceiver Initial royalty beneficiary (500 basis points).
    constructor(address initialOwner, address royaltyReceiver) ERC1155("") Ownable(initialOwner) {
        if (royaltyReceiver == address(0)) revert ZeroAddress();
        _setDefaultRoyalty(royaltyReceiver, 500);
        emit RoyaltySet(royaltyReceiver, 500);
    }

    /// @notice The first grant ever takes effect at once; every later one proposes activation in seven days.
    /// @dev Re-proposing restarts the delay. An existing authorization stays active until revoked. Supply plays
    ///      no part: a second grant waits even while nothing has been delivered yet.
    function grantMinter(address minter) external onlyOwner {
        if (minter == address(0)) revert ZeroAddress();
        if (!bootstrapped) {
            bootstrapped = true;
            delete pendingMinters[minter];
            minters[minter] = true;
            emit MinterSet(minter, true);
        } else {
            uint256 activatesAt = block.timestamp + MINTER_DELAY;
            pendingMinters[minter] = activatesAt;
            emit MinterProposed(minter, activatesAt);
        }
    }

    /// @notice Anyone may activate a proposal once its delay has elapsed.
    function activateMinter(address minter) external {
        uint256 activatesAt = pendingMinters[minter];
        if (activatesAt == 0) revert NoMinterProposal(minter);
        if (block.timestamp < activatesAt) revert MinterDelayNotElapsed(minter, activatesAt);
        delete pendingMinters[minter];
        minters[minter] = true;
        emit MinterSet(minter, true);
    }

    /// @notice Cancel a pending proposal without changing any existing authorization.
    function cancelMinter(address minter) external onlyOwner {
        if (pendingMinters[minter] == 0) revert NoMinterProposal(minter);
        delete pendingMinters[minter];
        emit MinterProposalCancelled(minter);
    }

    /// @notice Immediately revoke minting and discard any pending proposal.
    function revokeMinter(address minter) external onlyOwner {
        if (minter == address(0)) revert ZeroAddress();
        delete pendingMinters[minter];
        minters[minter] = false;
        emit MinterSet(minter, false);
    }

    /// @notice Mint piece IDs and quantities; only an explicitly authorized minter may call.
    function mintBatch(address to, uint256[] calldata ids, uint256[] calldata amounts) external {
        if (!minters[msg.sender]) revert NotMinter(msg.sender);
        _mintBatch(to, ids, amounts, "");
    }

    /// @notice Set the metadata prefix, including any desired trailing slash, until frozen.
    function setBaseURI(string calldata newBaseURI) external onlyOwner {
        if (metadataFrozen) revert MetadataFrozen();
        baseURI = newBaseURI;
        emit BaseURISet(newBaseURI);
    }

    /// @notice Permanently prevent further changes to the metadata prefix.
    function freezeMetadata() external onlyOwner {
        if (metadataFrozen) revert MetadataFrozen();
        metadataFrozen = true;
        emit MetadataPermanentlyFrozen(baseURI);
    }

    /// @notice Change the default royalty receiver and rate, up to 10%.
    function setRoyalty(address receiver, uint96 bps) external onlyOwner {
        if (receiver == address(0)) revert ZeroAddress();
        if (bps > MAX_ROYALTY_BPS) revert RoyaltyTooHigh(bps);
        _setDefaultRoyalty(receiver, bps);
        emit RoyaltySet(receiver, bps);
    }

    /// @notice Return baseURI + decimal piece ID + ".json", including for unminted IDs.
    function uri(uint256 id) public view override returns (string memory) {
        return string.concat(baseURI, Strings.toString(id), ".json");
    }

    /// @inheritdoc ERC1155
    function supportsInterface(bytes4 interfaceId) public view override(ERC1155, ERC2981) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    /// @dev Keep ERC-1155 balances and supply accounting on the same update path.
    function _update(address from, address to, uint256[] memory ids, uint256[] memory amounts)
        internal
        override(ERC1155, ERC1155Supply)
    {
        super._update(from, to, ids, amounts);
    }
}
