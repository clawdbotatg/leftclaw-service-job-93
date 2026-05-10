# Feature Plan — Job #148: Phase 3 — Charity Routing + 3-Way Split + About Page

## Scope

**A — Audit fixes (from job #147 QA report)**
- SB-1: Fix app crash — `decodeCategory()` uses array-index but viem returns named object
- SB-3: Wrong-network: action buttons must swap to "Switch to Base" CTA
- SB-4: Approve button — add finally block, prevent double-submit

**B — Phase 3 features**
1. Contract: 80/10/10 three-way split + Uniswap V3 swap + Endaoment charity routing
2. Frontend stat strip: totalBurned, totalCharityDonatedUsdc, totalCreaturesSubmitted
3. Payment modal: show per-action breakdown
4. About page: new nav tab with 3 sections

## Order of Operations

1. Rewrite ClawdSearch.sol (Phase 3) → keep all Phase 2 logic
2. Update deploy script + tests
3. Deploy to Base mainnet → get new address
4. Fix audit bugs + add new frontend features
5. Update deployedContracts.ts with new ABI + address
6. yarn build → bgipfs-ship.sh

## Key Addresses (Base mainnet)
- CLAWD: 0x9f86dB9fc6f7c9408e8Fda3Ff8ce4e78ac7a6b07
- USDC: 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
- WETH: 0x4200000000000000000000000000000000000006
- BURN_ADDRESS: 0x000000000000000000000000000000000000dEaD
- WWF_ENTITY (Endaoment): 0x3c57365d198586d6bc0e3e3f6b9a63e17425ac52
- ENDAOMENT_ORG_FUND_FACTORY: 0x10fd9348136dcea154f752fe0b6db45fc298a589
- UNISWAP_V3_ROUTER (SwapRouter02): 0x2626664c2603336E57B271c5C0b26F421741e481
- UNISWAP_V3_QUOTER (QuoterV2): 0x3d4e44Eb1374240CE5F1B136041212F0CF5d0990
- Treasury: 0x90eF2A9211A3E7CE788561E5af54C76B0Fa3aEd0

---

# Feature Plan — Job #146: Creature Feature Phase 2 (Six Active Crowns + Dynamic Categories)

---

_Phase 1 plan below for reference (Job 144):_

# Feature Plan — Job 144: Creature Feature Visual + Identity Reset (Phase 1)

## Mode
leftclaw — direct push to clawdbotatg/leftclaw-service-job-93

## Scope (all frontend-only, no contract changes)

### 1. Rebrand metadata + header
- layout.tsx: title="Creature Feature", description="Real creatures. Real competition."
- Header.tsx: text wordmark "Creature Feature" + tagline "Real creatures. Real competition.", drop 🦞
- page.tsx: update loading spinner emoji + text
- icon.svg: change favicon emoji from 🦞 to 🐾

### 2. iNaturalist scope expansion
- fetchCreatureList (was fetchLobsterList): taxon_id=1 instead of taxon_name=Homarus
- Cache key: clawd:creatures:Animalia (was clawd:lobsters:Homarus)
- "Random Lobster" → "Random Creature"; counter text "X lobsters" → "X creatures"
- fetchObservation fallback: "Lobster" → "Creature"

### 3. Homepage 6-card grid
- ACTIVE_CATEGORIES = [Cutest, LooksMostLikeCLAWDMascot] (WouldWinInAFight hidden)
- CATEGORY_META updated: LooksMostLikeCLAWDMascot displays as "Most Dapper Lobster"
- Add PLACEHOLDER_CARDS array (Most Pepe Frog, Most Pudgy Penguin, Best Bug, Best Eyes)
- Add PlaceholderCard component (Coming Soon badge, muted style, no CTAs)
- Grid: grid-cols-1 md:grid-cols-3, 2 active + 4 placeholder = 6 cards (3x2)

### 4. Lobster → creature copy site-wide
- Modal subtitle, picker headers, error messages, HowItWorks, WalletStrip network msg
- 404 photo placeholder → "This creature has returned to the wild…"
- Challenge confirm warning → "If your creature loses…"
- Hall of Fame uses ACTIVE_CATEGORIES (drops WouldWinInAFight lane)

### 5. UI improvements
- Add hero section above grid: large "Creature Feature" wordmark + tagline
- Section header: "The Three Thrones" → "The Crowns"
- Placeholder cards look intentional (styled, slightly muted, badge)
- Mobile: existing responsive classes are already touch-friendly

## Files changed (Phase 1)
- packages/nextjs/app/layout.tsx
- packages/nextjs/app/icon.svg
- packages/nextjs/app/page.tsx
- packages/nextjs/components/Header.tsx
- packages/nextjs/app/_components/ClawdSearchApp.tsx

---

# Phase 2 Plan — Job #146

## Contract changes (ClawdSearch.sol)
- Remove `enum Category`; add `CategoryData` struct + `mapping(uint256 => CategoryData)`
- Rename old `categories` mapping → `categoryStates`
- Add `nextCategoryId` counter
- Re-key all per-category storage with `uint256 categoryId`
- Constructor seeds 6 categories via `_seedCategory(name, taxonId)`
- `addCategory(string, uint32) external onlyOwner returns (uint256)` + `setCategoryActive`
- All user functions take `uint256 categoryId`; events emit `uint256 indexed categoryId`
- New events: CategoryAdded, CategorySetActive

## Category IDs (seed order)
- 0: Most Pudgy Penguin  taxon 3956
- 1: Most Dapper Lobster taxon 47764
- 2: Most Pepe Frog      taxon 20979
- 3: Cutest              taxon 1
- 4: Best Camouflage     taxon 1
- 5: Best Eyes           taxon 1

## Frontend changes
- Replace Category enum + CATEGORY_META with CATEGORY_CONFIG[6]
- `fetchCreaturePage(taxonId, page)`: per_page=200, paginated
- ActionModal: taxonId prop; Load More; direct obs ID input
- Homepage: 3×2 grid, all 6 active cards, no placeholders
- Hall of Fame: per category (categoryId 0-5)

## Files to modify
- packages/foundry/contracts/ClawdSearch.sol (full rewrite)
- packages/foundry/test/ClawdSearch.t.sol (update all enum refs)
- packages/nextjs/contracts/deployedContracts.ts (auto-regen after deploy)
- packages/nextjs/app/_components/ClawdSearchApp.tsx (full rewrite of logic layer)

---

# Feature Plan — Job 152: Audit Bug Fixes + Text Changes

## Mode
leftclaw — direct push to clawdbotatg/leftclaw-service-job-93

## Changes

### 1. Fix stale-closure bug in approval polling (SB-4)
File: `packages/nextjs/app/_components/ClawdSearchApp.tsx`
- In `handleApprove` (ActionModal): use `refetch()` return value, not stale `allowanceRead.data`.
- In `handleVote` (VoteButton): same fix for the promise-based poll.

### 2. Fix silent error handling (SF-9)
File: `packages/nextjs/app/_components/ClawdSearchApp.tsx`
- In `handleAction`: add `notification.error(...)` in the empty catch block.
- In `ResolveButton.handle`: add `notification.error(...)` in the empty catch block.

### 3. Fix wrong contract address in Footer (SB-8)
File: `packages/nextjs/components/Footer.tsx`
- Change `CONTRACT_ADDRESS` from `0x1C67563F968256778847407583d9E6aBe1e263e7`
  to `0xc4a2f0bb3fc691c7a008dddfbf9094a1ed95ba74`.

### 4. Text changes (customer request)
File: `packages/nextjs/app/_components/ClawdSearchApp.tsx`
- Change tagline for category id=1 from `"Anthropic-y. Scarlet. Pixel-poet."` → `"Drinks Tea. Builds Things;"`.
- After `Real creatures. Real competition.` add `Real Donations` as a new paragraph.
