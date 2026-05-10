"use client";

import { useEffect, useMemo, useState } from "react";
import { Address as AddressComp } from "@scaffold-ui/components";
import { formatUnits } from "viem";
import { base } from "viem/chains";
import { useAccount, useReadContract, useSwitchChain, useWriteContract } from "wagmi";
import deployedContracts from "~~/contracts/deployedContracts";
import externalContracts from "~~/contracts/externalContracts";
import {
  useScaffoldEventHistory,
  useScaffoldReadContract,
  useScaffoldWriteContract,
  useWriteAndOpen,
} from "~~/hooks/scaffold-eth";
import { notification } from "~~/utils/scaffold-eth";

// ----------------------------------------------------------------------------
// Constants
// ----------------------------------------------------------------------------

const CHAIN_ID = 8453 as const;
const CLAWD_SEARCH_ADDRESS = deployedContracts[CHAIN_ID].ClawdSearch.address as `0x${string}`;
const CLAWD_TOKEN_ADDRESS = externalContracts[CHAIN_ID].CLAWD.address as `0x${string}`;
const CLAWD_TOKEN_ABI = externalContracts[CHAIN_ID].CLAWD.abi;

const SUBMIT_PRICE = 1000n * 10n ** 18n;
const CHALLENGE_PRICE = 100n * 10n ** 18n;
const VOTE_PRICE = 100n * 10n ** 18n;

const CHALLENGE_DURATION = 48n * 60n * 60n; // seconds

// Six active categories — seeded in the constructor (phase 2 contract).
// id matches the on-chain categoryId (nextCategoryId order: 0-5).
const CATEGORY_CONFIG = [
  {
    id: 0,
    title: "Most Pudgy Penguin",
    emoji: "🐧",
    tagline: "Round. Waddly. Undeniable.",
    taxonId: 3956,
    hint: "Penguins only",
  },
  {
    id: 1,
    title: "Most Dapper Lobster",
    emoji: "🦞",
    tagline: "Anthropic-y. Scarlet. Pixel-poet.",
    taxonId: 47764,
    hint: "Lobsters only",
  },
  {
    id: 2,
    title: "Most Pepe Frog",
    emoji: "🐸",
    tagline: "Kek energy. Community decides.",
    taxonId: 20979,
    hint: "Frogs only",
  },
  { id: 3, title: "Cutest", emoji: "🥺", tagline: "Soft. Smol. Irresistible.", taxonId: 1, hint: null },
  { id: 4, title: "Best Camouflage", emoji: "🦎", tagline: "The master of disguise.", taxonId: 1, hint: null },
  { id: 5, title: "Best Eyes", emoji: "👁️", tagline: "The gaze that holds the crown.", taxonId: 1, hint: null },
] as const;

type CategoryConfig = (typeof CATEGORY_CONFIG)[number];

// ----------------------------------------------------------------------------
// iNaturalist
// ----------------------------------------------------------------------------

type INatPhoto = {
  id: number;
  url?: string;
};

type INatObservation = {
  id: number;
  speciesGuess: string;
  placeGuess: string;
  observedOn: string | null;
  photoUrl: string | null;
};

type CreaturePageResult = {
  list: INatObservation[];
  rawCount: number;
};

const CREATURE_PAGE_SIZE = 200;
const PHOTO_CACHE_TTL_MS = 60 * 60 * 1000;
const LIST_CACHE_TTL_MS = 7 * 60 * 1000;
const ALLOWED_PHOTO_HOST = "inaturalist-open-data.s3.amazonaws.com";

function isAllowedPhotoUrl(url: string | null | undefined): boolean {
  if (!url) return false;
  try {
    const parsed = new URL(url);
    return parsed.host === ALLOWED_PHOTO_HOST;
  } catch {
    return false;
  }
}

function upsizePhotoUrl(url: string | null): string | null {
  if (!url) return null;
  return url.replace(/\/square\./, "/medium.");
}

function lsGet<T>(key: string): { value: T; storedAt: number } | null {
  if (typeof window === "undefined") return null;
  try {
    const raw = window.localStorage.getItem(key);
    if (!raw) return null;
    return JSON.parse(raw) as { value: T; storedAt: number };
  } catch {
    return null;
  }
}

function lsSet<T>(key: string, value: T) {
  if (typeof window === "undefined") return;
  try {
    window.localStorage.setItem(key, JSON.stringify({ value, storedAt: Date.now() }));
  } catch {
    /* ignore quota errors */
  }
}

async function fetchObservation(obsId: bigint | number): Promise<INatObservation | null> {
  const idStr = obsId.toString();
  const cacheKey = `clawd:obs:${idStr}`;
  const cached = lsGet<INatObservation | null>(cacheKey);
  if (cached && Date.now() - cached.storedAt < PHOTO_CACHE_TTL_MS) {
    return cached.value;
  }
  try {
    const res = await fetch(`https://api.inaturalist.org/v1/observations/${idStr}`);
    if (!res.ok) {
      lsSet<INatObservation | null>(cacheKey, null);
      return null;
    }
    const data = await res.json();
    const result = data?.results?.[0];
    if (!result) {
      lsSet<INatObservation | null>(cacheKey, null);
      return null;
    }
    const photos: INatPhoto[] = result.photos ?? [];
    const photoUrl = upsizePhotoUrl(photos[0]?.url ?? null);
    const obs: INatObservation = {
      id: Number(idStr),
      speciesGuess: result.species_guess ?? result.taxon?.name ?? "Creature",
      placeGuess: result.place_guess ?? "—",
      observedOn: result.observed_on ?? null,
      photoUrl: isAllowedPhotoUrl(photoUrl) ? photoUrl : null,
    };
    lsSet<INatObservation | null>(cacheKey, obs);
    return obs;
  } catch {
    return null;
  }
}

