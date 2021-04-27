// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

contract DOGEPool is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount, uint256 indexed lockedId);
    event BatchWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event PoolAdded(uint256 pid, address indexed stakedToken, uint256 allocPoint);
    event PoolSetted(uint256 pid, address indexed stakedToken, uint256 allocPoint);
    
    struct LockedInfo {
        uint256 amount;
        uint256 stakedTime;
        uint256 expireTime;
        bool isWithdrawed;
    }
    
    // Info of each user.
    struct UserInfo {
        uint256 totalAmount;     // How many staked tokens the user has provided.
        uint256 rewardDebt; // Reward debt.
        LockedInfo[] lockedInfo;
    }
    
    // Info of each pools.
    struct PoolInfo {
        IERC20 stakedToken;           
        uint256 allocPoint;
        uint256 lastRewardBlock;
        uint256 accDOGEPerShare;
        uint256 totalAmount;
    }
    
    PoolInfo[] public poolInfo;
    // Info of each user that stakes tokens corresponding pid
    mapping (uint256 => mapping (address => UserInfo)) public userInfo;
    
    IERC20 public DOGE;
    uint256 public DOGEPerBlock;
    uint256 public totalDOGERemaining;
    uint256 public totalDOGERewarded;
    uint256 public totalAllocPoint;
    uint256 public rewardCycle = 7 days;
    uint256 public startBlock;
    uint256 public lockedTime = 30 days;
    // Speed of block, default every block / 3s on Heco chain
    uint256 public blockSpeed = 3;
    // pid corresponding address
    mapping(address => uint256) public pidOfPool;
    address public rewardSetter;
    
    constructor(
        IERC20 _doge,
        address _rewardSetter
    ) public {
        DOGE = _doge;
        // 10 mins after deploying to start
        startBlock = block.number.add(10 * 60 / blockSpeed);
        rewardSetter = _rewardSetter;
    }
    
    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) public pure returns (uint256) {
        return _to.sub(_from);
    }
    
    function getUserLockedInfo(uint256 _pid, address _user) public view returns(LockedInfo[] memory) {
        UserInfo memory user = userInfo[_pid][_user];
        return user.lockedInfo;
    }
    
    function getCurrentBlock() public view returns(uint256) {
        return block.number;
    }
    
    function getUserLockedAmount(uint256 _pid, address _user) public view returns(uint256) {
        UserInfo memory user = userInfo[_pid][_user];
        LockedInfo[] memory lockedInfo = user.lockedInfo;
        uint256 lockedAmount = 0;
        for(uint i = 0; i < lockedInfo.length; i++) {
            if (lockedInfo[i].expireTime > block.timestamp && !lockedInfo[i].isWithdrawed) {
                lockedAmount = lockedAmount.add(lockedInfo[i].amount);
            }
        }
        return lockedAmount;
    }
    
    function pendingDOGE(uint256 _pid, address _user) public view returns(uint256) {
        PoolInfo memory pool = poolInfo[_pid];
        UserInfo memory user = userInfo[_pid][_user];
        uint256 accDOGEPerShare = pool.accDOGEPerShare;
        uint256 stakedTokenSupply = pool.stakedToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && stakedTokenSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 dogeReward = multiplier.mul(DOGEPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            accDOGEPerShare = accDOGEPerShare.add(dogeReward.mul(1e22).div(stakedTokenSupply));
        }
        return user.totalAmount.mul(accDOGEPerShare).div(1e22).sub(user.rewardDebt);
    }
    
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        
        uint256 stakedTokenSupply = pool.stakedToken.balanceOf(address(this));
        if (stakedTokenSupply == 0 || totalDOGERemaining == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 dogeReward = multiplier.mul(DOGEPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
        if (dogeReward > totalDOGERemaining) {
            // In case of insufficient supply to reward
            dogeReward = totalDOGERemaining;
            totalDOGERemaining = 0;
        } else {
            totalDOGERemaining = totalDOGERemaining.sub(dogeReward);
        }
        totalDOGERewarded = totalDOGERewarded.add(dogeReward);
        pool.accDOGEPerShare = pool.accDOGEPerShare.add(dogeReward.mul(1e22).div(stakedTokenSupply));
        pool.lastRewardBlock = block.number;
    }
    
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }
    
    function deposit(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        if (user.totalAmount > 0) {
            uint256 pending = user.totalAmount.mul(pool.accDOGEPerShare).div(1e22).sub(user.rewardDebt);
            if(pending > 0) {
                _safeDOGETransfer(msg.sender, pending);
            }
        }
        if(_amount > 0) {
            pool.stakedToken.safeTransferFrom(address(msg.sender), address(this), _amount);
            user.totalAmount = user.totalAmount.add(_amount); 
            pool.totalAmount = pool.totalAmount.add(_amount);
            user.lockedInfo.push(LockedInfo(
                _amount,
                block.timestamp,
                block.timestamp.add(lockedTime),
                false
            ));
        }
        user.rewardDebt = user.totalAmount.mul(pool.accDOGEPerShare).div(1e22);
        emit Deposit(msg.sender, _pid, _amount);
    }
    
    function withdraw(uint256 _pid, uint256 _amount, uint256 _lockedId) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        if (user.totalAmount > 0) {
            uint256 pending = user.totalAmount.mul(pool.accDOGEPerShare).div(1e22).sub(user.rewardDebt);
            if(pending > 0) {
                _safeDOGETransfer(msg.sender, pending);
            }
        }
        if (_amount > 0) {
            require(!user.lockedInfo[_lockedId].isWithdrawed, "DOGEPool: This amount of lockedId is withdrawed");
            require(user.lockedInfo[_lockedId].expireTime < block.timestamp, "DOGEPool: Can't withdraw before expireTime");
            require(user.lockedInfo[_lockedId].amount == _amount, "DOGEPool: Invalid amount of lockedId");
            user.totalAmount = user.totalAmount.sub(_amount); 
            pool.totalAmount = pool.totalAmount.sub(_amount);
            pool.stakedToken.safeTransfer(address(msg.sender), _amount);
            _setIsWithdrawedToTrue(_pid, msg.sender, _lockedId);
        }
        user.rewardDebt = user.totalAmount.mul(pool.accDOGEPerShare).div(1e22);
        emit Withdraw(msg.sender, _pid, _amount, _lockedId);
    }
    
    // Batch withdraw unlocked amounts
    function batchWithdraw(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        if (user.totalAmount > 0) {
            uint256 pending = user.totalAmount.mul(pool.accDOGEPerShare).div(1e22).sub(user.rewardDebt);
            if(pending > 0) {
                _safeDOGETransfer(msg.sender, pending);
            }
        }
        uint256 unlockedAmount = 0;
        for(uint i = 0; i < user.lockedInfo.length; i++) {
            if (user.lockedInfo[i].expireTime < block.timestamp && !user.lockedInfo[i].isWithdrawed) {
                unlockedAmount = unlockedAmount.add(user.lockedInfo[i].amount);
                _setIsWithdrawedToTrue(_pid, msg.sender, i);
            }
        }
        require(unlockedAmount <= user.totalAmount, "DOGEPool: Invalid unlockedAmount is calculated");
        user.totalAmount = user.totalAmount.sub(unlockedAmount); 
        pool.totalAmount = pool.totalAmount.sub(unlockedAmount);
        pool.stakedToken.safeTransfer(address(msg.sender), unlockedAmount);
        user.rewardDebt = user.totalAmount.mul(pool.accDOGEPerShare).div(1e22);
        emit BatchWithdraw(msg.sender, _pid, unlockedAmount);
    }
    
    // ======== INTERNAL METHODS ========= //
    
    function _safeDOGETransfer(address _to, uint256 _amount) internal {
        uint256 dogeBal = DOGE.balanceOf(address(this));
        if (_amount > dogeBal) {
            DOGE.transfer(_to, dogeBal);
        } else {
            DOGE.transfer(_to, _amount);
        }
    }
    
    function _setIsWithdrawedToTrue(uint256 _pid, address _user, uint256 _lockedId) internal {
        UserInfo storage user = userInfo[_pid][_user];
        user.lockedInfo[_lockedId].isWithdrawed = true;
    }
    
    // ======== ONLY OWNER CONTROL METHODS ========== //
    
    function addPool(
        uint256 _allocPoint, 
        IERC20 _stakedToken, 
        bool _withUpdate
    ) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        poolInfo.push(PoolInfo({
            stakedToken: _stakedToken,
            allocPoint: _allocPoint,
            lastRewardBlock: lastRewardBlock,
            accDOGEPerShare: 0,
            totalAmount: 0
        }));
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        pidOfPool[address(_stakedToken)] = poolInfo.length.sub(1);
        emit PoolAdded(poolInfo.length - 1, address(_stakedToken), _allocPoint);
    }
    
    function setPool(
        uint256 _pid, 
        uint256 _allocPoint, 
        bool _withUpdate    
    ) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint;
        emit PoolSetted(_pid, address(poolInfo[_pid].stakedToken), _allocPoint);
    }
    
    function setDOGEPerBlock(uint256 amount) public onlyOwner {
        DOGEPerBlock = amount * 1e8;
    }
    
    function setRewardCycle(uint256 cycle) public onlyOwner {
        rewardCycle = cycle;
    }
    
    function setLockedTime(uint256 time) public onlyOwner {
        lockedTime = time;
    }
    
    function setBlockSpeed(uint256 speed) public onlyOwner {
        blockSpeed = speed;
    }
    
    function setRewardSetter(address newSetter) public onlyOwner {
        require(newSetter != address(0), "DOGEPool: zero address");
        rewardSetter = newSetter;
    }
    
    // Withdraw DOGE rewards for emergency 
    function emergencyWithdrawRewards() public onlyOwner {
        _safeDOGETransfer(msg.sender, DOGE.balanceOf(address(this)));
    }
    
    // Deposit new reward of DOGE and update DOGEPerBlock
    function newReward(uint256 amount) public {
        require(msg.sender == rewardSetter, "DOGEPool: incorrect sender");
        massUpdatePools();
        DOGE.safeTransferFrom(address(msg.sender), address(this), amount * 1e8);
        totalDOGERemaining = totalDOGERemaining.add(amount * 1e8);
        DOGEPerBlock = totalDOGERemaining.div(rewardCycle.div(blockSpeed));
    }
}