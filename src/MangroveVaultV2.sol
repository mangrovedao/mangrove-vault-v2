// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Mangrove
import {IMangrove, Local, OLKey} from "@mgv/src/IMangrove.sol";
import {Tick} from "@mgv/lib/core/TickLib.sol";
import {MAX_SAFE_VOLUME, MAX_TICK} from "@mgv/lib/core/Constants.sol";

// Mangrove Strategies
import {AbstractKandelSeeder} from
    "@mgv-strats/src/strategies/offer_maker/market_making/kandel/abstract/AbstractKandelSeeder.sol";
import {GeometricKandel} from "@mgv-strats/src/strategies/offer_maker/market_making/kandel/abstract/GeometricKandel.sol";
import {DirectWithBidsAndAsksDistribution} from
    "@mgv-strats/src/strategies/offer_maker/market_making/kandel/abstract/DirectWithBidsAndAsksDistribution.sol";
import {CoreKandel} from "@mgv-strats/src/strategies/offer_maker/market_making/kandel/abstract/CoreKandel.sol";
import {
    OfferType, KandelLib
} from "@mgv-strats/src/strategies/offer_maker/market_making/kandel/abstract/KandelLib.sol";

// OpenZeppelin
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

// Solady
import {FixedPointMathLib} from "@solady/src/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "@solady/src/utils/SafeTransferLib.sol";
import {ReentrancyGuard} from "@solady/src/utils/ReentrancyGuard.sol";
import {Ownable} from "@solady/src/auth/Ownable.sol";
import {SafeCastLib} from "@solady/src/utils/SafeCastLib.sol";
import {ERC20} from "@solady/src/tokens/ERC20.sol";

// Local dependencies
import {GeometricKandelExtra, Params} from "@mangrove-vault/src/lib/GeometricKandelExtra.sol";
import {IOracle} from "@mangrove-vault/src/oracles/IOracle.sol";
import {MangroveLib} from "@mangrove-vault/src/lib/MangroveLib.sol";
import {MangroveVaultConstants} from "@mangrove-vault/src/lib/MangroveVaultConstants.sol";
import {MangroveVaultErrors} from "@mangrove-vault/src/lib/MangroveVaultErrors.sol";
import {MangroveVaultEvents} from "@mangrove-vault/src/lib/MangroveVaultEvents.sol";
import {MangroveVaultV2Errors} from "./lib/MangroveVaultV2Errors.sol";
import {MangroveVaultV2Events} from "./lib/MangroveVaultV2Events.sol";
import {FundsState, KandelPosition} from "@mangrove-vault/src/MangroveVault.sol";

/**
 * @notice Oracle configuration struct packed into a single storage slot
 * @dev Total size: 320 bits (32 bytes)
 * @param isStatic Whether oracle is in static mode (8 bits)
 * @param maxTickDeviation Maximum allowed tick deviation (24 bits)
 * @param timelock Timelock duration for oracle changes (24 bits)
 * @param staticValue Static tick value for oracle-less mode (24 bits)
 * @param proposedAt Timestamp when current oracle was proposed (32 bits)
 * @param oracle Oracle contract address (160 bits)
 */
struct Oracle {
    bool isStatic; // 8 bits
    uint24 maxTickDeviation; // 24 bits
    uint24 timelock; // 24 bits
    int24 staticValue; // 24 bits
    uint32 proposedAt; // 32 bits
    address oracle; // 160 bits
}

/**
 * @notice Rebalance parameters struct
 * @param sell Whether to sell (true) or buy (false)
 * @param amount Amount to swap
 * @param minOut Minimum amount to receive
 * @param target Target contract for swap
 * @param data Calldata for swap
 */
struct RebalanceParams {
    bool sell;
    uint256 amount;
    uint256 minOut;
    address target;
    bytes data;
}

