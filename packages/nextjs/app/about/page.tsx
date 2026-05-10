import Link from "next/link";
import type { NextPage } from "next";

const About: NextPage = () => {
  return (
    <main className="max-w-3xl mx-auto px-4 py-12 flex flex-col gap-10">
      <div>
        <h1 className="text-4xl font-bold mb-2">About Creature Feature</h1>
        <p className="opacity-70 text-lg">A game where nature wins.</p>
      </div>

      {/* Section 1 — What this is */}
      <section className="card bg-base-100 border border-base-300">
        <div className="card-body p-6 flex flex-col gap-3">
          <h2 className="text-2xl font-bold my-0">What this is</h2>
          <p className="text-sm leading-relaxed my-0">
            Creature Feature is an on-chain competition where players crown real animals as champions across six
            categories — Most Pudgy Penguin, Most Dapper Lobster, Most Pepe Frog, Cutest, Best Camouflage, and Best
            Eyes. Every submission, challenge, and vote is backed by a real observation on{" "}
            <a href="https://www.inaturalist.org" target="_blank" rel="noreferrer" className="link">
              iNaturalist
            </a>
            .
          </p>
          <p className="text-sm leading-relaxed my-0">
            To submit a champion, you spend <strong>1,000 CLAWD</strong>. To challenge a sitting champion, 100 CLAWD. To
            vote during an active challenge, another 100 CLAWD. The champion with the most votes after 48 hours keeps
            the crown; ties go to the defender.
          </p>
          <p className="text-sm leading-relaxed my-0">
            All on-chain state lives in the{" "}
            <a
              href="https://basescan.org/address/0xc4a2f0bb3fc691c7a008dddfbf9094a1ed95ba74"
              target="_blank"
              rel="noreferrer"
              className="link"
            >
              ClawdSearch contract
            </a>{" "}
            on Base.
          </p>
        </div>
      </section>

      {/* Section 2 — How payments work */}
      <section className="card bg-base-100 border border-base-300">
        <div className="card-body p-6 flex flex-col gap-3">
          <h2 className="text-2xl font-bold my-0">How payments work</h2>
          <p className="text-sm leading-relaxed my-0">
            Every CLAWD payment is split three ways on-chain, automatically:
          </p>
          <ul className="text-sm flex flex-col gap-2 my-0 list-none p-0">
            <li className="flex items-start gap-3">
              <span className="text-xl shrink-0">🌿</span>
              <div>
                <strong>80% → Wildlife conservation.</strong> The CLAWD is swapped to USDC via Uniswap V3 and donated
                on-chain to the{" "}
                <a href="https://www.worldwildlife.org" target="_blank" rel="noreferrer" className="link">
                  World Wildlife Fund
                </a>{" "}
                through{" "}
                <a href="https://endaoment.org" target="_blank" rel="noreferrer" className="link">
                  Endaoment
                </a>
                , a registered 501(c)(3) nonprofit.
              </div>
            </li>
            <li className="flex items-start gap-3">
              <span className="text-xl shrink-0">🔥</span>
              <div>
                <strong>10% → Burned.</strong> Sent to the dead address, permanently removing CLAWD from circulation.
              </div>
            </li>
            <li className="flex items-start gap-3">
              <span className="text-xl shrink-0">🏛️</span>
              <div>
                <strong>10% → Builders fund.</strong> Goes to the CLAWD treasury to fund ongoing development and
                community initiatives.
              </div>
            </li>
          </ul>
          <p className="text-sm leading-relaxed my-0">
            The charity swap uses a two-hop Uniswap V3 path (CLAWD → WETH → USDC) with 1% slippage tolerance. If the
            swap fails for any reason, the CLAWD is refunded in-kind to Endaoment. The split ratios are owner-adjustable
            within the contract.
          </p>
        </div>
      </section>

      {/* Section 3 — Live stats */}
      <section className="card bg-base-100 border border-base-300">
        <div className="card-body p-6 flex flex-col gap-3">
          <h2 className="text-2xl font-bold my-0">Live stats</h2>
          <p className="text-sm leading-relaxed my-0">
            The stat strip on the{" "}
            <Link href="/" className="link">
              main page
            </Link>{" "}
            shows live totals pulled directly from the contract: creatures submitted, CLAWD burned, and USDC donated to
            wildlife. All figures are cumulative since Phase 3 launched.
          </p>
        </div>
      </section>

      <footer className="text-xs opacity-50 leading-relaxed border-t border-base-300 pt-6">
        Creature Feature is a community game on Base mainnet. CLAWD is a meme token with no guaranteed monetary value.
        Donations are processed on-chain through Endaoment, a registered 501(c)(3) public charity (EIN 84-4007162).
        Endaoment does not endorse this application. Tax deductibility of donations depends on your jurisdiction —
        consult a tax professional. This is not financial or investment advice.
      </footer>
    </main>
  );
};

export default About;
