#!/bin/bash
privateKey=$1

forge create --rpc-url https://sepolia-rpc.scroll.io/ --private-key $privateKey src/DynamicFeeHook.sol:DynamicFeeHook --constructor-args 0x6B18E29A6c6931af9f8087dbe12e21E495855adA --legacy
