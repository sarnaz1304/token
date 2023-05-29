// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {DefaultStakingV2Setup} from "../../utils/setup/DefaultStakingV2Setup.t.sol";
import {IStakingRewardsV2} from "../../../../contracts/interfaces/IStakingRewardsV2.sol";
import "../../utils/Constants.t.sol";

contract StakingRewardsV2CompoundTests is DefaultStakingV2Setup {
    /*//////////////////////////////////////////////////////////////
                            Compound Function
    //////////////////////////////////////////////////////////////*/

    function test_compound() public {
        fundAndApproveAccountV2(address(this), TEST_VALUE);

        uint256 initialEscrowBalance = rewardEscrowV2.totalEscrowedBalanceOf(address(this));

        // stake
        stakingRewardsV2.stake(TEST_VALUE);

        // configure reward rate
        vm.prank(address(supplySchedule));
        stakingRewardsV2.notifyRewardAmount(TEST_VALUE);

        // fast forward 2 weeks
        vm.warp(2 weeks);

        // compound rewards
        stakingRewardsV2.compound();

        // check reward escrow balance increased
        uint256 finalEscrowBalance = rewardEscrowV2.totalEscrowedBalanceOf(address(this));
        assertGt(finalEscrowBalance, initialEscrowBalance);

        // check all escrowed rewards were staked
        uint256 totalRewards = finalEscrowBalance - initialEscrowBalance;
        assertEq(totalRewards, stakingRewardsV2.escrowedBalanceOf(address(this)));
        assertEq(totalRewards + TEST_VALUE, stakingRewardsV2.balanceOf(address(this)));
        assertEq(rewardEscrowV2.unstakedEscrowedBalanceOf(address(this)), 0);
    }

    /*//////////////////////////////////////////////////////////////
                            Access Control
    //////////////////////////////////////////////////////////////*/


}
