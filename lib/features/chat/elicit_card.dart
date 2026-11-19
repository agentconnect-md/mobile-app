import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/webchat/chat_controller.dart';
import '../../core/webchat/elicit.dart';
import '../../l10n/app_localizations.dart';
import '../../ui/icons.dart';
import '../../ui/platform.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

/// A question the agent asks in the conversation: one choice, several
/// choices, a typed answer, a form of those, or a link to open.
///
/// What the person picks and types exists only in this widget's state.
/// Sending puts it on the socket and clears it at once; nothing is saved as
/// a draft or logged, and the controllers are wiped on dispose too. The
/// daemon decides how the card ends: an answer it refuses leaves it open.
class ElicitCardView extends StatefulWidget {
  const ElicitCardView({super.key, required this.item, required this.chat, this.openUrl});
  final LiveItem item;
  final ChatController? chat;

  /// Opens a consent link in the browser; tests replace it.
  final Future<bool> Function(Uri url)? openUrl;

  @override
  State<ElicitCardView> createState() => _ElicitCardViewState();
}

class _ElicitCardViewState extends State<ElicitCardView> with AutomaticKeepAliveClientMixin {
  /// Single-field cards: the multi-select's picks and the typed draft.
  List<String> _picked = [];
  final TextEditingController _draft = TextEditingController();

  /// Form cards, by property name.
  final Map<String, TextEditingController> _text = {};
  final Map<String, List<String>> _picks = {};
  final Map<String, bool> _others = {};

  ElicitCard get _card => widget.item.elicit!;
  List<ElicitField> get _fields => _card.fields ?? const [];

  /// Keeps what was entered while the card scrolls out of view.
  @override
  bool get wantKeepAlive => widget.item.elicitOutcome == null;

  @override
  void initState() {
    super.initState();
    _seed();
  }

  @override
  void didUpdateWidget(ElicitCardView old) {
    super.didUpdateWidget(old);
    // Another question in this slot: nothing entered for the last one carries over.
    if (!identical(old.item, widget.item)) {
      _wipe();
      _seed();
    }
  }

  /// Each control starts out holding its schema default.
  void _seed() {
    final card = _card;
    _picked = [...card.pickedDefault];
    _draft.text = card.typedDefault;
    for (final f in _fields) {
      if (f.isTyped) {
        _ctl(f.propName).text = f.typedDefault;
        // A question opens with its "Other" box showing only when that box has a default.
        if (f.customAnswerFor != null && f.typedDefault.trim().isNotEmpty) _others[f.customAnswerFor!] = true;
      } else {
        _picks[f.propName] = [...f.pickedDefault];
      }
    }
  }

  TextEditingController _ctl(String name) => _text.putIfAbsent(name, TextEditingController.new);

  void _wipe() {
    _draft.clear();
    for (final c in _text.values) {
      c.clear();
    }
    _picked = [];
    _picks.clear();
    _others.clear();
  }

  @override
  void dispose() {
    _wipe();
    _draft.dispose();
    for (final c in _text.values) {
      c.dispose();
    }
    super.dispose();
  }

  Map<String, String> get _drafts => {for (final e in _text.entries) e.key: e.value.text};

  /// Sends [value] (null dismisses). Sent: what was entered leaves the card
  /// at once, whatever the verdict.
  bool _answer(Object? value) {
    final chat = widget.chat;
    if (chat == null) return false;
    final sent = chat.answerElicit(widget.item, value);
    if (sent) {
      Haptics.medium();
      setState(() {
        _wipe();
        _seed();
      });
    } else {
      setState(() {});
    }
    return sent;
  }

