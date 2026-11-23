import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'connect_view.dart';
import 'pairing.dart';
import 'signaling.dart';

enum LinkState {
  idle('Ready'),
  connecting('Connecting via USB'),
  streaming('Live over USB'),
  failed('Problem');

  const LinkState(this.label);

  final String label;
}

const _serviceChannel = MethodChannel('beamcam/service');

enum Framing {
  landscape(
    'Landscape',
    'Wide standard 16:9 for meetings',
    Icons.stay_current_landscape,
    [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight],
  ),
  portrait(
    'Portrait',
    'Tall 9:16 frame',
    Icons.stay_current_portrait,
    [DeviceOrientation.portraitUp],
  ),
  auto(
    'Auto',
    'Rotates with phone orientation',
    Icons.screen_rotation,
    DeviceOrientation.values,
  );

  const Framing(this.label, this.note, this.icon, this.orientations);

  final String label;
  final String note;
  final IconData icon;
  final List<DeviceOrientation> orientations;
}

enum Quality {
  sd('480p', 640, 480, 30, 2000000, 'Low bandwidth'),
  hd('720p', 1280, 720, 30, 5000000, 'Fast & smooth'),
  fhd('1080p', 1920, 1080, 30, 10000000, 'Full HD (Standard)'),
  fhd60('1080p60', 1920, 1080, 60, 15000000, 'Smooth 60 fps'),
  qhd('1440p (2K)', 2560, 1440, 30, 25000000, '2K Quad HD'),
  uhd4k('2160p (4K)', 3840, 2160, 30, 40000000, '4K Ultra HD');

  const Quality(
    this.label,
    this.w,
    this.h,
    this.fps,
    this.maxBitrate,
    this.note,
  );

  final String label;
  final int w;
  final int h;
  final int fps;
  final int maxBitrate;
  final String note;

  String get spec =>
      '$w × $h · $fps fps · up to ${(maxBitrate / 1e6).toStringAsFixed(0)} Mbps';
}

class SenderPage extends StatefulWidget {
  const SenderPage({super.key});

  @override
  State<SenderPage> createState() => _SenderPageState();
}

class _SenderPageState extends State<SenderPage> {
  final _renderer = RTCVideoRenderer();

  WebSocket? _socket;
  RTCPeerConnection? _pc;
  MediaStream? _stream;

  LinkState _state = LinkState.idle;
  String _status = '';
  bool _front = false;
  Quality _quality = Quality.fhd;
  Framing _framing = Framing.landscape;
  bool _keepAlive = true;

  bool _videoEnabled = true;
  bool _audioEnabled = false;
  bool _preview = true;

  bool _mirror = false;
  bool _flip = false;

  // Zoom controls
  double _zoomLevel = 1.0;
  double _baseScale = 1.0;
  final double _minZoom = 1.0;
  final double _maxZoom = 8.0;

  // Battery saver / Stealth blackout mode
  bool _blackScreenMode = false;

  PairingPayload _target = PairingPayload.usb;
  bool _session = false;
  bool _restarting = false;
  DateTime? _liveSince;
  String? _videoTrackId;
  bool _disposed = false;

  bool get _live =>
      _state == LinkState.streaming || _state == LinkState.connecting;

  bool get _onStream => _session || _restarting;

  @override
  void initState() {
    super.initState();
    unawaited(_renderer.initialize());
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
  }

  @override
  void dispose() {
    _disposed = true;
    _teardown();
    _renderer.dispose();
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    super.dispose();
  }

  // ------------------------------------------------------------- Connection

  Future<void> _connectTo(PairingPayload target) async {
    if (!mounted) return;
    if (_session) {
      setState(() => _restarting = true);
      await _teardown();
      if (!mounted) return;
    }
    setState(() {
      _restarting = false;
      _state = LinkState.idle;
      _target = target;
    });
    await _start();
  }

  // ------------------------------------------------------------- Controls

  Future<void> _setFraming(Framing framing) async {
    setState(() => _framing = framing);
    await SystemChrome.setPreferredOrientations(
      _onStream ? framing.orientations : DeviceOrientation.values,
    );
    await Future<void>.delayed(const Duration(milliseconds: 700));
    await _pinRotation();
  }

  void _sendTransform() {
    _socket?.add(
      Signal('transform', {'mirror': _mirror, 'flip': _flip}).encode(),
    );
  }

