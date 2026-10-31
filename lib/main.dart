import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const DalilikApp());
}

class DalilikApp extends StatelessWidget {
  const DalilikApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'دليلك',
      debugShowCheckedModeBanner: false,
      locale: const Locale('ar'),
      supportedLocales: const [Locale('ar')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0B7A75)),
      ),
      home: const MapScreen(),
    );
  }
}

class PlaceResult {
  final String name;
  final LatLng point;

  const PlaceResult({required this.name, required this.point});

  Map<String, dynamic> toJson() => {
        'name': name,
        'lat': point.latitude,
        'lon': point.longitude,
      };

  static PlaceResult? fromJson(Map<String, dynamic> j) {
    final name = j['name'];
    final lat = j['lat'];
    final lon = j['lon'];
    if (name is! String || lat is! num || lon is! num) return null;
    return PlaceResult(
      name: name,
      point: LatLng(lat.toDouble(), lon.toDouble()),
    );
  }
}

class NavStep {
  final String instruction;
  final String type;
  final String? modifier;
  final LatLng point;
  final double distance;
  final double duration;

  const NavStep({
    required this.instruction,
    required this.type,
    required this.modifier,
    required this.point,
    required this.distance,
    required this.duration,
  });
}

class RouteOption {
  final List<LatLng> points;
  final List<NavStep> steps;
  final double distance;
  final double duration;

  const RouteOption({
    required this.points,
    required this.steps,
    required this.distance,
    required this.duration,
  });
}

String _arabicInstruction(
  String type,
  String? modifier,
  String name,
  int? exit,
) {
  final onName = name.isNotEmpty ? ' على $name' : '';
  final toName = name.isNotEmpty ? ' إلى $name' : '';

  switch (type) {
    case 'depart':
      return 'ابدأ السير$onName';
    case 'arrive':
      return 'وصلت إلى وجهتك';
    case 'roundabout':
    case 'rotary':
    case 'roundabout turn':
      if (exit != null) {
        return 'ادخل الدوّار وخذ المخرج رقم $exit$toName';
      }
      return 'ادخل الدوّار$toName';
    case 'exit roundabout':
    case 'exit rotary':
      return 'اخرج من الدوّار$toName';
  }

  switch (modifier) {
    case 'uturn':
      return 'استدر للخلف$toName';
    case 'sharp right':
      return 'انعطف يميناً بحدّة$toName';
    case 'right':
      return 'انعطف يميناً$toName';
    case 'slight right':
      return 'انعطف قليلاً يميناً$toName';
    case 'straight':
      return 'تابع مستقيماً$onName';
    case 'slight left':
      return 'انعطف قليلاً يساراً$toName';
    case 'left':
      return 'انعطف يساراً$toName';
    case 'sharp left':
      return 'انعطف يساراً بحدّة$toName';
  }
  return 'تابع السير$onName';
}

IconData _maneuverIcon(String type, String? modifier) {
  if (type == 'arrive') return Icons.flag;
  if (type == 'roundabout' || type == 'rotary' || type == 'roundabout turn') {
    return Icons.roundabout_left;
  }
  switch (modifier) {
    case 'uturn':
      return Icons.u_turn_left;
    case 'sharp right':
      return Icons.turn_sharp_right;
    case 'right':
      return Icons.turn_right;
    case 'slight right':
      return Icons.turn_slight_right;
    case 'straight':
      return Icons.straight;
    case 'slight left':
      return Icons.turn_slight_left;
    case 'left':
      return Icons.turn_left;
    case 'sharp left':
      return Icons.turn_sharp_left;
  }
  return Icons.navigation;
}

class PoiCategory {
  final String key;
  final String label;
  final IconData icon;
  final Color color;
  final List<String> filters;

  const PoiCategory(this.key, this.label, this.icon, this.color, this.filters);
}

class Poi {
  final String name;
  final LatLng point;
  final String key;

  const Poi({required this.name, required this.point, required this.key});
}

const List<PoiCategory> kPoiCategories = [
  PoiCategory('fuel', 'وقود', Icons.local_gas_station, Color(0xFFE65100),
      ['["amenity"="fuel"]']),
  PoiCategory('food', 'مطاعم', Icons.restaurant, Color(0xFFC62828),
      ['["amenity"~"^(restaurant|fast_food|cafe)\$"]']),
  PoiCategory('hotel', 'فنادق', Icons.hotel, Color(0xFF6A1B9A),
      ['["tourism"~"^(hotel|motel|guest_house|hostel)\$"]']),
  PoiCategory('parking', 'مواقف', Icons.local_parking, Color(0xFF1565C0),
      ['["amenity"="parking"]']),
  PoiCategory('market', 'أسواق', Icons.storefront, Color(0xFF2E7D32), [
    '["shop"~"^(supermarket|mall|department_store|convenience)\$"]',
    '["amenity"="marketplace"]',
  ]),
  PoiCategory('health', 'مستشفيات وصيدليات', Icons.local_hospital,
      Color(0xFFAD1457), ['["amenity"~"^(hospital|clinic|pharmacy)\$"]']),
  PoiCategory('tourism', 'سياحة', Icons.attractions, Color(0xFF00838F),
      ['["tourism"~"^(attraction|museum|viewpoint|gallery)\$"]']),
];

const List<Color> kStopColors = [
  Color(0xFFEF6C00),
  Color(0xFF8E24AA),
  Color(0xFF00897B),
  Color(0xFFD81B60),
  Color(0xFF3949AB),
  Color(0xFF6D4C41),
];

class _StopItem {
  final String name;
  final LatLng point;
  final String key;
  final String sub;

  const _StopItem(this.name, this.point, this.key, this.sub);
}

PoiCategory? poiCategoryByKey(String key) {
  for (final c in kPoiCategories) {
    if (c.key == key) return c;
  }
  return null;
}

class StopSheet extends StatefulWidget {
  final List<LatLng> route;
  final LatLng? me;
  final void Function(PlaceResult place) onPick;
  final VoidCallback onClose;

  const StopSheet({
    super.key,
    required this.route,
    required this.me,
    required this.onPick,
    required this.onClose,
  });

  @override
  State<StopSheet> createState() => _StopSheetState();
}

class _StopSheetState extends State<StopSheet> {
  final TextEditingController _q = TextEditingController();
  String? _catKey;
  bool _loading = false;
  String? _note;
  List<_StopItem> _items = [];

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  List<LatLng> _samples() {
    final r = widget.route;
    if (r.length < 2) return [];
    var start = 0;
    final me = widget.me;
    if (me != null) {
      var best = double.infinity;
      for (var i = 0; i < r.length; i++) {
        final dx = r[i].latitude - me.latitude;
        final dy = r[i].longitude - me.longitude;
        final d = dx * dx + dy * dy;
        if (d < best) {
          best = d;
          start = i;
        }
      }
    }
    const dist = Distance();
    final pts = <LatLng>[r[start]];
    var acc = 0.0;
    var total = 0.0;
    for (var i = start + 1; i < r.length; i++) {
      final d = dist.as(LengthUnit.Meter, r[i - 1], r[i]);
      acc += d;
      total += d;
      if (acc >= 400) {
        pts.add(r[i]);
        acc = 0;
      }
      if (total > 25000) break;
    }
    if (total <= 25000 && pts.last != r.last) pts.add(r.last);
    return pts;
  }

