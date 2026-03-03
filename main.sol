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
    }

    // -------------------------------------------------------------------------
    // VIEWS
    // -------------------------------------------------------------------------

    function getPod(bytes32 podId) external view returns (
        address curator_,
        uint8 riskTier_,
        uint256 totalStakeWei_,
        uint256 minStakeWei_,
        uint256 maxStakeWei_,
        uint256 performanceFeeBps_,
        uint256 managementFeeBps_,
        uint256 createdAtBlock_,
        bool frozen_,
        bool exists_
    ) {
        PodState storage p = _pods[podId];
        return (
            p.curator,
            p.riskTier,
            p.totalStakeWei,
            p.minStakeWei,
            p.maxStakeWei,
            p.performanceFeeBps,
            p.managementFeeBps,
            p.createdAtBlock,
            p.frozen,
            p.exists
        );
    }

    function podExists(bytes32 podId) external view returns (bool) {
        return _pods[podId].exists;
    }

    function stakeInPod(bytes32 podId, address staker) external view returns (uint256) {
        return _stakeInPod[podId][staker];
    }

    function getPodIdAt(uint256 index) external view returns (bytes32) {
        if (index >= _podIds.length) revert MC2_InvalidBatchLength();
        return _podIds[index];
    }

    function getStakersInPod(bytes32 podId) external view returns (address[] memory) {
        return _stakersInPod[podId];
    }

    function isAllocatorWhitelisted(address a) external view returns (bool) {
        return _allocatorWhitelist[a] || a == topCurator;
    }

    function isLatticePaused() external view returns (bool) {
        return _latticePaused[MC2_LATTICE_NAMESPACE];
    }

    function contractBalanceWei() external view returns (uint256) {
        return address(this).balance;
    }

    function getGlobalStats() external view returns (
        uint256 totalPods_,
        uint256 deployBlock_,
        uint256 currentFeeBps_,
        uint256 cooldownBlocks_,
        uint256 treasuryWei_
    ) {
        return (podCount, deployBlock, globalFeeBps, cooldownBlocks, totalTreasuryWei);
    }

    function getPodsInRange(uint256 fromIndex, uint256 toIndex) external view returns (
        bytes32[] memory podIds_,
        address[] memory curators_,
        uint8[] memory riskTiers_,
        uint256[] memory totalStakes_,
        bool[] memory frozenFlags_
    ) {
        if (fromIndex > toIndex || toIndex >= _podIds.length) revert MC2_InvalidBatchLength();
        uint256 len = toIndex - fromIndex + 1;
        podIds_ = new bytes32[](len);
        curators_ = new address[](len);
        riskTiers_ = new uint8[](len);
        totalStakes_ = new uint256[](len);
        frozenFlags_ = new bool[](len);
        for (uint256 i = 0; i < len; i++) {
            bytes32 id = _podIds[fromIndex + i];
            PodState storage p = _pods[id];
            podIds_[i] = id;
            curators_[i] = p.curator;
            riskTiers_[i] = p.riskTier;
            totalStakes_[i] = p.totalStakeWei;
            frozenFlags_[i] = p.frozen;
        }
    }

    function lastPullBlock(bytes32 podId, address staker) external view returns (uint256) {
        return _lastPullBlock[podId][staker];
    }

    function canPull(bytes32 podId, address staker) external view returns (bool) {
        if (_stakeInPod[podId][staker] == 0) return false;
        if (_pods[podId].frozen) return false;
        uint256 last = _lastPullBlock[podId][staker];
        if (last == 0) return true;
        return block.number - last >= cooldownBlocks;
    }

    function getSnapshotAt(bytes32 podId, uint256 index) external view returns (uint256 totalStakeWei_, uint256 blockNumber_, uint256 timestamp_) {
        PodSnapshot[] storage snap = _podSnapshots[podId];
        if (index >= snap.length) revert MC2_InvalidBatchLength();
        PodSnapshot storage s = snap[index];
        return (s.totalStakeWei, s.blockNumber, s.timestamp);
    }

    function getSnapshotCount(bytes32 podId) external view returns (uint256) {
        return _podSnapshots[podId].length;
    }

    function getTierStats(uint8 riskTier) external view returns (uint256 totalStakeWei_, uint256 podCount_, uint256 capWei_) {
        if (riskTier > MC2_MAX_RISK_TIER) revert MC2_InvalidRiskTier();
        return (tierTotalStakeWei[riskTier], tierPodCount[riskTier], tierCapWei[riskTier]);
    }

    function getRiskLabelForTier(uint8 riskTier) external pure returns (bytes32) {
        if (riskTier == 0) return MC2_RISK_LABEL_0;
        if (riskTier == 1) return MC2_RISK_LABEL_1;
        if (riskTier == 2) return MC2_RISK_LABEL_2;
        if (riskTier == 3) return MC2_RISK_LABEL_3;
        if (riskTier == 4) return MC2_RISK_LABEL_4;
        if (riskTier == 5) return MC2_RISK_LABEL_5;
        return bytes32(0);
    }

    function getStakerPortfolio(address staker, bytes32[] calldata podIds) external view returns (uint256[] memory stakes_) {
        stakes_ = new uint256[](podIds.length);
        for (uint256 i = 0; i < podIds.length; i++) {
            stakes_[i] = _stakeInPod[podIds[i]][staker];
        }
    }

    function getPodIdsByCurator(address curator) external view returns (bytes32[] memory) {
        return _podIdsByCurator[curator];
    }

    function getAllocatorListLength() external view returns (uint256) {
        return _allocatorList.length;
    }

    function getAllocatorAt(uint256 index) external view returns (address) {
        if (index >= _allocatorList.length) revert MC2_InvalidBatchLength();
        return _allocatorList[index];
    }

    function getAggregateStats() external view returns (
        uint256 totalAllocatedWei_,
        uint256 totalPulledWei_,
        uint256 allocationCount_,
        uint256 pullCount_,
        uint256 netStakeWei_
    ) {
        return (totalAllocatedWei, totalPulledWei, allocationCount, pullCount, totalAllocatedWei > totalPulledWei ? totalAllocatedWei - totalPulledWei : 0);
    }

    function wouldAllocateSucceed(bytes32 podId, uint256 amountWei) external view returns (bool) {
        if (podId == bytes32(0) || amountWei == 0) return false;
        PodState storage pod = _pods[podId];
        if (!pod.exists || pod.frozen) return false;
        if (pod.minStakeWei > 0 && amountWei < pod.minStakeWei) return false;
        if (pod.maxStakeWei > 0 && pod.totalStakeWei + amountWei > pod.maxStakeWei) return false;
        uint256 toPod = amountWei - (amountWei * globalFeeBps) / MC2_DENOM_BPS;
        if (tierCapWei[pod.riskTier] > 0 && tierTotalStakeWei[pod.riskTier] + toPod > tierCapWei[pod.riskTier]) return false;
        return true;
    }

    function getManagementFeeAccrued(bytes32 podId, uint256 upToBlock) external view returns (uint256) {
        PodState storage pod = _pods[podId];
        if (!pod.exists || pod.managementFeeBps == 0) return 0;
        uint256 fromBlock = pod.lastFeeBlock;
        if (upToBlock <= fromBlock) return 0;
        uint256 blocksElapsed = upToBlock - fromBlock;
        return (pod.totalStakeWei * pod.managementFeeBps * blocksElapsed) / (MC2_DENOM_BPS * 1_000_000);
    }

    /// @notice Returns full pod details in one call for off-chain indexing.
    function getFullPodDetails(bytes32 podId) external view returns (
        address curator_,
        uint8 riskTier_,
        uint256 totalStakeWei_,
        uint256 minStakeWei_,
        uint256 maxStakeWei_,
        uint256 performanceFeeBps_,
        uint256 managementFeeBps_,
        uint256 lastFeeBlock_,
        uint256 createdAtBlock_,
        bool frozen_,
        bool exists_,
        uint256 snapshotCount_
    ) {
        PodState storage p = _pods[podId];
        return (
            p.curator,
            p.riskTier,
            p.totalStakeWei,
            p.minStakeWei,
            p.maxStakeWei,
            p.performanceFeeBps,
            p.managementFeeBps,
            p.lastFeeBlock,
            p.createdAtBlock,
            p.frozen,
            p.exists,
            _podSnapshots[podId].length
        );
    }

    /// @notice Returns stats for all risk tiers in one call.
    function getTierStatsBatch() external view returns (
        uint256[] memory totalStakeWei_,
        uint256[] memory podCounts_,
        uint256[] memory capsWei_
    ) {
        uint256 n = MC2_MAX_RISK_TIER + 1;
        totalStakeWei_ = new uint256[](n);
        podCounts_ = new uint256[](n);
        capsWei_ = new uint256[](n);
        for (uint8 t = 0; t <= MC2_MAX_RISK_TIER; t++) {
            totalStakeWei_[t] = tierTotalStakeWei[t];
            podCounts_[t] = tierPodCount[t];
            capsWei_[t] = tierCapWei[t];
        }
    }

    /// @notice Sum of staker balance across given pods.
    function getStakerTotalAcrossPods(address staker, bytes32[] calldata podIds) external view returns (uint256 total_) {
        for (uint256 i = 0; i < podIds.length; i++) {
            total_ += _stakeInPod[podIds[i]][staker];
        }
    }

    /// @notice Blocks remaining until staker can pull from pod (0 if already allowed).
    function blocksUntilCanPull(bytes32 podId, address staker) external view returns (uint256) {
        uint256 last = _lastPullBlock[podId][staker];
        if (last == 0) return 0;
        uint256 elapsed = block.number - last;
        if (elapsed >= cooldownBlocks) return 0;
        return cooldownBlocks - elapsed;
    }

    /// @notice Compute global allocation fee for a given amount (pure-style using current globalFeeBps).
    function computeFeeForAmount(uint256 amountWei) external view returns (uint256 feeWei_, uint256 netWei_) {
        feeWei_ = (amountWei * globalFeeBps) / MC2_DENOM_BPS;
        netWei_ = amountWei - feeWei_;
    }

    /// @notice Check if tier cap would be exceeded by adding amount to pod.
    function wouldExceedTierCap(bytes32 podId, uint256 amountWei) external view returns (bool) {
        PodState storage pod = _pods[podId];
        if (!pod.exists || tierCapWei[pod.riskTier] == 0) return false;
        uint256 toPod = amountWei - (amountWei * globalFeeBps) / MC2_DENOM_BPS;
        return tierTotalStakeWei[pod.riskTier] + toPod > tierCapWei[pod.riskTier];
    }

    /// @notice Number of stakers in a pod.
    function getStakerCountInPod(bytes32 podId) external view returns (uint256) {
        return _stakersInPod[podId].length;
    }

    /// @notice Staker address at index in pod (for enumeration).
    function getStakerInPodAt(bytes32 podId, uint256 index) external view returns (address) {
        if (index >= _stakersInPod[podId].length) revert MC2_InvalidBatchLength();
        return _stakersInPod[podId][index];
    }

    /// @notice Total wei across all pods (sum of pod.totalStakeWei).
    function getTotalStakeAcrossAllPods() external view returns (uint256 total_) {
        for (uint256 i = 0; i < _podIds.length; i++) {
            total_ += _pods[_podIds[i]].totalStakeWei;
        }
    }

    /// @notice Pod IDs that have at least one snapshot.
    function getPodIdsWithSnapshots(uint256 fromIndex, uint256 toIndex) external view returns (bytes32[] memory ids_, uint256[] memory counts_) {
        if (fromIndex > toIndex || toIndex >= _podIds.length) revert MC2_InvalidBatchLength();
        uint256 len = toIndex - fromIndex + 1;
        ids_ = new bytes32[](len);
        counts_ = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            bytes32 id = _podIds[fromIndex + i];
            ids_[i] = id;
            counts_[i] = _podSnapshots[id].length;
        }
    }

    /// @notice Last snapshot for a pod (if any).
    function getLastSnapshot(bytes32 podId) external view returns (uint256 totalStakeWei_, uint256 blockNumber_, uint256 timestamp_) {
        PodSnapshot[] storage snap = _podSnapshots[podId];
        if (snap.length == 0) return (0, 0, 0);
        PodSnapshot storage s = snap[snap.length - 1];
        return (s.totalStakeWei, s.blockNumber, s.timestamp);
    }

    /// @notice Whether allocator list is at max capacity.
    function isAllocatorListFull() external view returns (bool) {
        return _allocatorList.length >= MC2_ALLOCATOR_LIST_MAX;
    }

    /// @notice Curator pod count (for topCurator).
    function getCuratorPodCount(address curator) external view returns (uint256) {
        return _podCountByCurator[curator];
    }

    /// @notice All pod IDs (length).
    function getPodIdsLength() external view returns (uint256) {
        return _podIds.length;
    }

    /// @notice Version namespace for off-chain identification.
    function getVersionNamespace() external pure returns (bytes32) {
        return MC2_VERSION;
    }

    /// @notice Lattice namespace for pause scope.
    function getLatticeNamespace() external pure returns (bytes32) {
        return MC2_LATTICE_NAMESPACE;
    }

    /// @notice Fee that would be charged for amount at given bps.
    function computeFeeAtBps(uint256 amountWei, uint256 feeBps) external pure returns (uint256 feeWei_) {
        if (feeBps > MC2_DENOM_BPS) return amountWei;
        return (amountWei * feeBps) / MC2_DENOM_BPS;
    }

    /// @notice Net amount after fee at given bps.
    function computeNetAtBps(uint256 amountWei, uint256 feeBps) external pure returns (uint256 netWei_) {
        if (feeBps > MC2_DENOM_BPS) return 0;
        return amountWei - (amountWei * feeBps) / MC2_DENOM_BPS;
    }

    /// @notice Validate risk tier (0..MC2_MAX_RISK_TIER).
    function isValidRiskTier(uint8 riskTier) external pure returns (bool) {
        return riskTier <= MC2_MAX_RISK_TIER;
    }

    /// @notice Max performance fee bps allowed.
    function getPerformanceFeeBpsCap() external pure returns (uint256) {
        return MC2_PERFORMANCE_FEE_BPS_CAP;
    }

    /// @notice Max management fee bps allowed.
    function getManagementFeeBpsCap() external pure returns (uint256) {
        return MC2_MANAGEMENT_FEE_BPS_CAP;
    }

    /// @notice Max batch allocation size.
    function getMaxBatchAllocSize() external pure returns (uint256) {
        return MC2_MAX_BATCH_ALLOC;
    }

    /// @notice Max pods per curator.
    function getMaxPodsPerCurator() external pure returns (uint256) {
        return MC2_MAX_PODS_PER_CURATOR;
    }

    /// @notice Max total pods.
    function getMaxPods() external pure returns (uint256) {
        return MC2_MAX_PODS;
    }

    /// @notice Default snapshot interval in blocks.
    function getSnapshotInterval() external pure returns (uint256) {
        return MC2_SNAPSHOT_INTERVAL;
    }

    /// @notice Max snapshots per pod.
    function getMaxSnapshotsPerPod() external pure returns (uint256) {
        return MC2_MAX_SNAPSHOTS_PER_POD;
    }

    /// @notice Get multiple pod summaries in one call (by index range).
    function getPodSummaries(uint256 fromIndex, uint256 toIndex) external view returns (
        bytes32[] memory podIds_,
        uint8[] memory riskTiers_,
        uint256[] memory totalStakes_,
        bool[] memory frozen_
    ) {
        if (fromIndex > toIndex || toIndex >= _podIds.length) revert MC2_InvalidBatchLength();
        uint256 len = toIndex - fromIndex + 1;
        podIds_ = new bytes32[](len);
        riskTiers_ = new uint8[](len);
        totalStakes_ = new uint256[](len);
        frozen_ = new bool[](len);
        for (uint256 i = 0; i < len; i++) {
            PodState storage p = _pods[_podIds[fromIndex + i]];
            podIds_[i] = p.podId;
            riskTiers_[i] = p.riskTier;
            totalStakes_[i] = p.totalStakeWei;
            frozen_[i] = p.frozen;
        }
    }

    /// @notice Estimate management fee for blocks elapsed (per 1M blocks scaled).
    function estimateManagementFeeForBlocks(uint256 principalWei, uint256 feeBps, uint256 blocksElapsed) external pure returns (uint256) {
        if (feeBps > MC2_MANAGEMENT_FEE_BPS_CAP) return 0;
        return (principalWei * feeBps * blocksElapsed) / (MC2_DENOM_BPS * 1_000_000);
    }

    /// @notice Bytes32 zero check for podId.
    function isZeroPodId(bytes32 podId) external pure returns (bool) {
        return podId == bytes32(0);
    }

    /// @notice Immutable addresses (for off-chain config).
    function getImmutableAddresses() external view returns (
        address topCurator_,
        address feeCollector_,
        address emergencyGuard_,
        address treasury_
    ) {
        return (topCurator, feeCollector, emergencyGuard, treasury);
    }

    /// @notice Get pod data for multiple pod IDs in one call.
    function getPodsBatch(bytes32[] calldata podIds) external view returns (
        address[] memory curators_,
        uint8[] memory riskTiers_,
        uint256[] memory totalStakes_,
        uint256[] memory minStakes_,
        uint256[] memory maxStakes_,
        bool[] memory frozen_,
        bool[] memory exists_
    ) {
        uint256 n = podIds.length;
        if (n > MC2_MAX_BATCH_ALLOC) revert MC2_InvalidBatchLength();
        curators_ = new address[](n);
        riskTiers_ = new uint8[](n);
        totalStakes_ = new uint256[](n);
        minStakes_ = new uint256[](n);
        maxStakes_ = new uint256[](n);
        frozen_ = new bool[](n);
        exists_ = new bool[](n);
        for (uint256 i = 0; i < n; i++) {
            PodState storage p = _pods[podIds[i]];
            curators_[i] = p.curator;
            riskTiers_[i] = p.riskTier;
            totalStakes_[i] = p.totalStakeWei;
            minStakes_[i] = p.minStakeWei;
            maxStakes_[i] = p.maxStakeWei;
            frozen_[i] = p.frozen;
            exists_[i] = p.exists;
        }
    }

    /// @notice Stake amounts for one staker across multiple pods (same as getStakerPortfolio but explicit name).
    function getStakesForPods(address staker, bytes32[] calldata podIds) external view returns (uint256[] memory) {
        uint256[] memory out = new uint256[](podIds.length);
        for (uint256 i = 0; i < podIds.length; i++) {
            out[i] = _stakeInPod[podIds[i]][staker];
        }
        return out;
    }

    /// @notice All risk label hashes (for off-chain mapping).
    function getAllRiskLabels() external pure returns (bytes32[] memory labels_) {
        labels_ = new bytes32[](6);
        labels_[0] = MC2_RISK_LABEL_0;
        labels_[1] = MC2_RISK_LABEL_1;
        labels_[2] = MC2_RISK_LABEL_2;
        labels_[3] = MC2_RISK_LABEL_3;
        labels_[4] = MC2_RISK_LABEL_4;
        labels_[5] = MC2_RISK_LABEL_5;
    }

    /// @notice Denominator for basis points (10000).
    function getDenomBps() external pure returns (uint256) {
        return MC2_DENOM_BPS;
    }

    /// @notice Total allocator count (whitelist length).
    function getTotalAllocatorCount() external view returns (uint256) {
        return _allocatorList.length;
    }

    /// @notice Check if address is the top curator.
    function isTopCurator(address account) external view returns (bool) {
        return account == topCurator;
    }

    /// @notice Check if address is the emergency guard.
    function isEmergencyGuard(address account) external view returns (bool) {
        return account == emergencyGuard;
    }

    /// @notice Check if address is the fee collector.
    function isFeeCollector(address account) external view returns (bool) {
        return account == feeCollector;
    }

    /// @notice Check if address is the treasury.
    function isTreasury(address account) external view returns (bool) {
        return account == treasury;
    }