  Future<void> _open(String url) async {
    // Consent first: a link opened while the chat is away would leave the agent waiting.
    if (!_answer(url)) return;
    final uri = Uri.parse(url);
    await (widget.openUrl ?? (u) => launchUrl(u, mode: LaunchMode.externalApplication))(uri);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final l = AppLocalizations.of(context);
    final p = context.pal;
    final card = _card;
    final item = widget.item;
    final outcome = item.elicitOutcome;
    final settled = outcome != null;
    final live = !settled && !item.elicitSent && widget.chat != null;
    final mode = card.mode;
    final positive = outcome == 'accepted' || outcome == 'completed';
    final rows = [
      for (final f in _fields)
        if (f.customAnswerFor == null) f,
    ];
    final drafts = _drafts;
    final cornerDismiss = live && (mode == ElicitMode.single || mode == ElicitMode.multi);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: AppCard(
        leftBar: settled ? (positive ? p.online : null) : p.accent,
        padding: const EdgeInsets.fromLTRB(14, 6, 6, 14),
        child: Padding(
          padding: const EdgeInsets.only(right: 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 36),
              child: Row(children: [
                Icon(mode == ElicitMode.url ? AppIcons.openInNew : AppIcons.chatBubbleOutline,
                    size: 14, color: p.tertiary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(l.elicitCrumb,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: p.tertiary, letterSpacing: 0.4)),
                ),
                if (live && mode == ElicitMode.form)
                  Text(
                      l.elicitProgress(
                          rows.where((f) => rowAnswered(f, companionOf(_fields, f), drafts, _picks)).length,
                          rows.length),
                      style: mono(context, size: 12)),
                if (cornerDismiss)
                  IconButton(
                    tooltip: l.elicitDeclineNoAnswer,
                    visualDensity: VisualDensity.compact,
                    icon: Icon(AppIcons.close, size: 18, color: p.tertiary),
                    onPressed: () => _answer(null),
                  ),
              ]),
            ),
            // The agent's words: untrusted, plain text.
            if (card.headLine.isNotEmpty)
              Text(card.headLine,
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: p.ink, height: 1.4)),
            if (card.preamble.isNotEmpty && !settled) ...[
              const SizedBox(height: 6),
              Text(card.preamble, style: TextStyle(color: p.secondary, fontSize: 14, height: 1.4)),
            ],
            const SizedBox(height: 10),
            if (settled)
              _settled(context, outcome)
            else if (!live)
              _waiting(context)
            else ...[
              ...switch (mode) {
                ElicitMode.url => _url(context, card.url!),
                ElicitMode.form => _form(context, rows, drafts),
                ElicitMode.typed => _typed(context),
                ElicitMode.multi || ElicitMode.single => _options(context, mode == ElicitMode.multi),
                ElicitMode.unanswerable => _unanswerable(context),
              },
              if (item.elicitError != null) ...[
                const SizedBox(height: 8),
                Semantics(
                    liveRegion: true,
                    child: Text(l.elicitNotConnected, style: TextStyle(color: p.error, fontSize: 13))),
              ],
            ],
          ]),
        ),
      ),
    );
  }

  Widget _settled(BuildContext context, String outcome) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    final positive = outcome == 'accepted' || outcome == 'completed';
    final label = widget.item.elicitLabel;
    final text = switch (outcome) {
      'accepted' => label == null || label.isEmpty ? l.elicitAnswered : label,
      'completed' => l.elicitCompleted,
      'cancelled' => l.elicitCancelled,
      _ => l.elicitDismissed,
    };
    return Semantics(
      liveRegion: true,
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(
              positive
                  ? AppIcons.checkCircleOutline
                  : outcome == 'cancelled'
                      ? AppIcons.history
                      : AppIcons.block,
              size: 16,
              color: positive ? p.online : p.secondary),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(text,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: positive ? p.online : p.secondary)),
        ),
      ]),
    );
  }

  /// The answer went out and the daemon hasn't said how the card ended.
  Widget _waiting(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    final chat = widget.chat;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Semantics(
        liveRegion: true,
        child: Text(l.elicitSent, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: p.ink)),
      ),
      if (chat != null && widget.item.elicitSent)
        TextButton(onPressed: () => chat.reopenElicit(widget.item), child: Text(l.elicitAnswerAgain)),
    ]);
  }

  List<Widget> _unanswerable(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    return [
      Text(l.elicitUnanswerable, style: TextStyle(color: p.secondary, fontSize: 13, height: 1.4)),
      const SizedBox(height: 10),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: OutlinedButton(onPressed: () => _answer(null), child: Text(l.elicitDismiss)),
      ),
    ];
  }

  /// A link to open: the URL is shown exactly as asked and never fetched
  /// here; the person's tap on Open link is the consent.
  List<Widget> _url(BuildContext context, String url) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    final c = readConsentUrl(url)!;
    return [
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(color: p.sunken, borderRadius: BorderRadius.circular(6)),
        child: Text.rich(
          TextSpan(style: mono(context, size: 13, color: p.tertiary), children: [
            TextSpan(text: c.scheme),
            TextSpan(text: c.host, style: mono(context, size: 13, color: p.ink, weight: FontWeight.w600)),
            TextSpan(text: c.rest),
          ]),
        ),
      ),
      for (final w in c.warnings) ...[
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(color: p.pausedSoft, borderRadius: BorderRadius.circular(6)),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(AppIcons.warningAmberRounded, size: 15, color: p.paused),
            ),
            const SizedBox(width: 6),
            Expanded(child: Text(noteText(l, w), style: TextStyle(fontSize: 13, color: p.ink, height: 1.4))),
          ]),
        ),
      ],
      const SizedBox(height: 10),
      Row(children: [
        Expanded(
          child: Tooltip(
            message: l.elicitRefuseNoOpen,
            child: OutlinedButton(onPressed: () => _answer(null), child: Text(l.elicitDecline)),
          ),
        ),
        const SizedBox(width: 6),
        Expanded(child: FilledButton(onPressed: () => _open(url), child: Text(l.elicitOpenLink))),
      ]),
      const SizedBox(height: 6),
      Text(l.elicitOpensBrowser, style: TextStyle(color: p.tertiary, fontSize: 12)),
    ];
  }

  List<Widget> _options(BuildContext context, bool multi) {
    final l = AppLocalizations.of(context);
    final card = _card;
    final max = card.multi?.maxItems;
    return [
      for (final o in card.options) ...[
        _OptionRow(
          label: o.label,
          on: _picked.contains(o.value),
          // A single choice answers on the tap, so only a multi-select shows what is held.
          mark: multi ? _Mark.check : _Mark.none,
          // At the cap, the options still unpicked stop taking a tap.
          onTap: multi && !_picked.contains(o.value) && max != null && _picked.length >= max
              ? null
              : () {
                  if (!multi) {
                    _answer(o.value);
                    return;
                  }
                  Haptics.selection();
                  setState(() => _picked.contains(o.value) ? _picked.remove(o.value) : _picked.add(o.value));
                },
        ),
        const SizedBox(height: 6),
      ],
      if (multi) ...[
        _hint(context, noteText(l, selectionHint(card.multi))),
        const SizedBox(height: 10),
        FilledButton(
          onPressed: selectionFits(card.multi, _picked.length) ? () => _answer([..._picked]) : null,
          child: Text(l.elicitConfirm),
        ),
      ],
    ];
  }

  List<Widget> _typed(BuildContext context) {
    final l = AppLocalizations.of(context);
    final card = _card;
    final problem = typedProblem(card, _draft.text);
    return [
      _input(context, card, _draft, label: l.elicitYourAnswer),
      if (problem != null) ...[
        const SizedBox(height: 6),
        _hint(context, noteText(l, problem)),
      ],
      const SizedBox(height: 10),
      Row(children: [
        Expanded(child: OutlinedButton(onPressed: () => _answer(null), child: Text(l.elicitDismiss))),
        const SizedBox(width: 6),
        Expanded(
          child: FilledButton(
            onPressed: problem != null
                ? null
                : () => _answer(card.number != null ? parseNumber(_draft.text) : _draft.text),
            child: Text(l.elicitSubmit),
          ),
        ),
      ]),
    ];
  }

  List<Widget> _form(BuildContext context, List<ElicitField> rows, Map<String, String> drafts) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    final fields = _fields;
    final blocked = rows.any((f) => rowProblem(f, companionOf(fields, f), drafts, _picks) != null);
    return [
      for (var i = 0; i < rows.length; i++) ...[
        if (i > 0) Divider(height: 20, color: p.hairline),
        _question(context, i, rows[i], companionOf(fields, rows[i]), drafts),
      ],
      const SizedBox(height: 12),
      Row(children: [
        Expanded(child: OutlinedButton(onPressed: () => _answer(null), child: Text(l.elicitDismiss))),
        const SizedBox(width: 6),
        Expanded(
          child: FilledButton(
            onPressed: blocked ? null : () => _answer(formAnswer(fields, drafts, _picks)),
            child: Text(l.elicitSubmitAnswers, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ),
      ]),
      const SizedBox(height: 6),
      Text(l.elicitOptionalNote, style: TextStyle(color: p.tertiary, fontSize: 12)),
    ];
  }

  Widget _question(BuildContext context, int index, ElicitField f, ElicitField? companion, Map<String, String> drafts) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    final problem = rowProblem(f, companion, drafts, _picks);
    final held = _picks[f.propName] ?? const <String>[];
    final cap = f.isMulti ? f.multi?.maxItems : null;
    final other = _others[f.propName] ?? false;
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(
        width: 26,
        child: Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text('${index + 1}'.padLeft(2, '0'), style: mono(context, size: 12)),
        ),
      ),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Text(f.label, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: p.ink)),
            ),
            const SizedBox(width: 8),
            Text(f.required ? l.elicitRequired : l.elicitOptional,
                style: TextStyle(fontSize: 12, color: f.required ? p.brandText : p.tertiary)),
          ]),
          if ((f.description ?? '').isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(f.description!, style: TextStyle(fontSize: 13, color: p.secondary, height: 1.4)),
          ],
          const SizedBox(height: 8),
          if (f.isTyped)
            _input(context, f, _ctl(f.propName), label: f.label, name: f.propName)
          else ...[
            for (final o in f.options) ...[
              _OptionRow(
                label: o.label,
                on: held.contains(o.value),
                mark: f.isMulti ? _Mark.check : _Mark.radio,
                onTap: !held.contains(o.value) && cap != null && held.length >= cap
                    ? null
                    : () {
                        Haptics.selection();
                        setState(() {
                          final was = [...held];
                          if (was.remove(o.value)) {
                            _picks[f.propName] = was;
                          } else {
                            // A single-pick field replaces its choice; a multi-select adds to the set.
                            _picks[f.propName] = f.isMulti ? [...was, o.value] : [o.value];
                          }
                        });
                      },
              ),
              const SizedBox(height: 6),
            ],
            if (companion != null)
              _OptionRow(
                label: l.elicitOther,
                on: other,
                soft: true,
                mark: _Mark.check,
                onTap: () {
                  Haptics.selection();
                  setState(() {
                    _others[f.propName] = !other;
                    // Closing the box drops its hidden draft.
                    if (other) _ctl(companion.propName).clear();
                  });
                },
              ),
          ],
          if (companion != null && (f.isTyped || other)) ...[
            const SizedBox(height: 6),
            _input(context, companion, _ctl(companion.propName),
                label: '${f.label}: ${companion.label}',
                name: companion.propName,
                hint: companion.label,
                autofocus: other),
          ],
          if (problem != null) ...[
            const SizedBox(height: 6),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(AppIcons.warningAmberRounded, size: 13, color: p.brandText),
              ),
              const SizedBox(width: 6),
              Expanded(child: Text(noteText(l, problem), style: TextStyle(fontSize: 12, color: p.brandText))),
            ]),
          ] else if (f.isMulti) ...[
            const SizedBox(height: 2),
            _hint(context, noteText(l, selectionHint(f.multi))),
          ],
        ]),
      ),
    ]);
  }

  Widget _hint(BuildContext context, String text) =>
      Text(text, style: TextStyle(color: context.pal.tertiary, fontSize: 12, height: 1.4));

  /// A typed answer's field, with the keyboard its constraints call for.
  Widget _input(BuildContext context, ElicitSpec spec, TextEditingController controller,
      {required String label, String? name, String? hint, bool autofocus = false}) {
    final n = spec.number;
    final t = spec.text;
    final plain = n == null && t?.format == null && t?.pattern == null;
    return Semantics(
      label: label,
      child: TextField(
        key: name == null ? null : ValueKey('elicit-field:$name'),
        controller: controller,
        autofocus: autofocus,
        // Nothing the keyboard keeps.
        enableIMEPersonalizedLearning: false,
        autocorrect: plain,
        minLines: 1,
        maxLines: plain ? 4 : 1,
        maxLength: t?.maxLength,
        maxLengthEnforcement: MaxLengthEnforcement.enforced,
        keyboardType: n != null
            ? TextInputType.numberWithOptions(signed: true, decimal: !n.integer)
            : switch (t?.format) {
                'email' => TextInputType.emailAddress,
                'uri' => TextInputType.url,
                'date' || 'date-time' => TextInputType.datetime,
                _ => plain ? TextInputType.multiline : TextInputType.text,
              },
        decoration: InputDecoration(isDense: true, counterText: '', hintText: hint),
        onChanged: (_) => setState(() {}),
      ),
    );
  }
}