  Future<void> _loadAlongRoute(PoiCategory cat) async {
    if (_loading) return;
    final pts = _samples();
    if (pts.isEmpty) {
      setState(() => _note = 'لا يوجد مسار لعرض الأماكن عليه.');
      return;
    }
    final coords = pts.map((p) => '${p.latitude},${p.longitude}').join(',');
    final parts = cat.filters.map((f) => 'nwr$f(around:500,$coords);').join();
    final query = '[out:json][timeout:25];($parts);out center 60;';
    setState(() {
      _catKey = cat.key;
      _loading = true;
      _note = null;
      _items = [];
    });
    try {
      final response = await http.post(
        Uri.parse('https://overpass-api.de/api/interpreter'),
        headers: {'User-Agent': 'Dalilik/0.1 (Flutter navigation app)'},
        body: {'data': query},
      ).timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        if (mounted) {
          setState(() =>
              _note = 'تعذّر تحميل الأماكن الآن (رمز ${response.statusCode}).');
        }
        return;
      }
      final data =
          jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      final elements = (data['elements'] as List<dynamic>?) ?? [];
      const dist = Distance();
      final me = widget.me;
      final scored = <MapEntry<int, _StopItem>>[];
      for (final e in elements) {
        final m = e as Map<String, dynamic>;
        double? lat = (m['lat'] as num?)?.toDouble();
        double? lon = (m['lon'] as num?)?.toDouble();
        final center = m['center'] as Map<String, dynamic>?;
        if (lat == null && center != null) {
          lat = (center['lat'] as num?)?.toDouble();
          lon = (center['lon'] as num?)?.toDouble();
        }
        if (lat == null || lon == null) continue;
        final tags = (m['tags'] as Map<String, dynamic>?) ?? {};
        final rawName = (tags['name:ar'] ?? tags['name'] ?? '').toString();
        final pt = LatLng(lat, lon);
        var idx = 0;
        var best = double.infinity;
        for (var i = 0; i < pts.length; i++) {
          final dx = pts[i].latitude - lat;
          final dy = pts[i].longitude - lon;
          final d = dx * dx + dy * dy;
          if (d < best) {
            best = d;
            idx = i;
          }
        }
        final sub = me == null
            ? cat.label
            : '${cat.label} • ${(dist.as(LengthUnit.Meter, me, pt) / 1000).toStringAsFixed(1)} كم';
        scored.add(MapEntry(
          idx,
          _StopItem(rawName.isNotEmpty ? rawName : cat.label, pt, cat.key, sub),
        ));
      }
      scored.sort((a, b) => a.key.compareTo(b.key));
      if (!mounted) return;
      setState(() {
        _items = scored.map((e) => e.value).toList();
        if (_items.isEmpty) {
          _note = 'لا توجد أماكن من هذا النوع مسجّلة قرب مسارك.';
        }
      });
    } catch (_) {
      if (mounted) {
        setState(() => _note = 'تعذّر تحميل الأماكن. تأكد من الاتصال بالإنترنت.');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _searchByName() async {
    final text = _q.text.trim();
    if (text.isEmpty || _loading) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _catKey = null;
      _loading = true;
      _note = null;
      _items = [];
    });
    try {
      final me = widget.me;
      final params = <String, String>{
        'q': text,
        'format': 'jsonv2',
        'limit': '8',
        'accept-language': 'ar',
      };
      if (me != null) {
        params['viewbox'] =
            '${me.longitude - 0.4},${me.latitude + 0.4},${me.longitude + 0.4},${me.latitude - 0.4}';
      }
      final response = await http.get(
        Uri.https('nominatim.openstreetmap.org', '/search', params),
        headers: {'User-Agent': 'Dalilik/0.1 (Flutter navigation app)'},
      ).timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        if (mounted) {
          setState(
              () => _note = 'تعذّر البحث الآن (رمز ${response.statusCode}).');
        }
        return;
      }
      final data = jsonDecode(utf8.decode(response.bodyBytes)) as List<dynamic>;
      const dist = Distance();
      final items = <_StopItem>[];
      for (final e in data) {
        final pt = LatLng(
          double.parse(e['lat'] as String),
          double.parse(e['lon'] as String),
        );
        final sub = me == null
            ? 'نتيجة بحث'
            : 'نتيجة بحث • ${(dist.as(LengthUnit.Meter, me, pt) / 1000).toStringAsFixed(1)} كم';
        items.add(_StopItem(e['display_name'] as String, pt, '', sub));
      }
      if (!mounted) return;
      setState(() {
        _items = items;
        if (items.isEmpty) _note = 'لا توجد نتائج لهذا البحث.';
      });
    } catch (_) {
      if (mounted) {
        setState(() => _note = 'تعذّر البحث. تأكد من الاتصال بالإنترنت.');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final small = Theme.of(context).textTheme.bodySmall;
    return Material(
      elevation: 4,
      color: scheme.surface,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 42,
                    child: TextField(
                      controller: _q,
                      textInputAction: TextInputAction.search,
                      onSubmitted: (_) => _searchByName(),
                      decoration: InputDecoration(
                        hintText: 'ابحث عن محطة بالاسم',
                        prefixIcon: const Icon(Icons.search),
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: 'إغلاق',
                  onPressed: widget.onClose,
                ),
              ],
            ),
            const SizedBox(height: 6),
            SizedBox(
              height: 38,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  for (final c in kPoiCategories)
                    Padding(
                      padding: const EdgeInsetsDirectional.only(end: 6),
                      child: ChoiceChip(
                        avatar: Icon(c.icon, size: 18, color: c.color),
                        label: Text(c.label),
                        showCheckmark: false,
                        selected: _catKey == c.key,
                        selectedColor: scheme.primaryContainer,
                        onSelected: (_) => _loadAlongRoute(c),
                      ),
                    ),
                ],
              ),
            ),
            if (_loading)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: LinearProgressIndicator(),
              ),
            if (_note != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(_note!, style: small),
              ),
            if (_items.isNotEmpty) ...[
              const SizedBox(height: 6),
              SizedBox(
                height: 84,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: _items.length,
                  itemBuilder: (ctx, i) {
                    final it = _items[i];
                    final cat = poiCategoryByKey(it.key);
                    return Padding(
                      padding: const EdgeInsetsDirectional.only(end: 8),
                      child: SizedBox(
                        width: 185,
                        child: Card(
                          margin: EdgeInsets.zero,
                          child: InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: () => widget.onPick(
                              PlaceResult(name: it.name, point: it.point),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(8),
                              child: Row(
                                children: [
                                  Icon(cat?.icon ?? Icons.place,
                                      color: cat?.color),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Column(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          it.name,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: small?.copyWith(
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                        Text(
                                          it.sub,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: small,
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> with WidgetsBindingObserver {
  final MapController _controller = MapController();
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  static const LatLng _start = LatLng(24.7136, 46.6753);

  static const String _historyKey = 'dalilik_search_history';
  static const int _historyMax = 10;

  static const String _kDestLat = 'dalilik_dest_lat';
  static const String _kDestLon = 'dalilik_dest_lon';
  static const String _kDestName = 'dalilik_dest_name';
  static const String _kNav = 'dalilik_nav_active';
  static const String _kStops = 'dalilik_stops';
  static const String _kSavedAt = 'dalilik_saved_at';
  static const String _kCamLat = 'dalilik_cam_lat';
  static const String _kCamLon = 'dalilik_cam_lon';
  static const String _kCamZoom = 'dalilik_cam_zoom';
  static const int _stateMaxAgeMs = 2 * 60 * 60 * 1000;
  List<PlaceResult> _history = [];

  LatLng? _myLocation;
  bool _locating = false;

  bool _searching = false;
  List<PlaceResult> _stops = [];
  bool _stopPanelOpen = false;
  String? _poiKey;
  List<Poi> _pois = [];
  bool _poiLoading = false;
  List<PlaceResult> _results = [];
  LatLng? _destination;
  String? _destinationName;

  bool _routing = false;
  List<LatLng> _routePoints = [];
  double? _distanceMeters;
  double? _durationSeconds;
  List<NavStep> _steps = [];
  List<RouteOption> _options = [];
  int _selected = 0;

  bool _navigating = false;
  StreamSubscription<Position>? _positionSub;
  double? _speedKmh;
  int _nextStep = 0;
  double _distToNext = 0;
  double _heading = 0;
  bool _hasHeading = false;

  final FlutterTts _tts = FlutterTts();
  bool _ttsReady = false;
  bool _voiceOn = true;
  int _spokenStep = -1;
  int _spokenStage = 0;

  int _offRouteCount = 0;
  bool _rerouting = false;
  DateTime? _lastReroute;

  @override
  void initState() {
    super.initState();
    _searchFocus.addListener(() {
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.addObserver(this);
    _loadHistory();
    _restoreState();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _saveState();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _positionSub?.cancel();
    _tts.stop();
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_historyKey) ?? [];
      final list = <PlaceResult>[];
      for (final s in raw) {
        try {
          final item =
              PlaceResult.fromJson(jsonDecode(s) as Map<String, dynamic>);
          if (item != null) list.add(item);
        } catch (_) {}
      }
      if (!mounted) return;
      setState(() => _history = list);
    } catch (_) {}
  }

  Future<void> _saveHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        _historyKey,
        _history.map((p) => jsonEncode(p.toJson())).toList(),
      );
    } catch (_) {}
  }

  void _addToHistory(PlaceResult place) {
    final list = <PlaceResult>[place];
    for (final p in _history) {
      if (p.name != place.name) list.add(p);
    }
    _history = list.take(_historyMax).toList();
    _saveHistory();
  }

  void _clearHistory() {
    setState(() => _history = []);
    _saveHistory();
  }

  Future<void> _saveState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final dest = _destination;
      if (dest == null) {
        await prefs.remove(_kDestLat);
        await prefs.remove(_kDestLon);
        await prefs.remove(_kDestName);
        await prefs.remove(_kNav);
        await prefs.remove(_kStops);
      } else {
        await prefs.setDouble(_kDestLat, dest.latitude);
        await prefs.setDouble(_kDestLon, dest.longitude);
        final name = _destinationName;
        if (name != null) {
          await prefs.setString(_kDestName, name);
        } else {
          await prefs.remove(_kDestName);
        }
        await prefs.setBool(_kNav, _navigating);
        await prefs.setString(
          _kStops,
          jsonEncode(_stops.map((st) => st.toJson()).toList()),
        );
      }
      await prefs.setInt(_kSavedAt, DateTime.now().millisecondsSinceEpoch);
      try {
        final cam = _controller.camera;
        await prefs.setDouble(_kCamLat, cam.center.latitude);
        await prefs.setDouble(_kCamLon, cam.center.longitude);
        await prefs.setDouble(_kCamZoom, cam.zoom);
      } catch (_) {}
    } catch (_) {}
  }

  Future<void> _restoreState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedAt = prefs.getInt(_kSavedAt) ?? 0;
      final age = DateTime.now().millisecondsSinceEpoch - savedAt;
      if (savedAt == 0 || age > _stateMaxAgeMs) {
        await prefs.remove(_kDestLat);
        await prefs.remove(_kDestLon);
        await prefs.remove(_kDestName);
        await prefs.remove(_kNav);
        await prefs.remove(_kStops);
        return;
      }
      final lat = prefs.getDouble(_kDestLat);
      final lon = prefs.getDouble(_kDestLon);
      final name = prefs.getString(_kDestName);
      final wasNavigating = prefs.getBool(_kNav) ?? false;
      final restoredStops = <PlaceResult>[];
      final stopsJson = prefs.getString(_kStops);
      if (stopsJson != null) {
        try {
          for (final e in jsonDecode(stopsJson) as List<dynamic>) {
            final st = PlaceResult.fromJson(e as Map<String, dynamic>);
            if (st != null) restoredStops.add(st);
          }
        } catch (_) {}
      }
      final camLat = prefs.getDouble(_kCamLat);
      final camLon = prefs.getDouble(_kCamLon);
      final camZoom = prefs.getDouble(_kCamZoom);
      if (!mounted) return;
      if (_destination != null || _navigating) return;

      if (camLat != null && camLon != null && camZoom != null) {
        try {
          _controller.move(LatLng(camLat, camLon), camZoom);
        } catch (_) {}
      }
      if (lat == null || lon == null) return;

      setState(() {
        _destination = LatLng(lat, lon);
        _destinationName = name;
        _stops = restoredStops;
      });
      await _computeRoute(silent: wasNavigating);
      if (!mounted) return;
      if (wasNavigating && _routePoints.length > 1) {
        _msg('تم استئناف الملاحة بعد عودتك إلى التطبيق.');
        await _startNavigation();
      }
    } catch (_) {}
  }

  void _zoom(double delta) {
    final cam = _controller.camera;
    _controller.move(cam.center, cam.zoom + delta);
  }

  void _msg(String text, {bool settings = false}) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(text),
        action: settings
            ? SnackBarAction(
                label: 'الإعدادات',
                onPressed: () {
                  Geolocator.openAppSettings();
                },
              )
            : null,
      ),
    );
  }

  void _resetRoute() {
    _routePoints = [];
    _distanceMeters = null;
    _durationSeconds = null;
    _steps = [];
    _options = [];
    _selected = 0;
    _nextStep = 0;
    _distToNext = 0;
    _spokenStep = -1;
    _spokenStage = 0;
    _offRouteCount = 0;
  }

  void _applyOption(RouteOption o) {
    _routePoints = o.points;
    _steps = o.steps;
    _distanceMeters = o.distance;
    _durationSeconds = o.duration;
    _nextStep = 0;
    _distToNext = 0;
    _spokenStep = -1;
    _spokenStage = 0;
    _offRouteCount = 0;
  }

  void _selectOption(int i) {
    if (_navigating || i == _selected) return;
    if (i < 0 || i >= _options.length) return;
    setState(() {
      _selected = i;
      _applyOption(_options[i]);
    });
  }

  String _optionLabel(int i, int fastest) {
    final o = _options[i];
    final prefix = i == fastest ? 'الأسرع • ' : '';
    return '$prefix${_formatDistance(o.distance)} • ${_formatDuration(o.duration)}';
  }

  String _formatDistance(double meters) {
    if (meters < 1000) {
      return '${meters.round()} م';
    }
    return '${(meters / 1000).toStringAsFixed(1)} كم';
  }

  String _formatDuration(double seconds) {
    final minutes = (seconds / 60).round();
    if (minutes < 1) return 'أقل من دقيقة';
    if (minutes < 60) return '$minutes دقيقة';
    final hours = minutes ~/ 60;
    final rest = minutes % 60;
    if (rest == 0) return '$hours ساعة';
    return '$hours ساعة و$rest دقيقة';
  }

  String _spokenDistance(double meters) {
    if (meters >= 1000) {
      return '${(meters / 1000).toStringAsFixed(1)} كيلومتر';
    }
    var rounded = (meters / 10).round() * 10;
    if (rounded < 10) rounded = 10;
    return '$rounded متر';
  }

  int _stageFor(double d) {
    if (d <= 30) return 3;
    if (d <= 150) return 2;
    if (d <= 500) return 1;
    return 0;
  }

  Future<void> _initTts() async {
    if (_ttsReady) return;
    try {
      final available = await _tts.isLanguageAvailable('ar');
      if (available == true || available == 1) {
        await _tts.setLanguage('ar');
        await _tts.setSpeechRate(0.45);
        await _tts.setVolume(1.0);
        await _tts.setPitch(1.0);
        _ttsReady = true;
      } else {
        _msg('الصوت العربي غير متوفر في هاتفك. فعّل بيانات اللغة العربية في إعدادات تحويل النص إلى كلام.');
      }
    } catch (_) {
      _msg('تعذّر تشغيل النطق الصوتي على هذا الهاتف.');
    }
  }

  Future<void> _speak(String text) async {
    if (!_voiceOn || !_ttsReady) return;
    try {
      await _tts.stop();
      await _tts.speak(text);
    } catch (_) {}
  }

  void _announceStart() {
    if (!_voiceOn || _steps.isEmpty) return;
    if (_myLocation == null) {
      _speak('بدأت الملاحة');
      return;
    }
    final step = _steps[_nextStep];
    _spokenStep = _nextStep;
    _spokenStage = _stageFor(_distToNext);
    if (step.type == 'arrive') {
      _speak('بدأت الملاحة. ${step.instruction}');
      return;
    }
    _speak(
      'بدأت الملاحة. بعد ${_spokenDistance(_distToNext)} ${step.instruction}',
    );
  }

  void _maybeSpeak() {
    if (!_voiceOn || !_navigating || _steps.isEmpty) return;
    if (_nextStep != _spokenStep) {
      _spokenStep = _nextStep;
      _spokenStage = 0;
    }
    final step = _steps[_nextStep];
    final stage = _stageFor(_distToNext);
    if (stage > _spokenStage) {
      _spokenStage = stage;
      if (stage == 3 || step.type == 'arrive') {
        _speak(step.instruction);
      } else {
        _speak('بعد ${_spokenDistance(_distToNext)} ${step.instruction}');
      }
    }
  }

  void _toggleVoice() {
    setState(() => _voiceOn = !_voiceOn);
    if (!_voiceOn) {
      _tts.stop();
    }
  }

  void _updateProgress(LatLng here) {
    if (_steps.isEmpty) return;
    const distance = Distance();
    var d = distance.as(LengthUnit.Meter, here, _steps[_nextStep].point);
    while (_nextStep < _steps.length - 1 && d < 25) {
      _nextStep++;
      d = distance.as(LengthUnit.Meter, here, _steps[_nextStep].point);
    }
    _distToNext = d;
  }

  double _routeDistanceSq(LatLng p) {
    if (_routePoints.length < 2) return 0;
    const dist = Distance();
    final mLat = dist.as(
          LengthUnit.Meter,
          p,
          LatLng(p.latitude + 0.001, p.longitude),
        ) /
        0.001;
    final mLon = dist.as(
          LengthUnit.Meter,
          p,
          LatLng(p.latitude, p.longitude + 0.001),
        ) /
        0.001;
    var best = double.infinity;
    for (var i = 0; i < _routePoints.length - 1; i++) {
      final a = _routePoints[i];
      final b = _routePoints[i + 1];
      final ax = (a.longitude - p.longitude) * mLon;
      final ay = (a.latitude - p.latitude) * mLat;
      final bx = (b.longitude - p.longitude) * mLon;
      final by = (b.latitude - p.latitude) * mLat;
      final dx = bx - ax;
      final dy = by - ay;
      final len2 = dx * dx + dy * dy;
      final t = (len2 == 0 ? 0.0 : -(ax * dx + ay * dy) / len2)
          .clamp(0.0, 1.0)
          .toDouble();
      final cx = ax + t * dx;
      final cy = ay + t * dy;
      final d2 = cx * cx + cy * cy;
      if (d2 < best) best = d2;
    }
    return best;
  }

  void _checkOffRoute(LatLng here, double accuracy) {
    if (!_navigating || _rerouting || _routing) return;
    if (_routePoints.length < 2 || accuracy > 40) return;
    if (_routeDistanceSq(here) > 40 * 40) {
      _offRouteCount++;
    } else {
      _offRouteCount = 0;
      return;
    }
    if (_offRouteCount < 3) return;
    final last = _lastReroute;
    if (last != null && DateTime.now().difference(last).inSeconds < 10) {
      return;
    }
    _reroute();
  }

  Future<void> _reroute({bool announce = true, String? prefix}) async {
    _rerouting = true;
    _lastReroute = DateTime.now();
    _offRouteCount = 0;
    if (announce) _speak('جارٍ إعادة حساب المسار');
    final before = _routePoints;
    await _computeRoute(silent: true);
    _rerouting = false;
    if (!mounted || !_navigating) return;
    if (identical(before, _routePoints) || _steps.isEmpty) return;
    setState(() {
      _nextStep = _steps.length > 1 ? 1 : 0;
      _spokenStep = _nextStep;
      final here = _myLocation;
      if (here != null) _updateProgress(here);
      _spokenStage = _stageFor(_distToNext);
    });
    final step = _steps[_nextStep];
    final lead = prefix == null ? '' : '$prefix. ';
    if (step.type == 'arrive') {
      _speak('$lead${step.instruction}');
    } else {
      _speak('$lead' 'بعد ${_spokenDistance(_distToNext)} ${step.instruction}');
    }
  }

  Future<void> _checkStopReached(LatLng here) async {
    if (!_navigating || _stops.isEmpty || _rerouting || _routing) return;
    const dist = Distance();
    final stop = _stops.first;
    if (dist.as(LengthUnit.Meter, here, stop.point) > 100) return;
    setState(() => _stops = _stops.sublist(1));
    _saveState();
    final lead = _stops.isEmpty
        ? 'وصلت إلى المحطة. نكمل إلى وجهتك'
        : 'وصلت إلى المحطة. نكمل إلى المحطة التالية';
    await _reroute(announce: false, prefix: lead);
  }

  Future<void> _addStop(PlaceResult place) async {
    if (!mounted) return;
    setState(() {
      _stops = [place, ..._stops];
      _stopPanelOpen = false;
    });
    _saveState();
    _msg('أُضيفت المحطة: ${place.name}');
    if (_navigating) {
      await _reroute(announce: false);
    } else {
      await _computeRoute();
    }
  }

  Future<void> _cancelStop() async {
    if (_stops.isEmpty) return;
    setState(() => _stops = _stops.sublist(1));
    _saveState();
    if (_navigating) {
      await _reroute(announce: false);
    } else {
      await _computeRoute(silent: true);
    }
  }

  void _openStopSheet() {
    if (_routePoints.length < 2) {
      _msg('حدّد وجهة ومساراً أولاً، ثم أضف المحطة.');
      return;
    }
    setState(() => _stopPanelOpen = !_stopPanelOpen);
  }

  Widget _stopBanner() {
    final st = _stops.first;
    return Material(
      elevation: 3,
      color: kStopColors[0],
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsetsDirectional.only(start: 12, end: 4),
        child: Row(
          children: [
            const Icon(Icons.flag_circle, size: 20, color: Colors.white),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'المحطة التالية: ${st.name}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 20, color: Colors.white),
              tooltip: 'إلغاء المحطة',
              onPressed: _cancelStop,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _locateMe() async {
    if (_locating) return;
    setState(() => _locating = true);
    try {
      final enabled = await Geolocator.isLocationServiceEnabled();
      if (!enabled) {
        _msg('خدمة الموقع (GPS) مغلقة. فعّلها من إعدادات الهاتف ثم حاول مرة أخرى.');
        return;
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied) {
        _msg('لم يتم السماح بالوصول إلى الموقع، لذلك لا يمكن تحديد موقعك.');
        return;
      }
      if (permission == LocationPermission.deniedForever) {
        _msg(
          'تم رفض إذن الموقع بشكل دائم. فعّله من إعدادات التطبيق.',
          settings: true,
        );
        return;
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: const Duration(seconds: 20),
        ),
      );
      final here = LatLng(position.latitude, position.longitude);
      if (!mounted) return;
      setState(() => _myLocation = here);
      if (_destination == null) {
        _controller.move(here, 16);
      }
    } catch (_) {
      _msg('تعذّر تحديد موقعك. تأكد من تفعيل GPS وحاول مرة أخرى.');
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  Future<void> _search() async {
    final query = _searchController.text.trim();
    if (query.isEmpty || _searching) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _searching = true;
      _results = [];
    });
    try {
      final uri = Uri.https('nominatim.openstreetmap.org', '/search', {
        'q': query,
        'format': 'jsonv2',
        'limit': '8',
        'accept-language': 'ar',
      });
      final response = await http.get(
        uri,
        headers: {'User-Agent': 'Dalilik/0.1 (Flutter navigation app)'},
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        _msg('تعذّر البحث الآن (رمز ${response.statusCode}). حاول لاحقاً.');
        return;
      }

      final data = jsonDecode(utf8.decode(response.bodyBytes)) as List<dynamic>;
      final results = data.map((e) {
        return PlaceResult(
          name: e['display_name'] as String,
          point: LatLng(
            double.parse(e['lat'] as String),
            double.parse(e['lon'] as String),
          ),
        );
      }).toList();

      if (!mounted) return;
      setState(() => _results = results);
      if (results.isEmpty) {
        _msg('لا توجد نتائج لهذا البحث.');
      }
    } catch (_) {
      _msg('تعذّر البحث. تأكد من الاتصال بالإنترنت وحاول مرة أخرى.');
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  PoiCategory? _poiCategory(String key) {
    for (final c in kPoiCategories) {
      if (c.key == key) return c;
    }
    return null;
  }

  void _clearPois() {
    setState(() {
      _poiKey = null;
      _pois = [];
    });
  }

  Future<void> _loadPois(String key) async {
    final cat = _poiCategory(key);
    if (cat == null || _poiLoading) return;
    final cam = _controller.camera;
    if (cam.zoom < 14) {
      _msg('قرّب الخريطة أكثر (مستوى 14 فما فوق) لعرض الأماكن.');
      return;
    }
    final b = cam.visibleBounds;
    final box = '${b.south},${b.west},${b.north},${b.east}';
    final parts = cat.filters.map((f) => 'nwr$f($box);').join();
    final query = '[out:json][timeout:20];($parts);out center 80;';
    setState(() {
      _poiKey = key;
      _pois = [];
      _poiLoading = true;
    });
    try {
      final response = await http.post(
        Uri.parse('https://overpass-api.de/api/interpreter'),
        headers: {'User-Agent': 'Dalilik/0.1 (Flutter navigation app)'},
        body: {'data': query},
      ).timeout(const Duration(seconds: 25));
      if (response.statusCode != 200) {
        _msg('تعذّر تحميل الأماكن الآن (رمز ${response.statusCode}). حاول بعد قليل.');
        return;
      }
      final data =
          jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      final elements = (data['elements'] as List<dynamic>?) ?? [];
      final list = <Poi>[];
      for (final e in elements) {
        final m = e as Map<String, dynamic>;
        double? lat = (m['lat'] as num?)?.toDouble();
        double? lon = (m['lon'] as num?)?.toDouble();
        final center = m['center'] as Map<String, dynamic>?;
        if (lat == null && center != null) {
          lat = (center['lat'] as num?)?.toDouble();
          lon = (center['lon'] as num?)?.toDouble();
        }
        if (lat == null || lon == null) continue;
        final tags = (m['tags'] as Map<String, dynamic>?) ?? {};
        final rawName = (tags['name:ar'] ?? tags['name'] ?? '').toString();
        list.add(Poi(
          name: rawName.isNotEmpty ? rawName : cat.label,
          point: LatLng(lat, lon),
          key: key,
        ));
      }
      if (!mounted) return;
      setState(() => _pois = list);
      if (list.isEmpty) {
        _msg('لا توجد أماكن من هذا النوع مسجّلة في هذه المنطقة.');
      }
    } catch (_) {
      _msg('تعذّر تحميل الأماكن. تأكد من الاتصال بالإنترنت وحاول مرة أخرى.');
    } finally {
      if (mounted) setState(() => _poiLoading = false);
    }
  }

  void _showPoi(Poi p) {
    final cat = _poiCategory(p.key);
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(cat?.icon ?? Icons.place, color: cat?.color),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      p.name,
                      style: Theme.of(ctx).textTheme.titleMedium,
                    ),
                  ),
                ],
              ),
              if (cat != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(cat.label),
                ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _navigating
                      ? null
                      : () {
                          Navigator.pop(ctx);
                          _selectPlace(
                              PlaceResult(name: p.name, point: p.point));
                        },
                  icon: const Icon(Icons.directions),
                  label: const Text('اجعله وجهتي'),
                ),
              ),
              if (_destination != null && _routePoints.length > 1) ...[
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () {
                      Navigator.pop(ctx);
                      _addStop(PlaceResult(name: p.name, point: p.point));
                    },
                    icon: const Icon(Icons.add_location_alt),
                    label: const Text('أضفه كمحطة على الطريق'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _poiMarker(Poi p) {
    final c = _poiCategory(p.key);
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
        border: Border.all(color: c?.color ?? Colors.grey, width: 2),
        boxShadow: const [BoxShadow(blurRadius: 3, color: Colors.black38)],
      ),
      child: Icon(c?.icon ?? Icons.place, color: c?.color, size: 22),
    );
  }

  Widget _poiChips() {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 42,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          if (_poiKey != null)
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 6),
              child: ActionChip(
                avatar: const Icon(Icons.close, size: 18),
                label: const Text('إخفاء'),
                backgroundColor: scheme.surface,
                onPressed: _clearPois,
              ),
            ),
          for (final c in kPoiCategories)
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 6),
              child: ChoiceChip(
                avatar: Icon(c.icon, size: 18, color: c.color),
                label: Text(c.label),
                showCheckmark: false,
                selected: _poiKey == c.key,
                backgroundColor: scheme.surface,
                selectedColor: scheme.primaryContainer,
                onSelected: (_) => _loadPois(c.key),
              ),
            ),
          if (_poiLoading)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 3),
              ),
            ),
        ],
      ),
    );
  }

  void _selectPlace(PlaceResult place) {
    FocusScope.of(context).unfocus();
    setState(() {
      _destination = place.point;
      _destinationName = place.name;
      _stops = [];
      _results = [];
      _resetRoute();
      _addToHistory(place);
    });
    _controller.move(place.point, 17);
    _saveState();
  }

  void _setDestinationFromMap(LatLng point) {
    if (_navigating) return;
    setState(() {
      _destination = point;
      _destinationName = null;
      _stops = [];
      _results = [];
      _resetRoute();
    });
    FocusScope.of(context).unfocus();
    _saveState();
  }

  void _clearDestination() {
    setState(() {
      _destination = null;
      _destinationName = null;
      _stops = [];
      _stopPanelOpen = false;
      _resetRoute();
    });
    _saveState();
  }

  RouteOption _parseRoute(Map<String, dynamic> route) {
    final geometry = route['geometry'] as Map<String, dynamic>;
    final coordinates = geometry['coordinates'] as List<dynamic>;
    final points = coordinates.map((c) {
      final p = c as List<dynamic>;
      return LatLng((p[1] as num).toDouble(), (p[0] as num).toDouble());
    }).toList();

    final steps = <NavStep>[];
    final legs = (route['legs'] as List<dynamic>?) ?? [];
    for (var li = 0; li < legs.length; li++) {
      final leg = legs[li];
      final legSteps =
          ((leg as Map<String, dynamic>)['steps'] as List<dynamic>?) ?? [];
      for (final s in legSteps) {
        final step = s as Map<String, dynamic>;
        final maneuver = step['maneuver'] as Map<String, dynamic>;
        final loc = maneuver['location'] as List<dynamic>;
        final type = (maneuver['type'] as String?) ?? '';
        final modifier = maneuver['modifier'] as String?;
        final name = (step['name'] as String?) ?? '';
        final exit = (maneuver['exit'] as num?)?.toInt();
        steps.add(
          NavStep(
            instruction: (type == 'arrive' && li < legs.length - 1)
                ? 'وصلت إلى المحطة'
                : _arabicInstruction(type, modifier, name, exit),
            type: type,
            modifier: modifier,
            point: LatLng(
              (loc[1] as num).toDouble(),
              (loc[0] as num).toDouble(),
            ),
            distance: (step['distance'] as num).toDouble(),
            duration: (step['duration'] as num).toDouble(),
          ),
        );
      }
    }

    return RouteOption(
      points: points,
      steps: steps,
      distance: (route['distance'] as num).toDouble(),
      duration: (route['duration'] as num).toDouble(),
    );
  }

  Future<void> _computeRoute({bool silent = false}) async {
    if (_destination == null || _routing) return;

    if (_myLocation == null) {
      await _locateMe();
    }
    if (!mounted) return;

    final from = _myLocation;
    final to = _destination;
    if (from == null || to == null) {
      _msg('نحتاج موقعك الحالي لحساب المسار. فعّل GPS واسمح بالإذن ثم حاول مرة أخرى.');
      return;
    }

    setState(() => _routing = true);
    try {
      final allPoints = <LatLng>[from, ..._stops.map((st) => st.point), to];
      final coordPath =
          allPoints.map((pt) => '${pt.longitude},${pt.latitude}').join(';');
      final uri = Uri.https(
        'router.project-osrm.org',
        '/route/v1/driving/$coordPath',
        {
          'overview': 'full',
          'geometries': 'geojson',
          'steps': 'true',
          'alternatives': _stops.isEmpty ? '3' : 'false',
        },
      );
      final response = await http.get(
        uri,
        headers: {'User-Agent': 'Dalilik/0.1 (Flutter navigation app)'},
      ).timeout(const Duration(seconds: 20));

      if (response.statusCode != 200) {
        _msg('تعذّر حساب المسار الآن (رمز ${response.statusCode}). حاول لاحقاً.');
        return;
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final routes = data['routes'] as List<dynamic>?;
      if (data['code'] != 'Ok' || routes == null || routes.isEmpty) {
        _msg('لم يتم العثور على مسار بري بين موقعك وهذه الوجهة.');
        return;
      }

      final options = <RouteOption>[];
      for (final r in routes) {
        options.add(_parseRoute(r as Map<String, dynamic>));
      }

      if (!mounted) return;
      setState(() {
        _options = options;
        _selected = 0;
        _applyOption(options[0]);
      });

      if (!silent && _routePoints.length > 1) {
        _controller.fitCamera(
          CameraFit.bounds(
            bounds: LatLngBounds.fromPoints(_routePoints),
            padding: const EdgeInsets.fromLTRB(40, 200, 40, 120),
          ),
        );
      }
    } catch (_) {
      _msg('تعذّر حساب المسار. تأكد من الاتصال بالإنترنت وحاول مرة أخرى.');
    } finally {
      if (mounted) setState(() => _routing = false);
    }
  }

  Future<void> _startNavigation() async {
    if (_routePoints.length < 2 || _navigating) return;

    final enabled = await Geolocator.isLocationServiceEnabled();
    if (!enabled) {
      _msg('خدمة الموقع (GPS) مغلقة. فعّلها من إعدادات الهاتف ثم حاول مرة أخرى.');
      return;
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      _msg('نحتاج إذن الموقع لبدء الملاحة.', settings: true);
      return;
    }
    if (!mounted) return;

    setState(() {
      _navigating = true;
      _results = [];
      _speedKmh = null;
      _nextStep = _steps.length > 1 ? 1 : 0;
      _distToNext = 0;
      _spokenStep = -1;
      _spokenStage = 0;
      _offRouteCount = 0;
      _heading = 0;
      _hasHeading = false;
      final here = _myLocation;
      if (here != null) {
        _updateProgress(here);
      }
    });
    FocusScope.of(context).unfocus();
    _saveState();

    if (_myLocation != null) {
      _controller.move(_myLocation!, 17);
    }

    await _initTts();
    if (!mounted || !_navigating) return;
    _announceStart();

    await _positionSub?.cancel();
    _positionSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 5,
      ),
    ).listen(
      (position) {
        if (!mounted) return;
        final here = LatLng(position.latitude, position.longitude);
        final speed = position.speed;
        setState(() {
          _myLocation = here;
          _speedKmh = speed >= 0 ? speed * 3.6 : null;
          _updateProgress(here);
        });
        _maybeSpeak();
        _checkOffRoute(here, position.accuracy);
        _checkStopReached(here);
        final h = position.heading;
        if (speed >= 1.5 && !h.isNaN && h >= 0 && h <= 360) {
          if (!_hasHeading) {
            _heading = h;
            _hasHeading = true;
          } else {
            final diff = ((h - _heading + 540) % 360) - 180;
            _heading = (_heading + diff * 0.4 + 360) % 360;
          }
        }
        final zoom = _controller.camera.zoom;
        final z = zoom < 16 ? 17.0 : zoom;
        final scale = 1 << z.round();
        final shift = 60 * 360 * 0.85 / (256 * scale);
        if (_hasHeading) {
          final target = const Distance().offset(here, shift * 111320, _heading);
          _controller.moveAndRotate(target, z, -_heading);
        } else {
          _controller.move(LatLng(here.latitude + shift, here.longitude), z);
        }
      },
      onError: (_) {
        _msg('تعذّرت متابعة موقعك. تأكد من تفعيل GPS.');
        _stopNavigation();
      },
    );
  }

  void _stopNavigation() {
    _positionSub?.cancel();
    _positionSub = null;
    _tts.stop();
    if (!mounted) return;
    setState(() {
      _navigating = false;
      _speedKmh = null;
      _spokenStep = -1;
      _spokenStage = 0;
      _offRouteCount = 0;
      _heading = 0;
      _hasHeading = false;
    });
    _controller.rotate(0);
    _saveState();
  }

  bool get _showHistory =>
      _searchFocus.hasFocus &&
      _searchController.text.isEmpty &&
      _history.isNotEmpty;

  Widget _searchBar() {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      elevation: 4,
      color: scheme.surface,
      borderRadius: BorderRadius.circular(12),
      child: TextField(
        controller: _searchController,
        focusNode: _searchFocus,
        textInputAction: TextInputAction.search,
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) => _search(),
        decoration: InputDecoration(
          hintText: 'ابحث عن مدينة أو شارع أو مكان',
          border: InputBorder.none,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          suffixIcon: _searching
              ? const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : IconButton(
                  icon: const Icon(Icons.search),
                  onPressed: _search,
                ),
        ),
      ),
    );
  }

  Widget _historyList() {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      elevation: 4,
      color: scheme.surface,
      borderRadius: BorderRadius.circular(12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 280),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 8, 0),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'آخر عمليات البحث',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                  TextButton(
                    onPressed: _clearHistory,
                    child: const Text('مسح'),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: _history.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final place = _history[index];
                  return ListTile(
                    leading: const Icon(Icons.history),
                    title: Text(
                      place.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () => _selectPlace(place),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _resultsList() {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      elevation: 4,
      color: scheme.surface,
      borderRadius: BorderRadius.circular(12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 280),
        child: ListView.separated(
          shrinkWrap: true,
          padding: EdgeInsets.zero,
          itemCount: _results.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, index) {
            final place = _results[index];
            return ListTile(
              leading: const Icon(Icons.place_outlined),
              title: Text(
                place.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => _selectPlace(place),
            );
          },
        ),
      ),
    );
  }

  Widget _destinationCard() {
    final scheme = Theme.of(context).colorScheme;
    final hasRoute = _distanceMeters != null && _durationSeconds != null;
    var fastest = 0;
    for (var i = 1; i < _options.length; i++) {
      if (_options[i].duration < _options[fastest].duration) fastest = i;
    }
    return Material(
      elevation: 4,
      color: scheme.surface,
      borderRadius: BorderRadius.circular(12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.flag, color: Colors.red),
            title: Text(
              _destinationName ?? 'وجهة محددة على الخريطة',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: IconButton(
              icon: const Icon(Icons.close),
              onPressed: _clearDestination,
            ),
          ),
          if (hasRoute)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Row(
                children: [
                  const Icon(Icons.route, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${_formatDistance(_distanceMeters!)}  •  ${_formatDuration(_durationSeconds!)}',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                ],
              ),
            ),
          if (_options.length > 1)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (var i = 0; i < _options.length; i++)
                      ChoiceChip(
                        label: Text(_optionLabel(i, fastest)),
                        selected: i == _selected,
                        onSelected: (_) => _selectOption(i),
                      ),
                  ],
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.tonalIcon(
                onPressed: _routing ? null : () => _computeRoute(),
                icon: _routing
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.directions),
                label: Text(hasRoute ? 'إعادة حساب المسار' : 'احسب المسار'),
              ),
            ),
          ),
          if (hasRoute)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _startNavigation,
                  icon: const Icon(Icons.navigation),
                  label: const Text('ابدأ الملاحة'),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _navigationCard() {
    final scheme = Theme.of(context).colorScheme;
    final speed = _speedKmh;
    final step = _steps.isNotEmpty ? _steps[_nextStep] : null;

    var remainingMeters = _distToNext;
    var remainingSeconds = 0.0;
    for (var i = _nextStep; i < _steps.length; i++) {
      remainingMeters += _steps[i].distance;
      remainingSeconds += _steps[i].duration;
    }
    final speedText = speed == null ? '-- كم/س' : '${speed.round()} كم/س';

    return Align(
      alignment: Alignment.topLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 275),
        child: Material(
          elevation: 3,
          color: scheme.surface.withOpacity(0.92),
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    if (step != null) ...[
                      Icon(
                        _maneuverIcon(step.type, step.modifier),
                        size: 26,
                        color: scheme.primary,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _formatDistance(_distToNext),
                              style: const TextStyle(
                                fontSize: 19,
                                fontWeight: FontWeight.bold,
                                height: 1.1,
                              ),
                            ),
                            Text(
                              step.instruction,
                              style: const TextStyle(fontSize: 15, height: 1.1),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ] else
                      const Expanded(
                        child: Text(
                          'الملاحة جارية',
                          style: TextStyle(fontSize: 16),
                        ),
                      ),
                    IconButton(
                      iconSize: 20,
                      padding: const EdgeInsets.all(4),
                      constraints: const BoxConstraints(),
                      visualDensity: VisualDensity.compact,
                      tooltip: _voiceOn ? 'كتم الصوت' : 'تشغيل الصوت',
                      onPressed: _toggleVoice,
                      icon: Icon(
                        _voiceOn ? Icons.volume_up : Icons.volume_off,
                      ),
                    ),
                    IconButton(
                      iconSize: 20,
                      padding: const EdgeInsets.all(4),
                      constraints: const BoxConstraints(),
                      visualDensity: VisualDensity.compact,
                      tooltip: 'إنهاء الملاحة',
                      onPressed: _stopNavigation,
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(
                    '${_formatDistance(remainingMeters)} • ${_formatDuration(remainingSeconds)} • $speedText',
                    style: const TextStyle(fontSize: 14, height: 1.2),
                    maxLines: 1,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('دليلك'),
        centerTitle: true,
      ),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _controller,
            options: MapOptions(
              initialCenter: _start,
              initialZoom: 12,
              minZoom: 3,
              maxZoom: 18,
              onLongPress: (tapPosition, point) =>
                  _setDestinationFromMap(point),
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.dalilik.dalilik',
              ),
              if (_routePoints.length > 1)
                PolylineLayer(
                  polylines: [
                    for (var i = 0; i < _options.length; i++)
                      if (i != _selected && !_navigating)
                        Polyline(
                          points: _options[i].points,
                          strokeWidth: 5,
                          color: const Color(0xFF90A4AE),
                          borderStrokeWidth: 1.5,
                          borderColor: Colors.white,
                        ),
                    Polyline(
                      points: _routePoints,
                      strokeWidth: 6,
                      color: const Color(0xFF1565C0),
                      borderStrokeWidth: 2,
                      borderColor: Colors.white,
                    ),
                  ],
                ),
              if (_myLocation != null)
                MarkerLayer(
                  rotate: true,
                  markers: [
                    Marker(
                      point: _myLocation!,
                      width: 24,
                      height: 24,
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.blue,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 3),
                          boxShadow: const [
                            BoxShadow(blurRadius: 6, color: Colors.black38),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              if (_stops.isNotEmpty)
                MarkerLayer(
                  rotate: true,
                  markers: [
                    for (var i = 0; i < _stops.length; i++)
                      Marker(
                        point: _stops[i].point,
                        width: 40,
                        height: 40,
                        child: Icon(
                          Icons.flag_circle,
                          color: kStopColors[i % kStopColors.length],
                          size: 38,
                        ),
                      ),
                  ],
                ),
              if (_pois.isNotEmpty)
                MarkerLayer(
                  rotate: true,
                  markers: [
                    for (final p in _pois)
                      Marker(
                        point: p.point,
                        width: 40,
                        height: 40,
                        child: GestureDetector(
                          onTap: () => _showPoi(p),
                          child: _poiMarker(p),
                        ),
                      ),
                  ],
                ),
              if (_destination != null)
                MarkerLayer(
                  rotate: true,
                  markers: [
                    Marker(
                      point: _destination!,
                      width: 44,
                      height: 44,
                      alignment: Alignment.topCenter,
                      child: const Icon(
                        Icons.location_on,
                        color: Colors.red,
                        size: 44,
                      ),
                    ),
                  ],
                ),
              RichAttributionWidget(
                attributions: [
                  TextSourceAttribution('© مساهمو OpenStreetMap'),
                ],
              ),
            ],
          ),
          Positioned(
            left: 16,
            bottom: 48,
            child: Column(
              children: [
                FloatingActionButton.small(
                  heroTag: 'zoom_in',
                  onPressed: () => _zoom(1),
                  child: const Icon(Icons.add),
                ),
                const SizedBox(height: 8),
                FloatingActionButton.small(
                  heroTag: 'zoom_out',
                  onPressed: () => _zoom(-1),
                  child: const Icon(Icons.remove),
                ),
              ],
            ),
          ),
          if (_destination != null && _routePoints.length > 1)
            Positioned(
              right: 16,
              bottom: 136,
              child: FloatingActionButton.small(
                heroTag: 'add_stop',
                tooltip: 'إضافة محطة على الطريق',
                onPressed: _openStopSheet,
                child: const Icon(Icons.add_location_alt),
              ),
            ),
          Positioned(
            right: 16,
            bottom: 64,
            child: FloatingActionButton(
              heroTag: 'locate',
              onPressed: _locateMe,
              child: _locating
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 3),
                    )
                  : const Icon(Icons.my_location),
            ),
          ),
          Positioned(
            top: 8,
            left: 12,
            right: 12,
            child: Column(
              children: [
                if (_navigating)
                  _navigationCard()
                else ...[
                  _searchBar(),
                  if (_results.isEmpty && !_showHistory) ...[
                    const SizedBox(height: 8),
                    _poiChips(),
                  ],
                  if (_results.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    _resultsList(),
                  ] else if (_showHistory) ...[
                    const SizedBox(height: 8),
                    _historyList(),
                  ] else if (_destination != null) ...[
                    const SizedBox(height: 8),
                    _destinationCard(),
                  ],
                ],
                if (_stops.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  _stopBanner(),
                ],
                if (_stopPanelOpen && _routePoints.length > 1) ...[
                  const SizedBox(height: 8),
                  StopSheet(
                    key: const ValueKey('stop_panel'),
                    route: _routePoints,
                    me: _myLocation,
                    onPick: _addStop,
                    onClose: () => setState(() => _stopPanelOpen = false),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
