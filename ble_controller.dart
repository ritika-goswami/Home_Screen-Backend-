import 'dart:convert';
import 'dart:async';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

class BLEController {
  // --- SINGLETON SETUP ---
  static final BLEController _instance = BLEController._internal();
  factory BLEController() => _instance;
  BLEController._internal();
  // -----------------------

  // UUIDs — Perfectly aligned with Rohit's ESP32 Firmware Constants
  static const String serviceUuid = "12345678-1234-1234-1234-123456789abc";
  static const String characteristicUuid = "abcd1234-ab12-cd34-ef56-abcdef123456"; // Write Commands
  static const String batUuid = "abcd1235-ab12-cd34-ef56-abcdef123456";           // Read Battery
  static const String targetDeviceName = "Easeband";

  BluetoothDevice? connectedDevice;
  BluetoothCharacteristic? targetCharacteristic; // Command Char mapping
  BluetoothCharacteristic? batteryCharacteristic; // Battery Char mapping
  StreamSubscription? scanSubscription;
  StreamSubscription? _batteryNotifySubscription; // ★ track so we can cancel cleanly on reconnect
  Timer? _batteryRetryTimer; // ★ retries the manual read if it comes back empty

  // --- BRAIDED NOTIFICATION STREAM CHANNELS FOR THE UI ---
  final StreamController<bool> _connectionStream = StreamController<bool>.broadcast();
  Stream<bool> get connectionStream => _connectionStream.stream;

  final StreamController<String> _batteryStream = StreamController<String>.broadcast();
  Stream<String> get batteryStream => _batteryStream.stream;

  // 1. IMPROVED AUTOMATIC DISCOVERY AND SCANNING
  Future<void> connectToDevice() async {
    // Prevent double execution loops if already paired up
    if (connectedDevice != null) {
      print("Already connected to ${connectedDevice!.platformName}");
      return;
    }

    // Shield configuration check for system BT state
    if (await FlutterBluePlus.adapterState.first != BluetoothAdapterState.on) {
      print("Bluetooth is OFF. Please turn it on in settings.");
      _connectionStream.add(false);
      return;
    }

    // Clean internal system scan stack memory space
    await FlutterBluePlus.stopScan();

    print("Starting Scan for $targetDeviceName...");

    await FlutterBluePlus.startScan(
      timeout: const Duration(seconds: 15),
      androidUsesFineLocation: true,
    );

    scanSubscription = FlutterBluePlus.scanResults.listen((results) async {
      for (ScanResult r in results) {
        String devName = r.device.platformName.isNotEmpty
            ? r.device.platformName
            : r.advertisementData.advName;

        if (devName == targetDeviceName) {
          print("Found $targetDeviceName! Attempting to connect...");

          await FlutterBluePlus.stopScan();
          scanSubscription?.cancel();

          try {
            // Immediate high-priority master-slave pairing execution profile
            await r.device.connect(autoConnect: false, timeout: const Duration(seconds: 10));
            connectedDevice = r.device;

            // Monitor state changes on the device line
            r.device.connectionState.listen((state) {
              if (state == BluetoothConnectionState.disconnected) {
                _handleDisconnectClean();
              }
            });

            await _setupServices();
          } catch (e) {
            print("Connection error: $e");
            _connectionStream.add(false);
          }
          break;
        }
      }
    }, onError: (e) => print("Scan Subscription Error: $e"));
  }

  // 2. DISCOVER & COMPARTMENTALIZE CONTROLLER CHARACTERISTICS
  Future<void> _setupServices() async {
    if (connectedDevice == null) return;

    try {
      List<BluetoothService> services = await connectedDevice!.discoverServices();
      for (var service in services) {
        if (service.uuid.toString().toLowerCase() == serviceUuid.toLowerCase()) {
          for (var char in service.characteristics) {
            String currentUuid = char.uuid.toString().toLowerCase();

            // A. Map Command/Write Node
            if (currentUuid == characteristicUuid.toLowerCase()) {
              targetCharacteristic = char;
              print("Easeband Command Characteristic Ready.");
            }

            // B. Map Battery Monitor/Notify Node
            if (currentUuid == batUuid.toLowerCase()) {
              batteryCharacteristic = char;
              print("Easeband Battery Characteristic Located.");
              await _setupBatteryMonitoring();
            }
          }
        }
      }

      // Notify the Home Screen UI framework that connection is verified
      _connectionStream.add(true);
    } catch (e) {
      print("Error discovering peripheral database entities: $e");
    }
  }

