// Builds the latency report straight from chain events, independent of any benchmark run log.
// Base Sepolia: ArbExecuted / ArbSkipped from the executor (origin block -> execution block).
// Reactive Lasna: GapDetected / LoopClosed from the reactive contract (1 s timestamps).
// Writes bench/results/summary.json, bench/results/loops.md and bench/results/latency.svg.
// Usage: npx tsx report.ts [baseFromBlock] [lasnaFromBlock]
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { createPublicClient, defineChain, http, parseAbi, parseEventLogs, type Address } from "viem";
import { baseSepolia } from "viem/chains";

const ROOT = new URL("..", import.meta.url);
const dep = JSON.parse(readFileSync(new URL("deployments/latest.json", ROOT), "utf8"));
const lasna = defineChain({
  id: 5318007,
  name: "Reactive Lasna",
  nativeCurrency: { name: "lREACT", symbol: "lREACT", decimals: 18 },
  rpcUrls: { default: { http: ["https://lasna-rpc.rnk.dev/"] } },
});
const base = createPublicClient({ chain: baseSepolia, transport: http("https://sepolia.base.org") });
const rn = createPublicClient({ chain: lasna, transport: http() });

const EXEC = parseAbi([
  "event ArbExecuted(uint256 indexed seq, uint256 originBlock, uint256 execBlock, uint256 execTimestamp, bool buyInB, uint256 amountIn1, uint256 profit1, uint256 gapBeforeBps, uint256 gapAfterBps)",
  "event ArbSkipped(uint256 indexed seq, uint256 originBlock, uint256 execBlock, string reason)",
]);
const RC = parseAbi([
  "event GapDetected(uint256 indexed seq, uint256 originBlock, uint256 originTxHash, uint256 gapBps, uint256 detectedAt)",
  "event LoopClosed(uint256 indexed seq, bool executed, uint256 originBlock, uint256 execBlock, uint256 closedAt)",
]);

async function logsInChunks(client: any, address: Address, from: bigint, to: bigint, step: bigint) {
  const out: any[] = [];
  for (let a = from; a <= to; a += step) {
    const b = a + step - 1n < to ? a + step - 1n : to;
    out.push(...(await client.getLogs({ address, fromBlock: a, toBlock: b })));
  }
  return out;
}

const q = (xs: number[], p: number) => {
  const s = [...xs].sort((a, b) => a - b);
  return s.length ? s[Math.min(s.length - 1, Math.floor(p * (s.length - 1) + 0.5))] : NaN;
};

