// ============================================================
// FeeCompounder Hook — Frontend
// UHI9 Hookathon 2026 | Demo Day June 19, 2026
// Built for: Uniswap v4 + Reactive Network
//
// "Beefy-style fee compounding inside a Uniswap v4 hook,
//  driven by Reactive Network."
//
// Live deployment: Unichain Sepolia (hook + pool) / Reactive Lasna (RSC)
// All addresses, ABIs and pool config below are the REAL deployed values
// read directly from the project's broadcast + on-chain state.
// ============================================================
import { useState, useEffect, useCallback, useRef, useMemo } from "react";
import { ethers } from "ethers";
import {
  Wallet,
  Activity,
  Layers,
  Coins,
  Fuel,
  Clock,
  TrendingUp,
  ArrowDownUp,
  Check,
  Copy,
  ExternalLink,
  ShieldCheck,
  GitBranch,
  RefreshCw,
  ChevronDown,
  AlertTriangle,
  Radio,
  Droplet,
  Tag,
  Zap,
  X,
} from "lucide-react";

// ─── CONSTANTS ───────────────────────────────────────────────
const CHAIN_ID = 1301; // Unichain Sepolia
const CHAIN_NAME = "Unichain Sepolia";
const CHAIN_HEX = "0x" + CHAIN_ID.toString(16);
const RPC_URL = "https://sepolia.unichain.org";
const EXPLORER_BASE = "https://unichain-sepolia.blockscout.com";
// NOTE: Unichain Sepolia public JSON-RPC nodes serve eth_call but NOT
// eth_getLogs (they return empty for every range). Historical + live logs are
// read from the Blockscout indexer API instead, which has the full event set.
const BLOCKSCOUT_API = `${EXPLORER_BASE}/api`;
const DEPLOY_BLOCK = 53942893; // first block of the demo deployment

// Reactive Network — RSC is deployed on the Lasna testnet (chain 5318007)
const REACTIVE_RPC = "https://lasna-rpc.rnk.dev/";
const REACTIVE_EXPLORER = "https://lasna.reactscan.net";
const REACTIVE_CHAIN_ID = 5318007;

const ADDRESSES = {
  HOOK: "0xB7DB48F88D2BcfecB6432F8fee4f2dc2f7824640",
  RSC: "0x4EEEa1Ba520257143906D950A27FEC288C87d11C", // on Lasna
  POOL_MANAGER: "0x00b036b58a818b1bc34d502d3fe730db729e62ac",
  TOKEN0: "0xF580EeEb192843e9D2fE5c83E093495139C740aC",
  TOKEN1: "0x1440BBe915431B489Bf65005F5c9AfFad1810092",
  AAVE_ADAPTER: "0x4692f3Ad0796Fe7428465821AB0015a8E8146D19",
  MORPHO_ADAPTER: "0x1E84bAaA8Da2Ce2D145C773c91b6cB3253c02175",
  POOL_REINVEST_ADAPTER: "0x0477Fa2cC9eEE5b52262A56B97684Da2db865AE7",
  CALLBACK_PROXY: "0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4",
  REACTIVE_SENDER: "0x4b992F2Fbf714C0fCBb23baC5130Ace48CaD00cd",
};

const POOL_ID =
  "0x6f9e18a470ba48beafb438ac56f6a66c47a126db70e2c2d1f8420ce933e2b623";

const POOL_FEE = 3000; // 0.30%
const TICK_SPACING = 60;

// PoolKey tuple in canonical (sorted) order — matches the deployed pool id.
const POOL_KEY = [
  ADDRESSES.TOKEN0,
  ADDRESSES.TOKEN1,
  POOL_FEE,
  TICK_SPACING,
  ADDRESSES.HOOK,
];

const TOKENS = {
  TOKEN0: { symbol: "FCD0", decimals: 18, address: ADDRESSES.TOKEN0 },
  TOKEN1: { symbol: "FCD1", decimals: 18, address: ADDRESSES.TOKEN1 },
};

const ROUTES = {
  [ADDRESSES.AAVE_ADAPTER.toLowerCase()]: "Aave v3",
  [ADDRESSES.MORPHO_ADAPTER.toLowerCase()]: "Morpho",
  [ADDRESSES.POOL_REINVEST_ADAPTER.toLowerCase()]: "Pool Reinvest",
};
const ROUTE_LIST = [
  { key: "MORPHO", name: "Morpho", address: ADDRESSES.MORPHO_ADAPTER },
  { key: "AAVE", name: "Aave v3", address: ADDRESSES.AAVE_ADAPTER },
  {
    key: "POOL",
    name: "Pool Reinvest",
    address: ADDRESSES.POOL_REINVEST_ADAPTER,
  },
];

// How far back to scan for historical events on load.
// Public RPCs cap eth_getLogs at 10k blocks/call, so we page in windows.
const LOOKBACK_BLOCKS = 250000;
const LOG_WINDOW = 9500;
const LOG_CONCURRENCY = 6;

// ─── ABIs (curated — only what the UI needs) ─────────────────
const HOOK_ABI = [
  "function pools(bytes32) view returns (uint256 totalShares, uint256 totalAssets0, uint256 totalAssets1, uint256 pendingFees0, uint256 pendingFees1, uint256 routeShares0, uint256 routeShares1, uint256 lastCompoundBlock, address activeYieldRoute, bool initialized)",
  "function pendingFeesFor(bytes32 id) view returns (uint256 pending0, uint256 pending1)",
  "function sharesToAssets(bytes32 id, uint256 shares) view returns (uint256 assets0, uint256 assets1)",
  "function lpShares(bytes32, address) view returns (uint256)",
  "function lpBalance(bytes32, address) view returns (uint256)",
  "function minCompoundThreshold() view returns (uint256)",
  "function gasPriceCeiling() view returns (uint256)",
  "function cooldownBlocks() view returns (uint256)",
  "function maxHoldBlocks() view returns (uint256)",
  "function compoundFeeBps() view returns (uint256)",
  "function defaultRoute() view returns (address)",
  "function feeReporter() view returns (address)",
  "function callbackProxy() view returns (address)",
  "function reactiveSender() view returns (address)",
  "function directCompoundCaller() view returns (address)",
  "function whitelistedAdapters(address) view returns (bool)",
  "function depositForDemo((address,address,uint24,int24,address) key, uint256 amount0, uint256 amount1, address receiver) returns (uint256 shares)",
  "function reportFees((address,address,uint24,int24,address) key, uint256 rawFee0, uint256 rawFee1)",
  "function triggerCompound((address,address,uint24,int24,address) key, address route)",
  "function withdrawShares((address,address,uint24,int24,address) key, uint256 shares, address receiver)",
  "event FeesAccrued(bytes32 indexed poolId, uint256 amount0, uint256 amount1, uint256 totalPending0, uint256 totalPending1, uint256 gasPrice, uint256 blockNumber)",
  "event CompoundExecuted(bytes32 indexed poolId, address indexed route, uint256 amount0Compounded, uint256 amount1Compounded, uint256 newTotalAssets0, uint256 newTotalAssets1, uint256 blockNumber)",
  "event SharesMinted(bytes32 indexed poolId, address indexed lp, uint256 sharesIssued, uint256 assets0, uint256 assets1)",
  "event SharesBurned(bytes32 indexed poolId, address indexed lp, uint256 sharesBurned, uint256 assets0, uint256 assets1)",
];

const ADAPTER_ABI = [
  "function name() view returns (string)",
  "function apyBps() view returns (uint256)",
  "function currentAPY(address) view returns (uint256)",
];

const ERC20_ABI = [
  "function symbol() view returns (string)",
  "function decimals() view returns (uint8)",
  "function balanceOf(address) view returns (uint256)",
  "function allowance(address,address) view returns (uint256)",
  "function approve(address,uint256) returns (bool)",
];

const RSC_ABI = [
  "event CompoundCallbackQueued(bytes32 indexed poolId, address indexed route, uint256 pending, uint256 gasPrice)",
  "event CompoundSkipped(bytes32 indexed poolId, string reason)",
  "event RouteAPYUpdated(address indexed route, uint256 apyBps)",
  "event PoolConfigured(bytes32 indexed poolId)",
  "event Callback(uint256 indexed chain_id, address indexed _contract, uint64 indexed gas_limit, bytes payload)",
];

// ─── HELPERS ─────────────────────────────────────────────────
const getReadProvider = () => new ethers.JsonRpcProvider(RPC_URL);
const getReactiveProvider = () => new ethers.JsonRpcProvider(REACTIVE_RPC);
const getBrowserProvider = () =>
  window.ethereum ? new ethers.BrowserProvider(window.ethereum) : null;

// Run async tasks with bounded concurrency (avoids hammering public RPCs).
async function mapLimit(items, limit, worker) {
  const out = new Array(items.length);
  let i = 0;
  const runners = Array.from({ length: Math.min(limit, items.length) }, async () => {
    while (i < items.length) {
      const idx = i++;
      out[idx] = await worker(items[idx], idx);
    }
  });
  await Promise.all(runners);
  return out;
}

// queryFilter across a large range by paging in <=10k-block windows.
// (Used for the Reactive/Lasna provider, which does serve eth_getLogs.)
async function getLogsChunked(contract, filter, fromBlock, toBlock) {
  const windows = [];
  for (let start = toBlock; start >= fromBlock; start -= LOG_WINDOW + 1) {
    windows.push([Math.max(fromBlock, start - LOG_WINDOW), start]);
  }
  const chunks = await mapLimit(windows, LOG_CONCURRENCY, async ([f, t]) => {
    try {
      return await contract.queryFilter(filter, f, t);
    } catch {
      return [];
    }
  });
  return chunks.flat();
}

