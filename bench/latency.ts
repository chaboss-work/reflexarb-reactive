// ReflexArb latency benchmark.
// Each loop: push pool A's price away from pool B with one swap on Base Sepolia (the "origin event"),
// then wait until ReflexArbExecutor emits ArbExecuted / ArbSkipped for that origin block.
// Recorded per loop:
//   - origin block and executor block on Base Sepolia (exact, 200 ms blocks);
//   - GapDetected.detectedAt and LoopClosed.closedAt on Reactive Lasna (1 s block timestamps);
//   - wall-clock time from the moment the swap receipt arrived until the script saw ArbExecuted.
// Usage: npx tsx latency.ts [loops=20] [shock1=300] [shock0=100]
import { readFileSync, mkdirSync, writeFileSync } from "node:fs";
import {
  createPublicClient,
  createWalletClient,
  defineChain,
  http,
  parseAbi,
  parseEther,
  parseEventLogs,
  type Address,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { baseSepolia } from "viem/chains";

const ROOT = new URL("..", import.meta.url);
const dep = JSON.parse(readFileSync(new URL("deployments/latest.json", ROOT), "utf8"));
// key file from `cast wallet new --json`: {"data":[{"address","private_key",...}]} — never printed
const keyFile = JSON.parse(readFileSync(new URL(".secrets/deployer.json", ROOT), "utf8"));
const keyEntry = Array.isArray(keyFile.data) ? keyFile.data[0] : keyFile.data;
const account = privateKeyToAccount(keyEntry.private_key as Hex);

const lasna = defineChain({
  id: 5318007,
  name: "Reactive Lasna",
  nativeCurrency: { name: "lREACT", symbol: "lREACT", decimals: 18 },
  rpcUrls: { default: { http: ["https://lasna-rpc.rnk.dev/"] } },
});
const base = createPublicClient({ chain: baseSepolia, transport: http("https://sepolia.base.org") });
const rn = createPublicClient({ chain: lasna, transport: http() });
const wallet = createWalletClient({ account, chain: baseSepolia, transport: http("https://sepolia.base.org") });

const POOL = parseAbi([
  "function swapExactIn(address tokenIn, uint256 amountIn, uint256 minOut, address to) returns (uint256)",
  "function getReserves() view returns (uint112, uint112)",
]);
const EXEC = parseAbi([
  "event ArbExecuted(uint256 indexed seq, uint256 originBlock, uint256 execBlock, uint256 execTimestamp, bool buyInB, uint256 amountIn1, uint256 profit1, uint256 gapBeforeBps, uint256 gapAfterBps)",
  "event ArbSkipped(uint256 indexed seq, uint256 originBlock, uint256 execBlock, string reason)",
  "function currentGapBps() view returns (uint256)",
]);
const RC = parseAbi([
  "event GapDetected(uint256 indexed seq, uint256 originBlock, uint256 originTxHash, uint256 gapBps, uint256 detectedAt)",
  "event LoopClosed(uint256 indexed seq, bool executed, uint256 originBlock, uint256 execBlock, uint256 closedAt)",
  "function inFlight() view returns (bool)",
  "function seq() view returns (uint256)",
  "function lastTriggerAt() view returns (uint256)",
]);

const loops = Number(process.argv[2] ?? 20);
const shock1 = parseEther(process.argv[3] ?? "300"); // token1 into pool A: pool A price of token0 goes up
const shock0 = parseEther(process.argv[4] ?? "100"); // token0 into pool A: pool A price goes down
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

// every finished loop is appended right away, so an interrupted run keeps its data
const RESULTS_DIR = new URL("bench/results/", ROOT);
mkdirSync(RESULTS_DIR, { recursive: true });
const JSONL = new URL("loops.jsonl", RESULTS_DIR);
function appendLine(row: Record<string, unknown>) {
  writeFileSync(JSONL, JSON.stringify({ ...row, executor: dep.executor, reactive: dep.reactive, at: new Date().toISOString() }) + "\n", { flag: "a" });
}

async function waitFor<T>(label: string, fn: () => Promise<T | undefined>, timeoutMs: number, everyMs = 250): Promise<T | undefined> {
  const end = Date.now() + timeoutMs;
  while (Date.now() < end) {
    try {
      const v = await fn();
      if (v !== undefined) return v;
    } catch (e) {
      // transient RPC errors: keep polling
    }
    await sleep(everyMs);
  }
  console.log(`  timeout waiting for ${label}`);
  return undefined;
}

async function main() {
  const results: Record<string, unknown>[] = [];
  const executor = dep.executor as Address;
  const reactive = dep.reactive as Address;
  const poolA = dep.poolA as Address;
  console.log(`executor ${executor}  reactive ${reactive}  loops ${loops}`);

  for (let i = 0; i < loops; i++) {
    // one arbitrage in flight at a time
    // (an in-flight flag older than the contract's 60 s timeout no longer blocks a new trigger)
    await waitFor(
      "reactive idle",
      async () => {
        const busy = await rn.readContract({ address: reactive, abi: RC, functionName: "inFlight" });
        if (!busy) return true;
        const at = await rn.readContract({ address: reactive, abi: RC, functionName: "lastTriggerAt" });
        return Date.now() / 1000 - Number(at) > 62 ? true : undefined;
      },
      90_000,
      1000,
    );
    const up = i % 2 === 0;
    const tokenIn = (up ? dep.token1 : dep.token0) as Address;
    const amount = up ? shock1 : shock0;
    const gapBefore = await base.readContract({ address: executor, abi: EXEC, functionName: "currentGapBps" });

    const sentAt = Date.now();
    const hash = await wallet.writeContract({ address: poolA, abi: POOL, functionName: "swapExactIn", args: [tokenIn, amount, 0n, account.address] });
    const rcpt = await base.waitForTransactionReceipt({ hash, pollingInterval: 100 });
    const minedSeenAt = Date.now();
    const originBlock = rcpt.blockNumber;
    const originBlk = await base.getBlock({ blockNumber: originBlock });
    const gapAfterShock = await base.readContract({ address: executor, abi: EXEC, functionName: "currentGapBps", blockNumber: originBlock });
    console.log(`\n#${i + 1} shock ${up ? "token1→token0" : "token0→token1"} in pool A, block ${originBlock}, gap ${gapBefore}→${gapAfterShock} bps`);

    // executor result for this origin block
    const exec = await waitFor(
      "ArbExecuted/ArbSkipped",
      async () => {
        const logs = await base.getLogs({ address: executor, fromBlock: originBlock, toBlock: "latest" });
        const parsed = parseEventLogs({ abi: EXEC, logs }) as any[];
        return parsed.find((l) => BigInt(l.args.originBlock) === originBlock);
      },
      60_000,
      200,
    );
    const execSeenAt = Date.now();
    if (!exec) {
      results.push({ loop: i + 1, originBlock: Number(originBlock), shockTx: hash, outcome: "no callback within 60 s" });
      continue;
    }
    const execBlock = BigInt(exec.args.execBlock);
    const seq = BigInt(exec.args.seq);

    // Reactive Network side
    const head = await rn.getBlockNumber();
    const rnLogs = await rn.getLogs({ address: reactive, fromBlock: head - 600n, toBlock: "latest" });
    const rnParsed = parseEventLogs({ abi: RC, logs: rnLogs }) as any[];
    const detected = rnParsed.find((l) => l.eventName === "GapDetected" && BigInt(l.args.seq) === seq);
    const closed = await waitFor(
      "LoopClosed",
      async () => {
        const h = await rn.getBlockNumber();
        const ls = parseEventLogs({ abi: RC, logs: await rn.getLogs({ address: reactive, fromBlock: h - 600n, toBlock: "latest" }) }) as any[];
        return ls.find((l) => l.eventName === "LoopClosed" && BigInt(l.args.seq) === seq);
      },
      30_000,
      500,
    );

    const row = {
      loop: i + 1,
      direction: up ? "token1→token0" : "token0→token1",
      seq: Number(seq),
      outcome: exec.eventName,
      shockTx: hash,
      originBlock: Number(originBlock),
      originTimestamp: Number(originBlk.timestamp),
      execTx: exec.transactionHash,
      execBlock: Number(execBlock),
      originToExecBlocks: Number(execBlock - originBlock),
      gapAfterShockBps: Number(gapAfterShock),
      gapAfterArbBps: exec.eventName === "ArbExecuted" ? Number(exec.args.gapAfterBps) : null,
      profit1: exec.eventName === "ArbExecuted" ? Number(exec.args.profit1) / 1e18 : 0,
      rnDetectTx: detected?.transactionHash ?? null,
      rnDetectedAt: detected ? Number(detected.args.detectedAt) : null,
      rnClosedAt: closed ? Number(closed.args.closedAt) : null,
      originToDetectSec: detected ? Number(detected.args.detectedAt) - Number(originBlk.timestamp) : null,
      wallReceiptToExecSeenMs: execSeenAt - minedSeenAt,
      wallSendToExecSeenMs: execSeenAt - sentAt,
    };
    results.push(row);
    appendLine(row);
    console.log(
      `  ${row.outcome} seq ${row.seq}: ${row.originToExecBlocks} Base blocks after origin, gap→${row.gapAfterArbBps} bps, profit ${row.profit1.toFixed(3)}; ` +
        `RN detect +${row.originToDetectSec}s; wall ${row.wallReceiptToExecSeenMs} ms from receipt`,
    );
    await sleep(3000);
  }

  // Base Sepolia block time from the chain itself (for converting block deltas into seconds)
  const latest = await base.getBlock();
  const earlier = await base.getBlock({ blockNumber: latest.number - 3000n });
  const baseBlockSec = Number(latest.timestamp - earlier.timestamp) / 3000;

  const ok = results.filter((r) => r.outcome === "ArbExecuted") as any[];
  const q = (xs: number[], p: number) => {
    const s = [...xs].sort((a, b) => a - b);
    return s.length ? s[Math.min(s.length - 1, Math.floor(p * (s.length - 1) + 0.5))] : NaN;
  };
  const blocks = ok.map((r) => r.originToExecBlocks);
  const wall = ok.map((r) => r.wallReceiptToExecSeenMs);
  const summary = {
    loops: results.length,
    executed: ok.length,
    skippedOrMissing: results.length - ok.length,
    baseBlockSec,
    originToExecBlocks: { p50: q(blocks, 0.5), p95: q(blocks, 0.95), min: Math.min(...blocks), max: Math.max(...blocks) },
    originToExecSec: { p50: q(blocks, 0.5) * baseBlockSec, p95: q(blocks, 0.95) * baseBlockSec },
    wallReceiptToExecSeenMs: { p50: q(wall, 0.5), p95: q(wall, 0.95) },
    totalProfit1: ok.reduce((a, r) => a + r.profit1, 0),
  };
  console.log("\nsummary", JSON.stringify(summary, null, 2));
  const dir = new URL("bench/results/", ROOT);
  mkdirSync(dir, { recursive: true });
  const stamp = new Date().toISOString().replace(/[:.]/g, "-");
  writeFileSync(new URL(`latency-${stamp}.json`, dir), JSON.stringify({ deployment: dep, summary, results }, null, 2));
  console.log(`saved bench/results/latency-${stamp}.json`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
