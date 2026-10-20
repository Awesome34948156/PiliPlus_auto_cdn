#!/usr/bin/env bash
# =============================================================================
# verify-rebuild.sh —— 「就地重建渲染上下文」两个 commit 的真机验收判定
#
# 用法:  ./verify-rebuild.sh <pili-console 日志文件>
#        例:  ./verify-rebuild.sh pili-console-14-2026-10-12.log
#
# 判定对象（都对 P3 的 `_runRenderContextRebuild` 生效）
#   376bc8092  重建后别把「在播」恢复成「暂停」
#   74c9c7c4b  就地重建不再丢续播点
#
# 为什么放 docs/logs/ 而不是 lib/scripts/
#   lib/scripts/ 装的是**构建/打包**脚本（patch-macos.sh、mpvkit/*），产出的是仓库
#   产物；这个脚本只吃同目录下那些**手工存档**的真机日志（README.md 的一张表列着
#   每份的来历、给谁作证），跟数据放在一起才有人知道它该跑哪个文件。
#
# -----------------------------------------------------------------------------
# A（暂停对）—— 为什么这么判
#   每次 `playerInit` 的 mpv option 块里，mpv 先把播放器建在 paused
#   （`Set property: pause=true -> 1`），随后 `pl_player/controller.dart` 的
#   `_initializePlayer` 里 `if (_autoPlay) playIfExists()` 才补一发
#   `Set property: pause=false -> 1`。于是：
#     * **成对** ⇒ 这次装载是「在播」（autoplay=true），起播后位置继续推进；
#     * **只有 pause=true** ⇒ 装载完停在暂停（`playback restart complete …
#       (paused)`、之后心跳 `播放中 false` 且位置冻住）。
#   重建路原本读的是**页面**字段 `videoDetailController.playerStatus`，它全仓只有一个
#   写点（`view.dart` 的 `didPushNext`，被别的页盖住时才赋值）→ 没被盖住过的页面读到
#   的恒是 null → `?? false` → 每一次重建都把在播的视频恢复成暂停。改法是读**播放器**
#   那个 `playerStatus`（`_removeListeners()` 之后它冻在拆之前的值）。见 log 13。
#
#   会骗人的形态（不排掉就会误判）：
#     * 用户自己按的暂停/播放**也**写 mpv 的 pause —— 有时长成裸的
#       `Set property: pause -> 1`（log 13 的 17:30:49.199），有时长成
#       `pause=true -> 1`（log 14 的 20:32:04.987）。所以「裸 pause」的条数只是个**旁证**，
#       不是铁证；真正判 A 只认落在**重建块内**的那对（块只跨 ~10ms，人按不进去）。
#     * 正常起播 / 换源重开 / 切 hw **也**打这对行 —— 所以必须限定窗口；脚本会顺手打一条
#       **块外对照**给你比（它只是「正常长什么样」的形状参照，不参与判定）。
#
# B（续播点）—— 为什么这么判
#   老毛病：重建那一刻 `defaultST` 恒为 null（每次成功装载收尾都 `defaultST = null;`），
#   续播点全压在 `playedTime` 上，而它由位置流无条件写、会被新装载开头那个 0 位置事件
#   钉成 0 → `resolveResumeSeek` 返回 null → `Setting option 'start'` 那一行**整个消失**。
#   修复是让发起方（`view.dart` 的 `_onRenderContextLost`）把拆之前冻住的
#   `position.value` 显式传下来（`resumeAt`）。判据三条：
#     ① `就地重建: 开始` 的条数 —— 本局重建过几次。
#     ② 每条重建**自己的 option 块内**有没有 `Setting option 'start'`（带值见过没）。
#     ③ `落点 …ms 落后于 …ms，补一次 seek` 的条数 —— 丢点后落点校正会被触发
#        （`cdn_switch_mixin.dart` 的 `_restoreResumePosition`）。
#        ⚠️ 这行日志的**第一个数是播放器此刻的位置读数，第二个数才是目标**（发射点
#        `cdn_switch_mixin.dart:1708`：`落点 ${player.positionInMilliseconds}ms 落后于
#        ${target.inMilliseconds}ms`）—— **不是"差值"**。所以判据只数「**落点读数 >0ms**」
#        的那些：那是"播放器已经落在某个位置、但不是目标位置"的真落后；而「落点读数
#        0ms」是新装载刚起步、位置读数还没跟上的固有形态（此刻发起补 seek 是这套双保险
#        的正常动作，且常被 mpv `error running command` 顶掉 —— 最终落点由 `start`
#        决定，判据② 已经管住了）。这个口径是 **2026-10-12 据 log 17 定的**。
#        ⚠️ 老实说：现有 13 份存档里**每一发补 seek 的落点读数都是 0ms**，所以这条扣分
#        路径在现有存档上**一次都没触发过** —— ③ 目前只是背景信息，log 14 的「红」完全
#        由判据② 扛着（3 次该带 start 的重建只带了 1 次）。
#
#   会骗人的形态（判据②**必须**限定窗口，跨全篇数会被污染）：
#     * 换源路 / `refreshPlayer`（硬解会话失效）**平时也打** `Setting option 'start'`，
#       而且常是**毫秒值**（`898.880`、`3.033`，来自 `media.copyWith(start:)` 那条更细
#       的路）。log 16 全篇就只有一条 `3.033`、而那一局**零重建** —— 不限定窗口就会把
#       这一条错记成「重建带了 start」。（log 11 那次重建也带 `898.880`，同属换源路
#       形态，**不是**本次修复的整秒值。）
#     * 所以窗口取「重建行 → 它那次 option 块的收尾行（`Set property: sid="no" -> 1`）」，
#       而不是一个拍脑袋的固定行数 —— 窗口由日志自己的结构兜住。
#     * 判据③ **也只数落在重建窗口内、「落点读数 >0ms」的**（与手册 F 节同口径）。换源路本来
#       就有落点校正这套双保险，它常发生在**首次重建之前**（log 13 那局唯一一发补 seek
#       就在重建前）—— 按全篇数会把「修好的一局」误判成未生效。全篇条数照样打印，只作背景。
#
#   两条**不能算功劳、必须剔除**的（脚本会在 ② 统计处标出来）：
#     * 修复前本来就带 start 的那次：log 14 第一次的 `704.000`，`defaultST` 恰好非零，
#       跟本次修复无关 —— 所以判据②看的是**比例**（几条要求带、带了几条），不是
#       「>0 就算修好了」。
#     * 第 **2/2** 次重建丢点**不判失败**：`PlayerTuning.noVideoRebuildMax = 2`，同一次自愈里第 2
#       次重建读到的 `position.value` 已被新一轮的 0 事件推翻，`resumeAt` 回落，
#       这一次天然救不了（`lib/utils/resume_seek.dart` 里写明了）。脚本对「第 2/2 次」
#       且缺 start 的**只记不判负**（不计入判据②的分母）。
#
#   ⚠️ 一条**必须知道**的局限：判据 ②③ 在**修复前的日志上也可能全绿**。
#     log 11（1/1）与 log 13（3/3）就是修复前的局，照样读「B 生效」—— 因为重建那几次
#     `defaultST` 恰好非零、且没触发窗口内的落点校正，**运气**替修复顶了班。
#     所以：**绿 = 不能反证修复无效，红 = 铁证还没修好**。唯一干净的「修复前」基准是
#     log 14（1/3，三次里两次丢点）。真机跑新包时，修复的形态是「**每一次**重建都带
#     整秒 start」——运气给不了这个，`resumeAt` 让 start 不再依赖 `defaultST`。
#     （诊断价值不受影响：这条局限只影响“回看旧日志”，不影响新包真机取证。）
#
#   落点怎么读（`playback restart complete @ X`）：
#     「起播落点」= 重建块收尾之后的第一发 —— **这才是新 player 自己落在哪**，判据②
#     缺 start 的那几次，就是它掉到 0 的。后面还有几发（落点校正 / CDN 切换再装载）
#     也会列出来，但它们不是初始 start：log 14 第 2 次就是靠随后那一发才落到 763
#     （README 记的「1237→763、倒退 474 秒」），第 3 次随后那发把 0 又带回 29。所以
#     两处都列、都算相对「检测位置」的净变化，别只看一个数。
# =============================================================================
set -u

