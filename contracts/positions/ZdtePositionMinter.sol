//SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

// Contracts
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Counters} from "@openzeppelin/contracts/utils/Counters.sol";

contract ZdtePositionMinter is ReentrancyGuard, ERC721("OP-ZdtePosition", "OPSP"), ERC721Enumerable, Ownable {
    using Counters for Counters.Counter;

    /// @dev Token ID counter for straddle positions
    Counters.Counter private _tokenIdCounter;

    address public zdteContract;

    constructor() {
        zdteContract = msg.sender;
    }

    function setZdteContract(address _zdteContract) public onlyOwner {
        zdteContract = _zdteContract;
    }

    function mint(address to) public returns (uint256 tokenId) {
        require(msg.sender == zdteContract, "Only option zdte contract can mint an zdte position token");
        tokenId = _tokenIdCounter.current();
        _tokenIdCounter.increment();
        _safeMint(to, tokenId);
        return tokenId;
    }

    function burn(uint256 id) public {
        require(msg.sender == zdteContract, "Only option zdte contract can burn an zdte position token");
        _burn(id);
    }


    // The following functions are overrides required by Solidity.
    function _beforeTokenTransfer(address from, address to, uint256 tokenId, uint256 batchSize)
        internal
        override(ERC721, ERC721Enumerable)
    {
        super._beforeTokenTransfer(from, to, tokenId, batchSize);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, ERC721Enumerable) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