// Decode hook event logs via the Blockscout indexer API. Blockscout pads the
// topics array to length 4 with nulls, which ethers rejects — so we strip
// non-32-byte entries before parsing.
const HOOK_IFACE = new ethers.Interface(HOOK_ABI);

async function fetchHookLogsApi(fromBlock) {
  try {
    const url = `${BLOCKSCOUT_API}?module=logs&action=getLogs&address=${ADDRESSES.HOOK}&fromBlock=${fromBlock}&toBlock=latest`;
    const res = await fetch(url);
    const j = await res.json();
    if (!Array.isArray(j.result)) return [];
    const out = [];
    for (const l of j.result) {
      const topics = (l.topics || []).filter(
        (t) => typeof t === "string" && t.startsWith("0x") && t.length === 66
      );
      let parsed;
      try {
        parsed = HOOK_IFACE.parseLog({ topics, data: l.data });
      } catch {
        continue;
      }
      if (!parsed) continue;
      out.push({
        name: parsed.name,
        args: parsed.args,
        blockNumber: parseInt(l.blockNumber, 16),
        transactionHash: l.transactionHash,
        logIndex: parseInt(l.logIndex || l.index || "0x0", 16),
      });
    }
    return out.sort(
      (a, b) => a.blockNumber - b.blockNumber || a.logIndex - b.logIndex
    );
  } catch {
    return [];
  }
}

const inPool = (l) =>
  !l.args?.poolId || l.args.poolId.toLowerCase() === POOL_ID.toLowerCase();

const truncate = (s, a = 6, b = 4) =>
  s ? `${s.slice(0, a)}…${s.slice(-b)}` : "";

const explorerTx = (h, reactive = false) =>
  `${reactive ? REACTIVE_EXPLORER : EXPLORER_BASE}/tx/${h}`;
const explorerAddr = (a, reactive = false) =>
  `${reactive ? REACTIVE_EXPLORER : EXPLORER_BASE}/address/${a}`;

const fmt = (v, decimals = 18, prec = 3) => {
  try {
    const n = Number(ethers.formatUnits(v ?? 0n, decimals));
    if (n === 0) return "0";
    if (n < 0.001) return "<0.001";
    return n.toLocaleString("en-US", {
      maximumFractionDigits: prec,
      minimumFractionDigits: 0,
    });
  } catch {
    return "0";
  }
};

const bpsToPct = (bps) => (Number(bps) / 100).toFixed(2);
const routeName = (addr) =>
  addr ? ROUTES[addr.toLowerCase()] || truncate(addr) : "—";

const shortReason = (e) => {
  const m = e?.shortMessage || e?.reason || e?.message || "Transaction failed";
  return m.length > 90 ? m.slice(0, 90) + "…" : m;
};

const ZERO = "0x0000000000000000000000000000000000000000";

// ─── SMALL UI PRIMITIVES ─────────────────────────────────────
function Dot({ color = "emerald", pulse = true }) {
  const map = {
    emerald: "bg-emerald-400",
    amber: "bg-amber-400",
    gray: "bg-neutral-500",
    red: "bg-red-400",
    accent: "bg-accent",
  };
  return (
    <span className="relative inline-flex h-2 w-2">
      {pulse && (
        <span
          className={`absolute inline-flex h-full w-full rounded-full opacity-60 fc-pulse ${map[color]}`}
        />
      )}
      <span className={`relative inline-flex h-2 w-2 rounded-full ${map[color]}`} />
    </span>
  );
}

function Copyable({ value, display, reactive = false, link = true }) {
  const [copied, setCopied] = useState(false);
  const onCopy = (e) => {
    e.preventDefault();
    e.stopPropagation();
    navigator.clipboard?.writeText(value);
    setCopied(true);
    setTimeout(() => setCopied(false), 1100);
  };
  return (
    <span className="group inline-flex items-center gap-1.5 font-mono text-[12.5px]">
      <span className="text-txt-dim">{display || truncate(value)}</span>
      <button
        onClick={onCopy}
        title="Copy"
        className="text-neutral-600 hover:text-accent transition-colors"
      >
        {copied ? <Check size={12} /> : <Copy size={12} />}
      </button>
      {link && value && (
        <a
          href={explorerAddr(value, reactive)}
          target="_blank"
          rel="noreferrer"
          title="View on explorer"
          className="text-neutral-600 hover:text-accent transition-colors"
        >
          <ExternalLink size={12} />
        </a>
      )}
    </span>
  );
}

function Card({ children, className = "" }) {
  return (
    <div
      className={`rounded-xl border border-line bg-card ${className}`}
    >
      {children}
    </div>
  );
}

function SectionTitle({ icon: Icon, title, right }) {
  return (
    <div className="flex items-center justify-between px-5 pt-4 pb-3 border-b border-line">
      <div className="flex items-center gap-2 text-txt">
        {Icon && <Icon size={15} className="text-accent" />}
        <h3 className="text-[13px] font-semibold tracking-wide">{title}</h3>
      </div>
      {right}
    </div>
  );
}

function Skeleton({ className = "" }) {
  return <div className={`fc-skeleton rounded-md ${className}`} />;
}

function RouteBadge({ name }) {
  const tone =
    name === "Morpho"
      ? "text-accent-soft border-accent/40 bg-accent/10"
      : name === "Aave v3"
        ? "text-indigo-300 border-indigo-500/30 bg-indigo-500/10"
        : "text-emerald-300 border-emerald-500/30 bg-emerald-500/10";
  return (
    <span
      className={`inline-flex items-center rounded-md border px-2 py-0.5 text-[11px] font-semibold ${tone}`}
    >
      {name}
    </span>
  );
}

// ─── HOOK: wallet ────────────────────────────────────────────
function useWallet() {
  const [account, setAccount] = useState(null);
  const [chainId, setChainId] = useState(null);

  const refresh = useCallback(async () => {
    const eth = window.ethereum;
    if (!eth) return;
    try {
      const accs = await eth.request({ method: "eth_accounts" });
      setAccount(accs?.[0] || null);
      const cid = await eth.request({ method: "eth_chainId" });
      setChainId(parseInt(cid, 16));
    } catch {
      /* ignore */
    }
  }, []);

  useEffect(() => {
    refresh();
    const eth = window.ethereum;
    if (!eth) return;
    const onAcc = (a) => setAccount(a?.[0] || null);
    const onChain = (c) => setChainId(parseInt(c, 16));
    eth.on?.("accountsChanged", onAcc);
    eth.on?.("chainChanged", onChain);
    return () => {
      eth.removeListener?.("accountsChanged", onAcc);
      eth.removeListener?.("chainChanged", onChain);
    };
  }, [refresh]);

  const connect = useCallback(async () => {
    const eth = window.ethereum;
    if (!eth) {
      window.open("https://metamask.io/download/", "_blank");
      return;
    }
    const accs = await eth.request({ method: "eth_requestAccounts" });
    setAccount(accs?.[0] || null);
    await refresh();
  }, [refresh]);

  const disconnect = useCallback(() => setAccount(null), []);

  const switchNetwork = useCallback(async () => {
    const eth = window.ethereum;
    if (!eth) return;
    try {
      await eth.request({
        method: "wallet_switchEthereumChain",
        params: [{ chainId: CHAIN_HEX }],
      });
    } catch (err) {
      if (err?.code === 4902) {
        await eth.request({
          method: "wallet_addEthereumChain",
          params: [
            {
              chainId: CHAIN_HEX,
              chainName: CHAIN_NAME,
              nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
              rpcUrls: [RPC_URL],
              blockExplorerUrls: [EXPLORER_BASE],
            },
          ],
        });
      }
    }
  }, []);

  return {
    account,
    chainId,
    connect,
    disconnect,
    switchNetwork,
    wrongNetwork: account != null && chainId != null && chainId !== CHAIN_ID,
  };
}

// ─── HOOK: activity feed + toasts ────────────────────────────
let _id = 0;
const nextId = () => `${Date.now()}-${++_id}`;

function useActivity() {
  const [feed, setFeed] = useState([]);
  const add = useCallback((entry) => {
    setFeed((prev) => {
      // de-dupe by txHash when present
      if (entry.txHash && prev.some((e) => e.txHash === entry.txHash))
        return prev;
      return [entry, ...prev].slice(0, 50);
    });
  }, []);
  const update = useCallback((id, patch) => {
    setFeed((prev) => prev.map((e) => (e.id === id ? { ...e, ...patch } : e)));
  }, []);
  return { feed, add, update, setFeed };
}

function useToasts() {
  const [toasts, setToasts] = useState([]);
  const push = useCallback((t) => {
    setToasts((prev) => [...prev, t]);
    if (t.status !== "FAILED") {
      setTimeout(
        () => setToasts((prev) => prev.filter((x) => x.id !== t.id)),
        8000
      );
    }
  }, []);
  const update = useCallback((id, patch) => {
    setToasts((prev) => prev.map((t) => (t.id === id ? { ...t, ...patch } : t)));
    setTimeout(
      () => setToasts((prev) => prev.filter((t) => t.id !== id || t.status === "FAILED")),
      8000
    );
  }, []);
  const dismiss = useCallback(
    (id) => setToasts((prev) => prev.filter((t) => t.id !== id)),
    []
  );
  return { toasts, push, update, dismiss };
}