file="${1:-}"
if [ -z "$file" ]; then
  echo "用法: $0 <pili-console 日志文件>" >&2
  exit 2
fi
if [ ! -f "$file" ]; then
  echo "找不到文件: $file" >&2
  exit 2
fi

awk '
# ---- 小工具 ---------------------------------------------------------------
function num(s) {                    # 从含中文/空格的片段里抠出数字；挖不到 → -1
  if (s == "") return -1
  gsub(/[^0-9]/, "", s)
  return (s == "") ? -1 : s + 0
}
function f6(x) { return sprintf("%.6f", x) }
function delta(pv, land) {           # 落点相对「检测位置」的净变化：落到后面 = 倒退
  d = land - pv
  if (d < -0.5) return sprintf("倒退 %d 秒", int(-d + 0.5))
  if (d > 0.5)  return sprintf("前进 %d 秒", int(d + 0.5))
  return "落到原处"
}

# ---- 第一遍：把事件按行号收集起来（窗口要事后才能算，见 END）--------------
{
  line = $0
  nr   = NR
  ts   = $1

  # 1) 重建行：起一条新记录 + 快照「重建前位置」
  if (line ~ /就地重建: 开始/) {
    n++
    rb_line[n] = nr
    rb_ts[n]   = ts
    rb_k[n]    = ""; rb_N[n] = ""
    if (match(line, /第 [0-9]+\/[0-9]+ 次/)) {
      s = substr(line, RSTART, RLENGTH)            # "第 1/2 次"
      split(s, b, " ")
      split(b[2], aim, "/")
      rb_k[n] = aim[1]; rb_N[n] = aim[2]
    }
    rb_pre[n]      = pre_pos                       # 紧邻其前最后一条「无视频轨」
    rb_pre_line[n] = pre_line
    inblock = 1
    cur     = n
    next
  }

  # 2) 重建块内：pause 对 + start + 块收尾行
  if (inblock) {
    if (line ~ /Set property: pause=true -> 1/)  a_true[cur]  = nr
    if (line ~ /Set property: pause=false -> 1/) a_false[cur] = nr
    if (line ~ /Setting option .start./) {
      b_start_line[cur] = nr
      if (match(line, /'\''[0-9.]+'\''/)) b_start_val[cur] = substr(line, RSTART+1, RLENGTH-2)
    }
    if (line ~ /Set property: sid="no" -> 1/) { block_end[cur] = nr; inblock = 0 }
    else if (nr - rb_line[cur] > 60)          { block_end[cur] = nr; inblock = 0 }
  }

  # 3) 「无视频轨」报的位置（下一个重建的「重建前位置」就是它）
  if (line ~ /无视频轨: 音频正常但画面始终为空/) {
    if (match(line, /位置 [0-9]+s/)) {
      pre_pos  = num(substr(line, RSTART, RLENGTH))
      pre_line = nr
    }
  }

  # 4) 所有落点（先不问窗口，END 里再筛）
  if (line ~ /playback restart complete @/) {
    if (match(line, /@ [0-9]+\.[0-9]+/)) {
      rn++
      rst_line[rn]   = nr
      rst_val[rn]    = substr(line, RSTART+2, RLENGTH-2) + 0
      rst_paused[rn] = (line ~ /\(paused\)/) ? 1 : 0     # "…(paused)" 是 A 缺陷的旁证
    }
  }

  # 5) 所有 Setting option start（用来算块外的「污染源」，也是「新装载」的边界）
  if (line ~ /Setting option .start./) {
    sn++
    st_line[sn] = nr
    if (match(line, /'\''[0-9.]+'\''/)) st_val[sn] = substr(line, RSTART+1, RLENGTH-2)
  }

  # 6) 补 seek（落点校正）—— 顺手抠出「落点 Nms」那个数：判据③只看 N>0 的，
  #    N==0 说明落点本来就在正确位置（mpv 把 seek 顶掉时的瞬时读数），不扣分。
  if (line ~ /落后于 .*ms，补一次 seek/) {
    kn++
    seek_line[kn] = nr
    seek_ts[kn]   = ts
    if (match(line, /落后于 [0-9]+ms/)) seek_tgt[kn] = num(substr(line, RSTART, RLENGTH))
    if (match(line, /落点 [0-9]+ms/))   seek_delta[kn] = num(substr(line, RSTART, RLENGTH))
  }

  # 7) 块外：留一对 pause 当「正常起播」对照；顺手数裸 pause（用户按键）
  if (!inblock) {
    if (line ~ /Set property: pause=true -> 1/) ctl_true = nr
    else if (line ~ /Set property: pause=false -> 1/) {
      if (ctl_true != "" && !ctl_shown) { ctl_a = ctl_true; ctl_b = nr; ctl_shown = 1 }
      ctl_true = ""
    }
    if (line ~ /Set property: pause -> [0-9]+/) bare_pause++
  }
}