  void _setTransform({bool? mirror, bool? flip}) {
    setState(() {
      _mirror = mirror ?? _mirror;
      _flip = flip ?? _flip;
    });
    _sendTransform();
  }

  Future<void> _setZoom(double zoom) async {
    final clamped = zoom.clamp(_minZoom, _maxZoom);
    setState(() => _zoomLevel = clamped);
    if (_stream != null) {
      final tracks = _stream!.getVideoTracks();
      if (tracks.isNotEmpty) {
        try {
          await Helper.setZoom(tracks.first, clamped);
        } catch (e) {
          debugPrint('BeamCam: setZoom error $e');
        }
      }
    }
  }

  void _toggleBlackScreen(bool enable) {
    setState(() => _blackScreenMode = enable);
    if (enable) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }

  Future<void> _pinRotation() async {
    final trackId = _videoTrackId;
    if (trackId == null) return;
    try {
      await _serviceChannel.invokeMethod('pinRotation', {'trackId': trackId});
    } on PlatformException catch (e) {
      _log('Rotation pin failed: ${e.message}');
    } on MissingPluginException {
      // Non-Android host
    }
  }

  Future<void> _setVideoEnabled(bool enabled) async {
    if (!enabled && !_audioEnabled) return;
    await _restartWith(() => _videoEnabled = enabled);
  }

  Future<void> _setAudioEnabled(bool enabled) async {
    if (!enabled && !_videoEnabled) return;
    await _restartWith(() => _audioEnabled = enabled);
  }

  Future<void> _setKeepScreenOn(bool enabled) async {
    if (!Platform.isAndroid) return;
    try {
      await _serviceChannel.invokeMethod('setKeepScreenOn', {'enabled': enabled});
    } catch (_) {}
  }

  Future<void> _syncBackgroundService({required bool shouldRun}) async {
    if (!Platform.isAndroid) return;
    try {
      await _serviceChannel.invokeMethod(
        shouldRun ? 'startBackground' : 'stopBackground',
        shouldRun ? {'video': _videoEnabled, 'audio': _audioEnabled} : null,
      );
    } catch (_) {}
  }

  void _setPreview(bool on) {
    setState(() => _preview = on);
    if (_stream != null) _renderer.srcObject = on ? _stream : null;
  }

  void _log(String msg, {LinkState? state}) {
    if (!mounted) return;
    setState(() {
      _status = msg;
      if (state != null) _state = state;
    });
  }

  Future<void> _start() async {
    if (_state == LinkState.connecting || _state == LinkState.streaming) return;
    if (!_videoEnabled && !_audioEnabled) {
      _log('Turn on camera or microphone first.', state: LinkState.failed);
      return;
    }

    setState(() {
      _session = true;
      _state = LinkState.connecting;
      _status = 'Opening camera…';
    });
    unawaited(_setKeepScreenOn(true));

    try {
      final preset = _quality;
      _stream = await navigator.mediaDevices.getUserMedia({
        'audio': _audioEnabled,
        'video': _videoEnabled
            ? {
                'facingMode': _front ? 'user' : 'environment',
                'width': {'ideal': preset.w},
                'height': {'ideal': preset.h},
                'frameRate': {'ideal': preset.fps},
              }
            : false,
      });

      _renderer.srcObject = _preview ? _stream : null;
      if (mounted) setState(() {});

      final videoTracks = _stream!.getVideoTracks();
      _videoTrackId = videoTracks.isEmpty ? null : videoTracks.first.id;

      // Apply initial zoom
      if (videoTracks.isNotEmpty && _zoomLevel != 1.0) {
        try {
          await Helper.setZoom(videoTracks.first, _zoomLevel);
        } catch (_) {}
      }

      await SystemChrome.setPreferredOrientations(_framing.orientations);
      await Future<void>.delayed(const Duration(milliseconds: 700));
      await _pinRotation();

      if (_keepAlive) await _syncBackgroundService(shouldRun: true);

      _log('Connecting over USB tunnel (127.0.0.1:${_target.port})…');
      final socket = await WebSocket.connect(
        'ws://${_target.host}:${_target.port}$kSignalPath',
      ).timeout(const Duration(seconds: 6));
      _socket = socket;

      final pc = await createPeerConnection(kRtcConfig);
      _pc = pc;

      pc.onIceCandidate = (candidate) {
        if (candidate.candidate == null) return;
        socket.add(Signal.ice(candidate).encode());
      };

      pc.onConnectionState = (s) {
        switch (s) {
          case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
            _liveSince = DateTime.now();
            _log('Connected via USB', state: LinkState.streaming);
          case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
            _log(
              'USB connection dropped. Check cable and adb reverse.',
              state: LinkState.failed,
            );
            unawaited(_teardown());
          case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
            _log('Reconnecting USB…', state: LinkState.connecting);
          default:
            break;
        }
      };

      for (final track in _stream!.getTracks()) {
        await pc.addTrack(track, _stream!);
      }

      socket.listen(
        (raw) => _onSignal(Signal.decode(raw as String)),
        onDone: () {
          if (!identical(_socket, socket)) return;
          _log('Mac closed the USB connection.', state: LinkState.failed);
          unawaited(_teardown());
        },
        onError: (Object e) {
          if (!identical(_socket, socket)) return;
          _log('USB connection error — $e', state: LinkState.failed);
          unawaited(_teardown());
        },
      );

      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      await _capBitrate(pc, preset.maxBitrate, preset.fps);
      socket.add(
        Signal('offer', {'sdp': offer.sdp, 'sdpType': offer.type}).encode(),
      );
      _log('Waiting for Mac companion to answer…');
    } on TimeoutException {
      _log(
        'Could not reach Mac on USB. Ensure "adb reverse tcp:8787 tcp:8787" is active on your Mac.',
        state: LinkState.failed,
      );
      await _teardown();
    } catch (e) {
      _log('Could not start — $e', state: LinkState.failed);
      await _teardown();
    }
  }

