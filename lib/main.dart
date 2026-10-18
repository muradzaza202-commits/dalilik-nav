import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

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
}

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final MapController _controller = MapController();
  final TextEditingController _searchController = TextEditingController();
  static const LatLng _start = LatLng(24.7136, 46.6753);

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

  bool _navigating = false;
  StreamSubscription<Position>? _positionSub;
  double? _speedKmh;

  @override
  void dispose() {
    _positionSub?.cancel();
    _searchController.dispose();
    super.dispose();
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
    setState(() {
      _destination = place.point;
      _destinationName = place.name;
      _results = [];
      _resetRoute();
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

  Future<void> _computeRoute() async {
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
        {'overview': 'full', 'geometries': 'geojson'},
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

      final route = routes[0] as Map<String, dynamic>;
      final geometry = route['geometry'] as Map<String, dynamic>;
      final coordinates = geometry['coordinates'] as List<dynamic>;
      final points = coordinates.map((c) {
        final p = c as List<dynamic>;
        return LatLng((p[1] as num).toDouble(), (p[0] as num).toDouble());
      }).toList();

      if (!mounted) return;
      setState(() {
        _routePoints = points;
        _distanceMeters = (route['distance'] as num).toDouble();
        _durationSeconds = (route['duration'] as num).toDouble();
      });

      if (points.length > 1) {
        _controller.fitCamera(
          CameraFit.bounds(
            bounds: LatLngBounds.fromPoints(points),
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
    });
    FocusScope.of(context).unfocus();

    if (_myLocation != null) {
      _controller.move(_myLocation!, 17);
    }

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
        });
        final zoom = _controller.camera.zoom;
        _controller.move(here, zoom < 16 ? 17 : zoom);
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
    if (!mounted) return;
    setState(() {
      _navigating = false;
      _speedKmh = null;
    });
  }

  Widget _searchBar() {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      elevation: 4,
      color: scheme.surface,
      borderRadius: BorderRadius.circular(12),
      child: TextField(
        controller: _searchController,
        textInputAction: TextInputAction.search,
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
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.tonalIcon(
                onPressed: _routing ? null : _computeRoute,
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
    return Material(
      elevation: 4,
      color: scheme.surface,
      borderRadius: BorderRadius.circular(12),
      child: ListTile(
        leading: Icon(Icons.navigation, color: scheme.primary),
        title: const Text('الملاحة جارية'),
        subtitle: Text(
          speed == null
              ? 'جارٍ تحديد السرعة...'
              : 'السرعة: ${speed.round()} كم/س',
        ),
        trailing: FilledButton.tonal(
          onPressed: _stopNavigation,
          child: const Text('إنهاء'),
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
              if (_destination != null)
                MarkerLayer(
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
                  if (_results.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    _resultsList(),
                  ] else if (_destination != null) ...[
                    const SizedBox(height: 8),
                    _destinationCard(),
                  ],
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
