"use client";

import Link from "next/link";
import { RainbowKitCustomConnectButton } from "~~/components/scaffold-eth";

/**
 * Site header — minimal nav for Clawd Search
 */
export const Header = () => {
  return (
    <div className="sticky lg:static top-0 navbar bg-base-100 min-h-0 shrink-0 justify-between z-20 shadow-md shadow-secondary px-2 sm:px-4">
      <div className="navbar-start">
        <Link href="/" passHref className="flex items-center gap-2 shrink-0">
          <span className="text-2xl">🦞</span>
          <div className="flex flex-col leading-tight">
            <span className="font-bold">Clawd Search</span>
            <span className="text-xs opacity-70">Crowns for the worthiest lobsters</span>
          </div>
        </Link>
      </div>
      <div className="navbar-end">
        <RainbowKitCustomConnectButton />
      </div>
    </div>
  );
};
