import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/webchat/chat_controller.dart';
import '../../core/webchat/frames.dart';
import '../../l10n/app_localizations.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

/// A Fill card: an agent asks the person to fill a website form on a
/// computer, without the agent ever seeing the values.
///
/// The values exist only in this widget's controllers. Fill sends them and
/// clears them at once; Cancel declines. Nothing is saved as a draft, logged
/// or kept in the transcript; the controllers are wiped on dispose too.
class FillCardView extends StatefulWidget {
  const FillCardView({super.key, required this.item, required this.chat, this.now});
  final LiveItem item;
  final ChatController? chat;

  /// For tests: the clock the expiry is read against.
  final DateTime Function()? now;

  @override
  State<FillCardView> createState() => _FillCardViewState();
}

class _FillCardViewState extends State<FillCardView> {
  final Map<String, TextEditingController> _text = {};
  final Map<String, String?> _choice = {};
  final Map<String, bool> _checks = {};
  final Set<String> _revealed = {};

  FillCard get _card => widget.item.fill!;

  TextEditingController _ctl(String id) => _text.putIfAbsent(id, TextEditingController.new);

  void _wipe() {
    for (final c in _text.values) {
      c.clear();
    }
    _choice.clear();
    _checks.clear();
    _revealed.clear();
  }

