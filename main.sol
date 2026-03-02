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
        emergencyGuard = address(0xE4D6f8A0B2c4e6F8a1B3c5d7E9f0A2b4C6d8E0f2);
        treasury = address(0xA1b3C5d7E9f0A2b4C6d8E0f1A3b5C7d9E1f3A5b7);
        deployBlock = block.number;
        globalFeeBps = 25;
        cooldownBlocks = 12;

        if (topCurator == address(0)) revert MC2_CuratorCannotBeZero();
        tierCapWei[0] = 1_000 ether;
        tierCapWei[1] = 5_000 ether;
        tierCapWei[2] = 10_000 ether;
        tierCapWei[3] = 25_000 ether;
        tierCapWei[4] = 50_000 ether;
        tierCapWei[5] = 100_000 ether;
    }

    // -------------------------------------------------------------------------
    // MODIFIERS
    // -------------------------------------------------------------------------

    modifier onlyCurator() {
        if (msg.sender != topCurator) revert MC2_NotCurator();
        _;
    }

    modifier onlyEmergencyGuard() {
        if (msg.sender != emergencyGuard) revert MC2_NotEmergencyGuard();
        _;
    }

    modifier whenLatticeNotPaused() {
        if (_latticePaused[MC2_LATTICE_NAMESPACE]) revert MC2_LatticePaused();
        _;
    }

    modifier nonReentrant() {
        if (_reentrancyLock != 0) revert MC2_ReentrantCall();
        _reentrancyLock = 1;
        _;
        _reentrancyLock = 0;
    }

    // -------------------------------------------------------------------------
    // POD LIFECYCLE
    // -------------------------------------------------------------------------

    function spawnPod(
        bytes32 podId,
        uint8 riskTier,
        uint256 minStakeWei,
        uint256 maxStakeWei,
        uint256 performanceFeeBps,
        uint256 managementFeeBps
    ) external onlyCurator nonReentrant whenLatticeNotPaused returns (bool) {
        if (podId == bytes32(0)) revert MC2_ZeroPod();
        if (_pods[podId].exists) revert MC2_PodExists();
        if (podCount >= MC2_MAX_PODS) revert MC2_MaxPodsReached();
        if (_podCountByCurator[topCurator] >= MC2_MAX_PODS_PER_CURATOR) revert MC2_MaxPodsPerCuratorReached();
        if (riskTier > MC2_MAX_RISK_TIER) revert MC2_InvalidRiskTier();
        if (performanceFeeBps > MC2_PERFORMANCE_FEE_BPS_CAP) revert MC2_PerformanceFeeTooHigh();
        if (managementFeeBps > MC2_MANAGEMENT_FEE_BPS_CAP) revert MC2_InvalidFeeBps();
        if (minStakeWei == 0 && maxStakeWei > 0) revert MC2_InvalidMinStake();

        _pods[podId] = PodState({
            podId: podId,
            curator: topCurator,
            riskTier: riskTier,
            totalStakeWei: 0,
            minStakeWei: minStakeWei,
            maxStakeWei: maxStakeWei,
            performanceFeeBps: performanceFeeBps,
            managementFeeBps: managementFeeBps,
            lastFeeBlock: block.number,
            createdAtBlock: block.number,
            frozen: false,
            exists: true
        });
        _podIds.push(podId);
        podCount++;
        _podIdsByCurator[topCurator].push(podId);
        _podCountByCurator[topCurator]++;
        tierPodCount[riskTier]++;
        _maybeTakeSnapshot(podId, 0);

        emit PodSpawned(podId, topCurator, riskTier, minStakeWei, block.number);
        return true;
    }

    function _updateTierStatsOnAlloc(uint8 riskTier, uint256 amountWei, bool isAdd) internal {
        if (riskTier > MC2_MAX_RISK_TIER) return;
        if (isAdd) {
            tierTotalStakeWei[riskTier] += amountWei;
        } else {
            if (tierTotalStakeWei[riskTier] >= amountWei) tierTotalStakeWei[riskTier] -= amountWei;
        }
    }

    function _maybeTakeSnapshot(bytes32 podId, uint256 currentTotal) internal {
        PodSnapshot[] storage snap = _podSnapshots[podId];
        if (snap.length >= MC2_MAX_SNAPSHOTS_PER_POD) return;
        if (snap.length > 0 && block.number < snap[snap.length - 1].blockNumber + MC2_SNAPSHOT_INTERVAL) return;
        snap.push(PodSnapshot({ totalStakeWei: currentTotal, blockNumber: block.number, timestamp: block.timestamp }));
        _snapshotCountByPod[podId] = snap.length;
    }

    function allocate(bytes32 podId) external payable nonReentrant whenLatticeNotPaused {
        if (podId == bytes32(0)) revert MC2_ZeroPod();
        PodState storage pod = _pods[podId];
        if (!pod.exists) revert MC2_PodNotFound();
        if (pod.frozen) revert MC2_PodFrozen();
        if (!_allocatorWhitelist[msg.sender] && topCurator != msg.sender) revert MC2_AllocatorNotWhitelisted();
        if (msg.value == 0) revert MC2_ZeroAmount();
        if (pod.minStakeWei > 0 && msg.value < pod.minStakeWei) revert MC2_BelowMinStake();
        if (pod.maxStakeWei > 0 && pod.totalStakeWei + msg.value > pod.maxStakeWei) revert MC2_AboveMaxStake();
        if (tierCapWei[pod.riskTier] > 0 && tierTotalStakeWei[pod.riskTier] + (msg.value - (msg.value * globalFeeBps) / MC2_DENOM_BPS) > tierCapWei[pod.riskTier]) revert MC2_AboveMaxStake();

        uint256 fee = (msg.value * globalFeeBps) / MC2_DENOM_BPS;
        uint256 toPod = msg.value - fee;
        if (fee > 0 && feeCollector != address(0)) {
            (bool okFee,) = feeCollector.call{ value: fee }("");
            if (!okFee) revert MC2_TransferFailed();
        }

        pod.totalStakeWei += toPod;
        _stakeInPod[podId][msg.sender] += toPod;
        if (_stakerIndexInPod[podId][msg.sender] == 0) {
            _stakersInPod[podId].push(msg.sender);
            _stakerIndexInPod[podId][msg.sender] = _stakersInPod[podId].length;
        }
        _updateTierStatsOnAlloc(pod.riskTier, toPod, true);
        totalAllocatedWei += toPod;
        allocationCount++;
        totalStakeByAllocator[msg.sender] += toPod;
        allocatorAllocationCount[msg.sender]++;
        _maybeTakeSnapshot(podId, pod.totalStakeWei);

        emit DegenAllocated(msg.sender, podId, toPod, block.number);
    }

    function pullStake(bytes32 podId, uint256 amountWei) external nonReentrant whenLatticeNotPaused {
        if (podId == bytes32(0)) revert MC2_ZeroPod();
        PodState storage pod = _pods[podId];
        if (!pod.exists) revert MC2_PodNotFound();
        if (pod.frozen) revert MC2_PodFrozen();
        uint256 staked = _stakeInPod[podId][msg.sender];
        if (amountWei == 0 || staked < amountWei) revert MC2_InsufficientStake();

        uint256 sincePull = block.number - _lastPullBlock[podId][msg.sender];
        if (sincePull < cooldownBlocks && _lastPullBlock[podId][msg.sender] != 0) revert MC2_CooldownActive();

        _lastPullBlock[podId][msg.sender] = block.number;
        pod.totalStakeWei -= amountWei;
        _stakeInPod[podId][msg.sender] -= amountWei;
        _updateTierStatsOnAlloc(pod.riskTier, amountWei, false);
        totalPulledWei += amountWei;
        pullCount++;
        totalStakeByAllocator[msg.sender] -= amountWei;
        _maybeTakeSnapshot(podId, pod.totalStakeWei);

        (bool ok,) = msg.sender.call{ value: amountWei }("");
        if (!ok) revert MC2_TransferFailed();

        emit StakePulled(msg.sender, podId, amountWei, block.number);
        emit PodRebalanced(podId, pod.totalStakeWei, block.number);
    }

    function rebalancePod(bytes32 podId) external nonReentrant {
        if (podId == bytes32(0)) revert MC2_ZeroPod();
        PodState storage pod = _pods[podId];
        if (!pod.exists) revert MC2_PodNotFound();
        if (msg.sender != pod.curator && msg.sender != topCurator) revert MC2_NotCurator();
        emit PodRebalanced(podId, pod.totalStakeWei, block.number);
    }

    function capturePerformanceFee(bytes32 podId, uint256 amountWei) external onlyCurator nonReentrant {
        if (podId == bytes32(0)) revert MC2_ZeroPod();
        PodState storage pod = _pods[podId];
        if (!pod.exists) revert MC2_PodNotFound();
        if (amountWei == 0 || amountWei > address(this).balance) revert MC2_ZeroAmount();
        uint256 maxFee = (pod.totalStakeWei * pod.performanceFeeBps) / MC2_DENOM_BPS;
        if (amountWei > maxFee) revert MC2_PerformanceFeeTooHigh();

        if (feeCollector != address(0)) {
            (bool ok,) = feeCollector.call{ value: amountWei }("");
            if (!ok) revert MC2_TransferFailed();
        }
        emit PerformanceFeeCaptured(podId, amountWei, block.number);
    }

    function sweepCuratorFees() external onlyCurator nonReentrant {
        uint256 bal = address(this).balance;
        if (bal == 0) revert MC2_ZeroAmount();
        (bool ok,) = feeCollector != address(0) ? feeCollector.call{ value: bal }("") : msg.sender.call{ value: bal }("");
        if (!ok) revert MC2_TransferFailed();
        emit CuratorFeeSwept(feeCollector != address(0) ? feeCollector : msg.sender, bal, block.number);
    }

    function setPodRiskTier(bytes32 podId, uint8 newTier) external onlyCurator nonReentrant {
        if (podId == bytes32(0)) revert MC2_ZeroPod();
        PodState storage pod = _pods[podId];
        if (!pod.exists) revert MC2_PodNotFound();
        if (newTier > MC2_MAX_RISK_TIER) revert MC2_InvalidRiskTier();
        uint8 prev = pod.riskTier;
        pod.riskTier = newTier;
        emit RiskTierUpdated(podId, prev, newTier, block.number);
    }

    function setPodMinStake(bytes32 podId, uint256 newMinStakeWei) external onlyCurator nonReentrant {
        if (podId == bytes32(0)) revert MC2_ZeroPod();
        PodState storage pod = _pods[podId];
        if (!pod.exists) revert MC2_PodNotFound();
        uint256 prev = pod.minStakeWei;
        pod.minStakeWei = newMinStakeWei;
        emit MinStakeUpdated(podId, prev, newMinStakeWei, block.number);
    }

    function setPodFrozen(bytes32 podId, bool frozen) external onlyCurator nonReentrant {
        if (podId == bytes32(0)) revert MC2_ZeroPod();
        PodState storage pod = _pods[podId];
        if (!pod.exists) revert MC2_PodNotFound();
        pod.frozen = frozen;
        emit PodFrozen(podId, frozen, block.number);
    }

    function setLatticePaused(bool paused) external onlyCurator {
        _latticePaused[MC2_LATTICE_NAMESPACE] = paused;
        emit LatticePaused(MC2_LATTICE_NAMESPACE, paused, block.number);
    }

    function setAllocatorWhitelist(address allocator, bool allowed) external onlyCurator {
        if (allocator == address(0)) revert MC2_ZeroAddress();
        _allocatorWhitelist[allocator] = allowed;
        if (allowed) {
            bool found = false;
            for (uint256 i = 0; i < _allocatorList.length; i++) {
                if (_allocatorList[i] == allocator) {
                    found = true;
                    break;
                }
            }
            if (!found && _allocatorList.length < MC2_ALLOCATOR_LIST_MAX) {
                _allocatorList.push(allocator);
            }
        }
        emit AllocatorWhitelisted(allocator, allowed, block.number);
    }

    function setGlobalFeeBps(uint256 newFeeBps) external onlyCurator {
        if (newFeeBps > MC2_MANAGEMENT_FEE_BPS_CAP) revert MC2_InvalidFeeBps();
        uint256 prev = globalFeeBps;
        globalFeeBps = newFeeBps;
        emit FeeBpsUpdated(prev, newFeeBps, block.number);
    }

    function setCooldownBlocks(uint256 blocks) external onlyCurator {
        if (blocks > 1_000_000) revert MC2_InvalidCooldownBlocks();
        cooldownBlocks = blocks;
    }

    function setTierCapWei(uint8 riskTier, uint256 capWei) external onlyCurator {
        if (riskTier > MC2_MAX_RISK_TIER) revert MC2_InvalidRiskTier();
        tierCapWei[riskTier] = capWei;
    }

    function takeSnapshot(bytes32 podId) external onlyCurator nonReentrant {
        if (podId == bytes32(0)) revert MC2_ZeroPod();
        PodState storage pod = _pods[podId];
        if (!pod.exists) revert MC2_PodNotFound();
        _maybeTakeSnapshot(podId, pod.totalStakeWei);
    }

    function emergencyDrain(uint256 amountWei) external onlyEmergencyGuard nonReentrant {
        if (amountWei == 0 || amountWei > address(this).balance) revert MC2_ZeroAmount();
        (bool ok,) = treasury != address(0) ? treasury.call{ value: amountWei }("") : msg.sender.call{ value: amountWei }("");
        if (!ok) revert MC2_TransferFailed();
        totalTreasuryWei += amountWei;
        emit EmergencyDrain(treasury != address(0) ? treasury : msg.sender, amountWei, block.number);
    }

    function topTreasury() external payable {
        if (msg.value == 0) revert MC2_ZeroAmount();
        totalTreasuryWei += msg.value;
        emit TreasuryTopped(msg.value, block.number);
    }

    // -------------------------------------------------------------------------
    // BATCH ALLOCATE
    // -------------------------------------------------------------------------

    function batchAllocate(bytes32[] calldata podIds, uint256[] calldata amountsWei) external payable nonReentrant whenLatticeNotPaused {
        if (podIds.length != amountsWei.length || podIds.length == 0 || podIds.length > MC2_MAX_BATCH_ALLOC) revert MC2_InvalidBatchLength();
        if (!_allocatorWhitelist[msg.sender] && topCurator != msg.sender) revert MC2_AllocatorNotWhitelisted();

        uint256 totalNeeded = 0;
        for (uint256 i = 0; i < podIds.length; i++) {
            totalNeeded += amountsWei[i];
        }
        if (msg.value < totalNeeded) revert MC2_InsufficientStake();

        uint256 globalFeeTotal = 0;
        for (uint256 i = 0; i < podIds.length; i++) {
            if (podIds[i] == bytes32(0)) revert MC2_ZeroPod();
            PodState storage pod = _pods[podIds[i]];
            if (!pod.exists) revert MC2_PodNotFound();
            if (pod.frozen) revert MC2_PodFrozen();
            uint256 amt = amountsWei[i];
            if (amt == 0) continue;
            if (pod.minStakeWei > 0 && amt < pod.minStakeWei) revert MC2_BelowMinStake();
            if (pod.maxStakeWei > 0 && pod.totalStakeWei + amt > pod.maxStakeWei) revert MC2_AboveMaxStake();

            uint256 fee = (amt * globalFeeBps) / MC2_DENOM_BPS;
            globalFeeTotal += fee;
            uint256 toPod = amt - fee;
            pod.totalStakeWei += toPod;
            _stakeInPod[podIds[i]][msg.sender] += toPod;
            if (_stakerIndexInPod[podIds[i]][msg.sender] == 0) {
                _stakersInPod[podIds[i]].push(msg.sender);
                _stakerIndexInPod[podIds[i]][msg.sender] = _stakersInPod[podIds[i]].length;
            }
            _updateTierStatsOnAlloc(pod.riskTier, toPod, true);
            totalAllocatedWei += toPod;
            allocationCount++;
            totalStakeByAllocator[msg.sender] += toPod;
            allocatorAllocationCount[msg.sender]++;
            _maybeTakeSnapshot(podIds[i], pod.totalStakeWei);
            emit DegenAllocated(msg.sender, podIds[i], toPod, block.number);
        }

        if (globalFeeTotal > 0 && feeCollector != address(0)) {
            (bool okFee,) = feeCollector.call{ value: globalFeeTotal }("");
            if (!okFee) revert MC2_TransferFailed();
        }
        if (msg.value > totalNeeded) {
            (bool okRefund,) = msg.sender.call{ value: msg.value - totalNeeded }("");
            if (!okRefund) revert MC2_TransferFailed();
        }
        emit BatchAllocated(podIds.length, msg.sender, totalNeeded, block.number);
