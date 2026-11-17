// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IStrategy} from "./interfaces/IStrategy.sol";

/// @title KassoraVault
/// @notice ERC-4626 vault that routes a single asset (e.g. USDG) into a set of capped strategies.
/// @dev Roles:
///      - owner (Ownable2Step): sets roles, fee, timelock. Should be a multisig.
///      - curator: adds strategies (timelocked), sets caps, allocates/deallocates, orders the withdraw queue.
///      - guardian: pauses deposits, revokes pending changes, triggers emergency exits.
///      Risk-increasing changes (new strategy, higher cap, higher fee, shorter timelock) wait `timelock` seconds.
///      Risk-reducing changes apply immediately. Withdrawals are never paused.
///      Fees: charged on any rise in totalAssets since the last accrual. There is no high-water mark,
///      so after a loss the recovery is also charged (same model as Morpho MetaMorpho V1).
///      Inflation attack: mitigated by OpenZeppelin virtual shares (`_decimalsOffset`).
contract KassoraVault is ERC4626, Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;
    using SafeCast for uint256;

    /* -------------------------------------------------------------------------- */
    /*                                  CONSTANTS                                 */
    /* -------------------------------------------------------------------------- */

    uint256 internal constant WAD = 1e18;
    /// @notice Hard ceiling on the performance fee: 30% of profit. Enforced on-chain.
    uint256 public constant MAX_FEE = 0.3e18;
    uint256 public constant MIN_TIMELOCK = 1 days;
    uint256 public constant MAX_TIMELOCK = 2 weeks;
    uint256 public constant MAX_STRATEGIES = 10;
    uint8 public constant MAX_DECIMALS_OFFSET = 18;

    /* -------------------------------------------------------------------------- */
    /*                                   STORAGE                                  */
    /* -------------------------------------------------------------------------- */

    struct InitParams {
        IERC20 asset;
        string name;
        string symbol;
        address owner;
        address curator;
        address guardian;
        address feeRecipient;
        uint256 timelock; // 0 allowed only here (bootstrap); raise it before opening deposits
        uint256 depositCap;
        uint8 decimalsOffset;
    }

    struct StrategyConfig {
        uint192 cap;
        bool enabled;
    }

    struct Pending {
        uint192 value;
        uint64 validAt; // 0 = nothing pending
    }

    uint8 private immutable _offset;

    address public curator;
    address public guardian;
    address public feeRecipient;

    uint256 public fee;
    uint256 public timelock;
    uint256 public depositCap;
    /// @notice totalAssets() at the last fee accrual. Profit above this is subject to `fee`.
    uint256 public lastTotalAssets;

    mapping(IStrategy => StrategyConfig) public config;
    mapping(IStrategy => Pending) public pendingCap;
    Pending public pendingTimelock;
    Pending public pendingFee;

    /// @notice Enabled strategies, in the order liquidity is pulled on withdraw.
    IStrategy[] public withdrawQueue;

    /* -------------------------------------------------------------------------- */
    /*                                   EVENTS                                   */
    /* -------------------------------------------------------------------------- */

    event SetCurator(address indexed curator);
    event SetGuardian(address indexed guardian);
    event SetFeeRecipient(address indexed feeRecipient);
    event SetDepositCap(uint256 depositCap);
    event SubmitTimelock(uint256 newTimelock, uint256 validAt);
    event SetTimelock(uint256 newTimelock);
    event SubmitFee(uint256 newFee, uint256 validAt);
    event SetFee(uint256 newFee);
    event SubmitCap(IStrategy indexed strategy, uint256 cap, uint256 validAt);
    event SetCap(IStrategy indexed strategy, uint256 cap);
    event StrategyAdded(IStrategy indexed strategy);
    event StrategyRemoved(IStrategy indexed strategy);
    event SetWithdrawQueue(IStrategy[] queue);
    event Allocate(IStrategy indexed strategy, uint256 assets);
    event Deallocate(IStrategy indexed strategy, uint256 requested, uint256 withdrawn);
    event EmergencyExit(IStrategy indexed strategy, uint256 withdrawn);
    event ForceRemoveStrategy(IStrategy indexed strategy);
    event RevokePendingCap(IStrategy indexed strategy);
    event RevokePendingTimelock();
    event RevokePendingFee();
    event AccrueFee(uint256 newTotalAssets, uint256 feeShares);

    /* -------------------------------------------------------------------------- */
    /*                                   ERRORS                                   */
    /* -------------------------------------------------------------------------- */

    error NotCuratorRole();
    error NotGuardianRole();
    error ZeroAddress();
    error AlreadySet();
    error AlreadyPending();
    error NoPendingValue();
    error TimelockNotElapsed();
    error TimelockOutOfBounds();
    error FeeTooHigh();
    error FeeRecipientNotSet();
    error InvalidStrategy();
    error StrategyNotEnabled();
    error StrategyCapExceeded();
    error StrategyNotEmpty();
    error MaxStrategiesReached();
    error InvalidQueue();
    error InsufficientLiquidity();
    error DecimalsOffsetTooHigh();

    /* -------------------------------------------------------------------------- */
    /*                                  MODIFIERS                                 */
    /* -------------------------------------------------------------------------- */

    modifier onlyCuratorRole() {
        if (msg.sender != curator && msg.sender != owner()) revert NotCuratorRole();
        _;
    }

    modifier onlyGuardianRole() {
        if (msg.sender != guardian && msg.sender != owner()) revert NotGuardianRole();
        _;
    }

    modifier afterTimelock(uint256 validAt) {
        if (validAt == 0) revert NoPendingValue();
        if (block.timestamp < validAt) revert TimelockNotElapsed();
        _;
    }

    /* -------------------------------------------------------------------------- */
    /*                                 CONSTRUCTOR                                */
    /* -------------------------------------------------------------------------- */

    constructor(InitParams memory p) ERC4626(p.asset) ERC20(p.name, p.symbol) Ownable(p.owner) {
        if (p.decimalsOffset > MAX_DECIMALS_OFFSET) revert DecimalsOffsetTooHigh();
        if (p.timelock != 0 && (p.timelock < MIN_TIMELOCK || p.timelock > MAX_TIMELOCK)) {
            revert TimelockOutOfBounds();
        }
        _offset = p.decimalsOffset;
        curator = p.curator;
        guardian = p.guardian;
        feeRecipient = p.feeRecipient;
        timelock = p.timelock;
        depositCap = p.depositCap;

        emit SetCurator(p.curator);
        emit SetGuardian(p.guardian);
        emit SetFeeRecipient(p.feeRecipient);
        emit SetTimelock(p.timelock);
        emit SetDepositCap(p.depositCap);
    }

    /* -------------------------------------------------------------------------- */
    /*                                 OWNER ONLY                                 */
    /* -------------------------------------------------------------------------- */

    function setCurator(address newCurator) external onlyOwner {
        if (newCurator == curator) revert AlreadySet();
        curator = newCurator;
        emit SetCurator(newCurator);
    }

    function setGuardian(address newGuardian) external onlyOwner {
        if (newGuardian == guardian) revert AlreadySet();
        guardian = newGuardian;
        emit SetGuardian(newGuardian);
    }

    function setFeeRecipient(address newFeeRecipient) external onlyOwner {
        if (newFeeRecipient == feeRecipient) revert AlreadySet();
        if (newFeeRecipient == address(0) && fee != 0) revert ZeroAddress();
        _accrueFee(); // fees earned so far go to the old recipient
        feeRecipient = newFeeRecipient;
        emit SetFeeRecipient(newFeeRecipient);
    }

    /// @notice Longer timelock applies now. Shorter timelock waits the current timelock.
    function submitTimelock(uint256 newTimelock) external onlyOwner {
        if (newTimelock == timelock) revert AlreadySet();
        if (pendingTimelock.validAt != 0) revert AlreadyPending();
        if (newTimelock < MIN_TIMELOCK || newTimelock > MAX_TIMELOCK) revert TimelockOutOfBounds();

        if (newTimelock > timelock) {
            _setTimelock(newTimelock);
        } else {
            uint64 validAt = (block.timestamp + timelock).toUint64();
            pendingTimelock = Pending(newTimelock.toUint192(), validAt);
            emit SubmitTimelock(newTimelock, validAt);
        }
    }

    function acceptTimelock() external afterTimelock(pendingTimelock.validAt) {
        _setTimelock(pendingTimelock.value);
    }

    /// @notice Lower fee applies now. Higher fee waits the timelock. Never above MAX_FEE.
    function submitFee(uint256 newFee) external onlyOwner {
        if (newFee == fee) revert AlreadySet();
        if (newFee > MAX_FEE) revert FeeTooHigh();
        if (pendingFee.validAt != 0) revert AlreadyPending();
        if (newFee != 0 && feeRecipient == address(0)) revert FeeRecipientNotSet();

        if (newFee < fee) {
            _setFee(newFee);
        } else {
            uint64 validAt = (block.timestamp + timelock).toUint64();
            pendingFee = Pending(newFee.toUint192(), validAt);
            emit SubmitFee(newFee, validAt);
        }
    }

    function acceptFee() external afterTimelock(pendingFee.validAt) {
        if (feeRecipient == address(0)) revert FeeRecipientNotSet();
        _setFee(pendingFee.value);
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /* -------------------------------------------------------------------------- */
    /*                                CURATOR ROLE                                */
    /* -------------------------------------------------------------------------- */

    function setDepositCap(uint256 newDepositCap) external onlyCuratorRole {
        if (newDepositCap == depositCap) revert AlreadySet();
        depositCap = newDepositCap;
        emit SetDepositCap(newDepositCap);
    }

    /// @notice Lowering a cap applies now. Raising a cap, or adding a new strategy, waits the timelock.
    function submitCap(IStrategy strategy, uint256 newCap) external onlyCuratorRole {
        if (strategy.vault() != address(this) || strategy.asset() != asset()) revert InvalidStrategy();
        if (pendingCap[strategy].validAt != 0) revert AlreadyPending();

        StrategyConfig storage cfg = config[strategy];
        if (newCap == cfg.cap) revert AlreadySet();

        if (newCap < cfg.cap) {
            cfg.cap = newCap.toUint192();
            emit SetCap(strategy, newCap);
        } else {
            uint64 validAt = (block.timestamp + timelock).toUint64();
            pendingCap[strategy] = Pending(newCap.toUint192(), validAt);
            emit SubmitCap(strategy, newCap, validAt);
        }
    }

    function acceptCap(IStrategy strategy) external afterTimelock(pendingCap[strategy].validAt) {
        StrategyConfig storage cfg = config[strategy];
        if (!cfg.enabled) {
            if (withdrawQueue.length >= MAX_STRATEGIES) revert MaxStrategiesReached();
            cfg.enabled = true;
            withdrawQueue.push(strategy);
            emit StrategyAdded(strategy);
        }
        cfg.cap = pendingCap[strategy].value;
        delete pendingCap[strategy];
        emit SetCap(strategy, cfg.cap);
    }

    /// @notice Remove an emptied strategy. Set its cap to 0 and deallocate everything first.
    function removeStrategy(IStrategy strategy) external onlyCuratorRole {
        StrategyConfig storage cfg = config[strategy];
        if (!cfg.enabled) revert StrategyNotEnabled();
        if (cfg.cap != 0 || strategy.totalAssets() != 0) revert StrategyNotEmpty();

        _removeFromQueue(strategy);
    }

    /// @notice Reorder the withdraw queue. Must be a permutation of the current queue.
    function setWithdrawQueue(IStrategy[] calldata newQueue) external onlyCuratorRole {
        uint256 len = withdrawQueue.length;
        if (newQueue.length != len) revert InvalidQueue();
        for (uint256 i; i < len; ++i) {
            if (!config[newQueue[i]].enabled) revert InvalidQueue();
            for (uint256 j = i + 1; j < len; ++j) {
                if (newQueue[i] == newQueue[j]) revert InvalidQueue();
            }
        }
        withdrawQueue = newQueue;
        emit SetWithdrawQueue(newQueue);
    }

    /// @notice Move idle assets into a strategy, within its cap.
    function allocate(IStrategy strategy, uint256 assets) external onlyCuratorRole whenNotPaused nonReentrant {
        StrategyConfig memory cfg = config[strategy];
        if (!cfg.enabled) revert StrategyNotEnabled();
        if (strategy.totalAssets() + assets > cfg.cap) revert StrategyCapExceeded();

        _accrueFee();
        IERC20(asset()).safeTransfer(address(strategy), assets);
        strategy.deposit(assets);
        emit Allocate(strategy, assets);
    }

    /// @notice Pull assets from a strategy back to the vault as idle.
    function deallocate(IStrategy strategy, uint256 assets) external onlyCuratorRole nonReentrant {
        if (!config[strategy].enabled) revert StrategyNotEnabled();
        _accrueFee();
        uint256 withdrawn = strategy.withdraw(assets, address(this));
        emit Deallocate(strategy, assets, withdrawn);
    }

    /* -------------------------------------------------------------------------- */
    /*                                GUARDIAN ROLE                               */
    /* -------------------------------------------------------------------------- */

    function pause() external onlyGuardianRole {
        _pause();
    }

    function revokePendingCap(IStrategy strategy) external {
        if (msg.sender != guardian && msg.sender != curator && msg.sender != owner()) revert NotGuardianRole();
        if (pendingCap[strategy].validAt == 0) revert NoPendingValue();
        delete pendingCap[strategy];
        emit RevokePendingCap(strategy);
    }

    function revokePendingTimelock() external onlyGuardianRole {
        if (pendingTimelock.validAt == 0) revert NoPendingValue();
        delete pendingTimelock;
        emit RevokePendingTimelock();
    }

    function revokePendingFee() external onlyGuardianRole {
        if (pendingFee.validAt == 0) revert NoPendingValue();
        delete pendingFee;
        emit RevokePendingFee();
    }

    /// @notice Zero a strategy's cap and pull everything out of it. Use when a strategy is compromised.
    function emergencyExit(IStrategy strategy) external onlyGuardianRole nonReentrant {
        StrategyConfig storage cfg = config[strategy];
        if (!cfg.enabled) revert StrategyNotEnabled();
        _accrueFee();
        cfg.cap = 0;
        delete pendingCap[strategy];
        emit SetCap(strategy, 0);
        uint256 withdrawn = strategy.withdrawAll(address(this));
        emit EmergencyExit(strategy, withdrawn);
    }

    /// @notice Drop a strategy whose views revert, without calling it. Also pauses deposits.
    /// @dev Its assets stop counting in totalAssets(), so the share price drops until it is fixed.
    ///      Nothing is lost: ERC4626Strategy has no admin, so re-adding the same strategy (submitCap +
    ///      timelock) restores its assets. Deposits are paused so nobody can buy shares at the
    ///      written-down price and profit when the strategy is re-added.
    function forceRemoveStrategy(IStrategy strategy) external onlyGuardianRole {
        if (!config[strategy].enabled) revert StrategyNotEnabled();
        _removeFromQueue(strategy);
        if (!paused()) _pause();
        emit SetCap(strategy, 0);
        emit ForceRemoveStrategy(strategy);
    }

    /* -------------------------------------------------------------------------- */
    /*                                   PUBLIC                                   */
    /* -------------------------------------------------------------------------- */

    function accrueFee() external nonReentrant {
        _accrueFee();
    }

    function withdrawQueueLength() external view returns (uint256) {
        return withdrawQueue.length;
    }

    /// @notice Assets sitting in the vault, not allocated to any strategy.
    function idleAssets() public view returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    /// @notice Assets withdrawable right now: idle plus what every strategy can release.
    function availableLiquidity() public view returns (uint256 liquidity) {
        liquidity = idleAssets();
        uint256 len = withdrawQueue.length;
        for (uint256 i; i < len; ++i) {
            try withdrawQueue[i].maxWithdraw() returns (uint256 m) {
                liquidity += m;
            } catch {}
        }
    }

    /* -------------------------------------------------------------------------- */
    /*                               ERC-4626 VIEWS                               */
    /* -------------------------------------------------------------------------- */

    function totalAssets() public view override returns (uint256 assets) {
        assets = idleAssets();
        uint256 len = withdrawQueue.length;
        for (uint256 i; i < len; ++i) {
            assets += withdrawQueue[i].totalAssets();
        }
    }

    function maxDeposit(address) public view override returns (uint256) {
        if (paused()) return 0;
        uint256 assets = totalAssets();
        return depositCap > assets ? depositCap - assets : 0;
    }

    function maxMint(address receiver) public view override returns (uint256) {
        return _convertToShares(maxDeposit(receiver), Math.Rounding.Floor);
    }

    function maxWithdraw(address owner_) public view override returns (uint256) {
        return Math.min(_convertToAssets(balanceOf(owner_), Math.Rounding.Floor), availableLiquidity());
    }

    function maxRedeem(address owner_) public view override returns (uint256) {
        return Math.min(balanceOf(owner_), _convertToShares(availableLiquidity(), Math.Rounding.Floor));
    }

    /* -------------------------------------------------------------------------- */
    /*                             ERC-4626 MUTATIONS                             */
    /* -------------------------------------------------------------------------- */

    function deposit(uint256 assets, address receiver) public override nonReentrant returns (uint256) {
        _accrueFee();
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver) public override nonReentrant returns (uint256) {
        _accrueFee();
        return super.mint(shares, receiver);
    }

    function withdraw(uint256 assets, address receiver, address owner_) public override nonReentrant returns (uint256) {
        _accrueFee();
        return super.withdraw(assets, receiver, owner_);
    }

    function redeem(uint256 shares, address receiver, address owner_) public override nonReentrant returns (uint256) {
        _accrueFee();
        return super.redeem(shares, receiver, owner_);
    }

    /* -------------------------------------------------------------------------- */
    /*                                  INTERNAL                                  */
    /* -------------------------------------------------------------------------- */

    function _decimalsOffset() internal view override returns (uint8) {
        return _offset;
    }

    /// @dev Share math includes fee shares that would be minted if fees were accrued now,
    ///      so previews match what deposit/withdraw actually do.
    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view override returns (uint256) {
        (uint256 feeShares, uint256 newTotalAssets) = _accruedFeeShares();
        return assets.mulDiv(totalSupply() + feeShares + 10 ** _decimalsOffset(), newTotalAssets + 1, rounding);
    }

    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view override returns (uint256) {
        (uint256 feeShares, uint256 newTotalAssets) = _accruedFeeShares();
        return shares.mulDiv(newTotalAssets + 1, totalSupply() + feeShares + 10 ** _decimalsOffset(), rounding);
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        super._deposit(caller, receiver, assets, shares);
        lastTotalAssets += assets;
    }

    function _withdraw(address caller, address receiver, address owner_, uint256 assets, uint256 shares)
        internal
        override
    {
        _pullLiquidity(assets);
        lastTotalAssets = lastTotalAssets > assets ? lastTotalAssets - assets : 0;
        super._withdraw(caller, receiver, owner_, assets, shares);
    }

    /// @dev Pull from strategies in queue order until `assets` are idle. A reverting strategy is skipped
    ///      so a single broken integration cannot block every withdrawal.
    function _pullLiquidity(uint256 assets) internal {
        uint256 idle = idleAssets();
        if (idle >= assets) return;

        uint256 len = withdrawQueue.length;
        for (uint256 i; i < len && idle < assets; ++i) {
            try withdrawQueue[i].withdraw(assets - idle, address(this)) {} catch {}
            idle = idleAssets();
        }
        if (idle < assets) revert InsufficientLiquidity();
    }

    function _accruedFeeShares() internal view returns (uint256 feeShares, uint256 newTotalAssets) {
        newTotalAssets = totalAssets();
        uint256 last = lastTotalAssets;
        if (fee == 0 || newTotalAssets <= last) return (0, newTotalAssets);

        uint256 feeAssets = (newTotalAssets - last).mulDiv(fee, WAD);
        feeShares = feeAssets.mulDiv(
            totalSupply() + 10 ** _decimalsOffset(), newTotalAssets - feeAssets + 1, Math.Rounding.Floor
        );
    }

    function _accrueFee() internal {
        (uint256 feeShares, uint256 newTotalAssets) = _accruedFeeShares();
        if (feeShares != 0) _mint(feeRecipient, feeShares);
        lastTotalAssets = newTotalAssets;
        emit AccrueFee(newTotalAssets, feeShares);
    }

    function _removeFromQueue(IStrategy strategy) internal {
        delete config[strategy];
        delete pendingCap[strategy];

        uint256 len = withdrawQueue.length;
        for (uint256 i; i < len; ++i) {
            if (withdrawQueue[i] == strategy) {
                withdrawQueue[i] = withdrawQueue[len - 1];
                withdrawQueue.pop();
                break;
            }
        }
        emit StrategyRemoved(strategy);
    }

    function _setTimelock(uint256 newTimelock) internal {
        timelock = newTimelock;
        delete pendingTimelock;
        emit SetTimelock(newTimelock);
    }

    function _setFee(uint256 newFee) internal {
        _accrueFee(); // profit so far is charged at the old rate
        fee = newFee;
        delete pendingFee;
        emit SetFee(newFee);
    }
}
