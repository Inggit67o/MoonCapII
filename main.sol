// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title MoonCapII
/// @notice Lattice-weighted fund-of-funds: top degens run pods; allocators route capital; risk tiers set how far you go. Invest as you like.

contract MoonCapII {

    // -------------------------------------------------------------------------
    // EVENTS
    // -------------------------------------------------------------------------

    event PodSpawned(bytes32 indexed podId, address indexed curator, uint8 riskTier, uint256 minStakeWei, uint256 atBlock);
    event DegenAllocated(address indexed allocator, bytes32 indexed podId, uint256 amountWei, uint256 atBlock);
    event StakePulled(address indexed staker, bytes32 indexed podId, uint256 amountWei, uint256 atBlock);
    event PodRebalanced(bytes32 indexed podId, uint256 newTotalStake, uint256 atBlock);
    event CuratorFeeSwept(address indexed to, uint256 amountWei, uint256 atBlock);
    event RiskTierUpdated(bytes32 indexed podId, uint8 previousTier, uint8 newTier, uint256 atBlock);
    event MinStakeUpdated(bytes32 indexed podId, uint256 previousMin, uint256 newMin, uint256 atBlock);
    event LatticePaused(bytes32 indexed latticeId, bool paused, uint256 atBlock);
    event AllocatorWhitelisted(address indexed allocator, bool allowed, uint256 atBlock);
    event EmergencyDrain(address indexed to, uint256 amountWei, uint256 atBlock);
    event PerformanceFeeCaptured(bytes32 indexed podId, uint256 amountWei, uint256 atBlock);
    event BatchAllocated(uint256 podCount, address indexed by, uint256 totalWei, uint256 atBlock);
    event PodFrozen(bytes32 indexed podId, bool frozen, uint256 atBlock);
    event CuratorRotated(address indexed previousCurator, address indexed newCurator, uint256 atBlock);
    event FeeBpsUpdated(uint256 previousBps, uint256 newBps, uint256 atBlock);
    event TreasuryTopped(uint256 amountWei, uint256 atBlock);

    // -------------------------------------------------------------------------
    // ERRORS
    // -------------------------------------------------------------------------

    error MC2_ZeroPod();
    error MC2_ZeroAddress();
    error MC2_ZeroAmount();
    error MC2_NotCurator();
    error MC2_NotAllocator();
    error MC2_NotEmergencyGuard();
    error MC2_PodNotFound();
    error MC2_PodExists();
    error MC2_PodFrozen();
    error MC2_LatticePaused();
    error MC2_InsufficientStake();
    error MC2_BelowMinStake();
    error MC2_AboveMaxStake();
    error MC2_InvalidRiskTier();
    error MC2_TransferFailed();
    error MC2_ReentrantCall();
    error MC2_InvalidFeeBps();
    error MC2_InvalidBatchLength();
    error MC2_AllocatorNotWhitelisted();
    error MC2_MaxPodsReached();
    error MC2_MaxPodsPerCuratorReached();
    error MC2_AlreadyWithdrawn();
    error MC2_CooldownActive();
    error MC2_InvalidCooldownBlocks();
    error MC2_InvalidMinStake();
    error MC2_PerformanceFeeTooHigh();
    error MC2_CuratorCannotBeZero();

    // -------------------------------------------------------------------------
    // CONSTANTS
    // -------------------------------------------------------------------------

    uint256 public constant MC2_DENOM_BPS = 10_000;
    uint256 public constant MC2_MAX_RISK_TIER = 5;
    uint256 public constant MC2_MAX_PODS = 200_000;
    uint256 public constant MC2_MAX_PODS_PER_CURATOR = 50;
    uint256 public constant MC2_MAX_BATCH_ALLOC = 32;
    uint256 public constant MC2_PERFORMANCE_FEE_BPS_CAP = 2_000;
    uint256 public constant MC2_MANAGEMENT_FEE_BPS_CAP = 500;
    bytes32 public constant MC2_LATTICE_NAMESPACE = keccak256("MoonCapII.lattice.v1");
    bytes32 public constant MC2_VERSION = keccak256("mooncap-ii.v1");

    // -------------------------------------------------------------------------
    // IMMUTABLES
    // -------------------------------------------------------------------------

    address public immutable topCurator;
    address public immutable feeCollector;
    address public immutable emergencyGuard;
    address public immutable treasury;
    uint256 public immutable deployBlock;

    // -------------------------------------------------------------------------
    // STATE
    // -------------------------------------------------------------------------

    struct PodState {
        bytes32 podId;
        address curator;
        uint8 riskTier;
        uint256 totalStakeWei;
        uint256 minStakeWei;
        uint256 maxStakeWei;
        uint256 performanceFeeBps;
        uint256 managementFeeBps;
        uint256 lastFeeBlock;
        uint256 createdAtBlock;
        bool frozen;
        bool exists;
    }

    mapping(bytes32 => PodState) private _pods;
    bytes32[] private _podIds;
    uint256 public podCount;

    mapping(address => bytes32[]) private _podIdsByCurator;
    mapping(address => uint256) private _podCountByCurator;

    mapping(bytes32 => mapping(address => uint256)) private _stakeInPod;
    mapping(bytes32 => address[]) private _stakersInPod;
    mapping(bytes32 => mapping(address => uint256)) private _stakerIndexInPod;

    mapping(address => bool) private _allocatorWhitelist;
    address[] private _allocatorList;

    mapping(bytes32 => bool) private _latticePaused;
    uint256 public globalFeeBps;
    uint256 private _reentrancyLock;

    uint256 public cooldownBlocks;
    mapping(bytes32 => mapping(address => uint256)) private _lastPullBlock;

    uint256 public totalTreasuryWei;

    uint256 public constant MC2_SNAPSHOT_INTERVAL = 256;
    uint256 public constant MC2_MAX_SNAPSHOTS_PER_POD = 64;
    uint256 public constant MC2_MIN_STAKE_WEI_FLOOR = 1 wei;
    uint256 public constant MC2_DEFAULT_COOLDOWN = 12;
    uint256 public constant MC2_RISK_TIER_CAP_MULTIPLIER = 1000;
    uint256 public constant MC2_ALLOCATOR_LIST_MAX = 500;

    struct PodSnapshot {
        uint256 totalStakeWei;
        uint256 blockNumber;
        uint256 timestamp;
    }
    mapping(bytes32 => PodSnapshot[]) private _podSnapshots;
    mapping(bytes32 => uint256) private _snapshotCountByPod;

    mapping(uint8 => uint256) public tierTotalStakeWei;
    mapping(uint8 => uint256) public tierPodCount;
    mapping(uint8 => uint256) public tierCapWei;

    uint256 public totalAllocatedWei;
    uint256 public totalPulledWei;
    uint256 public allocationCount;
    uint256 public pullCount;

    mapping(address => uint256) public totalStakeByAllocator;
    mapping(address => uint256) public allocatorAllocationCount;

    bytes32 public constant MC2_RISK_LABEL_0 = keccak256("mooncap.risk.chill");
    bytes32 public constant MC2_RISK_LABEL_1 = keccak256("mooncap.risk.low");
    bytes32 public constant MC2_RISK_LABEL_2 = keccak256("mooncap.risk.med");
    bytes32 public constant MC2_RISK_LABEL_3 = keccak256("mooncap.risk.high");
    bytes32 public constant MC2_RISK_LABEL_4 = keccak256("mooncap.risk.degen");
    bytes32 public constant MC2_RISK_LABEL_5 = keccak256("mooncap.risk.max");

    // -------------------------------------------------------------------------
    // CONSTRUCTOR
    // -------------------------------------------------------------------------

    constructor() {
        topCurator = address(0x8B7C9d2E4f6A1b3c5D7e9F0a2B4c6d8E0f1A3B5);
        feeCollector = address(0x3F1A5b9c2D4e6f8A0b2C4d6E8f0a1B3c5D7e9F1);
