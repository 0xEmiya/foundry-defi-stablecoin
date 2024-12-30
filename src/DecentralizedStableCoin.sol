// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/**
 * @title DecentralizedStableCoin
 * @author 0xEmiya
 * @notice This is the contract meant to be owned by DSCEngine. It is a ERC20 token that can be minted and burned by the DSCEngine smart contract.
 * Collateral:
 * - WETH
 * - WBTC
 * Minting (stability mechanism): Decentralized (Algorithmic)
 * Value (Relative stablity): Anchored (Pegged to USD)
 * Collateral Type: Crypto
 *
 */
contract DecentralizedStableCoin is ERC20Burnable, Ownable {
    constructor() ERC20("DecentralizedStableCoin", "DSC") Ownable(msg.sender) {}
}
