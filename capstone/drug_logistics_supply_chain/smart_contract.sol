// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

contract DrugSupplyChainWithQuality {

    // Roles
    enum Role { Unknown, Manufacturer, Distributor, Pharmacy, Regulator, QualityInspector, Consumer }

    // Drug lifecycle states
    enum DrugState {
        Manufactured,
        ShippedToDistributor,
        ReceivedByDistributor,
        ShippedToPharmacy,
        ReceivedByPharmacy,
        SoldToCustomer,
        Recalled
    }

    // Participant
    struct Participant {
        address addr;
        string name;
        string location;
        Role role;
        bool active;        // true for active, false for inactive
        uint256 registeredAt;
    }

    // Transfer record
    struct TransferRecord {
        address from;
        address to;
        uint256 timestamp;
        string notes;       // mention shipment ID, condition, transport info etc.
    }

    // Quality Check record
    struct QualityCheck {
        address inspector;     // inspector account address
        uint256 timestamp;     // time of quality check (block time)
        string location;       // whether lab or warehouse
        int16 temperature;     // temperature or drugs in °C, can be negative
        uint8 humidity;        // 0% to 100%
        bool passed;           // QC true for pass, false for fail
        string remarks;        // test remarks
        string documentHash;   // IPFS CID
        string ipfsGatewayURL; // optional gateway URL 
                               // url example: https://ipfs.io/ipfs/
    }

    // Drug batch
    struct Drug {
        uint256 drugId;             // unique ID
        string name;                // name of the drug
        string batchNumber;         // batch or lot number (unique)
        string documentHash;        // optional manufacturer doc CID in IPFS
        address manufacturer;       // manufacturer address
        uint256 manufactureDate;    // timestamp of manufacture
        uint256 expiryDate;         // timestamp of expiry of the medicine
        DrugState state;            // current status of the drug
        address currentOwner;       // current holder, who is in possesstion
        address[] ownershipHistory; // maintain owners in chronological order
        TransferRecord[] transfers; // details of drug transfer
        QualityCheck[] qualityHistory; // QC records (with IPFS links)
    }

    // Storage
    address public contractOwner;                 // Regulator is the administrator
    uint256 private _drugCounter;                 // incremental counter for drugId

    mapping(address => Participant) public participants;      // participant registry
    mapping(uint256 => Drug) private drugs;                   // drugId => Drug
    mapping(string => uint256) public batchToDrugId;          // batchNumber => drugId (0 = unset)
    mapping(address => bool) public isRegistered;             // quick lookup

    // Events
    event ParticipantRegistered(address indexed addr, Role role, string name);
    event ParticipantActivated(address indexed addr);
    event DrugManufactured(uint256 indexed drugId, string batchNumber, address indexed manufacturer);
    event DrugStateChanged(uint256 indexed drugId, DrugState newState);
    event DrugTransferred(uint256 indexed drugId, address indexed from, address indexed to, string notes);
    event DrugRecalled(uint256 indexed drugId, string notes);
    event QualityCheckAdded(uint256 indexed drugId, address indexed inspector, string documentHash, string ipfsGatewayURL);

    // Modifiers
    modifier onlyContractOwner() {
        require(msg.sender == contractOwner, "Only contract owner");
        _;
    }

    modifier onlyRegisteredActive() {
        require(isRegistered[msg.sender], "Not registered");
        require(participants[msg.sender].active, "Participant not active");
        _;
    }

    modifier onlyRole(Role required) {
        require(isRegistered[msg.sender], "Not registered");
        require(participants[msg.sender].role == required, "Incorrect role");
        require(participants[msg.sender].active, "Participant not active");
        _;
    }

    modifier drugExists(uint256 drugId) {
        require(drugId > 0 && drugId <= _drugCounter, "Drug does not exist");
        _;
    }

    modifier batchUnique(string memory batchNumber) {
        require(batchToDrugId[batchNumber] == 0, "Batch number already exists");
        _;
    }

    // Constructor
    constructor() {
        contractOwner = msg.sender;
        _drugCounter = 0;
        // Register owner as Regulator by default
        participants[contractOwner] = Participant(contractOwner, "Admin", "OnChain", Role.Regulator, true, block.timestamp);
        isRegistered[contractOwner] = true;
        emit ParticipantRegistered(contractOwner, Role.Regulator, "Admin");
        emit ParticipantActivated(contractOwner);
    }

    // Participant management

    /// @notice Register a participant (only contract owner / admin)
    /// @param addr address of participant
    /// @param name human-readable name
    /// @param location physical address / location string
    /// @param roleNum numeric role value per Role enum (1..6)
    function registerParticipant(address addr, string calldata name, string calldata location, uint8 roleNum)
        external onlyContractOwner
    {
        require(addr != address(0), "Invalid address");
        require(!isRegistered[addr], "Already registered");
        Role role = Role(roleNum);
        require(role != Role.Unknown, "Invalid role");

        participants[addr] = Participant({
            addr: addr,
            name: name,
            location: location,
            role: role,
            active: false,               // owner must activate after off-chain KYC. Meaning offline KYC.
            registeredAt: block.timestamp
        });

        isRegistered[addr] = true;
        emit ParticipantRegistered(addr, role, name);
    }

    /// @notice Activate a registered participant after verification (only owner)
    function activateParticipant(address addr) external onlyContractOwner {
        require(isRegistered[addr], "Not registered");
        participants[addr].active = true;
        emit ParticipantActivated(addr);
    }

    /// @notice Deactivate a participant (only owner)
    function deactivateParticipant(address addr) external onlyContractOwner {
        require(isRegistered[addr], "Not registered");
        participants[addr].active = false;
    }

    /// @notice Update participant metadata (callable by the participant)
    function updateParticipantInfo(string calldata name, string calldata location) external {
        require(isRegistered[msg.sender], "Not registered");
        Participant storage p = participants[msg.sender];
        p.name = name;
        p.location = location;
    }

    // Drug lifecycle & logistics

    /// @notice Manufacturer creates a new drug batch (registers it on-chain)
    /// @param name drug name
    /// @param batchNumber unique batch/lot number
    /// @param documentHash optional: CID of manufacturer certificate or spec (IPFS CID)
    /// @param expiryDate UNIX timestamp of expiry
    function manufactureDrug(
        string calldata name,
        string calldata batchNumber,
        string calldata documentHash,
        uint256 expiryDate
    )
        external onlyRole(Role.Manufacturer)
        batchUnique(batchNumber)
    {
        require(expiryDate > block.timestamp, "Expiry must be in future");

        _drugCounter += 1;
        uint256 newId = _drugCounter;

        // create dynamic arrays
        address[] memory ownersInitial;
        ownersInitial[0] = msg.sender;

        Drug storage d = drugs[newId];
        d.drugId = newId;
        d.name = name;
        d.batchNumber = batchNumber;
        d.documentHash = documentHash;
        d.manufacturer = msg.sender;
        d.manufactureDate = block.timestamp;
        d.expiryDate = expiryDate;
        d.state = DrugState.Manufactured;
        d.currentOwner = msg.sender;
        d.ownershipHistory = ownersInitial;

        batchToDrugId[batchNumber] = newId;

        emit DrugManufactured(newId, batchNumber, msg.sender);
    }

    /// @notice Transfer a drug batch from current owner to another participant
    /// @param drugId internal drug id
    /// @param to address of recipient (must be registered & active)
    /// @param notes optional transfer notes
    function transferDrug(uint256 drugId, address to, string calldata notes)
        external drugExists(drugId)
    {
        Drug storage d = drugs[drugId];
        require(d.currentOwner == msg.sender, "Only current owner can transfer");
        require(isRegistered[to] && participants[to].active, "Recipient not active registered participant");
        require(to != address(0), "Cannot transfer to zero address");

        // record transfer
        d.transfers.push(TransferRecord({
            from: msg.sender,
            to: to,
            timestamp: block.timestamp,
            notes: notes
        }));

        // update ownership
        d.ownershipHistory.push(to);
        address prev = d.currentOwner;
        d.currentOwner = to;

        emit DrugTransferred(drugId, prev, to, notes);
    }

    /// @notice Update the state of a drug (for supply-chain stage tracking)
    /// @param drugId internal drug id
    /// @param newState new state enum value
    function updateDrugState(uint256 drugId, DrugState newState)
        external drugExists(drugId)
    {
        Drug storage d = drugs[drugId];
        // Only current owner or contract owner (admin/regulator) can update state
        require(msg.sender == d.currentOwner || msg.sender == contractOwner, "Not authorized to change state");

        d.state = newState;
        emit DrugStateChanged(drugId, newState);
    }

    /// @notice Mark a batch as recalled (only contract owner / regulator)
    function recallDrug(uint256 drugId, string calldata notes) external onlyContractOwner drugExists(drugId) {
        Drug storage d = drugs[drugId];
        d.state = DrugState.Recalled;
        // Append a transfer-like record with same from/to to show recall event context
        d.transfers.push(TransferRecord({
            from: d.currentOwner,
            to: d.currentOwner,
            timestamp: block.timestamp,
            notes: notes
        }));
        emit DrugRecalled(drugId, notes);
        emit DrugStateChanged(drugId, DrugState.Recalled);
    }

    // Quality checks (IPFS linked)

    /// @notice Add a quality check record for a drug (only QualityInspector or Regulator)
    /// @param drugId internal drug id
    /// @param location inspection location (lab, warehouse)
    /// @param temperature °C (int16)
    /// @param humidity % (uint8)
    /// @param passed pass/fail boolean
    /// @param remarks textual notes
    /// @param documentHash IPFS CID 
    /// @param ipfsGatewayURL optional gateway link string. For example: https://ipfs.io/ipfs/
    function addQualityCheck(
        uint256 drugId,
        string calldata location,
        int16 temperature,
        uint8 humidity,
        bool passed,
        string calldata remarks,
        string calldata documentHash,
        string calldata ipfsGatewayURL
    )
        external drugExists(drugId)
    {
        require(isRegistered[msg.sender], "Inspector not registered");
        require(participants[msg.sender].active, "Inspector not active");
        //Role r = participants[msg.sender].role;
        require(participants[msg.sender].role == Role.QualityInspector || participants[msg.sender].role == Role.Regulator, "Only inspector or regulator can add QC");
        require(bytes(documentHash).length > 0, "documentHash (IPFS CID) required");

        Drug storage d = drugs[drugId];

        d.qualityHistory.push(QualityCheck({
            inspector: msg.sender,
            timestamp: block.timestamp,
            location: location,
            temperature: temperature,
            humidity: humidity,
            passed: passed,
            remarks: remarks,
            documentHash: documentHash,
            ipfsGatewayURL: ipfsGatewayURL
        }));

        emit QualityCheckAdded(drugId, msg.sender, documentHash, ipfsGatewayURL);
    }

    // Queries & convenience getters

    /// @notice Verify a batch by batchNumber
    /// @param batchNumber unique batch number
    /// @return exists true if registered
    /// @return drugId internal id;If not found then, return 0
    function verifyByBatch(string calldata batchNumber) external view returns (bool exists, uint256 drugId) {
        uint256 id = batchToDrugId[batchNumber];
        if (id == 0) return (false, 0);
        return (true, id);
    }

    /// @notice Get basic details of a drug
    function getDrugBasic(uint256 drugId) external view drugExists(drugId)
        returns (
            uint256 id,
            string memory name,
            string memory batchNumber,
            string memory documentHash,
            address manufacturer,
            uint256 manufactureDate,
            uint256 expiryDate,
            DrugState state,
            address currentOwner
        )
    {
        Drug storage d = drugs[drugId];
        return (
            d.drugId,
            d.name,
            d.batchNumber,
            d.documentHash,
            d.manufacturer,
            d.manufactureDate,
            d.expiryDate,
            d.state,
            d.currentOwner
        );
    }

    /// @notice Get ownership history (addresses) for a drug
    function getOwnershipHistory(uint256 drugId) external view drugExists(drugId) returns (address[] memory) {
        return drugs[drugId].ownershipHistory;
    }

    /// @notice Number of transfers recorded for a drug
    function getTransfersCount(uint256 drugId) external view drugExists(drugId) returns (uint256) {
        return drugs[drugId].transfers.length;
    }

    /// @notice Get a single transfer record by index
    function getTransferByIndex(uint256 drugId, uint256 index) external view drugExists(drugId)
        returns (address from, address to, uint256 timestamp, string memory notes)
    {
        TransferRecord storage t = drugs[drugId].transfers[index];
        return (t.from, t.to, t.timestamp, t.notes);
    }

    /// @notice Number of QC records for a drug
    function getQualityChecksCount(uint256 drugId) external view drugExists(drugId) returns (uint256) {
        return drugs[drugId].qualityHistory.length;
    }

    /// @notice Get a single QC record by index (safer than returning array)
    function getQualityCheckByIndex(uint256 drugId, uint256 index) external view drugExists(drugId)
        returns (
            address inspector,
            uint256 timestamp,
            string memory location,
            int16 temperature,
            uint8 humidity,
            bool passed,
            string memory remarks,
            string memory documentHash,
            string memory ipfsGatewayURL
        )
    {
        QualityCheck storage q = drugs[drugId].qualityHistory[index];
        return (
            q.inspector,
            q.timestamp,
            q.location,
            q.temperature,
            q.humidity,
            q.passed,
            q.remarks,
            q.documentHash,
            q.ipfsGatewayURL
        );
    }

    /// @notice Return participant details for an address
    function getParticipant(address addr) external view returns (Participant memory) {
        require(isRegistered[addr], "Not registered");
        return participants[addr];
    }

    /// @notice Total registered drug batches
    function totalDrugs() external view returns (uint256) {
        return _drugCounter;
    }

}