  @override
  void dispose() {
    _wipe();
    for (final c in _text.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// What was entered: text for inputs and choices, `checked` for checkboxes
  /// the person touched. Untouched fields are left as the page has them.
  List<Map<String, Object>> _values() {
    final out = <Map<String, Object>>[];
    for (final f in _card.fields) {
      if (f.isCheckbox) {
        final c = _checks[f.id];
        if (c != null) out.add({'field': f.id, 'checked': c});
      } else {
        final v = f.isChoice ? _choice[f.id] : _text[f.id]?.text;
        if (v != null && v.isNotEmpty) out.add({'field': f.id, 'value': v});
      }
    }
    return out;
  }

  void _fill() {
    final chat = widget.chat;
    final values = _values();
    if (chat == null || values.isEmpty) return;
    if (chat.answerFill(widget.item, values: values)) {
      // Sent: the values leave this card at once, whatever the fill's outcome.
      setState(_wipe);
    } else {
      setState(() {});
    }
  }

  void _cancel() {
    final chat = widget.chat;
    if (chat == null) return;
    if (chat.answerFill(widget.item, cancel: true)) {
      setState(_wipe);
    } else {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    final card = _card;
    final item = widget.item;
    final expired = card.expired(widget.now?.call());
    final outcome = item.fillOutcome ?? (expired && !item.fillSent ? 'expired' : null);
    final live = outcome == null && !item.fillSent && widget.chat != null;
    final hint = TextStyle(color: p.secondary, fontSize: 13, height: 1.4);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: AppCard(
        leftBar: live ? p.paused : null,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Icon(Icons.key_outlined, size: 14, color: p.tertiary),
            const SizedBox(width: 6),
            Expanded(
              child: Text(l.fillCrumb(card.computerName),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: p.tertiary, letterSpacing: 0.4)),
            ),
          ]),
          const SizedBox(height: 8),
          // The website as the browser reports it: what the person decides by.
          Text(card.origin, style: mono(context, size: 14, color: p.ink, weight: FontWeight.w600)),
          if ((card.title ?? '').isNotEmpty)
            Text(card.title!, maxLines: 1, overflow: TextOverflow.ellipsis, style: hint),
          if (card.frameOrigin != null) Text(l.fillFrame(card.frameOrigin!), style: hint),
          if ((card.reason ?? '').isNotEmpty) ...[
            const SizedBox(height: 8),
            // The agent's reason: untrusted, plain text.
            Text(card.reason!, style: TextStyle(color: p.secondary, fontSize: 14, height: 1.4)),
          ],
          const SizedBox(height: 10),
          if (!live)
            Semantics(
              liveRegion: true,
              child: Text(_outcomeText(l, outcome ?? 'sending'),
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: p.ink)),
            )
          else ...[
            for (final f in card.fields) ...[
              _field(context, f),
              const SizedBox(height: 10),
            ],
            Text(card.unmaskedOnPage ? l.fillUnmaskedNote : l.fillPrivacyNote, style: hint),
            if (item.fillError != null) ...[
              const SizedBox(height: 6),
              Text(item.fillError == 'not_connected' ? l.fillNotConnected : _refusal(l, item.fillError!),
                  style: TextStyle(color: p.error, fontSize: 13)),
            ],
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: OutlinedButton(onPressed: _cancel, child: Text(l.cancel))),
              const SizedBox(width: 6),
              Expanded(child: FilledButton(onPressed: _fill, child: Text(l.fillAction))),
            ]),
          ],
        ]),
      ),
    );
  }

  Widget _field(BuildContext context, FillField f) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    final label = Row(children: [
      Flexible(
        child: Text(f.title,
            maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: p.ink)),
      ),
      if (f.required) ...[
        const SizedBox(width: 6),
        Text(l.fillRequired, style: TextStyle(fontSize: 11, color: p.tertiary)),
      ],
    ]);
    if (f.isCheckbox) {
      return CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        dense: true,
        controlAffinity: ListTileControlAffinity.leading,
        value: _checks[f.id] ?? false,
        onChanged: (v) => setState(() => _checks[f.id] = v ?? false),
        title: label,
      );
    }
    if (f.isChoice) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        label,
        const SizedBox(height: 4),
        DropdownButtonFormField<String>(
          initialValue: _choice[f.id],
          isExpanded: true,
          items: [
            for (final o in f.options)
              DropdownMenuItem(value: o.value, child: Text(o.label, overflow: TextOverflow.ellipsis)),
          ],
          onChanged: (v) => setState(() => _choice[f.id] = v),
        ),
      ]);
    }
    // Every secret is masked here, whatever the website does with it.
    final masked = f.masked && !_revealed.contains(f.id);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      label,
      const SizedBox(height: 4),
      TextField(
        controller: _ctl(f.id),
        obscureText: masked,
        enableSuggestions: false,
        autocorrect: false,
        enableIMEPersonalizedLearning: false,
        // No autofill or suggestions: nothing the keyboard keeps.
        autofillHints: null,
        minLines: f.control == 'textarea' && !f.masked ? 2 : 1,
        maxLines: f.control == 'textarea' && !f.masked ? 5 : 1,
        maxLength: f.maxLength != null && f.maxLength! <= 4096 ? f.maxLength : 4096,
        maxLengthEnforcement: MaxLengthEnforcement.enforced,
        keyboardType: switch (f.control) {
          'email' => TextInputType.emailAddress,
          'tel' => TextInputType.phone,
          'number' => TextInputType.number,
          'url' => TextInputType.url,
          'date' => TextInputType.datetime,
          'textarea' => TextInputType.multiline,
          _ => TextInputType.text,
        },
        decoration: InputDecoration(
          isDense: true,
          counterText: '',
          hintText: f.placeholder,
          suffixIcon: f.masked
              ? IconButton(
                  tooltip: masked ? l.fillShow : l.fillHide,
                  icon: Icon(masked ? Icons.visibility_outlined : Icons.visibility_off_outlined, size: 18),
                  onPressed: () => setState(() => masked ? _revealed.add(f.id) : _revealed.remove(f.id)),
                )
              : null,
        ),
      ),
    ]);
  }

  static String _refusal(AppLocalizations l, String reason) => reason == 'refused' ? l.fillNotAccepted : reason;

  static String _outcomeText(AppLocalizations l, String outcome) => switch (outcome) {
        'filled' => l.fillOutcomeFilled,
        'partial' => l.fillOutcomePartial,
        'failed' => l.fillOutcomeFailed,
        'uncertain' => l.fillOutcomeUncertain,
        'target_changed' => l.fillOutcomeTargetChanged,
        'unsupported' => l.fillOutcomeUnsupported,
        'cancelled' => l.fillOutcomeCancelled,
        'expired' => l.fillOutcomeExpired,
        _ => l.fillOutcomeSending,
      };
}
