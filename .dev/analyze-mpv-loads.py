#!/usr/bin/env python3
"""把一份开着 mpv verbose 的真机日志按「一次装载」切开看。

判据（2026-10-15 那局定的，见 memory `cdn-no-video-track-mediakit-deadlock`）：
健康装载必有 `VO: [libmpv]`（或 `VO: Description: render API for libmpv`）
+ 之后约 200ms 的 `libmpv_render: Window size:` 这一对；
坏的那次两条都没有 —— mpv 从没配过视频输出。

例外：**回前台续播**（`reinitDecoderAfterBackground`）不重建视频输出，restart
自然没有新的 `VO:`。判断它是不是这种良性情况要看心跳行 `CDN 看门狗:` 里的
`{宽}x{高}` —— 非零就说明视频输出还在，只是沿用了旧的。心跳 10s 一拍，
所以按 restart 前后 ±30s 找最近一条。

用法：python3 -I analyze-mpv-loads.py <log> [--top N]
"""
import re
import sys
from datetime import datetime

TS = re.compile(r"^(\d{2}:\d{2}:\d{2}\.\d{3}) (.*)$")
# 心跳行结尾是 `... hwdec <值> {宽}x{高}`；没有视频轨时是 `0x0`。
HB_DIMS = re.compile(r"(\d+)x(\d+)\s*$")


def t(s):
    return datetime.strptime(s, "%H:%M:%S.%f")


def main():
    path = sys.argv[1]
    top = 15
    if "--top" in sys.argv:
        top = int(sys.argv[sys.argv.index("--top") + 1])

    rows = []
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            m = TS.match(line.rstrip("\n"))
            if m:
                rows.append((t(m.group(1)), m.group(2)))

    sel, first, done, vo, win, prob, watch, app = [], [], [], [], [], [], [], []
    # 心跳里的视频参数：(时刻, 宽, 高)。用来区分「没配视频输出」与「沿用了旧的」。
    video_hb = []
    for ts, msg in rows:
        if msg.startswith("选流:"):
            sel.append((ts, msg))
        elif "first video frame after restart shown" in msg:
            first.append(ts)
        elif "playback restart complete" in msg:
            done.append((ts, msg.split("@")[-1].strip()))
        elif "VO: [" in msg or "VO: Description" in msg:
            vo.append(ts)
        elif "libmpv_render: Window size:" in msg:
            win.append(ts)
        elif msg.startswith("VideoOutput.Probe"):
            watch.append(ts)
        elif msg.startswith("{") and "elapsedMs" in msg:
            prob.append((ts, msg))
        elif "CDN 看门狗" in msg or "无视频轨" in msg or "重建" in msg:
            app.append((ts, msg))
            if "video-codec" in msg:
                m = HB_DIMS.search(msg)
                if m:
                    video_hb.append((ts, int(m.group(1)), int(m.group(2))))

    print(f"文件 {path}")
    print(f"  区间 {rows[0][0].time()} → {rows[-1][0].time()}，{len(rows)} 行")
    print(f"  选流 {len(sel)} 次 | VO 配置 {len(vo)} | Window size {len(win)} "
          f"| restart complete {len(done)} | first frame {len(first)}")
    print(f"  app 侧告警（无视频轨/重建）: "
          f"{sum(1 for _, m in app if '无视频轨' in m or '重建' in m)} 条")
    print(f"  探针 {len(prob)} 条: "
          + " ".join(f"{ts.time()}" for ts, _ in prob))

    if prob:
        print("  探针详情:")
        for ts, m in prob:
            print(f"    {ts.time()} {m}")

    # 每次选流 → 第一个视频帧 的延迟
    print(f"\n每次「选流 → 首帧」延迟（只列最慢 {top} 条）:")
    lat = []
    for ts, msg in sel:
        nxt = next((f for f in first if f >= ts), None)
        if nxt is None:
            lat.append((None, ts, msg))
            continue
        lat.append(((nxt - ts).total_seconds(), ts, msg))
    for secs, ts, msg in sorted(
        [x for x in lat if x[0] is not None], key=lambda x: -x[0]
    )[:top]:
        print(f"    {secs:6.2f}s  {ts.time()}  {msg[len('选流: '):][:60]}")
    if any(x[0] is None for x in lat):
        print(f"    ({sum(1 for x in lat if x[0] is None)} 次选流之后没有首帧)")

    # 有没有哪次重启没有 VO 对（健康装载的 VO 一定落在 restart complete 之前 ~0.2s）。
    print("\n没有 VO 配置的「restart complete」（窗口 3s）:")
    print("    （回前台续播沿用旧视频输出的不算 —— 再看 ±30s 内心跳的分辨率）")

    def hb_near(ts):
        # 优先看 restart **之后**的心跳：换源时旧 player 的心跳还能在 restart 前
        # 报出上一个流的分辨率，拿它会把"新流没配 VO"洗成"沿用旧输出"。
        after = [
            ((h - ts).total_seconds(), h, w, ht)
            for h, w, ht in video_hb
            if 0 <= (h - ts).total_seconds() <= 30
        ]
        if after:
            return min(after)
        before = [
            ((ts - h).total_seconds(), h, w, ht)
            for h, w, ht in video_hb
            if 0 < (ts - h).total_seconds() <= 30
        ]
        return min(before, default=None)

    bad, reused = [], []
    for ts, tail in done:
        # EOF 处的 restart 不是一次装载：片尾到了，本来就没有新视频轨要配。
        if "video=eof" in tail:
            continue
        if any(v <= ts and (ts - v).total_seconds() < 3 for v in vo):
            continue
        near = hb_near(ts)
        if near and near[2] > 0 and near[3] > 0:
            reused.append((ts, tail, near))
        else:
            bad.append((ts, tail))
    if not bad:
        print("    无 —— 每次装载都配上了视频输出")
    for ts, tail in bad:
        print(f"    {ts.time()}  {tail}")
    for ts, tail, (_, h, w, ht) in reused:
        print(f"    {ts.time()}  {tail}  → 不计：{h.time()} 心跳有 {w}x{ht}，本次沿用旧输出")

    # 静默时段
    print("\n>60s 的静默时段:")
    for (a, _), (b, _) in zip(rows, rows[1:]):
        d = (b - a).total_seconds()
        if d > 60:
            print(f"    {a.time()} → {b.time()}  ({d / 60:.1f} 分钟)")


if __name__ == "__main__":
    main()
