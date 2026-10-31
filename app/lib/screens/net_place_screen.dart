import 'package:flutter/material.dart';

import '../services/parking_network.dart';
import '../theme.dart';

/// Přidání / úprava místa v síti parkovišť: druh, počet míst, poplatek, vybavení, poznámka.
/// Velká tlačítka – vyplní se za pár vteřin na parkovišti. Vrací uložené místo.
class NetPlaceScreen extends StatefulWidget {
  final NetPlace place;
  final bool isNew;
  const NetPlaceScreen({super.key, required this.place, this.isNew = false});

  @override
  State<NetPlaceScreen> createState() => _NetPlaceScreenState();
}

class _NetPlaceScreenState extends State<NetPlaceScreen> {
  late final NetPlace p = NetPlace.fromJson(widget.place.toJson());
  late final _name = TextEditingController(text: widget.place.name);
  late final _cap = TextEditingController(text: widget.place.capacity?.toString() ?? '');
  late final _note = TextEditingController(text: widget.place.note ?? '');
  bool _saving = false;

  static IconData amenityIcon(NetAmenity a) => switch (a) {
    NetAmenity.wc => Icons.wc,
    NetAmenity.shower => Icons.shower,
    NetAmenity.food => Icons.restaurant,
    NetAmenity.shop => Icons.shopping_cart,
    NetAmenity.fuel => Icons.local_gas_station,
    NetAmenity.adblue => Icons.water_drop,
    NetAmenity.guarded => Icons.videocam,
    NetAmenity.fenced => Icons.fence,
    NetAmenity.lit => Icons.light_mode,
    NetAmenity.wifi => Icons.wifi,
    NetAmenity.hotel => Icons.hotel,
    NetAmenity.nonstop => Icons.schedule,
  };

  static String amenityTitle(NetAmenity a) => switch (a) {
    NetAmenity.fuel => 'Nafta pro kamiony',
    NetAmenity.guarded => 'Hlídané / kamery',
    final x => x.label[0].toUpperCase() + x.label.substring(1),
  };

  @override
  void dispose() {
    _name.dispose();
    _cap.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    final name = _name.text.trim();
    p
      ..name = name.isEmpty ? p.type.label : name
      ..capacity = int.tryParse(_cap.text.trim())?.clamp(0, 2000)
      ..note = _note.text.trim().isEmpty ? null : _note.text.trim();
    setState(() => _saving = true);
    await ParkingNetwork.instance.save(p);
    if (mounted) Navigator.pop(context, p);
  }

  Widget _head(String t) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
    child: Text(
      t,
      style: const TextStyle(color: Lkw.muted, fontWeight: FontWeight.w800, letterSpacing: 1),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final net = ParkingNetwork.instance;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isNew ? 'Přidat parkoviště' : 'Upravit parkoviště'),
        actions: [IconButton(icon: const Icon(Icons.check), onPressed: _save)],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            net.shared
                ? 'Místo uvidí všichni řidiči LKWnav.'
                : 'Uloží se do sítě v telefonu. Ostatním se odešle, až bude zapnutý server sítě.',
            style: const TextStyle(color: Lkw.muted),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _name,
            textCapitalization: TextCapitalization.sentences,
            maxLength: 80,
            decoration: const InputDecoration(
              labelText: 'Název',
              hintText: 'např. Truckpark Kolín, odpočívka Vystrkov',
              border: OutlineInputBorder(),
            ),
          ),
          _head('DRUH MÍSTA'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final t in NetType.values)
                ChoiceChip(
                  label: Text(t.label, style: const TextStyle(fontSize: 16)),
                  selected: p.type == t,
                  selectedColor: Lkw.amber,
                  labelStyle: TextStyle(color: p.type == t ? Colors.black : Lkw.text),
                  onSelected: (_) => setState(() => p.type = t),
                ),
            ],
          ),
          _head('MÍST PRO KAMIONY (ODHAD)'),
          Row(
            children: [
              SizedBox(
                width: 110,
                child: TextField(
                  controller: _cap,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(border: OutlineInputBorder(), hintText: '?'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final n in const [5, 10, 20, 50, 100])
                      ActionChip(label: Text('$n'), onPressed: () => setState(() => _cap.text = '$n')),
                  ],
                ),
              ),
            ],
          ),
          _head('PARKOVÁNÍ'),
          SegmentedButton<NetFee>(
            segments: const [
              ButtonSegment(value: NetFee.free, label: Text('Zdarma')),
              ButtonSegment(value: NetFee.paid, label: Text('Placené')),
              ButtonSegment(value: NetFee.unknown, label: Text('Nevím')),
            ],
            selected: {p.fee},
            onSelectionChanged: (s) => setState(() => p.fee = s.first),
          ),
          _head('VYBAVENÍ'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final a in NetAmenity.values)
                FilterChip(
                  avatar: Icon(amenityIcon(a), size: 20, color: p.amenities.contains(a) ? Colors.black : Lkw.amber),
                  label: Text(amenityTitle(a), style: const TextStyle(fontSize: 15)),
                  selected: p.amenities.contains(a),
                  showCheckmark: false,
                  selectedColor: Lkw.amber,
                  labelStyle: TextStyle(color: p.amenities.contains(a) ? Colors.black : Lkw.text),
                  onSelected: (v) => setState(() => v ? p.amenities.add(a) : p.amenities.remove(a)),
                ),
            ],
          ),
          _head('POZNÁMKA'),
          TextField(
            controller: _note,
            maxLines: 3,
            maxLength: 300,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              hintText: 'např. Vjezd z obce, v noci plno od 19 h, platí se v restauraci',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: const Icon(Icons.save),
            label: Text(widget.isNew ? 'Přidat do sítě' : 'Uložit'),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