async function fetchCreaturePage(taxonId: number, page: number): Promise<CreaturePageResult> {
  const cacheKey = `clawd:creatures:taxon${taxonId}:page${page}`;
  // Only cache page 1 in localStorage.
  if (page === 1) {
    const cached = lsGet<CreaturePageResult>(cacheKey);
    if (cached && Date.now() - cached.storedAt < LIST_CACHE_TTL_MS) {
      return cached.value;
    }
  }
  try {
    const res = await fetch(
      `https://api.inaturalist.org/v1/observations?taxon_id=${taxonId}&photos=true&per_page=${CREATURE_PAGE_SIZE}&page=${page}&order=desc&order_by=observed_on&quality_grade=research`,
    );
    if (!res.ok) return { list: [], rawCount: 0 };
    const data = await res.json();
    const rawResults = (data.results ?? []) as any[];
    const list: INatObservation[] = rawResults
      .map((r: any) => {
        const photos = r.photos ?? [];
        const photoUrl = upsizePhotoUrl(photos[0]?.url ?? null);
        return {
          id: r.id as number,
          speciesGuess: r.species_guess ?? r.taxon?.name ?? "Creature",
          placeGuess: r.place_guess ?? "—",
          observedOn: r.observed_on ?? null,
          photoUrl,
        };
      })
      .filter((o: INatObservation) => isAllowedPhotoUrl(o.photoUrl));
    const result: CreaturePageResult = { list, rawCount: rawResults.length };
    if (page === 1) {
      lsSet(cacheKey, result);
    }
    return result;
  } catch {
    return { list: [], rawCount: 0 };
  }
}

function usePhoto(obsId?: bigint) {
  const [obs, setObs] = useState<INatObservation | null>(null);
  const [loading, setLoading] = useState<boolean>(false);

  useEffect(() => {
    let cancelled = false;
    if (!obsId || obsId === 0n) {
      setObs(null);
      return;
    }
    setLoading(true);
    fetchObservation(obsId).then(o => {
      if (!cancelled) {
        setObs(o);
        setLoading(false);
      }
    });
    return () => {
      cancelled = true;
    };
  }, [obsId]);

  return { obs, loading };
}

// ----------------------------------------------------------------------------
// Helpers
// ----------------------------------------------------------------------------

function formatClawd(amount: bigint | undefined | null, opts?: { compact?: boolean }): string {
  if (amount === undefined || amount === null) return "—";
  const s = formatUnits(amount, 18);
  const [whole, frac] = s.split(".");
  const wholeFmt = Number(whole).toLocaleString();
  if (!frac || frac === "0" || /^0+$/.test(frac)) return wholeFmt;
  if (opts?.compact && Number(whole) >= 1) return wholeFmt;
  return `${wholeFmt}.${frac.replace(/0+$/, "").slice(0, 4)}`;
}

