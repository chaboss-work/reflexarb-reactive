"""Narrated ReflexArb demo (~2 min) for the Reactive Omni submission: the scenes of make_video.py plus a voice-over
and a "still live" scene from the 25 Nov 2026 re-check.

Every number comes from chain events: bench/results/summary.json (21 executed loops, 11 Nov) and
bench/results/latency-2026-11-25T14-39-18-658Z.json (one loop re-run on 25 Nov, seq 25).

Run with H:\\work\\tts\\venv-qwen\\Scripts\\python.exe (Kokoro af_heart, the series voice):
    make_narrated.py --tts     narration per scene -> docs/video/narrated/seg-N.wav + segments.json
    make_narrated.py           assemble -> docs/video/reflexarb-narrated.mp4 (1280x720),
                               published as docs/video/reflexarb-demo.mp4 (the 70-s silent cut is reflexarb-demo-short.mp4)
"""
import json
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import make_video as mv  # noqa: E402  (scene renderers and the benchmark data)

sys.path.insert(0, "H:/work/whop/videos/shorts/s1-odds-rule")
import build as s1  # noqa: E402  (Kokoro narration with the series lexicon, RAM-guarded)

OUT = HERE / "narrated"
RECHECK = json.loads((mv.ROOT / "bench/results/latency-2026-11-25T14-39-18-658Z.json").read_text(encoding="utf-8"))
LIVE = RECHECK["results"][0]


def live_check_card():
    img, d = mv.canvas()
    d.text((80, 90), "Still live: re-checked on 25 Nov 2026", font=mv.font(mv.SANS_B, 44), fill=mv.TEXT)
    d.text((84, 160), "two weeks after deployment, same contracts, one new loop", font=mv.font(mv.SANS, 26), fill=mv.MUTED)
    rows = [
        ("[Base Sepolia]", f"block {LIVE['originBlock']}   swap pushes the gap to {LIVE['gapAfterShockBps']} bps", mv.TEXT),
        ("[Lasna]", f"GapDetected seq {LIVE['seq']}, same second   tx {LIVE['rnDetectTx'][:18]}…", mv.ACCENT),
        ("[Base Sepolia]", f"block {LIVE['execBlock']}   ArbExecuted, {LIVE['originToExecBlocks']} blocks = "
                           f"{LIVE['originToExecBlocks'] * 0.2:.1f} s after the swap", mv.BLUE),
        ("[Base Sepolia]", f"gap {LIVE['gapAfterShockBps']} → {LIVE['gapAfterArbBps']} bps, profit "
                           f"{LIVE['profit1']:.3f} RXUSD   tx {LIVE['execTx'][:18]}…", mv.BLUE),
    ]
    d.rounded_rectangle((40, 230, mv.W - 40, 560), radius=14, fill=mv.PANEL, outline=mv.LINE)
    for i, (chain, text, color) in enumerate(rows):
        y = 262 + i * 70
        d.text((64, y), chain, font=mv.font(mv.MONO, 20), fill=mv.MUTED)
        d.text((250, y), text, font=mv.font(mv.MONO, 20), fill=color)
    d.text((80, 590), "Reactive contract balance: 4.43 lREACT, enough for about 90 more loops",
           font=mv.font(mv.SANS, 24), fill=mv.MUTED)
    mv.footer(d)
    return img