  Future<void> _capBitrate(RTCPeerConnection pc, int bps, int fps) async {
    try {
      RTCRtpSender? video;
      for (final sender in await pc.getSenders()) {
        if (sender.track?.kind == 'video') {
          video = sender;
          break;
        }
      }
      if (video == null) return;
      final params = video.parameters;
      final encodings = params.encodings;
      if (encodings == null || encodings.isEmpty) return;
      for (final encoding in encodings) {
        encoding.maxBitrate = bps;
        encoding.maxFramerate = fps;
      }
      await video.setParameters(params);
    } catch (_) {}
  }

  Future<void> _onSignal(Signal signal) async {
    final pc = _pc;
    if (pc == null) return;
    switch (signal.type) {
      case 'answer':
        await pc.setRemoteDescription(
          RTCSessionDescription(
            signal.data['sdp'] as String,
            signal.data['sdpType'] as String,
          ),
        );
        _log('Live over USB', state: LinkState.streaming);
      case 'ice':
        await pc.addCandidate(signal.toCandidate());
      default:
        break;
    }
  }

  Future<void> _teardown() async {
    unawaited(_setKeepScreenOn(false));
    if (!_disposed && mounted) {
      setState(() {
        _session = false;
        _liveSince = null;
      });
    } else {
      _session = false;
      _liveSince = null;
    }

    await _syncBackgroundService(shouldRun: false);
    if (_videoTrackId != null) {
      try {
        await _serviceChannel.invokeMethod('unpinRotation', {
          'trackId': _videoTrackId,
        });
      } catch (_) {}
      _videoTrackId = null;
    }
    final socket = _socket;
    _socket = null;
    await socket?.close();
    final pc = _pc;
    _pc = null;
    await pc?.close();
    for (final track in _stream?.getTracks() ?? const <MediaStreamTrack>[]) {
      await track.stop();
    }
    await _stream?.dispose();
    _stream = null;
    if (!_disposed) _renderer.srcObject = null;
  }

  Future<void> _stop() async {
    unawaited(SystemChrome.setPreferredOrientations(DeviceOrientation.values));
    await _teardown();
    _log('Stopped', state: LinkState.idle);
  }

  Future<void> _restartWith(void Function() mutate) async {
    if (_restarting) return;
    final wasLive = _session;
    if (wasLive) setState(() => _restarting = true);
    await _teardown();
    if (!mounted) return;
    setState(() {
      _state = LinkState.idle;
      _restarting = false;
      mutate();
    });
    if (wasLive) await _start();
  }

  // ------------------------------------------------------------- Build UI

  @override
  Widget build(BuildContext context) {
    if (_blackScreenMode) {
      return _buildBlackScreenView();
    }
    return _onStream ? _streamScreen(context) : _connectScreen();
  }

  Widget _connectScreen() {
    return ConnectView(
      onConnect: (p) => unawaited(_connectTo(p)),
      error: _state == LinkState.failed ? _status : null,
    );
  }

