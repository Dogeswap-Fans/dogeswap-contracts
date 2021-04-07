// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "../interfaces/IDOG.sol";

contract DogeswapPools is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event Mint(uint256 amount);
    event PoolAdded(POOL_TYPE poolType, address indexed stakedToken, uint256 allocPoint);
    event PoolSetted(address indexed stakedToken, uint256 allocPoint);
    
    // max supply of DOG token
    uint256 private constant maxSupply = 1_000_000_000e18;
    
    // Control mining
    bool public paused = false;
    modifier notPause() {
        require(paused == false, "DogeswapPools: Mining has been suspended");
        _;
    }

    enum POOL_TYPE { Single, LP }

    // Info of each user.
    struct UserInfo {
        uint256 amount;     // How many LP/Single tokens the user has provided.
        uint256 rewardDebt; // Reward debt.
    }

    // Info of each pools.
    struct PoolInfo {
        POOL_TYPE poolType;
        IERC20 stakedToken;           
        uint256 allocPoint;
        uint256 lastRewardBlock;
        uint256 accDOGPerShare;
        uint256 totalStakedAddress;
        uint256 totalAmount;
    }

    PoolInfo[] public poolInfo;
    // Info of each user that stakes tokens corresponding pid
    mapping (uint256 => mapping (address => UserInfo)) public userInfo;
    // Is staked address corresponding pid
    mapping (uint256 => mapping (address => bool)) isStakedAddress;

    // DOG token
    IDOG public DOG;
    // total DOG token mined per block
    uint256 public DOGPerBlock;
    // Single pool shares 5% per block
    uint256 public SINGLE_SHARE = 5;
    // LP pool shares 95% per block
    uint256 public LP_SHARE = 95;
    // Single allocation points. Must be the sum of all allocation points in all single pools.
    uint256 public singleAllocPoints = 0;
    // LP allocation points. Must be the sum of all allocation points in all lp pools.
    uint256 public lpAllocPoints = 0;
    // The block number when DOG mining starts.
    uint256 public startBlock;
    // Halving cycle
    uint256 public HALVING_CYCLE = 60 days;
    // Dev address which get DOG token.
    address payable public devaddr;
    // Fee address which get fee of single pool.
    address payable public feeAddr;
    // pid corresponding address
    mapping(address => uint256) public pidOfPool;
    
    // feeOn of deposit and withdraw to single pool
    bool public depositSinglePoolFeeOn = true;
    uint256 public depositSinglePoolFee = 1e17;
    bool public withdrawSinglePoolFeeOn = true;
    uint256 public withdrawSinglePoolFee = 1e17;
    
    constructor(
        IDOG _dog,
        uint256 _dogPerBlock,
        address payable _devaddr,
        address payable _feeAddr,
        uint256 _startTime
    ) public {
        require(_startTime > block.timestamp, "DogeswapPools: Incorrect start time");
        DOG = _dog;
        DOGPerBlock = _dogPerBlock * 1e18;
        devaddr = _devaddr;
        feeAddr = _feeAddr;
        startBlock = block.number + (_startTime - block.timestamp) / 3;
    }
    
    function poolLength() public view returns (uint256) {
        return poolInfo.length;
    }
    
    function phase(uint256 blockNumber) public view returns (uint256) {
        if (HALVING_CYCLE == 0) {
            return 0;
        }
        if (blockNumber > startBlock) {
            return (blockNumber.sub(startBlock).sub(1)).div(HALVING_CYCLE);
        }
        return 0;
    }

    function reward(uint256 blockNumber) public view returns (uint256) {
        uint256 _phase = phase(blockNumber);
        return DOGPerBlock.div(2 ** _phase);
    }
    
    function getDOGBlockReward(uint256 _lastRewardBlock, uint256 _currentBlock) public view returns (uint256) {
        uint256 blockReward = 0;
        uint256 n = phase(_lastRewardBlock);
        uint256 m = phase(_currentBlock);
        while (n < m) {
            n++;
            uint256 r = n.mul(HALVING_CYCLE).add(startBlock);
            blockReward = blockReward.add((r.sub(_lastRewardBlock)).mul(reward(r)));
            _lastRewardBlock = r;
        }
        blockReward = blockReward.add((_currentBlock.sub(_lastRewardBlock)).mul(reward(_currentBlock)));
        return blockReward;
    }
    
    function pendingDOG(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accDOGPerShare = pool.accDOGPerShare;
        uint256 stakedTokenSupply;
        if (_isDOGPool(pool.stakedToken)) {
            stakedTokenSupply = pool.totalAmount;
        } else {
            stakedTokenSupply = pool.stakedToken.balanceOf(address(this));
        }
        if (user.amount > 0) {
            if (block.number > pool.lastRewardBlock) {
                uint256 blockReward = getDOGBlockReward(pool.lastRewardBlock, block.number);
                uint256 dogReward = 0;
                if (pool.poolType == POOL_TYPE.Single) {
                    dogReward = blockReward.mul(SINGLE_SHARE).div(100).mul(pool.allocPoint).div(singleAllocPoints);
                } else {
                    dogReward = blockReward.mul(LP_SHARE).div(100).mul(pool.allocPoint).div(lpAllocPoints);
                }
                accDOGPerShare = accDOGPerShare.add(dogReward.mul(1e12).div(stakedTokenSupply));
                return user.amount.mul(accDOGPerShare).div(1e12).sub(user.rewardDebt);
            }
            if (block.number == pool.lastRewardBlock) {
                return user.amount.mul(accDOGPerShare).div(1e12).sub(user.rewardDebt);
            }
        }
        return 0;
    }
    
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        
        uint256 stakedTokenSupply;
        
        if (_isDOGPool(pool.stakedToken)) {
            if (pool.totalAmount == 0) {
                pool.lastRewardBlock = block.number;
                return;
            }
            stakedTokenSupply = pool.totalAmount;
        } else {
            stakedTokenSupply = pool.stakedToken.balanceOf(address(this));
            if (stakedTokenSupply == 0) {
                pool.lastRewardBlock = block.number;
                return;
            }
        }
        
        uint256 blockReward = getDOGBlockReward(pool.lastRewardBlock, block.number);
        uint256 dogReward = 0;
        
        if (blockReward <= 0) {
            return;
        }
        
        if (pool.poolType == POOL_TYPE.Single) {
            dogReward = blockReward.mul(SINGLE_SHARE).div(100).mul(pool.allocPoint).div(singleAllocPoints);
        } else {
            dogReward = blockReward.mul(LP_SHARE).div(100).mul(pool.allocPoint).div(lpAllocPoints);
        }
        
        uint256 remaining = maxSupply.sub(DOG.totalSupply());
        
        if (dogReward.add(dogReward.div(10)) < remaining) {
            DOG.mint(devaddr, dogReward.div(10));
            DOG.mint(address(this), dogReward);
            pool.accDOGPerShare = pool.accDOGPerShare.add(dogReward.mul(1e12).div(stakedTokenSupply));
            emit Mint(dogReward);
        } else {
            uint256 devReward = remaining.mul(1).div(11);
            DOG.mint(devaddr, devReward);
            DOG.mint(address(this), remaining.sub(devReward));
            pool.accDOGPerShare = pool.accDOGPerShare.add(remaining.sub(devReward).mul(1e12).div(stakedTokenSupply));
            emit Mint(remaining.sub(devReward));
        }
        
        pool.lastRewardBlock = block.number;
    }
    
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }
    
    function deposit(uint256 _pid, uint256 _amount) public payable notPause {
        PoolInfo storage pool = poolInfo[_pid];
        if (pool.poolType == POOL_TYPE.Single && depositSinglePoolFeeOn) {
            require(msg.value == depositSinglePoolFee, "DogeswapPools: Can't deposit to single pool without fee");
            feeAddr.transfer(address(this).balance);
        }
        address _user = msg.sender;
        UserInfo storage user = userInfo[_pid][_user];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 pendingAmount = user.amount.mul(pool.accDOGPerShare).div(1e12).sub(user.rewardDebt);
            if (pendingAmount > 0) {
                _safeDOGTransfer(_user, pendingAmount);
            }
        }
        if (_amount > 0) {
            pool.stakedToken.safeTransferFrom(_user, address(this), _amount);
            user.amount = user.amount.add(_amount);
            pool.totalAmount = pool.totalAmount.add(_amount);
            if (!isStakedAddress[_pid][_user]) {
                isStakedAddress[_pid][_user] = true;
                pool.totalStakedAddress = pool.totalStakedAddress.add(1);
            }
        }
        user.rewardDebt = user.amount.mul(pool.accDOGPerShare).div(1e12);
        emit Deposit(_user, _pid, _amount);
    }
    
    function withdraw(uint256 _pid, uint256 _amount) public payable notPause {
        PoolInfo storage pool = poolInfo[_pid];
        if (pool.poolType == POOL_TYPE.Single && withdrawSinglePoolFeeOn) {
            require(msg.value == withdrawSinglePoolFee, "DogeswapPools: Can't withdraw from single pool without fee");
            feeAddr.transfer(address(this).balance);
        }
        address _user = msg.sender;
        UserInfo storage user = userInfo[_pid][_user];
        require(user.amount >= _amount, "DogeswapPools: Insuffcient amount to withdraw");
        updatePool(_pid);
        uint256 pendingAmount = user.amount.mul(pool.accDOGPerShare).div(1e12).sub(user.rewardDebt);
        if (pendingAmount > 0) {
            _safeDOGTransfer(_user, pendingAmount);
        }
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.totalAmount = pool.totalAmount.sub(_amount);
            pool.stakedToken.safeTransfer(_user, _amount);
            if (user.amount == 0) {
                isStakedAddress[_pid][_user] = false;
                pool.totalStakedAddress = pool.totalStakedAddress.sub(1);
            }
        }
        user.rewardDebt = user.amount.mul(pool.accDOGPerShare).div(1e12);
        emit Withdraw(_user, _pid, _amount);
    }
    
    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public payable notPause {
        PoolInfo storage pool = poolInfo[_pid];
        if (pool.poolType == POOL_TYPE.Single && withdrawSinglePoolFeeOn) {
            require(msg.value == withdrawSinglePoolFee, "DogeswapPools: Can't withdraw from single pool without fee");
        }
        address _user = msg.sender;
        UserInfo storage user = userInfo[_pid][_user];
        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        pool.stakedToken.safeTransfer(_user, amount);
        pool.totalAmount = pool.totalAmount.sub(amount);
        isStakedAddress[_pid][_user] = false;
        pool.totalStakedAddress = pool.totalStakedAddress.sub(1);
        emit EmergencyWithdraw(_user, _pid, amount);
    }
    
    function get365EarnedByPid(uint256 _pid) public view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        uint256 blockReward = getDOGBlockReward(block.number, block.number.add(365 days / 3));
        uint256 dogReward = 0;
        
        if (blockReward <= 0) {
            return 0;
        }
        
        if (pool.poolType == POOL_TYPE.Single) {
            dogReward = blockReward.mul(SINGLE_SHARE).div(100).mul(pool.allocPoint).div(singleAllocPoints);
        } else {
            dogReward = blockReward.mul(LP_SHARE).div(100).mul(pool.allocPoint).div(lpAllocPoints);
        }
        
        return dogReward;
    }
    
    // ======== INTERNAL METHODS ========= //
    
    function _addPool(
        POOL_TYPE _poolType, 
        uint256 _allocPoint, 
        IERC20 _stakedToken, 
        bool _withUpdate
    ) internal {
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        if (_poolType == POOL_TYPE.Single) {
            singleAllocPoints = singleAllocPoints.add(_allocPoint);
        } else {
            lpAllocPoints = lpAllocPoints.add(_allocPoint);
        }
        poolInfo.push(PoolInfo({
            poolType: _poolType,
            stakedToken: _stakedToken,
            allocPoint: _allocPoint,
            lastRewardBlock: lastRewardBlock,
            accDOGPerShare: 0,
            totalAmount: 0,
            totalStakedAddress: 0
        }));
        pidOfPool[address(_stakedToken)] = poolInfo.length - 1;
        emit PoolAdded(_poolType, address(_stakedToken), _allocPoint);
    }
    
    function _setPool(
        uint256 _pid, 
        uint256 _allocPoint, 
        bool _withUpdate
    ) internal {
        if (_withUpdate) {
            massUpdatePools();
        }
        if (poolInfo[_pid].poolType == POOL_TYPE.Single) {
            singleAllocPoints = singleAllocPoints.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        } else {
            lpAllocPoints = lpAllocPoints.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        }
        poolInfo[_pid].allocPoint = _allocPoint;
        emit PoolSetted(address(poolInfo[_pid].stakedToken), _allocPoint);
    }
    
    function _isDOGPool(IERC20 stakedToken) internal view returns (bool) {
        return stakedToken == DOG;
    }
    
    function _safeDOGTransfer(address _to, uint256 _amount) internal {
        uint256 dogBal = DOG.balanceOf(address(this));
        if (_amount > dogBal) {
            DOG.transfer(_to, dogBal);
        } else {
            DOG.transfer(_to, _amount);
        }
    }
    
    // ======== ONLY OWNER CONTROL METHODS ========== //
    function getPools() public view onlyOwner returns (PoolInfo[] memory) {
        return poolInfo;
    }
    
    function batchAddPools(
        IERC20[] memory stakedTokens,
        uint256[] memory allocPoints,
        POOL_TYPE[] memory poolTypes,
        bool _withUpdate
    ) public onlyOwner {
        require(
            stakedTokens.length == allocPoints.length && 
            stakedTokens.length == poolTypes.length,
            "DogeswapPools: Invalid length of pools"
        );
        for(uint i = 0; i < stakedTokens.length; i++) {
            _addPool(poolTypes[i], allocPoints[i], stakedTokens[i], _withUpdate);
        }
    }
    
    function batchSetPoolsByStakedToken(
        IERC20[] memory stakedTokens, 
        uint256[] memory allocPoints, 
        bool _withUpdate
    ) public onlyOwner {
        require(
            stakedTokens.length == allocPoints.length,
            "DogeswapPools: Invalid length of pools"
        );
        for(uint i = 0; i < stakedTokens.length; i++) {
            _setPool(pidOfPool[address(stakedTokens[i])], allocPoints[i], _withUpdate);
        }
    }
    
    function setDOGPerBlock(uint256 num) public onlyOwner {
        DOGPerBlock = num * 1e18;
    }
    
    function setHalvingCycle(uint256 cycleTime) public onlyOwner {
        HALVING_CYCLE = cycleTime;
    }
    
    function setPoolShare(uint256 single, uint256 lp) public onlyOwner {
        require(single.add(lp) == 100, "DogeswapPools: the sum of two share should be 100");
        SINGLE_SHARE = single;
        LP_SHARE = lp;
    }
    
    function setPause() public onlyOwner {
        paused = !paused;
    }
    
    // Update dev address by owner
    function setDevAddr(address payable _devaddr) public onlyOwner {
        devaddr = _devaddr;
    }
    
    // Update fee address by owner
    function setFeeAddr(address payable _feeAddr) public onlyOwner{
        feeAddr = _feeAddr;
    }
    
    function setDepositFee(bool _feeOn, uint256 _fee) public onlyOwner {
        depositSinglePoolFeeOn = _feeOn;
        depositSinglePoolFee = _fee;
    }
    
    function setWithdrawFee(bool _feeOn, uint256 _fee) public onlyOwner {
        withdrawSinglePoolFeeOn = _feeOn;
        withdrawSinglePoolFee = _fee;
    }
}