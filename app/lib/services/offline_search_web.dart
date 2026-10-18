import 'dart:io';

import 'geocoding.dart';

/// Webová verze nemá SQLite – hledá se jen online.
class OfflineSearch {
  OfflineSearch._();
  static final instance = OfflineSearch._();

  bool get ready => false;

  static Future<File> file() async => File('search-cz.sqlite');

  Future<void> open([String? path]) async {}

  void close() {}

  String? nearestTown(Object p) => null;

  bool get hasTownBorders => false;

  String? townAt(Object p) => null;

  bool get hasRamps => false;

  bool get hasOsm => false;
  bool get hasAccess => false;
  bool get hasLanes => false;

  Map<int, Map<String, String>> wayTags(Iterable<int> ids) => {};

  List<Map<String, dynamic>> osmElements(double a, double b, double c, double d) => const [];

  List<(String, String, dynamic)> poisOfKinds(Set<String> kinds) => const [];

  (Object, int)? rampAt(Object p) => null;

  List<Place> search(String query, {int limit = 12}) => [];
}
