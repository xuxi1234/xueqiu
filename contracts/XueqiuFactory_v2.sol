// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title XueqiuFactory v2
 * - 部署费 0.002 BNB
 * - 使用 CREATE2 + salt 挖尾号00000的合约地址
 * - 8种代币模板
 */

interface IUniswapV2Router {
    function addLiquidityETH(address,uint,uint,uint,address,uint) external payable returns(uint,uint,uint);
    function swapExactETHForTokensSupportingFeeOnTransferTokens(uint,address[] calldata,address,uint) external payable;
    function WETH() external pure returns(address);
    function factory() external pure returns(address);
}

interface IUniswapV2Factory {
    function createPair(address,address) external returns(address);
}

// ============ BASE TOKEN ============
contract XueqiuToken {
    string public name;
    string public symbol;
    uint8 public decimals = 18;
    uint256 public totalSupply;
    uint256 public maxSupply;
    uint256 public mintTarget;
    uint256 public raisedAmount;
    address public owner;
    address public factory;
    bool public launched;
    bool public refundEnabled;

    // Template type
    uint8 public templateType; // 0=standard,1=time,2=buyback,3=lp,4=holdLpBurn,5=burnOut,6=moduleLimit,7=burnOther

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => uint256) public mintContribution;

    // Template-specific params
    uint256 public buyTax;
    uint256 public sellTax;
    uint256 public marketingShare;
    uint256 public reflowShare;
    uint256 public dividendShare;
    uint256 public burnShare;
    address public marketingWallet;

    // Time-weighted
    uint256 public weightTime;
    mapping(address => uint256) public holdSince;

    // Buyback
    uint256 public buybackThreshold;
    uint256 public buybackPool;

    // Module limit
    uint256 public limitAmount;
    uint256 public limitDuration;
    uint256 public launchTime;

    // Burn other
    address public burnOtherToken;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Minted(address indexed user, uint256 bnbAmount, uint256 tokenAmount);
    event Launched(uint256 totalRaised);
    event Refunded(address indexed user, uint256 bnbAmount);

    modifier onlyOwner() { require(msg.sender == owner || msg.sender == factory, "Not authorized"); _; }

    function initialize(
        string memory _name, string memory _symbol,
        uint256 _maxSupply, uint256 _mintTarget,
        address _owner, uint8 _templateType,
        address _marketingWallet,
        uint256[4] memory _taxParams // buyTax, sellTax, marketingShare, reflowShare
    ) external {
        require(factory == address(0), "Already initialized");
        name = _name; symbol = _symbol;
        maxSupply = _maxSupply * 10**18;
        mintTarget = _mintTarget;
        owner = _owner; factory = msg.sender;
        templateType = _templateType;
        marketingWallet = _marketingWallet == address(0) ? _owner : _marketingWallet;
        buyTax = _taxParams[0];
        sellTax = _taxParams[1];
        marketingShare = _taxParams[2];
        reflowShare = _taxParams[3];
        dividendShare = 50;
        burnShare = 100 - _taxParams[2] - _taxParams[3];
        if(burnShare > 100) burnShare = 0;
    }

    function mint() external payable {
        require(!launched && !refundEnabled, "Not mintable");
        require(msg.value > 0 && raisedAmount + msg.value <= mintTarget, "Invalid amount");
        uint256 tokenAmount = (msg.value * maxSupply) / mintTarget;
        mintContribution[msg.sender] += msg.value;
        raisedAmount += msg.value;
        totalSupply += tokenAmount;
        balanceOf[msg.sender] += tokenAmount;
        if(templateType == 1) holdSince[msg.sender] = block.timestamp;
        emit Transfer(address(0), msg.sender, tokenAmount);
        emit Minted(msg.sender, msg.value, tokenAmount);
        if(raisedAmount >= mintTarget) _launch();
    }

    function _launch() internal {
        launched = true;
        launchTime = block.timestamp;
        uint256 fee = raisedAmount * 2 / 100;
        uint256 ownerAmt = raisedAmount - fee;
        payable(factory).transfer(fee);
        payable(owner).transfer(ownerAmt);
        emit Launched(raisedAmount);
    }

    function enableRefund() external onlyOwner {
        require(!launched); refundEnabled = true;
    }

    function refund() external {
        require(refundEnabled);
        uint256 c = mintContribution[msg.sender]; require(c > 0);
        uint256 t = balanceOf[msg.sender];
        balanceOf[msg.sender] = 0; totalSupply -= t;
        mintContribution[msg.sender] = 0; raisedAmount -= c;
        payable(msg.sender).transfer(c);
        emit Transfer(msg.sender, address(0), t);
        emit Refunded(msg.sender, c);
    }

    function transfer(address to, uint256 amount) external returns(bool) {
        require(balanceOf[msg.sender] >= amount);
        balanceOf[msg.sender] -= amount; balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount); return true;
    }

    function approve(address spender, uint256 amount) external returns(bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount); return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns(bool) {
        require(balanceOf[from] >= amount && allowance[from][msg.sender] >= amount);
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount; balanceOf[to] += amount;
        emit Transfer(from, to, amount); return true;
    }

    function getMintProgress() external view returns(uint256 raised, uint256 target, uint256 percent) {
        raised = raisedAmount; target = mintTarget;
        percent = mintTarget > 0 ? (raisedAmount * 100) / mintTarget : 0;
    }

    function isLimitActive() external view returns(bool) {
        if(templateType != 6 || !launched) return false;
        return block.timestamp < launchTime + limitDuration * 60;
    }

    receive() external payable {}
}

