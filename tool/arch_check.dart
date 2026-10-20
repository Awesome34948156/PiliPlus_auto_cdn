// 分层 ratchet：只允许"最大强连通分量内部边数"和"底层反向依赖页面层"下降。
//
// 用法：
//   dart run tool/arch_check.dart                 # 与基线比较，超了退出 1
//   dart run tool/arch_check.dart --update        # 用当前指标重写基线
//   dart run tool/arch_check.dart --baseline P    # 指定另一份基线
//
// 退出码：0 通过；1 任一 gated 指标大于基线；2 参数/IO/基线格式错误。
//
// 指标定义见 `tool/README.md`。这里刻意不依赖 `package:analyzer`：import/export
// 只需要行首正则，拉起完整解析器既慢又会在语言版本升级时漂移。

import 'dart:convert';
import 'dart:io';

const _defaultBaselinePath = 'tool/arch_baseline.json';

/// 与报告一致：这些目录不参与建图。
const _excludedPrefixes = [
  'lib/grpc/',
  'lib/common/widgets/flutter/',
];
const _excludedSuffixes = ['.g.dart', '.freezed.dart'];

/// "底层"的六个目录（见体检报告 §4.2）。
const _lowLevelPrefixes = [
  'lib/utils/',
  'lib/models/',
  'lib/models_new/',
  'lib/common/',
  'lib/services/',
  'lib/http/',
];
const _pagesPrefix = 'lib/pages/';

/// 只有这四项参与 ratchet。节点数、边数、SCC 个数只记录：代码总量增长本身
/// 不该把门禁弄红。
const _gatedMetrics = [
  'max_scc_size',
  'max_scc_internal_edges',
  'low_level_files_importing_pages',
  'low_level_imports_into_pages',
];

const _allMetrics = [
  'nodes',
  'edges',
  'scc_gt1',
  'max_scc_size',
  'max_scc_internal_edges',
  'low_level_files_importing_pages',
  'low_level_imports_into_pages',
];

void main(List<String> args) {
  String baselinePath = _defaultBaselinePath;
  var update = false;
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '--update') {
      update = true;
    } else if (arg == '--baseline') {
      if (i + 1 >= args.length) _usage('--baseline 缺少路径');
      baselinePath = args[++i];
    } else if (arg == '--help' || arg == '-h') {
      _usage();
    } else {
      _usage('未知参数：$arg');
    }
  }

  final Map<String, int> current;
  try {
    current = _computeMetrics();
  } on FileSystemException catch (e) {
    stderr.writeln('arch_check: 读取源码失败：$e');
    exit(2);
  }

  if (update) {
    final baseline = <String, Object>{
      'commit': _headCommit(),
      'date': _today(),
      'method':
          'import/export graph over lib/, excluding lib/grpc/ and '
          'lib/common/widgets/flutter/ plus *.g.dart and *.freezed.dart; '
          'Kosaraju SCC; edges deduplicated per (src, dst).',
      'metrics': {for (final k in _allMetrics) k: current[k]},
    };
    final file = File(baselinePath);
    try {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(baseline)}\n',
      );
    } on FileSystemException catch (e) {
      stderr.writeln('arch_check: 写入基线失败：$e');
      exit(2);
    }
    stdout.writeln('arch_check: 已更新基线 $baselinePath');
    _printMetrics(current);
    exit(0);
  }

  final Map<String, int> baseline;
  try {
    baseline = _loadBaseline(baselinePath);
  } on FormatException catch (e) {
    stderr.writeln('arch_check: 基线格式错误（$baselinePath）：${e.message}');
    exit(2);
  } on FileSystemException catch (e) {
    stderr.writeln('arch_check: 读取基线失败（$baselinePath）：$e');
    exit(2);
  }

  _printMetrics(current);
  var failed = false;
  for (final key in _gatedMetrics) {
    final before = baseline[key];
    final now = current[key]!;
    if (before == null) {
      stderr.writeln('arch_check: 基线缺少指标 $key');
      exit(2);
    }
    final status = now > before
        ? 'FAIL'
        : now < before
        ? 'improved'
        : 'ok';
    stdout.writeln(
      '  ${key.padRight(32)} $now <= $before  $status',
    );
    if (now > before) failed = true;
  }

  if (failed) {
    stderr.writeln(
      'arch_check: 分层指标回退。若这是有意为之，确认后用 --update 重写基线。',
    );
    exit(1);
  }
  stdout.writeln('arch_check: 通过');
  exit(0);
}

Never _usage([String? message]) {
  if (message != null) stderr.writeln('arch_check: $message');
  stderr.writeln(
    'usage: dart run tool/arch_check.dart '
    '[--update] [--baseline <path>]',
  );
  exit(2);
}

