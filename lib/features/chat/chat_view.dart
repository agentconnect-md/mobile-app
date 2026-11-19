import 'dart:async';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/api/models.dart';
import '../../core/auth/app_state.dart';
import '../../core/webchat/attach_tray.dart';
import '../../core/webchat/attachments.dart';
import '../../core/webchat/chat_controller.dart';
import '../../l10n/app_localizations.dart';
import '../../ui/theme.dart';
import '../home/home_screen.dart' show SendButton;
import 'attachment_views.dart';
import 'bubbles.dart';
import 'composer_commands.dart';
import 'live_turn.dart';
import 'run_settings.dart';
import 'transcript_scroll.dart';
import '../../ui/icons.dart';
import '../../ui/adaptive.dart';

/// A conversation surface: [header] entries (stored transcript, empty state),
/// then the live chat (in memory only), then the message box.
///
/// The live connection opens on the first send: reading a conversation does
/// not start a chat. A webchat session resumes its conversation; another
/// session continues by its session token; a 403/409 turns the box into a
/// read-only note.
class ChatView extends StatefulWidget {
  const ChatView({
    super.key,
    required this.agent,
    required this.agentId,
    required this.agentName,
    this.sessionId,
    this.conversationId,
    this.header = const [],
    this.older = const [],
    this.earlier,
    this.onAtLatest,
    this.headerSliver,
    this.trailing = const [],
    this.firstMessage,
    this.onTurnDone,
    this.model,
    this.hint,
    this.footnote,
    this.runDefaults,
    this.thread,
    this.anyThread = false,
    this.focusSeq,
    this.fillRequestId,
    this.attachPolicy,
    this.linkSessionId,
  });

  /// The session whose transcript seqs the header's messages carry, for their
  /// share links (default [sessionId]); a task-held thread writes to the task
  /// but shows the coordinator's rows.
  final String? linkSessionId;

  /// The thread this box writes in (see [ChatController.thread]).
  final String? thread;

  /// A task's own continuation (see [ChatController.anyThread]).
  final bool anyThread;

  /// A message a link names: scrolled to and briefly highlighted once shown.
  final int? focusSeq;

  /// A Fill card a link names (`?fill=<requestId>`): the chat connects and
  /// asks for it (`fill_open`) as soon as the view opens.
  final String? fillRequestId;

  /// What the box may attach. Null: a new chat or a web chat takes images and
  /// files; another session's continuation asks the server
  /// (`continuationAttachments`).
  final AttachPolicy? attachPolicy;

  /// Message box placeholder (default "Message `agent`…").
  final String? hint;

  /// Small text under the box instead of the run chips ("Goes to this task only").
  final String? footnote;

  /// Shows the model / permission chips and the run settings sheet.
  final RunDefaults? runDefaults;
  final Agent? agent;
  final String agentId;
  final String agentName;
  final String? sessionId;

  /// For a webchat session: the conversation to resume (see [ChatController]).
  final String? conversationId;
  final List<Entry> header;

  /// Entries from pages older than the one the view opened on, oldest first.
  /// Kept apart from [header] so adding a page leaves the view where it is.
  final List<Entry> older;

  /// Shown above everything (the "Load earlier messages" button).
  final Widget? earlier;

  /// Told whether the view shows the latest row, when it opens and whenever
  /// that changes: the conversation counts as read up to there.
  final ValueChanged<bool>? onAtLatest;

  /// Shown instead of [header] when set (e.g. the new-chat intro).
  final Widget? headerSliver;

  /// Widgets after the transcript (in-session approval cards).
  final List<Widget> trailing;
  final String? firstMessage;
  final VoidCallback? onTurnDone;
  final String? model;

