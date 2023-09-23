// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.21;

import {DynamicFeeHook} from "./DynamicFeeHook.sol";

import {BaseHook} from "periphery-next/BaseHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";

contract DynamicFeeStub is DynamicFeeHook {
    constructor(IPoolManager _poolManager, DynamicFeeHook addressToEtch) DynamicFeeHook(_poolManager) {}

    function validateHookAddress(BaseHook _this) internal pure override {}

    function setTickerLower(PoolId poolId, uint24 tickLower) public {
        super._setTickLower(poolId, tickLower);
    }
}

