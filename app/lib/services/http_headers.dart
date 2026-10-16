import 'package:flutter/foundation.dart';

/// Prohlížeč nedovolí nastavit User-Agent (a vynutil by CORS preflight).
Map<String, String> uaHeaders([Map<String, String> extra = const {}]) => {
  if (!kIsWeb) 'User-Agent': 'LKWnav/1.0 (truck navigation)',
  ...extra,
};