  @override
  State<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<ChatView> {
  final _text = TextEditingController();
  final _list = GlobalKey<TranscriptScrollState>();
  ChatController? _chat;
  bool _wasBusy = false;
  final _focusKey = GlobalKey();

  /// The "New" divider's row: the view opens on it when it is off screen.
  final _newKey = GlobalKey();
  int? _focused;
  bool _highlight = false;

  /// Brings the linked message into view once it's in [ChatView.header].
  void _maybeFocus() {
    final seq = widget.focusSeq;
    if (seq == null || _focused == seq) return;
    if (!widget.header.any((e) => entrySeq(e) == seq) && !widget.older.any((e) => entrySeq(e) == seq)) return;
    _focused = seq;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _focusKey.currentContext;
      if (ctx == null || !mounted) return;
      Scrollable.ensureVisible(ctx, alignment: 0.3, duration: const Duration(milliseconds: 300));
      setState(() => _highlight = true);
      Future<void>.delayed(const Duration(seconds: 2), () {
        if (mounted) setState(() => _highlight = false);
      });
    });
  }

  AttachTray? _tray;

  @override
  void initState() {
    super.initState();
    _text.addListener(() {
      if (_text.text.trimLeft().startsWith('/')) _loadSkills();
      setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _initAttach());
    final fill = widget.fillRequestId;
    if (fill != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _ensure().openFill(fill);
      });
    }
    final first = widget.firstMessage;
    if (first != null && first.trim().isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _send(first));
    }
  }

  @override
  void dispose() {
    _quiet?.cancel();
    _chat?.removeListener(_onChat);
    _chat?.dispose();
    _tray?.dispose();
    _text.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(ChatView old) {
    super.didUpdateWidget(old);
    // The session refreshes its transcript when a turn ends; once that holds
    // the live turn, the stored rows take the live copy's place.
    _settle();
  }

  /// The last transcript seq stored when the live chat began showing a turn:
  /// stored rows after it are that turn's, and stay hidden while the live
  /// copy shows (see `live_turn.dart`). Null when no live turn is shown.
  int? _liveMark;

  /// The chat has been quiet since its last turn for a while.
  bool _waited = false;
  Timer? _quiet;

  /// How long after a turn the stored transcript is given to hold it by its
  /// reply, before whatever is stored is taken as the turn.
  static const _settleWait = Duration(seconds: 3);

  /// [ChatView.header] without the stored copy of the turns shown live.
  List<Entry> get _storedShown {
    final mark = _liveMark;
    final c = _chat;
    if (mark == null || c == null || c.items.isEmpty) return widget.header;
    return storedBesideLive(widget.header, mark, c.items);
  }

  /// Lets the live copy of finished turns go once the stored transcript
  /// holds them. The rows swap in place: nothing is listed twice or moves.
  void _settle() {
    final c = _chat;
    final mark = _liveMark;
    if (c == null || mark == null || c.busy || c.items.isEmpty) return;
    final tail = widget.header.sublist(storedBefore(widget.header, mark));
    if (!liveTurnStored(tail, c.items, waited: _waited)) return;
    c.dropSettled();
    _quiet?.cancel();
    _liveMark = null;
    _waited = false;
    _sentCount = 0;
  }

  ChatController _ensure() {
    final existing = _chat;
    if (existing != null) return existing;
    final app = AppScope.read(context);
    final c = ChatController(
      client: app.client,
      orgId: app.current!.orgId,
      agentId: widget.agentId,
      sessionId: widget.sessionId,
      conversationId: widget.conversationId,
      thread: widget.thread,
      anyThread: widget.anyThread,
    )..addListener(_onChat);
    _chat = c;
    c.connect();
    return c;
  }

  void _onChat() {
    final c = _chat!;
    if (_wasBusy && !c.busy) widget.onTurnDone?.call();
    _wasBusy = c.busy;
    if (c.items.isEmpty) _liveMark = null;
    if (_liveMark == null && hasTurnContent(c.items)) _liveMark = lastSeq(widget.header) ?? -1;
    // Once the chat goes quiet, the stored transcript is read again in case
    // the turn was saved after the first refresh.
    _quiet?.cancel();
    _waited = false;
    if (_liveMark != null && !c.busy && c.items.isNotEmpty) {
      _quiet = Timer(_settleWait, () {
        if (!mounted) return;
        setState(() {
          _waited = true;
          _settle();
        });
        if (_liveMark != null) widget.onTurnDone?.call();
      });
    }
    if (mounted) setState(() {});
    // Sending goes to the latest row; otherwise the list follows only while
    // the person is already there.
    final sent = c.items.where((i) => i.kind == LiveKind.user).length;
    if (sent > _sentCount) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _list.currentState?.toLatest());
    }
    _sentCount = sent;
  }

  /// Messages sent live so far, to tell a send from other chat activity.
  int _sentCount = 0;

  List<String>? _fallbackModels;

  Future<void> _openRun() async {
    final chat = _ensure();
    final d = widget.runDefaults!;
    final a = d.agent;
    if (_fallbackModels == null && a?.daemonId != null) {
      final app = AppScope.read(context);
      try {
        _fallbackModels = await app.client.runtimeModels(app.current!.orgId, a!.daemonId!, a.runtime);
      } catch (_) {
        _fallbackModels = const [];
      }
    }
    if (!mounted) return;
    await showRunSettings(context, chat: chat, defaults: d, fallbackModels: _fallbackModels ?? const []);
  }

  List<RuntimeCommand>? _skills;
  bool _skillsAsked = false;

  /// The agent's skills, asked once, when a `/` is first typed.
  Future<void> _loadSkills() async {
    if (_skillsAsked) return;
    _skillsAsked = true;
    final app = AppScope.read(context);
    try {
      final all = await app.client.runtimeCommands(app.current!.orgId, widget.agentId);
      if (mounted) setState(() => _skills = all.where((c) => c.isSkill).toList());
    } catch (_) {
      // No skills listed; console commands still work.
    }
  }

  /// The console commands the toolbar would allow right now.
  List<ControlCommand> _controls() {
    final l = AppLocalizations.of(context);
    final c = _chat;
    final app = AppScope.read(context);
    final out = <ControlCommand>[];
    if (c?.busy == true) out.add(const ControlCommand(ControlName.stop));
    final d = widget.runDefaults;
    final runtime = d != null && widget.footnote == null && c?.conn != ChatConn.readOnly && app.canWrite &&
        (c?.participants ?? 0) <= 1;
    if (!runtime) return out;
    final run = c?.run;
    final model = run?.model ?? d.model;
    final effort = run?.effort ?? d.effort;
    final perm = run?.permissionMode ?? d.permissionMode;
    final models = run?.models ?? (_fallbackModels?.isEmpty ?? true ? null : _fallbackModels);
    if (models != null && models.isNotEmpty) {
      out.add(ControlCommand(ControlName.model, [for (final m in models) ControlChoice(m, m, current: m == model)]));
    }
    final efforts = run?.efforts;
    if (efforts != null && efforts.isNotEmpty) {
      out.add(ControlCommand(
          ControlName.effort, [for (final e in efforts) ControlChoice(e, effortLabel(l, e), current: e == effort)]));
    }
    final perms = run?.permissionModes;
    if (perms != null && perms.isNotEmpty) {
      out.add(ControlCommand(ControlName.permission,
          [for (final m in perms) ControlChoice(m, permissionLabel(l, m).$1, current: m == perm)]));
    }
    if (run?.fastModeAvailable == true) {
      final on = run?.fastMode == true;
      out.add(ControlCommand(ControlName.fast,
          [ControlChoice('on', l.fastOn, current: on), ControlChoice('off', l.fastOff, current: !on)]));
    }
    return out;
  }

  /// Runs a console command (with its chosen value) and takes its line out
  /// of the draft: nothing of it goes to the agent.
  void _runControl(ControlCommand cmd, String? value) {
    final chat = _ensure();
    switch (cmd.name) {
      case ControlName.stop:
        chat.cancel();
      case ControlName.model:
        if (value != null) chat.setModel(value);
      case ControlName.effort:
        if (value != null) chat.setEffort(value);
      case ControlName.permission:
        if (value != null) chat.setPermissionMode(value);
      case ControlName.fast:
        if (value != null) chat.setFast(value == 'on');
    }
    _text.clear();
  }

  void _pick(CommandRow row) {
    switch (row) {
      case ControlRow(:final command):
        if (command.choices == null) {
          _runControl(command, null);
        } else {
          // Second level: the choices, narrowed by what's typed next.
          _setDraft('/${command.word} ');
        }
      case ChoiceRow(:final command, :final choice):
        _runControl(command, choice.value);
      case SkillRow(:final skill):
        _setDraft('/${skill.name} ');
    }
  }

  void _setDraft(String t) {
    _text.value = TextEditingValue(text: t, selection: TextSelection.collapsed(offset: t.length));
  }

  /// A typed console command is run (or refused) here, never sent as text.
  /// True when [t] was one.
  bool _interceptCommand(String t) {
    final d = parseCommandDraft(t);
    final name = d == null ? null : controlForWord(d.word);
    if (d == null || name == null) return false;
    final cmd = _controls().where((c) => c.name == name).firstOrNull;
    final choices = cmd?.choices;
    if (cmd != null && choices == null) {
      _runControl(cmd, null);
    } else if (cmd != null && d.arg.isNotEmpty && matchChoices(choices!, d.arg).isNotEmpty) {
      _runControl(cmd, matchChoices(choices, d.arg).first.value);
    } else if (cmd != null) {
      _setDraft('/${cmd.word} ');
    } else {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(AppLocalizations.of(context).commandUnavailable(d.word))));
    }
    return true;
  }

  /// Decides what the box may attach, then sets up the tray (none: no
  /// attach button). Files need the deployment's file transfer and a daemon
  /// that fetches uploads; otherwise one image goes inline.
  Future<void> _initAttach() async {
    if (!mounted) return;
    final app = AppScope.read(context);
    final org = app.current?.orgId;
    if (org == null) return;
    var policy = widget.attachPolicy;
    if (policy == null) {
      if (widget.sessionId != null && widget.conversationId == null) {
        try {
          policy = await app.client.continuationAttachments(org, widget.sessionId!);
        } catch (_) {
          policy = AttachPolicy.none;
        }
      } else {
        policy = AttachPolicy.imagesAndFiles;
      }
    }
    if (policy == AttachPolicy.none || !mounted) return;
    FileTransferConfig? transfer;
    if (policy == AttachPolicy.imagesAndFiles) {
      try {
        transfer = await app.client.fileTransfer();
      } catch (_) {}
    }
    final daemonId = (widget.agent ?? app.orgData?.agent(widget.agentId))?.daemonId;
    Machine? daemon;
    for (final m in app.orgData?.machines ?? const <Machine>[]) {
      if (m.id == daemonId) daemon = m;
    }
    // An unlisted daemon may still fetch uploads: the server says when not.
    final daemonOk = daemon == null ||
        (daemon.features.contains(fileTransferFeature) && daemon.features.contains(uploadPreviewsFeature));
    if (!mounted) return;
    setState(() {
      _tray = AttachTray(
        client: app.client,
        orgId: org,
        agentId: widget.agentId,
        uploads: transfer != null && daemonOk,
        transfer: transfer,
      )..addListener(() {
          if (mounted) setState(() {});
        });
    });
  }

  Future<void> _pickAttachments() async {
    final l = AppLocalizations.of(context);
    final tray = _tray;
    if (tray == null || tray.room <= 0) return;
    final choice = await showActionMenu<String>(
      context,
      cancel: l.cancel,
      note: tray.uploads ? null : l.attachOneImageNote,
      actions: [
        MenuAction('photos', AppIcons.photoLibraryOutlined, l.attachPhotos),
        MenuAction('camera', AppIcons.photoCameraOutlined, l.attachCamera),
        if (tray.uploads) MenuAction('files', AppIcons.attachFile, l.attachFiles),
      ],
    );
    if (choice == null || !mounted) return;
    final picked = <(String, Uint8List, String?)>[];
    var tooBig = 0;
    try {
      final picker = ImagePicker();
      // HEIC photos come back as JPEG once a size or quality is asked for.
      const edge = 2560.0;
      switch (choice) {
        case 'photos':
          final xs = tray.room > 1
              ? await picker.pickMultiImage(maxWidth: edge, maxHeight: edge, imageQuality: 90, limit: tray.room)
              : [?await picker.pickImage(source: ImageSource.gallery, maxWidth: edge, maxHeight: edge, imageQuality: 90)];
          for (final x in xs) {
            picked.add((x.name, await x.readAsBytes(), x.mimeType));
          }
        case 'camera':
          final x = await picker.pickImage(source: ImageSource.camera, maxWidth: edge, maxHeight: edge, imageQuality: 90);
          if (x != null) picked.add((x.name, await x.readAsBytes(), x.mimeType));
        case 'files':
          final xs = tray.room > 1 ? await openFiles() : [?await openFile()];
          final limit = tray.transfer?.singlePutMax;
          for (final x in xs) {
            if (limit != null && await x.length() > limit) {
              tooBig++;
              continue;
            }
            picked.add((x.name, await x.readAsBytes(), null));
          }
      }
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.attachPickFailed)));
      return;
    }
    if (!mounted) return;
    final skipped = tray.add(picked);
    if (skipped > 0 || tooBig > 0) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(tooBig > 0 ? l.attachTooLarge : l.attachLimit(tray.max))));
    }
  }

  bool get _canSend {
    final tray = _tray;
    if (tray != null && !tray.ready) return false;
    return _text.text.trim().isNotEmpty || (tray != null && !tray.isEmpty);
  }

  void _send([String? text]) {
    final t = (text ?? _text.text).trim();
    final tray = text == null ? _tray : null;
    final hasFiles = tray != null && !tray.isEmpty;
    if (t.isEmpty && !hasFiles) return;
    if (text == null && _interceptCommand(t)) return;
    if (tray != null && !tray.ready) return;
    final chat = _ensure();
    if (chat.busy) return;
    // A relay that predates file previews would refuse the turn.
    final f = chat.features;
    if (hasFiles &&
        f != null &&
        !f.contains(uploadPreviewsFeature) &&
        tray.items.any((p) => p.uploaded?.preview != null)) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(AppLocalizations.of(context).attachNeedsRelay)));
      return;
    }
    final (images, files) = hasFiles ? tray.take() : (const <ImageAttachment>[], const <UploadedFile>[]);
    chat.send(t, images: images, files: files);
    if (text == null) _text.clear();
  }


  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    final app = AppScope.of(context);
    final c = _chat;
    final live = c == null ? const <Entry>[] : entriesFromLive(c.items, app.current?.userName);
    final entries = groupTools([..._storedShown, ...live]);
    final status = c == null
        ? null
        : c.conn == ChatConn.connecting && c.busy
            ? l.statusConnecting
            : c.conn == ChatConn.lost
                ? l.statusLost
                : c.waitingApproval
                    ? l.statusWaitingApproval
                    : c.statusLine == 'tool'
                        ? l.usingTool(c.statusTool ?? '')
                        : c.statusLine == 'thinking'
                            ? l.statusThinking
                            : null;
    final readOnly = c?.conn == ChatConn.readOnly;
    _maybeFocus();
    final focusing = widget.focusSeq != null && _focused != null;
    final rows = readOnly ? const <CommandRow>[] : commandRows(_text.text, _controls(), _skills ?? const []);
    final suggestion = readOnly || _text.text.isNotEmpty ? null : c?.suggestion;
    Widget row(Entry e) => EntryView(
          key: widget.focusSeq != null && entrySeq(e) == widget.focusSeq
              ? _focusKey
              : e is NewDividerEntry
                  ? _newKey
                  : null,
          entry: e,
          agent: widget.agent,
          sessionId: widget.linkSessionId ?? widget.sessionId,
          linkThread: widget.thread,
          chat: c,
          highlight: _highlight && entrySeq(e) == widget.focusSeq,
        );
    return Column(children: [
      Expanded(
        child: TranscriptScroll(
          key: _list,
          messageCount: entries.where((e) => e is UserEntry || e is AgentEntry).length,
          openAtLatest: widget.focusSeq == null,
          openAt: _newKey,
          onFollowing: widget.onAtLatest,
          // While landing on a linked message, build every row so it can be found.
          buildAll: focusing && !_highlight && _focusKey.currentContext == null,
          earlier: [
            ?widget.earlier,
            for (final e in groupTools(widget.older)) row(e),
          ],
          rows: [
            if (widget.headerSliver != null && live.isEmpty) widget.headerSliver!,
            for (final e in entries) row(e),
            ...widget.trailing,
            if (status != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(36, 6, 0, 0),
                child: Row(children: [
                  SizedBox(width: 12, height: 12, child: Spinner(strokeWidth: 1.5, color: p.tertiary)),
                  const SizedBox(width: 8),
                  Flexible(child: Text(status, style: TextStyle(color: p.secondary, fontSize: 13))),
                ]),
              ),
            if (c?.offline == true)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(l.agentOffline(widget.agentName), style: TextStyle(color: p.paused, fontSize: 13)),
              ),
          ],
        ),
      ),
      SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
          child: readOnly
              ? Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                      color: p.sunken,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: p.border)),
                  child: Text(l.readOnlyFooter,
                      textAlign: TextAlign.center, style: TextStyle(color: p.secondary, fontSize: 14)),
                )
              : Container(
                  decoration: BoxDecoration(
                    color: p.surface,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: p.border),
                    boxShadow: [BoxShadow(color: p.shadow, blurRadius: 3, offset: const Offset(0, 1))],
                  ),
                  padding: const EdgeInsets.fromLTRB(4, 2, 8, 8),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    if (_tray != null && !_tray!.isEmpty) _TrayStrip(tray: _tray!),
                    if (rows.isNotEmpty) _CommandList(rows: rows, onPick: _pick),
                    if (suggestion != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: ActionChip(
                            avatar: Icon(AppIcons.autoAwesomeOutlined, size: 16, color: p.secondary),
                            label: Text(suggestion, maxLines: 2, overflow: TextOverflow.ellipsis),
                            tooltip: l.useSuggestion,
                            // Fills an editable draft; never sent by itself.
                            onPressed: () => _setDraft(suggestion),
                          ),
                        ),
                      ),
                    TextField(
                      controller: _text,
                      minLines: 1,
                      maxLines: 5,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: InputDecoration(
                        hintText: widget.hint ?? l.messageAgent(widget.agentName),
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        filled: false,
                        contentPadding: const EdgeInsets.fromLTRB(10, 12, 10, 4),
                      ),
                    ),
                    Row(children: [
                      if (_tray != null)
                        IconButton(
                          tooltip: AppLocalizations.of(context).attach,
                          onPressed: _tray!.room > 0 && c?.busy != true ? _pickAttachments : null,
                          icon: Icon(AppIcons.addCircleOutline),
                        )
                      else
                        const SizedBox(width: 6),
                      Expanded(
                        child: widget.runDefaults != null && widget.footnote == null
                            ? Align(
                                alignment: Alignment.centerLeft,
                                child: RunChips(chat: c, defaults: widget.runDefaults!, onOpen: _openRun),
                              )
                            : Padding(
                                padding: const EdgeInsets.only(left: 4),
                                child: Text(widget.footnote ?? widget.model ?? '',
                                    maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(context, size: 12)),
                              ),
                      ),
                      if (c?.busy == true)
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: OutlinedButton(
                            style: OutlinedButton.styleFrom(minimumSize: const Size(56, 40)),
                            onPressed: c!.cancel,
                            child: Text(l.stop),
                          ),
                        ),
                      SendButton(enabled: _canSend && c?.busy != true, onPressed: _send),
                    ]),
                  ]),
                ),
        ),
      ),
    ]);
  }
}

