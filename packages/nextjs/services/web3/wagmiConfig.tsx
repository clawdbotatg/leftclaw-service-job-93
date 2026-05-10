import { wagmiConnectors } from "./wagmiConnectors";
import { Chain, createClient, fallback, http } from "viem";
import { hardhat, mainnet } from "viem/chains";
import { createConfig } from "wagmi";
import scaffoldConfig, { DEFAULT_ALCHEMY_API_KEY, ScaffoldConfig } from "~~/scaffold.config";
import { getAlchemyHttpUrl } from "~~/utils/scaffold-eth";

const { targetNetworks } = scaffoldConfig;

// We always want to have mainnet enabled (ENS resolution, ETH price, etc). But only once.
export const enabledChains = targetNetworks.find((network: Chain) => network.id === 1)
  ? targetNetworks
  : ([...targetNetworks, mainnet] as const);

export const wagmiConfig = createConfig({
  chains: enabledChains,
  connectors: wagmiConnectors(),
  ssr: true,
  client: ({ chain }) => {
    const mainnetFallbackWithDefaultRPC = [http("https://mainnet.rpc.buidlguidl.com")];
    // Start with public fallbacks; mainnet gets BuidlGuidl RPC, others get bare http() as last resort.
    let rpcFallbacks: ReturnType<typeof http>[] = [
      ...(chain.id === mainnet.id ? mainnetFallbackWithDefaultRPC : []),
      http(),
    ];
    const rpcOverrideUrl = (scaffoldConfig.rpcOverrides as ScaffoldConfig["rpcOverrides"])?.[chain.id];
    if (rpcOverrideUrl) {
      rpcFallbacks = [http(rpcOverrideUrl), ...rpcFallbacks];
    } else {
      const alchemyHttpUrl = getAlchemyHttpUrl(chain.id);
      if (alchemyHttpUrl) {
        const isUsingDefaultKey = scaffoldConfig.alchemyApiKey === DEFAULT_ALCHEMY_API_KEY;
        if (isUsingDefaultKey) {
          // Default key: public RPC first (rate-limited anyway), Alchemy as fallback.
          rpcFallbacks = [...rpcFallbacks, http(alchemyHttpUrl)];
        } else {
          // Real Alchemy key: Alchemy only — drop the bare http() public fallback to
          // prevent rate-limited public RPC requests on page load with many contract reads.
          rpcFallbacks =
            chain.id === mainnet.id ? [http(alchemyHttpUrl), ...mainnetFallbackWithDefaultRPC] : [http(alchemyHttpUrl)];
        }
      }
    }
    return createClient({
      chain,
      transport: fallback(rpcFallbacks),
      ...(chain.id !== (hardhat as Chain).id ? { pollingInterval: scaffoldConfig.pollingInterval } : {}),
    });
  },
});
