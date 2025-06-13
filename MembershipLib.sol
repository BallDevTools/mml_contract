// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./ContractErrors.sol";

library MembershipLib {
    struct MembershipPlan {
        uint256 price;
        string name;
        uint256 membersPerCycle;
        bool isActive;
    }

    struct Member {
        address upline;
        uint256 totalReferrals;
        uint256 totalEarnings;
        uint256 planId;
        uint256 cycleNumber;
        uint256 registeredAt;
    }

    struct CycleInfo {
        uint256 currentCycle;
        uint256 membersInCurrentCycle;
    }

    function updateCycle(
        CycleInfo storage cycleInfo,
        MembershipPlan storage plan
    ) internal returns (uint256) {
        cycleInfo.membersInCurrentCycle++;
        
        if (cycleInfo.membersInCurrentCycle >= plan.membersPerCycle) {
            cycleInfo.currentCycle++;
            cycleInfo.membersInCurrentCycle = 0;
        }
        
        return cycleInfo.currentCycle;
    }

    function validatePlanUpgrade(
        uint256 newPlanId,
        Member storage currentMember,
        mapping(uint256 => MembershipPlan) storage plans,
        uint256 planCount
    ) internal view {
        if (newPlanId == 0 || newPlanId > planCount) revert ContractErrors.InvalidPlanID();
        if (!plans[newPlanId].isActive) revert ContractErrors.InactivePlan();
        if (newPlanId != currentMember.planId + 1) revert ContractErrors.NextPlanOnly();
    }

    function determineUpline(
        address upline,
        uint256 planId,
        address sender,
        bool isFirstMember,
        address contractOwner,
        mapping(address => Member) storage members,
        function(address) external view returns (bool) hasBalance
    ) internal view returns (address) {
        if (isFirstMember) {
            return contractOwner;
        }
        
        if (upline == address(0) || upline == sender) {
            return contractOwner;
        }
        
        if (!hasBalance(upline)) revert ContractErrors.UplineNotMember();
        if (members[upline].planId < planId) revert ContractErrors.UplinePlanLow();
        
        return upline;
    }
}