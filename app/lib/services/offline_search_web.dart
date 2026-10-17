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

  List<Place> search(String query, {int limit = 12}) => [];
}
