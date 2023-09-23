// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {DynamicFeeHook} from "../src/DynamicFeeHook.sol";
import {HookMiner} from "../test/utils/HookMiner.sol";

contract DynamicFeeHookScript is Script {
    address constant CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);

    function setUp() public {}

    function run() public {
        IPoolManager manager = IPoolManager(payable(0x6B18E29A6c6931af9f8087dbe12e21E495855adA));

        // hook contracts must have specific flags encoded in the address
        uint160 flags = uint160(
            Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_INITIALIZE_FLAG
        );

        // Mine a salt that will produce a hook address with the correct flags
        (address hookAddress, bytes32 salt) = HookMiner.find(CREATE2_DEPLOYER, flags, 1000, type(DynamicFeeHook).creationCode, abi.encode(address(manager)));

        // Deploy the hook using CREATE2
        vm.broadcast();
        DynamicFeeHook hook = new DynamicFeeHook{salt: salt}(manager);
        console.log(hookAddress);
        require(address(hook) == hookAddress, "Script: hook address mismatch");
    }
}