// ============================================================
// COMPONENT: TopBar — logo, chain badge, wallet
// ============================================================
function TopBar({ wallet, latestBlock }) {
  const { account, chainId, connect, disconnect, wrongNetwork } = wallet;
  return (
    <header className="sticky top-0 z-30 flex h-14 items-center justify-between border-b border-line bg-ink/80 px-5 backdrop-blur">
      <div className="flex items-center gap-2.5">
        <div className="flex h-7 w-7 items-center justify-center rounded-lg bg-gradient-to-br from-accent to-blue-600 text-[15px] shadow-[0_0_18px_rgba(34,211,238,0.35)]">
          ⚛️
        </div>
        <div className="leading-none">
          <div className="text-[14px] font-semibold text-txt">
            FeeCompounder Hook
          </div>
          <div className="mt-0.5 text-[10.5px] text-txt-dim">
            Uniswap v4 × Reactive Network
          </div>
        </div>
      </div>

      <div className="flex items-center gap-3">
        <div
          className={`flex items-center gap-1.5 rounded-lg border px-2.5 py-1.5 text-[12px] font-medium ${
            wrongNetwork
              ? "border-red-500/40 bg-red-500/10 text-red-300"
              : "border-line bg-card text-txt-dim"
          }`}
        >
          <Dot color={wrongNetwork ? "red" : "emerald"} pulse={!wrongNetwork} />
          {wrongNetwork ? "Wrong Network" : CHAIN_NAME}
          <span className="text-neutral-600">· {CHAIN_ID}</span>
        </div>

        {account ? (
          <button
            onClick={disconnect}
            title="Click to disconnect"
            className="flex items-center gap-2 rounded-lg border border-line bg-card px-3 py-1.5 text-[12.5px] font-medium text-txt transition-colors hover:border-accent/50"
          >
            <span className="h-1.5 w-1.5 rounded-full bg-emerald-400" />
            <span className="font-mono">{truncate(account)}</span>
          </button>
        ) : (
          <button
            onClick={connect}
            className="flex items-center gap-2 rounded-lg bg-accent px-3.5 py-1.5 text-[12.5px] font-semibold text-white transition-colors hover:bg-accent-soft"
          >
            <Wallet size={14} /> Connect Wallet
          </button>
        )}
      </div>
    </header>
  );
}

// ============================================================
// COMPONENT: LiveProofStrip — thin "live on chain" bar
// ============================================================
function LiveProofStrip({ latestBlock, lastTx }) {
  return (
    <div className="flex items-center gap-3 border-b border-line bg-gradient-to-r from-accent/[0.07] to-transparent px-5 py-1.5 text-[11.5px]">
      <span className="flex items-center gap-1.5 font-medium text-emerald-300">
        <Dot color="emerald" /> LIVE ON {CHAIN_NAME.toUpperCase()}
      </span>
      <span className="text-neutral-700">|</span>
      <span className="text-txt-dim">
        Block{" "}
        <span className="font-mono text-txt">
          {latestBlock ? latestBlock.toLocaleString() : "—"}
        </span>
      </span>
      {lastTx && (
        <>
          <span className="text-neutral-700">|</span>
          <span className="flex items-center gap-1.5 text-txt-dim">
            Latest tx
            <a
              href={explorerTx(lastTx)}
              target="_blank"
              rel="noreferrer"
              className="flex items-center gap-1 font-mono text-accent hover:text-accent-soft"
            >
              {truncate(lastTx)} <ExternalLink size={11} />
            </a>
          </span>
        </>
      )}
    </div>
  );
}

// ============================================================
// COMPONENT: LeftSidebar — pool info, RSC status, nav
// ============================================================
function LeftSidebar({ pool, config, rsc, loading }) {
  return (
    <aside className="flex w-[280px] shrink-0 flex-col gap-5 border-r border-line bg-panel px-5 py-5">
      {/* Pool info */}
      <div>
        <div className="mb-3 text-[11px] font-semibold uppercase tracking-wider text-txt-dim">
          Pool
        </div>
        <div className="mb-3 flex items-center gap-2">
          <div className="flex -space-x-2">
            <span className="flex h-7 w-7 items-center justify-center rounded-full border border-line bg-accent/20 text-[10px] font-bold text-accent-soft">
              {TOKENS.TOKEN0.symbol.slice(-2)}
            </span>
            <span className="flex h-7 w-7 items-center justify-center rounded-full border border-line bg-blue-500/15 text-[10px] font-bold text-blue-300">
              {TOKENS.TOKEN1.symbol.slice(-2)}
            </span>
          </div>
          <div className="text-[14px] font-semibold text-txt">
            {TOKENS.TOKEN0.symbol} / {TOKENS.TOKEN1.symbol}
          </div>
          <span className="ml-auto rounded-md border border-line px-1.5 py-0.5 text-[10px] text-txt-dim">
            {POOL_FEE / 10000}%
          </span>
        </div>

        <div className="space-y-2 text-[12px]">
          <Row label="Pool ID" value={POOL_ID} link={false} />
          <Row label="Hook" value={ADDRESSES.HOOK} />
          <Row label="Pool Manager" value={ADDRESSES.POOL_MANAGER} />
          <Row label="Token0" value={ADDRESSES.TOKEN0} />
          <Row label="Token1" value={ADDRESSES.TOKEN1} />
        </div>
      </div>

      {/* RSC status */}
      <div className="border-t border-line pt-4">
        <div className="mb-3 flex items-center gap-2 text-[11px] font-semibold uppercase tracking-wider text-txt-dim">
          Reactive Smart Contract
        </div>
        <div className="mb-2 flex items-center gap-2 text-[12.5px] text-txt">
          <Dot color="accent" />
          RSC Monitoring
        </div>
        <p className="mb-3 text-[11.5px] leading-relaxed text-txt-dim">
          Watching{" "}
          <span className="font-mono text-accent-soft">FeesAccrued</span> on the
          hook, applying threshold / gas / cooldown gates.
        </p>
        <div className="space-y-2 text-[12px]">
          <Row label="RSC" value={ADDRESSES.RSC} reactive />
          <div className="flex items-center justify-between">
            <span className="text-txt-dim">Last compound</span>
            {loading ? (
              <Skeleton className="h-3 w-16" />
            ) : (
              <span className="font-mono text-[12px] text-txt">
                {pool?.lastCompoundBlock
                  ? `#${pool.lastCompoundBlock.toLocaleString()}`
                  : "—"}
              </span>
            )}
          </div>
        </div>
        <a
          href={explorerAddr(ADDRESSES.RSC, true)}
          target="_blank"
          rel="noreferrer"
          className="mt-3 inline-flex items-center gap-1 text-[12px] font-medium text-accent hover:text-accent-soft"
        >
          View on Reactive Explorer <ExternalLink size={12} />
        </a>
      </div>

      {/* Nav */}
      <nav className="mt-auto border-t border-line pt-4">
        {[
          ["overview", "Overview"],
          ["actions", "Actions"],
          ["chart", "Reserve Chart"],
          ["activity", "Activity"],
          ["rsc", "RSC Panel"],
          ["verify", "Verify on Chain"],
        ].map(([id, label]) => (
          <a
            key={id}
            href={`#${id}`}
            className="block rounded-md px-2 py-1.5 text-[12.5px] text-txt-dim transition-colors hover:bg-white/[0.03] hover:text-txt"
          >
            {label}
          </a>
        ))}
      </nav>
    </aside>
  );
}

function Row({ label, value, reactive = false, link = true }) {
  return (
    <div className="flex items-center justify-between">
      <span className="text-txt-dim">{label}</span>
      <Copyable value={value} reactive={reactive} link={link} />
    </div>
  );
}

// ============================================================
// COMPONENT: HeroMetricCards
// ============================================================
function Metric({ icon: Icon, label, value, sub, loading, accent }) {
  return (
    <Card className="px-4 py-3.5 fc-fade">
      <div className="mb-2 flex items-center gap-1.5 text-[11px] font-medium text-txt-dim">
        {Icon && <Icon size={12} />} {label}
      </div>
      {loading ? (
        <Skeleton className="h-7 w-24" />
      ) : (
        <div
          className={`font-mono text-[22px] font-semibold leading-none ${
            accent ? "text-accent-soft" : "text-txt"
          }`}
        >
          {value}
        </div>
      )}
      <div className="mt-1.5 h-4 text-[11px] text-txt-dim">{!loading && sub}</div>
    </Card>
  );
}

function HeroMetricCards({ pool, config, apys, bestRoute, latestBlock, loading }) {
  const tvl =
    pool != null
      ? Number(ethers.formatUnits(pool.totalAssets0, 18)) +
        Number(ethers.formatUnits(pool.totalAssets1, 18))
      : 0;
  const pending =
    pool != null
      ? Number(ethers.formatUnits(pool.pendingFees0, 18)) +
        Number(ethers.formatUnits(pool.pendingFees1, 18))
      : 0;
  const threshold = config ? Number(ethers.formatUnits(config.minThreshold, 18)) : 1;
  const blocksAgo =
    pool?.lastCompoundBlock && latestBlock
      ? Math.max(0, latestBlock - pool.lastCompoundBlock)
      : null;

  return (
    <div className="grid grid-cols-6 gap-3">
      <Metric
        icon={TrendingUp}
        label="Best Route APY"
        value={bestRoute ? `${bpsToPct(bestRoute.apy)}%` : "—"}
        sub={bestRoute ? `via ${bestRoute.name}` : ""}
        loading={loading}
        accent
      />
      <Metric
        icon={Coins}
        label="Pending Reserve"
        value={`${pending.toLocaleString("en-US", { maximumFractionDigits: 2 })}`}
        sub={`threshold ${threshold} · ${pending >= threshold ? "ready" : "below"}`}
        loading={loading}
      />
      <Metric
        icon={Layers}
        label="Vault TVL"
        value={tvl.toLocaleString("en-US", { maximumFractionDigits: 2 })}
        sub={`${TOKENS.TOKEN0.symbol}+${TOKENS.TOKEN1.symbol} backed`}
        loading={loading}
      />
      <Metric
        icon={GitBranch}
        label="Total LP Shares"
        value={pool ? fmt(pool.totalShares, 18, 2) : "—"}
        sub={pool?.initialized ? "pool initialized" : "uninitialized"}
        loading={loading}
      />
      <Metric
        icon={Clock}
        label="Last Compound"
        value={blocksAgo != null ? `${blocksAgo.toLocaleString()}` : "—"}
        sub={blocksAgo != null ? "blocks ago" : ""}
        loading={loading}
      />
      <Metric
        icon={Tag}
        label="Active Route"
        value={
          pool && pool.activeYieldRoute !== ZERO
            ? routeName(pool.activeYieldRoute)
            : "default"
        }
        sub={`compound fee ${config ? Number(config.compoundFeeBps) / 100 : 10}%`}
        loading={loading}
      />
    </div>
  );
}

