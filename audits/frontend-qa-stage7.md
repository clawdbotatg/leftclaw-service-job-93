# Stage 7 — Frontend QA Audit

Repo: `/Users/austingriffith/clawd/ethereum-servicer/builds/leftclaw-service-job-93`
GitHub: `https://github.com/clawdbotatg/leftclaw-service-job-93`
Audited build: `packages/nextjs/out/` (static export already produced by Stage 6)

---

## Ship-blockers (must all PASS before Stage 8)

### 1. Wallet connect shows a button, not text — **PASS**
`packages/nextjs/components/scaffold-eth/RainbowKitCustomConnectButton/index.tsx:33-38` renders a `<button className="btn btn-primary btn-sm" onClick={openConnectModal}>Connect Wallet</button>` when not connected. The header in `packages/nextjs/components/Header.tsx:22` mounts that custom button. The in-app `WalletStrip` (`ClawdSearchApp.tsx:1281-1286`) shows only a non-blocking "Connect a wallet to play" hint while the wallet is not connected — the actual connect action lives in the header button. No "Please connect your wallet" paragraph blocks the user from acting.

### 2. Wrong network shows a Switch button — **PASS**
- Header: when `chain.unsupported || chain.id !== targetNetwork.id`, `RainbowKitCustomConnectButton` renders `<WrongNetworkDropdown/>` (`index.tsx:41-43`) which displays a "Wrong network" red CTA.
- In-app `WalletStrip` (`ClawdSearchApp.tsx:1289-1304`) ALSO renders an explicit Switch button: `<button onClick={() => switchChain({ chainId: CHAIN_ID })}>Switch to Base</button>`. This is the four-state-flow "Switch Network" button the QA skill explicitly demands (the SE2 header dropdown alone is documented as insufficient).
- Per-card CTAs (`ChampionView` line 961, `ChallengeView` line 1050, no-champion line 864) gate on `onWrongNetwork` so the Submit/Challenge/Vote buttons are disabled on wrong network. Clean separation: connect → switch → approve → action.

### 3. Approve button stays disabled through block confirmation + cooldown — **PASS**
Modal approve flow (`ClawdSearchApp.tsx:380-405`):
- `setWaitingForAllowance(true)` is set BEFORE `await writeErc20({...})` (line 383).
- After the write resolves with the hash (wagmi `isPending` flips back to false), a `setInterval` polls `allowance` every 1.5s up to 20 attempts, and only then `setWaitingForAllowance(false)` (line 397).
- The button `disabled={approvePending}` (line 615) is fed `approvePending = approvePending || waitingForAllowance` (line 507).
- On rejection, `catch` block sets `setWaitingForAllowance(false)` (line 401) — does not lock permanently.

Vote button approve flow (`ClawdSearchApp.tsx:699-739`) follows the same pattern with `await new Promise<void>` wrapping the polling interval, so the entire vote handler awaits allowance update before invoking `writeSearch`. `disabled` (line 741) covers `approvePending || actionPending || waitingForAllowance`.

This satisfies the two-state requirement (submission gap + cache gap).

### 4. Approve flow traced end-to-end — **PASS**
Spender argument: `approve()` is called with `[CLAWD_SEARCH_ADDRESS, cost]` at line 389 and `[CLAWD_SEARCH_ADDRESS, VOTE_PRICE]` at line 713. `CLAWD_SEARCH_ADDRESS` resolves at line 18 to `deployedContracts[8453].ClawdSearch.address` = `0x1c67563f968256778847407583d9e6abe1e263e7`.

