"use client";

import Link from "next/link";
import { RainbowKitCustomConnectButton } from "~~/components/scaffold-eth";

export const Header = () => {
  return (
    <div className="sticky lg:static top-0 navbar bg-base-100 min-h-0 shrink-0 justify-between z-20 shadow-md shadow-secondary px-2 sm:px-4">
      <div className="navbar-start">
        <Link href="/" passHref className="flex items-center gap-2 shrink-0">
          <div className="flex flex-col leading-tight">
            <span className="font-bold text-lg">Creature Feature</span>
            <span className="text-xs opacity-70">Real creatures. Real competition.</span>
          </div>
        </Link>
      </div>
      <div className="navbar-end gap-3">
        <Link href="/about" className="text-sm font-medium opacity-70 hover:opacity-100 hidden sm:block">
          About
        </Link>
        <RainbowKitCustomConnectButton />
      </div>
    </div>
  );
};