# ---- 第二遍：判定 ---------------------------------------------------------
END {
  printf "\n==== 就地重建验收: %s ====\n", FILENAME
  printf "行数 %d；`就地重建: 开始` %d 条；全篇 `Setting option '\''start'\''` %d 条\n", NR, n, sn

  # 块外的 start（换源路/refreshPlayer）—— 演示「跨全篇数判据②会被污染」
  out_start = 0; out_start_ms = 0
  for (j = 1; j <= sn; j++) {
    inbox = 0
    for (i = 1; i <= n; i++)
      if (st_line[j] >= rb_line[i] && block_end[i] != "" && st_line[j] <= block_end[i]) { inbox = 1; break }
    if (!inbox) {
      out_start++
      if (st_val[j] != "" && st_val[j] !~ /\.000$/) out_start_ms++
    }
  }

  # =========================================================================
  # A. 暂停对
  # =========================================================================
  printf "\n--- A. 376bc8092「重建后别把在播恢复成暂停」 ---\n"
  printf "判据: 重建块的 option 里应成对 pause=true -> 1 与**随后的** pause=false -> 1\n"

  a_bad = 0; a_ok = 0; a_unk = 0
  for (i = 1; i <= n; i++) {
    kk = (rb_k[i] == "") ? "?" : rb_k[i]
    NN = (rb_N[i] == "") ? "?" : rb_N[i]
    printf "\n  [重建 #%d] %s  第 %s/%s 次  (行 %d)\n", i, rb_ts[i], kk, NN, rb_line[i]
    printf "      块: 行 %d → %s\n", rb_line[i], (block_end[i] == "" ? "(未闭合)" : block_end[i])
    if (a_true[i] == "" && a_false[i] == "") {
      printf "      暂停对: [?] 块内既无 pause=true 也无 pause=false —— 这次没跑到 option 块，无法判定\n"
      a_unk++
    } else if (a_false[i] == "") {
      printf "      暂停对: [缺] 只有 pause=true @%d 行，**没有**随后的 pause=false\n", a_true[i]
      printf "              → 装载完停在暂停，重建后在播的视频会变暂停（A 未生效的形态）\n"
      a_bad++
    } else {
      printf "      暂停对: [有] pause=true @%d 行 + pause=false @%d 行  → 在播起播\n", a_true[i], a_false[i]
      a_ok++
    }
  }
  if (ctl_shown)
    printf "\n  块外对照（正常起播/换源重开，同样成对）: pause=true @%d 行 + pause=false @%d 行\n", ctl_a, ctl_b
  # ⚠️ 用户自己的暂停也会写 mpv 的 pause（log 14 的 20:32:04.987 就是 `pause=true -> 1`），
  # 所以裸 pause 的条数只是个**旁证**：真正判 A 只看重建块内那对（块只跨 ~10ms，
  # 人按不进去）。
  printf "  全篇裸 `Set property: pause -> N`（运行时属性设置，按键多长这样）: %d 条%s\n", \
         bare_pause+0, ((bare_pause > 0) ? "  ← 有；判 A 前先想一下会不会是用户按的" : "")

  if (n == 0) {
    printf "\n  A 判定: 不适用（本局没有就地重建，A 无从触发）\n"
    a_verdict = "不适用"
  } else if (a_bad > 0) {
    printf "\n  A 判定: 未生效 —— %d 次重建里 %d 次缺配对的 pause=false\n", n, a_bad
    a_verdict = "未生效"
  } else if (a_unk > 0) {
    printf "\n  A 判定: 无法判定 —— %d 次重建没跑到 option 块\n", a_unk
    a_verdict = "无法判定"
  } else {
    printf "\n  A 判定: 生效 —— %d 次重建全部成对带 pause=false\n", a_ok
    a_verdict = "生效"
  }

  # =========================================================================
  # B. 续播点
  # =========================================================================
  printf "\n--- B. 74c9c7c4b「就地重建不再丢续播点」 ---\n"
  printf "判据: ② 每条重建自己的 option 块内应带 Setting option '\''start'\''；③ 补 seek 应为 0\n"
  printf "① 重建次数 = %d\n", n
  printf "\n  ② 逐条重建的起播点 / 位置（行号即证据）:\n"

  b_need = 0; b_have = 0
  for (i = 1; i <= n; i++) {
    kk = (rb_k[i] == "") ? "?" : rb_k[i]
    NN = (rb_N[i] == "") ? "?" : rb_N[i]
    excused = (kk == NN && kk != "" && kk != "?")       # 第 2/2 次 → 丢点不判失败
    printf "\n  [重建 #%d] %s  第 %s/%s 次  (行 %d)%s\n", i, rb_ts[i], kk, NN, rb_line[i], \
           (excused ? "   ← 第 2/2 次，丢点不判失败" : "")
    if (b_start_val[i] != "") {
      form = (b_start_val[i] ~ /\.000$/) ? "整秒形态（本次修复那条路）" : \
             "毫秒形态（换源路/refreshPlayer 那种，不是本次修复的）"
      zero = (b_start_val[i] == "0.000") ? "  ⚠️ 值为 0，等于没有续播点" : ""
      printf "      起播点: [有] Setting option '\''start'\'' = '\''%s'\'' @%d 行   (%s)%s\n", \
             b_start_val[i], b_start_line[i], form, zero
    } else {
      printf "      起播点: [缺] 块内**没有** Setting option '\''start'\''（seek 落到 null → 从 0 起播）\n"
    }
    pv = rb_pre[i] + 0
    printf "      检测位置: %s @%d 行（重建前最后一条 `无视频轨` 报的）\n", \
           ((rb_pre[i] == "" || pv < 0) ? "?" : rb_pre[i] "s"), rb_pre_line[i]+0

    # 这一段的窗口：[块收尾, 下一个重建行) —— 右界只到下一次重建。
    # 不拿「下一个 Setting option start」当右界：重建 episode 内部本来就会再来一次
    # 带 start 的装载（CDN 切换重开，log 14 的 605 行就是），拿它当界会把今回自己的
    # 落点也挡掉。代价是窗口偶尔跨到后面别条媒体的装载，所以下面把「往前跳」的落点
    # 单独标出来 —— 那才是位置跳变/遥测失真，不是续播点落点。
    low  = (block_end[i] == "" ? rb_line[i] : block_end[i])
    high = (i < n) ? rb_line[i+1] : NR + 1
    c = 0; lastv = -1
    for (k = 1; k <= rn; k++) {
      if (rst_line[k] > low && rst_line[k] < high) {
        if (rst_val[k] == lastv) continue            # 同一落点反复报，去重
        c++; wv[c] = rst_val[k]; wl[c] = rst_line[k]; wp[c] = rst_paused[k]; lastv = rst_val[k]
      }
    }
    if (c == 0) {
      printf "      落点: (窗口内没有新的 playback restart complete)\n"
    } else {
      printf "      起播落点: %s @%d 行  %s%s   ← 新 player 自己落在哪\n", f6(wv[1]), wl[1], delta(pv, wv[1]), \
             (wp[1] ? "  ← paused" : "")
      for (k = 2; k <= c && k <= 4; k++) {
        why = (wv[k] - pv > 5) ? "位置往前跳了，是跳变/遥测失真，不是落点校正的结果" : \
                                 "落点校正/CDN 再装载带的，不是新 player 的初始 start"
        printf "      随后落点: %s @%d 行  %s%s   ← %s\n", \
               f6(wv[k]), wl[k], delta(pv, wv[k]), (wp[k] ? "  ← paused" : ""), why
      }
    }
    # 带了 start 却没落在检测位置 —— 这正是 74c9c7c4b 有意留给真机验收的那格
    # （重建路没做落点校正，理由见 commit「未做（有意）」）
    if (c >= 1 && b_start_val[i] != "" && pv >= 0) {
      dev = wv[1] - pv; if (dev < 0) dev = -dev
      if (dev > 3)
        printf "      ⚠️ 带了 start 但落点没落在检测位置（差 %d 秒）—— 「落点准不准」正是本次\n" \
               "         修复留给真机验收的那一格（重建路不做落点校正）；出现大偏离才需要照抄换源路那套\n", \
               int(dev + 0.5)
    }
    if (!excused) { b_need++; if (b_start_val[i] != "") b_have++ }
  }

  printf "\n  ② 统计: 要求带 start 的重建 %d 次，实带 %d 次%s\n", b_need, b_have, \
         ((b_need > 0 && b_have < b_need) ? "   ← 没带的就是丢续播点的那几次" : "")
  printf "      ⚠️ 修复前本来就带 start 的那次不能算功劳（log 14 第一次的 704.000，defaultST\n"
  printf "         恰好非零）—— 判据看的是比例，不是 >0 就算修好。\n"

  printf "\n  ③ 补 seek（`落点 …ms 落后于 …ms`）: 共 %d 条（判定只数落在重建窗口内**且落点读数 >0ms** 的）\n", kn+0
  kn_win  = 0     # 窗口内且「落点读数 >0ms」—— 玩家落在别处，真的落后，判定计数
  kn_win0 = 0     # 窗口内但「落点读数 0ms」—— 新装载刚起步的固有形态，不扣分
  kn_out  = 0     # 窗口外 —— 换源路/复位自己的落点校正
  for (k = 1; k <= kn; k++) {
    inwin = 0
    for (i = 1; i <= n; i++) {
      wlo = rb_line[i]
      whi = (i < n) ? rb_line[i+1] : NR + 1
      if (seek_line[k] >= wlo && seek_line[k] < whi) { inwin = 1; break }
    }
    sd = seek_delta[k] + 0
    if (!inwin) {
      kn_out++
      printf "       行 %-5d %s  落后于 %sms   ← 窗口外，换源路/复位的落点校正，不计\n", \
             seek_line[k], seek_ts[k], seek_tgt[k]+0
    } else if (sd > 0) {
      kn_win++
      printf "       行 %-5d %s  落后于 %sms   ← 落在重建窗口内，落点读数 %dms（>0，落在别处）—— 判定计数\n", \
             seek_line[k], seek_ts[k], seek_tgt[k]+0, sd
    } else {
      kn_win0++
      printf "       行 %-5d %s  落后于 %sms   ← 落在重建窗口内，落点读数 0ms（新装载起始），不扣分\n", \
             seek_line[k], seek_ts[k], seek_tgt[k]+0
    }
  }
  if (kn_win0 > 0) {
    printf "      ⚠️ 窗口内那 %d 发补 seek 的落点读数都是 0ms（新装载刚起步、位置还没跟上；这套\n", kn_win0
    printf "         双保险此刻发起补 seek 属正常，且常被 mpv 顶掉）—— 按 2026-10-12 据 log 17 定的\n"
    printf "         口径不算「续播点没到位」，不进判定；最终落点看判据② 的 start 与 restart 落点。\n"
  }
  if (kn_out > 0) {
    printf "      ⚠️ 窗口外那 %d 发是换源路自己的落点校正（那条路本来就有这套双保险，见\n", kn_out
    printf "         手册 F 节）：换源路在**首次重建之前**发生，与重建丢点无关，因此不计入判定。\n"
  }

  printf "\n  全篇 start 共 %d 条，块外 %d 条（换源路/refreshPlayer，含 %d 条毫秒形态）\n", \
         sn, out_start, out_start_ms+0
  if (out_start > 0)
    printf "      —— 跨全篇数判据②会把这几条块外的错记成「重建带了点」\n"

  if (n == 0) {
    printf "\n  B 判定: 不适用（本局没有就地重建，B 无从触发）\n"
    b_verdict = "不适用"
  } else if (b_have < b_need) {
    printf "\n  B 判定: 未生效 —— %d 次该带 start 的重建里只带了 %d 次\n", b_need, b_have
    b_verdict = "未生效"
  } else if (kn_win > 0) {
    printf "\n  B 判定: 未生效 —— 重建都带点了，但重建窗口内仍有 %d 发补 seek（落点读数 >0 却仍落后，续播点没一次到位）\n", kn_win
    b_verdict = "未生效"
  } else {
    printf "\n  B 判定: 生效 —— %d 次重建全部带 start，且重建窗口内 0 发「落点读数 >0 却仍落后」的补 seek\n", b_have
    if (kn_win0 > 0)
      printf "      （窗口内另有 %d 发补 seek 的落点读数为 0ms，按口径不计）\n", kn_win0
    if (kn_out > 0)
      printf "      （全篇另有 %d 发窗口外的补 seek，属换源路，不计）\n", kn_out
    b_verdict = "生效"
  }

  # =========================================================================
  printf "\n==== 总评 (%s) ====\n", FILENAME
  if (n > 0)
    printf "A(暂停对) %s   B(续播点) %s   [重建 %d 次 / 带点 %d/%d / 补 seek 计分 %d · 窗内 %d · 全篇 %d]\n", \
           a_verdict, b_verdict, n, b_have, b_need, kn_win+0, kn_win+kn_win0, kn+0
  else
    printf "A(暂停对) %s   B(续播点) %s   [本局零重建]\n", a_verdict, b_verdict
}
' "$file"