  // ★ NEW — isolated, retry-aware battery setup
  Future<void> _setupBatteryMonitoring() async {
    if (batteryCharacteristic == null) return;

    // Cancel any stale subscription from a previous connection before re-subscribing
    await _batteryNotifySubscription?.cancel();
    _batteryRetryTimer?.cancel();

    // 1. Subscribe to live notifications (covers the 30s periodic updates)
    await batteryCharacteristic!.setNotifyValue(true);
    _batteryNotifySubscription = batteryCharacteristic!.onValueReceived.listen((value) {
      if (value.isNotEmpty) {
        String decodedPct = utf8.decode(value);
        print("Live Battery Notification Broadcasted: $decodedPct%");
        _batteryStream.add(decodedPct);
      }
    });

    // 2. Try an immediate manual read so the UI doesn't sit blank until the
    //    next 30s notify cycle. The ESP32 now seeds a real value at boot,
    //    so this should succeed on the first try — but we retry a couple
    //    times in case the GATT read races the characteristic init.
    await _readBatteryWithRetry();
  }

  // ★ NEW — retries the manual read up to 3 times, 1.5s apart, since a
  // freshly-connected peripheral can occasionally return an empty packet
  // on the very first GATT read.
  Future<void> _readBatteryWithRetry({int attempt = 1}) async {
    if (batteryCharacteristic == null) return;

    try {
      List<int> initialPacket = await batteryCharacteristic!.read();
      if (initialPacket.isNotEmpty) {
        String decodedPct = utf8.decode(initialPacket);
        print("Manual battery read succeeded on attempt $attempt: $decodedPct%");
        _batteryStream.add(decodedPct);
        return; // success — no retry needed
      } else {
        print("Manual battery read returned empty on attempt $attempt");
      }
    } catch (e) {
      print("Battery handshake reading baseline skipped (attempt $attempt): $e");
    }

    // Retry up to 3 attempts total, then give up and just wait for notify
    if (attempt < 3) {
      _batteryRetryTimer = Timer(const Duration(milliseconds: 1500), () {
        _readBatteryWithRetry(attempt: attempt + 1);
      });
    } else {
      print("Battery read retries exhausted — waiting on next notify cycle instead.");
    }
  }

  // 3. LOW-LATENCY REALTIME COMMAND PIPELINE
  Future<void> sendCommand(String command) async {
    if (targetCharacteristic == null) {
      print("Error: No peripheral mapping established. Triggering recovery...");
      connectToDevice();
      return;
    }

    try {
      await targetCharacteristic!.write(
        utf8.encode(command),
        withoutResponse: true, // Bypasses acknowledgement delay layers
      );
      print("Sent command successfully: $command");
    } catch (e) {
      print("Failed to dispatch active command string over the air: $e");
    }
  }

  // 4. RESOURCE DISPOSAL & CLEANUPS
  void _handleDisconnectClean() {
    connectedDevice = null;
    targetCharacteristic = null;
    batteryCharacteristic = null;
    _batteryNotifySubscription?.cancel();
    _batteryRetryTimer?.cancel();
    _connectionStream.add(false);
    print("Easeband disconnected — Internal hardware state maps flushed cleanly.");
  }

  Future<void> disconnect() async {
    scanSubscription?.cancel();
    _batteryNotifySubscription?.cancel();
    _batteryRetryTimer?.cancel();
    await connectedDevice?.disconnect();
    _handleDisconnectClean();
  }

  void dispose() {
    _batteryNotifySubscription?.cancel();
    _batteryRetryTimer?.cancel();
    _connectionStream.close();
    _batteryStream.close();
  }
}