/// The `/` and `!` picker above the box: console commands, then skills.
class _CommandList extends StatelessWidget {
  const _CommandList({required this.rows, required this.onPick});
  final List<CommandRow> rows;
  final void Function(CommandRow) onPick;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    String desc(ControlName n) => switch (n) {
          ControlName.stop => l.cmdStop,
          ControlName.model => l.cmdModel,
          ControlName.effort => l.cmdEffort,
          ControlName.permission => l.cmdPermission,
          ControlName.fast => l.cmdFast,
        };
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 240),
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.only(top: 6),
        children: [
          for (final r in rows)
            switch (r) {
              ControlRow(:final command) => ListTile(
                  dense: true,
                  leading: Icon(command.name == ControlName.stop ? AppIcons.stopCircleOutlined : AppIcons.tune,
                      size: 18, color: p.accent),
                  title: Text('/${command.word}', style: mono(context, size: 13, color: p.ink)),
                  subtitle: Text(desc(command.name), maxLines: 1, overflow: TextOverflow.ellipsis),
                  onTap: () => onPick(r),
                ),
              ChoiceRow(:final choice) => ListTile(
                  dense: true,
                  leading: Icon(choice.current ? AppIcons.radioButtonChecked : AppIcons.radioButtonOff,
                      size: 18, color: choice.current ? p.accent : p.borderStrong),
                  title: Text(choice.label, style: mono(context, size: 13, color: p.ink)),
                  onTap: () => onPick(r),
                ),
              SkillRow(:final skill) => ListTile(
                  dense: true,
                  leading: Icon(AppIcons.boltOutlined, size: 18, color: p.secondary),
                  title: Text(['/${skill.name}', ?skill.hint].join(' '), style: mono(context, size: 13, color: p.ink)),
                  subtitle: skill.description.isEmpty
                      ? null
                      : Text(skill.description, maxLines: 1, overflow: TextOverflow.ellipsis),
                  onTap: () => onPick(r),
                ),
            },
        ],
      ),
    );
  }
}

