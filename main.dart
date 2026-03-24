import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

// ─────────────────────────────────────────────────────────────
//  JoyCon Gyro Cursor Driver
//  Dependencies (pubspec.yaml):
//    flutter_blue_plus: ^1.31.0
//    permission_handler: ^11.0.0
// ─────────────────────────────────────────────────────────────

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const JoyConApp());
}

class JoyConApp extends StatelessWidget {
  const JoyConApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'JoyCon Cursor',
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark().copyWith(
          scaffoldBackgroundColor: const Color(0xFF0A0A0F),
          colorScheme: const ColorScheme.dark(
            primary: Color(0xFF00E5FF),
            secondary: Color(0xFFFF2D78),
          ),
        ),
        home: const CursorOverlay(),
      );
}

// ─────────────────────────────────────────────────────────────
//  CURSOR OVERLAY — full-screen transparent canvas + UI
// ─────────────────────────────────────────────────────────────
class CursorOverlay extends StatefulWidget {
  const CursorOverlay({super.key});
  @override
  State<CursorOverlay> createState() => _CursorOverlayState();
}

class _CursorOverlayState extends State<CursorOverlay>
    with TickerProviderStateMixin {

  // Cursor position
  double _cx = 0, _cy = 0;
  double _velX = 0, _velY = 0;

  // Settings
  double _sensitivity = 8;
  double _deadZone    = 8;
  double _smoothing   = 5;

  // State
  bool _connected    = false;
  bool _scanning     = false;
  bool _clicking     = false;
  bool _calibrating  = false;

  // Calibration drift
  double _calibGX = 0, _calibGY = 0;
  final List<Map<String, double>> _calibSamples = [];

  // Log
  final List<_LogEntry> _log = [];

  // BLE
  BluetoothDevice? _device;
  StreamSubscription? _notifySub;
  StreamSubscription? _stateSub;

  // Ripples
  final List<_Ripple> _ripples = [];

  // Joy-Con Nintendo Vendor ID
  static const int _nintendoVendor = 0x057e;

  late AnimationController _cursorAnim;

  @override
  void initState() {
    super.initState();
    _cursorAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 120),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final size = MediaQuery.of(context).size;
      setState(() { _cx = size.width / 2; _cy = size.height / 2; });
    });
    _addLog('Готово к подключению', LogType.info);
    _addLog('Joy-Con L/R, Pro Controller', LogType.info);
  }

  @override
  void dispose() {
    _cursorAnim.dispose();
    _notifySub?.cancel();
    _stateSub?.cancel();
    super.dispose();
  }

  // ── LOG ──────────────────────────────────────────────────
  void _addLog(String msg, LogType type) {
    setState(() {
      _log.insert(0, _LogEntry(msg, type, DateTime.now()));
      if (_log.length > 40) _log.removeLast();
    });
  }

  // ── MOVE CURSOR ──────────────────────────────────────────
  void _moveCursor(double dx, double dy) {
    final size = MediaQuery.of(context).size;
    final alpha = _smoothing / 10.0;
    _velX = _velX * (1 - alpha) + dx * alpha;
    _velY = _velY * (1 - alpha) + dy * alpha;
    setState(() {
      _cx = (_cx + _velX).clamp(0, size.width);
      _cy = (_cy + _velY).clamp(0, size.height);
    });
  }

  double _applyDead(double v) {
    if (v.abs() < _deadZone) return 0;
    return v > 0 ? v - _deadZone : v + _deadZone;
  }

  // ── CLICK ────────────────────────────────────────────────
  void _doClick({bool right = false}) {
    setState(() {
      _clicking = true;
      _ripples.add(_Ripple(_cx, _cy));
    });
    _addLog(right ? 'ZR — ПКМ' : 'ZL — ЛКМ', LogType.ok);
    Future.delayed(const Duration(milliseconds: 150), () {
      if (mounted) setState(() => _clicking = false);
    });
    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted) setState(() => _ripples.removeWhere((r) => r.id == _ripples.first.id));
    });
  }

  // ── BLE CONNECT ──────────────────────────────────────────
  Future<void> _connect() async {
    if (_connected) { await _disconnect(); return; }

    setState(() => _scanning = true);
    _addLog('Поиск Joy-Con...', LogType.info);

    try {
      // Check BT state
      final state = await FlutterBluePlus.adapterState.first;
      if (state != BluetoothAdapterState.on) {
        _addLog('Включи Bluetooth!', LogType.warn);
        setState(() => _scanning = false);
        return;
      }

      // Scan for Nintendo devices
      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 10),
        withNames: ['Joy-Con (L)', 'Joy-Con (R)', 'Pro Controller'],
      );

      BluetoothDevice? found;
      await for (final results in FlutterBluePlus.scanResults) {
        for (final r in results) {
          final name = r.device.platformName.toLowerCase();
          if (name.contains('joy-con') || name.contains('pro controller')) {
            found = r.device;
            break;
          }
        }
        if (found != null) break;
      }

      await FlutterBluePlus.stopScan();

      if (found == null) {
        _addLog('Joy-Con не найден. Убедись что он в режиме сопряжения.', LogType.warn);
        setState(() => _scanning = false);
        return;
      }

      _addLog('Найден: ${found.platformName}', LogType.ok);
      _device = found;

      await found.connect(timeout: const Duration(seconds: 10));
      _addLog('Подключено ✓', LogType.ok);

      _stateSub = found.connectionState.listen((s) {
        if (s == BluetoothConnectionState.disconnected) {
          _addLog('Соединение потеряно', LogType.warn);
          setState(() => _connected = false);
        }
      });

      // Discover services
      final services = await found.discoverServices();
      _addLog('Сервисов найдено: ${services.length}', LogType.info);

      // Joy-Con HID service UUID
      // Nintendo uses custom UUIDs for HID over BLE on some firmware
      // Standard HID Service: 0x1812
      BluetoothCharacteristic? hidChar;
      for (final svc in services) {
        for (final char in svc.characteristics) {
          final props = char.properties;
          if (props.notify || props.indicate) {
            hidChar = char;
            _addLog('HID char: ${char.uuid}', LogType.info);
          }
        }
      }

      if (hidChar == null) {
        _addLog('HID характеристика не найдена', LogType.warn);
        _addLog('Попробуй подключить Joy-Con через системный Bluetooth', LogType.warn);
      } else {
        await hidChar.setNotifyValue(true);
        _notifySub = hidChar.lastValueStream.listen(_onHIDData);
        _addLog('Слушаю HID данные...', LogType.ok);
      }

      setState(() {
        _connected = true;
        _scanning  = false;
      });

      // Calibrate
      await Future.delayed(const Duration(milliseconds: 300));
      _startCalibration();

    } catch (e) {
      _addLog('Ошибка: $e', LogType.err);
      setState(() => _scanning = false);
    }
  }

  Future<void> _disconnect() async {
    _notifySub?.cancel();
    _stateSub?.cancel();
    await _device?.disconnect();
    _device = null;
    setState(() => _connected = false);
    _addLog('Отключено', LogType.warn);
  }

  // ── CALIBRATION ──────────────────────────────────────────
  void _startCalibration() {
    _calibrating = true;
    _calibSamples.clear();
    _addLog('Калибровка... держи неподвижно', LogType.warn);
    Future.delayed(const Duration(milliseconds: 1500), () {
      if (_calibSamples.isNotEmpty) {
        _calibGX = _calibSamples.map((s) => s['gx']!).reduce((a, b) => a + b) / _calibSamples.length;
        _calibGY = _calibSamples.map((s) => s['gy']!).reduce((a, b) => a + b) / _calibSamples.length;
      }
      _calibrating = false;
      _addLog('Калибровка готова (drift: ${_calibGX.toStringAsFixed(0)}, ${_calibGY.toStringAsFixed(0)})', LogType.ok);
    });
  }

  // ── HID DATA PARSER ──────────────────────────────────────
  // Joy-Con Full Input Report 0x30:
  // [0]  = report id (0x30)
  // [1]  = timer
  // [2]  = battery | connection
  // [3..5] = button status
  // [6..11] = left stick / right stick
  // [13..] = IMU samples (3x12 bytes)
  //   each: gyroX(i16le), gyroY(i16le), gyroZ(i16le),
  //         accX(i16le),  accY(i16le),  accZ(i16le)
  void _onHIDData(List<int> data) {
    if (data.isEmpty) return;
    final bytes = Uint8List.fromList(data);
    final reportId = bytes[0];

    if (reportId != 0x30 && reportId != 0x31 && reportId != 0x33) return;
    if (bytes.length < 25) return;

    final bd = ByteData.sublistView(bytes);

    // Buttons
    final btn1 = bytes.length > 3 ? bytes[3] : 0;
    final zl = (btn1 & 0x40) != 0;
    final zr = (btn1 & 0x80) != 0;

    // IMU — first sample at offset 13
    final gx = bd.getInt16(13, Endian.little).toDouble();
    final gy = bd.getInt16(15, Endian.little).toDouble();
    final gz = bd.getInt16(17, Endian.little).toDouble();

    if (_calibrating) {
      _calibSamples.add({'gx': gx, 'gy': gy});
      return;
    }

    // Apply calibration
    final cgx = gx - _calibGX;
    final cgy = gy - _calibGY;

    // Apply dead zone + scale
    final dx = _applyDead(cgy) * _sensitivity * 0.001;
    final dy = _applyDead(cgx) * _sensitivity * 0.001;

    _moveCursor(dx, dy);

    // Buttons (edge detection)
    if (zl && !_lastZL) _doClick(right: false);
    if (zr && !_lastZR) _doClick(right: true);
    _lastZL = zl;
    _lastZR = zr;

    // Store raw for UI
    setState(() {
      _rawGX = cgx; _rawGY = cgy; _rawGZ = gz;
    });
  }

  bool _lastZL = false, _lastZR = false;
  double _rawGX = 0, _rawGY = 0, _rawGZ = 0;

  // ─────────────────────────────────────────────────────────
  //  BUILD
  // ─────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;

    return Scaffold(
      body: Stack(
        children: [
          // ── BACKGROUND ──
          Container(
            decoration: const BoxDecoration(
              gradient: RadialGradient(
                center: Alignment.topLeft,
                radius: 1.5,
                colors: [Color(0xFF0D0D1A), Color(0xFF0A0A0F)],
              ),
            ),
          ),

          // ── MAIN UI ──
          SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildHeader(),
                  const SizedBox(height: 14),
                  _buildConnectBtn(),
                  const SizedBox(height: 12),
                  _buildPositionRow(),
                  const SizedBox(height: 10),
                  _buildGyroBars(),
                  const SizedBox(height: 10),
                  _buildSettings(),
                  const SizedBox(height: 10),
                  _buildLog(),
                ],
              ),
            ),
          ),

          // ── RIPPLES ──
          ..._ripples.map((r) => Positioned(
            left: r.x - 30, top: r.y - 30,
            child: _RippleWidget(key: ValueKey(r.id)),
          )),

          // ── CURSOR ──
          if (_connected)
            Positioned(
              left: _cx - 14, top: _cy - 2,
              child: AnimatedScale(
                scale: _clicking ? 0.75 : 1.0,
                duration: const Duration(milliseconds: 100),
                child: CustomPaint(
                  size: const Size(28, 32),
                  painter: _CursorPainter(clicking: _clicking),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ── HEADER ──────────────────────────────────────────────
  Widget _buildHeader() => Row(
    children: [
      Container(
        width: 44, height: 44,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF00E5FF), Color(0xFFFF2D78)],
            begin: Alignment.topLeft, end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Center(child: Text('🕹', style: TextStyle(fontSize: 22))),
      ),
      const SizedBox(width: 12),
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ShaderMask(
            shaderCallback: (b) => const LinearGradient(
              colors: [Color(0xFF00E5FF), Colors.white],
            ).createShader(b),
            child: const Text('JoyCon Cursor',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900,
                color: Colors.white, letterSpacing: -0.5)),
          ),
          const Text('GYRO → POINTER DRIVER v1.0',
            style: TextStyle(fontSize: 10, color: Color(0xFF555570),
              letterSpacing: 0.8)),
        ],
      ),
      const Spacer(),
      _buildStatusBadge(),
    ],
  );

  Widget _buildStatusBadge() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    decoration: BoxDecoration(
      color: const Color(0xFF111118),
      border: Border.all(color: const Color(0xFF1E1E2E)),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          width: 8, height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _connected
                ? const Color(0xFF00FF88)
                : _scanning
                    ? const Color(0xFF00E5FF)
                    : const Color(0xFF555570),
            boxShadow: _connected ? [
              const BoxShadow(color: Color(0xFF00FF88), blurRadius: 6)
            ] : null,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          _connected ? 'ON' : _scanning ? '...' : 'OFF',
          style: const TextStyle(fontSize: 11,
            fontFamily: 'monospace', color: Colors.white),
        ),
      ],
    ),
  );

  // ── CONNECT BUTTON ──────────────────────────────────────
  Widget _buildConnectBtn() => GestureDetector(
    onTap: _scanning ? null : _connect,
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: _connected
              ? [const Color(0xFFFF2D78), const Color(0xFF880033)]
              : [const Color(0xFF00E5FF), const Color(0xFF0077AA)],
        ),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Center(
        child: _scanning
            ? const SizedBox(width: 20, height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2, color: Colors.black))
            : Text(
                _connected ? '⛔  Отключить' : '🔵  Подключить Joy-Con',
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800,
                  color: Colors.black, letterSpacing: 0.3),
              ),
      ),
    ),
  );

  // ── POSITION ROW ────────────────────────────────────────
  Widget _buildPositionRow() => Row(
    children: [
      Expanded(child: _buildPanel('CURSOR X', '${_cx.toStringAsFixed(0)} px')),
      const SizedBox(width: 10),
      Expanded(child: _buildPanel('CURSOR Y', '${_cy.toStringAsFixed(0)} px')),
    ],
  );

  Widget _buildPanel(String label, String value) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: const Color(0xFF111118),
      border: Border.all(color: const Color(0xFF1E1E2E)),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 10, color: Color(0xFF555570),
          letterSpacing: 1, fontFamily: 'monospace')),
        const SizedBox(height: 6),
        Text(value, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700,
          fontFamily: 'monospace')),
      ],
    ),
  );

  // ── GYRO BARS ───────────────────────────────────────────
  Widget _buildGyroBars() => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: const Color(0xFF111118),
      border: Border.all(color: const Color(0xFF1E1E2E)),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('ГИРОСКОП', style: TextStyle(fontSize: 10,
          color: Color(0xFF555570), letterSpacing: 1, fontFamily: 'monospace')),
        const SizedBox(height: 10),
        _gyroBar('GX', _rawGX, 800),
        _gyroBar('GY', _rawGY, 800),
        _gyroBar('GZ', _rawGZ, 800),
      ],
    ),
  );

  Widget _gyroBar(String label, double val, double max) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      children: [
        SizedBox(width: 24,
          child: Text(label, style: const TextStyle(fontSize: 11,
            color: Color(0xFF555570), fontFamily: 'monospace'))),
        Expanded(
          child: LayoutBuilder(builder: (ctx, c) {
            final half = c.maxWidth / 2;
            final pct  = (val.abs() / max * half).clamp(0.0, half);
            return Stack(
              children: [
                Container(height: 6,
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E1E2E),
                    borderRadius: BorderRadius.circular(3))),
                Positioned(
                  left: val >= 0 ? half : half - pct,
                  child: Container(
                    width: pct, height: 6,
                    decoration: BoxDecoration(
                      color: val >= 0
                        ? const Color(0xFF00E5FF)
                        : const Color(0xFFFF2D78),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
              ],
            );
          }),
        ),
        SizedBox(width: 46,
          child: Text(val.toStringAsFixed(0),
            textAlign: TextAlign.right,
            style: const TextStyle(fontSize: 10, fontFamily: 'monospace'))),
      ],
    ),
  );

  // ── SETTINGS ────────────────────────────────────────────
  Widget _buildSettings() => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: const Color(0xFF111118),
      border: Border.all(color: const Color(0xFF1E1E2E)),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('НАСТРОЙКИ', style: TextStyle(fontSize: 10,
          color: Color(0xFF555570), letterSpacing: 1, fontFamily: 'monospace')),
        const SizedBox(height: 8),
        _settingSlider('Чувствительность', _sensitivity, 1, 20, (v) => setState(() => _sensitivity = v)),
        _settingSlider('Dead zone',         _deadZone,    0, 30, (v) => setState(() => _deadZone = v)),
        _settingSlider('Сглаживание',       _smoothing,   1, 10, (v) => setState(() => _smoothing = v)),
      ],
    ),
  );

  Widget _settingSlider(String name, double val, double min, double max, ValueChanged<double> onChanged) =>
    Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(width: 130, child: Text(name,
            style: const TextStyle(fontSize: 13))),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
                activeTrackColor: const Color(0xFF00E5FF),
                inactiveTrackColor: const Color(0xFF1E1E2E),
                thumbColor: const Color(0xFF00E5FF),
                overlayColor: const Color(0x2200E5FF),
              ),
              child: Slider(value: val, min: min, max: max, onChanged: onChanged),
            ),
          ),
          SizedBox(width: 32,
            child: Text(val.toStringAsFixed(0),
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 11,
                color: Color(0xFF00E5FF), fontFamily: 'monospace'))),
        ],
      ),
    );

  // ── LOG ─────────────────────────────────────────────────
  Widget _buildLog() => Container(
    height: 90,
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: const Color(0xFF111118),
      border: Border.all(color: const Color(0xFF1E1E2E)),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('ЛОГ', style: TextStyle(fontSize: 10,
          color: Color(0xFF555570), letterSpacing: 1, fontFamily: 'monospace')),
        const SizedBox(height: 6),
        Expanded(
          child: ListView.builder(
            reverse: false,
            itemCount: _log.length,
            itemBuilder: (_, i) {
              final e = _log[i];
              return Text(
                '[${e.time.hour.toString().padLeft(2,'0')}:'
                '${e.time.minute.toString().padLeft(2,'0')}:'
                '${e.time.second.toString().padLeft(2,'0')}] ${e.msg}',
                style: TextStyle(
                  fontSize: 10, fontFamily: 'monospace',
                  color: switch(e.type) {
                    LogType.ok   => const Color(0xFF00FF88),
                    LogType.warn => const Color(0xFFFFCC00),
                    LogType.err  => const Color(0xFFFF2D78),
                    LogType.info => const Color(0xFF00E5FF),
                  },
                ),
              );
            },
          ),
        ),
      ],
    ),
  );
}