enum _Mark { none, radio, check }

/// One offered option: a full-width row, at least 44 pt tall. [mark] shows
/// what is held until the answer is sent; a row without one answers on tap.
class _OptionRow extends StatelessWidget {
  const _OptionRow({required this.label, required this.on, required this.mark, required this.onTap, this.soft = false});
  final String label;
  final bool on;
  final _Mark mark;

  /// An option the agent did not offer ("Other…").
  final bool soft;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final enabled = onTap != null;
    final icon = switch (mark) {
      _Mark.none => null,
      _Mark.radio => on ? AppIcons.radioButtonChecked : AppIcons.radioButtonUnchecked,
      _Mark.check => on ? AppIcons.checkBox : AppIcons.checkBoxOutlineBlank,
    };
    return Semantics(
      button: true,
      enabled: enabled,
      checked: mark == _Mark.none ? null : on,
      child: Opacity(
        opacity: enabled ? 1 : 0.5,
        child: Material(
          color: on ? p.hover : p.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(color: on ? p.borderStrong : p.border),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 44),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(children: [
                  if (icon != null) ...[
                    Icon(icon, size: 18, color: on ? p.accent : p.tertiary),
                    const SizedBox(width: 10),
                  ],
                  Expanded(
                    child: Text(label,
                        style: TextStyle(
                            fontSize: 14,
                            height: 1.35,
                            fontWeight: FontWeight.w500,
                            color: soft && !on ? p.secondary : p.ink)),
                  ),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The words for a validation note, a selection hint or a link warning.
String noteText(AppLocalizations l, ElicitNote n) => switch (n.code) {
      'number' => l.elicitNoteNumber,
      'whole' => l.elicitNoteWhole,
      'min' => l.elicitNoteMin(n.a as String),
      'max' => l.elicitNoteMax(n.a as String),
      'minLength' => l.elicitNoteMinLength(n.a as int),
      'maxLength' => l.elicitNoteMaxLength(n.a as int),
      'answer' => l.elicitNoteAnswer,
      'email' => l.elicitNoteEmail,
      'uri' => l.elicitNoteUri,
      'date' => l.elicitNoteDate,
      'dateTime' => l.elicitNoteDateTime,
      'pattern' => l.elicitNotePattern(n.a as String),
      'chooseOne' => l.elicitNoteChooseOne,
      'selectExactly' => l.elicitSelectExactly(n.a as int),
      'selectRange' => l.elicitSelectRange(n.a as int, n.b as int),
      'selectAtLeast' => l.elicitSelectAtLeast(n.a as int),
      'selectUpTo' => l.elicitSelectUpTo(n.a as int),
      'selectAny' => l.elicitSelectAny,
      'http' => l.elicitWarnHttp,
      'userinfo' => l.elicitWarnUserinfo(n.a as String),
      'lookalike' => l.elicitWarnLookalike,
      _ => l.elicitNoteCannot,
    };