/// The picked files above the box: a card each, with remove, progress and
/// retry.
class _TrayStrip extends StatelessWidget {
  const _TrayStrip({required this.tray});
  final AttachTray tray;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    return SizedBox(
      height: attachmentCardSize + 30,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
        itemCount: tray.items.length,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (context, i) {
          final a = tray.items[i];
          final busy = a.state == PendingState.preparing || a.state == PendingState.uploading;
          final failed = a.state == PendingState.failed;
          final overlay = Stack(children: [
            if (busy || failed)
              Positioned.fill(
                child: Container(
                  color: p.surface.withValues(alpha: 0.7),
                  alignment: Alignment.center,
                  child: busy
                      ? const SizedBox(width: 20, height: 20, child: Spinner(strokeWidth: 2))
                      : a.canRetry
                          ? IconButton(
                              tooltip: l.retry,
                              onPressed: () => tray.retry(a),
                              icon: Icon(AppIcons.refresh, color: p.error),
                            )
                          : Icon(AppIcons.errorOutline, color: p.error),
                ),
              ),
            Positioned(
              top: 0,
              right: 0,
              child: IconButton(
                tooltip: l.remove,
                visualDensity: VisualDensity.compact,
                onPressed: () => tray.remove(a),
                icon: Container(
                  decoration: BoxDecoration(color: p.ink.withValues(alpha: 0.6), shape: BoxShape.circle),
                  padding: const EdgeInsets.all(2),
                  child: Icon(AppIcons.close, size: 14, color: p.surface),
                ),
              ),
            ),
          ]);
          final card = a.isImage && (a.thumb != null || !failed)
              ? ImageCard(bytes: a.thumb, label: a.name, overlay: overlay)
              : FileCard(name: a.name, mimeType: a.mimeType, sizeText: fileSizeText(a.size), overlay: overlay);
          return SizedBox(
            width: attachmentCardSize,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              card,
              const SizedBox(height: 4),
              Text(
                failed ? _errorText(l, a.error) : a.state == PendingState.uploading ? l.attachUploading : '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: failed ? p.error : p.tertiary),
              ),
            ]),
          );
        },
      ),
    );
  }

  static String _errorText(AppLocalizations l, PendingError? e) => switch (e) {
        PendingError.unreadableImage => l.attachUnreadable,
        PendingError.tooLarge => l.attachTooLarge,
        PendingError.uploadsUnavailable => l.attachUploadsUnavailable,
        PendingError.daemonTooOld => l.attachDaemonTooOld,
        PendingError.network => l.attachNetwork,
        _ => l.attachFailed,
      };
}