async function main() {
  const baseFrom = BigInt(process.argv[2] ?? "57215000");
  const lasnaFrom = BigInt(process.argv[3] ?? "8040000");
  const baseHead = await base.getBlockNumber();
  const rnHead = await rn.getBlockNumber();

  const exLogs = parseEventLogs({ abi: EXEC, logs: await logsInChunks(base, dep.executor, baseFrom, baseHead, 199n) }) as any[];
  const rcLogs = parseEventLogs({ abi: RC, logs: await logsInChunks(rn, dep.reactive, lasnaFrom, rnHead, 29_000n) }) as any[];

  const bySeq = new Map<number, any>();
  for (const l of exLogs) bySeq.set(Number(l.args.seq), { exec: l });
  for (const l of rcLogs) {
    const s = Number(l.args.seq);
    const row = bySeq.get(s) ?? {};
    row[l.eventName === "GapDetected" ? "detected" : "closed"] = l;
    bySeq.set(s, row);
  }

  // Base Sepolia block time measured on chain
  const headBlk = await base.getBlock({ blockNumber: baseHead });
  const oldBlk = await base.getBlock({ blockNumber: baseHead - 3000n });
  const baseBlockSec = Number(headBlk.timestamp - oldBlk.timestamp) / 3000;

  const rows: any[] = [];
  for (const [seq, r] of [...bySeq.entries()].sort((a, b) => a[0] - b[0])) {
    if (!r.exec) continue;
    const originBlock = BigInt(r.exec.args.originBlock);
    const execBlock = BigInt(r.exec.args.execBlock);
    const originTs = Number((await base.getBlock({ blockNumber: originBlock })).timestamp);
    rows.push({
      seq,
      outcome: r.exec.eventName,
      originBlock: Number(originBlock),
      execBlock: Number(execBlock),
      blocks: Number(execBlock - originBlock),
      seconds: Number(execBlock - originBlock) * baseBlockSec,
      gapBeforeBps: r.exec.eventName === "ArbExecuted" ? Number(r.exec.args.gapBeforeBps) : (r.detected ? Number(r.detected.args.gapBps) : null),
      gapAfterBps: r.exec.eventName === "ArbExecuted" ? Number(r.exec.args.gapAfterBps) : null,
      profit1: r.exec.eventName === "ArbExecuted" ? Number(r.exec.args.profit1) / 1e18 : 0,
      execTx: r.exec.transactionHash,
      originTs,
      detectedAt: r.detected ? Number(r.detected.args.detectedAt) : null,
      detectTx: r.detected?.transactionHash ?? null,
      closedAt: r.closed ? Number(r.closed.args.closedAt) : null,
      closeTx: r.closed?.transactionHash ?? null,
    });
  }

  const ex = rows.filter((r) => r.outcome === "ArbExecuted");
  const secs = ex.map((r) => r.seconds);
  const blocks = ex.map((r) => r.blocks);
  const summary = {
    executor: dep.executor,
    reactive: dep.reactive,
    loops: rows.length,
    executed: ex.length,
    skipped: rows.length - ex.length,
    baseBlockSec,
    originToExecBlocks: { min: Math.min(...blocks), p50: q(blocks, 0.5), p95: q(blocks, 0.95), max: Math.max(...blocks) },
    originToExecSeconds: { min: Math.min(...secs), p50: q(secs, 0.5), p95: q(secs, 0.95), max: Math.max(...secs), mean: secs.reduce((a, b) => a + b, 0) / (secs.length || 1) },
    gapAfterBps: { min: Math.min(...ex.map((r) => r.gapAfterBps)), max: Math.max(...ex.map((r) => r.gapAfterBps)) },
    totalProfit1: ex.reduce((a, r) => a + r.profit1, 0),
    generatedAt: new Date().toISOString(),
  };

  const dir = new URL("bench/results/", ROOT);
  mkdirSync(dir, { recursive: true });
  writeFileSync(new URL("summary.json", dir), JSON.stringify({ summary, rows }, null, 2));

  const short = (h: string) => `${h.slice(0, 10)}…`;
  const md = [
    `| seq | origin block | exec block | Base blocks | seconds | gap before → after (bps) | profit (RXUSD) | exec tx | Lasna detect tx |`,
    `|---|---|---|---|---|---|---|---|---|`,
    ...rows.map(
      (r) =>
        `| ${r.seq} | ${r.originBlock} | ${r.execBlock} | ${r.blocks} | ${r.seconds.toFixed(1)} | ${r.gapBeforeBps ?? "?"} → ${r.gapAfterBps ?? "skipped"} | ${r.profit1.toFixed(3)} | [${short(r.execTx)}](https://sepolia.basescan.org/tx/${r.execTx}) | ${r.detectTx ? `[${short(r.detectTx)}](https://lasna.reactscan.net/tx/${r.detectTx})` : "—"} |`,
    ),
  ].join("\n");
  writeFileSync(new URL("loops.md", dir), md + "\n");

  // simple SVG bar chart: seconds from origin event to arbitrage execution, per loop
  const W = 720, H = 260, pad = 40, bw = (W - 2 * pad) / Math.max(1, ex.length);
  const maxS = Math.max(3, Math.ceil(Math.max(...secs)));
  const bars = ex
    .map((r, i) => {
      const h = ((H - 2 * pad) * r.seconds) / maxS;
      return `<rect x="${pad + i * bw + 2}" y="${H - pad - h}" width="${bw - 4}" height="${h}" fill="#4f7cff"><title>seq ${r.seq}: ${r.seconds.toFixed(1)} s (${r.blocks} blocks)</title></rect>`;
    })
    .join("");
  const p50y = H - pad - ((H - 2 * pad) * summary.originToExecSeconds.p50) / maxS;
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" font-family="sans-serif" font-size="12">
<rect width="100%" height="100%" fill="#ffffff"/>
<text x="${pad}" y="20" font-size="14" font-weight="bold">ReflexArb: origin event → arbitrage executed (Base Sepolia, ${ex.length} loops)</text>
${bars}
<line x1="${pad}" x2="${W - pad}" y1="${p50y}" y2="${p50y}" stroke="#e5484d" stroke-dasharray="4 3"/>
<text x="${W - pad}" y="${p50y - 4}" text-anchor="end" fill="#e5484d">p50 ${summary.originToExecSeconds.p50.toFixed(1)} s</text>
<line x1="${pad}" x2="${W - pad}" y1="${H - pad}" y2="${H - pad}" stroke="#333"/>
<text x="${pad - 6}" y="${H - pad}" text-anchor="end">0 s</text>
<text x="${pad - 6}" y="${pad + 4}" text-anchor="end">${maxS} s</text>
<text x="${W / 2}" y="${H - 12}" text-anchor="middle">loop (seq)</text>
</svg>`;
  writeFileSync(new URL("latency.svg", dir), svg);
  console.log(JSON.stringify(summary, null, 2));
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