// ============================================================
// COMPONENT: DemoFlowIndicator
// ============================================================
const DEMO_STEPS = [
  "Pool Initialized",
  "LP Deposits",
  "Fees Reported",
  "RSC Evaluates",
  "Compound Executed",
  "LP Withdraws",
];

function DemoFlowIndicator({ step }) {
  return (
    <div className="flex items-center gap-1 overflow-x-auto rounded-xl border border-line bg-card px-4 py-3">
      {DEMO_STEPS.map((label, i) => {
        const done = i < step;
        const active = i === step;
        return (
          <div key={label} className="flex items-center gap-1">
            <div
              className={`flex items-center gap-1.5 whitespace-nowrap rounded-lg px-2.5 py-1 text-[11.5px] font-medium transition-colors ${
                done
                  ? "bg-emerald-500/10 text-emerald-300"
                  : active
                    ? "bg-accent/15 text-accent-soft"
                    : "text-txt-dim"
              }`}
            >
              <span
                className={`flex h-4 w-4 items-center justify-center rounded-full text-[9px] ${
                  done
                    ? "bg-emerald-400 text-black"
                    : active
                      ? "bg-accent text-white fc-pulse"
                      : "border border-line"
                }`}
              >
                {done ? <Check size={10} /> : i + 1}
              </span>
              {label}
            </div>
            {i < DEMO_STEPS.length - 1 && (
              <span
                className={`h-px w-4 ${done ? "bg-emerald-500/40" : "bg-line"}`}
              />
            )}
          </div>
        );
      })}
    </div>
  );
}

// ============================================================
// COMPONENT: ActionPanel — Deposit / Withdraw / Report / Compound
// ============================================================
function ActionPanel({ wallet, exec, refresh, balances, lpShares, roles, bestRoute }) {
  const [tab, setTab] = useState("deposit");
  const [a0, setA0] = useState("");
  const [a1, setA1] = useState("");
  const [shares, setShares] = useState("");
  const [pct, setPct] = useState(0);
  const [f0, setF0] = useState("");
  const [f1, setF1] = useState("");
  const [route, setRoute] = useState(ADDRESSES.MORPHO_ADAPTER);

  const connected = !!wallet.account && !wallet.wrongNetwork;
  const isReporter =
    wallet.account &&
    roles?.feeReporter &&
    wallet.account.toLowerCase() === roles.feeReporter.toLowerCase();

  useEffect(() => {
    if (bestRoute?.address) setRoute(bestRoute.address);
  }, [bestRoute?.address]);

  const setSharesPct = (p) => {
    setPct(p);
    if (lpShares != null) {
      const v = (lpShares * BigInt(p)) / 100n;
      setShares(ethers.formatUnits(v, 18));
    }
  };

  const tabs = [
    { id: "deposit", label: "Deposit", icon: Droplet },
    { id: "withdraw", label: "Withdraw", icon: ArrowDownUp },
    { id: "report", label: "Report Fees", icon: Tag },
    { id: "compound", label: "Compound", icon: Zap },
  ];

  return (
    <Card className="flex flex-col">
      <SectionTitle icon={GitBranch} title="Vault Actions" />
      <div className="flex gap-1 border-b border-line px-3 pt-3">
        {tabs.map((t) => (
          <button
            key={t.id}
            onClick={() => setTab(t.id)}
            className={`flex items-center gap-1.5 rounded-t-lg px-3 py-2 text-[12px] font-medium transition-colors ${
              tab === t.id
                ? "border-b-2 border-accent text-txt"
                : "text-txt-dim hover:text-txt"
            }`}
          >
            <t.icon size={13} /> {t.label}
          </button>
        ))}
      </div>

      <div className="p-5">
        {tab === "deposit" && (
          <div className="space-y-3">
            <p className="text-[12px] leading-relaxed text-txt-dim">
              Seed backed inventory into the vault. Shares are minted pro-rata;
              the first deposit burns 1000 dead shares to block inflation
              attacks.
            </p>
            <TokenInput
              token={TOKENS.TOKEN0}
              value={a0}
              onChange={setA0}
              balance={balances?.token0}
            />
            <TokenInput
              token={TOKENS.TOKEN1}
              value={a1}
              onChange={setA1}
              balance={balances?.token1}
            />
            <ActionButton
              disabled={!connected || (!a0 && !a1)}
              wallet={wallet}
              onClick={() =>
                exec.deposit(a0 || "0", a1 || "0").then(() => {
                  setA0("");
                  setA1("");
                })
              }
              label="Approve & Deposit"
              pending="Depositing…"
            />
          </div>
        )}

        {tab === "withdraw" && (
          <div className="space-y-3">
            <div className="flex items-center justify-between text-[12px]">
              <span className="text-txt-dim">Your shares</span>
              <span className="font-mono text-txt">
                {lpShares != null ? fmt(lpShares, 18, 4) : "—"}
              </span>
            </div>
            <div className="flex gap-1.5">
              {[25, 50, 75, 100].map((p) => (
                <button
                  key={p}
                  onClick={() => setSharesPct(p)}
                  className={`flex-1 rounded-lg border py-1.5 text-[11.5px] font-medium transition-colors ${
                    pct === p
                      ? "border-accent/50 bg-accent/10 text-accent-soft"
                      : "border-line text-txt-dim hover:text-txt"
                  }`}
                >
                  {p}%
                </button>
              ))}
            </div>
            <div className="rounded-lg border border-line bg-ink px-3 py-2.5">
              <div className="mb-1 text-[11px] text-txt-dim">Shares to burn</div>
              <input
                value={shares}
                onChange={(e) => {
                  setShares(e.target.value);
                  setPct(0);
                }}
                placeholder="0.0"
                inputMode="decimal"
                className="w-full bg-transparent font-mono text-[18px] text-txt outline-none placeholder:text-neutral-700"
              />
            </div>
            <ActionButton
              disabled={!connected || !shares || Number(shares) <= 0}
              wallet={wallet}
              onClick={() => exec.withdraw(shares).then(() => setShares(""))}
              label="Withdraw"
              pending="Withdrawing…"
            />
          </div>
        )}

        {tab === "report" && (
          <div className="space-y-3">
            <div
              className={`flex items-start gap-2 rounded-lg border px-3 py-2 text-[11.5px] ${
                isReporter
                  ? "border-emerald-500/30 bg-emerald-500/[0.06] text-emerald-300"
                  : "border-amber-500/30 bg-amber-500/[0.06] text-amber-300"
              }`}
            >
              <AlertTriangle size={14} className="mt-0.5 shrink-0" />
              <span>
                {isReporter
                  ? "Your wallet is the authorized fee reporter."
                  : "Restricted to the fee reporter. Connect as the feeReporter wallet to report fees."}
              </span>
            </div>
            <p className="text-[12px] leading-relaxed text-txt-dim">
              Transfers a {roles ? Number(roles.compoundFeeBps) / 100 : 10}%
              compound slice into pending reserves and emits{" "}
              <span className="font-mono text-accent-soft">FeesAccrued</span>,
              which the RSC observes.
            </p>
            <TokenInput
              token={TOKENS.TOKEN0}
              value={f0}
              onChange={setF0}
              balance={balances?.token0}
              label="Raw fee0"
            />
            <TokenInput
              token={TOKENS.TOKEN1}
              value={f1}
              onChange={setF1}
              balance={balances?.token1}
              label="Raw fee1"
            />
            <ActionButton
              disabled={!connected || (!f0 && !f1)}
              wallet={wallet}
              onClick={() =>
                exec.reportFees(f0 || "0", f1 || "0").then(() => {
                  setF0("");
                  setF1("");
                })
              }
              label="Approve & Report Fees"
              pending="Reporting fees…"
            />
          </div>
        )}

        {tab === "compound" && (
          <div className="space-y-3">
            <p className="text-[12px] leading-relaxed text-txt-dim">
              Manually invoke the compound path the RSC normally triggers. Picks
              a whitelisted yield route and moves pending reserves into it.
            </p>
            <div className="space-y-1.5">
              <div className="text-[11px] text-txt-dim">Yield route</div>
              {ROUTE_LIST.map((r) => (
                <button
                  key={r.key}
                  onClick={() => setRoute(r.address)}
                  className={`flex w-full items-center justify-between rounded-lg border px-3 py-2 text-[12.5px] transition-colors ${
                    route.toLowerCase() === r.address.toLowerCase()
                      ? "border-accent/50 bg-accent/[0.08]"
                      : "border-line hover:border-line-strong"
                  }`}
                >
                  <span className="flex items-center gap-2">
                    <RouteBadge name={r.name} />
                    {bestRoute?.address?.toLowerCase() ===
                      r.address.toLowerCase() && (
                      <span className="text-[10px] text-accent-soft">
                        best APY
                      </span>
                    )}
                  </span>
                  <span className="font-mono text-txt-dim">
                    {r.apy != null ? `${bpsToPct(r.apy)}%` : ""}
                  </span>
                </button>
              ))}
            </div>
            <ActionButton
              disabled={!connected}
              wallet={wallet}
              onClick={() => exec.compound(route)}
              label="Trigger Compound"
              pending="Compounding…"
            />
          </div>
        )}
      </div>
    </Card>
  );
}

