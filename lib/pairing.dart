import 'signaling.dart';

const String kUsbHost = '127.0.0.1';

class PairingPayload {
  const PairingPayload({
    this.host = kUsbHost,
    this.port = kSignalPort,
    this.name = 'USB Cable',
  });

  final String host;
  final int port;
  final String name;

  static PairingPayload get usb => const PairingPayload(
    host: kUsbHost,
    port: kSignalPort,
    name: 'USB Cable',
  );

  @override
  bool operator ==(Object other) =>
      other is PairingPayload && other.host == host && other.port == port;

  @override
  int get hashCode => Object.hash(host, port);
}