function shortDuration(seconds: number): string {
  if (seconds < 0) seconds = 0;
  if (seconds < 60) return `${Math.floor(seconds)}s`;
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m`;
  if (seconds < 86400) return `${Math.floor(seconds / 3600)}h`;
  return `${Math.floor(seconds / 86400)}d`;
}

function reignDays(reignStart: number, now: number): string {
  const diff = Math.max(0, now - reignStart);
  if (diff < 60) return `${diff}s`;
  if (diff < 3600) return `${Math.floor(diff / 60)} min`;
  if (diff < 86400) return `${Math.floor(diff / 3600)} hr`;
  return `${Math.floor(diff / 86400)} day${Math.floor(diff / 86400) === 1 ? "" : "s"}`;
}

function useNow(intervalMs = 30_000) {
  const [now, setNow] = useState<number>(() => Math.floor(Date.now() / 1000));
  useEffect(() => {
    const id = setInterval(() => setNow(Math.floor(Date.now() / 1000)), intervalMs);
    return () => clearInterval(id);
  }, [intervalMs]);
  return now;
}

// ----------------------------------------------------------------------------
// Decoded category state type
// ----------------------------------------------------------------------------

type CategoryState = {
  championObsId: bigint;
  championOwner: `0x${string}`;
  challengerObsId: bigint;
  challengerOwner: `0x${string}`;
  championVotes: bigint;
  challengerVotes: bigint;
  challengeStart: bigint;
  cooldownEnd: bigint;
  reignStart: bigint;
  challengeRound: bigint;
};

function decodeCategory(raw: readonly unknown[] | undefined): CategoryState | undefined {
  if (!raw || raw.length < 10) return undefined;
  return {
    championObsId: raw[0] as bigint,
    championOwner: raw[1] as `0x${string}`,
    challengerObsId: raw[2] as bigint,
    challengerOwner: raw[3] as `0x${string}`,
    championVotes: raw[4] as bigint,
    challengerVotes: raw[5] as bigint,
    challengeStart: BigInt(raw[6] as bigint | number),
    cooldownEnd: BigInt(raw[7] as bigint | number),
    reignStart: BigInt(raw[8] as bigint | number),
    challengeRound: BigInt(raw[9] as bigint | number),
  };
}

// ----------------------------------------------------------------------------
// CreaturePhoto
// ----------------------------------------------------------------------------

function CreaturePhoto({ obsId, size = "h-40" }: { obsId: bigint; size?: string }) {
  const { obs, loading } = usePhoto(obsId);

  if (obsId === 0n) return null;

  if (loading) {
    return <div className={`${size} w-full bg-base-200 rounded-lg animate-pulse`} />;
  }

  if (!obs || !obs.photoUrl) {
    return (
      <div
        className={`${size} w-full bg-base-200 rounded-lg flex items-center justify-center text-center text-xs px-3 opacity-70`}
      >
        🌿 This creature has returned to the wild — observation no longer available on iNaturalist.
      </div>
    );
  }

  return (
    <div className={`${size} w-full overflow-hidden rounded-lg bg-base-200`}>
      {/* eslint-disable-next-line @next/next/no-img-element */}
      <img src={obs.photoUrl} alt={`Observation ${obs.id}`} className="w-full h-full object-cover" loading="lazy" />
    </div>
  );
}

// ----------------------------------------------------------------------------
// Modal — Submit / Challenge (with per_page=200, Load More, direct obs ID)
// ----------------------------------------------------------------------------

type ModalKind = "submit" | "challenge";

function ActionModal({
  open,
  onClose,
  kind,
  categoryId,
  taxonId,
  categoryTitle,
  refetchCategory,
}: {
  open: boolean;
  onClose: () => void;
  kind: ModalKind;
  categoryId: number;
  taxonId: number;
  categoryTitle: string;
  refetchCategory: () => void;
}) {
  const { address: account } = useAccount();
  const cost = kind === "submit" ? SUBMIT_PRICE : CHALLENGE_PRICE;
  const half = cost / 2n;

  const [list, setList] = useState<INatObservation[]>([]);
  const [listLoading, setListLoading] = useState<boolean>(false);
  const [picked, setPicked] = useState<INatObservation | null>(null);
  const [currentPage, setCurrentPage] = useState<number>(1);
  const [hasMore, setHasMore] = useState<boolean>(true);
  const [loadingMore, setLoadingMore] = useState<boolean>(false);
  const [obsInput, setObsInput] = useState<string>("");
  const [obsInputError, setObsInputError] = useState<string | null>(null);
  const [obsInputLoading, setObsInputLoading] = useState<boolean>(false);

  useEffect(() => {
    if (!open) return;
    setListLoading(true);
    setCurrentPage(1);
    setHasMore(true);
    fetchCreaturePage(taxonId, 1).then(({ list: l, rawCount }) => {
      setList(l);
      setHasMore(rawCount >= CREATURE_PAGE_SIZE);
      setListLoading(false);
    });
  }, [open, taxonId]);

  useEffect(() => {
    if (!open) {
      setPicked(null);
      setObsInput("");
      setObsInputError(null);
      setObsInputLoading(false);
    }
  }, [open]);

  const loadMore = async () => {
    if (loadingMore || !hasMore) return;
    setLoadingMore(true);
    const next = currentPage + 1;
    const { list: more, rawCount } = await fetchCreaturePage(taxonId, next);
    setList(prev => {
      const seen = new Set(prev.map(o => o.id));
      const merged = [...prev];
      for (const o of more) {
        if (!seen.has(o.id)) merged.push(o);
      }
      return merged;
    });
    setCurrentPage(next);
    setHasMore(rawCount >= CREATURE_PAGE_SIZE);
    setLoadingMore(false);
  };

  const handleObsInputSubmit = async () => {
    const trimmed = obsInput.trim();
    if (!trimmed) {
      setObsInputError("Couldn't parse — try a numeric ID or full iNat URL.");
      return;
    }
    let id: string | null = null;
    if (/^\d+$/.test(trimmed)) {
      id = trimmed;
    } else {
      const urlMatch = trimmed.match(/inaturalist\.org\/observations\/(\d+)/i);
      if (urlMatch) id = urlMatch[1];
    }
    if (!id) {
      setObsInputError("Couldn't parse — try a numeric ID or full iNat URL.");
      return;
    }
    setObsInputError(null);
    setObsInputLoading(true);
    const obs = await fetchObservation(BigInt(id));
    setObsInputLoading(false);
    if (!obs || !obs.photoUrl) {
      setObsInputError(
        "That observation isn't available, has no photo, or its photo isn't on iNaturalist's open data CDN. Try another.",
      );
      return;
    }
    setPicked(obs);
  };

  const balanceRead = useReadContract({
    chainId: CHAIN_ID,
    address: CLAWD_TOKEN_ADDRESS,
    abi: CLAWD_TOKEN_ABI,
    functionName: "balanceOf",
    args: account ? [account] : undefined,
    query: { enabled: open && !!account },
  });
  const allowanceRead = useReadContract({
    chainId: CHAIN_ID,
    address: CLAWD_TOKEN_ADDRESS,
    abi: CLAWD_TOKEN_ABI,
    functionName: "allowance",
    args: account ? [account, CLAWD_SEARCH_ADDRESS] : undefined,
    query: { enabled: open && !!account },
  });

  const balance = (balanceRead.data as bigint | undefined) ?? 0n;
  const allowance = (allowanceRead.data as bigint | undefined) ?? 0n;

  const insufficientBalance = balance < cost;
  const needsApproval = allowance < cost;

  const { writeContractAsync: writeErc20, isPending: approvePending } = useWriteContract();
  const { writeContractAsync: writeSearch, isPending: actionPending } = useScaffoldWriteContract({
    contractName: "ClawdSearch",
  });
  const { openWalletOnMobile } = useWriteAndOpen();

  const [waitingForAllowance, setWaitingForAllowance] = useState(false);

  const handleApprove = async () => {
    if (!account) return;
    try {
      setWaitingForAllowance(true);
      openWalletOnMobile();
      await writeErc20({
        chainId: CHAIN_ID,
        address: CLAWD_TOKEN_ADDRESS,
        abi: CLAWD_TOKEN_ABI,
        functionName: "approve",
        args: [CLAWD_SEARCH_ADDRESS, cost],
      });
      let tries = 0;
      const id = setInterval(async () => {
        tries += 1;
        await allowanceRead.refetch();
        if (((allowanceRead.data as bigint | undefined) ?? 0n) >= cost || tries > 20) {
          clearInterval(id);
          setWaitingForAllowance(false);
        }
      }, 1500);
    } catch (e) {
      setWaitingForAllowance(false);
      console.error(e);
      notification.error("Approval failed or was rejected");
    }
  };

  const handleAction = async () => {
    if (!account || !picked) return;
    try {
      const fnName = kind === "submit" ? "submit" : "challenge";
      openWalletOnMobile();
      await writeSearch({
        functionName: fnName,
        args: [BigInt(categoryId), BigInt(picked.id)],
      });
      notification.success(
        kind === "submit" ? "Champion crowned! 👑" : "Challenge opened — voting is live for 48 hours.",
      );
      await refetchCategory();
      onClose();
    } catch (e) {
      console.error(e);
    }
  };

  if (!open) return null;

  const costLabel = kind === "submit" ? "1,000 CLAWD" : "100 CLAWD";

  return (
    <div className="modal modal-open" role="dialog" aria-modal="true">
      <div className="modal-box max-w-3xl">
        <div className="flex items-start justify-between mb-2">
          <div>
            <h3 className="font-bold text-lg my-0">
              {kind === "submit" ? "Submit Champion" : "Challenge Champion"} · {categoryTitle}
            </h3>
            <p className="text-sm opacity-70 mt-1 mb-0">
              Pick a creature from iNaturalist (research grade, real photos only).
            </p>
          </div>
          <button className="btn btn-sm btn-circle btn-ghost" onClick={onClose} aria-label="Close">
            ✕
          </button>
        </div>

        {!picked ? (
          <>
            {/* Direct observation ID input */}
            <div className="flex gap-2 my-3">
              <input
                type="text"
                className="input input-bordered input-sm flex-1"
                placeholder="Paste iNaturalist URL or numeric observation ID…"
                value={obsInput}
                onChange={e => {
                  setObsInput(e.target.value);
                  if (obsInputError) setObsInputError(null);
                }}
                disabled={obsInputLoading}
                onKeyDown={e => e.key === "Enter" && handleObsInputSubmit()}
              />
              <button
                className="btn btn-sm btn-secondary"
                onClick={handleObsInputSubmit}
                disabled={obsInputLoading || obsInput.trim().length === 0}
              >
                {obsInputLoading ? <span className="loading loading-spinner loading-xs" /> : "Go"}
              </button>
            </div>
            {obsInputError && <p className="text-xs text-error mt-1 mb-0">{obsInputError}</p>}

            <div className="flex justify-between items-center my-3">
              <button
                className="btn btn-sm btn-secondary"
                onClick={() => {
                  if (list.length === 0) return;
                  const r = list[Math.floor(Math.random() * list.length)];
                  setPicked(r);
                }}
                disabled={list.length === 0}
              >
                🎲 Random Creature
              </button>
              <span className="text-xs opacity-70">{list.length} creatures with photos</span>
            </div>
            {listLoading ? (
              <div className="grid grid-cols-3 gap-3 max-h-96 overflow-y-auto">
                {Array.from({ length: 9 }).map((_, i) => (
                  <div key={i} className="aspect-square bg-base-200 rounded-lg animate-pulse" />
                ))}
              </div>
            ) : list.length === 0 ? (
              <div className="alert alert-warning my-3">
                <span>Couldn&apos;t reach iNaturalist. Try again in a moment.</span>
              </div>
            ) : (
              <>
                <div className="grid grid-cols-2 sm:grid-cols-3 gap-3 max-h-96 overflow-y-auto pr-2">
                  {list.map(o => (
                    <button
                      key={o.id}
                      className="lobster-card card bg-base-200 hover:bg-base-300 text-left p-2 cursor-pointer"
                      onClick={() => setPicked(o)}
                    >
                      {/* eslint-disable-next-line @next/next/no-img-element */}
                      <img
                        src={o.photoUrl ?? ""}
                        alt={o.speciesGuess}
                        className="obs-thumb rounded-md w-full"
                        loading="lazy"
                      />
                      <div className="text-xs mt-1 leading-tight">
                        <div className="font-semibold truncate">{o.speciesGuess}</div>
                        <div className="opacity-60 truncate">{o.placeGuess}</div>
                      </div>
                    </button>
                  ))}
                </div>
                {hasMore && (
                  <div className="flex justify-center mt-3">
                    <button className="btn btn-sm btn-outline" onClick={loadMore} disabled={loadingMore}>
                      {loadingMore ? (
                        <>
                          <span className="loading loading-spinner loading-xs" />
                          Loading More…
                        </>
                      ) : (
                        "Load More"
                      )}
                    </button>
                  </div>
                )}
              </>
            )}
          </>
        ) : (
          <ConfirmPanel
            picked={picked}
            kind={kind}
            half={half}
            costLabel={costLabel}
            balance={balance}
            allowance={allowance}
            insufficientBalance={insufficientBalance}
            needsApproval={needsApproval}
            approvePending={approvePending || waitingForAllowance}
            actionPending={actionPending}
            onBack={() => setPicked(null)}
            onApprove={handleApprove}
            onAction={handleAction}
            account={account}
          />
        )}
      </div>
      <div className="modal-backdrop bg-black/40" onClick={onClose} />
    </div>
  );
}

function ConfirmPanel({
  picked,
  kind,
  half,
  costLabel,
  balance,
  allowance,
  insufficientBalance,
  needsApproval,
  approvePending,
  actionPending,
  onBack,
  onApprove,
  onAction,
  account,
}: {
  picked: INatObservation;
  kind: ModalKind;
  half: bigint;
  costLabel: string;
  balance: bigint;
  allowance: bigint;
  insufficientBalance: boolean;
  needsApproval: boolean;
  approvePending: boolean;
  actionPending: boolean;
  onBack: () => void;
  onApprove: () => void;
  onAction: () => void;
  account?: string;
}) {
  return (
    <div className="flex flex-col gap-4 mt-3">
      <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
        {/* eslint-disable-next-line @next/next/no-img-element */}
        <img
          src={picked.photoUrl ?? ""}
          alt={picked.speciesGuess}
          className="rounded-lg w-full max-h-64 object-cover"
        />
        <div className="flex flex-col gap-1 text-sm">
          <div>
            <span className="opacity-60">Observation:</span> #{picked.id}
          </div>
          <div>
            <span className="opacity-60">Species:</span> {picked.speciesGuess}
          </div>
          <div>
            <span className="opacity-60">Location:</span> {picked.placeGuess}
          </div>
          {picked.observedOn && (
            <div>
              <span className="opacity-60">Observed:</span> {picked.observedOn}
            </div>
          )}
          <a
            href={`https://www.inaturalist.org/observations/${picked.id}`}
            target="_blank"
            rel="noreferrer"
            className="link text-xs"
          >
            View on iNaturalist ↗
          </a>
        </div>
      </div>

      <div className="bg-base-200 rounded-lg p-4 text-sm flex flex-col gap-1">
        <div className="font-semibold">Cost: {costLabel}</div>
        <div>
          🔥 {formatClawd(half)} CLAWD burned + 🏛️ {formatClawd(half)} CLAWD to treasury
        </div>
        {kind === "challenge" && (
          <div className="text-warning mt-1">
            ⚠️ If your creature loses, observation #{picked.id} cannot challenge this category again.
          </div>
        )}
        <div className="opacity-60 mt-2">
          Your balance: {formatClawd(balance)} CLAWD · Allowance: {formatClawd(allowance)} CLAWD
        </div>
      </div>

      {!account ? (
        <div className="alert alert-info my-0">
          <span>Connect your wallet to continue.</span>
        </div>
      ) : insufficientBalance ? (
        <div className="alert alert-error my-0">
          <span>Insufficient CLAWD balance: {formatClawd(balance)}</span>
        </div>
      ) : needsApproval ? (
        <div className="flex flex-col sm:flex-row gap-2">
          <button className="btn btn-ghost" onClick={onBack} disabled={approvePending}>
            ← Back
          </button>
          <button className="btn btn-primary flex-1" onClick={onApprove} disabled={approvePending}>
            {approvePending ? (
              <>
                <span className="loading loading-spinner loading-xs"></span>
                Approving {costLabel}…
              </>
            ) : (
              <>1️⃣ Approve {costLabel}</>
            )}
          </button>
          <button className="btn btn-primary flex-1" disabled>
            2️⃣ {kind === "submit" ? "Submit" : "Challenge"}
          </button>
        </div>
      ) : (
        <div className="flex flex-col sm:flex-row gap-2">
          <button className="btn btn-ghost" onClick={onBack} disabled={actionPending}>
            ← Back
          </button>
          <button className="btn btn-primary flex-1" onClick={onAction} disabled={actionPending}>
            {actionPending ? (
              <>
                <span className="loading loading-spinner loading-xs"></span>
                Submitting…
              </>
            ) : kind === "submit" ? (
              <>👑 Submit Champion — {costLabel}</>
            ) : (
              <>⚔️ Challenge — {costLabel}</>
            )}
          </button>
        </div>
      )}
    </div>
  );
}

