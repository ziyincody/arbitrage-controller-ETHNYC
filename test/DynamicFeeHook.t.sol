// SPDX-License-Identifier: UNLICENSED
// Updated solidity
pragma solidity ^0.8.21;

// Foundry libraries
import "forge-std/Test.sol";
import "forge-std/console.sol";
import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";

// Test ERC-20 token implementation
import {TestERC20} from "v4-core/test/TestERC20.sol";

// Libraries
import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FeeLibrary} from "v4-core/libraries/FeeLibrary.sol";

// Interfaces
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

// Pool Manager related contracts
import {PoolManager} from "v4-core/PoolManager.sol";
import {PoolModifyPositionTest} from "v4-core/test/PoolModifyPositionTest.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";

// Our contracts
import {DynamicFeeHook} from "../src/DynamicFeeHook.sol";
import {DynamicFeeStub} from "../src/DynamicFeeStub.sol";

contract DynamicFeeHookTest is Test, GasSnapshot {
    // Use the libraries
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using FeeLibrary for uint24;

    // Hardcode the address for our hook instead of deploying it
    // We will overwrite the storage to replace code at this address with code from the stub
    DynamicFeeHook hook = DynamicFeeHook(address(uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG)));

    // poolManager is the Uniswap v4 Pool Manager
    PoolManager poolManager;

    // modifyPositionRouter is the test-version of the contract that allows
    // liquidity providers to add/remove/update their liquidity positions
    PoolModifyPositionTest modifyPositionRouter;

    // swapRouter is the test-version of the contract that allows
    // users to execute swaps on Uniswap v4
    PoolSwapTest swapRouter;

    // token0 and token1 are the two tokens in the pool
    TestERC20 token0;
    TestERC20 token1;

    // poolKey and poolId are the pool key and pool id for the pool
    PoolKey poolKey;
    PoolId poolId;

    // SQRT_RATIO_1_1 is the Q notation for sqrtPriceX96 where price = 1
    // i.e. sqrt(1) * 2^96
    // This is used as the initial price for the pool 
    // as we add equal amounts of token0 and token1 to the pool during setUp
    uint160 constant SQRT_RATIO_1_1 = 79228162514264337593543950336;

    function _deployERC20Tokens() private {
        TestERC20 tokenA = new TestERC20(2 ** 128);
        TestERC20 tokenB = new TestERC20(2 ** 128);

        if (address(tokenA) < address(tokenB)) {
            token0 = tokenA;
            token1 = tokenB;
        } else {
            token0 = tokenB;
            token1 = tokenA;
        }
    }

    function _stubValidateHookAddress() private {
        DynamicFeeStub stub = new DynamicFeeStub(poolManager, hook);

        (, bytes32[] memory writes) = vm.accesses(address(stub));

        vm.etch(address(hook), address(stub).code);

        unchecked {
            for (uint256 i = 0; i < writes.length; i++) {
                bytes32 slot = writes[i];
                vm.store(address(hook), slot, vm.load(address(stub), slot));
            }
        }
    }

    function _initializePool() private {
        modifyPositionRouter = new PoolModifyPositionTest(IPoolManager(address(poolManager)));
        swapRouter = new PoolSwapTest(IPoolManager(address(poolManager)));

        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000 | FeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(hook)
        });
        poolId = poolKey.toId();

        poolManager.initialize(poolKey, SQRT_RATIO_1_1, '0x00');
    }

    function _addLiquidityToPool() private {
        token0.mint(address(this), 100 ether);
        token1.mint(address(this), 100 ether);

        token0.approve(address(modifyPositionRouter), 100 ether);
        token1.approve(address(modifyPositionRouter), 100 ether);

        modifyPositionRouter.modifyPosition(
            poolKey,
            IPoolManager.ModifyPositionParams(-60, 60, 10 ether)
        );

        modifyPositionRouter.modifyPosition(
            poolKey,
            IPoolManager.ModifyPositionParams(-120, 120, 10 ether)
        );

        modifyPositionRouter.modifyPosition(
            poolKey,
            IPoolManager.ModifyPositionParams(
                TickMath.minUsableTick(60),
                TickMath.maxUsableTick(60),
                50 ether
            )
        );

        token0.approve(address(swapRouter), 100 ether);
        token1.approve(address(swapRouter), 100 ether);
    }

    function setUp() public {
        _deployERC20Tokens();
        poolManager = new PoolManager(500_000);
        _stubValidateHookAddress();
        _initializePool();
        _addLiquidityToPool();
    }

    receive() external payable {}

    function test_getFeeBaseFee() public {
        vm.roll(100);

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: 1 ether,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_RATIO + 1
        });
        
        // with no previous fee
        uint24 fee = hook.getFee(address(this), poolKey, params, "0x00");
        assertEq(fee, 3000);

        _swap(params);
        assertNotEq(hook.getTickLower(poolId, 100), 0);
    }

    function test_getFeeWithPriceChanges() public {
        vm.roll(100);

        IPoolManager.SwapParams memory zeroToOneParams = _getSwapParams(true, 5 ether);

        // first two blocks no fee changes cuz still getting data
        uint24 fee100 = hook.getFee(address(this), poolKey, zeroToOneParams, "0x00");
        assertEq(fee100, 3000);
        _swap(zeroToOneParams);
        
        vm.roll(101);
        uint24 fee101 = hook.getFee(address(this), poolKey, zeroToOneParams, "0x00");
        assertEq(fee101, 3000);
        _swap(zeroToOneParams);

        // because previous zeroToOne, selling token 0 to token 1
        // so the buy fee will be lower, while the sell fee increases, both by 10%
        vm.roll(102);
        uint24 sellFee102 = hook.getFee(address(this), poolKey, zeroToOneParams, "0x00");
        assertEq(sellFee102, 3300);
        IPoolManager.SwapParams memory oneToZeroParam = _getSwapParams(false, 5 ether);
        uint24 buyFee102 = hook.getFee(address(this), poolKey, oneToZeroParam, "0x00");
        assertEq(buyFee102, 2700);
        _swap(oneToZeroParam);

        vm.roll(103);
        uint24 sellFee103 = hook.getFee(address(this), poolKey, zeroToOneParams, "0x00");
        assertEq(sellFee103, 3000);
        uint24 buyFee103 = hook.getFee(address(this), poolKey, oneToZeroParam, "0x00");
        assertEq(buyFee103, 3000);
    }

    function _swap(IPoolManager.SwapParams memory params) private {
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            withdrawTokens: true, settleUsingTransfer: true
        });

        swapRouter.swap(poolKey, params, testSettings);
    }

    function _getSwapParams(bool zeroForOne, int256 amountSpecified) private pure returns (IPoolManager.SwapParams memory params) {
        params.zeroForOne = zeroForOne;
        params.amountSpecified = amountSpecified;
        params.sqrtPriceLimitX96 = zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1;
    }

}

