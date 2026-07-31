// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import "../src/ForkFlip.sol";
import "../script/Deploy.s.sol";

contract ForkFlipTest is Test {
    ForkFlip flip;

    address owner = address(0xF0);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    uint16 constant EDGE = 200; // 1.98x, a 1% edge on the stake
    /// Mirrors of the contract's constants. Read inline as `flip.TINES()` they
    /// would consume the pending `vm.prank` and run the call as this contract.
    uint8 constant TINES = 0;
    uint8 constant HANDLE = 1;
    uint64 constant WINDOW = 200;
    uint16 constant MAX_EDGE_BPS = 500;
    uint256 constant MIN = 0.01 ether;
    uint256 constant MAX = 10 ether;

    function setUp() public {
        vm.deal(owner, 1000 ether);
        vm.prank(owner);
        flip = new ForkFlip{value: 500 ether}(owner, EDGE, MIN, MAX);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    // ------------------------------------------------------------- helpers ---

    function _commit(uint8 guess, bytes32 salt, address player) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(guess, salt, player));
    }

    function _outcome(bytes32 salt, bytes32 seed, uint256 id) internal pure returns (uint8) {
        return uint8(uint256(keccak256(abi.encodePacked(salt, seed, id))) & 1);
    }

    /// Find a block hash that makes round `id` come up `want`. Only a test can do
    /// this: it needs the salt, which on chain is secret until the reveal.
    function _seedFor(bytes32 salt, uint256 id, uint8 want) internal pure returns (bytes32) {
        for (uint256 i = 1; i < 512; i++) {
            bytes32 seed = bytes32(i);
            if (_outcome(salt, seed, id) == want) return seed;
        }
        revert("no seed found");
    }

    /// Stake, advance past the deciding block, and pin that block's hash so the
    /// outcome is `want`.
    function _stakeAndRig(address player, uint256 stake, uint8 guess, bytes32 salt, uint8 want)
        internal
        returns (uint256 id)
    {
        vm.prank(player);
        id = flip.flip{value: stake}(_commit(guess, salt, player));

        uint256 deciding = block.number + 1;
        vm.roll(block.number + 2);
        vm.setBlockhash(deciding, _seedFor(salt, id, want));
    }

    /// Every wei in the contract is either house money or owed to an open round.
    function _assertSolvent() internal view {
        assertEq(address(flip).balance, flip.bankroll() + flip.lockedFunds(), "balance != bankroll + locked");
    }

    // ---------------------------------------------------------------- setup ---

    /// Guards the mirrors above against the contract drifting out from under them.
    function test_localConstantsMatchTheContract() public view {
        assertEq(flip.TINES(), TINES);
        assertEq(flip.HANDLE(), HANDLE);
        assertEq(flip.REVEAL_WINDOW(), WINDOW);
        assertEq(flip.MAX_EDGE_BPS(), MAX_EDGE_BPS);
    }

    function test_constructor_seedsBankroll() public view {
        assertEq(flip.bankroll(), 500 ether);
        assertEq(flip.owner(), owner);
        assertEq(flip.edgeBps(), EDGE);
        _assertSolvent();
    }

    function test_constructor_rejectsExcessiveEdge() public {
        vm.expectRevert(ForkFlip.EdgeTooHigh.selector);
        new ForkFlip(owner, 501, MIN, MAX);
    }

    function test_constructor_rejectsBadLimits() public {
        vm.expectRevert(ForkFlip.BadLimits.selector);
        new ForkFlip(owner, EDGE, 0, MAX);
        vm.expectRevert(ForkFlip.BadLimits.selector);
        new ForkFlip(owner, EDGE, 2 ether, 1 ether);
    }

    // ----------------------------------------------------------------- play ---

    function test_win_paysStakePlusProfit() public {
        uint256 stake = 1 ether;
        bytes32 salt = keccak256("alice's secret");
        uint256 id = _stakeAndRig(alice, stake, TINES, salt, TINES);

        uint256 before = alice.balance;
        vm.prank(alice);
        (uint8 outcome, bool won) = flip.reveal(id, TINES, salt);

        assertEq(outcome, TINES);
        assertTrue(won);
        assertEq(alice.balance - before, 1.98 ether, "should be paid 1.98x");
        assertEq(flip.totalPaidOut(), 1.98 ether);
        _assertSolvent();
    }

    function test_loss_keepsStakeInBankroll() public {
        uint256 stake = 1 ether;
        bytes32 salt = keccak256("alice's secret");
        uint256 bankrollBefore = flip.bankroll();
        uint256 id = _stakeAndRig(alice, stake, TINES, salt, HANDLE);

        uint256 before = alice.balance;
        vm.prank(alice);
        (uint8 outcome, bool won) = flip.reveal(id, TINES, salt);

        assertEq(outcome, HANDLE);
        assertFalse(won);
        assertEq(alice.balance, before, "loser is paid nothing");
        assertEq(flip.bankroll(), bankrollBefore + stake, "house keeps exactly the stake");
        assertEq(flip.lockedFunds(), 0);
        _assertSolvent();
    }

    function test_flip_locksHouseExposure() public {
        uint256 stake = 1 ether;
        uint256 bankrollBefore = flip.bankroll();

        vm.prank(alice);
        uint256 id = flip.flip{value: stake}(_commit(TINES, "s", alice));

        // 1.98x total payout on a 1 ether stake is 0.98 ether of house exposure.
        assertEq(flip.bankroll(), bankrollBefore - 0.98 ether);
        assertEq(flip.lockedFunds(), 1.98 ether);
        (, uint128 s, uint128 p,,,) = flip.rounds(id);
        assertEq(s, stake);
        assertEq(p, 1.98 ether);
        _assertSolvent();
    }

    function test_reveal_revertsBeforeDecidingBlock() public {
        bytes32 salt = "s";
        vm.prank(alice);
        uint256 id = flip.flip{value: 1 ether}(_commit(TINES, salt, alice));

        vm.prank(alice);
        vm.expectRevert(ForkFlip.TooEarly.selector);
        flip.reveal(id, TINES, salt);

        vm.roll(block.number + 1); // now at commitBlock + 1, still too early
        vm.prank(alice);
        vm.expectRevert(ForkFlip.TooEarly.selector);
        flip.reveal(id, TINES, salt);
    }

    function test_reveal_revertsAfterWindow() public {
        bytes32 salt = "s";
        vm.prank(alice);
        uint256 id = flip.flip{value: 1 ether}(_commit(TINES, salt, alice));

        vm.roll(block.number + WINDOW + 1);
        vm.prank(alice);
        vm.expectRevert(ForkFlip.WindowClosed.selector);
        flip.reveal(id, TINES, salt);
    }

    function test_reveal_rejectsWrongSalt() public {
        bytes32 salt = "right";
        uint256 id = _stakeAndRig(alice, 1 ether, TINES, salt, TINES);

        vm.prank(alice);
        vm.expectRevert(ForkFlip.BadReveal.selector);
        flip.reveal(id, TINES, "wrong");
    }

    /// The whole point of committing the guess: you cannot switch it after seeing
    /// the block that decides the flip.
    function test_reveal_rejectsSwitchedGuess() public {
        bytes32 salt = "s";
        uint256 id = _stakeAndRig(alice, 1 ether, TINES, salt, HANDLE);

        vm.prank(alice);
        vm.expectRevert(ForkFlip.BadReveal.selector);
        flip.reveal(id, HANDLE, salt);
    }

    function test_reveal_rejectsStranger() public {
        bytes32 salt = "s";
        uint256 id = _stakeAndRig(alice, 1 ether, TINES, salt, TINES);

        vm.prank(bob);
        vm.expectRevert(ForkFlip.NotPlayer.selector);
        flip.reveal(id, TINES, salt);
    }

    function test_reveal_rejectsBadGuessValue() public {
        bytes32 salt = "s";
        uint256 id = _stakeAndRig(alice, 1 ether, TINES, salt, TINES);

        vm.prank(alice);
        vm.expectRevert(ForkFlip.BadGuess.selector);
        flip.reveal(id, 2, salt);
    }

    function test_reveal_cannotBeReplayed() public {
        bytes32 salt = "s";
        uint256 id = _stakeAndRig(alice, 1 ether, TINES, salt, TINES);

        vm.prank(alice);
        flip.reveal(id, TINES, salt);

        vm.prank(alice);
        vm.expectRevert(ForkFlip.NotOpen.selector);
        flip.reveal(id, TINES, salt);
        _assertSolvent();
    }

    function test_betOutOfRange() public {
        vm.prank(alice);
        vm.expectRevert(ForkFlip.BetOutOfRange.selector);
        flip.flip{value: MIN - 1}(_commit(TINES, "s", alice));

        vm.prank(alice);
        vm.expectRevert(ForkFlip.BetOutOfRange.selector);
        flip.flip{value: MAX + 1}(_commit(TINES, "s", alice));
    }

    function test_flip_revertsWhenBankrollCannotCoverIt() public {
        uint256 free = flip.bankroll();
        vm.prank(owner);
        flip.withdrawBankroll(owner, free); // empty the house

        vm.prank(alice);
        vm.expectRevert(ForkFlip.BankrollTooThin.selector);
        flip.flip{value: 1 ether}(_commit(TINES, "s", alice));
    }

    // ------------------------------------------------------------- forfeits ---

    function test_forfeit_afterWindowGivesStakeToHouse() public {
        uint256 bankrollBefore = flip.bankroll();
        vm.prank(alice);
        uint256 id = flip.flip{value: 1 ether}(_commit(TINES, "s", alice));

        vm.roll(block.number + WINDOW + 1);
        vm.prank(bob); // anyone may close a stale round
        flip.forfeit(id);

        assertEq(flip.bankroll(), bankrollBefore + 1 ether);
        assertEq(flip.lockedFunds(), 0);
        _assertSolvent();
    }

    function test_forfeit_revertsWhileWindowOpen() public {
        vm.prank(alice);
        uint256 id = flip.flip{value: 1 ether}(_commit(TINES, "s", alice));

        vm.roll(block.number + WINDOW);
        vm.expectRevert(ForkFlip.WindowStillOpen.selector);
        flip.forfeit(id);
    }

    /// A player who refuses to reveal a loss is no better off than one who reveals
    /// it, which is what stops "just don't reveal" from being a strategy.
    function test_forfeitCostsTheSameAsLosing() public {
        bytes32 salt = "s";

        uint256 id1 = _stakeAndRig(alice, 1 ether, TINES, salt, HANDLE);
        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        flip.reveal(id1, TINES, salt);
        uint256 costOfRevealingALoss = aliceBefore - alice.balance;

        vm.prank(bob);
        uint256 id2 = flip.flip{value: 1 ether}(_commit(TINES, salt, bob));
        uint256 bobBefore = bob.balance;
        vm.roll(block.number + WINDOW + 1);
        flip.forfeit(id2);
        uint256 costOfWalkingAway = bobBefore - bob.balance;

        assertEq(costOfRevealingALoss, costOfWalkingAway, "walking away must not be cheaper");
        assertEq(costOfWalkingAway, 0, "the stake was already paid at commit time");
    }

    // ------------------------------------------------------------- bankroll ---

    function test_ownerCannotWithdrawMoneyOwedToOpenRounds() public {
        vm.prank(alice);
        flip.flip{value: 10 ether}(_commit(TINES, "s", alice));

        uint256 free = flip.bankroll();
        vm.prank(owner);
        vm.expectRevert(ForkFlip.InsufficientBankroll.selector);
        flip.withdrawBankroll(owner, free + 1);

        // Draining every free wei still leaves the open round fully covered.
        vm.prank(owner);
        flip.withdrawBankroll(owner, free);
        assertEq(flip.bankroll(), 0);
        assertEq(address(flip).balance, flip.lockedFunds());
        assertEq(address(flip).balance, 19.8 ether);
    }

    /// The owner emptying the bankroll mid-round must not be able to strand a
    /// winner: the payout is already held aside.
    function test_winnerIsPaidEvenAfterOwnerDrainsBankroll() public {
        bytes32 salt = "s";
        uint256 id = _stakeAndRig(alice, 10 ether, TINES, salt, TINES);

        uint256 free = flip.bankroll();
        vm.prank(owner);
        flip.withdrawBankroll(owner, free);

        uint256 before = alice.balance;
        vm.prank(alice);
        flip.reveal(id, TINES, salt);
        assertEq(alice.balance - before, 19.8 ether, "winner paid in full");
        assertEq(address(flip).balance, 0);
    }

    function test_withdrawBankroll_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(ForkFlip.NotOwner.selector);
        flip.withdrawBankroll(alice, 1 ether);
    }

    function test_plainTransferFundsBankroll() public {
        uint256 before = flip.bankroll();
        vm.prank(bob);
        (bool ok,) = address(flip).call{value: 5 ether}("");
        assertTrue(ok);
        assertEq(flip.bankroll(), before + 5 ether);
        _assertSolvent();
    }

    // ---------------------------------------------------------------- admin ---

    function test_setEdge_cappedAndOwnerOnly() public {
        vm.prank(owner);
        vm.expectRevert(ForkFlip.EdgeTooHigh.selector);
        flip.setEdge(501);

        vm.prank(alice);
        vm.expectRevert(ForkFlip.NotOwner.selector);
        flip.setEdge(100);

        vm.prank(owner);
        flip.setEdge(500);
        assertEq(flip.edgeBps(), 500);
    }

    /// A round in flight keeps the payout it was staked at, whatever the owner
    /// does to the edge afterwards.
    function test_edgeChangeDoesNotRepriceOpenRounds() public {
        bytes32 salt = "s";
        uint256 id = _stakeAndRig(alice, 1 ether, TINES, salt, TINES);

        vm.prank(owner);
        flip.setEdge(MAX_EDGE_BPS);

        uint256 before = alice.balance;
        vm.prank(alice);
        flip.reveal(id, TINES, salt);
        assertEq(alice.balance - before, 1.98 ether, "priced at the edge it was staked at");
    }

    function test_setOwner() public {
        vm.prank(owner);
        flip.setOwner(bob);
        assertEq(flip.owner(), bob);
        vm.prank(owner);
        vm.expectRevert(ForkFlip.NotOwner.selector);
        flip.setOwner(owner);
    }

    // -------------------------------------------------------------- helpers ---

    function test_winnings_matchesQuotedPayout() public view {
        assertEq(flip.winnings(1 ether), 1.98 ether);
        assertEq(flip.winnings(0.5 ether), 0.99 ether);
    }

    function test_maxAcceptableBet_tracksBankroll() public {
        assertEq(flip.maxAcceptableBet(), MAX, "capped by maxBet while the house is deep");

        uint256 keep = flip.bankroll() - 0.98 ether;
        vm.prank(owner);
        flip.withdrawBankroll(owner, keep);
        // 0.98 ether of exposure backs exactly a 1 ether stake at a 1.98x payout.
        assertEq(flip.maxAcceptableBet(), 1 ether);

        vm.prank(alice);
        flip.flip{value: 1 ether}(_commit(TINES, "s", alice));
        assertEq(flip.maxAcceptableBet(), 0);
    }

    function test_commitmentFor_matchesWhatRevealChecks() public {
        bytes32 salt = "s";
        assertEq(flip.commitmentFor(TINES, salt, alice), _commit(TINES, salt, alice));

        uint256 id = _stakeAndRig(alice, 1 ether, TINES, salt, TINES);
        vm.prank(alice);
        flip.reveal(id, TINES, salt); // the encoding the contract advertises works
    }

    /// A cross-language vector. This is the commitment the keccak-256 in
    /// index.html produces for guess=HANDLE, this salt and this player. The
    /// frontend builds commitments itself, so if the two encodings ever drift
    /// apart every stake placed through the site becomes unrevealable. Pinning
    /// the vector here makes that drift a failing test rather than lost money.
    function test_commitmentMatchesTheFrontendVector() public view {
        bytes32 salt = 0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef;
        assertEq(
            flip.commitmentFor(HANDLE, salt, address(0xa11ce)),
            0xe616605ffc75bd50d1ddf969ddd18d8f697ddf52f43deb5c10a1ea6e37c640e2
        );
    }

    function test_revealable_reportsWindow() public {
        vm.prank(alice);
        uint256 id = flip.flip{value: 1 ether}(_commit(TINES, "s", alice));
        uint256 commitBlock = block.number;

        (bool ok, uint256 deciding, uint256 deadline) = flip.revealable(id);
        assertFalse(ok);
        assertEq(deciding, commitBlock + 1);
        assertEq(deadline, commitBlock + WINDOW);

        vm.roll(commitBlock + 2);
        (ok,,) = flip.revealable(id);
        assertTrue(ok);

        vm.roll(deadline + 1);
        (ok,,) = flip.revealable(id);
        assertFalse(ok);
    }

    /// The uint128 fields in `Round` are only safe because maxBet is bounded.
    function test_setLimits_rejectsLimitsThatCouldTruncate() public {
        uint256 ceiling = uint256(type(uint128).max) / 2;

        vm.prank(owner);
        flip.setLimits(MIN, ceiling); // exactly at the ceiling is fine
        assertEq(flip.maxBet(), ceiling);

        vm.prank(owner);
        vm.expectRevert(ForkFlip.LimitTooLarge.selector);
        flip.setLimits(MIN, ceiling + 1);

        vm.expectRevert(ForkFlip.LimitTooLarge.selector);
        new ForkFlip(owner, EDGE, MIN, ceiling + 1);
    }

    function test_setLimits_ownerOnly() public {
        vm.prank(alice);
        vm.expectRevert(ForkFlip.NotOwner.selector);
        flip.setLimits(MIN, MAX);
    }

    /// The deploy script checks EDGE_BPS against a copy of the cap before casting
    /// it to uint16. If the contract's cap moved, that check would be wrong.
    function test_deployScriptCapMatchesContract() public {
        assertEq(new Deploy().flipMaxEdge(), flip.MAX_EDGE_BPS());
    }

    // ----------------------------------------------------------------- fuzz ---

    /// Solvency is the invariant that matters: whatever sequence of stakes and
    /// outcomes runs through the contract, it always holds what it owes.
    function testFuzz_staysSolvent(uint96 rawStake, bytes32 salt, uint8 rawGuess, bool wantWin) public {
        uint256 stake = bound(uint256(rawStake), MIN, MAX);
        uint8 guess = uint8(bound(uint256(rawGuess), 0, 1));
        uint8 want = wantWin ? guess : (guess == 0 ? 1 : 0);

        vm.deal(alice, stake);
        uint256 id = _stakeAndRig(alice, stake, guess, salt, want);
        _assertSolvent();

        vm.prank(alice);
        (, bool won) = flip.reveal(id, guess, salt);

        assertEq(won, wantWin);
        _assertSolvent();
    }

    /// Over many rounds with real block hashes, the flip should land near even.
    function test_outcomeIsNotBiased() public {
        uint256 heads;
        uint256 n = 400;
        for (uint256 i = 0; i < n; i++) {
            bytes32 salt = keccak256(abi.encodePacked("salt", i));
            vm.deal(alice, 1 ether);
            vm.prank(alice);
            uint256 id = flip.flip{value: 1 ether}(_commit(TINES, salt, alice));

            uint256 deciding = block.number + 1;
            vm.roll(block.number + 2);
            vm.setBlockhash(deciding, keccak256(abi.encodePacked("block", i)));

            vm.prank(alice);
            (uint8 outcome,) = flip.reveal(id, TINES, salt);
            if (outcome == TINES) heads++;
        }
        // ~5 sigma either way; a biased bit would blow straight through this.
        assertGt(heads, n / 2 - 50);
        assertLt(heads, n / 2 + 50);
        _assertSolvent();
    }
}
