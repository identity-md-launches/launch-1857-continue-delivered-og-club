// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {OGClubFurniture} from "./OGClubFurniture.sol";
import {BlockHeader} from "./libraries/BlockHeader.sol";

/// @title OG Club Box
/// @notice Sell furniture boxes using an immutable season and a future block's authenticated prevRandao.
/// @dev No custody of purchase payments. Direct external calls are only to token and furniture.
contract OGClubBox is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Tier numbers are Common, Uncommon, Rare, Epic, Legendary (0 through 4).
    struct Entry {
        uint256 itemId;
        uint8 tier;
        uint256 weight;
        uint256 cap;
    }

    struct Season {
        uint256 price;
        uint256 opensAt;
        uint256 closesAt;
        uint256 burnBps;
        uint256 fallbackItem;
        bool closed;
        bool cancelled;
    }

    struct Purchase {
        address buyer;
        uint256 seasonId;
        uint256 count;
        uint256 targetBlock;
        bool opened;
        bool delivered;
    }

    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    uint256 public constant BPS = 10_000;
    uint256 public constant TARGET_DELAY = 3;
    uint256 public constant REVEAL_WINDOW = 256;
    /// @notice Gas forwarded to the initial delivery mint, always in full; retries may use more gas.
    uint256 public constant OPEN_MINT_GAS_LIMIT = 1_000_000;
    /// @notice Gas kept back from the mint: enough for ten cold item slots, the array length and catch overhead.
    uint256 public constant DELIVERY_RESERVE_GAS = 300_000;
    /// @notice Gas that must remain when delivery starts, or `open` reverts with InsufficientGas instead of
    ///         recording a delivery failure. Gas estimation therefore lands above it and no caller can starve
    ///         the mint of its full budget.
    uint256 public constant OPEN_DELIVERY_GAS = OPEN_MINT_GAS_LIMIT + DELIVERY_RESERVE_GAS;
    /// @notice Upper bound of a season's summed weights, so `seed % totalWeight` is unbiased to within 2^-128.
    uint256 public constant MAX_TOTAL_WEIGHT = 1 << 128;
    /// @notice Longest season notice a deployment may fix at construction.
    uint256 public constant MAX_SEASON_NOTICE = 30 days;

    IERC20 public immutable token;
    OGClubFurniture public immutable furniture;
    /// @notice Seconds every season must be announced ahead of its opening: createSeason requires
    ///         `opensAt >= block.timestamp + seasonNotice`, so no season can sell before it is public.
    uint256 public immutable seasonNotice;
    address public vault;
    bool public paused;
    uint256 public seasonCount;
    uint256 public purchaseCount;

    mapping(uint256 seasonId => Season) private _seasons;
    mapping(uint256 seasonId => Entry[]) private _entries;
    mapping(uint256 seasonId => mapping(uint256 itemId => uint256 amount)) public minted;
    mapping(uint256 purchaseId => Purchase) private _purchases;
    mapping(uint256 purchaseId => uint256[] itemIds) private _storedItems;

    error InvalidAddress();
    error InvalidEntryCount();
    error InvalidSeasonParameters();
    error InvalidSeasonNotice(uint256 notice, uint256 maximum);
    error SeasonOpensTooSoon(uint256 opensAt, uint256 earliest);
    error InvalidEntry(uint256 index);
    error DuplicateItem(uint256 itemId);
    error InvalidFallback();
    error WeightOverflow();
    error UnknownSeason(uint256 seasonId);
    error SeasonAlreadyClosed(uint256 seasonId);
    error SeasonAlreadyStarted(uint256 seasonId);
    error SalesUnavailable(uint256 seasonId);
    error BuyingPaused();
    error BoxNotMinter();
    error InvalidCount();
    error PaymentOverflow();
    error ShortTransfer(address recipient, uint256 expected, uint256 received);
    error UnknownPurchase(uint256 purchaseId);
    error AlreadyOpened(uint256 purchaseId);
    error NotOpened(uint256 purchaseId);
    error AlreadyDelivered(uint256 purchaseId);
    error NoStoredItems(uint256 purchaseId);
    error NotBuyer(uint256 purchaseId);
    error TargetBlockNotPassed(uint256 targetBlock);
    error HeaderHashMismatch();
    error HeaderNumberMismatch(uint256 expected, uint256 actual);
    error NoAvailableItems();
    error InsufficientGas(uint256 required, uint256 available);

    event SeasonCreated(
        uint256 indexed seasonId,
        uint256 price,
        uint256 opensAt,
        uint256 closesAt,
        uint256 burnBps,
        uint256 fallbackItem
    );
    event SeasonEntry(uint256 indexed seasonId, uint256 indexed itemId, uint8 tier, uint256 weight, uint256 cap);
    event SeasonClosed(uint256 indexed seasonId);
    event SeasonCancelled(uint256 indexed seasonId);
    event PausedSet(bool paused);
    event VaultSet(address indexed previousVault, address indexed newVault);
    event BoxesBought(
        uint256 indexed purchaseId,
        address indexed buyer,
        uint256 indexed seasonId,
        uint256 count,
        uint256 targetBlock,
        uint256 burnAmt,
        uint256 vaultAmt
    );
    event BoxOpened(
        uint256 indexed purchaseId, uint256 index, uint256 itemId, uint8 tier, bytes32 prevRandao, bool expired
    );
    event Delivered(uint256 indexed purchaseId, address indexed to);
    event DeliveryFailed(uint256 indexed purchaseId);

    /// @param token_ ERC-20 used for prices, in that token's smallest units.
    /// @param furniture_ Furniture contract which must authorize this box as a minter after deployment.
    /// @param vault_ Nonzero beneficiary of the unburned payment share.
    /// @param initialOwner Account allowed to create/stop seasons and manage sales settings.
    /// @param seasonNotice_ Seconds between a season's creation and the earliest `opensAt` it may carry, at most
    ///        MAX_SEASON_NOTICE. Fixed for the life of the contract.
    constructor(IERC20 token_, OGClubFurniture furniture_, address vault_, address initialOwner, uint256 seasonNotice_)
        Ownable(initialOwner)
    {
        if (address(token_) == address(0) || address(furniture_) == address(0)) revert InvalidAddress();
        if (seasonNotice_ > MAX_SEASON_NOTICE) revert InvalidSeasonNotice(seasonNotice_, MAX_SEASON_NOTICE);
        token = token_;
        furniture = furniture_;
        seasonNotice = seasonNotice_;
        _setVault(vault_);
    }

    /// @notice Create a season with permanent terms and at least one unlimited Common fallback.
    /// @dev IDs start at 1. Summed weights may not exceed MAX_TOTAL_WEIGHT. Seasons may overlap. A season
    ///      must open no earlier than `block.timestamp + seasonNotice`, so its terms are public for the
    ///      whole notice before anyone, the owner included, can buy from it.
    function createSeason(
        uint256 price,
        uint256 opensAt,
        uint256 closesAt,
        uint256 burnBps,
        uint256 fallbackItem,
        Entry[] calldata entries
    ) external onlyOwner returns (uint256 seasonId) {
        if (entries.length == 0 || entries.length > 32) revert InvalidEntryCount();
        if (price == 0 || opensAt >= closesAt || burnBps > BPS) revert InvalidSeasonParameters();
        uint256 earliest = block.timestamp + seasonNotice;
        if (opensAt < earliest) revert SeasonOpensTooSoon(opensAt, earliest);
        uint256 totalWeight;
        bool validFallback;
        for (uint256 i; i < entries.length; ++i) {
            Entry calldata entry = entries[i];
            if (entry.tier > 4 || entry.weight == 0) revert InvalidEntry(i);
            if (entry.weight > MAX_TOTAL_WEIGHT - totalWeight) revert WeightOverflow();
            totalWeight += entry.weight;
            for (uint256 j; j < i; ++j) {
                if (entry.itemId == entries[j].itemId) revert DuplicateItem(entry.itemId);
            }
            if (entry.itemId == fallbackItem && entry.cap == 0 && entry.tier == 0) validFallback = true;
        }
        if (!validFallback) revert InvalidFallback();

        seasonId = ++seasonCount;
        _seasons[seasonId] = Season(price, opensAt, closesAt, burnBps, fallbackItem, false, false);
        emit SeasonCreated(seasonId, price, opensAt, closesAt, burnBps, fallbackItem);
        for (uint256 i; i < entries.length; ++i) {
            _entries[seasonId].push(entries[i]);
            emit SeasonEntry(seasonId, entries[i].itemId, entries[i].tier, entries[i].weight, entries[i].cap);
        }
    }

    /// @notice Permanently stop this season's sales without preventing existing purchases from opening.
    function closeSeason(uint256 seasonId) external onlyOwner {
        Season storage season = _season(seasonId);
        if (season.closed) revert SeasonAlreadyClosed(seasonId);
        season.closed = true;
        emit SeasonClosed(seasonId);
    }

    /// @notice Cancel an unstarted, not-yet-closed season. Cancellation is permanent.
    function cancelSeason(uint256 seasonId) external onlyOwner {
        Season storage season = _season(seasonId);
        if (season.closed) revert SeasonAlreadyClosed(seasonId);
        if (block.timestamp >= season.opensAt) revert SeasonAlreadyStarted(seasonId);
        season.closed = true;
        season.cancelled = true;
        emit SeasonCancelled(seasonId);
    }

    /// @notice Pause or resume purchases; reveals remain permissionless.
    function setPaused(bool value) external onlyOwner {
        paused = value;
        emit PausedSet(value);
    }

    /// @notice Set the destination of future purchases' vault share.
    function setVault(address newVault) external onlyOwner {
        _setVault(newVault);
    }

    /// @notice Pay for 1–10 boxes and commit to a target three blocks in the future.
    /// @dev Both payment legs go directly from the buyer to their recipients. A revert is atomic.
    ///      Sales require the furniture contract to currently authorize this box as a minter, so no
    ///      payment is taken while the box's minting permission is revoked.
    function buy(uint256 seasonId, uint256 count) external nonReentrant returns (uint256 purchaseId) {
        Season storage season = _season(seasonId);
        if (count == 0 || count > 10) revert InvalidCount();
        if (paused) revert BuyingPaused();
        if (season.closed || block.timestamp < season.opensAt || block.timestamp >= season.closesAt) {
            revert SalesUnavailable(seasonId);
        }
        if (!furniture.minters(address(this))) revert BoxNotMinter();
        if (season.price > type(uint256).max / count) revert PaymentOverflow();
        uint256 total = season.price * count;
        uint256 burnAmt = Math.mulDiv(total, season.burnBps, BPS);
        uint256 vaultAmt = total - burnAmt;
        address recipient = vault;
        uint256 targetBlock = block.number + TARGET_DELAY;
        purchaseId = ++purchaseCount;
        _purchases[purchaseId] = Purchase(msg.sender, seasonId, count, targetBlock, false, false);

        _pay(BURN_ADDRESS, burnAmt);
        _pay(recipient, vaultAmt);
        emit BoxesBought(purchaseId, msg.sender, seasonId, count, targetBlock, burnAmt, vaultAmt);
    }

    /// @notice Open a purchase for its buyer using the target block's complete RLP header.
    /// @dev Expired purchases ignore the header and roll only the fallback. Caps reserve even undelivered items.
    ///      Delivery failures store the final roll for retry; receiver callbacks cannot veto the opening.
    ///      Reverts with InsufficientGas unless OPEN_DELIVERY_GAS remains when delivery starts.
    function open(uint256 purchaseId, bytes calldata header) external nonReentrant {
        Purchase memory purchase = _openable(purchaseId);
        bool expired = block.number - purchase.targetBlock > REVEAL_WINDOW;
        bytes32 prevRandao;
        if (!expired) {
            if (keccak256(header) != blockhash(purchase.targetBlock)) revert HeaderHashMismatch();
            uint256 number;
            (number, prevRandao) = BlockHeader.decode(header);
            if (number != purchase.targetBlock) revert HeaderNumberMismatch(purchase.targetBlock, number);
        }

        _purchases[purchaseId].opened = true;
        (uint256[] memory ids, uint8[] memory tiers) = _roll(purchaseId, purchase, prevRandao, expired);
        uint256[] memory amounts = new uint256[](purchase.count);
        for (uint256 i; i < purchase.count; ++i) {
            ++minted[purchase.seasonId][ids[i]];
            amounts[i] = 1;
            emit BoxOpened(purchaseId, i, ids[i], tiers[i], prevRandao, expired);
        }
        // A caller short of gas is a precondition failure, not a delivery failure: revert the whole opening rather
        // than starve the mint and store a healthy roll. Past this check the mint always receives its full budget
        // and the reserve still saves the largest roll even if the receiver exhausts that budget.
        uint256 available = gasleft();
        if (available < OPEN_DELIVERY_GAS) revert InsufficientGas(OPEN_DELIVERY_GAS, available);
        try furniture.mintBatch{gas: OPEN_MINT_GAS_LIMIT}(purchase.buyer, ids, amounts) {
            _purchases[purchaseId].delivered = true;
            emit Delivered(purchaseId, purchase.buyer);
        } catch {
            _storedItems[purchaseId] = ids;
            emit DeliveryFailed(purchaseId);
        }
    }

    /// @notice Anyone may retry delivery of an opened purchase's recorded items to its buyer.
    function deliver(uint256 purchaseId) external nonReentrant {
        _deliver(purchaseId, _purchases[purchaseId].buyer);
    }

    /// @notice The buyer may redirect a failed delivery to another nonzero recipient.
    function deliverTo(uint256 purchaseId, address to) external nonReentrant {
        if (_purchases[purchaseId].buyer != msg.sender) revert NotBuyer(purchaseId);
        if (to == address(0)) revert InvalidAddress();
        _deliver(purchaseId, to);
    }

    function _deliver(uint256 purchaseId, address to) private {
        Purchase storage purchase = _purchases[purchaseId];
        if (purchase.buyer == address(0)) revert UnknownPurchase(purchaseId);
        if (!purchase.opened) revert NotOpened(purchaseId);
        if (purchase.delivered) revert AlreadyDelivered(purchaseId);
        uint256[] memory ids = _storedItems[purchaseId];
        if (ids.length == 0) revert NoStoredItems(purchaseId);
        purchase.delivered = true;
        delete _storedItems[purchaseId];
        uint256[] memory amounts = new uint256[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            amounts[i] = 1;
        }
        // A revert restores both the delivered flag and stored items, allowing another retry.
        furniture.mintBatch(to, ids, amounts);
        emit Delivered(purchaseId, to);
    }

    /// @notice Original purchase view; delivery status is exposed separately without changing this ABI.
    function purchases(uint256 purchaseId)
        external
        view
        returns (address buyer, uint256 seasonId, uint256 count, uint256 targetBlock, bool opened)
    {
        Purchase storage purchase = _purchases[purchaseId];
        return (purchase.buyer, purchase.seasonId, purchase.count, purchase.targetBlock, purchase.opened);
    }

    /// @notice Whether the purchase has been delivered, either at open or by a later retry.
    function delivered(uint256 purchaseId) external view returns (bool) {
        return _purchases[purchaseId].delivered;
    }

    /// @notice Final rolled IDs, in box order with duplicates, only while a failed delivery is outstanding.
    function getStoredItems(uint256 purchaseId) external view returns (uint256[] memory) {
        return _storedItems[purchaseId];
    }

    /// @notice Predict an open using current caps and the supplied prevRandao (not authenticated by this view).
    /// @dev Same readiness checks and roll path as open. Expired previews ignore prevRandao.
    ///      Another open can only sell out a capped entry, which degrades a pending pick of that entry to the
    ///      fallback (or re-rolls a guaranteed tenth box among the remaining rares); this view reserves nothing.
    function previewOpen(uint256 purchaseId, bytes32 prevRandao) external view returns (uint256[] memory itemIds) {
        Purchase memory purchase = _openable(purchaseId);
        (itemIds,) = _roll(purchaseId, purchase, prevRandao, block.number - purchase.targetBlock > REVEAL_WINDOW);
    }

    /// @notice Read a season's immutable terms and terminal sales flags.
    function getSeason(uint256 seasonId) external view returns (Season memory) {
        return _season(seasonId);
    }

    /// @notice Read the original entries in their original weighted-roll order.
    function getEntries(uint256 seasonId) external view returns (Entry[] memory) {
        _season(seasonId);
        return _entries[seasonId];
    }

    function _setVault(address newVault) private {
        if (newVault == address(0) || newVault == address(this)) revert InvalidAddress();
        emit VaultSet(vault, newVault);
        vault = newVault;
    }

    /// @dev A recipient must gain the full amount. A recipient paying itself keeps its balance instead, so that
    ///      leg only requires no loss; a self-transfer that loses tokens still reverts.
    function _pay(address recipient, uint256 amount) private {
        if (amount == 0) return;
        uint256 beforeBalance = token.balanceOf(recipient);
        token.safeTransferFrom(msg.sender, recipient, amount);
        uint256 afterBalance = token.balanceOf(recipient);
        uint256 expected = recipient == msg.sender ? 0 : amount;
        uint256 received = afterBalance >= beforeBalance ? afterBalance - beforeBalance : 0;
        if (afterBalance < beforeBalance || received < expected) revert ShortTransfer(recipient, expected, received);
    }

    function _season(uint256 seasonId) private view returns (Season storage season) {
        if (seasonId == 0 || seasonId > seasonCount) revert UnknownSeason(seasonId);
        return _seasons[seasonId];
    }

    function _openable(uint256 purchaseId) private view returns (Purchase memory purchase) {
        purchase = _purchases[purchaseId];
        if (purchase.buyer == address(0)) revert UnknownPurchase(purchaseId);
        if (purchase.opened) revert AlreadyOpened(purchaseId);
        if (block.number <= purchase.targetBlock) revert TargetBlockNotPassed(purchase.targetBlock);
    }

    /// @dev Simulate every mint locally so preview and execution share cap depletion and the ten-pack rule.
    function _roll(uint256 purchaseId, Purchase memory purchase, bytes32 prevRandao, bool expired)
        private
        view
        returns (uint256[] memory ids, uint8[] memory tiers)
    {
        ids = new uint256[](purchase.count);
        tiers = new uint8[](purchase.count);
        if (expired) {
            uint256 fallbackItem = _seasons[purchase.seasonId].fallbackItem;
            for (uint256 i; i < purchase.count; ++i) {
                ids[i] = fallbackItem;
            }
            return (ids, tiers);
        }

        Entry[] storage entries = _entries[purchase.seasonId];
        uint256[] memory picks = _picks(purchaseId, purchase, prevRandao, entries);
        for (uint256 i; i < picks.length; ++i) {
            ids[i] = entries[picks[i]].itemId;
            tiers[i] = entries[picks[i]].tier;
        }
    }

    /// @dev Entry index chosen for every box of a live purchase, with cap depletion simulated across the pack.
    function _picks(uint256 purchaseId, Purchase memory purchase, bytes32 prevRandao, Entry[] storage entries)
        private
        view
        returns (uint256[] memory picks)
    {
        picks = new uint256[](purchase.count);
        uint256[] memory counts = new uint256[](entries.length);
        uint256 fallbackItem = _seasons[purchase.seasonId].fallbackItem;
        uint256 fallbackIndex;
        for (uint256 j; j < entries.length; ++j) {
            counts[j] = minted[purchase.seasonId][entries[j].itemId];
            if (entries[j].itemId == fallbackItem) fallbackIndex = j;
        }
        for (uint256 i; i < purchase.count; ++i) {
            uint256 seed = uint256(keccak256(abi.encode(prevRandao, block.chainid, address(this), purchaseId, i)));
            picks[i] = _pick(entries, counts, seed, fallbackIndex, purchase.count == 10 && i == 9);
            ++counts[picks[i]];
        }
    }

    /// @dev Fixed-odds pick. The seed selects over the season's full original weight, so the selected entry
    ///      depends only on the seed and never on which other purchases opened first. A selected entry that
    ///      has already sold out degrades to the fallback; a sell-out can therefore never improve a pending
    ///      pick. A guaranteed tenth box is handled by _pickRare first and falls through when no rare is left.
    function _pick(
        Entry[] storage entries,
        uint256[] memory counts,
        uint256 seed,
        uint256 fallbackIndex,
        bool guarantee
    ) private view returns (uint256) {
        if (guarantee) {
            (bool found, uint256 rare) = _pickRare(entries, counts, seed);
            if (found) return rare;
        }
        uint256 totalWeight;
        for (uint256 j; j < entries.length; ++j) {
            totalWeight += entries[j].weight;
        }
        uint256 picked = _walk(entries, counts, seed % totalWeight, false, false);
        return _available(entries[picked], counts[picked]) ? picked : fallbackIndex;
    }

    /// @dev Guaranteed tenth box: select over the full original weight of every tier >= 2 entry. Only when that
    ///      selection has sold out does a derived seed re-roll among the rares still available, keeping the
    ///      guarantee while one remains. Returns found = false when no rare entry is available.
    function _pickRare(Entry[] storage entries, uint256[] memory counts, uint256 seed)
        private
        view
        returns (bool found, uint256 picked)
    {
        uint256 rareWeight;
        uint256 availableRareWeight;
        for (uint256 j; j < entries.length; ++j) {
            Entry storage entry = entries[j];
            if (entry.tier < 2) continue;
            rareWeight += entry.weight;
            if (_available(entry, counts[j])) availableRareWeight += entry.weight;
        }
        if (availableRareWeight == 0) return (false, 0);
        picked = _walk(entries, counts, seed % rareWeight, true, false);
        if (!_available(entries[picked], counts[picked])) {
            uint256 retry = uint256(keccak256(abi.encode(seed)));
            picked = _walk(entries, counts, retry % availableRareWeight, true, true);
        }
        return (true, picked);
    }

    function _available(Entry storage entry, uint256 count) private view returns (bool) {
        return entry.cap == 0 || count < entry.cap;
    }

    /// @dev Walk entries in original order, skipping those outside the requested pool, until the roll is spent.
    function _walk(Entry[] storage entries, uint256[] memory counts, uint256 roll, bool rareOnly, bool availableOnly)
        private
        view
        returns (uint256)
    {
        for (uint256 j; j < entries.length; ++j) {
            Entry storage entry = entries[j];
            if (rareOnly && entry.tier < 2) continue;
            if (availableOnly && !_available(entry, counts[j])) continue;
            if (roll < entry.weight) return j;
            roll -= entry.weight;
        }
        revert NoAvailableItems(); // Unreachable: every roll is below the summed weight of the walked pool.
    }
}
