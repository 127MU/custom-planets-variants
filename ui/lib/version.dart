import 'dart:convert';
import 'dart:io';

/// 版本号只存在于发行包清单 `manifest.json`（由 `tools/package-rust.py` 从
/// `backend/Cargo.toml` 生成）。便携版与单文件版都把清单放在可执行文件同级，
/// 因此运行时读取清单即可，Dart 侧不再维护第二份版本号。
///
/// 开发环境（flutter run / flutter test）没有清单，返回空串；调用方需要
/// 自行决定展示与更新比较的兜底。
String readReleaseVersion({String? executable}) {
  try {
    final exe = executable ?? Platform.resolvedExecutable;
    final manifest = File(
      '${File(exe).parent.path}${Platform.pathSeparator}manifest.json',
    );
    if (!manifest.existsSync()) return '';
    final data = jsonDecode(manifest.readAsStringSync());
    if (data is! Map) return '';
    final version = data['version'];
    return version is String &&
            RegExp(r'^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$').hasMatch(version)
        ? version
        : '';
  } catch (_) {
    return '';
  }
}
