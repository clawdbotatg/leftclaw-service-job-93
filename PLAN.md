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
