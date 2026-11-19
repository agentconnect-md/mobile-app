import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;

import '../../l10n/app_localizations.dart';
import '../../ui/icons.dart';
import '../../ui/theme.dart';

/// The scrolling list of a conversation.
///
/// [earlier] rows sit above a fixed anchor and [rows] below it, so rows added
/// above (an older page) or below (a new message) leave what is on screen
/// where it is. The view opens on the latest row and keeps to it as rows
/// arrive, until the person scrolls away; then a floating button leads back
/// to it, with a count of the messages that arrived meanwhile.
class TranscriptScroll extends StatefulWidget {
  const TranscriptScroll({
    super.key,
    this.earlier = const [],
    required this.rows,
    this.messageCount = 0,
    this.openAtLatest = true,
    this.buildAll = false,
  });

  /// Rows older than the ones the view opened on, oldest first. Grows at its
  /// start.
  final List<Widget> earlier;

  /// The rows the view opened on and everything after. Grows at its end.
  final List<Widget> rows;

  /// How many of [rows] are messages: the button counts the ones added while
  /// the person was scrolled away.
  final int messageCount;

  /// Open on the latest row; false when the view will land somewhere else
  /// (a linked message).
  final bool openAtLatest;

  /// Build every row, not only those near the screen, so one can be found.
  final bool buildAll;

  @override
  State<TranscriptScroll> createState() => TranscriptScrollState();
}

class TranscriptScrollState extends State<TranscriptScroll> {
  /// This close to the end still counts as being at the latest row.
  static const _nearEnd = 32.0;

  /// Further from the end than this, the button to the latest row shows.
  static const _farFromEnd = 120.0;

  final _scroll = ScrollController();
  final _anchor = GlobalKey();

  /// The view is at the latest row and follows new ones.
  late bool _following = widget.openAtLatest;

  /// The first layout has been positioned; until then every row is built so
  /// the end of the list is known exactly.
  bool _opened = false;

  /// A scroll to the latest row is under way.
  bool _goingToLatest = false;

  /// The view is far enough from the latest row to offer the way back.
  bool _away = false;

  /// The messages there were when the person was last at the latest row.
  late int _seenCount = widget.messageCount;

  @override
  void didUpdateWidget(TranscriptScroll oldWidget) {
    super.didUpdateWidget(oldWidget);
    // At the latest row every message is seen; a count that drops (rows
    // replaced) never leaves a stale number behind.
    if (_following || widget.messageCount < _seenCount) _seenCount = widget.messageCount;
  }

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_following) _snap();
      setState(() => _opened = true);
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_goingToLatest) return;
    final pos = _scroll.position;
    _following = pos.maxScrollExtent - pos.pixels <= _nearEnd;
    _track();
  }

  /// Updates what the button shows from where the view is now.
  void _track() {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    final away = !_following && pos.maxScrollExtent - pos.pixels > _farFromEnd;
    final seen = _following ? widget.messageCount : _seenCount;
    if (away == _away && seen == _seenCount) return;
    setState(() {
      _away = away;
      _seenCount = seen;
    });
  }

  /// Puts the view exactly on the latest row.
  void _snap() {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    if (pos.pixels < pos.maxScrollExtent) pos.jumpTo(pos.maxScrollExtent);
  }

  /// The list grew, shrank or changed size (a new row, streamed text, the
  /// keyboard): stay on the latest row when the view was on it.
  bool _onMetrics(ScrollMetricsNotification n) {
    if (n.depth != 0 || _goingToLatest) return false;
    if (_following) {
      _snap();
    } else {
      _track();
    }
    return false;
  }

  /// Scrolls to the latest row and follows new ones again.
  Future<void> toLatest() async {
    _following = true;
    _track();
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    // Far away: skip most of the way, then glide the rest.
    const glide = 1200.0;
    _goingToLatest = true;
    if (pos.maxScrollExtent - pos.pixels > glide) pos.jumpTo(pos.maxScrollExtent - glide);
    await pos.animateTo(pos.maxScrollExtent, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    if (!mounted || !_goingToLatest) return; // the person took over
    _goingToLatest = false;
    // The end of a long list is an estimate until its last rows are laid out.
    _snap();
  }

  /// A drag takes the view back from a scroll to the latest row.
  bool _onUserScroll(ScrollStartNotification n) {
    if (n.depth == 0 && n.dragDetails != null && _goingToLatest) {
      _goingToLatest = false;
      _following = false;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final unseen = _following ? 0 : widget.messageCount - _seenCount;
    final list = NotificationListener<ScrollMetricsNotification>(
      onNotification: _onMetrics,
      child: NotificationListener<ScrollStartNotification>(
        onNotification: _onUserScroll,
        child: CustomScrollView(
          controller: _scroll,
          center: _anchor,
          scrollCacheExtent: !_opened || widget.buildAll ? const ScrollCacheExtent.pixels(1e6) : null,
          slivers: [
            // Grows upward from the anchor: its first child is the row just above it.
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              sliver: SliverList(delegate: SliverChildListDelegate(widget.earlier.reversed.toList())),
            ),
            SliverPadding(
              key: _anchor,
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              sliver: SliverList(delegate: SliverChildListDelegate(widget.rows)),
            ),
          ],
        ),
      ),
    );
    return Stack(children: [
      Positioned.fill(child: list),
      Positioned(
        right: 12,
        bottom: 12,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 150),
          child: _away ? _JumpToLatest(count: unseen < 0 ? 0 : unseen, onTap: toLatest) : const SizedBox.shrink(),
        ),
      ),
    ]);
  }
}

/// The round button over the list's bottom right corner: back to the latest
/// row, with the number of messages that arrived while scrolled away.
class _JumpToLatest extends StatelessWidget {
  const _JumpToLatest({required this.count, required this.onTap});
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    return Tooltip(
      message: l.jumpToLatest,
      child: Badge(
        isLabelVisible: count > 0,
        backgroundColor: p.accent,
        offset: const Offset(-2, -4),
        label: Text(count > 99 ? '99+' : '$count', semanticsLabel: l.newMessagesCount(count)),
        child: Material(
          color: p.surface,
          elevation: 2,
          shadowColor: p.shadow,
          shape: CircleBorder(side: BorderSide(color: p.border)),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: SizedBox(width: 44, height: 44, child: Icon(AppIcons.arrowDownward, size: 20, color: p.ink)),
          ),
        ),
      ),
    );
  }
}
