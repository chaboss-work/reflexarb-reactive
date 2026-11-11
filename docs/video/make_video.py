"""Build the ReflexArb demo video (~1 min) from the on-chain benchmark data.

    python docs/video/make_video.py

Scenes: title, problem, architecture, the loop step by step, one real loop replayed with its transactions,
latency chart from bench/results/summary.json, correctness, outro. Output: docs/video/reflexarb-demo.mp4
"""
from __future__ import annotations

import json
import shutil
import subprocess
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[2]
FFMPEG = shutil.which("ffmpeg") or r"H:\work\.tools\ffmpeg-pkg\ffmpeg-9.0.2-essentials_build\bin\ffmpeg.exe"
W, H = 1280, 720
BG, PANEL, TEXT, MUTED, ACCENT, LINE, BLUE, RED = "#0f1114", "#171a1f", "#e9ecf1", "#9aa3b0", "#3ccf9b", "#2a2f37", "#5b8cff", "#ff6b6b"
FONTS = Path("C:/Windows/Fonts")
SANS, SANS_B, MONO = "segoeui.ttf", "segoeuib.ttf", "consola.ttf"

DATA = json.loads((ROOT / "bench/results/summary.json").read_text(encoding="utf-8"))
DEP = json.loads((ROOT / "deployments/latest.json").read_text(encoding="utf-8"))
S = DATA["summary"]
ROWS = [r for r in DATA["rows"] if r["outcome"] == "ArbExecuted"]


def font(name, size):
    return ImageFont.truetype(str(FONTS / name), size)


def canvas():
    img = Image.new("RGB", (W, H), BG)
    return img, ImageDraw.Draw(img)


def footer(d):
    d.text((40, H - 44), "ReflexArb · Reactive Omni Buildathon · Every Second Counts · Base Sepolia + Reactive Lasna",
           font=font(SANS, 18), fill=MUTED)


def wrap(d, text, f, width):
    words, lines, cur = text.split(), [], ""
    for w in words:
        t = (cur + " " + w).strip()
        if d.textlength(t, font=f) <= width:
            cur = t
        else:
            lines.append(cur)
            cur = w
    if cur:
        lines.append(cur)
    return lines


def title_card():
    img, d = canvas()
    d.text((80, 220), "ReflexArb", font=font(SANS_B, 80), fill=TEXT)
    d.text((84, 330), "Cross-pool arbitrage that closes itself.", font=font(SANS, 38), fill=ACCENT)
    d.text((84, 392), f"Pool event  →  reactive contract  →  callback.  Median {S['originToExecSeconds']['p50']:.1f} s, no bots.",
           font=font(SANS, 26), fill=MUTED)
    footer(d)
    return img


def text_card(heading, paras):
    img, d = canvas()
    d.text((80, 140), heading, font=font(SANS_B, 48), fill=TEXT)
    y = 240
    for i, para in enumerate(paras):
        for line in wrap(d, para, font(SANS, 30), W - 160):
            d.text((80, y), line, font=font(SANS, 30), fill=TEXT if i == 0 else MUTED)
            y += 44
        y += 22
    footer(d)
    return img


def box(d, xy, title, lines, color):
    x0, y0, x1, y1 = xy
    d.rounded_rectangle(xy, radius=14, fill=PANEL, outline=color, width=3)
    d.text((x0 + 18, y0 + 12), title, font=font(SANS_B, 24), fill=color)
    for i, l in enumerate(lines):
        d.text((x0 + 18, y0 + 52 + i * 30), l, font=font(SANS, 20), fill=TEXT)


def arrow(d, a, b, label, color=MUTED, above=True):
    d.line([a, b], fill=color, width=3)
    import math
    ang = math.atan2(b[1] - a[1], b[0] - a[0])
    for s in (-0.4, 0.4):
        d.line([b, (b[0] - 16 * math.cos(ang + s), b[1] - 16 * math.sin(ang + s))], fill=color, width=3)
    mx, my = (a[0] + b[0]) / 2, (a[1] + b[1]) / 2
    d.text((mx - d.textlength(label, font=font(SANS, 19)) / 2, my - (30 if above else -8)), label, font=font(SANS, 19), fill=color)


