// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

// Inheritance
import {IRewardEscrowV2, VestingEntries} from "./interfaces/IRewardEscrowV2.sol";
import {ERC721EnumerableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

// Internal references
import {IKwenta} from "./interfaces/IKwenta.sol";
import {IStakingRewardsV2} from "./interfaces/IStakingRewardsV2.sol";

// TODO: think about safeTransfer, safeMint etc. - Should I use SafeERC20 link in StakingRewards?
// TODO: Think about what functions could be "approved for" with lower risk - such that they can be delegated from a hardware wallet to a hot wallet

/// @title KWENTA Reward Escrow
/// @author SYNTHETIX, JaredBorders (jaredborders@proton.me), JChiaramonte7 (jeremy@bytecode.llc), tommyrharper (zeroknowledgeltd@gmail.com)
/// @notice Updated version of Synthetix's RewardEscrow with new features specific to Kwenta
contract RewardEscrowV2 is
    IRewardEscrowV2,
    ERC721EnumerableUpgradeable,
    OwnableUpgradeable,
    UUPSUpgradeable
{
    /*///////////////////////////////////////////////////////////////
                        CONSTANTS/IMMUTABLES
    ///////////////////////////////////////////////////////////////*/

    /// @notice Max escrow duration
    uint256 public constant MAX_DURATION = 4 * 52 weeks; // Default max 4 years duration

    uint256 public constant DEFAULT_DURATION = 52 weeks; // Default 1 year duration

    /// @notice Default early vesting fee - used for new vesting entries from staking rewards
    uint8 public constant DEFAULT_EARLY_VESTING_FEE = 90; // Default 90 percent

    /// @notice Maximum early vesting fee - cannot be higher than 100%
    uint8 public constant MAXIMUM_EARLY_VESTING_FEE = 100;

    /// @notice Minimum early vesting fee
    uint8 public constant MINIMUM_EARLY_VESTING_FEE = 50;

    /// @notice Contract for KWENTA ERC20 token
    IKwenta public kwenta;

    /// @notice Contract for StakingRewardsV2
    IStakingRewardsV2 public stakingRewards;

    /*///////////////////////////////////////////////////////////////
                                STATE
    ///////////////////////////////////////////////////////////////*/

    ///@notice mapping of entryIDs to vesting entries
    mapping(uint256 => VestingEntries.VestingEntry) public vestingSchedules;

    // TODO: delete and use totalSupply() instead - maybe not with burn decrementing it?
    /// @notice Counter for new vesting entry ids
    uint256 public nextEntryId;

    /// @notice An account's total escrowed KWENTA balance to save recomputing this for fee extraction purposes
    mapping(address => uint256) public totalEscrowedAccountBalance;

    /// @notice An account's total vested reward KWENTA
    mapping(address => uint256) public totalVestedAccountBalance;

    /// @notice The total remaining escrowed balance, for verifying the actual KWENTA balance of this contract against
    uint256 public totalEscrowedBalance;

    /// @notice treasury address - this may change
    address public treasuryDAO;

    /*///////////////////////////////////////////////////////////////
                                AUTH
    ///////////////////////////////////////////////////////////////*/

    /// @notice Restrict function to only the staking rewards contract
    modifier onlyStakingRewards() {
        if (msg.sender != address(stakingRewards)) revert OnlyStakingRewards();
        _;
    }

    /*///////////////////////////////////////////////////////////////
                        CONSTRUCTOR / INITIALIZER
    ///////////////////////////////////////////////////////////////*/

    /// @dev disable default constructor for disable implementation contract
    /// Actual contract construction will take place in the initialize function via proxy
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc IRewardEscrowV2
    function initialize(address _owner, address _kwenta) external override initializer {
        // Initialize inherited contracts
        __Ownable_init();
        __UUPSUpgradeable_init();
        __ERC721_init("Kwenta Reward Escrow", "KRE");

        // transfer ownership
        transferOwnership(_owner);

        // define variables
        nextEntryId = 1;
        kwenta = IKwenta(_kwenta);
    }

    /*///////////////////////////////////////////////////////////////
                                SETTERS
    ///////////////////////////////////////////////////////////////*/

    /// @inheritdoc IRewardEscrowV2
    function setStakingRewards(address _stakingRewards) external override onlyOwner {
        if (_stakingRewards == address(0)) revert ZeroAddress();
        if (address(stakingRewards) != address(0)) revert StakingRewardsAlreadySet();

        stakingRewards = IStakingRewardsV2(_stakingRewards);
        emit StakingRewardsSet(address(_stakingRewards));
    }

    /// @inheritdoc IRewardEscrowV2
    function setTreasuryDAO(address _treasuryDAO) external override onlyOwner {
        if (_treasuryDAO == address(0)) revert ZeroAddress();
        treasuryDAO = _treasuryDAO;
        emit TreasuryDAOSet(treasuryDAO);
    }

    /*///////////////////////////////////////////////////////////////
                                VIEWS
    ///////////////////////////////////////////////////////////////*/

    /// @inheritdoc IRewardEscrowV2
    function getKwentaAddress() external view override returns (address) {
        return address(kwenta);
    }

    /// @inheritdoc IRewardEscrowV2
    function totalEscrowedBalanceOf(address _account) external view override returns (uint256) {
        return totalEscrowedAccountBalance[_account];
    }

    /// @inheritdoc IRewardEscrowV2
    function unstakedEscrowedBalanceOf(address _account) public view override returns (uint256) {
        return totalEscrowedAccountBalance[_account] - stakingRewards.escrowedBalanceOf(_account);
    }

    /// @inheritdoc IRewardEscrowV2
    function getVestingEntry(uint256 _entryID)
        external
        view
        override
        returns (uint64 endTime, uint256 escrowAmount, uint256 duration, uint8 earlyVestingFee)
    {
        endTime = vestingSchedules[_entryID].endTime;
        escrowAmount = vestingSchedules[_entryID].escrowAmount;
        duration = vestingSchedules[_entryID].duration;
        earlyVestingFee = vestingSchedules[_entryID].earlyVestingFee;
    }

    /// @inheritdoc IRewardEscrowV2
    function getVestingSchedules(address _account, uint256 _index, uint256 _pageSize)
        external
        view
        override
        returns (VestingEntries.VestingEntryWithID[] memory)
    {
        uint256 endIndex = _index + _pageSize;

        // If index starts after the endIndex return no results
        if (endIndex <= _index) {
            return new VestingEntries.VestingEntryWithID[](0);
        }

        // If the page extends past the end of the list, truncate it.
        uint256 numEntries = balanceOf(_account);
        if (endIndex > numEntries) {
            endIndex = numEntries;
        }

        uint256 n = endIndex - _index;
        VestingEntries.VestingEntryWithID[] memory vestingEntries =
            new VestingEntries.VestingEntryWithID[](n);
        for (uint256 i; i < n;) {
            uint256 entryID = tokenOfOwnerByIndex(_account, i + _index);

            VestingEntries.VestingEntry memory entry = vestingSchedules[entryID];

            vestingEntries[i] = VestingEntries.VestingEntryWithID({
                endTime: uint64(entry.endTime),
                escrowAmount: entry.escrowAmount,
                entryID: entryID
            });

            unchecked {
                ++i;
            }
        }
        return vestingEntries;
    }

    /// @inheritdoc IRewardEscrowV2
    function getAccountVestingEntryIDs(address _account, uint256 _index, uint256 _pageSize)
        external
        view
        override
        returns (uint256[] memory)
    {
        uint256 endIndex = _index + _pageSize;

        // If the page extends past the end of the list, truncate it.
        uint256 numEntries = balanceOf(_account);
        if (endIndex > numEntries) {
            endIndex = numEntries;
        }
        if (endIndex <= _index) {
            return new uint256[](0);
        }

        uint256 n = endIndex - _index;
        uint256[] memory page = new uint256[](n);
        for (uint256 i; i < n;) {
            page[i] = tokenOfOwnerByIndex(_account, i + _index);

            unchecked {
                ++i;
            }
        }
        return page;
    }

    /// @inheritdoc IRewardEscrowV2
    function getVestingQuantity(uint256[] calldata _entryIDs)
        external
        view
        override
        returns (uint256 total, uint256 totalFee)
    {
        uint256 entryIDsLength = _entryIDs.length;
        for (uint256 i = 0; i < entryIDsLength;) {
            VestingEntries.VestingEntry memory entry = vestingSchedules[_entryIDs[i]];

            // Skip entry if escrowAmount == 0
            if (entry.escrowAmount != 0) {
                (uint256 quantity, uint256 fee) = _claimableAmount(entry);

                // add quantity to total
                total += quantity;
                totalFee += fee;
            }

            unchecked {
                ++i;
            }
        }
    }

    /// @inheritdoc IRewardEscrowV2
    function getVestingEntryClaimable(uint256 _entryID)
        external
        view
        override
        returns (uint256 quantity, uint256 fee)
    {
        VestingEntries.VestingEntry memory entry = vestingSchedules[_entryID];
        (quantity, fee) = _claimableAmount(entry);
    }

    function _claimableAmount(VestingEntries.VestingEntry memory _entry)
        internal
        view
        returns (uint256 quantity, uint256 fee)
    {
        uint256 escrowAmount = _entry.escrowAmount;

        if (escrowAmount != 0) {
            // Full escrow amounts claimable if block.timestamp equal to or after entry endTime
            if (block.timestamp >= _entry.endTime) {
                quantity = escrowAmount;
            } else {
                fee = _earlyVestFee(_entry);
                quantity = escrowAmount - fee;
            }
        }
    }

    function _earlyVestFee(VestingEntries.VestingEntry memory _entry)
        internal
        view
        returns (uint256 earlyVestFee)
    {
        uint256 timeUntilVest = _entry.endTime - block.timestamp;
        // Fee starts by default at 90% (but could be any percentage) and falls linearly
        uint256 initialFee = _entry.escrowAmount * _entry.earlyVestingFee / 100;
        earlyVestFee = initialFee * timeUntilVest / _entry.duration;
    }

    function _isEscrowStaked(address _account) internal view returns (bool) {
        return stakingRewards.escrowedBalanceOf(_account) > 0;
    }

    /*///////////////////////////////////////////////////////////////
                            MUTATIVE FUNCTIONS
    ///////////////////////////////////////////////////////////////*/

    /// @inheritdoc IRewardEscrowV2
    function vest(uint256[] calldata _entryIDs) external override {
        uint256 total;
        uint256 totalFee;
        uint256 entryIDsLength = _entryIDs.length;
        for (uint256 i = 0; i < entryIDsLength; ++i) {
            VestingEntries.VestingEntry storage entry = vestingSchedules[_entryIDs[i]];
            if (_ownerOf(_entryIDs[i]) != msg.sender) {
                continue;
            }

            // TODO: if i decide to keep deleting these at burn, this check may be unecessary
            // Skip entry if escrowAmount == 0 already vested
            if (entry.escrowAmount != 0) {
                (uint256 quantity, uint256 fee) = _claimableAmount(entry);

                // update entry to remove escrowAmount
                _burn(_entryIDs[i]);

                // add quantity to total
                total += quantity;
                totalFee += fee;
            }
        }

        // Transfer vested tokens. Will revert if total > totalEscrowedAccountBalance
        if (total != 0) {
            // Withdraw staked escrowed kwenta if needed for reward
            if (_isEscrowStaked(msg.sender)) {
                uint256 totalWithFee = total + totalFee;
                uint256 unstakedEscrow = unstakedEscrowedBalanceOf(msg.sender);
                if (totalWithFee > unstakedEscrow) {
                    uint256 amountToUnstake = totalWithFee - unstakedEscrow;
                    stakingRewards.unstakeEscrowSkipCooldown(msg.sender, amountToUnstake);
                }
            }

            // Send any fee to Treasury
            if (totalFee != 0) {
                _reduceAccountEscrowBalances(msg.sender, totalFee);

                /// @dev this will revert if the kwenta token transfer fails
                /// @dev if using this with a different token, make sure to check the return value
                kwenta.transfer(treasuryDAO, totalFee);
            }

            // Transfer kwenta
            _transferVestedTokens(msg.sender, total);
        }
    }

    /// @inheritdoc IRewardEscrowV2
    function createEscrowEntry(
        address _beneficiary,
        uint256 _deposit,
        uint256 _duration,
        uint8 _earlyVestingFee
    ) external override {
        if (_beneficiary == address(0)) revert ZeroAddress();
        if (_earlyVestingFee > MAXIMUM_EARLY_VESTING_FEE) revert EarlyVestingFeeTooHigh();
        if (_earlyVestingFee < MINIMUM_EARLY_VESTING_FEE) revert EarlyVestingFeeTooLow();
        if (_deposit == 0) revert ZeroAmount();
        if (_duration == 0 || _duration > MAX_DURATION) revert InvalidDuration();

        // TODO: test this is the case on on fork
        /// @dev this will revert if the kwenta token transfer fails
        /// @dev if using this with a different token, make sure to check the return value
        kwenta.transferFrom(msg.sender, address(this), _deposit);

        // Append vesting entry for the beneficiary address
        _mint(_beneficiary, _deposit, _duration, _earlyVestingFee);
    }

    /// @inheritdoc IRewardEscrowV2
    function appendVestingEntry(address _account, uint256 _quantity)
        external
        override
        onlyStakingRewards
    {
        _mint(_account, _quantity, DEFAULT_DURATION, DEFAULT_EARLY_VESTING_FEE);
    }

    /// @inheritdoc IRewardEscrowV2
    function stakeEscrow(uint256 _amount) external override {
        stakingRewards.stakeEscrow(msg.sender, _amount);
    }

    /// @inheritdoc IRewardEscrowV2
    function unstakeEscrow(uint256 _amount) public override {
        stakingRewards.unstakeEscrow(msg.sender, _amount);
    }

    /// @inheritdoc IRewardEscrowV2
    function bulkTransferFrom(address _from, address _to, uint256[] calldata _entryIDs)
        external
        override
    {
        uint256 entryIDsLength = _entryIDs.length;
        for (uint256 i = 0; i < entryIDsLength;) {
            transferFrom(_from, _to, _entryIDs[i]);
            unchecked {
                ++i;
            }
        }
    }

    /*///////////////////////////////////////////////////////////////
                                INTERNALS
    ///////////////////////////////////////////////////////////////*/

    /// @dev override the internal _transfer function to ensure vestingSchedules and account balances are updated
    /// and that there is sufficient unstaked escrow for a transfer
    function _transfer(address _from, address _to, uint256 _entryID) internal override {
        VestingEntries.VestingEntry memory entry = vestingSchedules[_entryID];

        // TODO: more efficient way for bulk transfer without querying each time?
        uint256 unstakedEscrow = unstakedEscrowedBalanceOf(_from);
        if (unstakedEscrow < entry.escrowAmount) {
            revert InsufficientUnstakedBalance(_entryID, entry.escrowAmount, unstakedEscrow);
        }

        super._transfer(_from, _to, _entryID);

        totalEscrowedAccountBalance[_from] -= entry.escrowAmount;
        totalEscrowedAccountBalance[_to] += entry.escrowAmount;
    }

    function _burn(uint256 _entryID) internal override {
        // TODO: should delete the whole entry? or just the escrowAmount as before? gas savings?
        // vestingSchedules[_entryID].escrowAmount = 0;
        delete vestingSchedules[_entryID];
        super._burn(_entryID);
    }

    /// @dev Transfer vested KWENTA to account and update totalEscrowedAccountBalance, totalVestedAccountBalance
    function _transferVestedTokens(address _account, uint256 _amount) internal {
        _reduceAccountEscrowBalances(_account, _amount);
        totalVestedAccountBalance[_account] += _amount;
        kwenta.transfer(_account, _amount);
        emit Vested(_account, _amount);
    }

    function _reduceAccountEscrowBalances(address _account, uint256 _amount) internal {
        // Reverts if amount being vested is greater than the account's existing totalEscrowedAccountBalance
        totalEscrowedBalance -= _amount;
        totalEscrowedAccountBalance[_account] -= _amount;
    }

    function _mint(address _account, uint256 _quantity, uint256 _duration, uint8 _earlyVestingFee)
        internal
    {
        // There must be enough balance in the contract to provide for the vesting entry.
        totalEscrowedBalance += _quantity;
        if (kwenta.balanceOf(address(this)) < totalEscrowedBalance) revert InsufficientBalance();

        // Escrow the tokens for duration.
        uint256 endTime = block.timestamp + _duration;

        // Add quantity to account's escrowed balance
        totalEscrowedAccountBalance[_account] += _quantity;

        uint256 entryID = nextEntryId;
        vestingSchedules[entryID] = VestingEntries.VestingEntry({
            endTime: uint64(endTime),
            escrowAmount: _quantity,
            duration: _duration,
            earlyVestingFee: _earlyVestingFee
        });

        // TODO: think - should safeMint? - could use nonReentrant
        _mint(_account, entryID);

        // Increment the next entry id.
        ++nextEntryId;

        // TODO: add earlyVestingFee to this event
        emit VestingEntryCreated(_account, _quantity, _duration, entryID);
    }

    function _authorizeUpgrade(address _newImplementation) internal override onlyOwner {}
}
