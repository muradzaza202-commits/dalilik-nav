import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
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

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final MapController _controller = MapController();
  static const LatLng _start = LatLng(24.7136, 46.6753);

  LatLng? _myLocation;
  bool _locating = false;

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
      _controller.move(here, 16);
    } catch (e) {
      _msg('تعذّر تحديد موقعك. تأكد من تفعيل GPS وحاول مرة أخرى.');
    } finally {
      if (mounted) setState(() => _locating = false);
    }
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
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.dalilik.dalilik',
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
        ],
      ),
    );
  }
}
