import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 短剧「预加载部数」的持久化配置（0–5，默认 2）。
///
/// 预加载 = 为 feed 里接下来的 N 部提前解析播放地址，并为没有观看历史
/// 的新剧创建「已 prepare（缓冲首段数据）但未播放」的播放器停进共享池；
/// 刷到时走池内复用路径，近乎无缝起播。有历史的剧会续看第 N 集，预热
/// 固定装第 1 集，因此那类只预取地址不建播放器。
///
/// 内存代价：每个驻留播放器约占几十 MB（解码器 + 首段缓冲）；官方
/// `ShortPlayerSharePool` 固定容量 3（约等于默认值 2 的形态），本仓库放开
/// 给用户配，池容量随之 = max(3, N+1)。
class DramaPreheatPreferences {
  DramaPreheatPreferences._();

  static final DramaPreheatPreferences instance = DramaPreheatPreferences._();

  static const _key = 'drama_preheat_count';
  static const maxCount = 5;
  static const defaultCount = 2;

  /// 当前预加载部数。load() 完成前读默认值。
  final ValueNotifier<int> count = ValueNotifier<int>(defaultCount);

  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final sp = await SharedPreferences.getInstance();
      final stored = sp.getInt(_key);
      count.value =
          stored == null ? defaultCount : stored.clamp(0, maxCount);
    } catch (_) {
      // 读取失败按默认值处理，不拖启动。
    }
  }

  /// 忘掉已加载状态，让下一次 [load] 重新读。只为测试存在
  /// （与 DramaMutePreferences.resetForTest 同款理由）。
  @visibleForTesting
  void resetForTest() {
    _loaded = false;
    count.value = defaultCount;
  }

  Future<void> set(int value) async {
    final clamped = value.clamp(0, maxCount);
    count.value = clamped;
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setInt(_key, clamped);
    } catch (_) {
      // 持久化失败只影响下次启动的初值，本次会话仍生效。
    }
  }

  /// 共享池容量：在播 1 部不占池（parked 才占），预热 N 部 + 回滑余量。
  /// 下限 3 保持官方形态（默认 2 时与官方完全一致）。
  int get poolCapacity => (count.value + 1).clamp(3, maxCount + 1);
}
