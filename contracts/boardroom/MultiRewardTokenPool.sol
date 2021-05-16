// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/EnumerableSet.sol";

contract MultiRewardTokenPool is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount, uint256 indexed lockedId, uint256 penlaty);
    event PoolAdded(uint256 pid, address indexed stakedToken, uint256 allocPoint);
    event PoolSetted(uint256 pid, address indexed stakedToken, uint256 allocPoint);
    event RewardTokenAdded(address indexed rewardToken, uint256 decimals, uint256 rid);
    
    struct LockedInfo {
        uint256 amount;
        uint256 stakedTime;
        uint256 expireTime;
        uint256 unlockTime;
        bool isWithdrawed;
    }
    
    // Info of each user.
    struct UserInfo {
        uint256 totalAmount;     // How many staked tokens the user has provided.
        // Reward debt corresponding rid
        mapping (uint256 => uint256) rewardDebt; 
        LockedInfo[] lockedInfo;
    }
    
    // Info of each pools.
    struct PoolInfo {
        IERC20 stakedToken;           
        uint256 allocPoint;
        // lastReardBlock corresponding rid
        mapping (uint256 => uint256) lastRewardBlock;
        // accRewardPerShare corresponding rid
        mapping (uint256 => uint256) accRewardPerShare;
        uint256 totalAmount;
        uint256 totalStakedAddress;
    }

    struct RewardTokenInfo {
        IERC20 rewardToken;
        string symbol;
        uint256 decimals;
        uint256 magicNumber;
        uint256 startBlock;
        uint256 endBlock;
        uint256 rewardPerBlock;
        uint256 tokenRemaining;
        uint256 tokenRewarded;
        uint256 rid;
    }
    
    RewardTokenInfo[] public rewardTokenInfo;
    PoolInfo[] public poolInfo;
    // Info of each user that stakes tokens corresponding pid
    mapping (uint256 => mapping (address => UserInfo)) public userInfo;
    // Is staked address corresponding pid
    mapping (uint256 => mapping (address => bool)) isStakedAddress;
    
    uint256 public totalAllocPoint;
    uint256 public rewardCycle = 7 days;
    uint256 public lockedTime = 30 days;
    uint256 public phase1Time = 10 days;
    uint256 public phase2Time = 20 days;
    uint256 public PENLATY_RATIO1 = 30;
    uint256 public PENLATY_RATIO2 = 20;
    uint256 public PENLATY_RATIO3 = 10;
    // Speed of block, default every block / 3s on Heco chain
    uint256 public blockSpeed = 3;
    // pid corresponding pool staked token address
    mapping(address => uint256) public pidOfPool;
    // rid corresponding reward token address
    mapping(address => uint256) public ridOfReward;
    mapping(uint256 => address) public setterOfRid;
    mapping(address => bool) public isExistedRewardToken;
    EnumerableSet.AddressSet private _setter;
    address public BLACK_HOLE;

    modifier onlySetter() {
        require(isSetter(msg.sender), "MultiRewardTokenPool: Not the setter");
        _;
    }
    
    constructor(address _blackHole) public {
        BLACK_HOLE = _blackHole;
        EnumerableSet.add(_setter, msg.sender);
    }

    function getSetterLength() public view returns (uint256) {
        return EnumerableSet.length(_setter);
    }

    function isSetter(address _set) public view returns (bool) {
        return EnumerableSet.contains(_setter, _set);
    }

    function getSetter(uint256 _index) public view returns (address){
        require(_index <= getSetterLength() - 1, "MultiRewardTokenPool: index out of bounds");
        return EnumerableSet.at(_setter, _index);
    }
    
    function getRewardTokenInfo() external view returns(RewardTokenInfo[] memory) {
        return rewardTokenInfo;
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
    
    function pendingRewards(uint256 _rid, uint256 _pid, address _user) public view returns(uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        RewardTokenInfo storage token = rewardTokenInfo[_rid];
        uint256 accRewardPerShare = pool.accRewardPerShare[_rid];
        uint256 lastRewardBlock = pool.lastRewardBlock[_rid];
        uint256 stakedTokenSupply = pool.stakedToken.balanceOf(address(this));
        if (block.number > lastRewardBlock && stakedTokenSupply != 0) {
            uint256 multiplier = getMultiplier(lastRewardBlock, block.number);
            uint256 tokenReward = multiplier.mul(token.rewardPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            if (tokenReward > token.tokenRemaining) {
                // In case of insufficient supply to reward
                tokenReward = token.tokenRemaining;
            }
            accRewardPerShare = accRewardPerShare.add(tokenReward.mul(token.magicNumber).div(stakedTokenSupply));
        }
        return user.totalAmount.mul(accRewardPerShare).div(token.magicNumber).sub(user.rewardDebt[_rid]);
    }
    
    function updatePool(uint256 _pid, uint256 _rid) public {
        PoolInfo storage pool = poolInfo[_pid];
        RewardTokenInfo storage token = rewardTokenInfo[_rid];
        uint256 lastRewardBlock = pool.lastRewardBlock[_rid];
        
        if (block.number <= lastRewardBlock) {
            return;
        }
        
        uint256 stakedTokenSupply = pool.stakedToken.balanceOf(address(this));
        if (stakedTokenSupply == 0 || token.tokenRemaining == 0) {
            pool.lastRewardBlock[_rid] = block.number;
            return;
        }

        uint256 multiplier = getMultiplier(lastRewardBlock, block.number);
        uint256 tokenReward = multiplier.mul(token.rewardPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
        if (tokenReward > token.tokenRemaining) {
            // In case of insufficient supply to reward
            tokenReward = token.tokenRemaining;
            token.tokenRemaining = 0;
        } else {
            token.tokenRemaining = token.tokenRemaining.sub(tokenReward);
        }
        token.tokenRewarded = token.tokenRewarded.add(tokenReward);
        pool.accRewardPerShare[_rid] = pool.accRewardPerShare[_rid].add(tokenReward.mul(token.magicNumber).div(stakedTokenSupply));
        pool.lastRewardBlock[_rid] = block.number;
    }
    
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            for (uint256 rid = 0; rid < rewardTokenInfo.length; ++rid) {
                updatePool(pid, rid);
            }
        }
    }
    
    function deposit(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        address _user = msg.sender;
        UserInfo storage user = userInfo[_pid][_user];
        for (uint256 rid = 0; rid < rewardTokenInfo.length; ++rid) {
            updatePool(_pid, rid);
            if (user.totalAmount > 0) {
                uint256 pending = user.totalAmount.mul(pool.accRewardPerShare[rid]).div(rewardTokenInfo[rid].magicNumber).sub(user.rewardDebt[rid]);
                if(pending > 0) {
                    _safeTokenTransfer(rewardTokenInfo[rid].rewardToken, msg.sender, pending);
                }
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
                0,
                false
            ));
            if (!isStakedAddress[_pid][_user]) {
                isStakedAddress[_pid][_user] = true;
                pool.totalStakedAddress = pool.totalStakedAddress.add(1);
            }
        }
        for (uint256 rid = 0; rid < rewardTokenInfo.length; ++rid) {
            user.rewardDebt[rid] = user.totalAmount.mul(pool.accRewardPerShare[rid]).div(rewardTokenInfo[rid].magicNumber);
        }
        emit Deposit(msg.sender, _pid, _amount);
    }
    
    function withdraw(uint256 _pid, uint256 _amount, uint256 _lockedId) public {
        PoolInfo storage pool = poolInfo[_pid];
        address _user = msg.sender;
        UserInfo storage user = userInfo[_pid][_user];
        for (uint256 rid = 0; rid < rewardTokenInfo.length; ++rid) {
            updatePool(_pid, rid);
            if (user.totalAmount > 0) {
                uint256 pending = user.totalAmount.mul(pool.accRewardPerShare[rid]).div(rewardTokenInfo[rid].magicNumber).sub(user.rewardDebt[rid]);
                if(pending > 0) {
                    _safeTokenTransfer(rewardTokenInfo[rid].rewardToken, msg.sender, pending);
                }
            }
        }
        uint256 penlaty = 0;
        if (_amount > 0) {
            require(!user.lockedInfo[_lockedId].isWithdrawed, "MultiRewardTokenPool: This amount of lockedId is withdrawed");
            require(user.lockedInfo[_lockedId].amount == _amount, "MultiRewardTokenPool: Invalid amount of lockedId");
            uint256 expireTime = user.lockedInfo[_lockedId].expireTime;
            uint256 stakedTime = user.lockedInfo[_lockedId].stakedTime;
            if (expireTime < block.timestamp) {
                pool.stakedToken.safeTransfer(address(msg.sender), _amount);
            } else {
                uint256 interval = block.timestamp - stakedTime;
                if (interval <= phase1Time) {
                    penlaty = _amount.mul(PENLATY_RATIO1).div(100);
                } else if (interval <= phase2Time) {
                    penlaty = _amount.mul(PENLATY_RATIO2).div(100);
                } else {
                    penlaty = _amount.mul(PENLATY_RATIO3).div(100);
                }
                pool.stakedToken.safeTransfer(address(msg.sender), _amount.sub(penlaty));
                // transfer penlaty to black hole address
                pool.stakedToken.safeTransfer(BLACK_HOLE, penlaty);
            }
            user.lockedInfo[_lockedId].unlockTime = block.timestamp;
            user.totalAmount = user.totalAmount.sub(_amount); 
            pool.totalAmount = pool.totalAmount.sub(_amount);
            _setIsWithdrawedToTrue(_pid, msg.sender, _lockedId);
            if (user.totalAmount == 0) {
                isStakedAddress[_pid][_user] = false;
                pool.totalStakedAddress = pool.totalStakedAddress.sub(1);
            }
        }
        for (uint256 rid = 0; rid < rewardTokenInfo.length; ++rid) {
            user.rewardDebt[rid] = user.totalAmount.mul(pool.accRewardPerShare[rid]).div(rewardTokenInfo[rid].magicNumber);
        }
        emit Withdraw(msg.sender, _pid, _amount, _lockedId, penlaty);
    }

    // ======== INTERNAL METHODS ========= //
    
    function _safeTokenTransfer(IERC20 _token, address _to, uint256 _amount) internal {
        uint256 tokenBal = _token.balanceOf(address(this));
        if (_amount > tokenBal) {
            _token.transfer(_to, tokenBal);
        } else {
            _token.transfer(_to, _amount);
        }
    }
    
    function _setIsWithdrawedToTrue(uint256 _pid, address _user, uint256 _lockedId) internal {
        UserInfo storage user = userInfo[_pid][_user];
        user.lockedInfo[_lockedId].isWithdrawed = true;
    }

    mapping(uint256 => PoolInfo) private newPool;
    
    // ======== ONLY OWNER CONTROL METHODS ========== //

    function addSetter(address _newSetter) public onlyOwner returns (bool) {
        require(_newSetter != address(0), "MultiRewardTokenPool: NewSetter is the zero address");
        return EnumerableSet.add(_setter, _newSetter);
    }

    function delSetter(address _delSetter) public onlyOwner returns (bool) {
        require(_delSetter != address(0), "MultiRewardTokenPool: DelSetter is the zero address");
        return EnumerableSet.remove(_setter, _delSetter);
    }
    
    function addPool(
        uint256 _allocPoint, 
        IERC20 _stakedToken, 
        bool _withUpdate
    ) external onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        PoolInfo storage _newPool = newPool[0];
        for (uint rid = 0; rid < rewardTokenInfo.length; ++rid) {
            uint256 startBlock = rewardTokenInfo[rid].startBlock;
            uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
            _newPool.lastRewardBlock[rid] = lastRewardBlock;
            _newPool.accRewardPerShare[rid] = 0;
        }
        _newPool.stakedToken = _stakedToken;
        _newPool.allocPoint = _allocPoint;
        _newPool.totalAmount = 0;
        _newPool.totalStakedAddress = 0;
        poolInfo.push(_newPool);
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        pidOfPool[address(_stakedToken)] = poolInfo.length.sub(1);
        emit PoolAdded(poolInfo.length - 1, address(_stakedToken), _allocPoint);
    }
    
    function setPool(
        uint256 _pid, 
        uint256 _allocPoint, 
        bool _withUpdate    
    ) external onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint;
        emit PoolSetted(_pid, address(poolInfo[_pid].stakedToken), _allocPoint);
    }
    
    function setRewardCycle(uint256 cycle) external onlyOwner {
        rewardCycle = cycle;
    }
    
    function setLockedTime(uint256 time) external onlyOwner {
        lockedTime = time;
    }
    
    function setPhase1Time(uint256 time) external onlyOwner {
        phase1Time = time;
    }
    
    function setPhase2Time(uint256 time) external onlyOwner {
        phase2Time = time;
    }
    
    function setPenlatyRatio1(uint256 ratio) external onlyOwner {
        PENLATY_RATIO1 = ratio;
    }
    
    function setPenlatyRatio2(uint256 ratio) external onlyOwner {
        PENLATY_RATIO2 = ratio;
    }
    
    function setPenlatyRatio3(uint256 ratio) external onlyOwner {
        PENLATY_RATIO3 = ratio;
    }
    
    function setBlockSpeed(uint256 speed) external onlyOwner {
        blockSpeed = speed;
    }
    
    // Withdraw Token rewards for emergency 
    function emergencyWithdrawRewards(uint256 rid) external onlyOwner {
        _safeTokenTransfer(rewardTokenInfo[rid].rewardToken, msg.sender, rewardTokenInfo[rid].rewardToken.balanceOf(address(this)));
    }
    
    function setDecimalsOfRewardToken(uint256 rid, uint256 _decimals) external onlyOwner {
        RewardTokenInfo storage rewardToken = rewardTokenInfo[rid];
        rewardToken.decimals = _decimals;
    }
    
    function setSymbolOfRewardToken(uint256 rid, string memory _symbol) external onlyOwner {
        RewardTokenInfo storage rewardToken = rewardTokenInfo[rid];
        rewardToken.symbol = _symbol;
    }

    function addRewardToken(
        uint256 _startTime,
        address _rewardToken,
        uint256 _decimals,
        string memory _symbol
    ) external onlySetter {
        require(_startTime > block.timestamp, "MultiRewardTokenPool: invalid start time");
        require(_rewardToken != address(poolInfo[0].stakedToken), "MultiRewardTokenPool: can't add DOG to be reward token");
        require(!isExistedRewardToken[_rewardToken], "MultiRewardTokenPool: existed reward token");
        massUpdatePools();
        rewardTokenInfo.push(RewardTokenInfo({
            rewardToken: IERC20(_rewardToken),
            decimals: _decimals,
            symbol: _symbol,
            magicNumber: 10 ** (30 - _decimals),
            startBlock: block.number + (_startTime - block.timestamp) / blockSpeed,
            endBlock: block.number + (_startTime - block.timestamp) / blockSpeed,
            rewardPerBlock: 0,
            tokenRemaining: 0,
            tokenRewarded: 0,
            rid: rewardTokenInfo.length
        }));
        ridOfReward[_rewardToken] = rewardTokenInfo.length - 1;
        setterOfRid[rewardTokenInfo.length - 1] = msg.sender;
        isExistedRewardToken[_rewardToken] = true;
        emit RewardTokenAdded(_rewardToken, _decimals, rewardTokenInfo.length - 1);
    }
    
    // Deposit new reward of Token and update TokenPerBlock by rid filter
    function depoistRewardToken(uint256 amount, uint256 rid) onlySetter external {
        require(setterOfRid[rid] == msg.sender, "MultiRewardTokenPool: incorrect setter of this reward token pool");
        massUpdatePools();
        RewardTokenInfo storage token = rewardTokenInfo[rid];
        uint256 prevBal = token.rewardToken.balanceOf(address(this));
        uint256 amountUnit = 10 ** token.decimals;
        token.rewardToken.safeTransferFrom(address(msg.sender), address(this), amount * amountUnit);
        uint256 currBal = token.rewardToken.balanceOf(address(this));
        require((currBal - prevBal) == amount * amountUnit, "MultiRewardTokenPool: incorrect balance after depositing");
        token.tokenRemaining = token.tokenRemaining.add(amount * amountUnit);
        token.rewardPerBlock = token.tokenRemaining.div(rewardCycle.div(blockSpeed));
        token.endBlock = block.number.add(rewardCycle.div(blockSpeed));
    }
}