def architecture(highlight=0):
    img, d = canvas()
    d.text((60, 40), "The loop", font=font(SANS_B, 44), fill=TEXT)
    d.text((60, 110), "Base Sepolia", font=font(SANS_B, 22), fill=MUTED)
    d.text((780, 110), "Reactive Network (Lasna)", font=font(SANS_B, 22), fill=MUTED)
    on = lambda n: ACCENT if highlight in (0, n) else LINE
    box(d, (60, 150, 470, 290), "MiniPool A / B", ["constant product, 0.3% fee", "emits Sync(r0, r1)"], on(1))
    box(d, (780, 150, 1220, 330), "ReflexArbReactive", ["mirrors reserves of A and B", "gap ≥ 80 bps & nothing in flight?",
                                                         "emit GapDetected", "requestCallback(Base, executor)"], on(2))
    box(d, (60, 420, 470, 590), "ReflexArbExecutor", ["optimal size (closed form)", "buy cheap, sell dear", "emit ArbExecuted"], on(3))
    arrow(d, (470, 200), (780, 200), "1  Sync event", on(1))
    arrow(d, (780, 300), (430, 420), "2  callback onGap()", on(2))
    arrow(d, (470, 520), (1000, 330), "3  ArbExecuted → LoopClosed", on(3), above=False)
    footer(d)
    return img


def replay_frames(row):
    frames = []
    lines = [
        ("Base Sepolia", f"block {row['originBlock']}   swap in pool A pushes the price — gap {row['gapBeforeBps']} bps", TEXT),
        ("Lasna", f"GapDetected seq {row['seq']}   tx {row['detectTx'][:18]}…", ACCENT),
        ("Lasna", "requestCallbackV_1_0 → Base Sepolia, executor.onGap(seq, originBlock, gap)", MUTED),
        ("Base Sepolia", f"block {row['execBlock']}   ArbExecuted — {row['blocks']} blocks = {row['seconds']:.1f} s after the origin block", BLUE),
        ("Base Sepolia", f"gap {row['gapBeforeBps']} → {row['gapAfterBps']} bps, profit {row['profit1']:.3f} RXUSD   tx {row['execTx'][:18]}…", BLUE),
        ("Lasna", f"LoopClosed seq {row['seq']} — the next gap can trigger again", ACCENT),
    ]
    for n in range(2, len(lines) + 1, 2):
        img, d = canvas()
        d.rounded_rectangle((40, 40, W - 40, H - 140), radius=14, fill=PANEL, outline=LINE)
        d.text((64, 56), f"One real loop, seq {row['seq']} (from chain events)", font=font(SANS_B, 26), fill=TEXT)
        for i, (chain, text, color) in enumerate(lines[:n]):
            y = 130 + i * 62
            d.text((64, y), f"[{chain}]", font=font(MONO, 20), fill=MUTED)
            d.text((250, y), text, font=font(MONO, 20), fill=color)
        cap = {2: "The swap's Sync event reaches the reactive contract", 4: "The callback lands on Base a moment later",
               6: "Gap closed into the fee band; the loop unlocks"}[n]
        d.text((64, H - 116), cap, font=font(SANS_B, 28), fill=TEXT)
        footer(d)
        frames.append(img)
    return frames


