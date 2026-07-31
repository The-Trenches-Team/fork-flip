# Deploying ForkFlip

Everything below runs against Fork in Hood, chain `36754663`, RPC
`https://rpc.forkinhood.com`, gas token `$FORKIN`.

You need a key with enough FORKIN to cover the bankroll plus gas. Nothing here
asks for that key except `forge script`, and it is never written to the repo.

## 0. Get the repo

`fork-flip` is its own repository. Every command below runs from its root, not
from `fork-in-hood`.

```bash
git clone https://github.com/The-Trenches-Team/fork-flip.git
```

## 1. Tests first

```bash
cd fork-flip && forge install foundry-rs/forge-std && forge test
```

`foundry.toml` is at the repo root rather than under `contracts/`, because
`forge install` resolves paths from the git root: a nested config would quietly
drop `forge-std` one directory above the config that references it.

36 tests. The one to look at is `test_commitmentMatchesTheFrontendVector`, which
pins the commitment encoding that `index.html` builds in the browser. If that
ever fails, the site would be placing stakes nobody can reveal.

## 2. Deploy

```bash
PRIVATE_KEY=0xYOUR_REAL_KEY BANKROLL=100000000000000000000 forge script contracts/script/Deploy.s.sol:Deploy --rpc-url https://rpc.forkinhood.com --broadcast
```

`PRIVATE_KEY` has to be an actual 64-hex-character key. A literal `0x…` fails
before anything is broadcast.

Environment it reads:

| | | default |
|---|---|---|
| `PRIVATE_KEY` | deployer, and the owner unless `OWNER` is set | required |
| `OWNER` | the only address that can withdraw the bankroll | the deployer |
| `BANKROLL` | starting house capital, in wei | 100 FORKIN |
| `EDGE_BPS` | house edge, capped at 500 by the contract | 200 → a win pays 1.98x |
| `MIN_BET` / `MAX_BET` | accepted stake range, in wei | 0.01 / 10 FORKIN |

The bankroll is sent in the deploying transaction, so the contract is never live
with nothing behind it.

## 3. Point the site at it

Set `CFG.contract` in `index.html` to the deployed address, commit, push. GitHub
Pages redeploys on its own.

Before editing anything you can try a deployment live by appending
`?contract=0x…` to the URL — the page accepts an address that way and plays
against it.

## 4. Running it

- `maxAcceptableBet()` is the largest stake the bankroll can currently back. It
  falls as rounds open and rises as they settle; the site shows it.
- `withdrawBankroll(to, amount)` only ever touches `bankroll`, never
  `lockedFunds`. Draining it stops new flips; it cannot strand a player mid-round.
- `fund()` (or a plain transfer) tops the bankroll back up. There is no share
  issued in return — it is a donation to the house, not an investment in it.
- Rounds nobody reveals within 200 blocks can be closed by anyone with
  `forfeit(id)`, which returns the tied-up exposure to the bankroll.

## What this does not solve

Fork in Hood has one sequencer, and you run it. The commit-reveal means you
cannot *aim* an outcome — the salt is secret until the reveal, so grinding block
hashes is grinding blind — but you can still refuse to sequence a reveal until
its window closes and take the stake. A 200-block window makes that obvious
rather than subtle. It is not removed, because on a one-sequencer chain it
cannot be.

Two operational notes worth deciding on deliberately before this holds real
value: a contract taking wagers in a live token is a real-money gambling
service, with whatever that implies where you and your players are; and
nothing here has had an outside audit.
