import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/media_item.dart';
import '../models/playlet_comment.dart';
import '../services/api_client.dart';
import '../services/backend_transport.dart' show BackendRequest;
import '../services/drama_preheat_preferences.dart';
import '../services/inline_video_playback.dart';
import '../services/library_store.dart';
import '../services/native_player.dart';
import '../services/player_history.dart';
import '../services/shelf_store.dart';
import '../widgets/home/home_media_card.dart' show StoryCover;
import '../widgets/player/playlet_comment_panel.dart';
import '../widgets/player/playlet_danmaku_layer.dart';
import '../widgets/player/playlet_danmaku_loader.dart';
import 'drama_download_sheet.dart';
import 'drama_page.dart';
import 'home_provider.dart';
import 'series_detail_page.dart';

/// 短剧「纯净模式」：全屏竖滑切剧的独立页面。
///
/// 与短剧页（[DramaPage]）的差异只在「显示哪些部件」，播放机制复用同一套
/// [InlineVideoPlayback]（本页自建实例；进入前短剧页已按 `_pushOverFeed`
/// 语义销毁自己的播放器，返回时它会自行恢复）：
/// - 无频道条/搜索条/引导层；左上角只有「退出」与「弹幕开关」；
/// - 右侧竖排三按钮：下载 / 查看评论 / 收藏（本地书架，无账号同步）；
/// - 底部整宽条「观看完整短剧 ›」→ 剧集详情页（[SeriesDetailPage]）；
/// - 弹幕保留：按当前播放剧集取数（接法参考播放页，去掉横屏/拖动补数等
///   播放页专属分支）。
class DramaCleanPage extends ConsumerStatefulWidget {
  const DramaCleanPage({
    super.key,
    required this.initialIndex,
    this.directoryLoader,
    this.contentLoader,
    this.playerFactory,
    this.historyStore,
  });

  /// 进入时停在哪部（短剧页当前屏）。
  final int initialIndex;

  // ── 与 DramaPage 同款的注入缝，测试与宿主复用 ──────────────────────
  final Future<List<List<Chapter>>> Function(String id, String tab)?
  directoryLoader;
  final Future<Map<String, dynamic>> Function(String itemId, String tab)?
  contentLoader;
  final NativePlayer Function()? playerFactory;
  final ReaderStore? historyStore;

  @override
  ConsumerState<DramaCleanPage> createState() => _DramaCleanPageState();
}