def latency_card():
    img, d = canvas()
    d.text((60, 36), f"Latency over {S['executed']} live loops", font=font(SANS_B, 40), fill=TEXT)
    x0, y0, x1, y1 = 80, 130, 860, 560
    maxs = max(3.0, max(r["seconds"] for r in ROWS))
    bw = (x1 - x0) / len(ROWS)
    for i, r in enumerate(ROWS):
        h = (y1 - y0) * r["seconds"] / maxs
        d.rectangle((x0 + i * bw + 3, y1 - h, x0 + (i + 1) * bw - 3, y1), fill=BLUE)
    p50 = S["originToExecSeconds"]["p50"]
    yp = y1 - (y1 - y0) * p50 / maxs
    d.line((x0, yp, x1, yp), fill=RED, width=2)
    lbl = f"p50 {p50:.1f} s"
    tw = d.textlength(lbl, font=font(SANS_B, 20))
    d.rectangle((x0 + 6, yp - 30, x0 + 18 + tw, yp - 4), fill=BG)
    d.text((x0 + 12, yp - 30), lbl, font=font(SANS_B, 20), fill=RED)
    d.line((x0, y1, x1, y1), fill=MUTED, width=2)
    d.text((x0, y1 + 10), "each bar = one loop: origin swap → arbitrage executed (seconds)", font=font(SANS, 20), fill=MUTED)
    stats = [
        ("p50", f"{S['originToExecSeconds']['p50']:.1f} s"),
        ("p95", f"{S['originToExecSeconds']['p95']:.1f} s"),
        ("min", f"{S['originToExecSeconds']['min']:.1f} s"),
        ("blocks", f"{S['originToExecBlocks']['min']}–{S['originToExecBlocks']['max']}"),
        ("gap after", f"{S['gapAfterBps']['min']}–{S['gapAfterBps']['max']} bps"),
        ("profit", f"{S['totalProfit1']:.2f} RXUSD"),
    ]
    for i, (k, v) in enumerate(stats):
        d.text((920, 150 + i * 66), k, font=font(SANS, 24), fill=MUTED)
        d.text((1060, 146 + i * 66), v, font=font(SANS_B, 30), fill=TEXT)
    footer(d)
    return img


def outro():
    img, d = canvas()
    d.text((80, 170), "ReflexArb", font=font(SANS_B, 60), fill=TEXT)
    rows = [
        "github.com/chaboss-work/reflexarb-reactive",
        f"Reactive contract (Lasna)  {DEP['reactive']}",
        f"Executor (Base Sepolia)    {DEP['executor']}",
        "16 Foundry tests · timers in seconds · one loop in flight · closed-form sizing",
    ]
    for i, r in enumerate(rows):
        d.text((84, 270 + i * 54), r, font=font(MONO if i in (1, 2) else SANS, 26), fill=ACCENT if i == 0 else MUTED)
    footer(d)
    return img


def main():
    out = ROOT / "docs/video/reflexarb-demo.mp4"
    sample = next(r for r in ROWS if r["seq"] == 9)
    scenes = [(title_card(), 4.5),
              (text_card("The problem", [
                  "When one pool's price moves away from another's, the gap is free money for whoever closes it first.",
                  "Keeper bots poll RPCs and pay for servers. On Reactive Omni the event itself triggers the trade."]), 7.0),
              (architecture(0), 6.0)]
    scenes += [(architecture(n), 3.5) for n in (1, 2, 3)]
    scenes += [(f, 4.0) for f in replay_frames(sample)]
    scenes.append((latency_card(), 9.0))
    scenes.append((text_card("Why the gap stops at ~60 bps", [
        "With 0.3% fees in each pool, an optimal arbitrage leaves about 2 × fee of residual gap.",
        "The trigger sits at 80 bps, above that band, so the contract never fires on a gap it cannot profit from. "
        "An in-flight lock ignores the arbitrage's own Sync events; timers use seconds because Base makes a block every 200 ms."]), 9.0))
    scenes.append((outro(), 6.0))

    with tempfile.TemporaryDirectory() as tmp:
        listing = []
        for i, (img, dur) in enumerate(scenes):
            p = Path(tmp) / f"{i:03d}.png"
            img.save(p)
            listing.append(f"file '{p.as_posix()}'\nduration {dur}")
        listing.append(f"file '{(Path(tmp) / f'{len(scenes) - 1:03d}.png').as_posix()}'")
        (Path(tmp) / "list.txt").write_text("\n".join(listing), encoding="utf-8")
        subprocess.run([FFMPEG, "-v", "error", "-y", "-f", "concat", "-safe", "0", "-i", str(Path(tmp) / "list.txt"),
                        "-vf", "fps=30,format=yuv420p", "-c:v", "libx264", "-crf", "20", "-movflags", "+faststart", str(out)],
                       check=True)
        # keep stills for the README / submission page
        for name, idx in (("architecture.png", 2), ("latency.png", len(scenes) - 3)):
            scenes[idx][0].save(ROOT / "docs/video" / name)
    print(f"{out}  {sum(d for _, d in scenes):.1f}s  {len(scenes)} frames")


if __name__ == "__main__":
    main()
