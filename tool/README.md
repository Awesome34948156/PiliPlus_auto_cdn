# tool

## jnigen

`dart run tool/jnigen.dart`

## arch_check

分层 ratchet，防止循环依赖与"底层反向依赖页面层"回退。

```sh
dart run tool/arch_check.dart                 # 与基线比较
dart run tool/arch_check.dart --update        # 用当前指标重写基线
dart run tool/arch_check.dart --baseline P    # 指定另一份基线
```

退出码：`0` 通过；`1` 任一 gated 指标大于基线；`2` 参数、IO 或基线格式错误。
`--update` 是唯一会写 `tool/arch_baseline.json` 的方式，日常检查不要用它。

### 建图与指标

节点是 `lib/` 下的 `.dart` 文件，排除 `lib/grpc/`、`lib/common/widgets/flutter/`、
`*.g.dart` 与 `*.freezed.dart`。边是行首的 `import`/`export`：

- `package:PiliPlus/x` 解析为 `lib/x`；
- 相对路径按源文件目录解析；
- `dart:` 与外部 package 忽略；
- 两端都在节点集里才保留，同一对 `(src, dst)` 只记一条。

用 Kosaraju 求强连通分量（SCC），输出七个指标：

| 指标 | 含义 | 是否 gate |
|---|---|---|
| `nodes` / `edges` | 节点数 / 边数 | 否（代码增长不拦） |
| `scc_gt1` | 规模大于 1 的 SCC 个数 | 否 |
| `max_scc_size` | 最大 SCC 的文件数 | **是** |
| `max_scc_internal_edges` | **最大 SCC 内部**的边数 | **是** |
| `low_level_files_importing_pages` | 六个底层目录（`utils/`、`models/`、`models_new/`、`common/`、`services/`、`http/`）中，有 import 指向 `lib/pages/` 的文件数 | **是** |
| `low_level_imports_into_pages` | 上述 import 的条数 | **是** |

> 体检报告里的 **2,413** 是五个 SCC 的内部边**总和**（2,405 + 四个 2 文件小环各 2 条）。
> ratchet gate 的是**最大 SCC** 的内部边数，所以基线是 **2,405**，不是 2,413。

基线对应提交 `d3f00658f`。只允许下降；确实有意增加时，先确认 diff，再 `--update`。
仓库暂时没有 PR CI，门禁靠本地运行。
