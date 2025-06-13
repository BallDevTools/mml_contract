// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "./NFTMetadataLib.sol";
import "./FinanceLib.sol";
import "./MembershipLib.sol";
import "./TokenLib.sol";
import "./ContractErrors.sol";

contract CryptoMembershipNFT is ERC721Enumerable, Ownable, ReentrancyGuard {
    using TokenLib for IERC20;

    struct ContractState {
        uint256 tokenIdCounter;
        uint256 planCount;
        uint256 ownerBalance;
        uint256 feeSystemBalance;
        uint256 fundBalance;
        uint256 totalCommissionPaid;
        bool firstMemberRegistered;
        bool paused;
        uint256 emergencyWithdrawRequestTime;
    }

    ContractState private state;
    IERC20 public immutable usdtToken;
    uint8 private immutable _tokenDecimals;
    address public priceFeed;
    string private _baseTokenURI;

    uint256 public constant MAX_MEMBERS_PER_CYCLE = 4;
    uint256 public constant TIMELOCK_DURATION = 2 days;

    struct NFTImage {
        string imageURI;
        string name;
        string description;
        uint256 planId;
        uint256 createdAt;
    }

    mapping(uint256 => MembershipLib.MembershipPlan) public plans;
    mapping(address => MembershipLib.Member) public members;
    mapping(uint256 => MembershipLib.CycleInfo) public planCycles;
    mapping(uint256 => NFTImage) public tokenImages;
    mapping(uint256 => string) public planDefaultImages;
    mapping(address => address[]) private _referralChain;
    bool private _inTransaction;

    event PlanCreated(
        uint256 planId,
        string name,
        uint256 price,
        uint256 membersPerCycle
    );
    event MemberRegistered(
        address indexed member,
        address indexed upline,
        uint256 planId,
        uint256 cycleNumber
    );
    event ReferralPaid(
        address indexed from,
        address indexed to,
        uint256 amount
    );
    event PlanUpgraded(
        address indexed member,
        uint256 oldPlanId,
        uint256 newPlanId,
        uint256 cycleNumber
    );

    event PlanPriceUpdated(
        uint256 indexed planId,
        uint256 oldPrice,
        uint256 newPrice
    );
    event NewCycleStarted(uint256 planId, uint256 cycleNumber);
    event EmergencyWithdraw(address indexed to, uint256 amount);
    event ContractPaused(bool status);
    event PriceFeedUpdated(address indexed newPriceFeed);
    event MemberExited(address indexed member, uint256 refundAmount);
    event FundsDistributed(
        uint256 ownerAmount,
        uint256 feeAmount,
        uint256 fundAmount
    );
    event UplineNotified(
        address indexed upline,
        address indexed downline,
        uint256 downlineCurrentPlan,
        uint256 downlineTargetPlan
    );
    event PlanDefaultImageSet(uint256 indexed planId, string imageURI);
    event BatchWithdrawalProcessed(
        uint256 totalOwner,
        uint256 totalFee,
        uint256 totalFund
    );
    event EmergencyWithdrawRequested(uint256 timestamp);
    event TimelockUpdated(uint256 newDuration);
    event EmergencyWithdrawInitiated(uint256 timestamp, uint256 amount);
    event MetadataUpdated(uint256 indexed tokenId, string newURI);
    event TransferAttemptBlocked(
        address indexed from,
        address indexed to,
        uint256 tokenId
    );
    event MembershipMinted(address indexed to, uint256 tokenId, string message);
    event OwnerUpgradeBypass(
        address indexed owner,
        uint256 fromPlan,
        uint256 toPlan,
        uint256 timestamp
    );

    event ValidationError(
        address indexed user,
        string reason,
        uint256 timestamp
    );

    event FundBalanceUpdated(
        uint256 oldBalance,
        uint256 newBalance,
        string operation
    );

    event ContractBalanceAlert(
        uint256 expected,
        uint256 actual,
        uint256 difference
    );
    modifier whenNotPaused() {
        if (state.paused) revert ContractErrors.Paused();
        _;
    }

    modifier onlyMember() {
        if (balanceOf(msg.sender) == 0) revert ContractErrors.NotMember();
        _;
    }

    modifier noReentrantTransfer() {
        if (_inTransaction) revert ContractErrors.ReentrantTransfer();
        _inTransaction = true;
        _;
        _inTransaction = false;
    }



    modifier validAddress(address _addr) {
        if (_addr == address(0)) revert ContractErrors.ZeroAddress();
        _;
    }

    constructor(address _usdtToken, address initialOwner)
        ERC721("Chainsx", "CSX")
        Ownable(initialOwner)
    {
        usdtToken = IERC20(_usdtToken);
        _tokenDecimals = IERC20Metadata(_usdtToken).decimals();
        if (_tokenDecimals == 0) revert ContractErrors.InvalidDecimals();
        _createDefaultPlans();
        _setupDefaultImages();
        _baseTokenURI = "ipfs://";

        _createOwnerMembership(initialOwner);
    }

    function _createOwnerMembership(address ownerAddress) internal {
        uint256 highestPlanId = state.planCount; // Plan 16
        uint256 tokenId = state.tokenIdCounter++;

        _safeMintWithNotice(ownerAddress, tokenId);
        _setTokenImage(tokenId, highestPlanId);

        members[ownerAddress] = MembershipLib.Member(
            address(0),
            0,
            0,
            highestPlanId,
            1,
            block.timestamp
        );
        state.firstMemberRegistered = true;

        emit MemberRegistered(ownerAddress, address(0), highestPlanId, 1);
    }

    function _setupDefaultImages() internal {
        planDefaultImages[
            1
        ] = "bafybeignaodj5a2bmtt6ccz3mmf7dx5iseib3orllgf4ed4tdnfijnxfrq";
        planDefaultImages[
            2
        ] = "bafybeifymsrfkqzlmr2jetihb4cd7siro3vhq5s7xjjecshq3yoewxbbmy";
        planDefaultImages[
            3
        ] = "bafybeib36tixhjirirdq2hotmb6os5lgln66m4dseyhp353mqbbn5ubrzq";
        planDefaultImages[
            4
        ] = "bafybeihmyvmywvecl5x2idguejduw2bsy4kynplhnas37ji7qnir5y4k2i";
        planDefaultImages[
            5
        ] = "bafybeibkna2uzb5irusxczngkxdbijcpfed5lilsqa4yamkdzfrcbplyqy";
        planDefaultImages[
            6
        ] = "bafybeias7xs36rcrq64uswehgqfiqb5hkosjfmwya2jdmkt67fwqxybxk4";
        planDefaultImages[
            7
        ] = "bafybeihbrva37xflvzcqb3axouyd5kndshtldqooqgdcuniuahngjcxf2e";
        planDefaultImages[
            8
        ] = "bafybeiamlxlrejlvtbrwg7crgobz5wvanclef2uf7lrijw55hlhipnk4fu";
        planDefaultImages[
            9
        ] = "bafybeihsomjcfbqbb7uk27bxbgfooba7g4ggywnenleq442vr5rw3o3ygy";
        planDefaultImages[
            10
        ] = "bafybeiezl6kslyy7cmm2c5wdtpyj2awdzjuwqkp726owhx5x6llg4s2kwa";
        planDefaultImages[
            11
        ] = "bafybeigxtlrnxjm4gtkxobkg4mro5benoogrqtphqvewag6mcnqakcw7hm";
        planDefaultImages[
            12
        ] = "bafybeibi7daxnplgosboky33p3uvmhw3gg6bg5uojikdnhfaqryp6tb64y";
        planDefaultImages[
            13
        ] = "bafybeia7u3oblw32wh5e725tmxc47szss32ydbbc42pzserqky3dqt7ira";
        planDefaultImages[
            14
        ] = "bafybeicawcal7gklqjaorir7n6y3iewgzk3linc2srf4pj26pqcuypm5o4";
        planDefaultImages[
            15
        ] = "bafybeihqv3763mh2csw2vwhzluppejds6ahr7qyd7ejo5epyy5nnqmjvx4";
        planDefaultImages[
            16
        ] = "bafybeiav5pvrydstsr3ffjdscinlklhmjy3trhs6qglnilltbvxews5omm";
    }

    function _createDefaultPlans() internal {
        uint256 decimal = 10**_tokenDecimals;

        uint256[] memory prices = new uint256[](16);
        prices[0] = 1 * decimal;
        prices[1] = 2 * decimal;
        prices[2] = 3 * decimal;
        prices[3] = 4 * decimal;
        prices[4] = 5 * decimal;
        prices[5] = 6 * decimal;
        prices[6] = 7 * decimal;
        prices[7] = 8 * decimal;
        prices[8] = 9 * decimal;
        prices[9] = 10 * decimal;
        prices[10] = 11 * decimal;
        prices[11] = 12 * decimal;
        prices[12] = 13 * decimal;
        prices[13] = 14 * decimal;
        prices[14] = 15 * decimal;
        prices[15] = 16 * decimal; // Plan 16: $150,000

        uint256[] memory membersPerCycle = new uint256[](16);
        membersPerCycle[0] = 4;
        membersPerCycle[1] = 4;
        membersPerCycle[2] = 4;
        membersPerCycle[3] = 4;
        membersPerCycle[4] = 4;
        membersPerCycle[5] = 4;
        membersPerCycle[6] = 4;
        membersPerCycle[7] = 4;
        membersPerCycle[8] = 4;
        membersPerCycle[9] = 4;
        membersPerCycle[10] = 4;
        membersPerCycle[11] = 4;
        membersPerCycle[12] = 5;
        membersPerCycle[13] = 5;
        membersPerCycle[14] = 5;
        membersPerCycle[15] = 5;

        string[] memory planNames = new string[](16);
        planNames[0] = "Starter";
        planNames[1] = "Basic";
        planNames[2] = "Bronze";
        planNames[3] = "Silver";
        planNames[4] = "Gold";
        planNames[5] = "Platinum";
        planNames[6] = "Diamond";
        planNames[7] = "Elite";
        planNames[8] = "Master";
        planNames[9] = "Grand Master";
        planNames[10] = "Champion";
        planNames[11] = "Legend";
        planNames[12] = "Supreme";
        planNames[13] = "Ultimate";
        planNames[14] = "Apex";
        planNames[15] = "Infinity";

        for (uint256 i = 0; i < 16; ) {
            _createPlan(prices[i], planNames[i], membersPerCycle[i]);
            unchecked {
                ++i;
            }
        }
    }

    function _update(
        address to,
        uint256 tokenId,
        address auth
    ) internal override returns (address) {
        address from = _ownerOf(tokenId);
        if (from != address(0) && to != address(0)) {
            emit TransferAttemptBlocked(from, to, tokenId);
            revert ContractErrors.NonTransferable();
        }
        return super._update(to, tokenId, auth);
    }

    function _createPlan(
        uint256 _price,
        string memory _name,
        uint256 _membersPerCycle
    ) internal {
        state.planCount++;
        plans[state.planCount] = MembershipLib.MembershipPlan(
            _price,
            _name,
            _membersPerCycle,
            true
        );
        planCycles[state.planCount] = MembershipLib.CycleInfo(1, 0);
        emit PlanCreated(state.planCount, _name, _price, _membersPerCycle);
    }

    function updatePlanPrice(uint256 _planId, uint256 _newPrice)
        external
        onlyOwner
    {
        if (_planId == 0 || _planId > state.planCount)
            revert ContractErrors.InvalidPlanID();
        if (_newPrice == 0) revert ContractErrors.ZeroPrice();

        uint256 oldPrice = plans[_planId].price;
        plans[_planId].price = _newPrice;

        emit PlanPriceUpdated(_planId, oldPrice, _newPrice);
    }

    function setPlanDefaultImage(uint256 _planId, string calldata _imageURI)
        external
        onlyOwner
    {
        if (_planId == 0 || _planId > state.planCount)
            revert ContractErrors.InvalidPlanID();
        if (bytes(_imageURI).length == 0) revert ContractErrors.EmptyURI();
        planDefaultImages[_planId] = _imageURI;
        emit PlanDefaultImageSet(_planId, _imageURI);
    }

    function getPlanInfo(uint256 _planId)
        external
        view
        returns (
            uint256 price,
            string memory name,
            uint256 membersPerCycle,
            bool isActive,
            string memory imageURI
        )
    {
        if (_planId == 0 || _planId > state.planCount)
            revert ContractErrors.InvalidPlanID();

        MembershipLib.MembershipPlan memory plan = plans[_planId];
        return (
            plan.price,
            plan.name,
            plan.membersPerCycle,
            plan.isActive,
            planDefaultImages[_planId]
        );
    }

    function getTotalPlanCount() external view returns (uint256) {
        return state.planCount;
    }

    function getNFTImage(uint256 _tokenId)
        external
        view
        returns (
            string memory imageURI,
            string memory name,
            string memory description,
            uint256 planId,
            uint256 createdAt
        )
    {
        if (!_exists(_tokenId)) revert ContractErrors.NonexistentToken();
        NFTImage memory image = tokenImages[_tokenId];
        return (
            image.imageURI,
            image.name,
            image.description,
            image.planId,
            image.createdAt
        );
    }

    function tokenURI(uint256 _tokenId)
        public
        view
        override
        returns (string memory)
    {
        if (!_exists(_tokenId)) revert ContractErrors.NonexistentToken();
        NFTImage memory image = tokenImages[_tokenId];
        return
            string(
                abi.encodePacked(
                    "data:application/json;base64,",
                    NFTMetadataLib.base64Encode(
                        abi.encodePacked(
                            '{"name":"',
                            image.name,
                            '","description":"',
                            image.description,
                            " Non-transferable NFT.",
                            '","image":"',
                            image.imageURI,
                            '","attributes":[{"trait_type":"Plan Level","value":"',
                            NFTMetadataLib.uint2str(
                                members[ownerOf(_tokenId)].planId
                            ),
                            '"},{"trait_type":"Transferable","value":"No"}]}'
                        )
                    )
                )
            );
    }

    function isTokenTransferable() external pure returns (bool) {
        return false;
    }

    function registerMember(uint256 _planId, address _upline)
        external
        nonReentrant
        whenNotPaused
        validAddress(_upline)
    {
        bool isOwnerRegistering = msg.sender == owner();

        if (isOwnerRegistering) {
            revert ContractErrors.AlreadyMember();
        }

        if (_planId != 1 || _planId > state.planCount) {
            revert ContractErrors.Plan1Only();
        }

        if (!plans[_planId].isActive) {
            revert ContractErrors.InactivePlan();
        }

        if (balanceOf(msg.sender) > 0) {
            revert ContractErrors.AlreadyMember();
        }

        if (bytes(planDefaultImages[_planId]).length == 0) {
            revert ContractErrors.NoPlanImage();
        }

        address finalUpline;
        if (_upline == address(0) || _upline == msg.sender) {
            finalUpline = owner();
        } else {
            if (_upline == owner()) {
                finalUpline = _upline;
            } else if (balanceOf(_upline) == 0) {
                revert ContractErrors.UplineNotMember();
            } else if (members[_upline].planId < _planId) {
                revert ContractErrors.UplinePlanLow();
            } else {
                _referralChain[msg.sender] = new address[](1);
                _referralChain[msg.sender][0] = _upline;
                finalUpline = _upline;
            }
        }

        usdtToken.safeTransferFrom(
            msg.sender,
            address(this),
            plans[_planId].price
        );

        uint256 tokenId = state.tokenIdCounter++;
        _safeMintWithNotice(msg.sender, tokenId);
        _setTokenImage(tokenId, _planId);

        MembershipLib.CycleInfo storage cycleInfo = planCycles[_planId];
        cycleInfo.membersInCurrentCycle++;
        if (cycleInfo.membersInCurrentCycle >= plans[_planId].membersPerCycle) {
            cycleInfo.currentCycle++;
            cycleInfo.membersInCurrentCycle = 0;
            emit NewCycleStarted(_planId, cycleInfo.currentCycle);
        }

        members[msg.sender] = MembershipLib.Member(
            finalUpline,
            0,
            0,
            _planId,
            cycleInfo.currentCycle,
            block.timestamp
        );

        (
            uint256 ownerShare,
            uint256 feeShare,
            uint256 fundShare,
            uint256 uplineShare
        ) = FinanceLib.distributeFunds(plans[_planId].price, _planId);

        state.ownerBalance += ownerShare;
        state.feeSystemBalance += feeShare;
        state.fundBalance += fundShare;

        _handleUplinePayment(finalUpline, uplineShare);

        emit FundsDistributed(ownerShare, feeShare, fundShare);
        emit MemberRegistered(
            msg.sender,
            finalUpline,
            _planId,
            cycleInfo.currentCycle
        );
    }

    function _safeMintWithNotice(address to, uint256 tokenId) internal {
        _safeMint(to, tokenId);
        emit MembershipMinted(to, tokenId, "Non-transferable");
    }

    function _setTokenImage(uint256 tokenId, uint256 planId) private {
        string memory name = plans[planId].name;
        tokenImages[tokenId] = NFTImage(
            planDefaultImages[planId],
            name,
            string(abi.encodePacked("Crypto Membership NFT - ", name, " Plan")),
            planId,
            block.timestamp
        );
    }

    function _handleUplinePayment(address _upline, uint256 _uplineShare)
        internal
    {
        if (
            _upline == address(0) ||
            members[_upline].planId < members[msg.sender].planId
        ) {
            state.ownerBalance += _uplineShare;
            return;
        }
        _payReferralCommission(msg.sender, _upline, _uplineShare);
        members[_upline].totalReferrals++;
    }

    function _payReferralCommission(
        address _from,
        address _to,
        uint256 _amount
    ) internal noReentrantTransfer {
        usdtToken.safeTransfer(_to, _amount);
        members[_to].totalEarnings += _amount;
        state.totalCommissionPaid += _amount;
        emit ReferralPaid(_from, _to, _amount);
    }

    function upgradePlan(uint256 _newPlanId)
        external
        nonReentrant
        whenNotPaused
        onlyMember
        noReentrantTransfer
    {
        bool isOwnerUpgrading = msg.sender == owner();

        if (_newPlanId == 0 || _newPlanId > state.planCount) {
            revert ContractErrors.InvalidPlanID();
        }

        if (!plans[_newPlanId].isActive) {
            revert ContractErrors.InactivePlan();
        }

        MembershipLib.Member storage member = members[msg.sender];
        uint256 oldPlanId = member.planId;
        address upline = member.upline;

        if (!isOwnerUpgrading) {
            if (_newPlanId != member.planId + 1) {
                revert ContractErrors.NextPlanOnly();
            }
        } else {
            if (_newPlanId <= member.planId) {
                revert ContractErrors.InvalidPlanID();
            }
        }

        uint256 priceDifference = plans[_newPlanId].price - plans[oldPlanId].price;

        if (!isOwnerUpgrading) {
            // Check USDT allowance
            uint256 allowance = usdtToken.allowance(msg.sender, address(this));
            if (allowance < priceDifference) {
                emit ValidationError(msg.sender, "Insufficient USDT allowance", block.timestamp);
                revert ContractErrors.InvalidAmount();
            }

            // Check USDT balance
            uint256 balance = usdtToken.balanceOf(msg.sender);
            if (balance < priceDifference) {
                emit ValidationError(msg.sender, "Insufficient USDT balance", block.timestamp);
                revert ContractErrors.InvalidAmount();
            }

            // Check if contract has enough USDT balance
            uint256 contractBalance = usdtToken.balanceOf(address(this));
            uint256 expectedBalance = state.ownerBalance + state.feeSystemBalance + state.fundBalance;
            if (contractBalance < expectedBalance) {
                emit ContractBalanceAlert(expectedBalance, contractBalance, expectedBalance - contractBalance);
            }

            // Transfer USDT with additional checks
            uint256 balanceBefore = usdtToken.balanceOf(address(this));
            usdtToken.safeTransferFrom(msg.sender, address(this), priceDifference);
            uint256 balanceAfter = usdtToken.balanceOf(address(this));
            
            if (balanceAfter < balanceBefore + priceDifference) {
                emit ValidationError(msg.sender, "USDT transfer failed", block.timestamp);
                revert ContractErrors.InvalidAmount();
            }
        }

        _completeUpgradePlan(
            _newPlanId,
            oldPlanId,
            upline,
            priceDifference,
            isOwnerUpgrading
        );
    }

    function _completeUpgradePlan(
        uint256 _newPlanId,
        uint256 oldPlanId,
        address upline,
        uint256 priceDifference,
        bool isOwnerUpgrading
    ) private {
        MembershipLib.CycleInfo storage cycleInfo = planCycles[_newPlanId];
        cycleInfo.membersInCurrentCycle++;
        if (
            cycleInfo.membersInCurrentCycle >= plans[_newPlanId].membersPerCycle
        ) {
            cycleInfo.currentCycle++;
            cycleInfo.membersInCurrentCycle = 0;
            emit NewCycleStarted(_newPlanId, cycleInfo.currentCycle);
        }

        members[msg.sender].cycleNumber = cycleInfo.currentCycle;
        members[msg.sender].planId = _newPlanId;

        uint256 tokenId = tokenOfOwnerByIndex(msg.sender, 0);
        NFTImage storage image = tokenImages[tokenId];
        image.planId = _newPlanId;
        image.name = plans[_newPlanId].name;
        image.description = string(
            abi.encodePacked("Crypto Membership NFT - ", image.name, " Plan")
        );
        image.imageURI = planDefaultImages[_newPlanId];

        if (!isOwnerUpgrading) {
            (
                uint256 ownerShare,
                uint256 feeShare,
                uint256 fundShare,
                uint256 uplineShare
            ) = FinanceLib.distributeFunds(priceDifference, _newPlanId);

            state.ownerBalance += ownerShare;
            state.feeSystemBalance += feeShare;
            state.fundBalance += fundShare;

            if (upline != address(0) && members[upline].planId < _newPlanId) {
                emit UplineNotified(upline, msg.sender, oldPlanId, _newPlanId);
            }

            _handleUplinePayment(upline, uplineShare);
            emit FundsDistributed(ownerShare, feeShare, fundShare);
        } else {
            emit OwnerUpgradeBypass(
                msg.sender,
                oldPlanId,
                _newPlanId,
                block.timestamp
            );
        }

        emit PlanUpgraded(
            msg.sender,
            oldPlanId,
            _newPlanId,
            cycleInfo.currentCycle
        );
        emit MetadataUpdated(tokenId, tokenURI(tokenId));
    }

    function exitMembership() external nonReentrant whenNotPaused onlyMember {
    if (msg.sender == owner()) {
        revert ContractErrors.InvalidRequest();
    }
    
    MembershipLib.Member storage member = members[msg.sender];
    if (block.timestamp <= member.registeredAt + 30 days)
        revert ContractErrors.ThirtyDayLock();

    uint256 refundAmount = (plans[member.planId].price * 30) / 100;
    if (state.fundBalance < refundAmount)
        revert ContractErrors.LowFundBalance();

    state.fundBalance -= refundAmount;

    uint256 tokenId = tokenOfOwnerByIndex(msg.sender, 0);
    delete tokenImages[tokenId];
    _burn(tokenId);
    delete members[msg.sender];

    usdtToken.safeTransfer(msg.sender, refundAmount);
    emit MemberExited(msg.sender, refundAmount);
}

    function withdrawOwnerBalance(uint256 amount)
        external
        onlyOwner
        nonReentrant
        noReentrantTransfer
    {
        if (amount > state.ownerBalance)
            revert ContractErrors.LowOwnerBalance();
        state.ownerBalance -= amount;
        usdtToken.safeTransfer(owner(), amount);
    }

    function withdrawFeeSystemBalance(uint256 amount)
        external
        onlyOwner
        nonReentrant
        noReentrantTransfer
    {
        if (amount > state.feeSystemBalance)
            revert ContractErrors.LowFeeBalance();
        state.feeSystemBalance -= amount;
        usdtToken.safeTransfer(owner(), amount);
    }

    function withdrawFundBalance(uint256 amount)
        external
        onlyOwner
        nonReentrant
        noReentrantTransfer
    {
        if (amount > state.fundBalance) revert ContractErrors.LowFundBalance();
        state.fundBalance -= amount;
        usdtToken.safeTransfer(owner(), amount);
    }

    struct WithdrawalRequest {
        address recipient;
        uint256 amount;
        uint256 balanceType;
    }

    function batchWithdraw(WithdrawalRequest[] calldata requests)
        external
        onlyOwner
        nonReentrant
        noReentrantTransfer
    {
        if (requests.length == 0 || requests.length > 20)
            revert ContractErrors.InvalidRequests();

        uint256 totalOwner;
        uint256 totalFee;
        uint256 totalFund;

        for (uint256 i = 0; i < requests.length; ) {
            WithdrawalRequest calldata req = requests[i];
            if (req.recipient == address(0) || req.amount == 0)
                revert ContractErrors.InvalidRequest();

            if (req.balanceType == 0) {
                if (req.amount > state.ownerBalance)
                    revert ContractErrors.LowOwnerBalance();
                totalOwner += req.amount;
                state.ownerBalance -= req.amount;
            } else if (req.balanceType == 1) {
                if (req.amount > state.feeSystemBalance)
                    revert ContractErrors.LowFeeBalance();
                totalFee += req.amount;
                state.feeSystemBalance -= req.amount;
            } else {
                if (req.amount > state.fundBalance)
                    revert ContractErrors.LowFundBalance();
                totalFund += req.amount;
                state.fundBalance -= req.amount;
            }
            usdtToken.safeTransfer(req.recipient, req.amount);
            unchecked {
                ++i;
            }
        }
        emit BatchWithdrawalProcessed(totalOwner, totalFee, totalFund);
    }

    function getPlanCycleInfo(uint256 _planId)
        external
        view
        returns (
            uint256 currentCycle,
            uint256 membersInCurrentCycle,
            uint256 membersPerCycle
        )
    {
        if (_planId == 0 || _planId > state.planCount)
            revert ContractErrors.InvalidPlanID();

        MembershipLib.CycleInfo memory cycleInfo = planCycles[_planId];
        return (
            cycleInfo.currentCycle,
            cycleInfo.membersInCurrentCycle,
            plans[_planId].membersPerCycle
        );
    }

    function getSystemStats()
        external
        view
        returns (
            uint256 totalMembers,
            uint256 totalRevenue,
            uint256 totalCommission,
            uint256 ownerFunds,
            uint256 feeFunds,
            uint256 fundFunds
        )
    {
        return (
            totalSupply(),
            state.ownerBalance +
                state.feeSystemBalance +
                state.fundBalance +
                state.totalCommissionPaid,
            state.totalCommissionPaid,
            state.ownerBalance,
            state.feeSystemBalance,
            state.fundBalance
        );
    }

    function getContractStatus()
        external
        view
        returns (
            bool isPaused,
            uint256 totalBalance,
            uint256 memberCount,
            uint256 currentPlanCount,
            bool hasEmergencyRequest,
            uint256 emergencyTimeRemaining
        )
    {
        uint256 timeRemaining = state.emergencyWithdrawRequestTime > 0
            ? state.emergencyWithdrawRequestTime +
                TIMELOCK_DURATION -
                block.timestamp
            : 0;
        return (
            state.paused,
            usdtToken.balanceOf(address(this)),
            totalSupply(),
            state.planCount,
            state.emergencyWithdrawRequestTime > 0,
            timeRemaining
        );
    }

    function getReferralChain(address _member)
        external
        view
        returns (address[] memory)
    {
        address[] memory chain = new address[](1);
        chain[0] = members[_member].upline;
        return chain;
    }

    function updateMembersPerCycle(uint256 _planId, uint256 _newMembersPerCycle)
        external
        onlyOwner
    {
        if (_planId == 0 || _planId > state.planCount)
            revert ContractErrors.InvalidPlanID();
        if (_newMembersPerCycle == 0)
            revert ContractErrors.InvalidCycleMembers();
        plans[_planId].membersPerCycle = _newMembersPerCycle;
    }

    function setBaseURI(string calldata baseURI) external onlyOwner {
        if (bytes(baseURI).length == 0) revert ContractErrors.EmptyURI();
        _baseTokenURI = baseURI;
    }

    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }

    function setPlanStatus(uint256 _planId, bool _isActive) external onlyOwner {
        if (_planId == 0 || _planId > state.planCount)
            revert ContractErrors.InvalidPlanID();
        plans[_planId].isActive = _isActive;
    }

    function setPriceFeed(address _priceFeed) external onlyOwner {
        if (_priceFeed == address(0)) revert ContractErrors.ZeroAddress();
        priceFeed = _priceFeed;
        emit PriceFeedUpdated(_priceFeed);
    }

    function setPaused(bool _paused) external onlyOwner {
        state.paused = _paused;
        emit ContractPaused(_paused);
    }

    function requestEmergencyWithdraw() external onlyOwner {
        state.emergencyWithdrawRequestTime = block.timestamp;
        emit EmergencyWithdrawRequested(block.timestamp);
    }

    function cancelEmergencyWithdraw() external onlyOwner {
        if (state.emergencyWithdrawRequestTime == 0)
            revert ContractErrors.NoRequest();
        state.emergencyWithdrawRequestTime = 0;
        emit EmergencyWithdrawRequested(0);
    }

    function emergencyWithdraw()
        external
        onlyOwner
        nonReentrant
        noReentrantTransfer
    {
        if (state.emergencyWithdrawRequestTime == 0)
            revert ContractErrors.NoRequest();
        if (
            block.timestamp <
            state.emergencyWithdrawRequestTime + TIMELOCK_DURATION
        ) revert ContractErrors.TimelockActive();

        uint256 contractBalance = usdtToken.balanceOf(address(this));
        if (contractBalance == 0) revert ContractErrors.ZeroBalance();

        uint256 expectedBalance = state.ownerBalance +
            state.feeSystemBalance +
            state.fundBalance;

        emit EmergencyWithdrawInitiated(block.timestamp, contractBalance);

        if (expectedBalance > 0) {
            uint256 ownerShare;
            uint256 feeShare;
            uint256 fundShare;

            if (contractBalance >= expectedBalance) {
                ownerShare = state.ownerBalance;
                feeShare = state.feeSystemBalance;
                fundShare = state.fundBalance;
            } else {
                ownerShare =
                    (contractBalance * state.ownerBalance) /
                    expectedBalance;
                feeShare =
                    (contractBalance * state.feeSystemBalance) /
                    expectedBalance;

                if (ownerShare + feeShare > contractBalance) {
                    if (ownerShare > feeShare) {
                        ownerShare = contractBalance - feeShare;
                    } else {
                        feeShare = contractBalance - ownerShare;
                    }
                    fundShare = 0;
                } else {
                    fundShare = contractBalance - ownerShare - feeShare;
                }
            }

            state.ownerBalance = 0;
            state.feeSystemBalance = 0;
            state.fundBalance = 0;

            usdtToken.safeTransfer(owner(), contractBalance);

            emit EmergencyWithdraw(owner(), contractBalance);
            emit FundsDistributed(ownerShare, feeShare, fundShare);
        } else {
            state.ownerBalance = 0;
            state.feeSystemBalance = 0;
            state.fundBalance = 0;
            usdtToken.safeTransfer(owner(), contractBalance);
            emit EmergencyWithdraw(owner(), contractBalance);
        }

        state.emergencyWithdrawRequestTime = 0;
    }

    function restartAfterPause() external onlyOwner {
        if (!state.paused) revert ContractErrors.NotPaused();
        state.paused = false;
        emit ContractPaused(false);
    }

    function validateContractBalance()
        public
        view
        returns (
            bool,
            uint256,
            uint256
        )
    {
        uint256 expectedBalance = state.ownerBalance +
            state.feeSystemBalance +
            state.fundBalance;
        uint256 actualBalance = usdtToken.balanceOf(address(this));
        return (
            actualBalance >= expectedBalance,
            expectedBalance,
            actualBalance
        );
    }

    function _exists(uint256 tokenId) internal view returns (bool) {
        return _ownerOf(tokenId) != address(0);
    }
}