// ----------------------------------------------------------------------------
// Vote button (with inline approve)
// ----------------------------------------------------------------------------

function VoteButton({
  categoryId,
  forChallenger,
  onVoted,
  hasUserVoted,
  challengeOpen,
  label,
}: {
  categoryId: number;
  forChallenger: boolean;
  onVoted: () => void;
  hasUserVoted: boolean;
  challengeOpen: boolean;
  label: string;
}) {
  const { address: account } = useAccount();
  const { writeContractAsync: writeErc20, isPending: approvePending } = useWriteContract();
  const { writeContractAsync: writeSearch, isPending: actionPending } = useScaffoldWriteContract({
    contractName: "ClawdSearch",
  });
  const { openWalletOnMobile } = useWriteAndOpen();

  const allowanceRead = useReadContract({
    chainId: CHAIN_ID,
    address: CLAWD_TOKEN_ADDRESS,
    abi: CLAWD_TOKEN_ABI,
    functionName: "allowance",
    args: account ? [account, CLAWD_SEARCH_ADDRESS] : undefined,
    query: { enabled: !!account },
  });
  const balanceRead = useReadContract({
    chainId: CHAIN_ID,
    address: CLAWD_TOKEN_ADDRESS,
    abi: CLAWD_TOKEN_ABI,
    functionName: "balanceOf",
    args: account ? [account] : undefined,
    query: { enabled: !!account },
  });

  const allowance = (allowanceRead.data as bigint | undefined) ?? 0n;
  const balance = (balanceRead.data as bigint | undefined) ?? 0n;

  const [waitingForAllowance, setWaitingForAllowance] = useState(false);

  const handleVote = async () => {
    if (!account) return;
    try {
      if (balance < VOTE_PRICE) {
        notification.error(`Insufficient CLAWD. Need 100, have ${formatClawd(balance)}.`);
        return;
      }
      if (allowance < VOTE_PRICE) {
        setWaitingForAllowance(true);
        openWalletOnMobile();
        await writeErc20({
          chainId: CHAIN_ID,
          address: CLAWD_TOKEN_ADDRESS,
          abi: CLAWD_TOKEN_ABI,
          functionName: "approve",
          args: [CLAWD_SEARCH_ADDRESS, VOTE_PRICE],
        });
        let tries = 0;
        await new Promise<void>(resolve => {
          const id = setInterval(async () => {
            tries += 1;
            await allowanceRead.refetch();
            const newAllowance = (allowanceRead.data as bigint | undefined) ?? 0n;
            if (newAllowance >= VOTE_PRICE || tries > 20) {
              clearInterval(id);
              resolve();
            }
          }, 1500);
        });
        setWaitingForAllowance(false);
      }
      openWalletOnMobile();
      await writeSearch({
        functionName: "vote",
        args: [BigInt(categoryId), forChallenger],
      });
      notification.success("Vote cast!");
      onVoted();
    } catch (e) {
      setWaitingForAllowance(false);
      console.error(e);
    }
  };

  const disabled = !account || hasUserVoted || !challengeOpen || approvePending || actionPending || waitingForAllowance;
  const pending = approvePending || actionPending || waitingForAllowance;

  return (
    <div className="tooltip tooltip-top flex-1" data-tip="100 CLAWD: 🔥 50 burned + 🏛️ 50 to treasury">
      <button
        className={`btn btn-sm ${forChallenger ? "btn-warning" : "btn-info"} w-full`}
        onClick={handleVote}
        disabled={disabled}
      >
        {pending ? (
          <>
            <span className="loading loading-spinner loading-xs"></span>
            Voting…
          </>
        ) : hasUserVoted ? (
          "✓ Voted"
        ) : (
          <>
            {label}
            <span className="opacity-70 text-xs">— 100 CLAWD</span>
          </>
        )}
      </button>
    </div>
  );
}