class _DramaCleanPageState extends ConsumerState<DramaCleanPage>
    with WidgetsBindingObserver {
  late final InlineVideoPlayback _inline;
  late final PageController _pager;
  int _screenIndex = 0;
  bool _paging = false;

  // ── 弹幕（接法参考 player_page，简化版） ──────────────────────────
  bool _danmakuEnabled = DanmakuPreference.defaultEnabled;
  final DanmakuTimeline _danmaku = DanmakuTimeline();
  List<PlayletComment> _danmakuEntries = const [];
  late final DanmakuLoader _danmakuLoader = DanmakuLoader(
    fetch: _fetchDanmaku,
    onLoad: (page) {
      if (!mounted) return;
      final focus = _inline.position.value.inMilliseconds;
      setState(() {
        final retention = _danmaku.load(page, focusMs: focus);
        // 时间轴裁掉旧条目后要把窗口回灌给调度器，否则它会重复请求已被
        // 丢弃的段（player_page 同款处理）。
        if (retention.dropped) {
          _danmakuLoader.noteRetainedRange(
            minOffsetMs: retention.minOffsetMs,
            maxOffsetMs: retention.maxOffsetMs,
            droppedBehind: retention.droppedBehind,
            droppedAhead: retention.droppedAhead,
            emptied: retention.emptied,
          );
        }
        _danmakuEntries = _danmaku.entries;
      });
    },
  );
  BackendRequest? _danmakuFlight;
  Timer? _danmakuTimer;
  String? _danmakuVid;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _screenIndex = widget.initialIndex;
    _pager = PageController(initialPage: _screenIndex);
    _inline = InlineVideoPlayback(
      directoryLoader: widget.directoryLoader,
      contentLoader: widget.contentLoader,
      playerFactory: widget.playerFactory,
      historyStore: widget.historyStore,
    );
    unawaited(DramaPreheatPreferences.instance.load());
    // 弹幕开关持久化（播放页同款偏好源）。
    unawaited(_loadDanmakuPreference());
    // 进页即起播当前部（短剧页已在 push 前销毁了它的播放器）。
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncInline());
  }

  Future<void> _loadDanmakuPreference() async {
    final enabled = await DanmakuPreference.load();
    if (mounted && enabled != _danmakuEnabled) {
      setState(() => _danmakuEnabled = enabled);
    }
  }

  @override
  void dispose() {
    _danmakuTimer?.cancel();
    _danmakuFlight?.cancel();
    _danmakuLoader.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _pager.dispose();
    unawaited(_inline.dispose());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 与短剧页同款：后台暂停、前台恢复。
    if (state == AppLifecycleState.resumed) {
      final current = _currentItem();
      if (current != null && _inline.activeId.value == current.id) {
        unawaited(_inline.resume());
      } else {
        _syncInline();
      }
    } else if (state == AppLifecycleState.paused) {
      unawaited(_inline.pause());
    }
  }

  MediaItem? _currentItem() {
    final items = _visibleItems();
    return (_screenIndex >= 0 && _screenIndex < items.length)
        ? items[_screenIndex]
        : null;
  }

  List<MediaItem> _visibleItems() {
    // 与短剧页同源的 feed 数据（同一个 dramaProvider）；纯净模式沿用
    // 当前频道的可见列表（视频/漫剧卡）。
    final state = ref.read(dramaProvider);
    return state.items
        .where((item) => item.kind == 'video' || item.kind == 'manju')
        .toList(growable: false);
  }

  void _syncInline() {
    final item = _currentItem();
    if (item == null) {
      if (_inline.activeId.value != null) unawaited(_inline.release());
      return;
    }
    if (_inline.activeId.value == item.id) return;
    unawaited(_inline.activate(item));
    final items = _visibleItems();
    final preheat = DramaPreheatPreferences.instance.count.value;
    for (var i = 1; i <= preheat && _screenIndex + i < items.length; i++) {
      _inline.preheatDrama(items[_screenIndex + i]);
    }
    _loadDanmakuFor(item);
  }

  // ── 弹幕取数 ──────────────────────────────────────────────────────

  Future<PlayletCommentPage> _fetchDanmaku(DanmakuFetchRequest request) async {
    final flight = BackendRequest();
    _danmakuFlight = flight;
    final seriesId = _currentItem()?.seriesId ?? _currentItem()?.id ?? '';
    return ApiClient.instance.withCancellation(flight, () {
      return ApiClient.instance.playletDanmaku(
        request.vid,
        seriesId: seriesId,
        startOffsetMs: request.startOffsetMs,
        duration: _inline.duration.value,
        cursor: request.cursor,
      );
    });
  }

  void _loadDanmakuFor(MediaItem item) {
    // 弹幕以「当前播放剧集的 vid」为键（官方 `DanmakuRequestHelper` 语义）；
    // feed 卡是整剧，先解析目录、按历史推断当前集，再取该集弹幕。
    // best-effort：失败只是没有弹幕，不影响播放。
    final contentId = item.seriesId ?? item.id;
    final tab = item.kind == 'manju' ? '漫剧' : '短剧';
    unawaited(() async {
      try {
        final eps = await _episodesOf(item);
        if (eps.isEmpty || !mounted) return;
        var index = 0;
        try {
          final saved = await PlayerHistory(
            widget.historyStore ?? LibraryStore.instance,
          ).load(contentId);
          if (saved != null) {
            index = (resumeEpisodeIndex(saved, eps) ?? 0).clamp(
              0,
              eps.length - 1,
            );
          }
        } catch (_) {}
        final vid = eps[index].itemId;
        if (vid.isEmpty || vid == _danmakuVid) return;
        _danmakuVid = vid;
        _danmaku.reset();
        _danmakuLoader.reset(vid: vid);
        setState(() => _danmakuEntries = const []);
        _danmakuTimer?.cancel();
        // 官方进度心跳：1 秒一拍驱动分段预取（player_page 同款节拍）。
        _danmakuTimer = Timer.periodic(const Duration(seconds: 1), (_) {
          if (!mounted) return;
          _danmakuLoader.onProgress(_inline.position.value.inMilliseconds);
        });
      } catch (_) {
        // 弹幕是纯增益：失败静默。
      }
    }());
  }

  void _toggleDanmaku() {
    final enabled = !_danmakuEnabled;
    setState(() => _danmakuEnabled = enabled);
    unawaited(DanmakuPreference.save(enabled));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(enabled ? '弹幕已开启' : '弹幕已关闭'),
        duration: const Duration(milliseconds: 1200),
      ),
    );
  }

  // ── 右侧按钮与底部条动作 ──────────────────────────────────────────

  Future<List<Chapter>> _episodesOf(MediaItem item) async {
    final contentId = item.seriesId ?? item.id;
    final tab = item.kind == 'manju' ? '漫剧' : '短剧';
    try {
      final loader = widget.directoryLoader;
      final volumes = loader != null
          ? await loader(contentId, tab)
          : await ApiClient.instance.directoryChapters(contentId, tab: tab);
      return volumes.expand((volume) => volume).toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  Future<void> _openDownload(MediaItem item) async {
    final eps = await _episodesOf(item);
    if (!mounted || eps.isEmpty) return;
    await DramaDownloadSheet.show(
      context,
      seriesId: item.seriesId ?? item.id,
      title: item.title,
      cover: item.cover,
      episodes: eps,
    );
  }

  Future<void> _openComments(MediaItem item) async {
    await PlayletCommentPanel.show(
      context,
      seriesId: item.seriesId ?? item.id,
    );
  }

  Future<void> _openDetail(MediaItem item) async {
    final eps = await _episodesOf(item);
    if (!mounted) return;
    await _pushOver(() async {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => SeriesDetailPage(
            seriesId: item.seriesId ?? item.id,
            title: item.title,
            cover: item.cover,
            episodes: eps,
          ),
        ),
      );
    });
  }

  /// 与短剧页 `_pushOverFeed` 同语义：压在上面的路由可能自带播放器
  /// （详情页 → 选集 → 全页播放器），两个原生播放器不能同时存活。
  Future<void> _pushOver(Future<void> Function() push) async {
    await _inline.disposePlayer();
    if (!mounted) return;
    try {
      await push();
    } finally {
      if (mounted) _syncInline();
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = ref.watch(dramaProvider.select((state) => state.items));
    final visible = items
        .where((item) => item.kind == 'video' || item.kind == 'manju')
        .toList(growable: false);
    return Scaffold(
      backgroundColor: Colors.black,
      body: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light,
        child: Stack(
          children: [
            if (visible.isEmpty)
              const Center(
                child: CircularProgressIndicator(color: Colors.white),
              )
            else
              NotificationListener<ScrollNotification>(
                onNotification: (notification) {
                  // 拖动进行中不切播（与短剧页「Only after the drag settles」
                  // 同一语义），松手结算时 onPageChanged 已触发过 _syncInline。
                  if (notification is ScrollStartNotification) {
                    _paging = true;
                  } else if (notification is ScrollEndNotification) {
                    _paging = false;
                  }
                  return false;
                },
                child: PageView.builder(
                  controller: _pager,
                  scrollDirection: Axis.vertical,
                  itemCount: visible.length,
                  onPageChanged: (index) {
                    setState(() => _screenIndex = index);
                    if (index >= visible.length - 2) {
                      ref.read(dramaProvider.notifier).loadMore();
                    }
                    if (!_paging) _syncInline();
                  },
                  itemBuilder: (context, index) {
                    final item = visible[index];
                    final onScreen = index == _screenIndex;
                    return _CleanFeedCard(
                      item: item,
                      playback: onScreen ? _inline : null,
                      danmakuEntries: onScreen ? _danmakuEntries : const [],
                      danmakuEnabled: _danmakuEnabled,
                      onTogglePlay: () {
                        final current = _currentItem();
                        if (current == null) return;
                        if (_inline.activeId.value != current.id) {
                          _syncInline();
                          return;
                        }
                        if (_inline.playing.value) {
                          unawaited(_inline.pause());
                        } else {
                          unawaited(_inline.resume());
                        }
                      },
                      onDownload: () => unawaited(_openDownload(item)),
                      onComments: () => unawaited(_openComments(item)),
                      onDetail: () => unawaited(_openDetail(item)),
                    );
                  },
                ),
              ),
            // 左上：退出 + 弹幕开关。
            Positioned(
              top: MediaQuery.paddingOf(context).top + 8,
              left: 12,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _TopIcon(
                    icon: LucideIcons.chevron_left,
                    tooltip: '退出纯净模式',
                    onTap: () => Navigator.of(context).maybePop(),
                  ),
                  const SizedBox(width: 12),
                  _TopIcon(
                    label: '弹',
                    tooltip: '弹幕开关',
                    dimmed: !_danmakuEnabled,
                    onTap: _toggleDanmaku,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 左上角圆形半透明按钮（退出/弹幕开关共用）。
class _TopIcon extends StatelessWidget {
  final IconData? icon;
  final String? label;
  final String tooltip;
  final bool dimmed;
  final VoidCallback onTap;

  const _TopIcon({
    required this.tooltip,
    required this.onTap,
    this.icon,
    this.label,
    this.dimmed = false,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: dimmed ? const Color(0x33000000) : const Color(0x66000000),
            shape: BoxShape.circle,
          ),
          child: label != null
              ? Center(
                  child: Text(
                    label!,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                )
              : Icon(icon, size: 22, color: Colors.white),
        ),
      ),
    );
  }
}

/// 纯净模式的单张卡：视频/封面 + 弹幕层 + 右侧三按钮 + 底部详情条。
class _CleanFeedCard extends StatelessWidget {
  final MediaItem item;
  final InlineVideoPlayback? playback;
  final List<PlayletComment> danmakuEntries;
  final bool danmakuEnabled;
  final VoidCallback onTogglePlay;
  final VoidCallback onDownload;
  final VoidCallback onComments;
  final VoidCallback onDetail;

  const _CleanFeedCard({
    required this.item,
    required this.playback,
    required this.danmakuEntries,
    required this.danmakuEnabled,
    required this.onTogglePlay,
    required this.onDownload,
    required this.onComments,
    required this.onDetail,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // 视频/封面层（与短剧页同款布局计算；无圆角——纯净模式全屏）。
        playback != null
            ? InlineVideoLayer(item: item, playback: playback!)
            : StoryCover(
                item: item,
                cacheWidth:
                    (MediaQuery.sizeOf(context).width *
                            MediaQuery.devicePixelRatioOf(context))
                        .ceil(),
              ),
        // 底部渐变（信息可读性）。
        const Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: 220,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0x01000000), Color(0x80000000)],
              ),
            ),
          ),
        ),
        // 弹幕层（官方开关；关闭时整层不渲染）。
        if (playback != null && danmakuEnabled)
          Positioned.fill(
            child: PlayletDanmakuLayer(
              entries: danmakuEntries,
              position: playback!.position,
              playing: playback!.playing.value,
            ),
          ),
        // 单击 = 播放/暂停（官方 feed 手势的唯一单击语义）。
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTogglePlay,
          ),
        ),
        // 右侧竖排：下载 / 评论 / 收藏。
        Positioned(
          right: 12,
          bottom: 140,
          child: _CleanActions(
            item: item,
            onDownload: onDownload,
            onComments: onComments,
          ),
        ),
        // 底部整宽条：观看完整短剧 ›。
        Positioned(
          left: 16,
          right: 16,
          bottom: 24,
          child: _CleanBottomBar(onTap: onDetail),
        ),
      ],
    );
  }
}

