# 🎪 Creature Feature

**Real creatures. Real competition. Real donations.**

Creature Feature is an on-chain king-of-the-hill tournament where the community
crowns iNaturalist observations as champions of six categories — and donates
CLAWD to wildlife conservation in the process.

**Live URL:** https://bafybeickojnyakrcpf5fuxeha2lrylqlh4dds4hwk2vlxfssie4ls27oaa.ipfs.community.bgipfs.com/
- **Chain:** Base (8453)
- **Contract:** [`0xc4a2f0bb3fc691c7a008dddfbf9094a1ed95ba74`](https://basescan.org/address/0xc4a2f0bb3fc691c7a008dddfbf9094a1ed95ba74)
- **CLAWD token:** [`0x9f86dB9fc6f7c9408e8Fda3Ff8ce4e78ac7a6b07`](https://basescan.org/token/0x9f86dB9fc6f7c9408e8Fda3Ff8ce4e78ac7a6b07)

## The six categories

| # | Category | Emoji | Taxon |
|---|---|---|---|
| 0 | Most Pudgy Penguin | 🐧 | Penguins |
| 1 | Most Dapper Lobster | 🦞 | Lobsters |
| 2 | Most Pepe Frog | 🐸 | Frogs |
| 3 | Cutest | 🥺 | Any |
| 4 | Best Camouflage | 🦎 | Any |
| 5 | Best Eyes | 👁️ | Any |

## How to play

1. **Submit a Champion.** Pick a real observation from iNaturalist and spend
   **1,000 CLAWD** to crown it champion of a category. Funds split: 80% to
   wildlife conservation (World Wildlife Fund via Endaoment), 10% burned, 10%
   to the builders fund.
2. **Challenge.** Spend **100 CLAWD** to open a 48-hour challenge against the
   current champion.
3. **Vote.** During an active challenge, anyone can vote for **100 CLAWD**.
   One vote per wallet per challenge. Ties go to the defending champion.
4. **Resolve.** After 48 hours, anyone can call `resolve()`. Most votes wins.
   Zero votes? Challenger takes the throne by default.

A losing observation cannot challenge again in the same category — but is free
to take a shot at a different one.

## Local development

```bash
yarn install

# Foundry: fork Base for realistic local testing
yarn fork --network base
yarn deploy --network localhost

# In a third terminal:
yarn start    # http://localhost:3000
```

## Deploy

```bash
yarn deploy --network base
yarn verify --network base
```

The frontend is a static Next.js export, deployed to IPFS via
[bgipfs](https://bgipfs.com/).

```bash
cd packages/nextjs
yarn build              # → packages/nextjs/out/
npx bgipfs upload out
```

## Tech stack

- **Smart contracts:** Foundry, Solidity 0.8.x, OpenZeppelin v5
  (`Ownable2Step`, `ReentrancyGuard`, `SafeERC20`)
- **Frontend:** Scaffold-ETH 2 (Next.js App Router), RainbowKit, Wagmi, Viem,
  TypeScript, Tailwind CSS + DaisyUI
- **Lobster data:** [iNaturalist API](https://api.inaturalist.org/v1) — only
  research-grade observations with S3-hosted photos are surfaced
- **Hosting:** static export on IPFS (community.bgipfs.com gateway)

## Architecture notes

- **Token split.** Every paid action (`submit` / `challenge` / `vote`) splits
  the cost 50/50 between the burn address and the treasury, with any odd-wei
  remainder going to the burn side.
- **Lockout.** A losing observation in a category is permanently locked out of
  that category — but can still challenge in the other two.
- **Cooldown.** A 1-hour cooldown begins after every resolved challenge,
  preventing rapid-fire flips.
- **Renouncement disabled.** `renounceOwnership` is overridden to revert,
  because admin functions (treasury, prices) have no on-chain upgrade path.

## Disclaimer

Built by a community member using **LeftClaw Services** (beta). Not affiliated
with iNaturalist, $CLAWD, or any other project. Observation data and photos
from iNaturalist. Do your own research.

---

Built via [LeftClaw Services](https://leftclaw.services) job #93.
