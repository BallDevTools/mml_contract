// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract FakeUSDT is ERC20, Ownable {
    uint8 private constant _DECIMALS = 6;
    
    constructor() ERC20("Fake USDT", "USDT") Ownable(msg.sender) {
        _mint(msg.sender, 1000000 * 10**_DECIMALS);
    }
    
    function decimals() public pure override returns (uint8) {
        return _DECIMALS;
    }
    
    function mint(address to, uint256 amount) public onlyOwner {
        _mint(to, amount);
    }
    
    function burn(uint256 amount) public {
        _burn(msg.sender, amount);
    }
    
    function burnFrom(address account, uint256 amount) public {
        _spendAllowance(account, msg.sender, amount);
        _burn(account, amount);
    }
    
    function faucet(address to, uint256 amount) public {
        require(amount <= 10000 * 10**_DECIMALS, "Too much requested");
        _mint(to, amount);
    }
}