# Feature Plan — Job #155: Apply AUDIT.md Fixes (Job 149 QA Report)

## Mode
leftclaw — direct push to clawdbotatg/leftclaw-service-job-93

## Changes

### 1. README.md — stale content (SB-8)
- Fix contract address: 0x1C67563F... → 0xc4a2f0bb3fc691c7a008dddfbf9094a1ed95ba74
- Update categories to the 6 live ones (penguin, lobster, frog, cutest, camouflage, best eyes)

### 2. ClawdSearchApp.tsx — error translation (SF-9 / UX-7)
- Import getParsedError from ~~/utils/scaffold-eth
- Use getParsedError(e) in all catch blocks for contract-specific errors

### 3. wagmiConfig.tsx — RPC reliability (SF-6 / UX-5)
- Remove bare http() from fallback chain when real Alchemy key is in use

### 4. useWriteAndOpen.ts — mobile guard (SF-13)
- Add window.ethereum check: skip deep-link if already inside wallet browser

### 5. .env.production — bake Alchemy key + OG URL (SF-6, SF-4)
- Set NEXT_PUBLIC_ALCHEMY_API_KEY and NEXT_PUBLIC_PRODUCTION_URL

## Out of scope
- USD/CLAWD price conversion (SF-3, UX-4) — no Uniswap price utility in repo
- Contract verification (SB-5 MANUAL) — requires Etherscan key

---

# Feature Plan — Job #154: Text Fixes + Submit Champion Error

## Mode
leftclaw — direct push to clawdbotatg/leftclaw-service-job-93

## Root cause investigation — submit champion error
- TypeScript check passes — no type errors
- Code logic is correct — no obvious JS render error found
- polyfill-localstorage.cjs was missing from git (present on filesystem at prior build time)
- se2-prep run: polyfill restored, ScaffoldEthAppWithProviders and next.config.ts verified
- Fresh rebuild with polyfill in place should fix any corrupted static export from prior build

## Changes

### 1. "Drinks Tea. Builds Things;" → "Drinks Tea. Builds Things."
File: `packages/nextjs/app/_components/ClawdSearchApp.tsx`
CATEGORY_CONFIG id=1 tagline — change semicolon to period.

### 2. "Real Donations" → "Real donations." on same plane as "Real creatures. Real competition."
File: `packages/nextjs/app/_components/ClawdSearchApp.tsx`
Header section — merge into one paragraph so they appear at the same visual level.
Change "Real Donations" → "Real donations."

### 3. "USDC to wildlife" → "USDC to World Wildlife Fund"
File: `packages/nextjs/app/_components/ClawdSearchApp.tsx`
StatStrip — change the label under the charity stat box.

---

_Previous plans preserved below for reference._

# Feature Plan — Job #152: Audit Bug Fixes + Text Changes

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

---

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
