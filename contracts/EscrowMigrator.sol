// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

// Inheritance
import {IEscrowMigrator} from "./interfaces/IEscrowMigrator.sol";
import {Ownable2StepUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

// Internal references
import {IKwenta} from "./interfaces/IKwenta.sol";
import {IRewardEscrowV2} from "./interfaces/IRewardEscrowV2.sol";
import {IStakingRewardsV2} from "./interfaces/IStakingRewardsV2.sol";
import {IRewardEscrow, VestingEntries} from "./interfaces/IRewardEscrow.sol";

contract EscrowMigrator is
    IEscrowMigrator,
    Ownable2StepUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    /*///////////////////////////////////////////////////////////////
                        CONSTANTS/IMMUTABLES
    ///////////////////////////////////////////////////////////////*/

    /// @notice Contract for KWENTA ERC20 token
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    IKwenta public immutable kwenta;

    /// @notice Contract for RewardEscrowV1
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    IRewardEscrow public immutable rewardEscrowV1;

    /// @notice Contract for RewardEscrowV1
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    IRewardEscrowV2 public immutable rewardEscrowV2;

    /// @notice Contract for RewardEscrowV1
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    IStakingRewardsV2 public immutable stakingRewardsV2;

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    mapping(address => mapping(uint256 => VestingEntries.VestingEntry)) public
        registeredVestingSchedules;

    mapping(address => uint256) public totalVestedAccountBalanceAtRegistrationTime;

    mapping(address => uint256) public totalUserEscrowToMigrate;

    mapping(address => MigrationStatus) public migrationStatus;

    mapping(address => uint256[]) public registeredEntryIDs;

    /*///////////////////////////////////////////////////////////////
                        CONSTRUCTOR / INITIALIZER
    ///////////////////////////////////////////////////////////////*/

    /// @dev disable default constructor for disable implementation contract
    /// Actual contract construction will take place in the initialize function via proxy
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address _kwenta,
        address _rewardEscrowV1,
        address _rewardEscrowV2,
        address _stakingRewardsV2
    ) {
        if (_kwenta == address(0)) revert ZeroAddress();
        if (_rewardEscrowV1 == address(0)) revert ZeroAddress();
        if (_rewardEscrowV2 == address(0)) revert ZeroAddress();
        if (_stakingRewardsV2 == address(0)) revert ZeroAddress();

        kwenta = IKwenta(_kwenta);
        rewardEscrowV1 = IRewardEscrow(_rewardEscrowV1);
        rewardEscrowV2 = IRewardEscrowV2(_rewardEscrowV2);
        stakingRewardsV2 = IStakingRewardsV2(_stakingRewardsV2);

        _disableInitializers();
    }

    /// @inheritdoc IEscrowMigrator
    function initialize(address _contractOwner) external override initializer {
        if (_contractOwner == address(0)) revert ZeroAddress();

        // Initialize inherited contracts
        __Ownable2Step_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        // transfer ownership
        _transferOwnership(_contractOwner);
    }

    /*//////////////////////////////////////////////////////////////
                               FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    // step 1: initiate migration
    function initiateMigration() external {
        if (migrationStatus[msg.sender] != MigrationStatus.NOT_STARTED) {
            revert MigrationAlreadyStarted();
        }
        if (rewardEscrowV1.balanceOf(msg.sender) == 0) revert NoEscrowBalanceToMigrate();

        migrationStatus[msg.sender] = MigrationStatus.INITIATED;
        totalVestedAccountBalanceAtRegistrationTime[msg.sender] =
            rewardEscrowV1.totalVestedAccountBalance(msg.sender);
    }

    // step 2: register entries for migration
    function registerEntriesForEarlyVestingAndMigration(uint256[] calldata _entryIDs) external {
        if (
            migrationStatus[msg.sender] != MigrationStatus.INITIATED
            // allow the state to be REGISTERED so that users can register entries in batches
            && migrationStatus[msg.sender] != MigrationStatus.REGISTERED
        ) {
            revert MustBeInitiatedOrRegistered();
        }

        for (uint256 i = 0; i < _entryIDs.length; i++) {
            uint256 entryID = _entryIDs[i];

            // skip if already registered
            if (registeredVestingSchedules[msg.sender][entryID].endTime != 0) continue;

            (uint64 endTime, uint256 escrowAmount, uint256 duration) =
                rewardEscrowV1.getVestingEntry(msg.sender, entryID);

            // skip if entry does not exist
            if (endTime == 0) continue;
            // skip if entry is already vested
            if (escrowAmount == 0) continue;
            // skip if entry is already fully mature (hence no need to migrate)
            if (endTime <= block.timestamp) continue;

            registeredVestingSchedules[msg.sender][entryID] = VestingEntries.VestingEntry({
                endTime: endTime,
                escrowAmount: escrowAmount,
                duration: duration
            });

            registeredEntryIDs[msg.sender].push(entryID);
        }

        migrationStatus[msg.sender] = MigrationStatus.REGISTERED;
    }

    // step 3: vest all entries and confirm
    function confirmEntriesAreVested() external {
        if (migrationStatus[msg.sender] != MigrationStatus.REGISTERED) {
            revert MustBeInRegisteredState();
        }

        uint256[] storage entryIDs = registeredEntryIDs[msg.sender];
        for (uint256 i = 0; i < entryIDs.length; i++) {
            uint256 entryID = entryIDs[i];
            (, uint256 escrowAmount,) = rewardEscrowV1.getVestingEntry(msg.sender, entryID);

            // if it is not zero, it hasn't been vested
            assert(escrowAmount == 0);
        }

        migrationStatus[msg.sender] = MigrationStatus.VESTED;
    }

    // step 4: pay liquid kwenta for migration
    function payForMigration() external {
        if (migrationStatus[msg.sender] != MigrationStatus.VESTED) {
            revert MustBeInVestedState();
        }

        uint256 vestedAtRegistration = totalVestedAccountBalanceAtRegistrationTime[msg.sender];
        uint256 vestedNow = rewardEscrowV1.totalVestedAccountBalance(msg.sender);
        uint256 userDebt = vestedNow - vestedAtRegistration;
        kwenta.transferFrom(msg.sender, address(this), userDebt);

        migrationStatus[msg.sender] = MigrationStatus.PAID;
    }

    function migrateRegisteredAndVestedEntries(uint256[] calldata _entryIDs) external {
        if (migrationStatus[msg.sender] != MigrationStatus.PAID) {
            revert MustBeInPaidState();
        }

        for (uint256 i = 0; i < _entryIDs.length; i++) {
            uint256 entryID = _entryIDs[i];

            VestingEntries.VestingEntry storage registeredEntry =
                registeredVestingSchedules[msg.sender][entryID];

            // skip if not registered
            if (registeredEntry.endTime == 0) continue;

            (uint64 endTime, uint256 escrowAmount, uint256 duration) =
                rewardEscrowV1.getVestingEntry(msg.sender, entryID);

            // skip if entry is not already vested
            if (escrowAmount != 0) continue;

            bool isFullyMature = endTime < block.timestamp;
            uint256 earlyVestingFee;
            uint256 newDuration;
            if (isFullyMature) {
                // set duration to 1 as 0 is not allowed
                newDuration = 1;
                // 50% is the minimum allowed earlyVestingFee
                earlyVestingFee = 50;
            } else {
                uint256 timeRemaining = endTime - block.timestamp;
                // max percentageLeft is 100 as timeRemaining cannot be larger than duration
                uint256 percentageLeft = timeRemaining * 100 / duration;
                // 90% is the fixed early vesting fee for V1 entries
                // reduce based on the percentage of time remaining
                earlyVestingFee = percentageLeft * 90 / 100;
                assert(earlyVestingFee <= 90);
                newDuration = timeRemaining;
            }

            kwenta.approve(address(rewardEscrowV2), escrowAmount);
            rewardEscrowV2.createEscrowEntry(
                msg.sender, escrowAmount, newDuration, uint8(earlyVestingFee)
            );

            // update this to zero so it cannot be migrated again
            registeredEntry.endTime = 0;
        }
    }

    /*//////////////////////////////////////////////////////////////
                             UPGRADEABILITY
    //////////////////////////////////////////////////////////////*/

    function _authorizeUpgrade(address _newImplementation) internal override onlyOwner {}

    /*///////////////////////////////////////////////////////////////
                                PAUSABLE
    ///////////////////////////////////////////////////////////////*/

    /// @inheritdoc IEscrowMigrator
    function pauseRewardEscrow() external override onlyOwner {
        _pause();
    }

    /// @inheritdoc IEscrowMigrator
    function unpauseRewardEscrow() external override onlyOwner {
        _unpause();
    }
}