contract MangroveVaultV2 is Ownable, ERC20, Pausable, ReentrancyGuard {
    using SafeTransferLib for address;
    using Address for address;
    using SafeCastLib for uint256;
    using SafeCastLib for int256;
    using FixedPointMathLib for int256;
    using Math for uint256;
    using GeometricKandelExtra for GeometricKandel;
    using MangroveLib for IMangrove;

    /// @notice The GeometricKandel contract instance used for market making.
    GeometricKandel public immutable kandel;

    /// @notice The AbstractKandelSeeder contract instance used to initialize the Kandel contract.
    AbstractKandelSeeder public seeder;

    /// @notice The Mangrove deployment.
    IMangrove public immutable MGV;

    /// @notice The address of the first token in the token pair.
    address internal immutable BASE;

    /// @notice The address of the second token in the token pair.
    address internal immutable QUOTE;

    /// @notice The tick spacing for the Mangrove market.
    uint256 internal immutable TICK_SPACING;

    /// @notice The factor to scale the quote token amount by at initial mint.
    uint256 internal immutable QUOTE_SCALE;

    /// @notice The number of decimals of the LP token.
    uint8 internal immutable DECIMALS;

    /// @notice The name of the LP token.
    string internal NAME;

    /// @notice The symbol of the LP token.
    string internal SYMBOL;

    /// @notice Maximum base token amount allowed in the vault
    uint256 public immutable MAX_BASE;

    /// @notice Maximum quote token amount allowed in the vault
    uint256 public immutable MAX_QUOTE;

    /// @notice Oracle configuration
    Oracle public oracle;

    /// @notice A mapping to track which swap contracts are allowed.
    mapping(address => bool) public allowedSwapContracts;

    /**
     * @notice The current state of the vault
     * @dev This struct is packed into multiple storage slots
     * @param inKandel Whether the funds are currently in Kandel
     * @param feeRecipient The address of the fee recipient
     * @param managementFee The management fee (applied globally)
     * @param lastFeeAccrualTime Timestamp of last global fee accrual
     */
    struct State {
        bool inKandel; // 8 bits
        address feeRecipient; // + 160 bits = 168 bits
        uint16 managementFee; // + 16 bits = 184 bits
        uint64 lastFeeAccrualTime; // + 64 bits = 248 bits
        // Next storage slot
        bool isInKandel; // Additional field for funds state
        int24 tickIndex0; // Additional field for tick index
        int24 bestBid;
        int24 bestAsk;
    }

    /// @notice The current state of the vault.
    State internal _state;

    /// @notice The address of the manager of the vault.
    address public manager;

    /// @notice The address of the guardian who can dispute position updates.
    address public guardian;

    modifier onlyManager() {
        if (msg.sender != manager) {
            revert MangroveVaultErrors.ManagerOwnerUnauthorized(msg.sender);
        }
        _;
    }

    modifier onlyGuardian() {
        if (msg.sender != guardian) {
            revert MangroveVaultV2Errors.OnlyGuardian();
        }
        _;
    }

    modifier onlyOwnerOrManager() {
        if (msg.sender != owner() && msg.sender != manager) {
            revert MangroveVaultErrors.ManagerOwnerUnauthorized(msg.sender);
        }
        _;
    }

    /**
     * @notice Constructor for the MangroveVaultV2 contract.
     */
    constructor(
        AbstractKandelSeeder _seeder,
        address _BASE,
        address _QUOTE,
        uint256 _tickSpacing,
        uint8 _decimals,
        string memory name,
        string memory symbol,
        address _owner,
        uint256 _maxBase,
        uint256 _maxQuote,
        Oracle memory _oracle
    ) {
        _initializeOwner(_owner);
        seeder = _seeder;
        TICK_SPACING = _tickSpacing;
        MGV = _seeder.MGV();
        NAME = name;
        SYMBOL = symbol;
        BASE = _BASE;
        QUOTE = _QUOTE;
        MAX_BASE = _maxBase;
        MAX_QUOTE = _maxQuote;
        kandel = _seeder.sow(OLKey(_BASE, _QUOTE, _tickSpacing), false);

        uint8 offset = _decimals - ERC20(_QUOTE).decimals();
        DECIMALS = _decimals;
        QUOTE_SCALE = 10 ** offset;

        _state.feeRecipient = _owner;
        _state.lastFeeAccrualTime = uint64(block.timestamp);
        _state.bestAsk = type(int24).max;
        _state.bestBid = type(int24).max;
        emit MangroveVaultEvents.SetFeeData(0, 0, _owner);

        manager = _owner;
        emit MangroveVaultEvents.SetManager(_owner);

        guardian = _owner;
        emit MangroveVaultV2Events.GuardianSet(_owner);

        // Initialize oracle
        oracle = _oracle;
        oracle.proposedAt = uint32(block.timestamp);
    }

    /**
     * @inheritdoc ERC20
     */
    function decimals() public view override returns (uint8) {
        return DECIMALS;
    }

    /**
     * @inheritdoc ERC20
     */
    function name() public view override returns (string memory) {
        return NAME;
    }

    /**
     * @inheritdoc ERC20
     */
    function symbol() public view override returns (string memory) {
        return SYMBOL;
    }

    /**
     * @notice Retrieves the current market information for the vault
     */
    function market() external view returns (address base, address quote, uint256 tickSpacing) {
        return (BASE, QUOTE, TICK_SPACING);
    }

    /**
     * @notice Gets the current tick based on oracle configuration
     */
    function getCurrentTick() public view returns (Tick) {
        Oracle memory _oracle = oracle;
        if (!_oracle.isStatic && _oracle.oracle != address(0)) {
            return IOracle(_oracle.oracle).tick();
        } else {
            return Tick.wrap(_oracle.staticValue);
        }
    }

    /**
     * @notice Validates a tick against the current tick and max deviation
     */
    function _validateTick(Tick proposedTick) internal view {
        Oracle memory _oracle = oracle;
        Tick currentTick = getCurrentTick();
        int24 deviation = int24(Tick.unwrap(proposedTick) - Tick.unwrap(currentTick));

        if (uint24(FixedPointMathLib.abs(deviation)) > _oracle.maxTickDeviation) {
            revert MangroveVaultV2Errors.TickDeviationExceeded();
        }
    }

    /**
     * @notice Retrieves whether funds are currently in Kandel
     */
    function inKandel() external view returns (bool) {
        return _state.inKandel;
    }

    /**
     * @notice Retrieves the current fee data for the vault
     */
    function feeData() external view returns (uint16 managementFee, address feeRecipient) {
        return (_state.managementFee, _state.feeRecipient);
    }

    /**
     * @notice Retrieves the balances of the vault for both tokens.
     */
    function getVaultBalances() public view returns (uint256 baseAmount, uint256 quoteAmount) {
        baseAmount = IERC20(BASE).balanceOf(address(this));
        quoteAmount = IERC20(QUOTE).balanceOf(address(this));
    }

    /**
     * @notice Retrieves the inferred balances of the Kandel contract for both tokens.
     */
    function getKandelBalances() public view returns (uint256 baseAmount, uint256 quoteAmount) {
        (baseAmount, quoteAmount) = kandel.getBalances();
    }

    /**
     * @notice Retrieves the total underlying balances of both tokens.
     */
    function getUnderlyingBalances() public view returns (uint256 baseAmount, uint256 quoteAmount) {
        (baseAmount, quoteAmount) = getVaultBalances();
        (uint256 kandelBaseBalance, uint256 kandelQuoteBalance) = getKandelBalances();
        baseAmount += kandelBaseBalance;
        quoteAmount += kandelQuoteBalance;
    }

    /**
     * @notice Calculates the total value of the vault's assets in quote token.
     */
    function getTotalInQuote() public view returns (uint256 quoteAmount, Tick tick) {
        uint256 baseAmount;
        (baseAmount, quoteAmount) = getUnderlyingBalances();
        tick = getCurrentTick();
        quoteAmount = quoteAmount + tick.inboundFromOutboundUp(baseAmount);
    }

    /**
     * @notice Computes the shares that can be minted and minimum amounts
     */
    function getMintAmounts(uint256 baseMax, uint256 quoteMax)
        external
        view
        returns (uint256 shares, uint256 minBaseOut, uint256 minQuoteOut)
    {
        baseMax = Math.min(baseMax, MAX_SAFE_VOLUME);
        quoteMax = Math.min(quoteMax, MAX_SAFE_VOLUME);

        uint256 _totalSupply = totalSupply();

        if (_totalSupply != 0) {
            (uint256 baseAmount, uint256 quoteAmount) = getUnderlyingBalances();

            if (baseAmount == 0 && quoteAmount != 0) {
                shares = quoteMax.mulDiv(_totalSupply, quoteAmount);
                minBaseOut = 0;
                minQuoteOut = shares.mulDiv(quoteAmount, _totalSupply);
            } else if (baseAmount != 0 && quoteAmount == 0) {
                shares = baseMax.mulDiv(_totalSupply, baseAmount);
                minBaseOut = shares.mulDiv(baseAmount, _totalSupply);
                minQuoteOut = 0;
            } else if (baseAmount != 0 && quoteAmount != 0) {
                shares = Math.min(baseMax.mulDiv(_totalSupply, baseAmount), quoteMax.mulDiv(_totalSupply, quoteAmount));
                minBaseOut = shares.mulDiv(baseAmount, _totalSupply);
                minQuoteOut = shares.mulDiv(quoteAmount, _totalSupply);
            }
        } else {
            Tick tick = getCurrentTick();

            minBaseOut = tick.outboundFromInbound(quoteMax);
            if (minBaseOut > baseMax) {
                minBaseOut = baseMax;
                minQuoteOut = tick.inboundFromOutboundUp(baseMax);
            } else {
                minQuoteOut = quoteMax;
            }

            (, shares) = ((tick.inboundFromOutboundUp(minBaseOut) + minQuoteOut) * QUOTE_SCALE).trySub(
                MangroveVaultConstants.MINIMUM_LIQUIDITY
            );
        }
    }

    /**
     * @notice Calculates the underlying token balances corresponding to a given share amount.
     */
    function getUnderlyingBalancesByShare(uint256 share)
        public
        view
        returns (uint256 baseAmount, uint256 quoteAmount)
    {
        (uint256 baseBalance, uint256 quoteBalance) = getUnderlyingBalances();
        uint256 _totalSupply = totalSupply();

        if (_totalSupply == 0) {
            return (0, 0);
        }

        baseAmount = share.mulDiv(baseBalance, _totalSupply, Math.Rounding.Floor);
        quoteAmount = share.mulDiv(quoteBalance, _totalSupply, Math.Rounding.Floor);
    }

    /**
     * @notice Accrues management fees globally based on time elapsed
     * @dev Called before any major operation to ensure fees are up to date
     */
    function _accrueManagementFees() internal {
        uint256 managementFee = _state.managementFee;
        if (managementFee == 0) return;

        uint256 lastAccrualTime = _state.lastFeeAccrualTime;
        uint256 timeElapsed = block.timestamp - lastAccrualTime;
        if (timeElapsed == 0) return;

        uint256 _totalSupply = totalSupply();
        if (_totalSupply == 0) {
            _state.lastFeeAccrualTime = uint64(block.timestamp);
            return;
        }

        // Calculate management fee shares to mint
        // Fee rate is annual, so we calculate the portion for the elapsed time
        uint256 annualFeeRate = managementFee;
        uint256 feeRate = annualFeeRate * timeElapsed / (365 days);

        // Calculate fee shares: feeShares / (totalSupply + feeShares) = feeRate / PRECISION
        // Rearranging: feeShares = (totalSupply * feeRate) / (PRECISION - feeRate)
        uint256 feeShares = _totalSupply.mulDiv(feeRate, MangroveVaultConstants.MANAGEMENT_FEE_PRECISION - feeRate);

        if (feeShares > 0) {
            _mint(_state.feeRecipient, feeShares);
            emit MangroveVaultV2Events.ManagementFeesAccrued(feeShares, timeElapsed);
        }

        _state.lastFeeAccrualTime = uint64(block.timestamp);
    }

    // Interaction functions

    function fundMangrove() external payable {
        MGV.fund{value: msg.value}(address(kandel));
    }

    /**
     * @notice Mints new shares by depositing tokens into the vault
     * @dev For initial minting, oracle must be initialized and use the oracle tick
     */
    function mint(uint256 maxBase, uint256 maxQuote, uint256 minSharesOut)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 shares)
    {
        if (maxBase == 0 && maxQuote == 0) revert MangroveVaultErrors.ZeroAmount();

        // Accrue fees before minting
        _accrueManagementFees();

        uint256 _totalSupply = totalSupply();
        Tick tick = getCurrentTick();
        uint256 baseAmount;
        uint256 quoteAmount;

        if (_totalSupply != 0) {
            // Proportional to existing position
            (uint256 baseBalance, uint256 quoteBalance) = getUnderlyingBalances();

            if (baseBalance == 0 && quoteBalance != 0) {
                shares = maxQuote.mulDiv(_totalSupply, quoteBalance);
                baseAmount = 0;
                quoteAmount = shares.mulDiv(quoteBalance, _totalSupply);
            } else if (baseBalance != 0 && quoteBalance == 0) {
                shares = maxBase.mulDiv(_totalSupply, baseBalance);
                baseAmount = shares.mulDiv(baseBalance, _totalSupply);
                quoteAmount = 0;
            } else if (baseBalance != 0 && quoteBalance != 0) {
                shares =
                    Math.min(maxBase.mulDiv(_totalSupply, baseBalance), maxQuote.mulDiv(_totalSupply, quoteBalance));
                baseAmount = shares.mulDiv(baseBalance, _totalSupply);
                quoteAmount = shares.mulDiv(quoteBalance, _totalSupply);
            }
        } else {
            // Initial minting using oracle tick
            baseAmount = tick.outboundFromInbound(maxQuote);
            if (baseAmount > maxBase) {
                baseAmount = maxBase;
                quoteAmount = tick.inboundFromOutboundUp(maxBase);
            } else {
                quoteAmount = maxQuote;
            }

            (, shares) = ((tick.inboundFromOutboundUp(baseAmount) + quoteAmount) * QUOTE_SCALE).trySub(
                MangroveVaultConstants.MINIMUM_LIQUIDITY
            );
            _mint(address(this), MangroveVaultConstants.MINIMUM_LIQUIDITY);
        }

        if (shares < minSharesOut) {
            revert MangroveVaultErrors.SlippageExceeded(minSharesOut, shares);
        }

        // Check TVL limits after deposit
        (uint256 currentBaseBalance, uint256 currentQuoteBalance) = getUnderlyingBalances();

        if (currentBaseBalance + baseAmount > MAX_BASE) {
            revert MangroveVaultErrors.DepositExceedsMaxTotal(
                currentBaseBalance, currentBaseBalance + baseAmount, MAX_BASE
            );
        }

        if (currentQuoteBalance + quoteAmount > MAX_QUOTE) {
            revert MangroveVaultErrors.DepositExceedsMaxTotal(
                currentQuoteBalance, currentQuoteBalance + quoteAmount, MAX_QUOTE
            );
        }

        // Transfer tokens from user to vault
        if (baseAmount > 0) {
            BASE.safeTransferFrom(msg.sender, address(this), baseAmount);
        }
        if (quoteAmount > 0) {
            QUOTE.safeTransferFrom(msg.sender, address(this), quoteAmount);
        }

        _mint(msg.sender, shares);

        emit MangroveVaultEvents.Mint(msg.sender, shares, baseAmount, quoteAmount, Tick.unwrap(tick));

        return shares;
    }

    /**
     * @notice Burns shares and withdraws underlying assets
     * @dev If TVL - offered volume < amount to withdraw, retract position and burn shares
     */
    function burn(uint256 shares, uint256 minBaseOut, uint256 minQuoteOut)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 base, uint256 quote)
    {
        if (shares == 0) revert MangroveVaultErrors.ZeroAmount();

        // Accrue fees before burning
        _accrueManagementFees();

        // Get offered volume and TVL
        (uint256 kandelBase, uint256 kandelQuote) = getKandelBalances();
        (uint256 totalBase, uint256 totalQuote) = getUnderlyingBalances();

        uint256 _totalSupply = totalSupply();
        uint256 userShareOfBase = shares.mulDiv(totalBase, _totalSupply);
        uint256 userShareOfQuote = shares.mulDiv(totalQuote, _totalSupply);

        // Check if we need to retract position
        (uint256 vaultBase, uint256 vaultQuote) = getVaultBalances();
        if (userShareOfBase > vaultBase || userShareOfQuote > vaultQuote) {
            // Not enough liquidity in vault, need to withdraw from Kandel
            kandel.withdrawAllOffersAndFundsTo(payable(address(this)));
        }

        // Burn user shares
        _burn(msg.sender, shares);

        // Calculate output amounts
        base = userShareOfBase;
        quote = userShareOfQuote;

        // Check slippage
        if (base < minBaseOut) {
            revert MangroveVaultErrors.SlippageExceeded(minBaseOut, base);
        }
        if (quote < minQuoteOut) {
            revert MangroveVaultErrors.SlippageExceeded(minQuoteOut, quote);
        }

        // Transfer assets to user
        if (base > 0) {
            BASE.safeTransfer(msg.sender, base);
        }
        if (quote > 0) {
            QUOTE.safeTransfer(msg.sender, quote);
        }

        emit MangroveVaultEvents.Burn(msg.sender, shares, base, quote, Tick.unwrap(getCurrentTick()));

        return (base, quote);
    }

    /**
     * @notice Rebalances the vault by performing a swap
     */
    function rebalance(RebalanceParams memory params)
        external
        payable
        onlyManager
        nonReentrant
        returns (uint256 base, uint256 quote)
    {
        // Accrue fees before rebalancing
        _accrueManagementFees();

        if (!allowedSwapContracts[params.target]) {
            revert MangroveVaultErrors.UnauthorizedSwapContract(params.target);
        }

        (uint256 baseBalance, uint256 quoteBalance) = getVaultBalances();

        if (params.sell) {
            // Selling base for quote
            (, uint256 missingBase) = params.amount.trySub(baseBalance);
            if (missingBase > 0) {
                kandel.withdrawFunds(missingBase, 0, address(this));
            }
            BASE.safeApproveWithRetry(params.target, params.amount);
        } else {
            // Buying base with quote
            (, uint256 missingQuote) = params.amount.trySub(quoteBalance);
            if (missingQuote > 0) {
                kandel.withdrawFunds(0, missingQuote, address(this));
            }
            QUOTE.safeApproveWithRetry(params.target, params.amount);
        }

        // Execute swap
        params.target.functionCall(params.data);

        // Check results
        (uint256 newBaseBalance, uint256 newQuoteBalance) = getVaultBalances();

        if (params.sell) {
            uint256 receivedQuote = newQuoteBalance - quoteBalance;
            if (receivedQuote < params.minOut) {
                revert MangroveVaultErrors.SlippageExceeded(params.minOut, receivedQuote);
            }
            BASE.safeApproveWithRetry(params.target, 0);
        } else {
            uint256 receivedBase = newBaseBalance - baseBalance;
            if (receivedBase < params.minOut) {
                revert MangroveVaultErrors.SlippageExceeded(params.minOut, receivedBase);
            }
            QUOTE.safeApproveWithRetry(params.target, 0);
        }

        base = newBaseBalance;
        quote = newQuoteBalance;

        emit MangroveVaultEvents.Swap(
            params.target,
            int256(newBaseBalance) - int256(baseBalance),
            int256(newQuoteBalance) - int256(quoteBalance),
            params.sell
        );

        _checkPosition();

        return (base, quote);
    }

    /**
     * @notice Whitelists a target contract for swaps
     */
    function whitelist(address target) external onlyOwner {
        if (
            target == address(0) || target == address(this) || target == address(kandel) || target == BASE
                || target == QUOTE
        ) {
            revert MangroveVaultErrors.UnauthorizedSwapContract(target);
        }

        allowedSwapContracts[target] = true;
        emit MangroveVaultEvents.SwapContractAllowed(target, true);
    }

    /**
     * @notice Sets a pending oracle configuration
     */
    function setPendingOracle(Oracle memory _oracle) external onlyOwner {
        oracle = _oracle;
        oracle.proposedAt = uint32(block.timestamp);

        emit MangroveVaultV2Events.OracleConfigUpdated(
            _oracle.isStatic, _oracle.oracle, Tick.wrap(_oracle.staticValue), _oracle.timelock
        );
    }

    /**
     * @notice Accepts an oracle (placeholder - could be used for additional validation)
     */
    function acceptOracle(address oracleAddress) external onlyOwnerOrManager {
        Oracle memory _oracle = oracle;
        if (_oracle.oracle != oracleAddress) {
            revert MangroveVaultErrors.ZeroAddress();
        }
    }

    /**
     * @notice Revokes an oracle (guardian function)
     */
    function revokeOracle(address oracleAddress) external onlyGuardian {
        Oracle memory _oracle = oracle;
        if (_oracle.oracle == oracleAddress) {
            oracle.isStatic = true;
            oracle.oracle = address(0);
            emit MangroveVaultV2Events.OracleConfigUpdated(
                true, address(0), Tick.wrap(_oracle.staticValue), _oracle.timelock
            );
        }
    }

    /**
     * @notice Emergency kill function that withdraws all funds from Kandel (guardian only)
     * @dev This function is for emergency situations where immediate fund withdrawal is needed
     */
    function kill() external onlyGuardian {
        // Accrue fees before emergency withdrawal
        _accrueManagementFees();

        // Withdraw all offers and funds from Kandel to the vault
        kandel.withdrawAllOffersAndFundsTo(payable(address(this)));

        // Update state to reflect funds are no longer in Kandel
        _state.inKandel = false;

        emit MangroveVaultV2Events.EmergencyKill(msg.sender, block.timestamp);
    }

    /**
     * @notice Populates Kandel offers from a specific offset
     */
    function populateFromOffset(
        uint256 from,
        uint256 to,
        Tick baseQuoteTickIndex0,
        uint256 firstAskIndex,
        uint256 _baseQuoteTickOffset,
        uint256 bidGives,
        uint256 askGives,
        Params calldata parameters
    ) public payable onlyManager {
        // Accrue fees before major operations
        _accrueManagementFees();

        GeometricKandel.Params memory kandelParams;

        assembly {
            kandelParams := parameters
        }

        // Get the distribution and best bid/ask ticks
        // Create the parameters struct for _createGeometricDistribution
        CreateGeometricDistributionParams memory distParams = CreateGeometricDistributionParams({
            from: from,
            to: to,
            baseQuoteTickIndex0: baseQuoteTickIndex0,
            baseQuoteTickOffset: _baseQuoteTickOffset,
            firstAskIndex: firstAskIndex,
            bidGives: bidGives,
            askGives: askGives,
            stepSize: kandelParams.stepSize,
            pricePoints: kandelParams.pricePoints
        });

        // Get the distribution and best bid/ask ticks
        (DirectWithBidsAndAsksDistribution.Distribution memory distribution, int256 newBestBid, int256 newBestAsk) =
            _createGeometricDistribution(distParams);

        // Populate Kandel with the distribution
        kandel.populate{value: msg.value}(distribution, kandelParams, bidGives, askGives);

        // Update state with tick index
        _state.tickIndex0 = Tick.unwrap(baseQuoteTickIndex0).toInt24();
        kandel.setBaseQuoteTickOffset(_baseQuoteTickOffset);

        // Update best bid if the new one is better (higher tick = better bid)
        if (newBestBid > _state.bestBid) {
            _state.bestBid = int24(newBestBid);
        }

        // Update best ask if the new one is better (lower tick = better ask)
        if (newBestAsk < _state.bestAsk) {
            _state.bestAsk = int24(newBestAsk);
        }

        _checkPosition();
    }

    /**
     * @notice Populates a chunk of Kandel offers
     */
    function populateChunkFromOffset(
        uint256 from,
        uint256 to,
        Tick baseQuoteTickIndex0,
        uint256 _baseQuoteTickOffset,
        uint256 firstAskIndex,
        uint256 bidGives,
        uint256 askGives,
        Params calldata parameters
    ) public payable onlyManager {
        // Accrue fees before major operations
        _accrueManagementFees();

        GeometricKandel.Params memory kandelParams;

        assembly {
            kandelParams := parameters
        }

        // Create the parameters struct for _createGeometricDistribution
        CreateGeometricDistributionParams memory distParams = CreateGeometricDistributionParams({
            from: from,
            to: to,
            baseQuoteTickIndex0: baseQuoteTickIndex0,
            baseQuoteTickOffset: _baseQuoteTickOffset,
            firstAskIndex: firstAskIndex,
            bidGives: bidGives,
            askGives: askGives,
            stepSize: kandelParams.stepSize,
            pricePoints: kandelParams.pricePoints
        });

        // Get the distribution and best bid/ask ticks
        (DirectWithBidsAndAsksDistribution.Distribution memory distribution, int256 newBestBid, int256 newBestAsk) =
            _createGeometricDistribution(distParams);

        kandel.populateChunk(distribution);
        _checkPosition();
    }

    /**
     * @notice Gets the best ask tick from the market
     */
    function _bestAskTick() internal view returns (int256) {
        return _state.bestAsk;
    }

    /**
     * @notice Gets the best bid tick from the market
     */
    function _bestBidTick() internal view returns (int256) {
        return _state.bestBid;
    }

    /**
     * @notice Validates a tick against oracle configuration
     */
    function _checkTick(int256 tick, Oracle memory _oracle) internal view {
        // In static mode, no validation needed as manager controls the static value
        if (_oracle.isStatic) return;

        if (_oracle.oracle != address(0)) {
            Tick oracleTick = IOracle(_oracle.oracle).tick();
            int256 deviation = tick - Tick.unwrap(oracleTick);

            // Check if deviation exceeds allowed bounds (using timelock as max deviation for simplicity)
            if (uint24(FixedPointMathLib.abs(deviation)) > _oracle.timelock) {
                revert MangroveVaultV2Errors.TickDeviationExceeded();
            }
        }
    }

    /**
     * @notice Checks the current position against oracle constraints
     */
    function _checkPosition() internal {
        Oracle memory _oracle = oracle;
        int256 bestAskTick = _bestAskTick();
        int256 bestBidTick = _bestBidTick();

        _checkTick(bestAskTick, _oracle);
        _checkTick(-bestBidTick, _oracle);
    }

    /**
     * @notice Manually accrue management fees (public function)
     */
    function accrueManagementFees() external {
        _accrueManagementFees();
    }

    receive() external payable {}

    // Admin functions

    /**
     * @notice Disallows a previously allowed contract from performing swaps
     */
    function disallowSwapContract(address contractAddress) external onlyOwner {
        allowedSwapContracts[contractAddress] = false;
        emit MangroveVaultEvents.SwapContractAllowed(contractAddress, false);
    }

    /**
     * @notice Withdraws funds from Mangrove to a specified receiver
     */
    function withdrawFromMangrove(uint256 amount, address payable receiver) external onlyOwner {
        kandel.withdrawFromMangrove(amount, receiver);
    }

    /**
     * @notice Withdraws ERC20 tokens from the vault
     */
    function withdrawERC20(address token, uint256 amount) external onlyOwner {
        if (token == BASE || token == QUOTE || token == address(this)) {
            revert MangroveVaultErrors.CannotWithdrawToken(token);
        }
        token.safeTransfer(msg.sender, amount);
    }

    /**
     * @notice Withdraws native currency from the vault
     */
    function withdrawNative() external onlyOwner {
        (bool success,) = payable(msg.sender).call{value: address(this).balance}("");
        if (!success) {
            revert MangroveVaultErrors.NativeTransferFailed();
        }
    }

    /**
     * @notice Pauses the vault operations
     */
    function pause(bool pause_) external onlyOwner {
        if (pause_) {
            _pause();
        } else {
            _unpause();
        }
    }

    /**
     * @notice Sets the fee data for the vault (management fee only)
     */
    function setFeeData(uint16 managementFee, address feeRecipient) external onlyOwner {
        if (managementFee > MangroveVaultConstants.MAX_MANAGEMENT_FEE) {
            revert MangroveVaultErrors.MaxFeeExceeded(MangroveVaultConstants.MAX_MANAGEMENT_FEE, managementFee);
        }
        if (feeRecipient == address(0)) revert MangroveVaultErrors.ZeroAddress();

        // Accrue fees before changing fee parameters
        _accrueManagementFees();

        _state.managementFee = managementFee;
        _state.feeRecipient = feeRecipient;

        emit MangroveVaultEvents.SetFeeData(0, managementFee, feeRecipient);
    }

    /**
     * @notice Sets the manager of the vault
     */
    function setManager(address newManager) external onlyOwner {
        if (newManager == address(0)) revert MangroveVaultErrors.ZeroAddress();
        manager = newManager;
        emit MangroveVaultEvents.SetManager(newManager);
    }

    /**
     * @notice Sets the guardian of the vault
     */
    function setGuardian(address newGuardian) external onlyOwner {
        if (newGuardian == address(0)) revert MangroveVaultErrors.ZeroAddress();
        guardian = newGuardian;
        emit MangroveVaultV2Events.GuardianSet(newGuardian);
    }

    /**
     * @notice Manually deposits funds to Kandel
     */
    function depositFundsToKandel() external onlyOwnerOrManager {
        // Accrue fees before major operations
        _accrueManagementFees();
        _depositAllFunds();
    }

    /**
     * @notice Gets the TVL limits of the vault
     */
    function maxDeposit() external view returns (uint256 maxBase, uint256 maxQuote) {
        return (MAX_BASE, MAX_QUOTE);
    }

    /**
     * @notice Gets the current fee accrual information
     */
    function getFeeAccrualInfo() external view returns (uint64 lastFeeAccrualTime, uint256 pendingFeeShares) {
        lastFeeAccrualTime = _state.lastFeeAccrualTime;

        // Calculate pending fee shares
        uint256 managementFee = _state.managementFee;
        if (managementFee == 0) {
            pendingFeeShares = 0;
        } else {
            uint256 timeElapsed = block.timestamp - lastFeeAccrualTime;
            uint256 _totalSupply = totalSupply();

            if (timeElapsed == 0 || _totalSupply == 0) {
                pendingFeeShares = 0;
            } else {
                uint256 annualFeeRate = managementFee;
                uint256 feeRate = annualFeeRate * timeElapsed / (365 days);

                pendingFeeShares =
                    _totalSupply.mulDiv(feeRate, MangroveVaultConstants.MANAGEMENT_FEE_PRECISION - feeRate);
            }
        }
    }

    // Internal functions

    /**
     * @notice Calculates the adjusted minimum amount for a swap based on price spread
     */
    function adjustedAmountInMin(uint256 amountOut, uint256 _amountInMin, bool sell)
        public
        view
        returns (uint256 amountInMin)
    {
        uint256 _maxTickDeviation = oracle.maxTickDeviation;

        if (_maxTickDeviation == type(uint256).max) {
            return _amountInMin;
        }

        Tick tick = getCurrentTick();

        if (sell) {
            tick = Tick.wrap(Tick.unwrap(tick) - _maxTickDeviation.toInt256());
            amountInMin = tick.inboundFromOutboundUp(amountOut);
        } else {
            tick = Tick.wrap(Tick.unwrap(tick) + _maxTickDeviation.toInt256());
            amountInMin = tick.outboundFromInbound(amountOut);
        }
        amountInMin = Math.max(amountInMin, _amountInMin);
    }

    /**
     * @notice Converts base and quote amounts to a total quote amount using a specified tick
     */
    function _toQuoteAmount(uint256 amountBase, uint256 amountQuote, Tick tick)
        internal
        pure
        returns (uint256 quoteAmount)
    {
        quoteAmount = amountQuote + tick.inboundFromOutboundUp(amountBase);
    }

    /**
     * @notice Deposits all available funds from the vault to Kandel
     */
    function _depositAllFunds() internal {
        (uint256 baseBalance, uint256 quoteBalance) = getVaultBalances();
        if (baseBalance > 0) {
            BASE.safeApproveWithRetry(address(kandel), baseBalance);
        }
        if (quoteBalance > 0) {
            QUOTE.safeApproveWithRetry(address(kandel), quoteBalance);
        }
        kandel.depositFunds(baseBalance, quoteBalance);
    }

    /**
     * @notice Parameters for creating a geometric distribution
     * @param from populate offers starting from this index (inclusive). Must be at most `pricePoints`.
     * @param to populate offers until this index (exclusive). Must be at most `pricePoints`.
     * @param baseQuoteTickIndex0 the tick for the price point at index 0 given as a tick on the `base, quote` offer list
     * @param baseQuoteTickOffset the tick offset used for the geometric progression deployment. Must be at least 1.
     * @param firstAskIndex the (inclusive) index after which offer should be an ask. Must be at most `pricePoints`.
     * @param bidGives The initial amount of quote to give for all bids
     * @param askGives The initial amount of base to give for all asks
     * @param stepSize in amount of price points to jump for posting dual offer. Must be less than `pricePoints`.
     * @param pricePoints the number of price points for the Kandel instance. Must be at least 2.
     */
    struct CreateGeometricDistributionParams {
        uint256 from;
        uint256 to;
        Tick baseQuoteTickIndex0;
        uint256 baseQuoteTickOffset;
        uint256 firstAskIndex;
        uint256 bidGives;
        uint256 askGives;
        uint256 stepSize;
        uint256 pricePoints;
    }

    ///@dev Modified `KandelLib.createGeometricDistribution` implementation for this context
    ///@notice Creates a distribution of bids and asks given by the parameters. Dual offers are included with gives=0.
    ///@notice Returns not only the distribution but the best bid and ask prices
    ///@param params The parameters for creating the geometric distribution
    ///@return distribution the distribution of bids and asks to populate
    ///@return bestBid the tick of the best (highest price) bid
    ///@return bestAsk the tick of the best (lowest price) ask
    ///@dev the absolute price of an offer is the ratio of quote/base volumes of tokens it trades
    ///@dev the tick of offers on Mangrove are in relative taker price of maker's inbound/outbound volumes of tokens it trades
    ///@dev for Bids, outbound_tkn=quote, inbound_tkn=base so relative taker price of a a bid is the inverse of the absolute price.
    ///@dev for Asks, outbound_tkn=base, inbound_tkn=quote so relative taker price of an ask coincides with absolute price.
    ///@dev Index0 will contain the ask with the lowest relative price and the bid with the highest relative price. Absolute price is geometrically increasing over indexes.
    ///@dev tickOffset moves an offer relative price s.t. `AskTick_{i+1} = AskTick_i + tickOffset` and `BidTick_{i+1} = BidTick_i - tickOffset`
    ///@dev A hole is left in the middle at the size of stepSize - either an offer or its dual is posted, not both.
    ///@dev The caller should make sure the minimum and maximum tick does not exceed the MIN_TICK and MAX_TICK from respectively; otherwise, populate will fail for those offers.
    ///@dev If type(uint).max is used for `bidGives` or `askGives` then very high or low prices can yield gives=0 (which results in both offer an dual being dead) or gives>=type(uin96).max which is not supported by Mangrove.
    function _createGeometricDistribution(CreateGeometricDistributionParams memory params)
        private
        pure
        returns (DirectWithBidsAndAsksDistribution.Distribution memory distribution, int256 bestBid, int256 bestAsk)
    {
        require(
            params.bidGives != type(uint256).max || params.askGives != type(uint256).max, "Kandel/bothGivesVariable"
        );

        // Initialize best bid and ask to extreme values
        bestBid = type(int256).min; // Will be updated to the highest bid tick
        bestAsk = type(int256).max; // Will be updated to the lowest ask tick

        // First we restrict boundaries of bids and asks.

        // Create live bids up till first ask, except stop where live asks will have a dual bid.
        uint256 bidBound;
        {
            // Rounding - we skip an extra live bid if stepSize is odd.
            uint256 bidHoleSize = params.stepSize / 2 + params.stepSize % 2;
            // If first ask is close to start, then there are no room for live bids.
            bidBound = params.firstAskIndex > bidHoleSize ? params.firstAskIndex - bidHoleSize : 0;
            // If stepSize is large there is not enough room for dual outside
            uint256 lastBidWithPossibleDualAsk = params.pricePoints - params.stepSize;
            if (bidBound > lastBidWithPossibleDualAsk) {
                bidBound = lastBidWithPossibleDualAsk;
            }
        }
        // Here firstAskIndex becomes the index of the first actual ask, and not just the boundary - we need to take `stepSize` and `from` into account.
        params.firstAskIndex = params.firstAskIndex + params.stepSize / 2;
        // We should not place live asks near the beginning, there needs to be room for the dual bid.
        if (params.firstAskIndex < params.stepSize) {
            params.firstAskIndex = params.stepSize;
        }

        // Finally, account for the from/to boundaries
        if (params.to < bidBound) {
            bidBound = params.to;
        }
        if (params.firstAskIndex < params.from) {
            params.firstAskIndex = params.from;
        }

        // Allocate distributions - there should be room for live bids and asks, and their duals.
        {
            uint256 count = (params.from < bidBound ? bidBound - params.from : 0)
                + (params.firstAskIndex < params.to ? params.to - params.firstAskIndex : 0);
            distribution.bids = new DirectWithBidsAndAsksDistribution.DistributionOffer[](count);
            distribution.asks = new DirectWithBidsAndAsksDistribution.DistributionOffer[](count);
        }

        // Start bids at from
        uint256 index = params.from;
        // Calculate the taker relative tick of the first price point
        int256 tick = -(Tick.unwrap(params.baseQuoteTickIndex0) + int256(params.baseQuoteTickOffset) * int256(index));
        // A counter for insertion in the distribution structs
        uint256 i = 0;
        for (; index < bidBound; ++index) {
            // Add live bid
            // Use askGives unless it should be derived from bid at the price
            uint256 bidGivesAmount = params.bidGives == type(uint256).max
                ? Tick.wrap(tick).outboundFromInbound(params.askGives)
                : params.bidGives;

            distribution.bids[i] = DirectWithBidsAndAsksDistribution.DistributionOffer({
                index: index,
                tick: Tick.wrap(tick),
                gives: bidGivesAmount
            });

            // Update best bid if this is a live bid (gives > 0) and tick is higher
            if (bidGivesAmount > 0 && tick > bestBid) {
                bestBid = tick;
            }

            // Add dual (dead) ask
            uint256 dualIndex =
                KandelLib.transportDestination(OfferType.Ask, index, params.stepSize, params.pricePoints);
            distribution.asks[i] = DirectWithBidsAndAsksDistribution.DistributionOffer({
                index: dualIndex,
                tick: Tick.wrap(
                    (Tick.unwrap(params.baseQuoteTickIndex0) + int256(params.baseQuoteTickOffset) * int256(dualIndex))
                ),
                gives: 0
            });

            // Next tick
            tick -= int256(params.baseQuoteTickOffset);
            ++i;
        }

        // Start asks from (adjusted) firstAskIndex
        index = params.firstAskIndex;
        // Calculate the taker relative tick of the first ask
        tick = (Tick.unwrap(params.baseQuoteTickIndex0) + int256(params.baseQuoteTickOffset) * int256(index));
        for (; index < params.to; ++index) {
            // Add live ask
            // Use askGives unless it should be derived from bid at the price
            uint256 askGivesAmount = params.askGives == type(uint256).max
                ? Tick.wrap(tick).outboundFromInbound(params.bidGives)
                : params.askGives;

            distribution.asks[i] = DirectWithBidsAndAsksDistribution.DistributionOffer({
                index: index,
                tick: Tick.wrap(tick),
                gives: askGivesAmount
            });

            // Update best ask if this is a live ask (gives > 0) and tick is lower
            if (askGivesAmount > 0 && tick < bestAsk) {
                bestAsk = tick;
            }

            // Add dual (dead) bid
            uint256 dualIndex =
                KandelLib.transportDestination(OfferType.Bid, index, params.stepSize, params.pricePoints);
            distribution.bids[i] = DirectWithBidsAndAsksDistribution.DistributionOffer({
                index: dualIndex,
                tick: Tick.wrap(
                    -(Tick.unwrap(params.baseQuoteTickIndex0) + int256(params.baseQuoteTickOffset) * int256(dualIndex))
                ),
                gives: 0
            });

            // Next tick
            tick += int256(params.baseQuoteTickOffset);
            ++i;
        }

        // If no live bids or asks were found, set to sentinel values
        if (bestBid == type(int256).min) {
            bestBid = 0; // or another appropriate default
        }
        if (bestAsk == type(int256).max) {
            bestAsk = 0; // or another appropriate default
        }
    }
}
