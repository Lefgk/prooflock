# Prooflock

Permissionless USDC escrow for one agent job on Ethereum. The client funds a job, the provider submits a deliverable hash, and funds release on accept, auto-release after a review window, a missed-deadline refund, or an arbiter split.

> Prototype, **not audited**. It targets **Ethereum mainnet (1)** and **Base (8453)**, plus local anvil (31337) for development. The deploy scripts refuse any other chain and **refuse to broadcast on 1/8453 unless `CONFIRM_MAINNET=yes`**. Nothing has been deployed.

See [SPEC.md](SPEC.md) for the problem, competitors and choices, and [DEPLOY.md](DEPLOY.md) for the full deploy runbook.

## Layout
| Path | What |
|---|---|
| `src/Prooflock.sol` | Job escrow: create, bond, deliver, accept, auto-release, refund, dispute, resolve, fees |
| `src/MockUSDC.sol` | 6-decimal test token, used locally only |
| `test/` | Unit, fuzz and invariant tests (Foundry) |
| `test/fork/` | Fork tests against the real Circle USDC, plus a fork test of `Deploy.s.sol` |
| `script/Deploy.s.sol`, `script/DeployConfig.sol` | Deploy script and per-chain config (USDC addresses, live-chain flag) |
| `script/deploy.sh`, `script/verify.sh`, `script/deploy-anvil.sh` | Dry-run/broadcast wrapper, Etherscan v2 verify, local deploy |
| `script/dry-run-fork.sh`, `script/write-web-config.sh` | Anvil-fork dry run (port 8626) and dapp-config writer |
| `web/` | Vite + React + wagmi/viem dapp (Ethereum, Base and anvil) |
| `web/src/deployments.json` | Per-chain Prooflock/USDC addresses written by a successful deploy |
| `docs/slither-report.txt` | Static-analysis output |
| `Makefile` | One-command test, dapp build, dry-run and deploy targets |

## Contract model
- `createJob` pulls the job amount in USDC from the client. The provider, deadline, optional arbiter, optional bond, review window and optional ERC-8004 agent IDs are set here. The current protocol fee is snapshotted onto the job.
- `postBond` is required before `deliver` when a bond was set. `deliver` posts a hash/URI before the deadline and starts the review window.
- `accept` (client) or `autoRelease` (anyone, after the review window) pays the provider minus the snapshotted fee and returns the bond.
- `refund` (anyone, after a missed deadline with no delivery) returns the amount to the client and the bond to the provider.
- `dispute` (client, during review, only if an arbiter was named) then `resolve` (arbiter): a split of the amount is allowed, and the arbiter may slash the bond to the client.
- Fees default to 0, are capped at 5% (500 bps), and are taken only from the provider's payout. Owner uses `Ownable2Step`.

## Run the dapp

```bash
cd web
npm install
# optional: cp .env.example .env   # only to override RPCs or contract addresses
npm run dev      # http://localhost:5173
npm run build    # production build
```

The dapp is Vite + React + wagmi/viem, on Ethereum mainnet and Base (and local anvil). Contract addresses come from `web/src/deployments.json`, with optional `VITE_PROOFLOCK_*` / `VITE_USDC_*` overrides in `web/.env`. When the Prooflock address for the selected chain is empty, the page shows a clear **Not deployed yet** state and disables create-job.

Connect a wallet, switch network, then: create a job, look one up by id, post a bond, submit a deliverable, accept, dispute, refund, auto-release, or resolve a split.

## Tests

Needs Foundry (`forge` / `anvil`; this repo expects `~/.foundry/bin` on `PATH`) and Node 20+.

```bash
forge build
forge test              # unit, fuzz, invariant, and anvil deploy-script tests; fork tests skip without a fork
make dry-run-mainnet    # Deploy.s.sol dry-run + CONFIRM_MAINNET guard, on an anvil mainnet fork at port 8626
```

Fork tests (real Circle USDC, plus the deploy-script fork tests). Use **port 8626 only**:

```bash
anvil --port 8626 --fork-url https://ethereum-rpc.publicnode.com   # Ethereum fork
make test-fork-mainnet
# Then restart the same port as a Base fork:
anvil --port 8626 --fork-url https://mainnet.base.org
make test-fork-base
```

## Deploy to Ethereum or Base (not done: needs Lef's wallet and OK)

| Chain | Id | USDC (checked on fork: symbol USDC, 6 decimals) |
|---|---|---|
| Ethereum mainnet | 1 | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` |
| Base | 8453 | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |

Once the wallet is set (Foundry keystore account, keystore file, or `DEPLOYER_KEY` in a git-ignored `.env`):

```bash
cp .env.example .env && set -a && source .env && set +a
make dry-run-mainnet                 # local anvil fork on port 8626; sends nothing
CONFIRM_MAINNET=yes make deploy-mainnet
CONFIRM_MAINNET=yes make deploy-base
```

A successful broadcast writes the Prooflock address into `web/src/deployments.json` and, if `ETHERSCAN_API_KEY` is set, verifies via the Etherscan v2 API. See [DEPLOY.md](DEPLOY.md) for signer options and `./script/verify.sh`.

- `deploy.sh` and `Deploy.s.sol` both print the chain. Each refuses to broadcast on 1 or 8453 without `CONFIRM_MAINNET=yes`, so the guard holds even if someone calls `forge script` directly.
- Never commit `.env`, keys, or `broadcast/`.

## Local end-to-end (anvil, no keys)

```bash
anvil --port 8626                     # terminal 1 (chain 31337)
./script/deploy-anvil.sh
cd web && npm install && npm run dev
```

The anvil deploy uses anvil's unlocked dev accounts, so no private key is stored anywhere.

## Regenerate ABIs
`forge build && node tools/gen-abi.mjs` writes `web/src/abi.ts`.

## Contact

Support and questions: [lg.playstudio@gmail.com](mailto:lg.playstudio@gmail.com)