/// 右侧竖排按钮：下载 / 查看评论 / 收藏（本地书架，无账号同步）。
class _CleanActions extends StatelessWidget {
  final MediaItem item;
  final VoidCallback onDownload;
  final VoidCallback onComments;

  const _CleanActions({
    required this.item,
    required this.onDownload,
    required this.onComments,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _ActionButton(
          icon: LucideIcons.download,
          label: '下载',
          onTap: onDownload,
        ),
        const SizedBox(height: 18),
        _ActionButton(
          icon: LucideIcons.message_square,
          label: '评论',
          onTap: onComments,
        ),
        const SizedBox(height: 18),
        ValueListenableBuilder<int>(
          valueListenable: ShelfStore.instance.listenable,
          builder: (context, _, __) {
            final saved = ShelfStore.instance.containsItem(item);
            return _ActionButton(
              icon: saved
                  ? LucideIcons.bookmark_check
                  : LucideIcons.bookmark,
              label: saved ? '已收藏' : '收藏',
              onTap: () => unawaited(_toggleShelf(saved)),
            );
          },
        ),
      ],
    );
  }

  Future<void> _toggleShelf(bool saved) async {
    final store = ShelfStore.instance;
    if (saved) {
      await store.removeKeys([ShelfStore.keyOf(item)]);
    } else {
      await store.add(item);
    }
  }
}

/// 右侧单个按钮：图标在上、小字在下（官方 feed 右栏形态）。
class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: const BoxDecoration(
              color: Color(0x59000000),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 22, color: Colors.white),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              shadows: [Shadow(color: Colors.black45, blurRadius: 4)],
            ),
          ),
        ],
      ),
    );
  }
}

/// 底部整宽条：「▶ 观看完整短剧 ›」（点击进剧集详情页，N 集由详情页展示）。
class _CleanBottomBar extends StatelessWidget {
  final VoidCallback onTap;

  const _CleanBottomBar({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: const Key('clean_detail_bar'),
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 44,
        decoration: BoxDecoration(
          color: const Color(0x66000000),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: const Color(0x33FFFFFF), width: 0.5),
        ),
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(LucideIcons.play, size: 18, color: Colors.white),
            SizedBox(width: 6),
            Text(
              '观看完整短剧',
              style: TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(width: 4),
            Icon(LucideIcons.chevron_right, size: 16, color: Colors.white70),
          ],
        ),
      ),
    );
  }
}
