import 'dart:typed_data';

/// Web: značky z kamery se neukládají (kamera běží jen v telefonu).
class SignStore {
  SignStore._();
  static final instance = SignStore._();

  Future<void> add({
    required int t,
    double? lat,
    double? lon,
    double? acc,
    double? heading,
    double? speed,
    required String color,
    required String shape,
    required List<double> box,
    required int frames,
    String? text,
    String? kind,
    double? value,
    Uint8List? jpeg,
  }) async {}

  Future<(int, int, int)> stats() async => (0, 0, 0);
  Future<String> exportZip() async => throw UnsupportedError('web');
  Future<void> clear() async {}
}
