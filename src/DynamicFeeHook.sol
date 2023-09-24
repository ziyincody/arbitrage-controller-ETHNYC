// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.21;

import {BaseHook} from "periphery-next/BaseHook.sol";
import {ERC1155} from "openzeppelin-contracts/contracts/token/ERC1155/ERC1155.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {IDynamicFeeManager} from "v4-core/interfaces/IDynamicFeeManager.sol";
import {FeeLibrary} from "v4-core/libraries/FeeLibrary.sol";

contract DynamicFeeHook is BaseHook, IDynamicFeeManager {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using FixedPointMathLib for uint256;
    using FeeLibrary for uint24;

    error MustUseDynamicFee();

    // store updated tick per block number
    mapping(PoolId poolId => mapping(uint256 blockNumber => uint24 tickLower)) public tickLowerPerBlock;
    mapping(PoolId poolId => mapping(uint256 blockNumber => uint24 buyDynamicFee) ) public buyDynamicFees;
    mapping(PoolId poolId => mapping(uint256 blockNumber => uint24 sellDynamicFee)) public sellDynamicFees;

    // Compound address
    address public cometAddress;
    // Aave address
    address public aaveAddress
    // which lending protocol to use
    string public lendingProtocol;

    constructor(
        IPoolManager _poolManager,
        address _cometAddress,
        address _aaveAddress
    ) BaseHook(_poolManager) IDynamicFeeManager() {
        cometAddress = _cometAddress;
        aaveAddress = _aaveAddress;
    }

    function getHooksCalls() public pure override returns (Hooks.Calls memory) {
        return Hooks.Calls({
            beforeInitialize: true,
            afterInitialize: false,
            beforeModifyPosition: false,
            afterModifyPosition: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false
        });
    }

    function beforeInitialize(
        address, PoolKey calldata key, uint160, bytes calldata
    ) external pure override returns (bytes4 selector) {
        if (!key.fee.isDynamicFee()) revert MustUseDynamicFee();
        return BaseHook.beforeInitialize.selector;
    }

    function _getFeeBuy(PoolKey calldata key) private returns (uint24 newFee) {
        if (buyDynamicFees[key.toId()][block.number] != 0) {
            return buyDynamicFees[key.toId()][block.number];
        }

        uint24 feeDelta = _getFeeDelta(key);
        uint24 prevBuyFee = buyDynamicFees[key.toId()][block.number-1];
        if (prevBuyFee == 0) {
            prevBuyFee = _revertDynamicFeeFlag(key.fee);
        }
        uint24 newBuyFee = _isPriceIncreasing(key) ? prevBuyFee + feeDelta : prevBuyFee - feeDelta;
        buyDynamicFees[key.toId()][block.number] = newBuyFee;
        return newBuyFee;
    }

    function _getFeeSell(PoolKey calldata key) private returns (uint24 newFee) {
        if (sellDynamicFees[key.toId()][block.number] != 0) {
            return sellDynamicFees[key.toId()][block.number];
        }
        
        uint24 feeDelta = _getFeeDelta(key);
        uint24 prevSellFee = sellDynamicFees[key.toId()][block.number-1];
        if (prevSellFee == 0) {
            prevSellFee = _revertDynamicFeeFlag(key.fee);
        }
        uint24 newSellFee = _isPriceIncreasing(key) ? prevSellFee - feeDelta : prevSellFee + feeDelta;
        sellDynamicFees[key.toId()][block.number] = newSellFee;
        return newSellFee;
    }

    // Override getFee() function from IDynamicFeeManager
    // TODO: - this function is only called when there's a swap, what if there's no swap for multiple blocks?
    function getFee(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata) external returns (uint24 newFee) {
        // when the direction is unknown, we return the base fee
        if (tickLowerPerBlock[key.toId()][block.number-2] == 0) {
            uint24 fee = _revertDynamicFeeFlag(key.fee);
            sellDynamicFees[key.toId()][block.number] = fee;
            buyDynamicFees[key.toId()][block.number] = fee;
            return fee;
        }

        uint24 newBuyFee = _getFeeBuy(key);
        uint24 newSellFee = _getFeeSell(key);

        if (params.zeroForOne) {
            return newSellFee;
        } else {
            return newBuyFee;
        }
    }

    function _isPriceIncreasing(PoolKey calldata key) private view returns (bool isIncreasing) {
        return (tickLowerPerBlock[key.toId()][block.number-1] > tickLowerPerBlock[key.toId()][block.number-2]);
    }

    function _getFeeDelta(PoolKey calldata key) private view returns (uint24 feeDelta) {
        // Calculate fee delta with the formula => fee_delta = ((fee_buy + fee_sell) / 2)*0.10
        uint24 prevBuyFee = buyDynamicFees[key.toId()][block.number-1];
        uint24 prevSellFee = sellDynamicFees[key.toId()][block.number-1];
        return tenPercent((prevBuyFee + prevSellFee) / 2);
    }

    function afterSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata) external override poolManagerOnly returns (bytes4 selector) {
        (, int24 currentTickLower, , , ,) = poolManager.getSlot0(key.toId());
        _setTickLower(key.toId(), uint24(currentTickLower));

        return BaseHook.afterSwap.selector;
    }

    function afterModifyPosition(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyPositionParams calldata params,
        BalanceDelta,
        bytes calldata
    ) external virtual returns (bytes4) {
        // TODO: add other flags to make sure this modify is moving the rewards to the lending protocol
        // negative delta means withdrawing liquidity
        if (BalanceDelta < 0) {
            if (lendingProtocol == "compound") {
                _depositToCompound(key, params);
            } else if (lendingProtocol == "aave") {
                _depositToAave(key, params);
            }
        }
    }

    function setLendingProtocolChoice(string _lendingProtocol) external {
        lendingProtocol = _lendingProtocol;
    }

    function _depositToCompound(
        PoolKey calldata key,
        IPoolManager.ModifyPositionParams calldata params,
        uint256 amount
    ) private {
        address asset0 = Currency.unwrap(key.currency0);
        ERC20(asset0).approve(cometAddress, BalanceDelta);
        Comet(cometAddress).supply(asset0, BalanceDelta);

        address asset1 = Currency.unwrap(key.currency1);
        ERC20(asset1).approve(cometAddress, BalanceDelta);
        Comet(cometAddress).supply(asset1, BalanceDelta);
    }

    function _depositToAAVE(
        PoolKey calldata key,
        IPoolManager.ModifyPositionParams calldata params,
        uint256 amount
    ) private {
        address asset0 = Currency.unwrap(key.currency0);
        ERC20(asset0).approve(aaveAddress, BalanceDelta);
        LendingPool(cometAddress).deposit(asset0, BalanceDelta);

        address asset1 = Currency.unwrap(key.currency1);
        ERC20(asset1).approve(cometAddress, BalanceDelta);
        LendingPool(cometAddress).deposit(asset1, BalanceDelta);
    }

    function tenPercent(uint24 fee) private pure returns (uint24 newFee) {
        return fee * 10 / 100;
    }

    function _setTickLower(PoolId poolId, uint24 tickLower) internal {
        tickLowerPerBlock[poolId][block.number] = tickLower;
    }

    function _revertDynamicFeeFlag(uint24 fee) private pure returns (uint24 newFee) {
        return fee & ~FeeLibrary.DYNAMIC_FEE_FLAG;
    }

    function getTickLower(PoolId poolId, uint256 blockNumber) external view returns (uint24 tickLower) {
        return tickLowerPerBlock[poolId][blockNumber];
    }

    function getBuyDynamicFee(PoolId poolId, uint256 blockNumber) external view returns (uint24 buyDynamicFee) {
        return buyDynamicFees[poolId][blockNumber];
    }

    function getSellDynamicFee(PoolId poolId, uint256 blockNumber) external view returns (uint24 sellDynamicFee) {
        return sellDynamicFees[poolId][blockNumber];
    }
}