// ----------------------------------------------------------------------------
// Resolve
// ----------------------------------------------------------------------------

function ResolveButton({ categoryId, onResolved }: { categoryId: number; onResolved: () => void }) {
  const { writeContractAsync, isPending } = useScaffoldWriteContract({ contractName: "ClawdSearch" });
  const { openWalletOnMobile } = useWriteAndOpen();
  const handle = async () => {
    try {
      openWalletOnMobile();
      await writeContractAsync({ functionName: "resolve", args: [BigInt(categoryId)] });
      notification.success("Resolved!");
      onResolved();
    } catch (e) {
      console.error(e);
    }
  };
  return (
    <button className="btn btn-success btn-sm w-full" onClick={handle} disabled={isPending}>
      {isPending ? (
        <>
          <span className="loading loading-spinner loading-xs"></span>
          Resolving…
        </>
      ) : (
        "🏛️ Resolve Challenge"
      )}
    </button>
  );
}

// ----------------------------------------------------------------------------
// Category Card (active, wired to contract)
// ----------------------------------------------------------------------------

function CategoryCard({ config }: { config: CategoryConfig }) {
  const now = useNow();
  const { address: account, chain } = useAccount();
  const onWrongNetwork = !!chain && chain.id !== CHAIN_ID;

  const { data: rawCategory, refetch: refetchCategory } = useScaffoldReadContract({
    contractName: "ClawdSearch",
    functionName: "getCategory",
    args: [BigInt(config.id) as unknown as undefined],
  } as any);
  const cat = decodeCategory(rawCategory as readonly unknown[] | undefined);

  const championObsId = cat?.championObsId ?? 0n;
  const { data: championWins } = useScaffoldReadContract({
    contractName: "ClawdSearch",
    functionName: "categoryChampionWins",
    args: [BigInt(config.id) as unknown as undefined, championObsId as unknown as undefined],
  } as any);

  const challengeRound = cat?.challengeRound ?? 0n;
  const { data: hasUserVoted, refetch: refetchHasVoted } = useScaffoldReadContract({
    contractName: "ClawdSearch",
    functionName: "hasVoted",
    args: [
      BigInt(config.id) as unknown as undefined,
      challengeRound as unknown as undefined,
      account as unknown as undefined,
    ],
  } as any);

  const [modal, setModal] = useState<ModalKind | null>(null);

  const noChampion = !cat || cat.championObsId === 0n;
  const challengerActive = !noChampion && cat!.challengerObsId !== 0n;
  const challengeDeadline = cat && cat.challengeStart !== 0n ? cat.challengeStart + CHALLENGE_DURATION : 0n;
  const challengeWindowOpen = challengerActive && BigInt(now) < challengeDeadline;
  const challengeReadyToResolve = challengerActive && BigInt(now) >= challengeDeadline;

  const onCooldown = !noChampion && !challengerActive && BigInt(now) < (cat?.cooldownEnd ?? 0n);
  const cooldownRemaining = onCooldown ? Number(cat!.cooldownEnd - BigInt(now)) : 0;
  const challengeRemainingSec = challengeWindowOpen && cat ? Number(challengeDeadline - BigInt(now)) : 0;

  const refetchAll = () => {
    refetchCategory();
    refetchHasVoted();
  };

  return (
    <div className="card bg-base-100 shadow-md border border-base-300 flex flex-col">
      <div className="card-body p-5">
        <div className="flex items-start justify-between">
          <h2 className="card-title text-base sm:text-lg my-0">
            <span className="text-2xl">{config.emoji}</span>
            <span>{config.title}</span>
          </h2>
        </div>
        {config.hint && <p className="text-[10px] opacity-50 my-0 -mt-1 ml-9">{config.hint}</p>}
        <p className="text-xs opacity-70 my-1">{config.tagline}</p>

        {noChampion ? (
          <div className="flex flex-col items-center text-center gap-3 py-4">
            <div className="text-4xl opacity-50">👑</div>
            <p className="text-sm opacity-70 my-0">No champion yet. Be the first.</p>
            <button
              className="btn btn-primary btn-sm w-full"
              disabled={onWrongNetwork || !account}
              onClick={() => setModal("submit")}
            >
              Submit Champion — 1,000 CLAWD
            </button>
          </div>
        ) : challengerActive ? (
          <ChallengeView
            categoryId={config.id}
            cat={cat!}
            championWins={(championWins as bigint | undefined) ?? 0n}
            challengeRemainingSec={challengeRemainingSec}
            readyToResolve={challengeReadyToResolve}
            hasUserVoted={Boolean(hasUserVoted)}
            onWrongNetwork={onWrongNetwork}
            account={account}
            refetchAll={refetchAll}
          />
        ) : (
          <ChampionView
            cat={cat!}
            championWins={(championWins as bigint | undefined) ?? 0n}
            now={now}
            onCooldown={onCooldown}
            cooldownRemaining={cooldownRemaining}
            onChallenge={() => setModal("challenge")}
            onWrongNetwork={onWrongNetwork}
            account={account}
          />
        )}

        {modal && (
          <ActionModal
            open
            kind={modal}
            categoryId={config.id}
            taxonId={config.taxonId}
            categoryTitle={config.title}
            onClose={() => setModal(null)}
            refetchCategory={refetchAll}
          />
        )}
      </div>
    </div>
  );
}

