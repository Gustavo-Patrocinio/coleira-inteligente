/// BLE access to the collar behind a small interface, so the rest of the app (and the
/// tests) never touch the BLE library directly (ADR 0012).
library;

import 'dart:async';

import 'package:universal_ble/universal_ble.dart';

import '../core/contracts.dart';

class FoundCollar {
  const FoundCollar(this.id, this.name, this.rssi);
  final String id;
  final String name;
  final int? rssi;
}

abstract class CollarLink {
  /// Collars advertising the raw data service (ADR 0010).
  Stream<FoundCollar> scan();
  Future<void> stopScan();

  /// Connects, asks for a large MTU and subscribes to raw packets. Returns the MTU.
  Future<int> connect(String collarId);
  Stream<List<int>> rawPackets(String collarId);
  Future<void> disconnect(String collarId);
}

class UniversalBleCollarLink implements CollarLink {
  final _found = StreamController<FoundCollar>.broadcast();

  @override
  Stream<FoundCollar> scan() {
    UniversalBle.onScanResult = (d) =>
        _found.add(FoundCollar(d.deviceId, d.name ?? loggerName, d.rssi));
    unawaited(
      UniversalBle.startScan(
        scanFilter: ScanFilter(withServices: [rawServiceUuid]),
      ),
    );
    return _found.stream;
  }

  @override
  Future<void> stopScan() async {
    await UniversalBle.stopScan();
    UniversalBle.onScanResult = null;
  }

  @override
  Future<int> connect(String collarId) async {
    await UniversalBle.connect(collarId, timeout: const Duration(seconds: 20));
    await UniversalBle.discoverServices(collarId);
    // 128-byte packets need MTU ≥ 131. iOS negotiates on its own; Android needs the request.
    int mtu;
    try {
      mtu = await UniversalBle.requestMtu(collarId, 247);
    } catch (_) {
      mtu = 0; // platform decides; the recorder will see bad packets if it is too small
    }
    await UniversalBle.subscribeNotifications(
      collarId,
      rawServiceUuid,
      rawCharUuid,
    );
    return mtu;
  }

  @override
  Stream<List<int>> rawPackets(String collarId) =>
      UniversalBle.characteristicValueStream(collarId, rawCharUuid);

  @override
  Future<void> disconnect(String collarId) => UniversalBle.disconnect(collarId);
}
