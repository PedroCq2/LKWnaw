import 'dart:convert';

import 'package:flutter/material.dart';

import '../services/app_feedback.dart';
import '../services/parking_network.dart';
import '../services/settings.dart';
import '../theme.dart';

/// Okno po zatřesení telefonem (nebo z nabídky): chyba / vylepšení / nová funkce, text řidiče
/// a systémové informace o telefonu, aplikaci a jízdě, aby šel problém dohledat.
class FeedbackScreen extends StatefulWidget {
  final AppSettings settings;
  final Map<String, dynamic> state; // poloha, trasa… z obrazovky mapy
  const FeedbackScreen({super.key, required this.settings, this.state = const {}});

  @override
  State<FeedbackScreen> createState() => _FeedbackScreenState();
}

class _FeedbackScreenState extends State<FeedbackScreen> {
  FeedbackKind _kind = FeedbackKind.bug;
  final _text = TextEditingController();
  bool _withInfo = true;
  bool _sending = false;
  Map<String, dynamic>? _info;

  @override
  void initState() {
    super.initState();
    AppFeedback.systemInfo(widget.settings, widget.state).then((v) {
      if (mounted) setState(() => _info = v);
    });
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final msg = _text.text.trim();
    if (msg.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Napište prosím pár slov.')));
      return;
    }
    setState(() => _sending = true);
    await AppFeedback.send(_kind, msg, _withInfo ? _info : null);
    if (!mounted) return;
    final net = ParkingNetwork.instance;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          net.shared && net.pending == 0 ? 'Odesláno, díky!' : 'Uloženo – odešle se, až bude spojení. Díky!',
        ),
      ),
    );
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Zpráva pro vývoj')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          for (final k in FeedbackKind.values)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Material(
                color: _kind == k ? Lkw.amber : Lkw.panelHi,
                borderRadius: BorderRadius.circular(14),
                child: InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: () => setState(() => _kind = k),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                    child: Row(
                      children: [
                        Icon(switch (k) {
                          FeedbackKind.bug => Icons.bug_report,
                          FeedbackKind.improvement => Icons.auto_fix_high,
                          FeedbackKind.feature => Icons.lightbulb,
                        }, color: _kind == k ? Colors.black : Lkw.amber),
                        const SizedBox(width: 12),
                        Text(
                          k.label,
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: _kind == k ? Colors.black : Lkw.text,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          const SizedBox(height: 8),
          TextField(
            controller: _text,
            maxLines: 6,
            maxLength: 4000,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(hintText: _kind.hint, border: const OutlineInputBorder()),
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _withInfo,
            onChanged: (v) => setState(() => _withInfo = v ?? true),
            title: const Text('Přiložit systémové informace'),
            subtitle: const Text('Telefon, Android, verze aplikace, nastavení, poloha a trasa'),
          ),
          if (_withInfo && _info != null)
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('Co se odešle', style: TextStyle(color: Lkw.muted)),
              children: [
                SelectableText(
                  const JsonEncoder.withIndent('  ').convert(_info),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: Lkw.muted),
                ),
              ],
            ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _sending ? null : _send,
            icon: const Icon(Icons.send),
            label: const Text('Odeslat'),
          ),
        ],
      ),
    );
  }
}
