// // SPDX-License-Identifier: UNLICENSED
// pragma solidity ^0.8.20;

// import {Script} from "forge-std/Script.sol";
// import {DynamicFeeHook} from "../src/DynamicFeeHook.sol";
// import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

// contract StoreBytecode is Script {
//     function run() {
//         bytes memory _creationCode = type(DynamicFeeHook).creationCode;
//     }
// }

// contract DeployHook is Script {
//     // This should reuse the struct in the lib instead
//     bool beforeInitialize = true;
//     bool afterInitialize = true;
//     bool beforeModifyPosition = true;
//     bool afterModifyPosition = true;
//     bool beforeSwap = true;
//     bool afterSwap = true;
//     bool beforeDonate = true;
//     bool afterDonate = true;

//     IPoolManager poolManager = ;

//     bytes _creationCode = type(Hook).creationCode;

//     function setUp() public {
//         // read env for factory address

//         // read json for bytecode
//     }

//     function run() public {
//         vm.broadcast();
//         // Compute theoric address

//         // check the address has the corresponding hooks with lib hooks.validateHookAddress, if not, revert

//         // call to factory to deploy hook
//     }
// }

// contract DeployFactory is Script {

// }