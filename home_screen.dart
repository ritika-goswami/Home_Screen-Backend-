import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';
import 'package:easeflow_app/user_data.dart'; 
import 'package:easeflow_app/ble_controller.dart';
import 'package:cloud_firestore/cloud_firestore.dart'; 
import 'package:easeflow_app/screens/profile_screen.dart'; 

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  // --- BLE INSTANCE ---
  final BLEController _bleController = BLEController();
  bool isConnected = false;
  Timer? _statusTimer;
  StreamSubscription? _batteryUiSubscription; // Real-time stream monitor

  bool isFrontSelected = true;

  // --- STATE VARIABLES (LOCKED INITIAL STATE FOR BOOTUP) ---
  String selectedFrontHeat = "Off";      // Enforced initial baseline
  String selectedBackHeat = "Off";       // Enforced initial baseline
  String selectedFrontDuration = "Select"; // Enforced initial baseline
  String selectedBackDuration = "Select";  // Enforced initial baseline
  String selectedVibration = "Off";      // Enforced initial baseline
  String selectedVibType = "Select";      // Enforced initial baseline
  String _userName = "there"; 
  String _batteryLevel = "0%";           // Starts at 0% explicitly on open

  @override
  void initState() {
    super.initState();
    _loadSavedSettings();
    _fetchNameFromFirestore(); 
    
    // Wire up the live battery metrics notification sub
    _batteryUiSubscription = _bleController.batteryStream.listen((liveBatteryValue) {
      if (mounted && liveBatteryValue.isNotEmpty) {
        setState(() {
          // Formats the pure incoming string parsed from ESP32 to percentage
          _batteryLevel = "$liveBatteryValue%";
        });
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initBluetooth();
    });
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    _batteryUiSubscription?.cancel(); // Safety clean to avoid resource leakage
    super.dispose();
  }

  // --- LOGIC FOR NAME ---
  Future<void> _fetchNameFromFirestore() async {
    final prefs = await SharedPreferences.getInstance();
    final String? userPhone = prefs.getString('user_phone');

    if (userPhone != null && userPhone.isNotEmpty) {
      try {
        DocumentSnapshot userDoc = await FirebaseFirestore.instance
            .collection('users')
            .doc(userPhone)
            .get();

        if (userDoc.exists && mounted) {
          final data = userDoc.data() as Map<String, dynamic>;
          String fullName = data['name'] ?? "there";
          setState(() {
            _userName = fullName.split(' ')[0]; 
          });
        }
      } catch (e) {
        debugPrint("Error fetching name for Home: $e");
      }
    }
  }

  // --- BLE LOGIC (UNCHANGED) ---
  Future<void> _initBluetooth() async {
    print("Initiating Easeband Scan...");
    await _bleController.connectToDevice();
    
    _statusTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
      if (!mounted) return;
      bool currentStatus = _bleController.connectedDevice != null;
      if (currentStatus != isConnected) {
        setState(() => isConnected = currentStatus);
      }
    });
  }

  void _sendBleCommand(String cmd) {
    _bleController.sendCommand(cmd);
  }

  // --- CONVERSION HELPERS (UNCHANGED) ---
  int _getIntensityValue(String level) {
    switch (level) {
      case "L": return 1;
      case "M": return 2;
      case "H": return 3;
      default: return 0;
    }
  }

  int _getPatternValue(String pattern) {
    switch (pattern.toLowerCase()) {
      case "wave": return 1;
      case "pulse": return 2;
      case "circular": return 3;
      default: return 0;
    }
  }

  // --- SETTINGS STORAGE ---
  Future<void> _loadSavedSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      isFrontSelected = prefs.getBool('isFront') ?? true;
      selectedFrontHeat = prefs.getString('frontHeatLevel') ?? "Off";
      selectedBackHeat = prefs.getString('backHeatLevel') ?? "Off";
      selectedFrontDuration = prefs.getString('frontHeatDuration') ?? "Select";
      selectedBackDuration = prefs.getString('backHeatDuration') ?? "Select";
      selectedVibration = prefs.getString('vibLevel') ?? "Off";
      selectedVibType = prefs.getString('vibPattern') ?? "Select";
    });
  }

  Future<void> _saveSetting(String key, dynamic value) async {
    final prefs = await SharedPreferences.getInstance();
    if (value is String) await prefs.setString(key, value);
    if (value is bool) await prefs.setBool(key, value);
  }

  @override
  Widget build(BuildContext context) {
    String currentHeat = isFrontSelected ? selectedFrontHeat : selectedBackHeat;
    String currentDuration = isFrontSelected ? selectedFrontDuration : selectedBackDuration;

    return Scaffold(
      backgroundColor: const Color(0xFFFDF0F0), 
      body: SafeArea(
        child: SingleChildScrollView(
          child: Column(
            children: [
              _buildHeader(),
              const SizedBox(height: 10),
              
              Container(
                width: 280,
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: const Color(0xFFEDE8E8),
                  borderRadius: BorderRadius.circular(40),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: GestureDetector(
                        onTap: () {
                          setState(() => isFrontSelected = true);
                          _saveSetting('isFront', true);
                          _sendBleCommand("Hfront${_getIntensityValue(selectedFrontHeat)}");
                        },
                        child: _buildToggleButton("Front", isFrontSelected),
                      ),
                    ),
                    Expanded(
                      child: GestureDetector(
                        onTap: () {
                          setState(() => isFrontSelected = false);
                          _saveSetting('isFront', false);
                          _sendBleCommand("Hback${_getIntensityValue(selectedBackHeat)}");
                        },
                        child: _buildToggleButton("Back", !isFrontSelected),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 30),
              
              _buildTherapyCard(
                "Heat Therapy", 
                isFrontSelected ? "Hfront" : "Hback", 
                ["Off", "L", "M", "H"], 
                currentHeat,
                currentDuration,
                (val) {
                  setState(() {
                    if (isFrontSelected) {
                      selectedFrontHeat = val;
                      _saveSetting('frontHeatLevel', val);
                      _sendBleCommand("Hfront${_getIntensityValue(val)}");
                    } else {
                      selectedBackHeat = val;
                      _saveSetting('backHeatLevel', val);
                      _sendBleCommand("Hback${_getIntensityValue(val)}");
                    }
                  });
                }
              ),
              
              const SizedBox(height: 20),
              
              if (isFrontSelected) 
                _buildTherapyCard(
                  "Vibration Therapy", 
                  "VI", 
                  ["Off", "L", "M", "H"], 
                  selectedVibration,
                  selectedVibType,
                  (val) {
                    setState(() {
                      selectedVibration = val;
                      _saveSetting('vibLevel', val);
                      _sendBleCommand("VI${_getIntensityValue(val)}");
                    });
                  }
                ),
              const SizedBox(height: 100), 
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                "Hi, $_userName!", 
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: Color(0xFFE57373))
              ),
              const Text("How are you feeling today?", style: TextStyle(fontSize: 13, color: Color(0xFF9A7A7A))),
            ],
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Battery module pinned directly directly above the refresh button
              SizedBox(
                height: 52, // Binds stack height for aligned layout
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          height: 14,
                          width: 28,
                          alignment: Alignment.center,
                          padding: const EdgeInsets.symmetric(horizontal: 2),
                          decoration: BoxDecoration(
                            border: Border.all(color: const Color(0xFFE57373), width: 1.5),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            _batteryLevel.replaceAll('%', ''), // Strips string to show raw number cleanly
                            style: const TextStyle(
                              fontSize: 8, 
                              fontWeight: FontWeight.bold, 
                              color: Color(0xFFE57373),
                            ),
                          ),
                        ),
                        Container(
                          height: 5,
                          width: 1.5,
                          decoration: const BoxDecoration(
                            color: Color(0xFFE57373),
                            borderRadius: BorderRadius.only(
                              topRight: Radius.circular(1),
                              bottomRight: Radius.circular(1),
                            ),
                          ),
                        ),
                      ],
                    ),
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        print("Manual scan triggered...");
                        _bleController.connectToDevice();
                      },
                      child: const Padding(
                        padding: EdgeInsets.all(4.0), // Expands tap boundary box area
                        child: Icon(
                          Icons.refresh, 
                          color: Color(0xFFE57373), 
                          size: 24, 
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              GestureDetector(
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (context) => const ProfileScreen()),
                  );
                },
                child: Stack(
                  children: [
                    const CircleAvatar(
                      radius: 20,
                      backgroundColor: Color(0xFFE2C4C4), 
                      child: Icon(Icons.person, color: Colors.white)
                    ),
                    Positioned(
                      right: 0, bottom: 0, 
                      child: Container(
                        width: 12, height: 12, 
                        decoration: BoxDecoration(
                          color: isConnected ? Colors.green : Colors.grey, 
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 2),
                        ),
                      )
                    ),
                  ],
                ),
              ),
            ],
          )
        ],
      ),
    );
  }

  Widget _buildToggleButton(String text, bool isActive) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 11),
      decoration: BoxDecoration(
        color: isActive ? const Color(0xFFE2C4C4) : Colors.transparent,
        borderRadius: BorderRadius.circular(36),
      ),
      child: Center(
        child: Text(text, 
          style: TextStyle(
            fontWeight: FontWeight.w700, 
            color: isActive ? const Color(0xFF3A2A2A) : const Color(0xFF9A7A7A)
          )
        )
      ),
    );
  }

  Widget _buildTherapyCard(String title, String cmdPrefix, List<String> levels, String currentVal, String currentSubVal, Function(String) onSelect) {
    bool isHeat = title.contains("Heat");
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 14),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFFFDE8E8),
        borderRadius: BorderRadius.circular(22),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 20, offset: const Offset(0, 4))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: Color(0xFF3A2A2A))),
          const SizedBox(height: 14),
          const Text("Intensity", style: TextStyle(color: Color(0xFF9A7A7A), fontSize: 12, fontWeight: FontWeight.w600)),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: levels.map((l) {
              bool isSelected = currentVal == l;
              return GestureDetector(
                onTap: () => onSelect(l),
                child: Container(
                  width: 60,
                  height: 40,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: isSelected ? const Color(0xFFE57373) : Colors.white,
                    borderRadius: BorderRadius.circular(50),
                  ),
                  child: Text(l, style: TextStyle(fontWeight: FontWeight.w700, color: isSelected ? Colors.white : Colors.black)),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 20),
          Text(isHeat ? "Duration" : "Pattern", style: const TextStyle(color: Color(0xFF9A7A7A), fontSize: 12, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14)),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: currentSubVal,
                isExpanded: true,
                items: isHeat 
                  ? ['Select', '5 min', '10 min', '15 min', 'Continuous'].map((val) => DropdownMenuItem(value: val, child: Text(val))).toList()
                  : ['Select', 'wave', 'pulse', 'circular'].map((val) => DropdownMenuItem(value: val, child: Text(val))).toList(),
                onChanged: (newValue) {
                  if (newValue == null) return;
                  
                  setState(() {
                    if (isHeat) { 
                      if (isFrontSelected) {
                        selectedFrontDuration = newValue;
                        _saveSetting('frontHeatDuration', newValue);
                      } else {
                        selectedBackDuration = newValue;
                        _saveSetting('backHeatDuration', newValue);
                      }
                      
                      if (newValue != "Select") {
                        String mins = newValue.replaceAll(RegExp(r'[^0-9]'), '');
                        _sendBleCommand("D${mins.isEmpty ? '0' : mins}");
                      }
                    } else { 
                      selectedVibType = newValue; 
                      _saveSetting('vibPattern', newValue);
                      
                      if (newValue != "Select") {
                        _sendBleCommand("VP${_getPatternValue(newValue)}");
                      }
                    }
                  });
                },
              ),
            ),
          )
        ],
      ),
    );
  }
}