// ============ FACTORY ============
contract XueqiuFactory {
    address public owner;
    uint256 public deployFee = 0.002 ether; // 0.002 BNB
    uint256 public platformFeePercent = 2;   // 2% of raised

    struct TokenInfo {
        address tokenAddress;
        string name;
        string symbol;
        address creator;
        uint256 createdAt;
        uint256 mintTarget;
        uint8 templateType;
        string templateName;
    }

    TokenInfo[] public allTokens;
    mapping(address => address[]) public creatorTokens;
    mapping(address => bool) public isOurToken;

    event TokenDeployed(
        address indexed tokenAddress,
        address indexed creator,
        string name, string symbol,
        uint8 templateType
    );

    modifier onlyOwner() { require(msg.sender == owner); _; }

    constructor() { owner = msg.sender; }

    /**
     * @dev 普通部署（随机地址）
     */
    function deployToken(
        string memory _name,
        string memory _symbol,
        uint256 _maxSupply,
        uint256 _mintTargetBNB,
        uint8 _templateType,
        address _marketingWallet,
        uint256[4] memory _taxParams
    ) external payable returns(address) {
        require(msg.value >= deployFee, "Insufficient fee");
        require(_maxSupply > 0 && _mintTargetBNB >= 1, "Invalid params");
        require(_templateType <= 7, "Invalid template");

        XueqiuToken token = new XueqiuToken();
        token.initialize(
            _name, _symbol, _maxSupply,
            _mintTargetBNB * 1 ether,
            msg.sender, _templateType,
            _marketingWallet, _taxParams
        );

        _registerToken(address(token), _name, _symbol, _mintTargetBNB * 1 ether, _templateType);
        return address(token);
    }

    /**
     * @dev CREATE2部署，尾号00000
     * salt由前端计算好传入
     */
    function deployTokenWithSalt(
        string memory _name,
        string memory _symbol,
        uint256 _maxSupply,
        uint256 _mintTargetBNB,
        uint8 _templateType,
        address _marketingWallet,
        uint256[4] memory _taxParams,
        bytes32 _salt
    ) external payable returns(address) {
        require(msg.value >= deployFee, "Insufficient fee");
        require(_maxSupply > 0 && _mintTargetBNB >= 1, "Invalid params");
        require(_templateType <= 7, "Invalid template");

        bytes memory bytecode = type(XueqiuToken).creationCode;
        address tokenAddr;
        assembly {
            tokenAddr := create2(0, add(bytecode, 32), mload(bytecode), _salt)
        }
        require(tokenAddr != address(0), "Deploy failed");

        // Verify ends with 00000
        require(uint160(tokenAddr) % 100000 == 0, "Address not ending 00000");

        XueqiuToken(payable(tokenAddr)).initialize(
            _name, _symbol, _maxSupply,
            _mintTargetBNB * 1 ether,
            msg.sender, _templateType,
            _marketingWallet, _taxParams
        );

        _registerToken(tokenAddr, _name, _symbol, _mintTargetBNB * 1 ether, _templateType);
        return tokenAddr;
    }

    function _registerToken(address addr, string memory _name, string memory _symbol, uint256 target, uint8 tpl) internal {
        string[8] memory names = ["标准Mint","时间加权分红","回购销毁","LP分红","燃烧分红","理财出局","开盘限购","指定代币销毁"];
        allTokens.push(TokenInfo(addr, _name, _symbol, msg.sender, block.timestamp, target, tpl, names[tpl]));
        creatorTokens[msg.sender].push(addr);
        isOurToken[addr] = true;
        emit TokenDeployed(addr, msg.sender, _name, _symbol, tpl);
    }

    /**
     * @dev 计算CREATE2地址（前端用于挖salt）
     */
    function computeAddress(bytes32 salt) external view returns(address) {
        bytes32 hash = keccak256(abi.encodePacked(
            bytes1(0xff), address(this), salt,
            keccak256(type(XueqiuToken).creationCode)
        ));
        return address(uint160(uint256(hash)));
    }

    function getAllTokens() external view returns(TokenInfo[] memory) { return allTokens; }
    function getTokenCount() external view returns(uint256) { return allTokens.length; }
    function setDeployFee(uint256 _fee) external onlyOwner { deployFee = _fee; }
    function withdraw() external onlyOwner { payable(owner).transfer(address(this).balance); }
    receive() external payable {}
}
