// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/// @title ForkFlip
/// @notice A fork flip for $FORKIN, the gas token of Fork in Hood (chain 36754663).
///         Stake native FORKIN, call tines or handle, get paid on the same chain.
///
/// The flip is a two-transaction commit-reveal:
///
///   1. `flip(commitment)` with FORKIN attached. The commitment is
///      keccak256(guess, salt, player), where `salt` is a secret only the player
///      knows. Nobody can tell what was called, or predict the outcome.
///   2. `reveal(id, guess, salt)` at least two blocks later. The outcome is
///      keccak256(salt, blockhash(commitBlock + 1), id) & 1.
///
/// THE PROPERTY THAT MATTERS: neither side can steer the result.
///
/// The player cannot, because `blockhash(commitBlock + 1)` does not exist yet when
/// the salt is chosen, and the commitment fixes the salt before it does. Refusing
/// to reveal a loss gains nothing either: an expired round forfeits the stake to the
/// house, which is exactly what losing costs, so declining to reveal is never better
/// than revealing.
///
/// The house cannot, because the salt stays secret until the reveal. The sequencer
/// operator of a one-sequencer chain genuinely does control block production, and
/// so does control `blockhash` — but grinding it is grinding blind. Without the
/// salt there is no way to know which block hash produces which outcome, so the
/// power to choose the hash is not the power to choose the result.
///
/// What the operator can still do is censor: refuse to sequence a reveal until the
/// window closes and take the stake. That is inherent to a chain with one
/// sequencer, and is why `REVEAL_WINDOW` is 200 blocks rather than a handful.
/// It is stated here rather than left for you to find.
///
/// The owner's money and the players' money are tracked separately. `bankroll` is
/// what the house may withdraw; `lockedFunds` is what open rounds are owed. The
/// withdrawal path only ever reads `bankroll`, so a round that has been staked
/// cannot be defunded out from under the player, including by the owner.
contract ForkFlip {
    // ---------------------------------------------------------------- types ---

    enum Status {
        None,
        Open,
        Settled
    }

    struct Round {
        address player;
        uint128 stake; // what the player put in
        uint128 payout; // what a win pays out, stake included
        uint64 commitBlock;
        bytes32 commitment;
        Status status;
    }

    // ------------------------------------------------------------- constants ---

    uint8 public constant TINES = 0;
    uint8 public constant HANDLE = 1;

    /// Blocks after the commit in which a round may be revealed. Kept under 256
    /// because `blockhash` returns zero beyond that, which would leave a round
    /// unrevealable and silently turn every late flip into a forfeit.
    uint64 public constant REVEAL_WINDOW = 200;

    /// The house edge can never be raised past this, whatever the owner wants.
    /// 500 bps of a 2x payout is a 2.5% edge on the stake.
    uint16 public constant MAX_EDGE_BPS = 500;

    // --------------------------------------------------------------- storage ---

    address public owner;

    /// House capital that is free to back new rounds, and the only money the
    /// owner is ever able to withdraw.
    uint256 public bankroll;

    /// The total owed to rounds that are still open: every player's stake plus
    /// the house's matched exposure. Never withdrawable by anyone but the winner.
    uint256 public lockedFunds;

    /// Taken out of the winning payout, in basis points. At 200 a win pays 1.98x
    /// instead of 2x, which is a 1% edge on the amount staked.
    uint16 public edgeBps;

    uint256 public minBet;
    uint256 public maxBet;

    mapping(uint256 => Round) public rounds;
    uint256 public nextRoundId;

    /// Lifetime counters, for the frontend and for anyone checking our arithmetic.
    uint256 public totalFlips;
    uint256 public totalStaked;
    uint256 public totalPaidOut;

    bool private locked;

    // ---------------------------------------------------------------- events ---

    event Flipped(uint256 indexed id, address indexed player, uint256 stake, uint256 payout);
    event Revealed(uint256 indexed id, address indexed player, uint8 guess, uint8 outcome, bool won, uint256 paid);
    event Forfeited(uint256 indexed id, address indexed player, uint256 stake);
    event Funded(address indexed from, uint256 amount);
    event BankrollWithdrawn(address indexed to, uint256 amount);
    event EdgeChanged(uint16 edgeBps);
    event LimitsChanged(uint256 minBet, uint256 maxBet);
    event OwnerChanged(address indexed owner);

    // ---------------------------------------------------------------- errors ---

    error NotOwner();
    error ZeroAddress();
    error EdgeTooHigh();
    error BadLimits();
    error LimitTooLarge();
    error BetOutOfRange();
    error BankrollTooThin();
    error NotOpen();
    error NotPlayer();
    error TooEarly();
    error WindowClosed();
    error WindowStillOpen();
    error BadReveal();
    error BadGuess();
    error HashUnavailable();
    error InsufficientBankroll();
    error TransferFailed();
    error Reentrancy();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier nonReentrant() {
        if (locked) revert Reentrancy();
        locked = true;
        _;
        locked = false;
    }

    constructor(address _owner, uint16 _edgeBps, uint256 _minBet, uint256 _maxBet) payable {
        if (_owner == address(0)) revert ZeroAddress();
        if (_edgeBps > MAX_EDGE_BPS) revert EdgeTooHigh();
        owner = _owner;
        edgeBps = _edgeBps;
        _setLimits(_minBet, _maxBet);
        if (msg.value > 0) {
            bankroll = msg.value;
            emit Funded(msg.sender, msg.value);
        }
    }

    // ----------------------------------------------------------------- play ---

    /// Stake FORKIN on a call nobody else can see yet.
    ///
    /// `commitment` must be keccak256(abi.encodePacked(guess, salt, msg.sender)),
    /// with `guess` either TINES (0) or HANDLE (1) and `salt` a value you keep
    /// secret and do not lose. Losing the salt means losing the stake, because the
    /// round can never be revealed.
    function flip(bytes32 commitment) external payable nonReentrant returns (uint256 id) {
        uint256 stake = msg.value;
        if (stake < minBet || stake > maxBet) revert BetOutOfRange();

        uint256 payout = winnings(stake);
        uint256 exposure = payout - stake; // what the house stands to lose
        if (exposure > bankroll) revert BankrollTooThin();

        bankroll -= exposure;
        lockedFunds += payout;

        id = nextRoundId++;
        rounds[id] = Round({
            player: msg.sender,
            // Both exact: `_setLimits` caps maxBet at type(uint128).max / 2.
            stake: uint128(stake),
            payout: uint128(payout),
            commitBlock: uint64(block.number),
            commitment: commitment,
            status: Status.Open
        });

        totalFlips++;
        totalStaked += stake;
        emit Flipped(id, msg.sender, stake, payout);
    }

    /// Open the round. Pays out immediately on a win.
    ///
    /// Must happen at least two blocks after the commit, so that the block whose
    /// hash decides the flip is one that did not exist when the salt was chosen.
    function reveal(uint256 id, uint8 guess, bytes32 salt) external nonReentrant returns (uint8 outcome, bool won) {
        Round storage r = rounds[id];
        if (r.status != Status.Open) revert NotOpen();
        if (msg.sender != r.player) revert NotPlayer();
        if (guess > HANDLE) revert BadGuess();

        uint256 decidingBlock = uint256(r.commitBlock) + 1;
        if (block.number <= decidingBlock) revert TooEarly();
        if (block.number > uint256(r.commitBlock) + REVEAL_WINDOW) revert WindowClosed();

        if (keccak256(abi.encodePacked(guess, salt, msg.sender)) != r.commitment) revert BadReveal();

        bytes32 seed = blockhash(decidingBlock);
        // Unreachable while REVEAL_WINDOW < 256, and checked anyway: a zero hash
        // would make the outcome a constant.
        if (seed == bytes32(0)) revert HashUnavailable();

        outcome = uint8(uint256(keccak256(abi.encodePacked(salt, seed, id))) & 1);
        won = outcome == guess;

        uint256 payout = r.payout;
        r.status = Status.Settled;
        lockedFunds -= payout;

        uint256 paid;
        if (won) {
            paid = payout;
            totalPaidOut += payout;
            _push(r.player, payout);
        } else {
            // The stake and the house's exposure both return to the bankroll.
            bankroll += payout;
        }

        emit Revealed(id, r.player, guess, outcome, won, paid);
    }

    /// Close a round nobody revealed in time. The stake goes to the house, and the
    /// house's exposure is released. Callable by anyone, since leaving stale rounds
    /// open only ties up bankroll that could back live ones.
    function forfeit(uint256 id) external {
        Round storage r = rounds[id];
        if (r.status != Status.Open) revert NotOpen();
        if (block.number <= uint256(r.commitBlock) + REVEAL_WINDOW) revert WindowStillOpen();

        uint256 payout = r.payout;
        r.status = Status.Settled;
        lockedFunds -= payout;
        bankroll += payout;

        emit Forfeited(id, r.player, r.stake);
    }

    // ------------------------------------------------------------- bankroll ---

    /// Add house capital. Open to anyone; there is no share issued in return, so
    /// this is a donation to the bankroll rather than an investment in it.
    function fund() public payable {
        bankroll += msg.value;
        emit Funded(msg.sender, msg.value);
    }

    /// Plain transfers are treated as funding rather than reverted, so FORKIN sent
    /// here by hand is usable instead of stranded.
    receive() external payable {
        fund();
    }

    /// Take house capital back out.
    ///
    /// Reads `bankroll` and never `lockedFunds`, so this cannot reach money that an
    /// open round is owed. The worst an owner can do by emptying it is stop the
    /// contract from accepting new flips.
    function withdrawBankroll(address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amount > bankroll) revert InsufficientBankroll();
        bankroll -= amount;
        _push(to, amount);
        emit BankrollWithdrawn(to, amount);
    }

    // ---------------------------------------------------------------- admin ---

    /// Changing the edge only affects rounds opened after it. A round's payout is
    /// fixed in storage when it is staked, so a flip in flight cannot be repriced.
    function setEdge(uint16 _edgeBps) external onlyOwner {
        if (_edgeBps > MAX_EDGE_BPS) revert EdgeTooHigh();
        edgeBps = _edgeBps;
        emit EdgeChanged(_edgeBps);
    }

    function setLimits(uint256 _minBet, uint256 _maxBet) external onlyOwner {
        _setLimits(_minBet, _maxBet);
    }

    /// A `Round` packs the stake and the payout into uint128 each. Capping
    /// `maxBet` at half of what a uint128 holds makes both casts in `flip`
    /// exact rather than merely unlikely to truncate: a stake can never exceed
    /// `maxBet`, and a payout is at most twice a stake, which is what it would
    /// be if the edge were ever set to zero.
    ///
    /// The ceiling is around 1.7e20 FORKIN, so it constrains nothing real.
    function _setLimits(uint256 _minBet, uint256 _maxBet) private {
        if (_minBet == 0 || _maxBet < _minBet) revert BadLimits();
        if (_maxBet > type(uint128).max / 2) revert LimitTooLarge();
        minBet = _minBet;
        maxBet = _maxBet;
        emit LimitsChanged(_minBet, _maxBet);
    }

    function setOwner(address _owner) external onlyOwner {
        if (_owner == address(0)) revert ZeroAddress();
        owner = _owner;
        emit OwnerChanged(_owner);
    }

    // -------------------------------------------------------------- helpers ---

    /// What a winning stake of `stake` pays out in total, the stake included.
    function winnings(uint256 stake) public view returns (uint256) {
        return (stake * (20_000 - edgeBps)) / 10_000;
    }

    /// The largest stake the bankroll can currently back, ignoring `maxBet`.
    function maxBackableBet() public view returns (uint256) {
        uint256 exposurePerUnit = 10_000 - edgeBps; // per 10_000 staked
        if (exposurePerUnit == 0) return type(uint256).max;
        return (bankroll * 10_000) / exposurePerUnit;
    }

    /// The largest stake `flip` will actually accept right now.
    function maxAcceptableBet() external view returns (uint256) {
        uint256 backable = maxBackableBet();
        return backable < maxBet ? backable : maxBet;
    }

    /// Build the commitment for a call. Provided so a frontend and a test agree on
    /// the encoding; the salt must never leave the player's machine before reveal.
    function commitmentFor(uint8 guess, bytes32 salt, address player) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(guess, salt, player));
    }

    /// Whether `id` can be revealed in this block, and the block deciding it.
    function revealable(uint256 id) external view returns (bool ok, uint256 decidingBlock, uint256 deadline) {
        Round storage r = rounds[id];
        decidingBlock = uint256(r.commitBlock) + 1;
        deadline = uint256(r.commitBlock) + REVEAL_WINDOW;
        ok = r.status == Status.Open && block.number > decidingBlock && block.number <= deadline;
    }

    function _push(address to, uint256 amount) private {
        (bool sent,) = payable(to).call{value: amount}("");
        if (!sent) revert TransferFailed();
    }
}