  Widget _buildBlackScreenView() {
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onDoubleTap: () => _toggleBlackScreen(false),
        child: SizedBox.expand(
          child: SafeArea(
            child: Stack(
              children: [
                Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.videocam,
                        color: Colors.white.withValues(alpha: 0.12),
                        size: 48,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Stealth Mode · Camera Streaming over USB',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.20),
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Double tap anywhere to wake up screen',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.35),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                Positioned(
                  bottom: 24,
                  right: 24,
                  child: IconButton.filledTonal(
                    style: IconButton.styleFrom(
                      backgroundColor: Colors.white.withValues(alpha: 0.15),
                      foregroundColor: Colors.white70,
                    ),
                    icon: const Icon(Icons.wb_sunny_outlined),
                    tooltip: 'Wake screen',
                    onPressed: () => _toggleBlackScreen(false),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _streamScreen(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final landscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Disconnect',
          onPressed: () => unawaited(_stop()),
        ),
        title: const Text('USB Camera Live'),
        actions: [
          IconButton(
            icon: const Icon(Icons.dark_mode_outlined),
            tooltip: 'Turn screen off (Save battery)',
            onPressed: () => _toggleBlackScreen(true),
          ),
          const SizedBox(width: 8),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(20),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(left: 16, bottom: 8),
              child: Text(
                _state.label,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: _state == LinkState.streaming
                      ? scheme.primary
                      : scheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
      ),
      body: SafeArea(
        child: landscape
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(16, 0, 8, 16),
                      child: _stage(context),
                    ),
                  ),
                  SizedBox(
                    width: 380,
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(8, 8, 16, 16),
                      child: _controls(context),
                    ),
                  ),
                ],
              )
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                children: [
                  _stage(context),
                  const SizedBox(height: 16),
                  _controls(context),
                ],
              ),
      ),
    );
  }

  Widget _stage(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 4),
        _Elapsed(since: _liveSince),
        const SizedBox(height: 12),
        if (_preview && _videoEnabled) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(19),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 320),
                  child: AspectRatio(
                    aspectRatio: 16 / 9,
                    child: ColoredBox(
                      color: Colors.black,
                      child: _stream == null
                          ? const SizedBox.shrink()
                          : GestureDetector(
                              onScaleStart: (details) {
                                _baseScale = _zoomLevel;
                              },
                              onScaleUpdate: (details) {
                                _setZoom(_baseScale * details.scale);
                              },
                              child: Stack(
                                children: [
                                  Positioned.fill(
                                    child: RTCVideoView(
                                      _renderer,
                                      mirror: _front ? !_mirror : _mirror,
                                      objectFit: RTCVideoViewObjectFit
                                          .RTCVideoViewObjectFitCover,
                                    ),
                                  ),
                                  if (_zoomLevel > 1.0)
                                    Positioned(
                                      bottom: 12,
                                      right: 12,
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 4,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.black54,
                                          borderRadius:
                                              BorderRadius.circular(8),
                                        ),
                                        child: Text(
                                          '${_zoomLevel.toStringAsFixed(1)}x',
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 12,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            FilledButton.tonalIcon(
              onPressed: () => _toggleBlackScreen(true),
              icon: const Icon(Icons.nightlight_round),
              label: const Text('Black Screen Mode'),
            ),
            const SizedBox(width: 12),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: theme.colorScheme.errorContainer,
                foregroundColor: theme.colorScheme.onErrorContainer,
              ),
              onPressed: () => unawaited(_stop()),
              icon: const Icon(Icons.stop_circle_outlined),
              label: const Text('Stop'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _controls(BuildContext context) {
    return Card(
      child: Column(
        children: [
          SwitchListTile(
            secondary: const Icon(Icons.videocam_outlined),
            title: const Text('Camera Video'),
            subtitle: const Text('Stream video over USB'),
            value: _videoEnabled,
            onChanged: (v) => unawaited(_setVideoEnabled(v)),
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          SwitchListTile(
            secondary: const Icon(Icons.mic_none_outlined),
            title: const Text('Microphone Audio'),
            subtitle: const Text('Stream audio to Mac'),
            value: _audioEnabled,
            onChanged: (v) => unawaited(_setAudioEnabled(v)),
          ),
          if (_videoEnabled) ...[
            const Divider(height: 1, indent: 16, endIndent: 16),
            ListTile(
              leading: const Icon(Icons.zoom_in),
              title: Text('Zoom: ${_zoomLevel.toStringAsFixed(1)}x'),
              subtitle: Slider(
                value: _zoomLevel,
                min: _minZoom,
                max: _maxZoom,
                divisions: 28,
                label: '${_zoomLevel.toStringAsFixed(1)}x',
                onChanged: (v) => _setZoom(v),
              ),
              trailing: IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: 'Reset Zoom (1.0x)',
                onPressed: () => _setZoom(1.0),
              ),
            ),
            const Divider(height: 1, indent: 16, endIndent: 16),
            ListTile(
              leading: const Icon(Icons.cameraswitch_outlined),
              title: const Text('Camera Lens'),
              subtitle: Text(_front ? 'Front Camera' : 'Back Camera'),
              onTap: () => unawaited(_restartWith(() => _front = !_front)),
            ),
            const Divider(height: 1, indent: 16, endIndent: 16),
            ListTile(
              leading: const Icon(Icons.high_quality_outlined),
              title: const Text('Resolution & Quality'),
              subtitle: Text('${_quality.label} · ${_quality.spec}'),
              onTap: () => unawaited(_pickQuality(context)),
            ),
            const Divider(height: 1, indent: 16, endIndent: 16),
            ListTile(
              leading: Icon(_framing.icon),
              title: const Text('Framing & Orientation'),
              subtitle: Text('${_framing.label} (${_framing.note})'),
              onTap: () => unawaited(_pickFraming(context)),
            ),
            const Divider(height: 1, indent: 16, endIndent: 16),
            SwitchListTile(
              secondary: const Icon(Icons.flip),
              title: const Text('Mirror Video'),
              subtitle: const Text('Flip left to right'),
              value: _mirror,
              onChanged: (v) => _setTransform(mirror: v),
            ),
            const Divider(height: 1, indent: 16, endIndent: 16),
            SwitchListTile(
              secondary: const Icon(Icons.flip_camera_android_outlined),
              title: const Text('Flip Video'),
              subtitle: const Text('Turn picture upside down'),
              value: _flip,
              onChanged: (v) => _setTransform(flip: v),
            ),
            const Divider(height: 1, indent: 16, endIndent: 16),
            SwitchListTile(
              secondary: const Icon(Icons.visibility_outlined),
              title: const Text('On-screen Preview'),
              subtitle: const Text('Disabling saves phone GPU and battery'),
              value: _preview,
              onChanged: _setPreview,
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _pickQuality(BuildContext context) async {
    final picked = await showModalBottomSheet<Quality>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                'Video Resolution (over USB)',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            for (final q in Quality.values)
              RadioListTile<Quality>(
                value: q,
                groupValue: _quality,
                title: Text(q.label),
                subtitle: Text(q.spec),
                onChanged: (v) => Navigator.of(context).pop(v),
              ),
          ],
        ),
      ),
    );
    if (picked != null && picked != _quality) {
      await _restartWith(() => _quality = picked);
    }
  }

  Future<void> _pickFraming(BuildContext context) async {
    final picked = await showModalBottomSheet<Framing>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                'Framing Format',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            for (final f in Framing.values)
              RadioListTile<Framing>(
                value: f,
                groupValue: _framing,
                secondary: Icon(f.icon),
                title: Text(f.label),
                subtitle: Text(f.note),
                onChanged: (v) => Navigator.of(context).pop(v),
              ),
          ],
        ),
      ),
    );
    if (picked != null && picked != _framing) {
      await _setFraming(picked);
    }
  }
}

class _Elapsed extends StatefulWidget {
  const _Elapsed({required this.since});

  final DateTime? since;

  @override
  State<_Elapsed> createState() => _ElapsedState();
}

class _ElapsedState extends State<_Elapsed> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _arm();
  }

  @override
  void didUpdateWidget(covariant _Elapsed old) {
    super.didUpdateWidget(old);
    if (old.since != widget.since) _arm();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _arm() {
    _timer?.cancel();
    if (widget.since == null) return;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final since = widget.since;
    if (since == null) {
      return Text('00:00', style: theme.textTheme.displaySmall);
    }
    final d = DateTime.now().difference(since);
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final h = d.inHours;
    final text = h > 0 ? '$h:$m:$s' : '$m:$s';
    return Text(
      text,
      style: theme.textTheme.displaySmall?.copyWith(
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}
