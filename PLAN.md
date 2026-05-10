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

## Files changed
- packages/nextjs/app/layout.tsx
- packages/nextjs/app/icon.svg
- packages/nextjs/app/page.tsx
- packages/nextjs/components/Header.tsx
- packages/nextjs/app/_components/ClawdSearchApp.tsx
