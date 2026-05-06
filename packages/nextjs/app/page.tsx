"use client";

import dynamic from "next/dynamic";

// The Clawd Search app uses wagmi hooks heavily and reads chain state at
// import time via SE2 wrappers. We render it client-only to avoid prerender
// errors during the static export.
const ClawdSearchApp = dynamic(() => import("./_components/ClawdSearchApp"), {
  ssr: false,
  loading: () => (
    <div className="flex flex-col items-center justify-center grow py-20 gap-3">
      <div className="text-4xl">🦞</div>
      <div className="opacity-60 text-sm">Loading Clawd Search…</div>
    </div>
  ),
});

const Home = () => {
  return <ClawdSearchApp />;
};

export default Home;
