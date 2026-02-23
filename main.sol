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

    function getWaveEntriesBatch(bytes32[] calldata waveIds) external view returns (
        address[] memory senders,
        bytes32[] memory contentHashes,
        uint256[] memory tideEpochs,
        uint256[] memory castAtBlocks
    ) {
        uint256 n = waveIds.length;
        senders = new address[](n);
        contentHashes = new bytes32[](n);
        tideEpochs = new uint256[](n);
        castAtBlocks = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            WaveEntry storage w = waveById[waveIds[i]];
            senders[i] = w.sender;
            contentHashes[i] = w.contentHash;
            tideEpochs[i] = w.tideEpoch;
            castAtBlocks[i] = w.castAtBlock;
        }
        return (senders, contentHashes, tideEpochs, castAtBlocks);
    }

    function getBottleEntriesBatch(bytes32[] calldata bottleIds) external view returns (
        address[] memory senders,
        bytes32[] memory messageHashes,
        uint256[] memory feesWei,
        uint256[] memory castAtBlocks
    ) {
        uint256 n = bottleIds.length;
        senders = new address[](n);
        messageHashes = new bytes32[](n);
        feesWei = new uint256[](n);
        castAtBlocks = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            BottleEntry storage b = bottleById[bottleIds[i]];
            senders[i] = b.sender;
            messageHashes[i] = b.messageHash;
            feesWei[i] = b.feeWei;
            castAtBlocks[i] = b.castAtBlock;
        }
        return (senders, messageHashes, feesWei, castAtBlocks);
    }

    function getShoreWhispersBatch(bytes32 shoreId, uint256 offset, uint256 limit) external view returns (
        address[] memory senders,
        bytes32[] memory whisperHashes,
        uint256[] memory atBlocks
    ) {
        uint256 total = whisperCountByShore[shoreId];
        if (offset >= total) {
            return (new address[](0), new bytes32[](0), new uint256[](0));
        }
        uint256 end = offset + limit;
        if (end > total) end = total;
        uint256 n = end - offset;
        senders = new address[](n);
        whisperHashes = new bytes32[](n);
        atBlocks = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            ShoreWhisperEntry storage s = whispersOnShore[shoreId][offset + i];
            senders[i] = s.sender;
            whisperHashes[i] = s.whisperHash;
            atBlocks[i] = s.atBlock;
        }
        return (senders, whisperHashes, atBlocks);
    }

    function getConfigSnapshot() external view returns (
        address oceanTreasury_,
        address lighthouseKeeper_,
        uint256 genesisBlock_,
        uint256 currentTideEpoch_,
        uint256 waveCounter_,
        uint256 bottleCounter_,
        uint256 treasuryBalance_,
        bool dreamsPaused_
    ) {
        return (
            oceanTreasury,
            lighthouseKeeper,
            genesisBlock,
            currentTideEpoch,
            waveCounter,
            bottleCounter,
            treasuryBalance,
            dreamsPaused
        );
    }

    function getConstantsSnapshot() external pure returns (
        uint256 tideBlocks,
        uint256 wavesPerTideCap,
        uint256 whispersPerShoreCap,
        uint256 bottleFeeWei,
        uint256 maxBottlesTotal,
        uint256 maxBatchWaves
    ) {
        return (TIDE_BLOCKS, WAVES_PER_TIDE_CAP, WHISPERS_PER_SHORE_CAP, BOTTLE_FEE_WEI, MAX_BOTTLES_TOTAL, MAX_BATCH_WAVES);
    }

    function totalWavesCastView() external view returns (uint256) {
        return totalWavesCast;
    }

    function totalBottlesCastView() external view returns (uint256) {
        return totalBottlesCast;
    }

    function waveIdListLength() external view returns (uint256) {
        return _waveIdList.length;
    }

    function bottleIdListLength() external view returns (uint256) {
        return _bottleIdList.length;
    }

    function senderWaveCount(address account) external view returns (uint256) {
        return _wavesBySender[account].length;
    }

    function senderBottleCount(address account) external view returns (uint256) {
        return _bottlesBySender[account].length;
    }

    function tideEpochAtBlock(uint256 blockNum) external view returns (uint256) {
        if (blockNum <= genesisBlock) return 1;
        return ((blockNum - genesisBlock) / TIDE_BLOCKS) + 1;
    }

    function waveContentHash(bytes32 waveId) external view returns (bytes32) {
        return waveById[waveId].contentHash;
    }

    function bottleMessageHash(bytes32 bottleId) external view returns (bytes32) {
        return bottleById[bottleId].messageHash;
    }

    function waveSender(bytes32 waveId) external view returns (address) {
        return waveById[waveId].sender;
    }

    function bottleSender(bytes32 bottleId) external view returns (address) {
        return bottleById[bottleId].sender;
    }

    function waveCastAtBlock(bytes32 waveId) external view returns (uint256) {
        return waveById[waveId].castAtBlock;
    }

    function bottleCastAtBlock(bytes32 bottleId) external view returns (uint256) {
        return bottleById[bottleId].castAtBlock;
    }

    function bottleFeeWeiConstant() external pure returns (uint256) {
        return BOTTLE_FEE_WEI;
    }

    function tideBlocksConstant() external pure returns (uint256) {
        return TIDE_BLOCKS;
    }

    function wavesPerTideCapConstant() external pure returns (uint256) {
        return WAVES_PER_TIDE_CAP;
    }

    function whispersPerShoreCapConstant() external pure returns (uint256) {
        return WHISPERS_PER_SHORE_CAP;
    }

    function maxBottlesTotalConstant() external pure returns (uint256) {
        return MAX_BOTTLES_TOTAL;
    }

    function maxBatchWavesConstant() external pure returns (uint256) {
        return MAX_BATCH_WAVES;
    }

    function canCastWaveInCurrentTide() external view returns (bool) {
        uint256 blocksSinceGenesis = block.number - genesisBlock;
        uint256 epoch = (blocksSinceGenesis / TIDE_BLOCKS) + 1;
        return waveCountInTide[epoch] < WAVES_PER_TIDE_CAP;
    }

    function remainingWaveSlotsThisTide() external view returns (uint256) {
        uint256 blocksSinceGenesis = block.number - genesisBlock;
        uint256 epoch = (blocksSinceGenesis / TIDE_BLOCKS) + 1;
        uint256 used = waveCountInTide[epoch];
        return used >= WAVES_PER_TIDE_CAP ? 0 : (WAVES_PER_TIDE_CAP - used);
    }

    function canCastBottle() external view returns (bool) {
        return bottleCounter < MAX_BOTTLES_TOTAL;
    }

    function remainingBottleSlots() external view returns (uint256) {
        return bottleCounter >= MAX_BOTTLES_TOTAL ? 0 : (MAX_BOTTLES_TOTAL - bottleCounter);
    }

    function canShoreWhisper(bytes32 shoreId) external view returns (bool) {
        return whisperCountByShore[shoreId] < WHISPERS_PER_SHORE_CAP;
    }

    function remainingWhisperSlots(bytes32 shoreId) external view returns (uint256) {
        uint256 used = whisperCountByShore[shoreId];
        return used >= WHISPERS_PER_SHORE_CAP ? 0 : (WHISPERS_PER_SHORE_CAP - used);
    }

    function getTideSnapshotBatch(uint256[] calldata tideEpochs) external view returns (
        uint256[] memory blockNums,
        uint256[] memory waveCounts,
        uint256[] memory sealedAtBlocks
    ) {
        uint256 n = tideEpochs.length;
        blockNums = new uint256[](n);
        waveCounts = new uint256[](n);
        sealedAtBlocks = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            TideSnapshot storage t = tideSnapshots[tideEpochs[i]];
            blockNums[i] = t.blockNum;
            waveCounts[i] = t.waveCount;
            sealedAtBlocks[i] = t.sealedAtBlock;
        }
        return (blockNums, waveCounts, sealedAtBlocks);
    }

    function getWaveIdsForSenderPaginated(address account, uint256 offset, uint256 limit) external view returns (bytes32[] memory) {
        bytes32[] storage ids = _wavesBySender[account];
        if (offset >= ids.length) return new bytes32[](0);
        uint256 end = offset + limit;
        if (end > ids.length) end = ids.length;
        uint256 n = end - offset;
        bytes32[] memory out = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) out[i] = ids[offset + i];
        return out;
    }

    function getBottleIdsForSenderPaginated(address account, uint256 offset, uint256 limit) external view returns (bytes32[] memory) {
        bytes32[] storage ids = _bottlesBySender[account];
        if (offset >= ids.length) return new bytes32[](0);
        uint256 end = offset + limit;
        if (end > ids.length) end = ids.length;
        uint256 n = end - offset;
        bytes32[] memory out = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) out[i] = ids[offset + i];
        return out;
    }

    function latestWaveId() external view returns (bytes32) {
        if (_waveIdList.length == 0) return bytes32(0);
        return _waveIdList[_waveIdList.length - 1];
    }

    function latestBottleId() external view returns (bytes32) {
        if (_bottleIdList.length == 0) return bytes32(0);
        return _bottleIdList[_bottleIdList.length - 1];
    }

    function waveIdAtIndex(uint256 index) external view returns (bytes32) {
        if (index >= _waveIdList.length) return bytes32(0);
        return _waveIdList[index];
    }

    function bottleIdAtIndex(uint256 index) external view returns (bytes32) {
        if (index >= _bottleIdList.length) return bytes32(0);
        return _bottleIdList[index];
    }

    function oceanTreasuryAddress() external view returns (address) {
        return oceanTreasury;
    }

    function lighthouseKeeperAddress() external view returns (address) {
        return lighthouseKeeper;
    }

    function genesisBlockNumber() external view returns (uint256) {
        return genesisBlock;
    }

    function oceanSaltBytes() external view returns (bytes32) {
        return oceanSalt;
    }

    function isLighthouseKeeper(address account) external view returns (bool) {
        return account == lighthouseKeeper || account == owner();
    }

    function validateWaveId(bytes32 waveId) external view returns (bool) {
        return waveId != bytes32(0) && !_waveIdUsed[waveId];
    }

    function validateBottleId(bytes32 bottleId) external view returns (bool) {
        return bottleId != bytes32(0) && !_bottleIdUsed[bottleId] && bottleCounter < MAX_BOTTLES_TOTAL;
    }

    function estimateTideEpochAtBlock(uint256 blockNum) external view returns (uint256) {
        if (blockNum <= genesisBlock) return 1;
        return ((blockNum - genesisBlock) / TIDE_BLOCKS) + 1;
    }

    function getOceanSeedHex() external pure returns (uint256) {
        return OCEAN_SEED;
    }

    function treasuryBalanceView() external view returns (uint256) {
        return treasuryBalance;
    }

    function dreamsPausedView() external view returns (bool) {
        return dreamsPaused;
    }

    function waveCounterView() external view returns (uint256) {
        return waveCounter;
    }

    function bottleCounterView() external view returns (uint256) {
        return bottleCounter;
    }

    function currentTideEpochViewPublic() external view returns (uint256) {
        uint256 blocksSinceGenesis = block.number - genesisBlock;
        return (blocksSinceGenesis / TIDE_BLOCKS) + 1;
    }

    function getWaveEntryFull(bytes32 waveId) external view returns (
        bytes32 id,
        address senderAddr,
        bytes32 contentHashVal,
        uint256 tideEpochVal,
        uint256 castBlock
    ) {
        WaveEntry storage w = waveById[waveId];
        return (w.waveId, w.sender, w.contentHash, w.tideEpoch, w.castAtBlock);
    }

    function getBottleEntryFull(bytes32 bottleId) external view returns (
        bytes32 id,
        address senderAddr,
        bytes32 messageHashVal,
        uint256 feeWeiVal,
        uint256 castBlock
    ) {
        BottleEntry storage b = bottleById[bottleId];
        return (b.bottleId, b.sender, b.messageHash, b.feeWei, b.castAtBlock);
    }

    function getShoreWhisperFull(bytes32 shoreId, uint256 index) external view returns (
        bytes32 shoreIdVal,
        address senderAddr,
        bytes32 whisperHashVal,
        uint256 indexOnShoreVal,
        uint256 atBlockVal
    ) {
        ShoreWhisperEntry storage s = whispersOnShore[shoreId][index];
        return (s.shoreId, s.sender, s.whisperHash, s.indexOnShore, s.atBlock);
    }

    function wavesInTideEpoch(uint256 tideEpoch) external view returns (uint256) {
        return waveCountInTide[tideEpoch];
    }

    function shoreWhispersTotal(bytes32 shoreId) external view returns (uint256) {
        return whisperCountByShore[shoreId];
    }

    function hasWave(bytes32 waveId) external view returns (bool) {
        return _waveIdUsed[waveId];
    }

    function hasBottle(bytes32 bottleId) external view returns (bool) {
        return _bottleIdUsed[bottleId];
    }

    function minBottleFee() external pure returns (uint256) {
        return BOTTLE_FEE_WEI;
    }

    function tideIntervalBlocks() external pure returns (uint256) {
        return TIDE_BLOCKS;
    }

    function maxWavesPerTide() external pure returns (uint256) {
        return WAVES_PER_TIDE_CAP;
    }

    function maxWhispersPerShore() external pure returns (uint256) {
        return WHISPERS_PER_SHORE_CAP;
    }

    function maxBottles() external pure returns (uint256) {
        return MAX_BOTTLES_TOTAL;
    }

    function maxBatchWavesSize() external pure returns (uint256) {
        return MAX_BATCH_WAVES;
    }

    function allWaveIdsPaginated(uint256 pageSize, uint256 page) external view returns (bytes32[] memory) {
        uint256 len = _waveIdList.length;
        uint256 start = page * pageSize;
        if (start >= len) return new bytes32[](0);
        uint256 end = start + pageSize;
        if (end > len) end = len;
        uint256 n = end - start;
        bytes32[] memory out = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) out[i] = _waveIdList[start + i];
        return out;
    }

    function allBottleIdsPaginated(uint256 pageSize, uint256 page) external view returns (bytes32[] memory) {
        uint256 len = _bottleIdList.length;
        uint256 start = page * pageSize;
        if (start >= len) return new bytes32[](0);
        uint256 end = start + pageSize;
        if (end > len) end = len;
        uint256 n = end - start;
        bytes32[] memory out = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) out[i] = _bottleIdList[start + i];
        return out;
    }

    function waveIdsForTideEpoch(uint256 tideEpoch) external view returns (bytes32[] memory) {
        uint256 count = 0;
        for (uint256 i = 0; i < _waveIdList.length; i++) {
            if (waveById[_waveIdList[i]].tideEpoch == tideEpoch) count++;
        }
        bytes32[] memory out = new bytes32[](count);
        uint256 j = 0;
        for (uint256 i = 0; i < _waveIdList.length; i++) {
            if (waveById[_waveIdList[i]].tideEpoch == tideEpoch) {
                out[j] = _waveIdList[i];
                j++;
            }
        }
        return out;
    }

    function waveCountForSender(address account) external view returns (uint256) {
        return _wavesBySender[account].length;
    }

    function bottleCountForSender(address account) external view returns (uint256) {
        return _bottlesBySender[account].length;
    }

    function totalWaveCount() external view returns (uint256) {
        return _waveIdList.length;
    }

    function totalBottleCount() external view returns (uint256) {
        return _bottleIdList.length;
    }

    function getWaveSenderBatch(bytes32[] calldata waveIds) external view returns (address[] memory) {
        address[] memory out = new address[](waveIds.length);
        for (uint256 i = 0; i < waveIds.length; i++) out[i] = waveById[waveIds[i]].sender;
        return out;
    }

    function getWaveContentHashBatch(bytes32[] calldata waveIds) external view returns (bytes32[] memory) {
        bytes32[] memory out = new bytes32[](waveIds.length);
        for (uint256 i = 0; i < waveIds.length; i++) out[i] = waveById[waveIds[i]].contentHash;
        return out;
    }

    function getWaveTideEpochBatch(bytes32[] calldata waveIds) external view returns (uint256[] memory) {
        uint256[] memory out = new uint256[](waveIds.length);
        for (uint256 i = 0; i < waveIds.length; i++) out[i] = waveById[waveIds[i]].tideEpoch;
        return out;
    }

    function getWaveCastBlockBatch(bytes32[] calldata waveIds) external view returns (uint256[] memory) {
        uint256[] memory out = new uint256[](waveIds.length);
        for (uint256 i = 0; i < waveIds.length; i++) out[i] = waveById[waveIds[i]].castAtBlock;
        return out;
    }

    function getBottleSenderBatch(bytes32[] calldata bottleIds) external view returns (address[] memory) {
        address[] memory out = new address[](bottleIds.length);
        for (uint256 i = 0; i < bottleIds.length; i++) out[i] = bottleById[bottleIds[i]].sender;
        return out;
    }

    function getBottleMessageHashBatch(bytes32[] calldata bottleIds) external view returns (bytes32[] memory) {
        bytes32[] memory out = new bytes32[](bottleIds.length);
        for (uint256 i = 0; i < bottleIds.length; i++) out[i] = bottleById[bottleIds[i]].messageHash;
        return out;
    }

    function getBottleFeeBatch(bytes32[] calldata bottleIds) external view returns (uint256[] memory) {
        uint256[] memory out = new uint256[](bottleIds.length);
        for (uint256 i = 0; i < bottleIds.length; i++) out[i] = bottleById[bottleIds[i]].feeWei;
        return out;
    }

    function isWaveIdUsed(bytes32 waveId) external view returns (bool) {
        return _waveIdUsed[waveId];
    }

    function isBottleIdUsed(bytes32 bottleId) external view returns (bool) {
        return _bottleIdUsed[bottleId];
    }

    function nextTideBlockEstimate() external view returns (uint256) {
        uint256 blocksSinceGenesis = block.number - genesisBlock;
        uint256 inCurrent = blocksSinceGenesis % TIDE_BLOCKS;
        if (inCurrent == 0) return block.number + TIDE_BLOCKS;
        return block.number + (TIDE_BLOCKS - inCurrent);
    }

    function tideEpochNow() external view returns (uint256) {
        uint256 blocksSinceGenesis = block.number - genesisBlock;
        return (blocksSinceGenesis / TIDE_BLOCKS) + 1;
    }

    function wavesUsedInEpoch(uint256 epoch) external view returns (uint256) {
        return waveCountInTide[epoch];
    }

    function whispersUsedOnShore(bytes32 shoreId) external view returns (uint256) {
        return whisperCountByShore[shoreId];
    }

    function configTideBlocks() external pure returns (uint256) {
        return TIDE_BLOCKS;
    }

    function configWavesPerTide() external pure returns (uint256) {
        return WAVES_PER_TIDE_CAP;
    }

    function configWhispersPerShore() external pure returns (uint256) {
        return WHISPERS_PER_SHORE_CAP;
    }

    function configBottleFee() external pure returns (uint256) {
        return BOTTLE_FEE_WEI;
    }

    function configMaxBottles() external pure returns (uint256) {
        return MAX_BOTTLES_TOTAL;
    }

    function configMaxBatchWaves() external pure returns (uint256) {
        return MAX_BATCH_WAVES;
    }

    function treasuryAddr() external view returns (address) {
        return oceanTreasury;
    }

    function keeperAddr() external view returns (address) {
        return lighthouseKeeper;
    }

    function genesisBlockNum() external view returns (uint256) {
        return genesisBlock;
    }

    function saltBytes() external view returns (bytes32) {
        return oceanSalt;
    }

    function statsTotalWaves() external view returns (uint256) {
        return totalWavesCast;
    }

    function statsTotalBottles() external view returns (uint256) {
        return totalBottlesCast;
    }

    function statsTreasuryWei() external view returns (uint256) {
        return treasuryBalance;
    }

    function statsPaused() external view returns (bool) {
        return dreamsPaused;
    }

    function statsCurrentTide() external view returns (uint256) {
        return currentTideEpoch;
    }

    function statsWaveCounter() external view returns (uint256) {
        return waveCounter;
    }

    function statsBottleCounter() external view returns (uint256) {
        return bottleCounter;
    }

    function listWaveIds(uint256 maxReturn) external view returns (bytes32[] memory) {
        uint256 len = _waveIdList.length;
        if (len == 0) return new bytes32[](0);
        uint256 n = maxReturn > len ? len : maxReturn;
        bytes32[] memory out = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) out[i] = _waveIdList[len - 1 - i];
        return out;
    }

    function listBottleIds(uint256 maxReturn) external view returns (bytes32[] memory) {
        uint256 len = _bottleIdList.length;
        if (len == 0) return new bytes32[](0);
        uint256 n = maxReturn > len ? len : maxReturn;
        bytes32[] memory out = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) out[i] = _bottleIdList[len - 1 - i];
        return out;
    }

    function getShoreWhisperSenders(bytes32 shoreId, uint256 fromIndex, uint256 toIndex) external view returns (address[] memory) {
        uint256 total = whisperCountByShore[shoreId];
        if (fromIndex >= total || fromIndex >= toIndex) return new address[](0);
        if (toIndex > total) toIndex = total;
        uint256 n = toIndex - fromIndex;
        address[] memory out = new address[](n);
        for (uint256 i = 0; i < n; i++) out[i] = whispersOnShore[shoreId][fromIndex + i].sender;
        return out;
    }

    function getShoreWhisperHashes(bytes32 shoreId, uint256 fromIndex, uint256 toIndex) external view returns (bytes32[] memory) {
        uint256 total = whisperCountByShore[shoreId];
        if (fromIndex >= total || fromIndex >= toIndex) return new bytes32[](0);
        if (toIndex > total) toIndex = total;
        uint256 n = toIndex - fromIndex;
        bytes32[] memory out = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) out[i] = whispersOnShore[shoreId][fromIndex + i].whisperHash;
        return out;
    }

    function getShoreWhisperBlocks(bytes32 shoreId, uint256 fromIndex, uint256 toIndex) external view returns (uint256[] memory) {
        uint256 total = whisperCountByShore[shoreId];
        if (fromIndex >= total || fromIndex >= toIndex) return new uint256[](0);
        if (toIndex > total) toIndex = total;
        uint256 n = toIndex - fromIndex;
        uint256[] memory out = new uint256[](n);
        for (uint256 i = 0; i < n; i++) out[i] = whispersOnShore[shoreId][fromIndex + i].atBlock;
        return out;
    }

    function waveExists(bytes32 waveId) external view returns (bool) {
        return _waveIdUsed[waveId];
    }

    function bottleExists(bytes32 bottleId) external view returns (bool) {
        return _bottleIdUsed[bottleId];
    }

    function oceanSeedConstant() external pure returns (uint256) {
        return OCEAN_SEED;
    }

    function treasuryBalanceWei() external view returns (uint256) {
        return treasuryBalance;
    }

    function pausedState() external view returns (bool) {
        return dreamsPaused;
    }

    function currentEpoch() external view returns (uint256) {
        return currentTideEpoch;
    }

    function totalWaves() external view returns (uint256) {
        return totalWavesCast;
    }

    function totalBottles() external view returns (uint256) {
        return totalBottlesCast;
    }

    function waveListLength() external view returns (uint256) {
        return _waveIdList.length;
    }

    function bottleListLength() external view returns (uint256) {
        return _bottleIdList.length;
    }

    function senderWaves(address account) external view returns (bytes32[] memory) {
        return _wavesBySender[account];
    }

    function senderBottles(address account) external view returns (bytes32[] memory) {
        return _bottlesBySender[account];
    }

    function waveByIndex(uint256 index) external view returns (bytes32) {
        if (index >= _waveIdList.length) return bytes32(0);
        return _waveIdList[index];
    }

    function bottleByIndex(uint256 index) external view returns (bytes32) {
        if (index >= _bottleIdList.length) return bytes32(0);
        return _bottleIdList[index];
    }

    function tideWaveCount(uint256 epoch) external view returns (uint256) {
        return waveCountInTide[epoch];
    }

    function shoreCount(bytes32 shoreId) external view returns (uint256) {
        return whisperCountByShore[shoreId];
    }

    function checkWaveIdAvailable(bytes32 waveId) external view returns (bool) {
        return waveId != bytes32(0) && !_waveIdUsed[waveId];
    }

    function checkBottleIdAvailable(bytes32 bottleId) external view returns (bool) {
        return bottleId != bytes32(0) && !_bottleIdUsed[bottleId];
    }

    function blocksToNextTide() external view returns (uint256) {
        uint256 blocksSinceGenesis = block.number - genesisBlock;
        uint256 inCurrent = blocksSinceGenesis % TIDE_BLOCKS;
        return inCurrent == 0 ? TIDE_BLOCKS : (TIDE_BLOCKS - inCurrent);
    }

    function waveSlotsRemaining() external view returns (uint256) {
        uint256 blocksSinceGenesis = block.number - genesisBlock;
        uint256 epoch = (blocksSinceGenesis / TIDE_BLOCKS) + 1;
        uint256 used = waveCountInTide[epoch];
        return used >= WAVES_PER_TIDE_CAP ? 0 : (WAVES_PER_TIDE_CAP - used);
    }

    function bottleSlotsRemaining() external view returns (uint256) {
        return bottleCounter >= MAX_BOTTLES_TOTAL ? 0 : (MAX_BOTTLES_TOTAL - bottleCounter);
    }

    function whisperSlotsRemaining(bytes32 shoreId) external view returns (uint256) {
        uint256 used = whisperCountByShore[shoreId];
        return used >= WHISPERS_PER_SHORE_CAP ? 0 : (WHISPERS_PER_SHORE_CAP - used);
    }

    function getFullConfig() external view returns (
        address treasury,
        address keeper,
        uint256 genesis,
        bytes32 salt,
        uint256 wavesTotal,
        uint256 bottlesTotal,
        uint256 treasuryWei,
        bool paused,
        uint256 epoch
    ) {
        return (
            oceanTreasury,
            lighthouseKeeper,
            genesisBlock,
            oceanSalt,
            totalWavesCast,
            totalBottlesCast,
            treasuryBalance,
            dreamsPaused,
            currentTideEpoch
        );
    }

    function getFullConstants() external pure returns (
        uint256 tideBlk,
        uint256 waveCap,
        uint256 whisperCap,
        uint256 bottleFee,
        uint256 maxBottle,
        uint256 maxBatch
    ) {
        return (TIDE_BLOCKS, WAVES_PER_TIDE_CAP, WHISPERS_PER_SHORE_CAP, BOTTLE_FEE_WEI, MAX_BOTTLES_TOTAL, MAX_BATCH_WAVES);
    }

    function waveIdList() external view returns (bytes32[] memory) {
        return _waveIdList;
    }

    function bottleIdList() external view returns (bytes32[] memory) {
        return _bottleIdList;
    }

    function wavesBySender(address account) external view returns (bytes32[] memory) {
        return _wavesBySender[account];
    }

    function bottlesBySender(address account) external view returns (bytes32[] memory) {
        return _bottlesBySender[account];
    }

    function tideSnapshotBlock(uint256 epoch) external view returns (uint256) {
        return tideSnapshots[epoch].blockNum;
    }

    function tideSnapshotWaveCount(uint256 epoch) external view returns (uint256) {
        return tideSnapshots[epoch].waveCount;
    }

    function tideSnapshotSealedBlock(uint256 epoch) external view returns (uint256) {
        return tideSnapshots[epoch].sealedAtBlock;
    }

    function computeWaveId(bytes32 senderHash, uint256 nonce) external pure returns (bytes32) {
        return keccak256(abi.encodePacked("SeaSideDreams_Wave_", senderHash, nonce));
    }

    function computeBottleId(bytes32 senderHash, uint256 nonce) external pure returns (bytes32) {
        return keccak256(abi.encodePacked("SeaSideDreams_Bottle_", senderHash, nonce));
    }

    function computeShoreId(string calldata shoreName) external pure returns (bytes32) {
        return keccak256(abi.encodePacked("SeaSideDreams_Shore_", shoreName));
    }

    function contentHashFromBytes(bytes calldata data) external pure returns (bytes32) {
        return keccak256(data);
    }

    function messageHashFromBytes(bytes calldata data) external pure returns (bytes32) {
        return keccak256(data);
    }

    function epochFromBlock(uint256 blockNumber) external view returns (uint256) {
        if (blockNumber <= genesisBlock) return 1;
        return ((blockNumber - genesisBlock) / TIDE_BLOCKS) + 1;
    }

    function blockRangeForEpoch(uint256 epoch) external view returns (uint256 startBlock, uint256 endBlock) {
        startBlock = genesisBlock + (epoch - 1) * TIDE_BLOCKS;
        endBlock = genesisBlock + epoch * TIDE_BLOCKS - 1;
        return (startBlock, endBlock);
    }

    function isInEpoch(uint256 blockNumber, uint256 epoch) external view returns (bool) {
        if (blockNumber <= genesisBlock) return epoch == 1;
        uint256 e = ((blockNumber - genesisBlock) / TIDE_BLOCKS) + 1;
        return e == epoch;
    }

    function getWaveIdsInEpochRange(uint256 fromEpoch, uint256 toEpoch) external view returns (bytes32[] memory) {
        uint256 count = 0;
        for (uint256 i = 0; i < _waveIdList.length; i++) {
            uint256 te = waveById[_waveIdList[i]].tideEpoch;
            if (te >= fromEpoch && te <= toEpoch) count++;
        }
        bytes32[] memory out = new bytes32[](count);
        uint256 j = 0;
        for (uint256 i = 0; i < _waveIdList.length; i++) {
            uint256 te = waveById[_waveIdList[i]].tideEpoch;
            if (te >= fromEpoch && te <= toEpoch) {
                out[j] = _waveIdList[i];
                j++;
            }
        }
        return out;
    }

    function getLastNWaveIds(uint256 n) external view returns (bytes32[] memory) {
        uint256 len = _waveIdList.length;
        if (len == 0) return new bytes32[](0);
        if (n > len) n = len;
        bytes32[] memory out = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) out[i] = _waveIdList[len - 1 - i];
        return out;
    }

    function getLastNBottleIds(uint256 n) external view returns (bytes32[] memory) {
        uint256 len = _bottleIdList.length;
        if (len == 0) return new bytes32[](0);
        if (n > len) n = len;
        bytes32[] memory out = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) out[i] = _bottleIdList[len - 1 - i];
        return out;
    }

    function oceanTreasuryImmutable() external view returns (address) {
        return oceanTreasury;
    }

    function lighthouseKeeperImmutable() external view returns (address) {
        return lighthouseKeeper;
    }

    function genesisBlockImmutable() external view returns (uint256) {
        return genesisBlock;
    }

    function oceanSaltImmutable() external view returns (bytes32) {
        return oceanSalt;
    }

    function OCEAN_SEED_CONSTANT() external pure returns (uint256) {
        return OCEAN_SEED;
    }

    function TIDE_BLOCKS_CONSTANT() external pure returns (uint256) {
        return TIDE_BLOCKS;
    }

    function WAVES_PER_TIDE_CAP_CONSTANT() external pure returns (uint256) {
        return WAVES_PER_TIDE_CAP;
    }

    function WHISPERS_PER_SHORE_CAP_CONSTANT() external pure returns (uint256) {
        return WHISPERS_PER_SHORE_CAP;
    }

    function BOTTLE_FEE_WEI_CONSTANT() external pure returns (uint256) {
        return BOTTLE_FEE_WEI;
    }

    function MAX_BOTTLES_TOTAL_CONSTANT() external pure returns (uint256) {
        return MAX_BOTTLES_TOTAL;
    }

    function MAX_BATCH_WAVES_CONSTANT() external pure returns (uint256) {
        return MAX_BATCH_WAVES;
    }

    function getWaveStruct(bytes32 waveId) external view returns (WaveEntry memory) {
        return waveById[waveId];
    }

    function getBottleStruct(bytes32 bottleId) external view returns (BottleEntry memory) {
        return bottleById[bottleId];
    }

    function getTideStruct(uint256 epoch) external view returns (TideSnapshot memory) {
        return tideSnapshots[epoch];
    }

    function getShoreWhisperStruct(bytes32 shoreId, uint256 index) external view returns (ShoreWhisperEntry memory) {
        return whispersOnShore[shoreId][index];
    }

    function waveIdUsed(bytes32 waveId) external view returns (bool) {
        return _waveIdUsed[waveId];
    }

    function bottleIdUsed(bytes32 bottleId) external view returns (bool) {
        return _bottleIdUsed[bottleId];
    }

    function numWavesInEpoch(uint256 epoch) external view returns (uint256) {
        return waveCountInTide[epoch];
    }

    function numWhispersOnShore(bytes32 shoreId) external view returns (uint256) {
        return whisperCountByShore[shoreId];
    }

    function waveIdToContentHash(bytes32 waveId) external view returns (bytes32) {
        return waveById[waveId].contentHash;
    }

    function bottleIdToMessageHash(bytes32 bottleId) external view returns (bytes32) {
        return bottleById[bottleId].messageHash;
    }

    function waveIdToTideEpoch(bytes32 waveId) external view returns (uint256) {
        return waveById[waveId].tideEpoch;
    }

    function bottleIdToFee(bytes32 bottleId) external view returns (uint256) {
        return bottleById[bottleId].feeWei;
    }

    function waveSenderOf(bytes32 waveId) external view returns (address) {
        return waveById[waveId].sender;
    }

    function bottleSenderOf(bytes32 bottleId) external view returns (address) {
        return bottleById[bottleId].sender;
    }

    function waveCastBlock(bytes32 waveId) external view returns (uint256) {
        return waveById[waveId].castAtBlock;
    }

    function bottleCastBlock(bytes32 bottleId) external view returns (uint256) {
        return bottleById[bottleId].castAtBlock;
    }

    function totalWavesCastCount() external view returns (uint256) { return totalWavesCast; }

    receive() external payable {
        treasuryBalance += msg.value;
        emit OceanTreasuryTopped(msg.value, msg.sender, treasuryBalance);
    }
}

