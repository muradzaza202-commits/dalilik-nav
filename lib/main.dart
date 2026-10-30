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

// END-2
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

// END-3
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

// END-4
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

// END-5
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

// END-6
  
