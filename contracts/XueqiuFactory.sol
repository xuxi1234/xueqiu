// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title XueqiuToken - 每个项目的独立代币合约
 */
contract XueqiuToken {
    string public name;
    string public symbol;
    uint8 public decimals = 18;
    uint256 public totalSupply;
    uint256 public maxSupply;
    uint256 public mintPrice;       // 每个代币价格（BNB wei）
    uint256 public mintTarget;      // 铸造目标（BNB wei）
    uint256 public mintedAmount;    // 已铸造数量
    uint256 public raisedAmount;    // 已筹集BNB
    address public owner;
    address public factory;
    bool public launched;           // 是否已发射
    bool public refundEnabled;      // 是否开启退款

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => uint256) public mintContribution; // 每个地址贡献的BNB

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Minted(address indexed user, uint256 bnbAmount, uint256 tokenAmount);
    event Launched(uint256 totalRaised);
    event Refunded(address indexed user, uint256 bnbAmount);

    modifier onlyOwner() { require(msg.sender == owner, "Not owner"); _; }

    constructor(
        string memory _name,
        string memory _symbol,
        uint256 _maxSupply,
        uint256 _mintTarget,
        address _owner
    ) {
        name = _name;
        symbol = _symbol;
        maxSupply = _maxSupply * 10**18;
        mintTarget = _mintTarget;
        owner = _owner;
        factory = msg.sender;
        mintPrice = _mintTarget / (_maxSupply * 10**18); // BNB per token wei
    }

    /**
     * @dev 用户铸造代币，发送BNB
     */
    function mint() external payable {
        require(!launched, "Already launched");
        require(!refundEnabled, "Refund mode");
        require(msg.value > 0, "Send BNB to mint");
        require(raisedAmount + msg.value <= mintTarget, "Exceeds target");

        // 计算可获得的代币数量
        uint256 tokenAmount = (msg.value * maxSupply) / mintTarget;
        require(mintedAmount + tokenAmount <= maxSupply, "Exceeds max supply");

        mintContribution[msg.sender] += msg.value;
        raisedAmount += msg.value;
        mintedAmount += tokenAmount;
        balanceOf[msg.sender] += tokenAmount;
        totalSupply += tokenAmount;

        emit Transfer(address(0), msg.sender, tokenAmount);
        emit Minted(msg.sender, msg.value, tokenAmount);

        // 如果达到目标，自动发射
        if (raisedAmount >= mintTarget) {
            _launch();
        }
    }

    /**
     * @dev 达到目标后自动发射，资金转给项目方
     */
    function _launch() internal {
        launched = true;
        // 平台抽取 2% 手续费
        uint256 fee = raisedAmount * 2 / 100;
        uint256 ownerAmount = raisedAmount - fee;
        payable(factory).transfer(fee);
        payable(owner).transfer(ownerAmount);
        emit Launched(raisedAmount);
    }

    /**
     * @dev 项目方开启紧急退款（未达目标时）
     */
    function enableRefund() external onlyOwner {
        require(!launched, "Already launched");
        refundEnabled = true;
    }

    /**
     * @dev 用户申请退款
     */
    function refund() external {
        require(refundEnabled, "Refund not enabled");
        uint256 contribution = mintContribution[msg.sender];
        require(contribution > 0, "No contribution");

        // 销毁用户代币
        uint256 userTokens = balanceOf[msg.sender];
        balanceOf[msg.sender] = 0;
        totalSupply -= userTokens;
        mintContribution[msg.sender] = 0;
        raisedAmount -= contribution;

        payable(msg.sender).transfer(contribution);
        emit Transfer(msg.sender, address(0), userTokens);
        emit Refunded(msg.sender, contribution);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "Insufficient balance");
        require(allowance[from][msg.sender] >= amount, "Insufficient allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    function getMintProgress() external view returns (uint256 raised, uint256 target, uint256 percent) {
        raised = raisedAmount;
        target = mintTarget;
        percent = mintTarget > 0 ? (raisedAmount * 100) / mintTarget : 0;
    }
}

/**
 * @title XueqiuFactory - 雪球发射台工厂合约
 * 负责创建和管理所有代币项目
 */
contract XueqiuFactory {
    address public owner;
    uint256 public deployFee = 0.01 ether; // 部署费用 0.01 BNB
    
    struct TokenInfo {
        address tokenAddress;
        string name;
        string symbol;
        address creator;
        uint256 createdAt;
        uint256 mintTarget;
    }

    TokenInfo[] public allTokens;
    mapping(address => address[]) public creatorTokens;

    event TokenDeployed(address indexed tokenAddress, address indexed creator, string name, string symbol);

    modifier onlyOwner() { require(msg.sender == owner, "Not owner"); _; }

    constructor() { owner = msg.sender; }

    /**
     * @dev 部署新代币，需支付部署费
     */
    function deployToken(
        string memory _name,
        string memory _symbol,
        uint256 _maxSupply,
        uint256 _mintTargetBNB  // 单位：BNB（整数，如 10 = 10 BNB）
    ) external payable returns (address) {
        require(msg.value >= deployFee, "Insufficient deploy fee");
        require(_maxSupply > 0 && _maxSupply <= 1_000_000_000, "Invalid supply");
        require(_mintTargetBNB >= 1 && _mintTargetBNB <= 10000, "Target: 1-10000 BNB");
        require(bytes(_name).length > 0 && bytes(_symbol).length > 0, "Invalid name/symbol");

        uint256 mintTargetWei = _mintTargetBNB * 1 ether;

        XueqiuToken token = new XueqiuToken(
            _name, _symbol, _maxSupply, mintTargetWei, msg.sender
        );

        allTokens.push(TokenInfo({
            tokenAddress: address(token),
            name: _name,
            symbol: _symbol,
            creator: msg.sender,
            createdAt: block.timestamp,
            mintTarget: mintTargetWei
        }));

        creatorTokens[msg.sender].push(address(token));

        emit TokenDeployed(address(token), msg.sender, _name, _symbol);
        return address(token);
    }

    function getAllTokens() external view returns (TokenInfo[] memory) {
        return allTokens;
    }

    function getTokenCount() external view returns (uint256) {
        return allTokens.length;
    }

    function setDeployFee(uint256 _fee) external onlyOwner {
        deployFee = _fee;
    }

    function withdraw() external onlyOwner {
        payable(owner).transfer(address(this).balance);
    }

    receive() external payable {}
}