// ─────────────────────────────────────────────────────────────
//  CURSOR PAINTER
// ─────────────────────────────────────────────────────────────
class _CursorPainter extends CustomPainter {
  final bool clicking;
  const _CursorPainter({this.clicking = false});

  @override
  void paint(Canvas canvas, Size size) {
    final color = clicking ? const Color(0xFFFF2D78) : const Color(0xFF00E5FF);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    final stroke = Paint()
      ..color = const Color(0xFF003344)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;

    // Glow
    final glow = Paint()
      ..color = color.withOpacity(0.4)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);

    final path = Path()
      ..moveTo(4, 2)
      ..lineTo(4, 22)
      ..lineTo(9, 17)
      ..lineTo(13, 28)
      ..lineTo(16, 26)
      ..lineTo(12, 15)
      ..lineTo(20, 15)
      ..close();

    canvas.drawPath(path, glow);
    canvas.drawPath(path, paint);
    canvas.drawPath(path, stroke);
  }

  @override
  bool shouldRepaint(_CursorPainter old) => old.clicking != clicking;
}

// ─────────────────────────────────────────────────────────────
//  RIPPLE WIDGET
// ─────────────────────────────────────────────────────────────
class _RippleWidget extends StatefulWidget {
  const _RippleWidget({super.key});
  @override
  State<_RippleWidget> createState() => _RippleWidgetState();
}

class _RippleWidgetState extends State<_RippleWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _scale, _opacity;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 500))
      ..forward();
    _scale   = Tween(begin: 0.0, end: 1.0).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOut));
    _opacity = Tween(begin: 1.0, end: 0.0).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOut));
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _ctrl,
    builder: (_, __) => Transform.scale(
      scale: _scale.value,
      child: Opacity(
        opacity: _opacity.value,
        child: Container(
          width: 60, height: 60,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: const Color(0xFFFF2D78), width: 2),
          ),
        ),
      ),
    ),
  );
}

// ─────────────────────────────────────────────────────────────
//  MODELS
// ─────────────────────────────────────────────────────────────
enum LogType { info, ok, warn, err }

class _LogEntry {
  final String msg;
  final LogType type;
  final DateTime time;
  _LogEntry(this.msg, this.type, this.time);
}

class _Ripple {
  final double x, y;
  final int id;
  static int _counter = 0;
  _Ripple(this.x, this.y) : id = _counter++;
}
