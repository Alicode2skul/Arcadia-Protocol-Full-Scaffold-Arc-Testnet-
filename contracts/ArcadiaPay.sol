// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

/// @title ArcadiaPay - Invoice payments with fee routing, timelock-admin & pausability
/// @notice Admin is role-based (DEFAULT_ADMIN_ROLE) so you can set a TimelockController as admin
contract ArcadiaPay is AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    struct Invoice {
        address issuer;
        address payer;
        IERC20 token; // token used for invoice (e.g., USDC)
        uint256 amount; // gross amount expected
        uint256 netAmount; // amount available to release after fee is forwarded
        string metadataURI; // IPFS/Arweave pointer
        bool paid;
        bool released;
        uint256 createdAt;
    }

    uint256 public nextInvoiceId;
    mapping(uint256 => Invoice) public invoices;

    // fee basis points (parts per 10,000) forwarded to feeVault on payment
    uint16 public feeBps;
    address public feeVault;

    event InvoiceCreated(
        uint256 indexed id,
        address indexed issuer,
        address indexed payer,
        uint256 amount,
        address token,
        string metadataURI
    );
    event InvoicePaid(uint256 indexed id, address indexed payer, uint256 amount, uint256 fee);
    event InvoiceReleased(uint256 indexed id, address to, uint256 amount);
    event InvoiceRefunded(uint256 indexed id, address to, uint256 amount);
    event FeeBpsUpdated(uint16 newFeeBps);
    event FeeVaultUpdated(address newVault);

    modifier validInvoice(uint256 id) {
        require(id > 0 && id < nextInvoiceId, "invalid invoice id");
        _;
    }

    /// @param initialAdmin address that will receive DEFAULT_ADMIN_ROLE and PAUSER_ROLE (set to timelock or multisig)
    constructor(address initialAdmin, address _feeVault, uint16 _feeBps) {
        require(initialAdmin != address(0), "admin=0");
        require(_feeVault != address(0), "feeVault=0");
        require(_feeBps <= 2000, "feeBps>20%");

        _setupRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _setupRole(PAUSER_ROLE, initialAdmin);

        nextInvoiceId = 1;
        feeVault = _feeVault;
        feeBps = _feeBps;
    }

    function setFeeBps(uint16 _feeBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_feeBps <= 2000, "fee too high");
        feeBps = _feeBps;
        emit FeeBpsUpdated(_feeBps);
    }

    function setFeeVault(address _feeVault) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_feeVault != address(0), "zero addr");
        feeVault = _feeVault;
        emit FeeVaultUpdated(_feeVault);
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /// @notice Create an invoice. Issuer calls this.
    function createInvoice(
        address payer,
        IERC20 token,
        uint256 amount,
        string calldata metadataURI
    ) external whenNotPaused returns (uint256) {
        require(amount > 0, "amount>0");
        require(payer != address(0), "payer=0");
        require(address(token) != address(0), "token=0");

        uint256 id = nextInvoiceId++;
        invoices[id] = Invoice({
            issuer: msg.sender,
            payer: payer,
            token: token,
            amount: amount,
            netAmount: 0,
            metadataURI: metadataURI,
            paid: false,
            released: false,
            createdAt: block.timestamp
        });

        emit InvoiceCreated(id, msg.sender, payer, amount, address(token), metadataURI);
        return id;
    }

    /// @notice Pay an invoice. Payer must approve this contract for token transfer.
    /// Fee (feeBps) is forwarded to feeVault immediately; remaining netAmount is stored for release.
    function payInvoice(uint256 id) external nonReentrant whenNotPaused validInvoice(id) {
        Invoice storage inv = invoices[id];
        require(!inv.paid, "already paid");
        require(msg.sender == inv.payer, "only payer");
        require(inv.amount > 0, "invalid amount");

        uint256 gross = inv.amount;
        // transfer full gross amount from payer to contract
        inv.token.safeTransferFrom(msg.sender, address(this), gross);

        uint256 fee = (gross * feeBps) / 10000;
        uint256 net = gross - fee;

        if (fee > 0) {
            require(feeVault != address(0), "no fee vault");
            inv.token.safeTransfer(feeVault, fee);
        }

        inv.paid = true;
        inv.netAmount = net;

        emit InvoicePaid(id, msg.sender, gross, fee);
    }

    /// @notice Release net funds (after fee) to a recipient. Callable by issuer.
    function releaseFunds(uint256 id, address to) external nonReentrant whenNotPaused validInvoice(id) {
        Invoice storage inv = invoices[id];
        require(inv.paid, "not paid");
        require(!inv.released, "already released");
        require(msg.sender == inv.issuer, "only issuer");
        require(inv.netAmount > 0, "no funds");

        inv.released = true;
        uint256 amount = inv.netAmount;
        inv.netAmount = 0;

        inv.token.safeTransfer(to, amount);
        emit InvoiceReleased(id, to, amount);
    }

    /// @notice Refund net funds to a recipient (caller must be DEFAULT_ADMIN_ROLE or issuer).
    /// Fee is already forwarded at pay time.
    function refund(uint256 id, address to) external nonReentrant whenNotPaused validInvoice(id) {
        Invoice storage inv = invoices[id];
        require(inv.paid, "not paid");
        require(!inv.released, "already released");
        require(msg.sender == inv.issuer || hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "only issuer/admin");
        require(inv.netAmount > 0, "no funds");

        inv.released = true;
        uint256 amount = inv.netAmount;
        inv.netAmount = 0;

        inv.token.safeTransfer(to, amount);
        emit InvoiceRefunded(id, to, amount);
    }

    /// @notice View helper to fetch invoice struct
    function getInvoice(uint256 id) external view validInvoice(id) returns (Invoice memory) {
        return invoices[id];
    }
}