function ChampionView({
  cat,
  championWins,
  now,
  onCooldown,
  cooldownRemaining,
  onChallenge,
  onWrongNetwork,
  account,
}: {
  cat: CategoryState;
  championWins: bigint;
  now: number;
  onCooldown: boolean;
  cooldownRemaining: number;
  onChallenge: () => void;
  onWrongNetwork: boolean;
  account?: string;
}) {
  return (
    <div className="flex flex-col gap-3">
      <CreaturePhoto obsId={cat.championObsId} />
      <div className="text-xs flex flex-col gap-1">
        <div className="flex items-center justify-between">
          <span className="opacity-60">Submitter:</span>
          <AddressComp address={cat.championOwner} format="short" size="xs" chain={base} />
        </div>
        <div className="flex justify-between">
          <span className="opacity-60">Reign:</span>
          <span>{reignDays(Number(cat.reignStart), now)}</span>
        </div>
        <div className="flex justify-between">
          <span className="opacity-60">Wins:</span>
          <span>🏆 {championWins.toString()}</span>
        </div>
        <div className="flex justify-between">
          <span className="opacity-60">Obs:</span>
          <a
            href={`https://www.inaturalist.org/observations/${cat.championObsId.toString()}`}
            target="_blank"
            rel="noreferrer"
            className="link"
          >
            #{cat.championObsId.toString()} ↗
          </a>
        </div>
      </div>
      {onCooldown ? (
        <button className="btn btn-sm w-full" disabled>
          Next challenge in {shortDuration(cooldownRemaining)}
        </button>
      ) : (
        <button className="btn btn-warning btn-sm w-full" onClick={onChallenge} disabled={onWrongNetwork || !account}>
          Challenge — 100 CLAWD
        </button>
      )}
    </div>
  );
}