def scenes():
    sample = next(r for r in mv.ROWS if r["seq"] == 9)
    replay = mv.replay_frames(sample)
    s = mv.S
    return [
        (mv.title_card(),
         "ReflexArb: a cross-pool arbitrage that closes itself, built on Reactive Omni."),
        (mv.text_card("The problem", [
            "When one pool's price moves away from another's, the gap is free money for whoever closes it first.",
            "Keeper bots poll RPCs and pay for servers. On Reactive Omni the event itself triggers the trade."]),
         "When one pool's price drifts away from another's, the gap is free money for whoever closes it first. "
         "Keeper bots poll nodes around the clock, and someone pays for those servers. "
         "On Reactive Omni, the event itself triggers the trade."),
        (mv.architecture(0),
         "Two constant-product pools on Base Sepolia quote the same pair, and a reactive contract on Reactive's "
         "Lasna network watches both of them."),
        (mv.architecture(1),
         "Step one: every swap makes a pool emit a Sync event, and the reactive contract mirrors those reserves."),
        (mv.architecture(2),
         "Step two: when the gap passes eighty basis points and no loop is in flight, it emits Gap Detected, "
         "and asks Reactive to call our executor back on Base."),
        (mv.architecture(3),
         "Step three: the executor sizes the trade in closed form, buys where it's cheap, sells where it's dear, "
         "and its event closes the loop. No bot, no server, no keeper."),
        (replay[0],
         f"Here is one real loop, rebuilt from chain events only. A swap in pool A pushes the gap to "
         f"{sample['gapBeforeBps']} basis points, and the reactive contract sees it in the same second."),
        (replay[1],
         f"The callback lands on Base {sample['blocks']} blocks later: {sample['seconds']:.1f} seconds after the "
         "origin swap."),
        (replay[2],
         "The gap closes into the fee band, the profit stays with the executor, and the loop unlocks for the next one."),
        (mv.latency_card(),
         f"Across {s['executed']} executed loops, the median from origin swap to executed arbitrage is "
         f"{s['originToExecSeconds']['p50']:.1f} seconds, or {s['originToExecBlocks']['p50']} Base blocks. "
         f"The slowest took {s['originToExecSeconds']['max']:.1f} seconds, and every gap ended at "
         f"{s['gapAfterBps']['min']} to {s['gapAfterBps']['max']} basis points."),
        (mv.text_card("Why the gap stops at ~60 bps", [
            "With 0.3% fees in each pool, an optimal arbitrage leaves about 2 × fee of residual gap.",
            "The trigger sits at 80 bps, above that band, so the contract never fires on a gap it cannot profit from. "
            "An in-flight lock ignores the arbitrage's own Sync events; timers use seconds because Base makes a block "
            "every 200 ms."]),
         "Why sixty? With a zero point three percent fee in each pool, an optimal arbitrage always leaves about two "
         "fees of gap. The trigger sits above that band, so the contract never fires on a gap it can't profit from. "
         "An in-flight lock ignores the arbitrage's own Sync events, and every timer counts seconds, because Base "
         "makes a block every two hundred milliseconds."),
        (live_check_card(),
         f"We ran it again on November twenty-fifth, two weeks after deploying. The loop is still live: the "
         f"arbitrage landed {LIVE['originToExecBlocks']} blocks, {LIVE['originToExecBlocks'] * 0.2:.1f} seconds, "
         "after the swap."),
        (mv.outro(),
         "The contracts, sixteen Foundry tests and every transaction are on GitHub. ReflexArb: the event is the bot."),
    ]


def main():
    OUT.mkdir(exist_ok=True)
    built = scenes()
    s1.SEGMENTS, s1.OUT = [text for _, text in built], OUT
    if "--tts" in sys.argv:
        s1.tts()
        return
    durations = json.loads((OUT / "segments.json").read_text(encoding="utf-8"))
    assert len(durations) == len(built), "segments.json does not match the scenes: run --tts again"
    inputs, graph, labels = [], [], []
    for k, ((img, _), dur) in enumerate(zip(built, durations)):
        path = OUT / f"scene-{k + 1}.png"
        img.save(path)
        inputs += ["-loop", "1", "-framerate", "30", "-t", f"{dur:.3f}", "-i", str(path)]
    for k in range(len(built)):
        inputs += ["-i", str(OUT / f"seg-{k + 1}.wav")]
    n = len(built)
    for k in range(n):
        graph.append(f"[{k}:v]fps=30,format=yuv420p,setsar=1[v{k}]")
        graph.append(f"[{n + k}:a]aresample=48000,aformat=sample_rates=48000:channel_layouts=stereo[a{k}]")
        labels.append(f"[v{k}][a{k}]")
    graph.append("".join(labels) + f"concat=n={n}:v=1:a=1[vv][aa]")
    graph.append("[aa]loudnorm=I=-16:TP=-1.5:LRA=11,aresample=48000[au]")
    out = HERE / "reflexarb-narrated.mp4"
    cmd = [mv.FFMPEG, "-y", "-v", "error", *inputs, "-filter_complex", ";".join(graph), "-map", "[vv]", "-map", "[au]",
           "-c:v", "libx264", "-crf", "20", "-preset", "medium", "-c:a", "aac", "-b:a", "160k", "-threads", "4",
           "-movflags", "+faststart", str(out)]
    subprocess.run(cmd, check=True)
    print(f"готово: {out} ({sum(durations):.1f} с, {n} сцен)")


if __name__ == "__main__":
    main()
