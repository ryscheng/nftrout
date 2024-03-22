// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {
    ITaskAcceptor, TaskAcceptor
} from "@escrin/evm/contracts/tasks/v1/acceptors/TaskAcceptor.sol";
import {TimelockedDelegatedTaskAcceptor} from
    "@escrin/evm/contracts/tasks/v1/acceptors/DelegatedTaskAcceptor.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {
    IERC165, ERC165Checker
} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";

import {IERC721A, ERC721A} from "erc721a/contracts/ERC721A.sol";
import {ERC721ABurnable} from "erc721a/contracts/extensions/ERC721ABurnable.sol";
import {ERC721AQueryable} from "erc721a/contracts/extensions/ERC721AQueryable.sol";

contract NFTrout is
    ERC721A,
    ERC721ABurnable,
    ERC721AQueryable,
    TimelockedDelegatedTaskAcceptor,
    Ownable,
    Pausable
{
    using SafeERC20 for IERC20;

    type TokenId is uint256;

    /// The token does not exist;
    error NoSuchToken(TokenId id); // 08ff8e94 CP+OlA==

    /// The trout is no longer breedable.
    event Delisted();
    event TasksAccepted();

    bytes32 private immutable claimantsRoot;
    string private urlPrefix;
    string private urlSuffix;

    IERC20 public immutable paymentToken;
    uint256 public mintFee;
    mapping(address => uint256) public earnings;
    mapping(TokenId => uint256) public studFees;

    constructor(
        address upstreamAcceptor,
        uint64 initialAcceptorTimelock,
        address paymentTokenAddr,
        uint256 numClaimants,
        bytes32 claimantsMerkleRoot,
        uint256 initialMintFee,
        string memory initialUrlPrefix,
        string memory initialUrlSuffix
    )
        ERC721A("NFTrout", "TROUT")
        TimelockedDelegatedTaskAcceptor(upstreamAcceptor, initialAcceptorTimelock)
        Ownable(msg.sender)
    {
        require(
            ERC165Checker.supportsInterface(paymentTokenAddr, type(IERC20).interfaceId),
            "bad payment token"
        );

        mintFee = initialMintFee;
        claimantsRoot = claimantsMerkleRoot;
        (urlPrefix, urlSuffix) = (initialUrlPrefix, initialUrlSuffix);

        uint256 divisor = 9;
        uint256 batches = numClaimants >> divisor;
        uint256 remainder = numClaimants - (batches << divisor);
        for (uint256 i; i < batches; i++) {
            _mintERC2309(address(this), 1 << divisor);
        }
        if (remainder > 0) {
            _mintERC2309(address(this), remainder);
        }
    }

    struct ClaimRange {
        uint256 startTokenId;
        uint256 quantity;
    }

    function claim(address claimant, ClaimRange[] calldata ranges, bytes32[] calldata proof)
        external
    {
        bytes32 leaf = keccak256(abi.encode(claimant, ranges));
        if (!MerkleProof.verifyCalldata(proof, claimantsRoot, leaf)) revert Unauthorized();
        for (uint256 i; i < ranges.length; i++) {
            for (uint256 j; i < ranges[i].quantity; j++) {
                safeTransferFrom(address(this), claimant, ranges[i].startTokenId + j);
            }
        }
    }

    function mint(uint256 quantity) external whenNotPaused {
        uint256 fee = mintFee * quantity;
        _earn(owner(), fee);
        _safeMint(msg.sender, quantity);
        paymentToken.safeTransferFrom(msg.sender, address(this), fee);
    }

    /// Breeds any two trout to produce a third trout that will be owned by the caller.
    /// This method must be called with enough value to pay for the two trouts' fees and the minting fee.
    function breed(TokenId[] calldata lefts, TokenId[] calldata rights) external whenNotPaused {
        require(lefts.length == rights.length, "mismatched lengths");
        uint256 quantity = lefts.length;

        uint256 fee = _earn(owner(), quantity * mintFee);
        for (uint256 i; i < quantity; i++) {
            (TokenId left, TokenId right) = (lefts[i], rights[i]);
            require(TokenId.unwrap(left) != TokenId.unwrap(right), "cannot self-breed");
            if (!_exists(left)) revert NoSuchToken(left);
            if (!_exists(right)) revert NoSuchToken(right);
            fee += _earn(_ownerOf(left), getBreedingFee(msg.sender, left));
            fee += _earn(_ownerOf(right), getBreedingFee(msg.sender, right));
        }

        _safeMint(msg.sender, quantity);

        paymentToken.safeTransferFrom(msg.sender, address(this), fee);
    }

    /// Makes a trout not breedable.
    function delist(TokenId tokenId) external {
        if (msg.sender != _ownerOf(tokenId)) revert Unauthorized();
        studFees[tokenId] = 0;
        emit Delisted();
    }

    function withdraw() external {
        uint256 stack = earnings[msg.sender];
        earnings[msg.sender] = 0;
        paymentToken.safeTransferFrom(address(this), msg.sender, stack);
    }

    function setUrlComponents(string calldata prefix, string calldata suffix) external onlyOwner {
        (urlPrefix, urlSuffix) = (prefix, suffix);
    }

    function setMintFee(uint256 fee) external onlyOwner {
        mintFee = fee;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// Returns a cost for the payer to breed the trout that is no larger than the list price.
    function getBreedingFee(address breeder, TokenId tokenId) public view returns (uint256) {
        if (TokenId.unwrap(tokenId) == 0 || breeder == _ownerOf(tokenId)) return 0;
        uint256 fee = studFees[tokenId];
        if (fee == 0) revert Unauthorized();
        return fee;
    }

    function tokenURI(uint256 tokenId)
        public
        view
        override(IERC721A, ERC721A)
        returns (string memory)
    {
        return string.concat(urlPrefix, Strings.toString(tokenId));
    }

    function supportsInterface(bytes4 interfaceId)
        public
        pure
        override(IERC721A, ERC721A, TaskAcceptor)
        returns (bool)
    {
        return interfaceId == type(IERC165).interfaceId
            || interfaceId == type(ITaskAcceptor).interfaceId
            || interfaceId == type(IERC721A).interfaceId;
    }

    struct Task {
        TaskKind kind;
        bytes payload;
    }

    enum TaskKind {
        Unknown,
        Mint,
        Burn,
        List
    }

    struct MintTask {
        uint256 startTokenId;
        RecipentQuantity[] outputs;
    }

    struct RecipentQuantity {
        address recipient;
        uint256 quantity;
    }

    struct BurnTask {
        TokenId[] tokens;
    }

    struct ListTask {
        StudFee[] listings;
    }

    struct StudFee {
        TokenId stud;
        uint256 oldFee;
        uint256 newFee;
    }

    function _afterTaskResultsAccepted(
        uint256[] calldata,
        bytes calldata report,
        TaskIdSelector memory
    ) internal override {
        Task[] memory tasks = abi.decode(report, (Task[]));
        for (uint256 i; i < tasks.length; i++) {
            Task memory task = tasks[i];

            if (task.kind == TaskKind.Mint) {
                MintTask memory mintTask = abi.decode(task.payload, (MintTask));
                if (mintTask.startTokenId != _nextTokenId()) continue;
                for (uint256 j; j < mintTask.outputs.length; j++) {
                    _safeMint(mintTask.outputs[j].recipient, mintTask.outputs[j].quantity);
                }
                return;
            }

            if (task.kind == TaskKind.Burn) {
                BurnTask memory burnTask = abi.decode(task.payload, (BurnTask));
                for (uint256 j; j < burnTask.tokens.length; j++) {
                    if (!_exists(burnTask.tokens[j])) continue;
                    _burn(TokenId.unwrap(burnTask.tokens[j]));
                }
                return;
            }

            if (task.kind == TaskKind.List) {
                ListTask memory listTask = abi.decode(task.payload, (ListTask));
                for (uint256 j; j < listTask.listings.length; j++) {
                    StudFee memory l = listTask.listings[j];
                    if (studFees[l.stud] != l.oldFee) continue;
                    studFees[l.stud] = l.newFee;
                }
                return;
            }
        }
        emit TasksAccepted();
    }

    function _afterTokenTransfers(address from, address, uint256 startTokenId, uint256 quantity)
        internal
        override
    {
        if (from == address(0)) return;
        for (uint256 i = startTokenId; i < quantity; i++) {
            studFees[TokenId.wrap(i)] = 0;
        }
    }

    function _earn(address payee, uint256 amount) internal returns (uint256) {
        earnings[payee] += amount;
        return amount;
    }

    function _ownerOf(TokenId id) internal view returns (address) {
        return ownerOf(TokenId.unwrap(id));
    }

    function _exists(TokenId id) internal view returns (bool) {
        return _exists(TokenId.unwrap(id));
    }

    function _startTokenId() internal pure override returns (uint256) {
        return 1;
    }
}
