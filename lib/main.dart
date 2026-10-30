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

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final MapController _controller = MapController();
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  static const LatLng _start = LatLng(24.7136, 46.6753);

  static const String _historyKey = 'dalilik_search_history';
  static const int _historyMax = 10;
  List<PlaceResult> _history = [];

  LatLng? _myLocation;
  bool _locating = false;

  bool _searching = false;
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
    _loadHistory();
  }

  @override
  void dispose() {
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

  Future<void> _reroute() async {
    _rerouting = true;
    _lastReroute = DateTime.now();
    _offRouteCount = 0;
    _speak('جارٍ إعادة حساب المسار');
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
    if (step.type == 'arrive') {
      _speak(step.instruction);
    } else {
      _speak('بعد ${_spokenDistance(_distToNext)} ${step.instruction}');
    }
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

  void _selectPlace(PlaceResult place) {
    FocusScope.of(context).unfocus();
    setState(() {
      _destination = place.point;
      _destinationName = place.name;
      _results = [];
      _resetRoute();
      _addToHistory(place);
    });
    _controller.move(place.point, 17);
  }

  void _setDestinationFromMap(LatLng point) {
    if (_navigating) return;
    setState(() {
      _destination = point;
      _destinationName = null;
      _results = [];
      _resetRoute();
    });
    FocusScope.of(context).unfocus();
  }

  void _clearDestination() {
    setState(() {
      _destination = null;
      _destinationName = null;
      _resetRoute();
    });
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
    for (final leg in legs) {
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
            instruction: _arabicInstruction(type, modifier, name, exit),
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
      final uri = Uri.https(
        'router.project-osrm.org',
        '/route/v1/driving/${from.longitude},${from.latitude};${to.longitude},${to.latitude}',
        {
          'overview': 'full',
          'geometries': 'geojson',
          'steps': 'true',
          'alternatives': '3',
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
