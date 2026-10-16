import 'package:flutter/material.dart';

import '../services/offline_routing.dart';
import '../services/offline_search.dart';
import '../services/settings.dart';
import '../theme.dart';

/// Nastavení: balík tras ČR v telefonu (stažení, aktualizace, datum dat).
class OfflineRoutingSection extends StatefulWidget {
  final AppSettings settings;
  const OfflineRoutingSection({super.key, required this.settings});

  @override
  State<OfflineRoutingSection> createState() => _OfflineRoutingSectionState();
}

class _OfflineRoutingSectionState extends State<OfflineRoutingSection> {
  final _r = OfflineRouting.instance;
  (String, int?)? _latest;
  double? _progress;
  String? _error;

  @override
  void initState() {
    super.initState();
    _r.latest().then((v) {
      if (mounted) setState(() => _latest = v);
    });
  }

  static String _date(String? iso) {
    if (iso == null) return '?';
    final p = iso.split('-');
    return p.length == 3 ? '${int.parse(p[2])}. ${int.parse(p[1])}. ${p[0]}' : iso;
  }

  static String _mb(int? b) => b == null ? '' : '${(b / 1e6).round()} MB';

  Future<void> _download() async {
    setState(() {
      _progress = 0;
      _error = null;
    });
    try {
      await _r.download(
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
    } catch (e) {
      _error = 'Stažení selhalo: $e';
    }
    if (mounted) setState(() => _progress = null);
  }

  @override
  Widget build(BuildContext context) {
    if (!OfflineRouting.supported) return const SizedBox.shrink();
    final latest = _latest;
    final newer = latest != null && (_r.dataDate == null || latest.$1.compareTo(_r.dataDate!) > 0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text(
            'TRASY V TELEFONU (BEZ INTERNETU)',
            style: TextStyle(color: Lkw.amber, fontWeight: FontWeight.w800),
          ),
        ),
        ListTile(
          leading: Icon(_r.ready ? Icons.offline_pin : Icons.cloud_download, color: Lkw.amber),
          title: Text(_r.ready ? 'Balík tras ČR je stažený' : 'Balík tras ČR není stažený'),
          subtitle: Text(
            [
              if (_r.ready) 'data OSM z ${_date(_r.dataDate)} · ${_mb(_r.sizeBytes)}',
              if (_r.ready)
                OfflineSearch.instance.ready
                    ? 'hledání adres bez internetu: zapnuto'
                    : 'hledání adres bez internetu: stáhněte znovu',
              if (latest != null)
                'nejnovější: ${_date(latest.$1)}${latest.$2 != null ? ' · ke stažení ${_mb(latest.$2)}' : ''}',
              if (latest == null) 'nejnovější: nelze zjistit (bez internetu?)',
            ].join('\n'),
          ),
          isThreeLine: true,
        ),
        if (_progress != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              children: [
                LinearProgressIndicator(value: _progress == 0 ? null : _progress),
                const SizedBox(height: 4),
                Text('Stahuji ${(_progress! * 100).round()} % – nezavírejte aplikaci'),
              ],
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    icon: const Icon(Icons.download),
                    label: Text(!_r.ready ? 'Stáhnout ČR' : (newer ? 'Aktualizovat' : 'Stáhnout znovu')),
                    onPressed: latest == null ? null : _download,
                  ),
                ),
                if (_r.ready) ...[
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: 'Smazat balík',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () async {
                      await _r.remove();
                      setState(() {});
                    },
                  ),
                ],
              ],
            ),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            child: Text(_error!, style: const TextStyle(color: Lkw.danger)),
          ),
        SwitchListTile(
          title: const Text('Počítat trasy v telefonu'),
          subtitle: const Text(
            'Rychlé a bez signálu. Vypnuto = server (novější data); bez signálu se telefon '
            'použije vždy.',
          ),
          value: widget.settings.routeOnDevice,
          onChanged: (v) {
            setState(() => widget.settings.routeOnDevice = v);
            _r.preferDevice = v;
            widget.settings.save();
          },
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            'Balík obsahuje trasy a rejstřík adres a firem pro hledání bez signálu. '
            'Doporučeno stahovat přes Wi‑Fi. Aktualizace stahuje vždy celý balík – starý zůstává, '
            'dokud se nový nestáhne celý.',
            style: TextStyle(color: Lkw.muted, fontSize: 12),
          ),
        ),
      ],
    );
  }
}
