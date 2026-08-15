/// ZCode 远程设备条目。
///
/// URL 形如：
/// https://zcode.z.ai/remote/v4?sid=...&hash=...&t=...&mid=<机器ID>&name=<设备名>&app_version=...
class RemoteDevice {
  RemoteDevice({
    required this.id,
    required this.url,
    this.remark,
    required this.addedAt,
    required this.lastOpenedAt,
  });

  /// 唯一 ID：优先取 URL 里的 mid（机器 ID），取不到用时间戳生成。
  final String id;

  /// 完整连接地址（含 sid/hash 等凭证，敏感）。
  String url;

  /// 用户备注；为空时运行时尝试用 URL name 参数 / 页面标题兜底显示。
  String? remark;

  final DateTime addedAt;
  DateTime lastOpenedAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'url': url,
    'remark': remark,
    'addedAt': addedAt.toIso8601String(),
    'lastOpenedAt': lastOpenedAt.toIso8601String(),
  };

  factory RemoteDevice.fromJson(Map<String, dynamic> json) => RemoteDevice(
    id: json['id'] as String,
    url: json['url'] as String,
    remark: json['remark'] as String?,
    addedAt:
        DateTime.tryParse(json['addedAt'] as String? ?? '') ?? DateTime.now(),
    lastOpenedAt:
        DateTime.tryParse(json['lastOpenedAt'] as String? ?? '') ??
        DateTime.now(),
  );

  /// 从 URL query 中取 mid 参数。
  static String? midFromUrl(String raw) {
    try {
      return Uri.parse(raw.trim()).queryParameters['mid'];
    } catch (_) {
      return null;
    }
  }

  /// 从 URL query 中取 name 参数（Uri 已做 URL decode）。
  static String? nameFromUrl(String raw) {
    try {
      final name = Uri.parse(raw.trim()).queryParameters['name'];
      if (name != null && name.trim().isNotEmpty) return name.trim();
    } catch (_) {}
    return null;
  }

  /// 取 URL 的 host，用于最后的显示兜底。
  static String hostFromUrl(String raw) {
    try {
      return Uri.parse(raw.trim()).host;
    } catch (_) {
      return '';
    }
  }
}
