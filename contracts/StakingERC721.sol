// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IStakingERC721} from "./interfaces/IStakingERC721.sol";

error ZeroValue();
error NoTokenIds();
error WaitToFinish();
error NotTokenOwner();
error NotEnoughBalance();
error TooHighReward();
error FailedToWithdrawStaking();
error NotHaveReward();

/**
 * Stakes tokens for a certain duration and gets rewards according to their
 * staked shares
 */
contract StakingERC721 is
    IStakingERC721,
    IERC721Receiver,
    Ownable,
    Pausable,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;

    IERC721 public stakingToken;
    IERC20 public rewardsToken;
    uint256 public periodFinish;
    uint256 public rewardRate;
    uint256 public rewardsDuration = 7 days;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;

    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    uint256 public totalSupply;
    mapping(address => uint256) public balances;
    mapping(uint256 => address) public stakedAssets;

    uint256 public stakingFee; // New variable to represent staking fee

    event Staked(address indexed account, uint256 amount, uint256[] tokenIds);
    event Unstaked(address indexed account, uint256 amount, uint256[] tokenIds);
    event Claimed(address indexed account, uint256 amount);
    event Funded(uint256 amount);
    event RewardsDurationUpdated(uint256 duration);
    event Recovered(address token, uint256 amount);

    modifier updateReward(address account) {
        if (account != address(0)) {
            rewardPerTokenStored = _rewardPerToken();
            lastUpdateTime = _lastTimeRewardApplicable();
            rewards[account] = _earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    constructor(
        address rewardsToken_,
        address stakingToken_,
        uint256 duration,
        address initialOwner
    )Ownable(initialOwner)  {
        if (
            rewardsToken_ == address(0) ||
            stakingToken_ == address(0) ||
            duration == 0
        ) {
            revert ZeroValue();
        }
        rewardsToken = IERC20(rewardsToken_);
        stakingToken = IERC721(stakingToken_);
        rewardsDuration = duration;
    }

    function setPaused(bool newPaused) external onlyOwner {
        if (newPaused) {
            _pause();
        } else {
            _unpause();
        }
    }

    function setRewardsDuration(uint256 duration) external onlyOwner {
        if (duration == 0) {
            revert ZeroValue();
        }
        if (block.timestamp < periodFinish) {
            revert WaitToFinish();
        }
        rewardsDuration = duration;
        emit RewardsDurationUpdated(duration);
    }

    function setStakingFee(uint256 fee) external onlyOwner {
        stakingFee = fee;
    }

    function stake(uint256[] memory tokenIds) public override nonReentrant whenNotPaused updateReward(msg.sender) {
        if (tokenIds.length == 0) {
            revert NoTokenIds();
        }

        uint256 i;
        uint256 amount;
        uint256 length = tokenIds.length;
        for (; i < length; ) {
            stakedAssets[tokenIds[i]] = msg.sender;
            stakingToken.safeTransferFrom(
                msg.sender,
                address(this),
                tokenIds[i]
            );
            unchecked {
                ++i;
                ++amount;
            }
        }

        if (stakingFee > 0) {
            if (stakingToken.balanceOf(msg.sender) < stakingFee) {
                revert NotEnoughBalance();
            }
            stakingToken.safeTransferFrom(msg.sender, owner(), stakingFee);
        }

        _stake(amount);
        emit Staked(msg.sender, amount, tokenIds);
    }

    function unstake(uint256[] memory tokenIds) public override nonReentrant whenNotPaused updateReward(msg.sender) {
        if (tokenIds.length == 0) {
            revert NoTokenIds();
        }

        uint256 i;
        uint256 amount;
        uint256 length = tokenIds.length;
        for (; i < length; ) {
            if (stakedAssets[tokenIds[i]] != msg.sender) {
                revert NotTokenOwner();
            }
            stakedAssets[tokenIds[i]] = address(0);
            stakingToken.safeTransferFrom(
                address(this),
                msg.sender,
                tokenIds[i]
            );
            unchecked {
                ++amount;
                ++i;
            }
        }
        _unstake(amount);

        emit Unstaked(msg.sender, amount, tokenIds);
    }

    function claim() public override nonReentrant whenNotPaused updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        if (reward == 0) {
            revert NotHaveReward();
        }
        rewards[msg.sender] = 0;
        rewardsToken.safeTransfer(msg.sender, reward);
        emit Claimed(msg.sender, reward);
    }

    function exit(uint256[] memory tokenIds) external override whenNotPaused {
        unstake(tokenIds);
        claim();
    }

    function fund(uint256 reward) external onlyOwner nonReentrant whenNotPaused updateReward(address(0)) {
        if (block.timestamp >= periodFinish) {
            rewardRate = reward / rewardsDuration;
        } else {
            uint256 remaining = periodFinish - block.timestamp;
            uint256 leftover = remaining * rewardRate;
            rewardRate = (reward + leftover) / rewardsDuration;
        }

        rewardsToken.safeTransferFrom(msg.sender, address(this), reward);
        uint256 balance = rewardsToken.balanceOf(address(this));
        if (rewardRate > balance / rewardsDuration) {
            revert TooHighReward();
        }

        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + rewardsDuration;

        emit Funded(reward);
    }

    function recoverERC20(address tokenAddress, uint256 tokenAmount) external onlyOwner {
        if (tokenAddress == address(stakingToken)) {
            revert FailedToWithdrawStaking();
        }
        IERC20(tokenAddress).safeTransfer(owner(), tokenAmount);
        emit Recovered(tokenAddress, tokenAmount);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function balanceOf(address account) external view override returns (uint256) {
        return balances[account];
    }

    function lastTimeRewardApplicable() external view override returns (uint256) {
        return _lastTimeRewardApplicable();
    }

    function rewardPerToken() external view override returns (uint256) {
        return _rewardPerToken();
    }

    function earned(address account) external view override returns (uint256) {
        return _earned(account);
    }

    function getRewardForDuration() external view override returns (uint256) {
        return rewardRate * rewardsDuration;
    }

    function _lastTimeRewardApplicable() internal view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    function _rewardPerToken() internal view returns (uint256) {
        if (totalSupply == 0) {
            return rewardPerTokenStored;
        }
        return rewardPerTokenStored +
            ((_lastTimeRewardApplicable() - lastUpdateTime) * rewardRate * 1e18) /
            totalSupply;
    }

    function _earned(address account) internal view returns (uint256) {
        return (balances[account] * (_rewardPerToken() - userRewardPerTokenPaid[account])) / 1e18 + rewards[account];
    }

    function _stake(uint256 _amount) internal {
        totalSupply = totalSupply + _amount;
        balances[msg.sender] += _amount;
    }

    function _unstake(uint256 _amount) internal {
        totalSupply = totalSupply - _amount;
        balances[msg.sender] -= _amount;
    }
}
