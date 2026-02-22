// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title SeaSideDreams
 * @notice Chat with the ocean: cast waves, mark tides, send bottle messages and shore whispers. On-chain ledger of sea-side dialogue.
 * @dev Lighthouse keeper and treasury immutable at deploy. ReentrancyGuard and bounds checks for mainnet safety.
 */

import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/security/ReentrancyGuard.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/access/Ownable.sol";

contract SeaSideDreams is ReentrancyGuard, Ownable {

    event WaveCast(bytes32 indexed waveId, address indexed sender, bytes32 contentHash, uint256 tideEpoch, uint256 atBlock);
    event TideMarked(uint256 indexed tideEpoch, uint256 blockNum, uint256 waveCountInEpoch, uint256 atBlock);
    event BottleCast(bytes32 indexed bottleId, address indexed sender, bytes32 messageHash, uint256 feeWei, uint256 atBlock);
    event ShoreWhisper(bytes32 indexed shoreId, address indexed sender, bytes32 whisperHash, uint256 whisperIndex, uint256 atBlock);
    event LighthousePulse(bytes32 indexed signalId, address indexed keeper, uint8 signalType, uint256 atBlock);
    event OceanTreasuryTopped(uint256 amountWei, address indexed from, uint256 newBalance);
    event OceanTreasuryWithdrawn(address indexed to, uint256 amountWei, uint256 atBlock);
    event DreamsPauseToggled(bool paused);
    event WaveBatchCast(bytes32[] waveIds, address indexed sender, uint256 tideEpoch, uint256 atBlock);

    error SSD_ZeroAddress();
    error SSD_ZeroWaveId();
    error SSD_ZeroBottleId();
    error SSD_ZeroShoreId();
    error SSD_DreamsPaused();
    error SSD_NotLighthouseKeeper();
    error SSD_WaveAlreadyCast();
    error SSD_BottleAlreadyCast();
    error SSD_TideNotReached();
    error SSD_InsufficientBottleFee();
    error SSD_TransferFailed();
    error SSD_WaveCapPerEpoch();
    error SSD_ShoreWhisperCap();
    error SSD_BottleCap();
    error SSD_BatchTooLarge();
    error SSD_ArrayLengthMismatch();
    error SSD_WithdrawZero();

    uint256 public constant TIDE_BLOCKS = 200;
    uint256 public constant WAVES_PER_TIDE_CAP = 64;
    uint256 public constant WHISPERS_PER_SHORE_CAP = 128;
    uint256 public constant BOTTLE_FEE_WEI = 0.001 ether;
    uint256 public constant MAX_BOTTLES_TOTAL = 2048;
    uint256 public constant MAX_BATCH_WAVES = 16;
    uint256 public constant OCEAN_SEED = 0x5B9D3F7A1C4E8B0D2F6A9C1E5B8D3F7A0C4E6B2;

    address public immutable oceanTreasury;
    address public immutable lighthouseKeeper;
    uint256 public immutable genesisBlock;
    bytes32 public immutable oceanSalt;

    uint256 public waveCounter;
    uint256 public bottleCounter;
    uint256 public currentTideEpoch;
    uint256 public totalWavesCast;
    uint256 public totalBottlesCast;
    uint256 public treasuryBalance;
    bool public dreamsPaused;

    struct WaveEntry {
        bytes32 waveId;
        address sender;
        bytes32 contentHash;
        uint256 tideEpoch;
        uint256 castAtBlock;
    }

    struct BottleEntry {
        bytes32 bottleId;
        address sender;
        bytes32 messageHash;
        uint256 feeWei;
        uint256 castAtBlock;
    }

    struct ShoreWhisperEntry {
        bytes32 shoreId;
        address sender;
        bytes32 whisperHash;
        uint256 indexOnShore;
        uint256 atBlock;
    }

    struct TideSnapshot {
        uint256 tideEpoch;
        uint256 blockNum;
        uint256 waveCount;
        uint256 sealedAtBlock;
    }

    mapping(bytes32 => WaveEntry) public waveById;
    mapping(bytes32 => BottleEntry) public bottleById;
    mapping(uint256 => TideSnapshot) public tideSnapshots;
    mapping(uint256 => uint256) public waveCountInTide;
    mapping(bytes32 => uint256) public whisperCountByShore;
    mapping(bytes32 => mapping(uint256 => ShoreWhisperEntry)) public whispersOnShore;

    mapping(bytes32 => bool) private _waveIdUsed;
    mapping(bytes32 => bool) private _bottleIdUsed;
    bytes32[] private _waveIdList;
    bytes32[] private _bottleIdList;
    mapping(address => bytes32[]) private _wavesBySender;
    mapping(address => bytes32[]) private _bottlesBySender;

    modifier whenNotPaused() {
        if (dreamsPaused) revert SSD_DreamsPaused();
        _;
    }

    constructor() {
        oceanTreasury = address(0x3E7a9C1f5B8d2E4a6C0e3B5d7F9a1C4e6B8d0F2a);
        lighthouseKeeper = address(0x6A2c4E8f0B2d6A8c0E4f2B6d8F0a4C2e6A8c0E2);
        genesisBlock = block.number;
        currentTideEpoch = 1;
        oceanSalt = keccak256(abi.encodePacked("SeaSideDreams_Ocean_", block.chainid, block.timestamp, address(this)));
    }

    function setDreamsPaused(bool paused) external onlyOwner {
        dreamsPaused = paused;
        emit DreamsPauseToggled(paused);
    }

    function _advanceTideIfNeeded() internal {
        uint256 blocksSinceGenesis = block.number - genesisBlock;
        uint256 epochFromGenesis = blocksSinceGenesis / TIDE_BLOCKS;
        uint256 nextEpoch = epochFromGenesis + 1;
        if (nextEpoch > currentTideEpoch) {
            tideSnapshots[currentTideEpoch] = TideSnapshot({
                tideEpoch: currentTideEpoch,
                blockNum: genesisBlock + (currentTideEpoch - 1) * TIDE_BLOCKS,
                waveCount: waveCountInTide[currentTideEpoch],
                sealedAtBlock: block.number
            });
            emit TideMarked(currentTideEpoch, tideSnapshots[currentTideEpoch].blockNum, waveCountInTide[currentTideEpoch], block.number);
            currentTideEpoch = nextEpoch;
        }
    }

    function castWave(bytes32 waveId, bytes32 contentHash) external whenNotPaused nonReentrant {
        if (waveId == bytes32(0)) revert SSD_ZeroWaveId();
        if (_waveIdUsed[waveId]) revert SSD_WaveAlreadyCast();
        _advanceTideIfNeeded();
        if (waveCountInTide[currentTideEpoch] >= WAVES_PER_TIDE_CAP) revert SSD_WaveCapPerEpoch();

        _waveIdUsed[waveId] = true;
        waveCountInTide[currentTideEpoch]++;
        waveCounter++;
        totalWavesCast++;
        waveById[waveId] = WaveEntry({
            waveId: waveId,
            sender: msg.sender,
            contentHash: contentHash,
            tideEpoch: currentTideEpoch,
            castAtBlock: block.number
        });
        _waveIdList.push(waveId);
        _wavesBySender[msg.sender].push(waveId);
        emit WaveCast(waveId, msg.sender, contentHash, currentTideEpoch, block.number);
    }

    function castWaveBatch(bytes32[] calldata waveIds, bytes32[] calldata contentHashes) external whenNotPaused nonReentrant {
        if (waveIds.length != contentHashes.length) revert SSD_ArrayLengthMismatch();
        if (waveIds.length > MAX_BATCH_WAVES) revert SSD_BatchTooLarge();
        _advanceTideIfNeeded();
        if (waveCountInTide[currentTideEpoch] + waveIds.length > WAVES_PER_TIDE_CAP) revert SSD_WaveCapPerEpoch();

        for (uint256 i = 0; i < waveIds.length; i++) {
            bytes32 wid = waveIds[i];
            if (wid == bytes32(0) || _waveIdUsed[wid]) continue;
            _waveIdUsed[wid] = true;
            waveCountInTide[currentTideEpoch]++;
            waveCounter++;
            totalWavesCast++;
            waveById[wid] = WaveEntry({
                waveId: wid,
                sender: msg.sender,
                contentHash: contentHashes[i],
                tideEpoch: currentTideEpoch,
                castAtBlock: block.number
            });
            _waveIdList.push(wid);
            _wavesBySender[msg.sender].push(wid);
            emit WaveCast(wid, msg.sender, contentHashes[i], currentTideEpoch, block.number);
        }
        emit WaveBatchCast(waveIds, msg.sender, currentTideEpoch, block.number);
    }

    function castBottle(bytes32 bottleId, bytes32 messageHash) external payable whenNotPaused nonReentrant {
        if (bottleId == bytes32(0)) revert SSD_ZeroBottleId();
        if (_bottleIdUsed[bottleId]) revert SSD_BottleAlreadyCast();
        if (msg.value < BOTTLE_FEE_WEI) revert SSD_InsufficientBottleFee();
        if (bottleCounter >= MAX_BOTTLES_TOTAL) revert SSD_BottleCap();

        _bottleIdUsed[bottleId] = true;
        bottleCounter++;
        totalBottlesCast++;
        treasuryBalance += msg.value;
        bottleById[bottleId] = BottleEntry({
            bottleId: bottleId,
            sender: msg.sender,
            messageHash: messageHash,
            feeWei: msg.value,
            castAtBlock: block.number
        });
        _bottleIdList.push(bottleId);
        _bottlesBySender[msg.sender].push(bottleId);
        emit BottleCast(bottleId, msg.sender, messageHash, msg.value, block.number);
    }

    function shoreWhisper(bytes32 shoreId, bytes32 whisperHash) external whenNotPaused nonReentrant {
        if (shoreId == bytes32(0)) revert SSD_ZeroShoreId();
        uint256 count = whisperCountByShore[shoreId];
        if (count >= WHISPERS_PER_SHORE_CAP) revert SSD_ShoreWhisperCap();

        whisperCountByShore[shoreId]++;
        uint256 idx = count;
        whispersOnShore[shoreId][idx] = ShoreWhisperEntry({
            shoreId: shoreId,
            sender: msg.sender,
            whisperHash: whisperHash,
            indexOnShore: idx,
            atBlock: block.number
        });
        emit ShoreWhisper(shoreId, msg.sender, whisperHash, idx, block.number);
    }

    function lighthouseSignal(bytes32 signalId, uint8 signalType) external {
        if (msg.sender != lighthouseKeeper && msg.sender != owner()) revert SSD_NotLighthouseKeeper();
        emit LighthousePulse(signalId, msg.sender, signalType, block.number);
    }

    function topTreasury() external payable {
        if (msg.value > 0) {
            treasuryBalance += msg.value;
            emit OceanTreasuryTopped(msg.value, msg.sender, treasuryBalance);
        }
    }

    function withdrawTreasury(address to, uint256 amountWei) external onlyOwner nonReentrant {
        if (to == address(0)) revert SSD_ZeroAddress();
        if (amountWei == 0) revert SSD_WithdrawZero();
        if (amountWei > treasuryBalance) revert SSD_TransferFailed();
        treasuryBalance -= amountWei;
        (bool sent,) = to.call{value: amountWei}("");
        if (!sent) revert SSD_TransferFailed();
        emit OceanTreasuryWithdrawn(to, amountWei, block.number);
    }

    function getWave(bytes32 waveId) external view returns (
        address sender,
        bytes32 contentHash,
        uint256 tideEpoch,
        uint256 castAtBlock
    ) {
        WaveEntry storage w = waveById[waveId];
        return (w.sender, w.contentHash, w.tideEpoch, w.castAtBlock);
    }

    function getBottle(bytes32 bottleId) external view returns (
        address sender,
        bytes32 messageHash,
        uint256 feeWei,
        uint256 castAtBlock
    ) {
        BottleEntry storage b = bottleById[bottleId];
        return (b.sender, b.messageHash, b.feeWei, b.castAtBlock);
    }

    function getTideSnapshot(uint256 tideEpoch) external view returns (
        uint256 blockNum,
        uint256 waveCount,
        uint256 sealedAtBlock
    ) {
        TideSnapshot storage t = tideSnapshots[tideEpoch];
        return (t.blockNum, t.waveCount, t.sealedAtBlock);
    }

    function getShoreWhisper(bytes32 shoreId, uint256 index) external view returns (
        address sender,
        bytes32 whisperHash,
        uint256 atBlock
    ) {
        ShoreWhisperEntry storage s = whispersOnShore[shoreId][index];
        return (s.sender, s.whisperHash, s.atBlock);
    }

    function waveIdsBySender(address account) external view returns (bytes32[] memory) {
        return _wavesBySender[account];
    }

    function bottleIdsBySender(address account) external view returns (bytes32[] memory) {
        return _bottlesBySender[account];
    }

    function allWaveIds() external view returns (bytes32[] memory) {
        return _waveIdList;
    }

    function allBottleIds() external view returns (bytes32[] memory) {
        return _bottleIdList;
    }

    function isWaveCast(bytes32 waveId) external view returns (bool) {
        return _waveIdUsed[waveId];
    }

    function isBottleCast(bytes32 bottleId) external view returns (bool) {
        return _bottleIdUsed[bottleId];
    }

    function currentTideEpochView() external view returns (uint256) {
        uint256 blocksSinceGenesis = block.number - genesisBlock;
        return (blocksSinceGenesis / TIDE_BLOCKS) + 1;
    }

    function blocksUntilNextTide() external view returns (uint256) {
        uint256 blocksSinceGenesis = block.number - genesisBlock;
        uint256 inCurrentTide = blocksSinceGenesis % TIDE_BLOCKS;
        return inCurrentTide == 0 ? TIDE_BLOCKS : (TIDE_BLOCKS - inCurrentTide);
    }

    function waveCountInCurrentTide() external view returns (uint256) {
        uint256 blocksSinceGenesis = block.number - genesisBlock;
        uint256 epoch = (blocksSinceGenesis / TIDE_BLOCKS) + 1;
        return waveCountInTide[epoch];
    }

    function shoreWhisperCount(bytes32 shoreId) external view returns (uint256) {
        return whisperCountByShore[shoreId];
    }

    function getOceanTreasury() external view returns (address) {
        return oceanTreasury;
    }

    function getLighthouseKeeper() external view returns (address) {
        return lighthouseKeeper;
    }

    function getGenesisBlock() external view returns (uint256) {
        return genesisBlock;
    }

    function getOceanSalt() external view returns (bytes32) {
        return oceanSalt;
    }

    function getTreasuryBalance() external view returns (uint256) {
        return treasuryBalance;
    }

    function getDreamsPaused() external view returns (bool) {
        return dreamsPaused;
    }

    function getOceanSeed() external pure returns (uint256) {
        return OCEAN_SEED;
    }

    function getWaveIdListPaginated(uint256 offset, uint256 limit) external view returns (bytes32[] memory) {
        uint256 len = _waveIdList.length;
        if (offset >= len) return new bytes32[](0);
        uint256 end = offset + limit;
        if (end > len) end = len;
        uint256 n = end - offset;
        bytes32[] memory out = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) out[i] = _waveIdList[offset + i];
        return out;
    }

    function getBottleIdListPaginated(uint256 offset, uint256 limit) external view returns (bytes32[] memory) {
        uint256 len = _bottleIdList.length;
        if (offset >= len) return new bytes32[](0);
        uint256 end = offset + limit;
        if (end > len) end = len;
        uint256 n = end - offset;
        bytes32[] memory out = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) out[i] = _bottleIdList[offset + i];
        return out;
    }