function ChallengeView({
  categoryId,
  cat,
  championWins,
  challengeRemainingSec,
  readyToResolve,
  hasUserVoted,
  onWrongNetwork,
  account,
  refetchAll,
}: {
  categoryId: number;
  cat: CategoryState;
  championWins: bigint;
  challengeRemainingSec: number;
  readyToResolve: boolean;
  hasUserVoted: boolean;
  onWrongNetwork: boolean;
  account?: string;
  refetchAll: () => void;
}) {
  return (
    <div className="flex flex-col gap-3">
      <div className="grid grid-cols-2 gap-2">
        <div className="flex flex-col gap-1">
          <div className="text-[10px] opacity-60 uppercase tracking-wider">Champion</div>
          <CreaturePhoto obsId={cat.championObsId} size="h-28" />
          <div className="text-xs flex justify-between">
            <span className="opacity-60">Votes</span>
            <span className="font-bold">{cat.championVotes.toString()}</span>
          </div>
          <div className="text-xs">
            <AddressComp address={cat.championOwner} format="short" size="xs" chain={base} />
          </div>
          <div className="text-xs opacity-60">🏆 {championWins.toString()} wins</div>
        </div>
        <div className="flex flex-col gap-1">
          <div className="text-[10px] opacity-60 uppercase tracking-wider">Challenger</div>
          <CreaturePhoto obsId={cat.challengerObsId} size="h-28" />
          <div className="text-xs flex justify-between">
            <span className="opacity-60">Votes</span>
            <span className="font-bold">{cat.challengerVotes.toString()}</span>
          </div>
          <div className="text-xs">
            <AddressComp address={cat.challengerOwner} format="short" size="xs" chain={base} />
          </div>
          <div className="text-xs opacity-60">obs #{cat.challengerObsId.toString()}</div>
        </div>
      </div>

      {readyToResolve ? (
        <>
          <div className="alert alert-info py-2 text-xs">
            <span>Challenge window closed. Anyone can resolve.</span>
          </div>
          <ResolveButton categoryId={categoryId} onResolved={refetchAll} />
        </>
      ) : (
        <>
          <div className="text-xs text-center opacity-70">
            ⏳ Voting closes in <span className="font-bold">{shortDuration(challengeRemainingSec)}</span>
          </div>
          <div className="flex gap-2">
            <VoteButton
              categoryId={categoryId}
              forChallenger={false}
              onVoted={refetchAll}
              hasUserVoted={hasUserVoted}
              challengeOpen={true}
              label="🛡️ Champion"
            />
            <VoteButton
              categoryId={categoryId}
              forChallenger={true}
              onVoted={refetchAll}
              hasUserVoted={hasUserVoted}
              challengeOpen={true}
              label="⚔️ Challenger"
            />
          </div>
          {!account && <div className="text-[11px] text-center opacity-60">Connect to vote</div>}
          {onWrongNetwork && <div className="text-[11px] text-center text-warning">Switch to Base to vote</div>}
          {hasUserVoted && (
            <div className="text-[11px] text-center opacity-60">You&apos;ve already voted in this round.</div>
          )}
        </>
      )}
    </div>
  );
}

// ----------------------------------------------------------------------------
// How It Works
// ----------------------------------------------------------------------------

function HowItWorks() {
  return (
    <details className="collapse collapse-arrow bg-base-100 border border-base-300" open>
      <summary className="collapse-title text-lg font-semibold">How It Works</summary>
      <div className="collapse-content">
        <ol className="list-decimal list-inside space-y-3 text-sm">
          <li>
            <strong>Submit a Champion.</strong> Pick a real creature from iNaturalist and spend{" "}
            <strong>1,000 CLAWD</strong> to crown them champion of a category. Half is burned, half goes to the CLAWD
            treasury.
          </li>
          <li>
            <strong>Challenge.</strong> Think you&apos;ve got a better creature? Spend <strong>100 CLAWD</strong> to
            open a 48-hour challenge against the current champion.
          </li>
          <li>
            <strong>Vote.</strong> During an active challenge, anyone can vote for <strong>100 CLAWD</strong>. One vote
            per wallet per challenge. Ties go to the defending champion.
          </li>
          <li>
            <strong>Resolve.</strong> After 48 hours, anyone can call resolve. Most votes wins. Zero votes? Challenger
            takes the throne by default.
          </li>
        </ol>
      </div>
    </details>
  );
}

// ----------------------------------------------------------------------------
// Hall of Fame
// ----------------------------------------------------------------------------

function HallOfFame() {
  const { data: events, isLoading } = useScaffoldEventHistory({
    contractName: "ClawdSearch",
    eventName: "ChampionCrowned",
    fromBlock: 30000000n,
    watch: true,
  });

  const byCategory = useMemo(() => {
    const map: Record<number, { obsId: bigint; submitter: `0x${string}` }[]> = {};
    for (const cfg of CATEGORY_CONFIG) {
      map[cfg.id] = [];
    }
    if (!events) return map;
    for (const ev of events as any[]) {
      const args = ev.args ?? {};
      const catId = Number(args.categoryId ?? 0);
      const obsId = (args.observationId ?? 0n) as bigint;
      const submitter = (args.submitter ?? "0x0000000000000000000000000000000000000000") as `0x${string}`;
      if (!map[catId]) map[catId] = [];
      const existing = map[catId].find(e => e.obsId === obsId);
      if (!existing) {
        map[catId].push({ obsId, submitter });
      }
    }
    return map;
  }, [events]);

  const submitterStats = useMemo(() => {
    const counts: Record<string, number> = {};
    if (!events) return counts;
    for (const ev of events as any[]) {
      const args = ev.args ?? {};
      const submitter = ((args.submitter ?? "") as string).toLowerCase();
      if (!submitter) continue;
      counts[submitter] = (counts[submitter] ?? 0) + 1;
    }
    return counts;
  }, [events]);

  const topSubmitters = useMemo(() => {
    return Object.entries(submitterStats)
      .map(([addr, count]) => ({ addr: addr as `0x${string}`, count }))
      .sort((a, b) => b.count - a.count)
      .slice(0, 5);
  }, [submitterStats]);

  if (isLoading) {
    return (
      <section className="mt-12">
        <h2 className="text-xl font-bold mb-4">Hall of Fame</h2>
        <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
          {CATEGORY_CONFIG.map(cfg => (
            <div key={cfg.id} className="h-40 bg-base-200 rounded-lg animate-pulse" />
          ))}
        </div>
      </section>
    );
  }

  return (
    <section className="mt-12">
      <h2 className="text-xl font-bold mb-4">Hall of Fame</h2>
      <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
        {CATEGORY_CONFIG.map(cfg => (
          <HallOfFameLane key={cfg.id} config={cfg} entries={byCategory[cfg.id] ?? []} />
        ))}
      </div>
      {topSubmitters.length > 0 && (
        <div className="card bg-base-100 border border-base-300 mt-6">
          <div className="card-body p-5">
            <h3 className="font-semibold my-0">Top Submitters</h3>
            <ul className="text-sm flex flex-col gap-2 mt-2">
              {topSubmitters.map((s, i) => (
                <li key={s.addr} className="flex items-center justify-between">
                  <div className="flex items-center gap-2">
                    <span className="opacity-60 w-5">#{i + 1}</span>
                    <AddressComp address={s.addr} format="short" size="sm" chain={base} />
                  </div>
                  <span className="opacity-70">
                    {s.count} champion{s.count === 1 ? "" : "s"}
                  </span>
                </li>
              ))}
            </ul>
          </div>
        </div>
      )}
    </section>
  );
}

