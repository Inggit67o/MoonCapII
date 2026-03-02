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
