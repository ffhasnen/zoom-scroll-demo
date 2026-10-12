import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:go_router/go_router.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  usePathUrlStrategy();
  runApp(const AoPortalApp());
}

GoRouter createRouter() => GoRouter(
      routes: [
        GoRoute(path: '/', builder: (context, state) => const HomePage()),
      ],
    );

class MyAppScrollBehavior extends MaterialScrollBehavior {
  @override
  Set<PointerDeviceKind> get dragDevices => {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.trackpad,
      };

  // FIX (1/3): lists must stop hard at their edge (no iOS bounce).
  // Only then does Flutter report the "extra" drag (OverscrollNotification)
  // that we hand over to the InteractiveViewer below.
  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      const ClampingScrollPhysics();
}

/// Used only while 2 fingers are down: no list can scroll, so the
/// pinch is never stolen by a scroll.
class _PinchingScrollBehavior extends MyAppScrollBehavior {
  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      const NeverScrollableScrollPhysics();
}

class AoPortalApp extends StatefulWidget {
  const AoPortalApp({super.key});

  @override
  State<AoPortalApp> createState() => _AoPortalAppState();
}

class _AoPortalAppState extends State<AoPortalApp> {
  late final GoRouter _router;
  final _zoomController = TransformationController();
  bool _isZoomed = false;

  @override
  void initState() {
    super.initState();
    _router = createRouter();
    _zoomController.addListener(_onZoomChanged);
  }

  @override
  void dispose() {
    _zoomController.dispose();
    super.dispose();
  }

  void _onZoomChanged() {
    final isZoomed = _zoomController.value.getMaxScaleOnAxis() > 1.01;
    if (isZoomed != _isZoomed) {
      setState(() => _isZoomed = isZoomed);
    }
  }

  // FIX (2/3): a table/list is already at its edge and the finger keeps
  // dragging -> move the zoomed view instead (like a normal web page does).
  bool _onOverscroll(OverscrollNotification n, Size viewport) {
    if (!_isZoomed || n.dragDetails == null) return false;

    final m = _zoomController.value;
    final scale = m.getMaxScaleOnAxis();
    final move = -n.overscroll * scale;
    final t = m.getTranslation();
    var x = t.x, y = t.y;
    if (n.metrics.axis == Axis.horizontal) {
      x += move;
    } else {
      y += move;
    }
    // Keep the page inside the screen.
    x = x.clamp(viewport.width * (1 - scale), 0.0);
    y = y.clamp(viewport.height * (1 - scale), 0.0);

    _zoomController.value = m.clone()..setTranslationRaw(x, y, 0);
    return false;
  }

  // FIX (3/3): pinch always wins over scroll.
  // A Listener sees every finger, even when a list already took the touch.
  // With 2 fingers down we stop all scrolling and zoom ourselves.
  final _fingers = <int, Offset>{};
  bool _pinching = false;
  double _pinchStartDistance = 0;
  double _pinchStartScale = 1;
  Offset _pinchScenePoint = Offset.zero;

  void _onFingerDown(PointerDownEvent e) {
    _fingers[e.pointer] = e.localPosition;
    if (_fingers.length == 2) _startPinch();
  }

  void _onFingerMove(PointerMoveEvent e, Size viewport) {
    if (!_fingers.containsKey(e.pointer)) return;
    _fingers[e.pointer] = e.localPosition;
    if (!_pinching || _fingers.length < 2) return;

    final (a, b) = _twoFingers();
    final focal = (a + b) / 2;
    final scale = (_pinchStartScale * (a - b).distance / _pinchStartDistance)
        .clamp(1.0, 4.0);
    // Keep the spot that was under the fingers under the fingers.
    final x = (focal.dx - _pinchScenePoint.dx * scale)
        .clamp(viewport.width * (1 - scale), 0.0);
    final y = (focal.dy - _pinchScenePoint.dy * scale)
        .clamp(viewport.height * (1 - scale), 0.0);
    _zoomController.value = Matrix4.diagonal3Values(scale, scale, 1)
      ..setTranslationRaw(x, y, 0);
  }

