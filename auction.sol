// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../interfaces/IERC721.sol";
import "../interfaces/IERC721Receiver.sol";
import "../libraries/Counters.sol";
import "../libraries/SafeMath.sol";
import "../utils/ReentrancyGuard.sol";
import "../utils/Ownable.sol";
import "../ISecondaryMarketFee.sol";

interface MintNft721{
    struct Fee {
    address recipient;
    uint256 value;
    }

    function mint(
        uint256 tokenId,
        address to,
        uint8 v,
        bytes32 r,
        bytes32 s,
        Fee[] memory _fees,
        string memory uri,
        uint256 customNonce

    )
    external;

    } 

    interface MintNft721Collection{
    struct Fee {
    address recipient; 
    uint256 value;
    }

    function owner() external returns(address);
    function isDeputyOwner(address user) external returns(bool);

    function mint(
        uint256 tokenId,
        address to,
        Fee[] memory _fees,
        string memory uri
    ) external;


    } 

// contract to list NFTs for Auction
contract NFTAuction is IERC721Receiver, ReentrancyGuard, Ownable {
    mapping(address => mapping(uint256 => bool)) public isNonceUsed;
    using Counters for Counters.Counter;
    using SafeMath for uint256;
    Counters.Counter public _auctionIds; // count of auctions listed
    Counters.Counter private _auctionsSold; // cound of auction sold
    Counters.Counter private _auctionsInactive;
    uint256 treasuryRoyalty = 2;
    address payable treasury; // treaasury to transfer listing price
    address public MintContract721;

    enum BidType {
        OnChain,
        OffChain
    }

    struct Signature {
        bytes32 r;
        bytes32 s;
        uint8 v;
    }

    struct Mint{
        uint256 tokenId;
        address to;
        uint8 v;
        bytes32 r;
        bytes32 s;
        MintNft721.Fee[] _fees;
        string uri;
        uint256 customNonce;

    }

    struct Mint721Collection{
        uint256 tokenId;
        address to;
        MintNft721Collection.Fee[] _fees;
        string uri;
        address contractAddress;

    }

    constructor(address _treasury, address contractAddress721) {
        treasury = payable(_treasury);
        MintContract721 = contractAddress721;
    }

    // structure to show details of auction
    struct Auction {
        uint256 auctionId;
        address nftContract;
        uint256 tokenId;
        uint256 amount;
        uint256 duration;
        uint256 reservePrice;
        address payable seller;
        address payable bidder;
        BidType bidType;
        bool isActive;
        bool sold;
        uint256 startTime;
    
    }
    // mapping to fetch auction details using auction id
    mapping(uint256 => Auction) public idToAuction;

    event AuctionCreated(
        uint256 indexed auctionId,
        address nftContract,
        uint256 indexed tokenId,
        address seller,
        uint256 duration,
        uint256 startTime,
        bool isActive,
        uint256 reservePrice,
        bool sold
    );

    event BidPlaced(uint256 indexed auctionId, address bidder, uint256 amount);
    event AuctionEnded(uint256 indexed auctionId);
    event AuctionCancelled(uint256 indexed auctionId);
    event NftClaimed(uint256 indexed auctionId);
    event SetTreasury(address _treasury);
    event SetTreasuryRoyalty(uint256 royalty);

    // function to return minimum reserve price or minimum bid for a auction
    function getReservePrice(uint256 auctionId) public view returns (uint256) {
        require(auctionId <= _auctionIds.current(), " Enter a valid Id");
        return idToAuction[auctionId].reservePrice;
    }

    function setTreasury(address _treasury) external onlyOwner {
        treasury = payable(_treasury);
        emit SetTreasury(_treasury);
    }

    function onERC721Received(
        address,
        uint256,
        bytes memory
    ) public virtual override returns (bytes4) {
        return this.onERC721Received.selector;
    }



    /* Places an auction for sale on the marketplace */
    function createAuction(
        address nftContract,
        uint256 tokenId,
        uint256 price,
        uint256 startIn,
        uint256 duration
        
    ) external nonReentrant {
        require(nftContract != address(0), "zero address cannot be an input");
        require(price > 0, "Price must be at least 1 wei");
        _auctionIds.increment();
        uint256 auctionId = _auctionIds.current();

        uint256 startTime = block.timestamp + startIn;

        idToAuction[auctionId] = Auction({
            auctionId: auctionId,
            nftContract: nftContract,
            tokenId: tokenId,
            amount: 0,
            duration: duration,
            reservePrice: price,
            seller: payable(msg.sender),
            bidder: payable(address(0)),
            bidType: BidType.OnChain,
            isActive: true,
            sold: false,
            startTime: startTime
        });

        emit AuctionCreated(
            auctionId,
            nftContract,
            tokenId,
            msg.sender,
            duration,
            startTime,
            true,
            price,
            false
        );
    }



    function _validAuction(uint256 _auctionId) internal view {
        require(_auctionId <= _auctionIds.current(), " Enter a valid Id");
    }

    function _onGoingAuction(uint256 _auctionId) internal view {
        require(
            block.timestamp <
                (idToAuction[_auctionId].startTime) +
                    (idToAuction[_auctionId].duration),
            "Duartion Exceeded"
        );
        require(
            idToAuction[_auctionId].startTime <= block.timestamp,
            "Auction has not begun"
        );
        require(idToAuction[_auctionId].isActive == true, "Auction ended");
    }

    function _sellerCannotBid(uint256 _auctionId) internal view {
        require(
            msg.sender != idToAuction[_auctionId].seller,
            "seller cannot place bid"
        );
    }

    function getMessageForOffChainBid(
        uint256 _auctionId,
        address _bidder,
        uint256 customNonce
    ) public view returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    getChainID(),
                    address(this),
                    _auctionId,
                    _bidder,
                    customNonce
                )
            );
    }

    function getSigner(bytes32 _message, Signature memory _sig)
        public
        pure
        returns (address)
    {
        bytes memory prefix = "\x19Ethereum Signed Message:\n32";
        return
            ecrecover(
                keccak256(abi.encodePacked(prefix, _message)),
                _sig.v,
                _sig.r,
                _sig.s
            );
    }

    // function to place bid
    function placeBid(uint256 _auctionId) public payable nonReentrant {
        Auction storage auction = idToAuction[_auctionId];
        _validAuction(_auctionId);
        _onGoingAuction(_auctionId);
        _sellerCannotBid(_auctionId);

        if (auction.amount == 0) {
            require(msg.value >= auction.reservePrice, "Place a higher bid");
        } else {
            require(msg.value > auction.amount, "Place a higher bid");
            if (auction.bidType == BidType.OnChain) {
                transferFundsToLastBidder(_auctionId);
            }
        }

        auction.bidType = BidType.OnChain;
        auction.bidder = payable(msg.sender);
        auction.amount = msg.value;
        emit BidPlaced(_auctionId, msg.sender, msg.value);
    }

    function placeBidOffChain(
        uint256 _auctionId,
        Signature calldata _adminSig,
        address _buyer,
        uint256 customNonce
    ) external nonReentrant {
        Auction storage auction = idToAuction[_auctionId];
        _validAuction(_auctionId);
        _onGoingAuction(_auctionId);
        _sellerCannotBid(_auctionId);

        // if buyer is zero address, the asset is transferred to the caller
        if (_buyer == address(0)) _buyer = msg.sender;

        bytes32 message = getMessageForOffChainBid(
            _auctionId,
            _buyer,
            customNonce
        );
        require(
            getSigner(message, _adminSig) == owner(),
            "Admin must sign off-chain bid"
        );
        require(!isNonceUsed[owner()][customNonce], "Nonce is already used");
        isNonceUsed[owner()][customNonce] = true;

        if (auction.bidType == BidType.OnChain) {
            transferFundsToLastBidder(_auctionId);
        }

        auction.bidType = BidType.OffChain;
        auction.bidder = payable(_buyer);
        emit BidPlaced(_auctionId, _buyer, 0);
    }

    //function to end auction
        function endAuction(uint256 _auctionId, uint256 typeOfMint, // 0 means minted, 1 means custom nft and 2 means custom nft collection 
        Mint memory _mint,
        Mint721Collection memory _mintCollection) public {
        require(_auctionId <= _auctionIds.current(), " Enter a valid Id");
        Auction storage auction = idToAuction[_auctionId];
        require(
            msg.sender == auction.seller ||
                msg.sender == address(this) ||
                msg.sender == auction.bidder,
            "Caller has no rights"
        );
        require(auction.startTime <= block.timestamp, "Auction has not begun");
        require(
            (auction.startTime).add(auction.duration) <= block.timestamp,
            "Auction is still live"
        );
        require(auction.isActive = true, "Auction is not active");
        auction.isActive = false;
        
        if (auction.amount == 0 && auction.bidType == BidType.OnChain) {
            auction.sold = false;
        } else {
            auction.sold = true;
            if(typeOfMint == 1){
            MintNft721(MintContract721)
            .mint(_mint.tokenId, _mint.to, _mint.v, _mint.r, _mint.s,
            _mint._fees, _mint.uri, _mint.customNonce);

             }
              else if(typeOfMint == 2){
        
            require(idToAuction[_auctionId].seller == 
            MintNft721Collection(_mintCollection.contractAddress).owner() 
            || MintNft721Collection(_mintCollection.contractAddress).
            isDeputyOwner(idToAuction[_auctionId].seller),"Only Admin can sell");
 
             MintNft721Collection(_mintCollection.contractAddress)
             .mint( _mintCollection.tokenId , _mintCollection.to, _mintCollection._fees ,_mintCollection.uri);
            
            }

        require(IERC721(auction.nftContract).ownerOf(
                auction.tokenId
            ) == auction.seller,"Seller is not the owner of token ID");
            
            IERC721(auction.nftContract).safeTransferFrom(
                auction.seller,
                auction.bidder,
                auction.tokenId
            );
            if (auction.bidType == BidType.OnChain) {
                transferFunds(_auctionId);
            }
            _auctionsSold.increment();
        }
        _auctionsInactive.increment();
        emit AuctionEnded(_auctionId);
    }


    //function to cancel auction
    function cancelAuction(uint256 _auctionId) external {
        require(_auctionId <= _auctionIds.current(), " Enter a valid Id");
        Auction storage auction = idToAuction[_auctionId];
        require(
            msg.sender == auction.seller || msg.sender == address(this),
            "Caller has no rights"
        );
        require(
            (auction.startTime).add(auction.duration) > block.timestamp,
            "Auction has already ended, you can't cancel now"
        );
        require(auction.isActive = true, "Auction is not active");
        auction.isActive = false;
        if (auction.amount != 0 && auction.bidType == BidType.OnChain) {
            transferFundsToLastBidder(_auctionId);
        }
        auction.sold = false;
    
        _auctionsInactive.increment();
        emit AuctionCancelled(_auctionId);
    }

    /* Returns all unsold market auctions */
    function fetchUnsoldAuctions() public view returns (Auction[] memory) {
        uint256 auctionCount = _auctionIds.current();
        uint256 unsoldauctionCount = _auctionIds.current() -
            _auctionsInactive.current();
        uint256 currentIndex = 0;

        Auction[] memory auctions = new Auction[](unsoldauctionCount);
        for (uint256 i = 0; i < auctionCount; i++) {
            if (idToAuction[i.add(1)].isActive == true) {
                uint256 currentId = i.add(1);
                Auction storage currentauction = idToAuction[currentId];
                auctions[currentIndex] = currentauction;
                currentIndex = currentIndex.add(1);
            }
        }
        return auctions;
    }

    //returns the blocktimestamp when auction will end and time left for auction to end

    function timeLeftForAuctionToEnd(uint256 _auctionId)
        public
        view
        returns (uint256 timeEnd, uint256 timeleft)
    {
        require(_auctionId <= _auctionIds.current(), " Enter a valid Id");
        Auction memory auction = idToAuction[_auctionId];
        if (block.timestamp > (auction.startTime.add(auction.duration))) {
            return (auction.startTime.add(auction.duration), 0);
        } else {
            uint256 _time = (auction.startTime.add(auction.duration)).sub(
                block.timestamp
            );
            return (auction.startTime.add(auction.duration), _time);
        }
    }

    // returns all thr nfts sold in the auction

    function fetchSoldAuctions() public view returns (Auction[] memory) {
        uint256 auctionCount = _auctionIds.current();
        uint256 soldauctionCount = _auctionsSold.current();
        uint256 currentIndex = 0;

        Auction[] memory auctions = new Auction[](soldauctionCount);
        for (uint256 i = 0; i < auctionCount; i++) {
            if (idToAuction[i.add(1)].sold == true) {
                uint256 currentId = i.add(1);
                Auction storage currentauction = idToAuction[currentId];
                auctions[currentIndex] = currentauction;
                currentIndex = currentIndex.add(1);
            }
        }
        return auctions;
    }

    function setTreasuryRoyalty(uint256 royalty) external onlyOwner {
        treasuryRoyalty = royalty;
        emit SetTreasuryRoyalty(royalty);
    }

    //transfers funds to seller and the minter gets royalty
    function transferFunds(uint256 _auctionId) private {
        Auction memory auction = idToAuction[_auctionId];
        address payable _seller = auction.seller;
        ISecondaryMarketFees _secondaryMktContract = ISecondaryMarketFees(
            auction.nftContract
        );
        address[] memory recipients = _secondaryMktContract.getFeeRecipients(
            auction.tokenId
        );
        uint256[] memory fees = _secondaryMktContract.getFeeBps(
            auction.tokenId
        );

        uint256 amountToadmin = ((auction.amount).mul((treasuryRoyalty))).div(
            100
        );
        uint256 remainingAmount = (auction.amount).sub(amountToadmin);
        (treasury).transfer(amountToadmin);

        uint256 totalPaidAmount = 0;
        if (recipients.length > 0) {
            for (uint256 i = 0; i < recipients.length; i++) {
                if (fees[i] != 0) {
                    uint256 amountToMinter = ((remainingAmount).mul(fees[i]))
                        .div(100)
                        .div(1000);
                    address payable minter = payable(recipients[i]);
                    totalPaidAmount += amountToMinter;
                    (minter).transfer(amountToMinter);
                }
            }

            uint256 amountToSeller = (remainingAmount).sub(totalPaidAmount);
            (_seller).transfer(amountToSeller);
        } else {
            (_seller).transfer(remainingAmount);
        }
    }

    //transfer funds to last bidder
    function transferFundsToLastBidder(uint256 auctionId) private {
        address payable _bidder = idToAuction[auctionId].bidder;
        (_bidder).transfer(idToAuction[auctionId].amount);
    }

    /* Returns  auctions that a user has created */
    function fetchMyNFTs(address user) public view returns (Auction[] memory) {
        uint256 totalauctionCount = _auctionIds.current();
        uint256 auctionCount = 0;
        uint256 currentIndex = 0;

        for (uint256 i = 0; i < totalauctionCount; i++) {
            if (idToAuction[i.add(1)].seller == user) {
                auctionCount = auctionCount.add(1);
            }
        }

        Auction[] memory auctions = new Auction[](auctionCount);
        for (uint256 i = 0; i < totalauctionCount; i++) {
            if (idToAuction[i.add(1)].seller == user) {
                uint256 currentId = i.add(1);
                Auction storage currentauction = idToAuction[currentId];
                auctions[currentIndex] = currentauction;
                currentIndex = currentIndex.add(1);
            }
        }
        return auctions;
    }

    function highestBidder(uint256 auctionId)
        external
        view
        returns (address bidder)
    {
        return (idToAuction[auctionId].bidder);
    }

    //fetch auctions for which a user is the highest bidder
    function fetchAuctionsBid(address user)
        external
        view
        returns (Auction[] memory)
    {
        uint256 totalauctionCount = _auctionIds.current();
        uint256 auctionCount = 0;
        uint256 currentIndex = 0;

        for (uint256 i = 0; i < totalauctionCount; i++) {
            if (idToAuction[i.add(1)].bidder == user) {
                auctionCount = auctionCount.add(1);
            }
        }

        Auction[] memory auctions = new Auction[](auctionCount);
        for (uint256 i = 0; i < totalauctionCount; i++) {
            if (idToAuction[i.add(1)].bidder == user) {
                uint256 currentId = i.add(1);
                Auction storage currentauction = idToAuction[currentId];
                auctions[currentIndex] = currentauction;
                currentIndex = currentIndex.add(1);
            }
        }
        return auctions;
    }

    function getChainID() public view returns (uint256) {
        uint256 id;
        assembly {
            id := chainid()
        }
        return id;
    }
}