Map<String, int> _computeMetrics() {
  final nodes = <String>{};
  for (final entity in Directory('lib').listSync(recursive: true)) {
    if (entity is! File) continue;
    final path = _normalize(entity.path);
    if (!path.endsWith('.dart')) continue;
    if (_excludedPrefixes.any(path.startsWith)) continue;
    if (_excludedSuffixes.any(path.endsWith)) continue;
    nodes.add(path);
  }

  final index = <String, int>{};
  final paths = nodes.toList()..sort();
  for (var i = 0; i < paths.length; i++) {
    index[paths[i]] = i;
  }

  final edgeSet = <int>{};
  final importPattern = RegExp(
    r'''^\s*(?:import|export)\s+['"]([^'"]+)['"]''',
    multiLine: true,
  );
  for (final source in paths) {
    final text = File(source).readAsStringSync();
    for (final match in importPattern.allMatches(text)) {
      final target = _resolve(source, match.group(1)!);
      if (target == null) continue;
      final to = index[target];
      if (to == null) continue;
      edgeSet.add(index[source]! * paths.length + to);
    }
  }

  final adjacency = List<List<int>>.generate(paths.length, (_) => <int>[]);
  for (final packed in edgeSet) {
    adjacency[packed ~/ paths.length].add(packed % paths.length);
  }

  final components = _stronglyConnectedComponents(adjacency);
  final componentOf = List<int>.filled(paths.length, -1);
  for (var c = 0; c < components.length; c++) {
    for (final node in components[c]) {
      componentOf[node] = c;
    }
  }

  var maxSize = 0;
  var maxComponent = -1;
  var sccGt1 = 0;
  for (var c = 0; c < components.length; c++) {
    final size = components[c].length;
    if (size > 1) sccGt1++;
    if (size > maxSize) {
      maxSize = size;
      maxComponent = c;
    }
  }

  var internalEdges = 0;
  for (final packed in edgeSet) {
    final from = packed ~/ paths.length;
    final to = packed % paths.length;
    if (componentOf[from] == maxComponent && componentOf[to] == maxComponent) {
      internalEdges++;
    }
  }

  var lowLevelFiles = 0;
  var lowLevelImports = 0;
  final filesWithEdges = <int>{};
  for (final packed in edgeSet) {
    final from = packed ~/ paths.length;
    final to = packed % paths.length;
    if (!_lowLevelPrefixes.any(paths[from].startsWith)) continue;
    if (!paths[to].startsWith(_pagesPrefix)) continue;
    lowLevelImports++;
    filesWithEdges.add(from);
  }
  lowLevelFiles = filesWithEdges.length;

  return {
    'nodes': paths.length,
    'edges': edgeSet.length,
    'scc_gt1': sccGt1,
    'max_scc_size': maxSize,
    'max_scc_internal_edges': internalEdges,
    'low_level_files_importing_pages': lowLevelFiles,
    'low_level_imports_into_pages': lowLevelImports,
  };
}

/// 把 import URI 解析成节点集合里的相对路径；外部依赖与 `dart:` 返回 null。
String? _resolve(String source, String uri) {
  if (uri.startsWith('dart:')) return null;
  if (uri.startsWith('package:PiliPlus/')) {
    return _normalize('lib/${uri.substring('package:PiliPlus/'.length)}');
  }
  if (uri.startsWith('package:')) return null;
  if (!uri.startsWith('.')) return null;
  return _normalize('${_dirname(source)}/$uri');
}

String _normalize(String path) {
  final parts = <String>[];
  for (final segment in path.split('/')) {
    if (segment.isEmpty || segment == '.') continue;
    if (segment == '..') {
      if (parts.isNotEmpty) parts.removeLast();
    } else {
      parts.add(segment);
    }
  }
  return parts.join('/');
}

String _dirname(String path) {
  final slash = path.lastIndexOf('/');
  return slash < 0 ? '' : path.substring(0, slash);
}

/// Kosaraju：两遍 DFS，第一遍按完成时间逆序，第二遍在反向图上收集分量。
List<List<int>> _stronglyConnectedComponents(List<List<int>> graph) {
  final n = graph.length;
  final visited = List<bool>.filled(n, false);
  final order = <int>[];

  void dfs(int start) {
    final stack = <(int, int)>[(start, 0)];
    visited[start] = true;
    while (stack.isNotEmpty) {
      final (node, next) = stack.last;
      if (next < graph[node].length) {
        stack[stack.length - 1] = (node, next + 1);
        final child = graph[node][next];
        if (!visited[child]) {
          visited[child] = true;
          stack.add((child, 0));
        }
      } else {
        stack.removeLast();
        order.add(node);
      }
    }
  }

  for (var i = 0; i < n; i++) {
    if (!visited[i]) dfs(i);
  }

  final reversed = List<List<int>>.generate(n, (_) => <int>[]);
  for (var from = 0; from < n; from++) {
    for (final to in graph[from]) {
      reversed[to].add(from);
    }
  }

  final assigned = List<bool>.filled(n, false);
  final components = <List<int>>[];
  for (var i = order.length - 1; i >= 0; i--) {
    final root = order[i];
    if (assigned[root]) continue;
    final component = <int>[];
    final stack = <int>[root];
    assigned[root] = true;
    while (stack.isNotEmpty) {
      final node = stack.removeLast();
      component.add(node);
      for (final parent in reversed[node]) {
        if (!assigned[parent]) {
          assigned[parent] = true;
          stack.add(parent);
        }
      }
    }
    component.sort();
    components.add(component);
  }
  return components;
}

Map<String, int> _loadBaseline(String path) {
  final decoded = jsonDecode(File(path).readAsStringSync());
  if (decoded is! Map<String, Object?>) {
    throw const FormatException('顶层必须是对象');
  }
  final metrics = decoded['metrics'];
  if (metrics is! Map<String, Object?>) {
    throw const FormatException('缺少 metrics 对象');
  }
  final result = <String, int>{};
  for (final key in _allMetrics) {
    final value = metrics[key];
    if (value is! int) {
      throw FormatException('metrics.$key 必须是整数');
    }
    result[key] = value;
  }
  return result;
}

void _printMetrics(Map<String, int> metrics) {
  stdout.writeln(
    'arch_check: ${_allMetrics.map((k) => '$k=${metrics[k]}').join(' ')}',
  );
}

String _headCommit() {
  try {
    final result = Process.runSync('git', ['rev-parse', '--short', 'HEAD']);
    if (result.exitCode == 0) return (result.stdout as String).trim();
  } on ProcessException {
    // 没有 git（比如源码包）时留 commit 为空，指标本身仍可复算。
  }
  return '';
}

String _today() {
  final now = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${now.year}-${two(now.month)}-${two(now.day)}';
}
