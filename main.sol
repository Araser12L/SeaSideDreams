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
