/// BLE access to the collar behind a small interface, so the rest of the app (and the
/// tests) never touch the BLE library directly (ADR 0012).
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:universal_ble/universal_ble.dart';

import '../core/contracts.dart';
import '../core/sync_protocol.dart';
import 'sync_service.dart';

class FoundCollar {
  const FoundCollar(this.id, this.name, this.rssi);
  final String id;
  final String name;
  final int? rssi;
}

abstract class CollarLink {
  /// Collars advertising any of `services` (raw logger by default, ADR 0010; normal collar
  /// firmware: sync service, ADR 0013, which also serves raw dump mode, ADR 0014).
  Stream<FoundCollar> scan({List<String> services = const [rawServiceUuid]});
  Future<void> stopScan();

  /// Connects, asks for a large MTU and subscribes to raw packets. Returns the MTU.
  Future<int> connect(String collarId);
  Stream<List<int>> rawPackets(String collarId);
  Future<void> disconnect(String collarId);
}

class UniversalBleCollarLink implements CollarLink {
  final _found = StreamController<FoundCollar>.broadcast();

  @override
  Stream<FoundCollar> scan({List<String> services = const [rawServiceUuid]}) {
    UniversalBle.onScanResult = (d) =>
        _found.add(FoundCollar(d.deviceId, d.name ?? loggerName, d.rssi));
    unawaited(
      UniversalBle.startScan(scanFilter: ScanFilter(withServices: services)),
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

/// BLE transport for the summary sync service (contract 4.8) on top of universal_ble.
class UniversalBleSyncTransport implements SyncTransport {
  @override
  Future<void> connect(String collarId) async {
    await UniversalBle.connect(collarId, timeout: const Duration(seconds: 20));
    await UniversalBle.discoverServices(collarId);
    try {
      await UniversalBle.requestMtu(
        collarId,
        247,
      ); // 16 records per notification need 243
    } catch (_) {
      // iOS negotiates on its own; smaller MTUs just mean fewer records per notification
    }
  }

  @override
  Future<void> write(String collarId, String characteristic, Uint8List value) =>
      UniversalBle.write(collarId, syncServiceUuid, characteristic, value);

  @override
  Stream<List<int>> notifications(String collarId, String characteristic) =>
      UniversalBle.characteristicValueStream(collarId, characteristic);

  @override
  Future<void> subscribe(String collarId, String characteristic) =>
      UniversalBle.subscribeNotifications(
        collarId,
        syncServiceUuid,
        characteristic,
      );

  @override
  Future<void> disconnect(String collarId) => UniversalBle.disconnect(collarId);
}
