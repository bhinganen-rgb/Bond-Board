// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title BondBoard - peer-issued fixed-rate bonds on BOT Chain
contract BondBoard is Ownable, ReentrancyGuard, Pausable {
    enum Status { Open, Funded, Active, Repaid, Defaulted, Cancelled }

    struct Bond {
        address issuer;
        uint256 principal;
        uint256 repayAmount;
        uint256 collateral;
        uint256 maturitySecs;   // duration (before draw), abs timestamp (after draw)
        uint256 fundedAmount;
        uint256 issuedAt;
        uint16 collateralBps;
        Status status;
    }

    uint256 public bondCount;
    uint16 public platformFeeBps = 50;        // 0.5%
    uint256 public defaultGraceSecs = 7 days;
    uint256 public accruedFees;

    mapping(uint256 => Bond) private bonds;
    mapping(uint256 => address[]) private funders;
    mapping(uint256 => mapping(address => uint256)) private funderShare;
    mapping(uint256 => mapping(address => bool)) private hasFunded;
    mapping(uint256 => mapping(address => bool)) private claimedRepayment;
    mapping(uint256 => mapping(address => bool)) private claimedCollateral;

    mapping(address => uint256[]) private issuerBonds;
    mapping(address => uint256[]) private funderBonds;
    mapping(address => mapping(uint256 => bool)) private funderBondSeen;

    event BondIssued(uint256 indexed bondId, address indexed issuer, uint256 principal, uint256 repayAmount, uint256 collateral, uint256 maturitySecs);
    event BondFunded(uint256 indexed bondId, address indexed funder, uint256 amount, uint256 totalFunded);
    event PrincipalDrawn(uint256 indexed bondId, address indexed issuer, uint256 amount, uint256 fee, uint256 maturity);
    event BondRepaid(uint256 indexed bondId, address indexed issuer, uint256 amount);
    event RepaymentClaimed(uint256 indexed bondId, address indexed funder, uint256 amount);
    event BondDefaulted(uint256 indexed bondId, address indexed triggeredBy);
    event CollateralClaimed(uint256 indexed bondId, address indexed funder, uint256 amount);
    event BondCancelled(uint256 indexed bondId, address indexed issuer);

    constructor() Ownable(msg.sender) {}

    // ---------- Issue ----------
    function issueBond(uint256 principal, uint256 repayAmount, uint256 maturitySecs, uint16 collateralBps)
        external payable whenNotPaused nonReentrant returns (uint256 bondId)
    {
        require(principal > 0, "principal=0");
        require(repayAmount > principal, "repay<=principal");
        require(maturitySecs >= 1 days && maturitySecs <= 365 days, "bad maturity");
        require(collateralBps >= 1000 && collateralBps <= 10000, "bad collateral");
        uint256 collateral = (principal * collateralBps) / 10000;
        require(msg.value == collateral, "wrong collateral");

        bondId = ++bondCount;
        bonds[bondId] = Bond({
            issuer: msg.sender,
            principal: principal,
            repayAmount: repayAmount,
            collateral: collateral,
            maturitySecs: maturitySecs,
            fundedAmount: 0,
            issuedAt: block.timestamp,
            collateralBps: collateralBps,
            status: Status.Open
        });
        issuerBonds[msg.sender].push(bondId);
        emit BondIssued(bondId, msg.sender, principal, repayAmount, collateral, maturitySecs);
    }

    // ---------- Fund ----------
    function fundBond(uint256 bondId) external payable whenNotPaused nonReentrant {
        Bond storage b = bonds[bondId];
        require(b.issuer != address(0), "no bond");
        require(b.status == Status.Open, "not open");
        require(msg.value > 0, "amount=0");

        uint256 remaining = b.principal - b.fundedAmount;
        require(remaining > 0, "full");
        uint256 take = msg.value > remaining ? remaining : msg.value;
        uint256 refund = msg.value - take;

        if (!hasFunded[bondId][msg.sender]) {
            hasFunded[bondId][msg.sender] = true;
            funders[bondId].push(msg.sender);
        }
        funderShare[bondId][msg.sender] += take;
        b.fundedAmount += take;

        if (!funderBondSeen[msg.sender][bondId]) {
            funderBondSeen[msg.sender][bondId] = true;
            funderBonds[msg.sender].push(bondId);
        }

        if (b.fundedAmount == b.principal) {
            b.status = Status.Funded;
        }

        if (refund > 0) {
            (bool ok, ) = msg.sender.call{value: refund}("");
            require(ok, "refund fail");
        }
        emit BondFunded(bondId, msg.sender, take, b.fundedAmount);
    }

    // ---------- Draw ----------
    function drawPrincipal(uint256 bondId) external nonReentrant whenNotPaused {
        Bond storage b = bonds[bondId];
        require(msg.sender == b.issuer, "not issuer");
        require(b.status == Status.Funded, "not funded");

        uint256 fee = (b.principal * platformFeeBps) / 10000;
        uint256 payout = b.principal - fee;
        accruedFees += fee;

        b.status = Status.Active;
        b.maturitySecs = block.timestamp + b.maturitySecs; // now absolute

        (bool ok, ) = b.issuer.call{value: payout}("");
        require(ok, "pay fail");
        emit PrincipalDrawn(bondId, b.issuer, payout, fee, b.maturitySecs);
    }

    // ---------- Repay ----------
    function repayBond(uint256 bondId) external payable nonReentrant whenNotPaused {
        Bond storage b = bonds[bondId];
        require(msg.sender == b.issuer, "not issuer");
        require(b.status == Status.Active, "not active");
        require(msg.value == b.repayAmount, "wrong amount");

        b.status = Status.Repaid;

        uint256 c = b.collateral;
        b.collateral = 0;
        (bool ok, ) = b.issuer.call{value: c}("");
        require(ok, "collateral return fail");

        emit BondRepaid(bondId, b.issuer, msg.value);
    }

    // ---------- Claim repayment ----------
    function claimRepayment(uint256 bondId) external nonReentrant {
        Bond storage b = bonds[bondId];
        require(b.status == Status.Repaid, "not repaid");
        require(!claimedRepayment[bondId][msg.sender], "claimed");
        uint256 share = funderShare[bondId][msg.sender];
        require(share > 0, "not funder");

        claimedRepayment[bondId][msg.sender] = true;
        uint256 owed = (b.repayAmount * share) / b.principal;
        (bool ok, ) = msg.sender.call{value: owed}("");
        require(ok, "pay fail");
        emit RepaymentClaimed(bondId, msg.sender, owed);
    }

    // ---------- Seize ----------
    function seizeCollateral(uint256 bondId) external nonReentrant {
        Bond storage b = bonds[bondId];
        require(b.status == Status.Active, "not active");
        require(block.timestamp > b.maturitySecs + defaultGraceSecs, "grace not over");
        b.status = Status.Defaulted;
        emit BondDefaulted(bondId, msg.sender);
    }

    function claimCollateral(uint256 bondId) external nonReentrant {
        Bond storage b = bonds[bondId];
        require(b.status == Status.Defaulted, "not defaulted");
        require(!claimedCollateral[bondId][msg.sender], "claimed");
        uint256 share = funderShare[bondId][msg.sender];
        require(share > 0, "not funder");

        claimedCollateral[bondId][msg.sender] = true;
        uint256 owed = (b.collateral * share) / b.principal;
        (bool ok, ) = msg.sender.call{value: owed}("");
        require(ok, "pay fail");
        emit CollateralClaimed(bondId, msg.sender, owed);
    }

    // ---------- Cancel ----------
    function cancelBond(uint256 bondId) external nonReentrant {
        Bond storage b = bonds[bondId];
        require(msg.sender == b.issuer, "not issuer");
        require(b.status == Status.Open, "not open");

        b.status = Status.Cancelled;

        // refund funders
        address[] memory list = funders[bondId];
        for (uint256 i = 0; i < list.length; i++) {
            address f = list[i];
            uint256 amt = funderShare[bondId][f];
            if (amt > 0) {
                funderShare[bondId][f] = 0;
                (bool ok, ) = f.call{value: amt}("");
                require(ok, "refund fail");
            }
        }
        b.fundedAmount = 0;

        uint256 c = b.collateral;
        b.collateral = 0;
        (bool ok2, ) = b.issuer.call{value: c}("");
        require(ok2, "collateral return fail");

        emit BondCancelled(bondId, msg.sender);
    }

    // ---------- Views ----------
    function getBond(uint256 bondId) external view returns (
        address issuer, uint256 principal, uint256 repayAmount, uint256 collateral,
        uint256 fundedAmount, uint256 issuedAt, uint256 maturity, uint8 status
    ) {
        Bond storage b = bonds[bondId];
        return (b.issuer, b.principal, b.repayAmount, b.collateral, b.fundedAmount, b.issuedAt, b.maturitySecs, uint8(b.status));
    }

    function getFunderShare(uint256 bondId, address funder) external view returns (uint256) {
        return funderShare[bondId][funder];
    }

    function getFunders(uint256 bondId) external view returns (address[] memory) {
        return funders[bondId];
    }

    function getIssuerHistory(address issuer) external view returns (uint256[] memory bondIds, uint256 repaidCount, uint256 defaultedCount) {
        bondIds = issuerBonds[issuer];
        for (uint256 i = 0; i < bondIds.length; i++) {
            Status s = bonds[bondIds[i]].status;
            if (s == Status.Repaid) repaidCount++;
            else if (s == Status.Defaulted) defaultedCount++;
        }
    }

    function getFunderPositions(address funder) external view returns (uint256[] memory) {
        return funderBonds[funder];
    }

    // ---------- Admin ----------
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function setPlatformFeeBps(uint16 bps) external onlyOwner {
        require(bps <= 500, "fee too high"); // max 5%
        platformFeeBps = bps;
    }

    function setDefaultGraceSecs(uint256 s) external onlyOwner {
        require(s >= 1 days && s <= 30 days, "bad grace");
        defaultGraceSecs = s;
    }

    function withdrawFees(address to) external onlyOwner nonReentrant {
        uint256 amt = accruedFees;
        accruedFees = 0;
        (bool ok, ) = to.call{value: amt}("");
        require(ok, "fee send fail");
    }

    receive() external payable {}
}