  void _onFingerUp(PointerEvent e) {
    _fingers.remove(e.pointer);
    if (_fingers.length < 2 && _pinching) setState(() => _pinching = false);
  }

  void _startPinch() {
    final (a, b) = _twoFingers();
    _pinchStartDistance = (a - b).distance.clamp(1.0, double.infinity);
    _pinchStartScale = _zoomController.value.getMaxScaleOnAxis();
    _pinchScenePoint = _zoomController.toScene((a + b) / 2);
    setState(() => _pinching = true); // turns scrolling off (see build)
  }

  (Offset, Offset) _twoFingers() {
    final p = _fingers.values.take(2).toList();
    return (p[0], p[1]);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      theme: ThemeData(useMaterial3: false),
      builder: (context, child) {
        // Enable InteractiveViewer only on Android and iOS
        final isMobile = kIsWeb &&
            (defaultTargetPlatform == TargetPlatform.android ||
                defaultTargetPlatform == TargetPlatform.iOS);

        final content = child!;

        // Mobile → Enable zoom
        if (isMobile) {
          return LayoutBuilder(
            builder: (context, constraints) => Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: _onFingerDown,
              onPointerMove: (e) => _onFingerMove(e, constraints.biggest),
              onPointerUp: _onFingerUp,
              onPointerCancel: _onFingerUp,
              child: NotificationListener<OverscrollNotification>(
                onNotification: (n) => _onOverscroll(n, constraints.biggest),
                child: InteractiveViewer(
                  transformationController: _zoomController,
                  trackpadScrollCausesScale: false,
                  panEnabled: _isZoomed && !_pinching,
                  // Pinch is handled by the Listener above (FIX 3/3).
                  scaleEnabled: false,
                  minScale: 1.0,
                  maxScale: 4.0,
                  child: ScrollConfiguration(
                    behavior: _pinching
                        ? _PinchingScrollBehavior()
                        : MyAppScrollBehavior(),
                    child: content,
                  ),
                ),
              ),
            ),
          );
        }

        // Web/Desktop → Normal scrolling, no zoom
        return content;
      },
      routerConfig: _router,
      debugShowCheckedModeBanner: false,
      title: 'Zoom + Scroll Demo',
    );
  }
}

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Zoom + Scroll Demo')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          const Text(
            'Pinch to zoom in. Scroll the table all the way to the left, '
            'lift your finger, then drag right again: the zoomed page moves.',
          ),
          const SizedBox(height: 16),
          const Text('Wide table', style: TextStyle(fontSize: 18)),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columns: const [
                DataColumn(label: Text('S.No.')),
                DataColumn(label: Text('Form Type')),
                DataColumn(label: Text('Section')),
                DataColumn(label: Text('Deductee')),
                DataColumn(label: Text('Amount')),
                DataColumn(label: Text('Rate')),
                DataColumn(label: Text('Remarks')),
              ],
              rows: List.generate(
                15,
                (i) => DataRow(cells: [
                  DataCell(Text('${i + 1}')),
                  const DataCell(Text('Form 144')),
                  const DataCell(Text('393(3) [Table: Sl. No. 1], 393(2)')),
                  const DataCell(Text('Association of Persons (AOP)')),
                  const DataCell(Text('₹50,00,001 – ₹1,00,00,000')),
                  const DataCell(Text('10%')),
                  const DataCell(Text('Tax on long-term capital gains')),
                ]),
              ),
            ),
          ),
          const SizedBox(height: 24),
          const Text('Horizontal list', style: TextStyle(fontSize: 18)),
          const SizedBox(height: 8),
          SizedBox(
            height: 120,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: 20,
              itemBuilder: (context, i) => Container(
                width: 140,
                margin: const EdgeInsets.only(right: 8),
                color: Colors.primaries[i % Colors.primaries.length].shade200,
                alignment: Alignment.center,
                child: Text('Card ${i + 1}'),
              ),
            ),
          ),
          const SizedBox(height: 24),
          ...List.generate(
            20,
            (i) => ListTile(title: Text('Normal row ${i + 1}')),
          ),
        ],
      ),
    );
  }
}