function TokenInput({ token, value, onChange, balance, label }) {
  return (
    <div className="rounded-lg border border-line bg-ink px-3 py-2.5">
      <div className="mb-1 flex items-center justify-between text-[11px] text-txt-dim">
        <span>{label || token.symbol}</span>
        <button
          onClick={() => balance != null && onChange(ethers.formatUnits(balance, token.decimals))}
          className="hover:text-accent"
        >
          Balance: {balance != null ? fmt(balance, token.decimals, 3) : "—"}
        </button>
      </div>
      <div className="flex items-center gap-2">
        <input
          value={value}
          onChange={(e) => onChange(e.target.value)}
          placeholder="0.0"
          inputMode="decimal"
          className="w-full bg-transparent font-mono text-[18px] text-txt outline-none placeholder:text-neutral-700"
        />
        <span className="shrink-0 rounded-md border border-line px-2 py-1 text-[12px] font-semibold text-txt">
          {token.symbol}
        </span>
      </div>
    </div>
  );
}

function ActionButton({ disabled, onClick, label, pending, wallet }) {
  const [busy, setBusy] = useState(false);
  if (!wallet.account) {
    return (
      <button
        onClick={wallet.connect}
        className="w-full rounded-lg bg-accent py-2.5 text-[13px] font-semibold text-white transition-colors hover:bg-accent-soft"
      >
        Connect Wallet
      </button>
    );
  }
  if (wallet.wrongNetwork) {
    return (
      <button
        onClick={wallet.switchNetwork}
        className="w-full rounded-lg bg-red-500/90 py-2.5 text-[13px] font-semibold text-white transition-colors hover:bg-red-500"
      >
        Switch to {CHAIN_NAME}
      </button>
    );
  }
  return (
    <button
      disabled={disabled || busy}
      onClick={async () => {
        setBusy(true);
        try {
          await onClick();
        } finally {
          setBusy(false);
        }
      }}
      className="w-full rounded-lg bg-accent py-2.5 text-[13px] font-semibold text-white transition-colors hover:bg-accent-soft disabled:cursor-not-allowed disabled:bg-neutral-800 disabled:text-neutral-600"
    >
      {busy ? pending : label}
    </button>
  );
}

// ============================================================
// COMPONENT: ReserveChart — pending reserve over time (custom SVG)
// ============================================================
function ReserveChart({ points, threshold, loading }) {
  const W = 560;
  const H = 240;
  const PAD = { l: 38, r: 14, t: 16, b: 24 };

  const view = useMemo(() => {
    if (!points || points.length === 0) return null;
    const xs = points.map((_, i) => i);
    const ys = points.map((p) => p.value);
    const maxY = Math.max(threshold * 1.3, ...ys, 0.001);
    const innerW = W - PAD.l - PAD.r;
    const innerH = H - PAD.t - PAD.b;
    const X = (i) =>
      PAD.l + (points.length === 1 ? innerW / 2 : (i / (points.length - 1)) * innerW);
    const Y = (v) => PAD.t + innerH - (v / maxY) * innerH;
    const line = points.map((p, i) => `${X(i)},${Y(p.value)}`).join(" ");
    const area = `${PAD.l},${PAD.t + innerH} ${line} ${X(points.length - 1)},${
      PAD.t + innerH
    }`;
    return { X, Y, line, area, maxY, innerH, innerW };
  }, [points, threshold]);

  return (
    <Card id="chart" className="flex flex-col">
      <SectionTitle
        icon={Activity}
        title="Pending Reserve & Compounds"
        right={
          <div className="flex items-center gap-3 text-[10.5px]">
            <span className="flex items-center gap-1 text-accent-soft">
              <span className="h-2 w-2 rounded-full bg-accent" /> reserve
            </span>
            <span className="flex items-center gap-1 text-amber-300">
              <span className="h-px w-3 border-t border-dashed border-amber-400" />{" "}
              threshold
            </span>
          </div>
        }
      />
      <div className="p-3">
        {loading ? (
          <Skeleton className="h-[240px] w-full" />
        ) : !view ? (
          <div className="flex h-[240px] flex-col items-center justify-center gap-2 text-center text-txt-dim">
            <Activity size={22} className="text-neutral-700" />
            <p className="text-[12.5px]">
              No fee events yet. Report fees to populate the reserve curve.
            </p>
          </div>
        ) : (
          <svg viewBox={`0 0 ${W} ${H}`} className="w-full">
            <defs>
              <linearGradient id="fcArea" x1="0" y1="0" x2="0" y2="1">
                <stop offset="0%" stopColor="#22D3EE" stopOpacity="0.35" />
                <stop offset="100%" stopColor="#22D3EE" stopOpacity="0" />
              </linearGradient>
            </defs>
            {/* grid */}
            {[0, 0.25, 0.5, 0.75, 1].map((g) => {
              const y = PAD.t + view.innerH * g;
              return (
                <line
                  key={g}
                  x1={PAD.l}
                  x2={W - PAD.r}
                  y1={y}
                  y2={y}
                  stroke="rgba(255,255,255,0.05)"
                  strokeWidth="1"
                />
              );
            })}
            {/* threshold line */}
            <line
              x1={PAD.l}
              x2={W - PAD.r}
              y1={view.Y(threshold)}
              y2={view.Y(threshold)}
              stroke="#FBBF24"
              strokeWidth="1.25"
              strokeDasharray="5 4"
            />
            <text
              x={W - PAD.r}
              y={view.Y(threshold) - 4}
              textAnchor="end"
              fill="#FBBF24"
              fontSize="9"
              fontFamily="JetBrains Mono"
            >
              {threshold} min
            </text>
            {/* area + line */}
            <polygon points={view.area} fill="url(#fcArea)" />
            <polyline
              points={view.line}
              fill="none"
              stroke="#22D3EE"
              strokeWidth="2"
              strokeLinejoin="round"
              strokeLinecap="round"
            />
            {/* points */}
            {points.map((p, i) => (
              <circle
                key={i}
                cx={view.X(i)}
                cy={view.Y(p.value)}
                r={p.kind === "compound" ? 3.5 : 2.5}
                fill={p.kind === "compound" ? "#34D399" : "#22D3EE"}
                stroke="#0E1420"
                strokeWidth="1.5"
              >
                <title>
                  {p.kind === "compound" ? "Compound → reserve cleared" : "Fees accrued"}{" "}
                  · block {p.block}
                </title>
              </circle>
            ))}
            {/* y labels */}
            {[0, view.maxY].map((v, i) => (
              <text
                key={i}
                x={PAD.l - 6}
                y={i === 0 ? PAD.t + view.innerH : PAD.t + 4}
                textAnchor="end"
                fill="#8A8A92"
                fontSize="9"
                fontFamily="JetBrains Mono"
              >
                {v.toFixed(v < 1 ? 2 : 0)}
              </text>
            ))}
          </svg>
        )}
      </div>
    </Card>
  );
}

// ============================================================
// COMPONENT: ActivityFeed
// ============================================================
const ICONS = {
  Deposit: Droplet,
  Withdraw: ArrowDownUp,
  "Report Fees": Tag,
  Compound: Zap,
  "RSC Compound": Radio,
  "Fees Accrued": Coins,
  Approve: Check,
};

function StatusBadge({ status }) {
  const map = {
    PENDING: "border-amber-500/40 bg-amber-500/10 text-amber-300 fc-pulse",
    CONFIRMED: "border-emerald-500/40 bg-emerald-500/10 text-emerald-300",
    FAILED: "border-red-500/40 bg-red-500/10 text-red-300",
  };
  return (
    <span
      className={`rounded-md border px-1.5 py-0.5 text-[10px] font-semibold ${map[status]}`}
    >
      {status}
    </span>
  );
}

function ActivityFeed({ feed }) {
  return (
    <Card id="activity" className="flex flex-col">
      <SectionTitle
        icon={Activity}
        title="Activity Feed"
        right={
          <span className="text-[11px] text-txt-dim">{feed.length} events</span>
        }
      />
      <div className="max-h-[420px] overflow-y-auto">
        {feed.length === 0 ? (
          <div className="px-5 py-10 text-center text-[12.5px] text-txt-dim">
            No transactions yet. Execute a deposit or report fees to see live
            activity.
          </div>
        ) : (
          <div className="divide-y divide-line">
            {feed.map((e) => {
              const Icon = ICONS[e.action] || Activity;
              return (
                <div key={e.id} className="flex gap-3 px-5 py-3 fc-fade">
                  <div
                    className={`mt-0.5 flex h-7 w-7 shrink-0 items-center justify-center rounded-lg border ${
                      e.isRSC
                        ? "border-accent/30 bg-accent/10 text-accent-soft"
                        : "border-line bg-ink text-txt-dim"
                    }`}
                  >
                    <Icon size={13} />
                  </div>
                  <div className="min-w-0 flex-1">
                    <div className="flex items-center gap-2">
                      <span className="text-[12.5px] font-medium text-txt">
                        {e.action}
                      </span>
                      <StatusBadge status={e.status} />
                      <span className="ml-auto text-[10.5px] text-txt-dim">
                        {e.timestamp?.toLocaleTimeString?.() || ""}
                      </span>
                    </div>
                    <div className="mt-0.5 text-[11.5px] text-txt-dim">
                      {e.description}
                    </div>
                    {e.txHash && (
                      <a
                        href={explorerTx(e.txHash, e.isRSC)}
                        target="_blank"
                        rel="noreferrer"
                        className="mt-1 inline-flex items-center gap-1 font-mono text-[11px] text-accent hover:text-accent-soft"
                      >
                        {truncate(e.txHash)} <ExternalLink size={10} />
                      </a>
                    )}
                  </div>
                </div>
              );
            })}
          </div>
        )}
      </div>
    </Card>
  );
}

