// ignore_for_file: constant_identifier_names

//https://github.com/yujincheng08/BiliRoaming/blob/master/app/src/main/res/values/strings_raw.xml
//https://github.com/yujincheng08/BiliRoaming/blob/master/app/src/main/res/values/arrays.xml

enum CDNService {
  baseUrl('基础URL（不推荐）'),
  backupUrl('备用URL'),
  ali('ali（阿里云）', 'upos-sz-mirrorali.bilivideo.com'),
  cos('cos（腾讯云）', 'upos-sz-mirrorcos.bilivideo.com'),
  hw('hw（华为云，融合CDN）', 'upos-sz-mirrorhw.bilivideo.com'),
  tf_hw('tf_hw（华为云）', 'upos-tf-all-hw.bilivideo.com'),
  tf_tx('tf_tx（腾讯云）', 'upos-tf-all-tx.bilivideo.com'),
  akamai('akamai（Akamai海外）', 'upos-hz-mirrorakam.akamaized.net'),
  akamai_sz('akamai_sz（Akamai）', 'upos-sz-mirrorakam.akamaized.net'),
  aliov('aliov（阿里云海外）', 'upos-sz-mirroraliov.bilivideo.com'),
  cosov('cosov（腾讯云海外）', 'upos-sz-mirrorcosov.bilivideo.com'),
  hwov('hwov（华为云海外）', 'upos-sz-mirrorhwov.bilivideo.com'),
  ;

  final String desc;
  final String? host;

  const CDNService(this.desc, [this.host]);

  /// DNS 上根本不存在的镜像，永远不该进候选窗口。
  ///
  /// 2026-10-11 实测，`akamai_sz` 与 `hwov` 这两个主机名在**四个**解析器下
  /// （系统、223.5.5.5、119.29.29.29、8.8.8.8）全部返回 **NXDOMAIN**：
  ///
  ///   - `upos-sz-mirrorakam.akamaized.net` —— 注意兄弟条目 `akamai` 的
  ///     `upos-hz-mirrorakam.akamaized.net` 是**正常解析**的（它的问题是换
  ///     host 之后 403，那另外有 `CdnTuning.deadRetryAfter` 管）；
  ///   - `upos-sz-mirrorhwov.bilivideo.com` —— CNAME 指向
  ///     `…0979c69f.cdnhwcgqa21.com`，而那个目标没有 A 记录。
  ///
  /// `cosov` / `aliov`（另外两个海外条目）都正常解析到 IP，所以这不是
  /// "海外镜像全挂了"，更不是本地网络或 VPN —— 是表里的死数据，重试无用。
  /// 候选位只有两个（`CdnSpeedTest.autoCandidatesMax`），让它们每轮占一个
  /// 位子等于把探测能力砍掉一半，还白赔两次 3 秒超时。
  ///
  /// **只从候选筛选里排除，不删枚举项**：`CDNService` 是按名字存进 Hive 的，
  /// 删项会让旧设置读不出来。
  static const Set<CDNService> knownDead = {akamai_sz, hwov};
}

// from https://rec.danmuji.org/dev/cdn-info/
// {
//     'cn-ahwh-ct-': {'01': 16},
//     'cn-cq-ct-': {'01': 35, '02': 2},
//     'cn-gddg-ct-': {'01': 36},
//     'cn-gdfs-ct-': {'01': 28},
//     'cn-hblf-ct-': {'01': 21},
//     'cn-hbyc-ct-': {'02': 35},
//     'cn-hljheb-ct-': {'01': 12},
//     'cn-hnld-ct-': {'01': 56},
//     'cn-jsnt-ct-': {'01': 52},
//     'cn-jsyz-ct-': {'03': 52},
//     'cn-jxjj-ct-': {'01': 14},
//     'cn-sccd-ct-': {'01': 32},
//     'cn-sxxa-ct-': {'03': 14},
//     'cn-xj-ct-': {'01': 6},
//     'cn-zjjh-ct-': {'04': 37},
//     'cn-gddg-cu-': {'01': 15},
//     'cn-hncs-cu-': {'01': 14, 'v': 6},
//     'cn-hnly-cu-': {'01': 35},
//     'cn-jlcc-cu-': {'03': 16},
//     'cn-jstz-cu-': {'01': 14},
//     'cn-lnsy-cu-': {'01': 9, 'v': 4},
//     'cn-nmghhht-cu-': {'01': 15, 'v': 11},
//     'cn-sccd-cu-': {'01': 13},
//     'cn-sdqd-cu-': {'01': 25},
//     'cn-sxty-cu-': {'03': 10},
//     'cn-sxxa-cu-': {'02': 8},
//     'cn-zjhz-cu-': {'01': 8, 'v': 6},
//     'cn-cq-cm-': {'01': 30},
//     'cn-fjqz-cm-': {'01': 10},
//     'cn-gddg-cm-': {'01': 14},
//     'cn-gdst-cm-': {'01': 17},
//     'cn-hbsjz-cm-': {'02': 16},
//     'cn-hbwh-cm-': {'01': 23},
//     'cn-hncs-cm-': {'03': 24},
//     'cn-hnzz-cm-': {'01': 16},
//     'cn-jssz-cm-': {'01': 24, '02': 62},
//     'cn-jxnc-cm-': {'01': 20},
//     'cn-lnsy-cm-': {'01': 11},
//     'cn-nmghhht-cm-': {'01': 5},
//     'cn-sccd-cm-': {'03': 26},
//     'cn-sdjn-cm-': {'02': 14},
//     'cn-sxxa-cm-': {'01': 14},
//     'cn-tj-cm-': {'02': 16},
//     'cn-xj-cm-': {'02': 6},
//     'cn-zjhz-cm-': {'01': 29},
//     'cn-cq-gd-': {'01': 20},
//     'cn-gdgz-gd-': {'01': 20},
//     'cn-gzgy-gd-': {'01': 6},
//     'cn-hb-gd-': {'01': 4},
//     'cn-hbwh-gd-': {'01': 6},
//     'cn-hljheb-gd-': {'01': 2},
//     'cn-hncs-gd-': {'01': 8},
//     'cn-jlcc-gd-': {'01': 5},
//     'cn-jsnj-gd-': {'01': 8},
//     'cn-zjhz-gd-': {'02': 2},
//     'cn-bj-fx-': {'01': 6},
//     'cn-fjfz-fx-': {'01': 6},
//     'cn-gdgz-fx-': {'01': 18},
//     'cn-hbwh-fx-': {'01': 16},
//     'cn-hncs-fx-': {'01': 6},
//     'cn-hnzz-fx-': {'01': 8},
//     'cn-jsnj-fx-': {'02': 6},
//     'cn-sccd-fx-': {'01': 6},
//     'cn-sdjn-fx-': {'01': 6},
//     'cn-sh-fx-': {'01': 10},
//     'cn-tj-fx-': {'01': 6},
//     'cn-bj-se-': {'01': 8},
//     'cn-bj-cc-': {'03': 18},
//     'cn-gdfs-cc-': {'02': 21},
//     'cn-sh-cc-': {'01': 15},
//     'cn-zjhz-wasu-': {'03': 21, '04': 12},
//     'cn-sh-ix-': {'01': 13},
//     'cn-hk-eq-': {'01': 14}
// }