function HallOfFameLane({
  config,
  entries,
}: {
  config: CategoryConfig;
  entries: { obsId: bigint; submitter: `0x${string}` }[];
}) {
  const top5 = entries.slice(0, 5);

  return (
    <div className="card bg-base-100 border border-base-300">
      <div className="card-body p-5">
        <h3 className="font-semibold my-0">
          {config.emoji} {config.title}
        </h3>
        {top5.length === 0 ? (
          <p className="text-sm opacity-60 my-2">No champions yet — be the first.</p>
        ) : (
          <ul className="flex flex-col gap-3 mt-2">
            {top5.map((e, i) => (
              <HallOfFameEntry key={e.obsId.toString()} categoryId={config.id} entry={e} rank={i + 1} />
            ))}
          </ul>
        )}
      </div>
    </div>
  );
}

function HallOfFameEntry({
  categoryId,
  entry,
  rank,
}: {
  categoryId: number;
  entry: { obsId: bigint; submitter: `0x${string}` };
  rank: number;
}) {
  const { obs } = usePhoto(entry.obsId);
  const { data: wins } = useScaffoldReadContract({
    contractName: "ClawdSearch",
    functionName: "categoryChampionWins",
    args: [BigInt(categoryId) as unknown as undefined, entry.obsId as unknown as undefined],
  } as any);

  return (
    <li className="flex items-center gap-3">
      <span className="opacity-60 w-5 text-sm">#{rank}</span>
      <div className="w-12 h-12 rounded-md overflow-hidden bg-base-200 flex-shrink-0">
        {obs?.photoUrl ? (
          // eslint-disable-next-line @next/next/no-img-element
          <img src={obs.photoUrl} alt={`Obs ${entry.obsId}`} className="w-full h-full object-cover" />
        ) : (
          <div className="w-full h-full flex items-center justify-center text-xs">🌿</div>
        )}
      </div>
      <div className="flex-1 min-w-0">
        <div className="text-xs">
          <a
            href={`https://www.inaturalist.org/observations/${entry.obsId.toString()}`}
            target="_blank"
            rel="noreferrer"
            className="link"
          >
            #{entry.obsId.toString()} ↗
          </a>
        </div>
        <AddressComp address={entry.submitter} format="short" size="xs" chain={base} />
      </div>
      <div className="text-sm font-semibold whitespace-nowrap">
        🏆 {((wins as bigint | undefined) ?? 0n).toString()}
      </div>
    </li>
  );
}

// ----------------------------------------------------------------------------
// Wallet strip
// ----------------------------------------------------------------------------

function WalletStrip() {
  const { address, chain } = useAccount();
  const { switchChain, isPending: switching } = useSwitchChain();
  const onWrongNetwork = !!chain && chain.id !== CHAIN_ID;

  const balanceRead = useReadContract({
    chainId: CHAIN_ID,
    address: CLAWD_TOKEN_ADDRESS,
    abi: CLAWD_TOKEN_ABI,
    functionName: "balanceOf",
    args: address ? [address] : undefined,
    query: { enabled: !!address },
  });
  const balance = balanceRead.data as bigint | undefined;

  if (!address) {
    return (
      <div className="bg-base-100 border border-base-300 rounded-lg p-3 text-sm flex items-center justify-between">
        <span className="opacity-70">Connect a wallet to play.</span>
      </div>
    );
  }

  if (onWrongNetwork) {
    return (
      <div className="alert alert-warning flex items-center justify-between">
        <span className="text-sm">
          Wrong network — Creature Feature lives on <strong>Base</strong>.
        </span>
        <button
          className="btn btn-sm btn-primary"
          onClick={() => switchChain({ chainId: CHAIN_ID })}
          disabled={switching}
        >
          {switching ? "Switching…" : "Switch to Base"}
        </button>
      </div>
    );
  }

  return (
    <div className="bg-base-100 border border-base-300 rounded-lg p-3 text-sm flex flex-col sm:flex-row gap-2 items-center justify-between">
      <div className="flex items-center gap-2">
        <span className="opacity-60">Wallet:</span>
        <AddressComp address={address} format="short" size="sm" chain={base} />
      </div>
      <div className="flex items-center gap-1">
        <span className="opacity-60">CLAWD:</span>
        <span className="font-semibold">{formatClawd(balance)}</span>
        <a
          href={`https://basescan.org/token/${CLAWD_TOKEN_ADDRESS}?a=${address}`}
          target="_blank"
          rel="noreferrer"
          className="link text-xs ml-1 opacity-70"
        >
          (view ↗)
        </a>
      </div>
    </div>
  );
}

// ----------------------------------------------------------------------------
// Main exported component
// ----------------------------------------------------------------------------

export default function ClawdSearchApp() {
  return (
    <div className="flex flex-col grow">
      <main className="max-w-6xl mx-auto px-4 py-8 w-full flex flex-col gap-6">
        <header className="text-center py-4">
          <h1 className="text-5xl sm:text-6xl font-bold my-2 tracking-tight">Creature Feature</h1>
          <p className="opacity-70 my-2 text-lg">Real creatures. Real competition.</p>
        </header>

        <WalletStrip />

        <HowItWorks />

        <section>
          <h2 className="text-xl font-bold mb-3">The Crowns</h2>
          <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
            {CATEGORY_CONFIG.map(cfg => (
              <CategoryCard key={cfg.id} config={cfg} />
            ))}
          </div>
        </section>

        <HallOfFame />

        <div className="card bg-base-100 border border-base-300 mt-4">
          <div className="card-body p-5 text-sm">
            <h3 className="font-semibold my-0">Contracts</h3>
            <div className="flex flex-col gap-1 mt-2">
              <div className="flex items-center gap-2">
                <span className="opacity-60 w-32">Creature Feature:</span>
                <AddressComp address={CLAWD_SEARCH_ADDRESS} format="short" size="sm" chain={base} />
              </div>
              <div className="flex items-center gap-2">
                <span className="opacity-60 w-32">CLAWD token:</span>
                <AddressComp address={CLAWD_TOKEN_ADDRESS} format="short" size="sm" chain={base} />
              </div>
              <div className="flex items-center gap-2">
                <span className="opacity-60 w-32">Treasury (init):</span>
                <AddressComp
                  address={"0x90eF2A9211A3E7CE788561E5af54C76B0Fa3aEd0"}
                  format="short"
                  size="sm"
                  chain={base}
                />
              </div>
              <div className="flex items-center gap-2">
                <span className="opacity-60 w-32">Burn:</span>
                <AddressComp
                  address={"0x000000000000000000000000000000000000dEaD"}
                  format="short"
                  size="sm"
                  chain={base}
                />
              </div>
            </div>
          </div>
        </div>
      </main>
    </div>
  );
}