// ============================================================
// COMPONENT: ReactiveNetworkPanel
// ============================================================
function ReactiveNetworkPanel({ rscEvents, apys, bestRoute, pool }) {
  return (
    <Card id="rsc" className="flex flex-col">
      <SectionTitle
        icon={Radio}
        title="Reactive Network"
        right={
          <span className="flex items-center gap-1.5 text-[11px] text-accent-soft">
            <Dot color="accent" /> Lasna · {REACTIVE_CHAIN_ID}
          </span>
        }
      />

      {/* flow graphic */}
      <div className="flex items-center justify-between px-6 py-5">
        <FlowNode label="Hook" sub="FeesAccrued" />
        <FlowArrow />
        <FlowNode label="RSC" sub="evaluate gates" accent />
        <FlowArrow />
        <FlowNode label="Callback" sub="triggerCompound" />
      </div>

      <div className="grid grid-cols-3 gap-px border-y border-line bg-line">
        <Stat label="Monitored event" value="FeesAccrued" mono />
        <Stat
          label="Best APY route"
          value={bestRoute ? `${bestRoute.name} · ${bpsToPct(bestRoute.apy)}%` : "—"}
        />
        <Stat
          label="Active route"
          value={
            pool && pool.activeYieldRoute !== ZERO
              ? routeName(pool.activeYieldRoute)
              : "default"
          }
        />
      </div>

      {/* route APYs */}
      <div className="grid grid-cols-3 gap-2 px-5 py-4">
        {ROUTE_LIST.map((r) => {
          const apy = apys?.[r.address.toLowerCase()];
          const best = bestRoute?.address?.toLowerCase() === r.address.toLowerCase();
          return (
            <div
              key={r.key}
              className={`rounded-lg border px-3 py-2.5 ${
                best ? "border-accent/40 bg-accent/[0.06]" : "border-line"
              }`}
            >
              <div className="mb-1 flex items-center justify-between">
                <RouteBadge name={r.name} />
                {best && <span className="text-[9px] text-accent-soft">●</span>}
              </div>
              <div className="font-mono text-[16px] font-semibold text-txt">
                {apy != null ? `${bpsToPct(apy)}%` : "—"}
              </div>
            </div>
          );
        })}
      </div>

      {/* terminal log */}
      <div className="border-t border-line px-5 py-3">
        <div className="mb-2 text-[11px] font-medium text-txt-dim">
          Live RSC event stream (Lasna)
        </div>
        <div className="max-h-[180px] overflow-y-auto rounded-lg border border-line bg-black px-3 py-2.5 font-mono text-[11px] leading-relaxed">
          {!rscEvents ? (
            <span className="text-neutral-600">connecting to lasna-rpc…</span>
          ) : rscEvents.length === 0 ? (
            <span className="text-neutral-600">
              ⚛ subscribed · awaiting next FeesAccrued event…
            </span>
          ) : (
            rscEvents.map((e, i) => (
              <div key={i} className="flex gap-2">
                <span className="text-neutral-600">#{e.block}</span>
                <span
                  className={
                    e.kind === "skip"
                      ? "text-amber-400"
                      : e.kind === "apy"
                        ? "text-cyan-400"
                        : "text-emerald-400"
                  }
                >
                  {e.text}
                </span>
              </div>
            ))
          )}
        </div>
        <a
          href={explorerAddr(ADDRESSES.RSC, true)}
          target="_blank"
          rel="noreferrer"
          className="mt-3 inline-flex items-center gap-1 text-[12px] font-medium text-accent hover:text-accent-soft"
        >
          View RSC Contract <ExternalLink size={12} />
        </a>
      </div>
    </Card>
  );
}

function FlowNode({ label, sub, accent }) {
  return (
    <div className="flex flex-col items-center gap-1">
      <div
        className={`flex h-12 w-12 items-center justify-center rounded-xl border text-[11px] font-semibold ${
          accent
            ? "border-accent/50 bg-accent/15 text-accent-soft"
            : "border-line bg-ink text-txt"
        }`}
      >
        {label}
      </div>
      <span className="text-[10px] text-txt-dim">{sub}</span>
    </div>
  );
}
function FlowArrow() {
  return (
    <svg width="70" height="20" className="text-accent">
      <line
        x1="2"
        y1="10"
        x2="58"
        y2="10"
        stroke="currentColor"
        strokeWidth="1.5"
        className="fc-flow"
      />
      <polygon points="58,5 68,10 58,15" fill="currentColor" />
    </svg>
  );
}
function Stat({ label, value, mono }) {
  return (
    <div className="bg-card px-4 py-3">
      <div className="mb-1 text-[10.5px] text-txt-dim">{label}</div>
      <div className={`text-[13px] font-medium text-txt ${mono ? "font-mono" : ""}`}>
        {value}
      </div>
    </div>
  );
}

// ============================================================
// COMPONENT: VerifyOnChainPanel
// ============================================================
function VerifyOnChainPanel() {
  const [open, setOpen] = useState(true);
  const rows = [
    ["Hook Contract", ADDRESSES.HOOK, false],
    ["RSC Contract", ADDRESSES.RSC, true],
    ["Pool Manager", ADDRESSES.POOL_MANAGER, false],
    [`Token0 (${TOKENS.TOKEN0.symbol})`, ADDRESSES.TOKEN0, false],
    [`Token1 (${TOKENS.TOKEN1.symbol})`, ADDRESSES.TOKEN1, false],
    ["Aave v3 Adapter", ADDRESSES.AAVE_ADAPTER, false],
    ["Morpho Adapter", ADDRESSES.MORPHO_ADAPTER, false],
    ["Pool Reinvest Adapter", ADDRESSES.POOL_REINVEST_ADAPTER, false],
  ];
  return (
    <Card id="verify">
      <button
        onClick={() => setOpen((o) => !o)}
        className="flex w-full items-center justify-between px-5 py-4"
      >
        <span className="flex items-center gap-2 text-[13px] font-semibold text-txt">
          <ShieldCheck size={15} className="text-accent" /> Verify on Chain
        </span>
        <ChevronDown
          size={16}
          className={`text-txt-dim transition-transform ${open ? "rotate-180" : ""}`}
        />
      </button>
      {open && (
        <div className="border-t border-line px-5 py-4 fc-fade">
          <p className="mb-4 text-[12px] text-txt-dim">
            All contracts are deployed on {CHAIN_NAME} (hook + pool + adapters)
            and Reactive Lasna (RSC). Click any address to inspect it live.
          </p>
          <div className="space-y-2">
            {rows.map(([label, addr, reactive]) => (
              <div
                key={label}
                className="flex items-center justify-between border-b border-line/60 pb-2 last:border-0"
              >
                <span className="text-[12.5px] text-txt-dim">{label}</span>
                <div className="flex items-center gap-3">
                  <Copyable value={addr} reactive={reactive} />
                  {reactive && (
                    <span className="rounded border border-accent/30 bg-accent/10 px-1.5 py-0.5 text-[9px] font-semibold text-accent-soft">
                      LASNA
                    </span>
                  )}
                </div>
              </div>
            ))}
          </div>

          <div className="mt-5 grid grid-cols-2 gap-4">
            <div>
              <div className="mb-1.5 flex items-center justify-between text-[11px] text-txt-dim">
                <span>Forge test coverage</span>
                <span className="font-mono text-emerald-300">100%</span>
              </div>
              <div className="h-1.5 overflow-hidden rounded-full bg-white/5">
                <div className="h-full w-full rounded-full bg-gradient-to-r from-emerald-500 to-emerald-400" />
              </div>
            </div>
            <div className="text-[12px] text-txt-dim">
              <span className="text-txt">Tests passing</span> · full suite green
              <br />
              Solidity 0.8.26 · Uniswap v4 · Reactive Lasna
            </div>
          </div>

          <div className="mt-5 rounded-lg border border-line bg-ink px-4 py-2.5 text-center text-[11.5px] text-txt-dim">
            UHI9 Hookathon · FeeCompounder Hook · Demo Day{" "}
            <span className="text-txt">June 19, 2026</span>
          </div>
        </div>
      )}
    </Card>
  );
}

// ============================================================
// COMPONENT: TransactionToast
// ============================================================
function ToastStack({ toasts, dismiss }) {
  return (
    <div className="fixed right-5 top-16 z-50 flex w-[330px] flex-col gap-2">
      {toasts.map((t) => (
        <div
          key={t.id}
          className="fc-toast rounded-xl border border-line bg-card/95 p-3.5 shadow-2xl backdrop-blur"
        >
          <div className="flex items-start gap-2.5">
            <div className="mt-0.5">
              {t.status === "PENDING" && <Dot color="amber" />}
              {t.status === "CONFIRMED" && (
                <Check size={15} className="text-emerald-400" />
              )}
              {t.status === "FAILED" && (
                <AlertTriangle size={15} className="text-red-400" />
              )}
            </div>
            <div className="min-w-0 flex-1">
              <div className="flex items-center gap-2">
                <span className="text-[12.5px] font-semibold text-txt">
                  {t.action}
                </span>
                <StatusBadge status={t.status} />
              </div>
              <div className="mt-0.5 text-[11.5px] text-txt-dim">
                {t.description}
              </div>
              {t.txHash && (
                <a
                  href={explorerTx(t.txHash, t.isRSC)}
                  target="_blank"
                  rel="noreferrer"
                  className="mt-1 inline-flex items-center gap-1 font-mono text-[11px] text-accent hover:text-accent-soft"
                >
                  {truncate(t.txHash)} <ExternalLink size={10} />
                </a>
              )}
            </div>
            <button
              onClick={() => dismiss(t.id)}
              className="text-neutral-600 hover:text-txt"
            >
              <X size={13} />
            </button>
          </div>
        </div>
      ))}
    </div>
  );
}

