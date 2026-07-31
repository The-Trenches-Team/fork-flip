# Fork Flip

A coin flip, but it's a fork. Call **tines** or **handle**, watch it spin, find out.

**Play:** https://the-trenches-team.github.io/fork-flip/

Two modes:

- **Free play** — runs entirely in the page. `crypto.getRandomValues` with
  modulo-bias rejection, stats in `localStorage`. No wallet, no network.
- **$FORKIN** — stake the gas token of [Fork in Hood](https://forkinhood.com)
  (chain `36754663`) against the `ForkFlip` contract. Needs a deployed address;
  see [DEPLOY.md](DEPLOY.md).

One HTML file, no build step, no dependencies, no backend. The keccak-256 the
page needs to build commitments is ~60 lines of BigInt, lifted from
`forkinhood/verify.mjs`, and it self-tests against known digests before the page
will send a transaction.

## How the on-chain flip works

Two transactions:

1. `flip(commitment)` with FORKIN attached, where the commitment is
   `keccak256(guess, salt, player)` and the salt is random and secret.
2. `reveal(id, guess, salt)` at least two blocks later. The outcome is
   `keccak256(salt, blockhash(commitBlock + 1), id) & 1`.

Neither side can steer it. You cannot, because the deciding block does not exist
when you pick the salt, and the commitment locks the salt before it does. The
house cannot, because the salt stays secret until the reveal — the sequencer
does control block hashes, but without the salt it has no way to know which hash
produces which outcome.

A win pays 1.98x by default; the house edge is capped at 2.5% in the contract and
cannot be raised past it. A round already staked keeps the payout it was staked
at, whatever the owner changes afterwards.

Not revealing is never profitable: an expired round forfeits the stake, which is
exactly what losing costs.

One wrinkle worth knowing about: Fork in Hood only produces blocks when there
are transactions to put in them. On a quiet chain the block that decides your
flip would never arrive on its own, so the page waits briefly and then makes the
blocks itself with zero-value self-sends. That is why a flip can ask your wallet
to sign more than twice. It costs gas and nothing else.

The honest caveat, also in [DEPLOY.md](DEPLOY.md): Fork in Hood has one
sequencer. It cannot aim your flip, but it can refuse to sequence your reveal
until the 200-block window closes. That is inherent to a chain with one
sequencer, not something this contract can fix.

## Contracts

```bash
git clone https://github.com/The-Trenches-Team/fork-flip.git
cd fork-flip && forge install --no-git foundry-rs/forge-std && forge test
```

36 tests, including a solvency invariant (`balance == bankroll + lockedFunds`
after every operation), a check that the owner cannot withdraw money an open
round is owed, and a cross-language vector pinning the browser's commitment
encoding to the contract's.

Not audited.

## Run locally

Open `index.html` in a browser. That's it.

## License

MIT