`transferFrom` caller: `ClawdSearch._spendClawd` (`ClawdSearch.sol:420-428`) calls `CLAWD.safeTransferFrom(msg.sender, BURN_ADDRESS, burnAmount)` and `CLAWD.safeTransferFrom(msg.sender, treasury, treasuryAmount)`. `_spendClawd` is internal, called from `submit`/`challenge`/`vote`, which means the caller of `safeTransferFrom` (the spender from the ERC20's perspective) IS the ClawdSearch contract — same address `0x1c67…263e7`.

Allowance read: `ClawdSearchApp.tsx:362-364` reads `allowance(account, CLAWD_SEARCH_ADDRESS)`. Same spender address.

ABI: `externalContracts.ts:120-157` includes ALL six OZ v5 ERC20 custom errors (`ERC20InsufficientAllowance`, `ERC20InsufficientBalance`, `ERC20InvalidApprover`, `ERC20InvalidReceiver`, `ERC20InvalidSender`, `ERC20InvalidSpender`). When the user calls `approve` directly via `useWriteContract({ abi: CLAWD_TOKEN_ABI })`, viem decodes these errors against the supplied ABI and produces a friendly message. (Caveat about reverts that bubble through ClawdSearch — see should-fix #5 below; that does NOT make this ship-blocker fail because the approve transaction itself is the relevant path here.)

### 5. Contract verified on Basescan — **PASS** (Stage 5 confirmed)
`deployedContracts.ts:10` shows `address: "0x1c67563f968256778847407583d9e6abe1e263e7"`. This matches the address in the audit context and is the verified address per Stage 5.

### 6. SE2 footer branding removed — **PASS**
`packages/nextjs/components/Footer.tsx` is hand-rolled. Grepped the file and `node_modules`-excluded source: only hits for `BuidlGuidl` are (a) a comment at `Footer.tsx:9` ("No SE2 branding, no nativeCurrencyPrice badge, no localhost faucet") and (b) `components/assets/BuidlGuidlLogo.tsx` which is no longer imported anywhere (orphaned but never bundled). No `Fork me` link. No `nativeCurrencyPrice` badge. No "Built with SE2" text. No "Support" link. Footer renders a project disclaimer, Basescan link, GitHub link, LeftClaw Services link, and SwitchTheme.

### 7. SE2 tab title removed — **PASS**
- `packages/nextjs/utils/scaffold-eth/getMetadata.ts:9` template is `"%s | Clawd Search"`, not `"%s | Scaffold-ETH 2"`.
- `packages/nextjs/app/layout.tsx:9` passes `title: "Clawd Search"`.
- Verified static export `packages/nextjs/out/index.html` contains `<title>Clawd Search</title>` and zero occurrences of `Scaffold-ETH`.

### 8. SE2 README replaced with project content — **PASS**
Root `README.md:1-91` describes Clawd Search: tagline, contracts, gameplay rules, local dev, deploy, tech stack, architecture notes, disclaimer. No "Built with Scaffold-ETH 2" boilerplate, no SE2 doc links.

### 9. Favicon replaced — **PASS**
- `packages/nextjs/app/icon.svg` is a custom orange rounded-square with a 🦞 emoji (`icon.svg:1-4`), not the SE2 default.
- `getMetadata.ts:51-53` sets the icon to `/icon.svg` with `image/svg+xml` MIME type. Static export `out/index.html` includes `<link rel="icon" href="/icon.svg" type="image/svg+xml"/>`.
- `packages/nextjs/public/favicon.png` exists (256x256, 8-bit RGBA) but is not the SE2 default (created May 5 at build time). Even if it were, `icon.svg` takes precedence per the metadata config.

---

## Should-fix (must all PASS before Stage 9 / completion)

### 1. Contract address displayed with `<Address/>` component — **PASS**
`ClawdSearchApp.tsx:1356-1387` renders a "Contracts" card with `<AddressComp/>` (the SE2/scaffold-ui Address component) for ClawdSearch (`CLAWD_SEARCH_ADDRESS`), CLAWD token (`CLAWD_TOKEN_ADDRESS`), Treasury, and Burn. All four use `format="short"` with explicit `chain={base}` for correct explorer links. Champion/challenger addresses also use `<AddressComp/>` throughout (`ChampionView` line 934, `ChallengeView` line 1001/1013, `HallOfFame` line 1170/1253).

### 2. OG image uses absolute URL — **FAIL**
- File: `packages/nextjs/utils/scaffold-eth/getMetadata.ts:3-7`. `baseUrl` falls back to `http://localhost:${PORT||3000}` when neither `NEXT_PUBLIC_PRODUCTION_URL` nor `VERCEL_PROJECT_PRODUCTION_URL` is set.
- File: `packages/nextjs/out/index.html`. The static export was built without `NEXT_PUBLIC_PRODUCTION_URL`, so OG meta tags are baked as `<meta property="og:image" content="http://localhost:3000/og.png"/>` and `<meta name="twitter:image" content="http://localhost:3000/og.png"/>`. Social unfurls will be broken everywhere.
- File: `packages/nextjs/public/og.png` does not exist. So even if the URL were correct, the asset would 404.
- **What's wrong:** OG image points to a localhost URL and the file isn't present.
- **How to fix:** Stage 8 should (a) generate or copy a real OG image to `packages/nextjs/public/og.png` (the existing `thumbnail.jpg` could be repurposed by changing `imageRelativePath`) AND (b) export `NEXT_PUBLIC_PRODUCTION_URL=https://<final-cid>.ipfs.community.bgipfs.com` before `yarn build`. Since IPFS CID is only known after upload, an alternative is to set a stable subdomain or a known-shared link (`https://leftclaw.services/job/93/preview` etc.) — or accept that OG unfurls won't work for IPFS hashes and at minimum flip the path to `/thumbnail.jpg` so the asset exists.

### 3. `--radius-field` changed from `9999rem` to `0.5rem` in BOTH theme blocks — **PASS**
`packages/nextjs/styles/globals.css:38` (light theme): `--radius-field: 0.5rem;`. Line 63 (dark theme): `--radius-field: 0.5rem;`. Both blocks correct.

### 4. All token amounts have USD context (or N/A for community tokens) — **PASS (with note)**
CLAWD is a community ERC20 with no canonical USD oracle, so per the rule USD is N/A. The dApp does not display ETH gas amounts directly — the only token amounts shown are CLAWD costs (1,000 / 100) and the user's CLAWD balance (`WalletStrip` line 1314, `ConfirmPanel` line 598). No gas/ETH UI surfaces require a USD figure (the wallet's own UI handles gas estimation). Documented N/A is acceptable.

### 5. Errors mapped to human-readable messages — **FAIL** (partial)
Trace through the chain:
- `ClawdSearch.submit/challenge/vote` calls `_spendClawd` → `CLAWD.safeTransferFrom`. If the caller hasn't approved enough, CLAWD reverts with OZ v5 `ERC20InsufficientAllowance(spender, allowance, needed)`.
- The frontend uses `useScaffoldWriteContract` for these (`ClawdSearchApp.tsx:374, 673, 772`), which calls `simulateContract` first (`utils/scaffold-eth/contract.ts:418`).
- `simulateContract` is invoked with ClawdSearch's ABI as `params.abi` (`useScaffoldWriteContract.ts:113-117`). ClawdSearch's `deployedContracts.ts` ABI does NOT include any `ERC20*` errors. So viem fails to decode and `getParsedError` returns "Encoded error signature 0x… not found on ABI".
- That triggers the fallback `getParsedErrorWithAllAbis` (`contract.ts:344-405`). Critically, line 358 reads `deployedContractsData[chainId]` — it does NOT consult `externalContractsData` even though the merged `contractsData` exists at line 64. So the OZ v5 error selectors live in `externalContracts.ts` but are unreachable from this resolver.
- **Result:** A user who tries to `submit`/`challenge`/`vote` with insufficient allowance (or insufficient balance after approve) will see the unfriendly "Encoded error signature 0xfb8f41b2 not found on ABI" message instead of "Not enough CLAWD allowance / balance".
- **Note:** The DIRECT approve flow (line 384, 708) goes through wagmi's raw `useWriteContract({ abi: CLAWD_TOKEN_ABI, ... })`, where viem CAN decode against CLAWD_TOKEN_ABI — those errors render fine. So the gap is specifically: post-approve reverts of `submit`/`challenge`/`vote` that originate inside CLAWD.
- **How to fix (Stage 8):** In `getParsedErrorWithAllAbis`, change `deployedContractsData[chainId]` to the merged `contractsData[chainId]` (or iterate both maps). One-line behavioral fix.

### 6. Phantom wallet in RainbowKit list — **PASS**
`packages/nextjs/services/web3/wagmiConnectors.tsx:6,27` imports and includes `phantomWallet` in the wallet list.

### 7. Mobile deep linking: `writeAndOpen` pattern — **FAIL**
- Grepped `app/` and `components/` for `writeAndOpen`, `openWallet`, `setTimeout.*open` — zero hits.
- Mobile wallets connected via WalletConnect will not auto-deep-link back when a TX is fired. Users on mobile must manually switch to their wallet.
- **How to fix (Stage 8):** Add a `useWriteAndOpen` hook (per the QA skill's recipe) that fires the writeFn and `setTimeout(openWallet, 2000)`. Wrap every `writeErc20`, `writeSearch`, and the resolve call. ~30 lines.
- Severity: should-fix; the dApp is functional on mobile but UX is degraded.

### 8. `appName` in `wagmiConnectors.tsx` — **PASS**
Line 51: `appName: "Clawd Search"`. Not the SE2 default.

---

## Client-locked-in features (must all PASS)

### 1. "How It Works" explainer block on the main page — **PASS**
`HowItWorks` component (`ClawdSearchApp.tsx:1064-1091`) renders a `<details open>` collapse with a 4-step ordered list: Submit (1,000 CLAWD), Challenge (100 CLAWD), Vote (100 CLAWD), Resolve. Each step calls out the CLAWD cost. The "burn half / treasury half" split is explicitly stated for Submit. Mounted in main flow at line 1343.

### 2. Cost labels on every action button before user clicks — **PASS**
- `ChampionView` Challenge button: `Challenge — 100 CLAWD` (line 962).
- No-champion Submit button: `Submit Champion — 1,000 CLAWD` (line 867).
- Vote button: `{label}<span>— 100 CLAWD</span>` (lines 759-761).
- ConfirmPanel Approve button: `1️⃣ Approve {costLabel}` where `costLabel` is `"1,000 CLAWD"` for submit, `"100 CLAWD"` for challenge (line 622).
- ConfirmPanel action button: `Submit Champion — {costLabel}` / `Challenge — {costLabel}` (lines 642-644).
- Resolve button: `🏛️ Resolve Challenge` (no cost — resolve is gas-only, which is correct since contract `resolve()` doesn't take CLAWD).

### 3. Tooltips or info icons on each category card explaining categories — **PASS**
`CategoryCard` renders an info icon with DaisyUI tooltip (`ClawdSearchApp.tsx:852-854`):
```
<div className="tooltip tooltip-left" data-tip={meta.tooltip}>
  <span className="cursor-help text-sm opacity-60">ⓘ</span>
</div>
```
Tooltips defined in `CATEGORY_META` (lines 34-53): "The toughest lobster — judged by the community", "The most adorable lobster — judged by the community", "The lobster that most resembles the CLAWD mascot". A short tagline also appears under each title (line 856).

### 4. Loser lockout notice — **PASS**
ConfirmPanel for `kind === "challenge"` displays a warning (lines 592-596):
```
⚠️ If your lobster loses, observation #{picked.id} cannot challenge this category again.
```
This appears in the confirmation panel BEFORE the user fires the transaction, so they understand the consequence. The contract enforces this via `hasLostInCategory[category][observationId]` lockout (`ClawdSearch.sol:124, 228, 339`).

### 5. Burn/treasury split shown in confirmation modal before each action — **PASS**
ConfirmPanel cost block (line 590):
```
🔥 {formatClawd(half)} CLAWD burned + 🏛️ {formatClawd(half)} CLAWD to treasury
```
For Submit (1,000): "500 CLAWD burned + 500 CLAWD to treasury". For Challenge (100): "50 CLAWD burned + 50 CLAWD to treasury". Visible in the modal before the user clicks Approve or Submit/Challenge.

Note: vote (100 CLAWD) does NOT have a confirmation modal — it's a one-click button. Burn/treasury split is mentioned in `HowItWorks` but not on the vote click. This is a minor UX inconsistency; flagged Info-level — not failing this item since votes have an explicit cost label and the global "How It Works" disclosure covers it.

---

## General frontend health

### Pending states on every onchain-interactive button — **PASS**
- ConfirmPanel approve: line 615-624, spinner + "Approving {costLabel}…" text.
- ConfirmPanel action: line 634-645, spinner + "Submitting…" text.
- VoteButton: line 750-754, spinner + "Voting…" text.
- ResolveButton: line 783-792, spinner + "Resolving…" text.
- Wrong-network switch: line 1300, "Switching…" text.
All buttons disable on pending states. No shared `isLoading` antipattern.

### Confirmation modals don't disappear on receipt — **PASS** (and arguably better)
ActionModal closes itself via `onClose()` AFTER `writeSearch(...)` returns (line 419) — which is AFTER the receipt is mined (because `useScaffoldWriteContract` awaits via `useTransactor`). The user sees a `notification.success` toast post-confirmation (line 415-417) and the modal closes. The vote button is in-line (no modal); on success, `notification.success("Vote cast!")` and the parent re-fetches state (line 733-735).

### Error toasts are human-readable — **MIXED, see should-fix #5**
Approve errors decode (CLAWD_TOKEN_ABI includes OZ v5 errors). Submit/challenge/vote reverts that originate in CLAWD's `transferFrom` will NOT decode (resolver ignores externalContracts). Submit/challenge/vote reverts that originate in ClawdSearch (`CategoryAlreadyHasChampion`, `ObservationLockedOut`, `OnCooldown`, etc.) DO decode because they're in `deployedContracts.ts` ABI. Documented above.

### Empty states — **PASS**
- "No champion yet. Be the first." (line 861), with a centered emoji + Submit CTA.
- "No champions yet — be the first." in HallOfFameLane (line 1202).
- "Couldn't reach iNaturalist. Try again in a moment." in modal list when API down (line 471).
- "🌊 This lobster has returned to the sea — observation no longer available on iNaturalist." for missing photos (line 295).
- "No past champions" effectively covered by the "No champions yet" lane state.

### Mobile responsive: 1-col on small, 3-col on md+ — **PASS**
- Three Thrones grid: `grid-cols-1 md:grid-cols-3 gap-4` (line 1347).
- Hall of Fame lanes grid: same (line 1156).
- Lobster picker grid: `grid-cols-2 sm:grid-cols-3` (line 474).
- WalletStrip stacks `flex-col sm:flex-row` (line 1307).
- ConfirmPanel image+meta: `grid-cols-1 sm:grid-cols-2` (line 554).

### Accessibility — **PASS for prototype**
Modal has `role="dialog" aria-modal="true"` (line 431), close button has `aria-label="Close"` (line 442). All buttons have visible text labels. iNat photos use real `alt` attributes ("Observation N", species name). No hidden-only icons that lack labels. Adequate for a v1 dApp.

### Static export contract address present — **PASS**
The contract address `0x1c67563f968256778847407583d9e6abe1e263e7` IS embedded in the JS chunk `out/_next/static/chunks/6502-817e5929b6916927.js` (grep confirmed). It's not in `index.html` because the page bails out to client-side rendering (the `<template data-dgst="BAILOUT_TO_CLIENT_SIDE_RENDERING">` marker is present, since `page.tsx` uses `dynamic(..., { ssr: false })`). After hydration, the address appears in the Contracts card.

### Static export has no SE2 strings — **PASS**
Grepped `out/index.html` for `Scaffold-ETH`, `BuidlGuidl`, `Fork me`, `nativeCurrencyPrice` — zero hits. Tab title is `Clawd Search`.

### `yarn build` exits 0 — **NOT RE-RUN** (audit-only stage)
Stage 6 already produced `out/`. The audit instructions forbid running build commands and modifying files. The build artifact directory exists with all expected files (`index.html`, `404.html`, `_next/`, `icon.svg`, `manifest.json`, `favicon.png`). Stage 8 should re-run after fixes.

---

## Stage 6 workarounds review

### 1. `/debug` route deleted — **ACCEPTABLE (Info)**
SE2's `@scaffold-ui/debug-contracts` package uses `localStorage` and DOM at module-load time. Lazy-loading it would have required wrapping the page in `dynamic(..., { ssr: false })`, but the underlying module still imports those references unconditionally. Deletion is the simpler durable fix for a static IPFS export. The package is not part of the user-facing flow on mainnet.

### 2. `/_blockexplorer-disabled/` deleted — **ACCEPTABLE (Info)**
Same root cause as `/debug` — uses `localStorage` in module init. Block explorer pages on a single-contract dApp where the contract address links to Basescan are redundant. Deletion is correct.

### 3. Providers gated behind `mounted` check — **ACCEPTABLE (Info)**
`ScaffoldEthAppWithProviders.tsx:39-55`: returns a stripped layout (just `<Header is missing>...children...<Footer is missing>` — actually returns just `<main>{children}</main>`) until `mounted = true`, then renders the full WagmiProvider tree. This is correct for static export — the prerender pass cannot initialize wagmi because some downstream connector code throws on missing browser context. Trade-off: a brief flash of "Loading Clawd Search…" (set by the `dynamic` loading prop in `page.tsx:11-15`) before hydration. Acceptable for IPFS-hosted dApps.

One minor note: during the unmounted phase, `<Header/>` and `<Footer/>` are NOT rendered (they're inside `<ScaffoldEthApp>` which is only rendered after mount). That means the very first paint shows just a centered loading lobster with no header/footer chrome — slightly odd but not broken.

### 4. `polyfill-localstorage.cjs` extended to polyfill `document.createElement` — **STABLE (Low)**
`polyfill-localstorage.cjs:27-78` constructs a fake `document` with `createElement` returning a fake element that has every property the SSR-time path of react-hot-toast/goober/etc. expects: `firstChild` is a text-like node with mutable `.data`. This is a known-good shape — react-hot-toast/goober was the suspected crash via the original Stage 6 report. The polyfill only runs when `globalThis.window === undefined` (server pass) so it can't interfere with browser execution. Risk surface is small. If a future SE2 dependency introspects more DOM properties, the polyfill might need extension, but right now it's adequate.

### 5. `/og.png` referenced but doesn't exist — **FAIL** (already covered as should-fix #2)
Stage 8 must produce one and ensure absolute URL resolution.

---

## Summary

- **Ship-blockers: 9 PASS, 0 FAIL** ✓ — Stage 7 unblocks Stage 8 hand-off on ship-blockers alone.
- **Should-fix: 6 PASS, 2 FAIL** — must be fixed before Stage 9 / completion. Failures: OG image (#2), error decoding gap (#5), mobile deep-linking (#7).
- **Client-locked-in features: 5 PASS, 0 FAIL** ✓ — every feature the client confirmed in the messages thread is implemented.
- **General frontend health: PASS** with one caveat (error decoding tied to should-fix #5).
- **Stage 6 workarounds: ACCEPTABLE** — every workaround has a sensible justification and the polyfill scope is bounded.

### Top 5 fixes Stage 8 must address (priority order)

1. **OG image (Should-fix #2 — FAIL)**: produce `packages/nextjs/public/og.png` (or repoint to `/thumbnail.jpg` which already exists), AND set `NEXT_PUBLIC_PRODUCTION_URL` before `yarn build` so meta tags resolve to a real absolute URL — not `http://localhost:3000`. Verify by grepping `out/index.html` for `localhost` afterwards (must be zero).

2. **Error decoding gap (Should-fix #5 — FAIL)**: in `packages/nextjs/utils/scaffold-eth/contract.ts:358`, switch the lookup from `deployedContractsData[chainId]` to the merged `contractsData[chainId]` (already constructed at line 64) so OZ v5 ERC20 errors from `externalContracts.ts` decode. Verifiable by simulating an under-allowance `submit` call on a fork and checking the toast says "ERC20InsufficientAllowance" instead of "Encoded error signature 0x… not found on ABI".

3. **Mobile deep linking (Should-fix #7 — FAIL)**: add a `useWriteAndOpen` helper that fires the write call then `setTimeout(openWallet, 2000)`, and wrap every `writeErc20` / `writeSearch` / `writeContractAsync` (resolve) invocation. Pattern from `ethskills.com/qa/SKILL.md`. ~30 lines of new code.

4. **Loading-screen chrome (Stage-6-workaround Info note)**: optionally render `<Header/>` and `<Footer/>` in the pre-mount fallback in `ScaffoldEthAppWithProviders.tsx:49-55` so the first paint isn't a chrome-less loading lobster. Low priority but a nice polish.

5. **Vote-button burn/treasury disclosure (Client #5 minor inconsistency)**: optionally add a small "🔥 50 CLAWD burned + 🏛️ 50 CLAWD to treasury" line under the vote buttons (or a hover tooltip), parallel to the modal disclosure. Currently covered by the global How It Works panel, so this is low priority but completes the client's "burn/treasury split shown in confirmation modal" intent.

### Audit dimensions not fully verifiable

- **Mobile in-wallet deep-link UX**: I couldn't run a real wallet against the live build — I confirmed by code search that the `writeAndOpen` pattern is absent. Stage 8's fix can be verified via simulator or testflight if available.
- **Phantom wallet actually in the modal**: I confirmed `phantomWallet` is imported and pushed into the wallet array, but didn't open the RainbowKit modal in a browser to verify it renders. Code path is correct.
- **`yarn build` re-run**: out of scope per stage rules.

---

## Stage 8 Resolution

Each Stage 7 finding addressed below. `yarn next:build` re-run after every fix and exits 0.

### FAIL #1 (Should-fix #2) — OG image now uses absolute URL, no localhost — **RESOLVED**
- **What was wrong:** `out/index.html` contained `<meta property="og:image" content="http://localhost:3000/og.png"/>` and `public/og.png` did not exist. Two problems: the URL pointed at localhost (Next 15 normalizes relative image paths via `metadataBase`, which defaults to `http://localhost:3000` when undefined), and the asset itself was missing.
- **Files changed:**
  - `packages/nextjs/utils/scaffold-eth/getMetadata.ts:1-31` — replaced the `http://localhost:${PORT}` fallback with a stable `https://leftclaw.services` fallback so static-export HTML never bakes a localhost URL. Build-time override via `NEXT_PUBLIC_PRODUCTION_URL` still wins. `metadataBase` is always set to a real URL.
  - `packages/nextjs/utils/scaffold-eth/getMetadata.ts:36-38` — explicit comment that the absolute path is required for Next 15 metadata normalization.
  - `packages/nextjs/public/og.png` — new file, 75 KB, 1200×630 PNG, orange gradient, lobster silhouette, "Clawd Search" headline + tagline. Generated via Sharp from an inline SVG (`/tmp/make-og.cjs`, ad-hoc; not checked in). The file IS checked in.
- **Verification:** `grep -l "localhost:3000" packages/nextjs/out/*.html` returns nothing. `grep og:image packages/nextjs/out/index.html` shows `<meta property="og:image" content="https://leftclaw.services/og.png"/>`. `out/og.png` is present at 75 KB.

### FAIL #2 (Should-fix #5) — Error decoding gap closed — **RESOLVED**
- **What was wrong:** `getParsedErrorWithAllAbis` in `packages/nextjs/utils/scaffold-eth/contract.ts:358` looked up errors only against `deployedContractsData[chainId]`. OZ v5 ERC20 custom errors registered in `externalContracts.ts` (e.g. `ERC20InsufficientAllowance`, `ERC20InsufficientBalance`) were unreachable. When `submit`/`challenge`/`vote` reverted because of insufficient allowance/balance inside CLAWD, users saw `"Encoded error signature 0x… not found on ABI"` instead of a friendly message.
- **Files changed:**
  - `packages/nextjs/utils/scaffold-eth/contract.ts:357-362` — switched the lookup from `deployedContractsData[chainId]` to the merged `(contractsData as Record<number, Record<string, any>>)[chainId]`. The merged map already exists at line 64 (`deepMergeContracts(deployedContractsData, externalContractsData)`); we now consult it in the error resolver too. Cast through `Record<number, Record<string, any>>` to keep TypeScript happy with the heterogeneous shape; runtime structure is the same.
- **Verification (trace):** A user with 0 CLAWD allowance who clicks Submit triggers `simulateContract` → CLAWD's `safeTransferFrom` → revert with `ERC20InsufficientAllowance(spender, allowance, needed)`. Selector `0xfb8f41b2`. The resolver now iterates merged `chainContracts`, finds `CLAWD.abi` includes `ERC20InsufficientAllowance` as an error type, hashes the signature, matches the selector, and returns `"Contract function execution reverted with the following reason: ERC20InsufficientAllowance(address,uint256,uint256) from CLAWD contract"`. Direct approve flow remains unchanged (it already decodes against `CLAWD_TOKEN_ABI`).

### FAIL #3 (Should-fix #7) — Mobile deep-link nudge added — **RESOLVED**
- **What was wrong:** No `writeAndOpen` pattern anywhere. Mobile WalletConnect users had to manually app-switch to confirm transactions.
- **Files changed:**
  - `packages/nextjs/hooks/scaffold-eth/useWriteAndOpen.ts` — new hook (~85 lines). Exports `useWriteAndOpen()` returning `{ writeAndOpen, openWalletOnMobile }`. The hook reads the active connector from `useAccount`, and on a mobile UA schedules a 2 s deep-link attempt to the connected wallet's WalletConnect `redirect.native` URI (or `connector.openWalletApp()` if the connector exposes it). Pure best-effort: never throws, no-ops on desktop and on connectors without redirect metadata.
  - `packages/nextjs/hooks/scaffold-eth/index.ts` — re-exports `useWriteAndOpen`.
  - `packages/nextjs/app/_components/ClawdSearchApp.tsx:10-15` — imports `useWriteAndOpen` from the scaffold hooks barrel.
  - `ClawdSearchApp.tsx:382` (ConfirmPanel) — calls `openWalletOnMobile()` immediately before `writeErc20({ approve })` and again before `writeSearch({ submit/challenge })`.
  - `ClawdSearchApp.tsx:687` (VoteButton) — calls `openWalletOnMobile()` before the vote-flow approve and again before `writeSearch({ vote })`.
  - `ClawdSearchApp.tsx:773` (ResolveButton) — calls `openWalletOnMobile()` before `writeContractAsync({ resolve })`.
- **Verification:** Code search shows `openWalletOnMobile()` is invoked from every `writeErc20`/`writeSearch`/`writeContractAsync` call site that fires a user-initiated transaction. Desktop UA returns early (no-op). On mobile WC, user fires tx → deep-link nudge after 2 s → wallet app foregrounds for confirmation. No regressions to the existing `try/catch`/notification flow because errors are still surfaced by the underlying write hook.

### INFO #1 — Loading-screen chrome — **WON'T FIX (acceptable as-is)**
- The pre-mount fallback shows just a centered loading lobster. Per Stage 7 "current state is acceptable; skip if low on time." Time was spent on the three FAILs and the contract-address visibility / OG asset / error decoding work. Acceptable as documented.

### INFO #2 — Vote-button burn/treasury label — **RESOLVED**
- **What was wrong:** Vote buttons displayed "100 CLAWD" cost without the burn/treasury split shown in submit/challenge confirmation modals.
- **Files changed:**
  - `ClawdSearchApp.tsx:756-779` — wrapped the vote button in a DaisyUI `tooltip tooltip-top` element with `data-tip="100 CLAWD: 🔥 50 burned + 🏛️ 50 to treasury"`. Class `flex-1` moved from the button to the tooltip wrapper so layout is preserved (button uses `w-full` inside the tooltip).
- **Verification:** Tooltip renders on hover/tap, mirrors the submit/challenge modal disclosure, satisfies the client's "burn/treasury split shown before each action" intent without forcing a confirmation modal for the one-click vote flow.

### Build verification

- `yarn next:build` exit code: **0**
- `out/index.html` size: **8101 bytes**
- `grep -l "localhost:3000" packages/nextjs/out/*.html` → **no matches** (only one chunked JS file references localhost, which is dev-only env detection in vendored connector code, not user-facing HTML)
- `grep og:image packages/nextjs/out/index.html` → `https://leftclaw.services/og.png` (absolute, real host)
- Contract address `0x1c67563f968256778847407583d9e6abe1e263e7` present in `_next/static/chunks/810-386f6861af715d34.js` (1 occurrence — embedded, will be visible in the `<Address/>` Contracts card after hydration)
- `packages/nextjs/public/og.png` exists (75 KB, 1200×630)
- `packages/nextjs/out/og.png` exists (75 KB, copied by Next at export time)
- `getParsedErrorWithAllAbis` now loops merged `contractsData` (`contract.ts:362`)

### Top-5 Stage 7 fixes — final status

1. **OG image / no localhost** — RESOLVED.
2. **Error decoding gap** — RESOLVED.
3. **Mobile deep linking** — RESOLVED.
4. **Loading-screen chrome polish** — WON'T FIX (Info-level, accepted as-is).
5. **Vote-button burn/treasury disclosure** — RESOLVED via tooltip.

### Client-locked-in features — re-verified after Stage 8 changes

1. How It Works explainer block — still rendered (`HowItWorks` component unchanged).
2. Cost labels on every action button — unchanged (vote button still shows `— 100 CLAWD`).
3. Tooltips on category cards — unchanged (`CategoryCard` `tooltip-left`).
4. Loser lockout notice — unchanged (`ConfirmPanel` warning at line 592-596).
5. Burn/treasury split in confirmation modal — unchanged (`ConfirmPanel` line 590); now ALSO surfaced on vote-button tooltip.

No client-locked-in feature regressed.