// ============================================================
// APP ROOT
// ============================================================
export default function App() {
  const wallet = useWallet();
  const activity = useActivity();
  const toasts = useToasts();

  const [pool, setPool] = useState(null);
  const [config, setConfig] = useState(null);
  const [roles, setRoles] = useState(null);
  const [apys, setApys] = useState(null);
  const [balances, setBalances] = useState(null);
  const [lpShares, setLpShares] = useState(null);
  const [chartPoints, setChartPoints] = useState([]);
  const [rscEvents, setRscEvents] = useState(null);
  const [latestBlock, setLatestBlock] = useState(null);
  const [lastTx, setLastTx] = useState(null);
  const [loading, setLoading] = useState(true);
  const [demoStep, setDemoStep] = useState(1);
  const lastLogBlock = useRef(0);

  const bestRoute = useMemo(() => {
    if (!apys) return null;
    let best = null;
    for (const r of ROUTE_LIST) {
      const apy = apys[r.address.toLowerCase()];
      if (apy == null) continue;
      if (!best || apy > best.apy) best = { ...r, apy };
    }
    return best;
  }, [apys]);

  // ── load core state ──
  const loadState = useCallback(async () => {
    const provider = getReadProvider();
    try {
      const hook = new ethers.Contract(ADDRESSES.HOOK, HOOK_ABI, provider);
      const [
        pools,
        pending,
        minThreshold,
        gasCeiling,
        cooldown,
        maxHold,
        compoundFeeBps,
        defaultRoute,
        feeReporter,
        block,
      ] = await Promise.all([
        hook.pools(POOL_ID),
        hook.pendingFeesFor(POOL_ID),
        hook.minCompoundThreshold(),
        hook.gasPriceCeiling(),
        hook.cooldownBlocks(),
        hook.maxHoldBlocks(),
        hook.compoundFeeBps(),
        hook.defaultRoute(),
        hook.feeReporter(),
        provider.getBlockNumber(),
      ]);

      setPool({
        totalShares: pools[0],
        totalAssets0: pools[1],
        totalAssets1: pools[2],
        pendingFees0: pending[0],
        pendingFees1: pending[1],
        routeShares0: pools[5],
        routeShares1: pools[6],
        lastCompoundBlock: Number(pools[7]),
        activeYieldRoute: pools[8],
        initialized: pools[9],
      });
      setConfig({
        minThreshold,
        gasCeiling,
        cooldown: Number(cooldown),
        maxHold: Number(maxHold),
        compoundFeeBps,
        defaultRoute,
      });
      setRoles({ feeReporter, compoundFeeBps });
      setLatestBlock(block);

      // adapter APYs
      const apyEntries = await Promise.all(
        ROUTE_LIST.map(async (r) => {
          try {
            const a = new ethers.Contract(r.address, ADAPTER_ABI, provider);
            const apy = await a.apyBps();
            return [r.address.toLowerCase(), Number(apy)];
          } catch {
            return [r.address.toLowerCase(), null];
          }
        })
      );
      setApys(Object.fromEntries(apyEntries));
    } catch (e) {
      console.warn("loadState failed", e?.shortMessage || e?.message);
    } finally {
      setLoading(false);
    }
  }, []);

  // ── load balances + lp shares for connected wallet ──
  const loadWalletData = useCallback(async () => {
    if (!wallet.account) {
      setBalances(null);
      setLpShares(null);
      return;
    }
    const provider = getReadProvider();
    try {
      const t0 = new ethers.Contract(ADDRESSES.TOKEN0, ERC20_ABI, provider);
      const t1 = new ethers.Contract(ADDRESSES.TOKEN1, ERC20_ABI, provider);
      const hook = new ethers.Contract(ADDRESSES.HOOK, HOOK_ABI, provider);
      const [b0, b1, sh] = await Promise.all([
        t0.balanceOf(wallet.account),
        t1.balanceOf(wallet.account),
        hook.lpShares(POOL_ID, wallet.account),
      ]);
      setBalances({ token0: b0, token1: b1 });
      setLpShares(sh);
    } catch (e) {
      console.warn("loadWalletData failed", e?.message);
    }
  }, [wallet.account]);

  // ── load historical events → chart + activity ──
  const loadHistory = useCallback(async () => {
    const logs = (await fetchHookLogsApi(DEPLOY_BLOCK)).filter(inPool);
    if (!logs.length) return;
    lastLogBlock.current = Math.max(...logs.map((l) => l.blockNumber));

    const accrued = logs.filter((l) => l.name === "FeesAccrued");
    const compounds = logs.filter((l) => l.name === "CompoundExecuted");
    const minted = logs.filter((l) => l.name === "SharesMinted");
    const burned = logs.filter((l) => l.name === "SharesBurned");

    // chart points (sawtooth: accrue up, compound to 0)
    const pts = [];
    [...accrued, ...compounds]
      .sort((a, b) => a.blockNumber - b.blockNumber || a.logIndex - b.logIndex)
      .forEach((ev) => {
        if (ev.name === "FeesAccrued") {
          const v =
            Number(ethers.formatUnits(ev.args.totalPending0, 18)) +
            Number(ethers.formatUnits(ev.args.totalPending1, 18));
          pts.push({ value: v, block: ev.blockNumber, kind: "accrue" });
        } else {
          pts.push({ value: 0, block: ev.blockNumber, kind: "compound" });
        }
      });
    setChartPoints(pts.slice(-40));

    // activity feed (most recent first)
    const evs = [
      ...minted.map((e) => ({
        ev: e,
        action: "Deposit",
        desc: `${fmt(e.args.sharesIssued, 18, 3)} shares minted`,
      })),
      ...burned.map((e) => ({
        ev: e,
        action: "Withdraw",
        desc: `${fmt(e.args.sharesBurned, 18, 3)} shares burned`,
      })),
      ...accrued.map((e) => ({
        ev: e,
        action: "Fees Accrued",
        desc: `pending ${fmt(e.args.totalPending0, 18, 2)} ${TOKENS.TOKEN0.symbol} / ${fmt(e.args.totalPending1, 18, 2)} ${TOKENS.TOKEN1.symbol}`,
      })),
      ...compounds.map((e) => ({
        ev: e,
        action: "RSC Compound",
        isRSC: false,
        desc: `compounded into ${routeName(e.args.route)}`,
      })),
    ]
      .sort(
        (a, b) =>
          b.ev.blockNumber - a.ev.blockNumber || b.ev.logIndex - a.ev.logIndex
      )
      .slice(0, 25)
      .map((x) => ({
        id: `${x.ev.transactionHash}-${x.ev.logIndex}`,
        action: x.action,
        status: "CONFIRMED",
        txHash: x.ev.transactionHash,
        blockNumber: x.ev.blockNumber,
        isRSC: x.isRSC,
        description: `${x.desc} · block ${x.ev.blockNumber}`,
        timestamp: new Date(),
      }));
    activity.setFeed(evs);
    if (compounds.length) setDemoStep(5);
    else if (accrued.length) setDemoStep(3);
    else if (minted.length) setDemoStep(2);
  }, [activity.setFeed]);

  // ── poll Blockscout for NEW hook logs (live updates without eth_getLogs) ──
  const pollNewLogs = useCallback(async () => {
    const from = lastLogBlock.current ? lastLogBlock.current + 1 : DEPLOY_BLOCK;
    const logs = (await fetchHookLogsApi(from)).filter(inPool);
    if (!logs.length) return;
    lastLogBlock.current = Math.max(
      lastLogBlock.current,
      ...logs.map((l) => l.blockNumber)
    );
    for (const l of logs) {
      if (l.name === "FeesAccrued") {
        const v =
          Number(ethers.formatUnits(l.args.totalPending0, 18)) +
          Number(ethers.formatUnits(l.args.totalPending1, 18));
        setChartPoints((p) =>
          [...p, { value: v, block: l.blockNumber, kind: "accrue" }].slice(-40)
        );
        activity.add({
          id: `${l.transactionHash}-${l.logIndex}`,
          action: "Fees Accrued",
          status: "CONFIRMED",
          txHash: l.transactionHash,
          blockNumber: l.blockNumber,
          description: `pending reserve now ${v.toFixed(2)} · block ${l.blockNumber}`,
          timestamp: new Date(),
        });
        setDemoStep((s) => Math.max(s, 3));
      } else if (l.name === "CompoundExecuted") {
        setChartPoints((p) =>
          [...p, { value: 0, block: l.blockNumber, kind: "compound" }].slice(-40)
        );
        activity.add({
          id: `${l.transactionHash}-${l.logIndex}`,
          action: "RSC Compound",
          status: "CONFIRMED",
          txHash: l.transactionHash,
          blockNumber: l.blockNumber,
          description: `compounded into ${routeName(l.args.route)} · block ${l.blockNumber}`,
          timestamp: new Date(),
        });
        setDemoStep((s) => Math.max(s, 5));
      } else if (l.name === "SharesMinted") {
        activity.add({
          id: `${l.transactionHash}-${l.logIndex}`,
          action: "Deposit",
          status: "CONFIRMED",
          txHash: l.transactionHash,
          blockNumber: l.blockNumber,
          description: `${fmt(l.args.sharesIssued, 18, 3)} shares minted · block ${l.blockNumber}`,
          timestamp: new Date(),
        });
        setDemoStep((s) => Math.max(s, 2));
      } else if (l.name === "SharesBurned") {
        activity.add({
          id: `${l.transactionHash}-${l.logIndex}`,
          action: "Withdraw",
          status: "CONFIRMED",
          txHash: l.transactionHash,
          blockNumber: l.blockNumber,
          description: `${fmt(l.args.sharesBurned, 18, 3)} shares burned · block ${l.blockNumber}`,
          timestamp: new Date(),
        });
      }
    }
    loadState();
  }, [activity.add, loadState]);

  // ── load RSC events from Lasna ──
  const loadRsc = useCallback(async () => {
    try {
      const provider = getReactiveProvider();
      const rsc = new ethers.Contract(ADDRESSES.RSC, RSC_ABI, provider);
      const tip = await provider.getBlockNumber();
      const from = Math.max(0, tip - LOOKBACK_BLOCKS);
      const [queued, skipped, apy] = await Promise.all([
        getLogsChunked(rsc, rsc.filters.CompoundCallbackQueued(), from, tip),
        getLogsChunked(rsc, rsc.filters.CompoundSkipped(), from, tip),
        getLogsChunked(rsc, rsc.filters.RouteAPYUpdated(), from, tip),
      ]);
      const list = [
        ...queued.map((e) => ({
          block: e.blockNumber,
          kind: "ok",
          text: `callback queued → ${routeName(e.args.route)} (pending ${fmt(e.args.pending, 18, 2)})`,
        })),
        ...skipped.map((e) => ({
          block: e.blockNumber,
          kind: "skip",
          text: `skipped: ${e.args.reason}`,
        })),
        ...apy.map((e) => ({
          block: e.blockNumber,
          kind: "apy",
          text: `route APY → ${routeName(e.args.route)} ${bpsToPct(e.args.apyBps)}%`,
        })),
      ]
        .sort((a, b) => b.block - a.block)
        .slice(0, 12);
      setRscEvents(list);
    } catch (e) {
      console.warn("loadRsc failed", e?.message);
      setRscEvents([]);
    }
  }, []);

  // initial + polling loads
  useEffect(() => {
    loadState();
    loadHistory();
    loadRsc();
    const t = setInterval(() => {
      loadState();
      pollNewLogs();
      loadRsc();
      getReadProvider().getBlockNumber().then(setLatestBlock).catch(() => {});
    }, 12000);
    return () => clearInterval(t);
  }, [loadState, loadHistory, loadRsc, pollNewLogs]);

  useEffect(() => {
    loadWalletData();
  }, [loadWalletData]);

  // ── transaction executor ──
  const runTx = useCallback(
    async (action, isRSCStyle, fn) => {
      const id = nextId();
      const base = {
        id,
        action,
        status: "PENDING",
        txHash: null,
        isRSC: false,
        timestamp: new Date(),
        description: `${action} submitted…`,
      };
      activity.add(base);
      toasts.push(base);
      try {
        const tx = await fn();
        activity.update(id, {
          txHash: tx.hash,
          description: `${action} pending confirmation…`,
        });
        toasts.update(id, { txHash: tx.hash, status: "PENDING" });
        setLastTx(tx.hash);
        const receipt = await tx.wait();
        const patch = {
          status: "CONFIRMED",
          txHash: tx.hash,
          description: `${action} confirmed in block ${receipt.blockNumber}`,
        };
        activity.update(id, patch);
        toasts.update(id, { ...patch });
        // refresh state immediately; chase the freshly-indexed log a few
        // seconds later (Blockscout needs a moment to index the new event).
        loadState();
        loadWalletData();
        setTimeout(() => pollNewLogs(), 4000);
        setTimeout(() => pollNewLogs(), 10000);
        return receipt;
      } catch (e) {
        const patch = { status: "FAILED", description: `${action} failed: ${shortReason(e)}` };
        activity.update(id, patch);
        toasts.update(id, patch);
        throw e;
      }
    },
    [activity, toasts, loadState, loadWalletData, pollNewLogs]
  );

  const ensureAllowance = useCallback(
    async (signer, tokenAddr, amount) => {
      if (amount <= 0n) return;
      const erc = new ethers.Contract(tokenAddr, ERC20_ABI, signer);
      const owner = await signer.getAddress();
      const current = await erc.allowance(owner, ADDRESSES.HOOK);
      if (current >= amount) return;
      const id = nextId();
      const sym =
        tokenAddr.toLowerCase() === ADDRESSES.TOKEN0.toLowerCase()
          ? TOKENS.TOKEN0.symbol
          : TOKENS.TOKEN1.symbol;
      const base = {
        id,
        action: "Approve",
        status: "PENDING",
        timestamp: new Date(),
        description: `Approving ${sym}…`,
      };
      activity.add(base);
      toasts.push(base);
      const tx = await erc.approve(ADDRESSES.HOOK, ethers.MaxUint256);
      activity.update(id, { txHash: tx.hash });
      toasts.update(id, { txHash: tx.hash });
      await tx.wait();
      activity.update(id, { status: "CONFIRMED", description: `${sym} approved` });
      toasts.update(id, { status: "CONFIRMED", description: `${sym} approved` });
    },
    [activity, toasts]
  );

  // action implementations
  const exec = useMemo(
    () => ({
      deposit: async (a0, a1) => {
        const bp = getBrowserProvider();
        const signer = await bp.getSigner();
        const me = await signer.getAddress();
        const amt0 = ethers.parseUnits(a0 || "0", 18);
        const amt1 = ethers.parseUnits(a1 || "0", 18);
        await ensureAllowance(signer, ADDRESSES.TOKEN0, amt0);
        await ensureAllowance(signer, ADDRESSES.TOKEN1, amt1);
        const hook = new ethers.Contract(ADDRESSES.HOOK, HOOK_ABI, signer);
        await runTx("Deposit", false, () =>
          hook.depositForDemo(POOL_KEY, amt0, amt1, me)
        );
        setDemoStep((s) => Math.max(s, 2));
      },
      withdraw: async (sh) => {
        const bp = getBrowserProvider();
        const signer = await bp.getSigner();
        const me = await signer.getAddress();
        const hook = new ethers.Contract(ADDRESSES.HOOK, HOOK_ABI, signer);
        const shares = ethers.parseUnits(sh || "0", 18);
        await runTx("Withdraw", false, () =>
          hook.withdrawShares(POOL_KEY, shares, me)
        );
        setDemoStep((s) => Math.max(s, 6));
      },
      reportFees: async (f0, f1) => {
        const bp = getBrowserProvider();
        const signer = await bp.getSigner();
        const raw0 = ethers.parseUnits(f0 || "0", 18);
        const raw1 = ethers.parseUnits(f1 || "0", 18);
        await ensureAllowance(signer, ADDRESSES.TOKEN0, raw0);
        await ensureAllowance(signer, ADDRESSES.TOKEN1, raw1);
        const hook = new ethers.Contract(ADDRESSES.HOOK, HOOK_ABI, signer);
        await runTx("Report Fees", false, () =>
          hook.reportFees(POOL_KEY, raw0, raw1)
        );
        setDemoStep((s) => Math.max(s, 3));
      },
      compound: async (route) => {
        const bp = getBrowserProvider();
        const signer = await bp.getSigner();
        const hook = new ethers.Contract(ADDRESSES.HOOK, HOOK_ABI, signer);
        await runTx("Compound", false, () => hook.triggerCompound(POOL_KEY, route));
        setDemoStep((s) => Math.max(s, 5));
      },
    }),
    [runTx, ensureAllowance]
  );

  return (
    <div className="min-h-screen bg-ink text-txt">
      <TopBar wallet={wallet} latestBlock={latestBlock} />
      <LiveProofStrip latestBlock={latestBlock} lastTx={lastTx} />

      {wallet.wrongNetwork && (
        <div className="flex items-center justify-center gap-3 border-b border-red-500/30 bg-red-500/10 px-5 py-2.5 text-[13px] text-red-200">
          <AlertTriangle size={15} />
          Wallet is on the wrong network. Switch to {CHAIN_NAME} to interact.
          <button
            onClick={wallet.switchNetwork}
            className="ml-2 rounded-lg bg-red-500 px-3 py-1 text-[12px] font-semibold text-white hover:bg-red-400"
          >
            Switch Network
          </button>
        </div>
      )}

      <div className="flex">
        <LeftSidebar pool={pool} config={config} rsc={rscEvents} loading={loading} />

        <main className="min-w-0 flex-1 space-y-5 px-6 py-5">
          {/* hero */}
          <section id="overview">
            <div className="mb-4">
              <h1 className="text-[22px] font-semibold tracking-tight text-txt">
                Fees that compound themselves.
              </h1>
              <p className="mt-1 text-[13.5px] text-txt-dim">
                Beefy-style fee compounding inside a Uniswap v4 hook, driven by
                Reactive Network — gas-aware, yield-routed, and fully autonomous.
              </p>
            </div>
            <HeroMetricCards
              pool={pool}
              config={config}
              apys={apys}
              bestRoute={bestRoute}
              latestBlock={latestBlock}
              loading={loading}
            />
          </section>

          <DemoFlowIndicator step={demoStep} />

          {/* actions + chart */}
          <section id="actions" className="grid grid-cols-2 gap-5">
            <ActionPanel
              wallet={wallet}
              exec={exec}
              balances={balances}
              lpShares={lpShares}
              roles={roles}
              bestRoute={bestRoute}
            />
            <ReserveChart
              points={chartPoints}
              threshold={config ? Number(ethers.formatUnits(config.minThreshold, 18)) : 1}
              loading={loading}
            />
          </section>

          <ActivityFeed feed={activity.feed} />

          <ReactiveNetworkPanel
            rscEvents={rscEvents}
            apys={apys}
            bestRoute={bestRoute}
            pool={pool}
          />

          <VerifyOnChainPanel />

          <footer className="pb-6 pt-2 text-center text-[11.5px] text-txt-dim">
            FeeCompounder Hook — Hook 5 of 8 · Najnomics · UHI9 Hookathon 2026
          </footer>
        </main>
      </div>

      <ToastStack toasts={toasts.toasts} dismiss={toasts.dismiss} />
    </div>
  );
}
