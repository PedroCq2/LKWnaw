// Rejstřík v SQLite jen v telefonu; ve webové verzi (simulace) prázdná náhrada.
export 'offline_search_web.dart' if (dart.library.ffi) 'offline_search_io.dart';
export 'search_fold.dart';
