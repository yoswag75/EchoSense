import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:awesome_notifications/awesome_notifications.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await NotificationService().init();
  
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => SoundWatchProvider()),
      ],
      child: const SoundWatchApp(),
    ),
  );
}

// ==========================================
// NOTIFICATION SERVICE (Awesome Notifications v0.10.0)
// ==========================================
class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  Future<void> init() async {
    await AwesomeNotifications().initialize(
      null, 
      [
        NotificationChannel(
          channelGroupKey: 'alerts_group',
          channelKey: 'soundwatch_alerts',
          channelName: 'General Alerts',
          channelDescription: 'Notifications for detected audio threats',
          defaultColor: const Color(0xFF0F172A),
          ledColor: Colors.blue,
          importance: NotificationImportance.High,
        ),
        NotificationChannel(
          channelGroupKey: 'alerts_group',
          channelKey: 'soundwatch_critical',
          channelName: 'Critical Alerts',
          channelDescription: 'Critical notifications for persistent threats',
          defaultColor: const Color(0xFF0F172A),
          ledColor: Colors.red,
          importance: NotificationImportance.Max,
          criticalAlerts: true,
        )
      ],
      channelGroups: [
        NotificationChannelGroup(
          channelGroupKey: 'alerts_group',
          channelGroupName: 'SoundWatch Alerts',
        )
      ],
      debug: true,
    );

    bool isAllowed = await AwesomeNotifications().isNotificationAllowed();
    if (!isAllowed) {
      await AwesomeNotifications().requestPermissionToSendNotifications();
    }
  }

  Future<void> showNotification(int id, String title, String body, {bool critical = false}) async {
    await AwesomeNotifications().createNotification(
      content: NotificationContent(
        id: id,
        channelKey: critical ? 'soundwatch_critical' : 'soundwatch_alerts',
        title: title,
        body: body,
        notificationLayout: NotificationLayout.Default,
        criticalAlert: critical,
      ),
    );
  }
}

// ==========================================
// MODELS
// ==========================================
class ThreatCategory {
  final String name;
  final String type;
  int level;
  bool enabled;

  ThreatCategory({required this.name, required this.type, required this.level, required this.enabled});
}

class EventLog {
  final String category;
  final int confidence;
  final int db;
  final DateTime timestamp;
  final int level;

  EventLog({required this.category, required this.confidence, required this.db, required this.timestamp, required this.level});
}

class AlertLog {
  final String title;
  final String message;
  final String category;
  final int level;
  final int accuracy;
  final DateTime timestamp;
  final bool isPersistence;

  AlertLog({
    required this.title,
    required this.message,
    required this.category,
    required this.level,
    required this.accuracy,
    required this.timestamp,
    this.isPersistence = false,
  });
}

// ==========================================
// STATE MANAGEMENT 
// ==========================================
class SoundWatchProvider extends ChangeNotifier {
  IO.Socket? socket;
  bool isConnected = false;
  
  String hardwareState = "DISCONNECTED";
  String hardwareMessage = "Enter PC IP Address to connect.";

  List<EventLog> events = [];
  List<AlertLog> alerts = [];

  final Map<String, DateTime> _firstDetectionTime = {};
  final Map<String, DateTime> _lastDetectionTime = {};

  final Map<String, ThreatCategory> categories = {
    "Gunshot": ThreatCategory(name: "Gunshot", type: 'system', level: 3, enabled: true),
    "Fire Alarm": ThreatCategory(name: "Fire Alarm", type: 'system', level: 3, enabled: true),
    "Scream": ThreatCategory(name: "Scream", type: 'system', level: 2, enabled: true),
    "Glass Break": ThreatCategory(name: "Glass Break", type: 'system', level: 2, enabled: true),
    "Baby Crying": ThreatCategory(name: "Baby Crying", type: 'user', level: 2, enabled: true),
    "Dog Barking": ThreatCategory(name: "Dog Barking", type: 'user', level: 1, enabled: true),
    "Traffic": ThreatCategory(name: "Traffic", type: 'user', level: 1, enabled: false),
    "Conversation": ThreatCategory(name: "Conversation", type: 'user', level: 1, enabled: false),
    "Wind": ThreatCategory(name: "Wind", type: 'user', level: 1, enabled: false),
  };

  void connectToServer(String ipAddress) {
    if (socket != null && socket!.connected) {
      socket!.disconnect();
    }

    updateStatus("CONNECTING", "Trying $ipAddress...");
    
    socket = IO.io('http://$ipAddress:5000', <String, dynamic>{
      'transports': ['websocket'],
      'autoConnect': true,
    });

    socket!.onConnect((_) {
      isConnected = true;
      updateStatus("IDLE", "Connected to Server");
    });

    socket!.onDisconnect((_) {
      isConnected = false;
      updateStatus("DISCONNECTED", "Lost connection to server.");
    });

    socket!.on('hardware_status', (data) {
      updateStatus(data['state'], data['msg']);
    });

    socket!.on('sound_event', (data) {
      _handleRealTimeEvent(data['category'], data['confidence'], data['db']);
    });
  }

  void _handleRealTimeEvent(String categoryName, int confidence, int db) {
    final catData = categories[categoryName];
    if (catData == null || !catData.enabled) return;

    events.insert(0, EventLog(
      category: categoryName, 
      confidence: confidence, 
      db: db, 
      timestamp: DateTime.now(),
      level: catData.level,
    ));
    
    final now = DateTime.now();
    
    if (_lastDetectionTime.containsKey(categoryName) && 
        now.difference(_lastDetectionTime[categoryName]!).inSeconds > 15) {
      _firstDetectionTime.remove(categoryName);
    }
    
    _lastDetectionTime[categoryName] = now;
    _firstDetectionTime.putIfAbsent(categoryName, () => now);

    final secondsPersisting = now.difference(_firstDetectionTime[categoryName]!).inSeconds;
    
    if (secondsPersisting >= 60) {
      updateStatus("PERSISTENT", "Continuous $categoryName detected!");
      
      for (int i = 0; i < 2; i++) {
        Future.delayed(Duration(milliseconds: i * 500), () {
          _addAlert(
            category: categoryName,
            accuracy: confidence,
            level: 3, 
            isPersistence: true,
            title: "CRITICAL: PERSISTENCE ALERT",
            msg: "Continuous $categoryName detected for over 60 seconds. Immediate attention required.",
          );
        });
      }
      _firstDetectionTime[categoryName] = now; 
      
    } else {
      _triggerThreatAlert(catData, confidence, db);
    }
    
    notifyListeners();
  }

  void toggleCategory(String name) {
    categories[name]!.enabled = !categories[name]!.enabled;
    notifyListeners();
  }

  void cycleLevel(String name) {
    if (!categories[name]!.enabled) return;
    int current = categories[name]!.level;
    categories[name]!.level = current == 3 ? 1 : current + 1;
    notifyListeners();
  }

  void updateStatus(String state, String msg) {
    hardwareState = state;
    hardwareMessage = msg;
    notifyListeners();
  }

  void clearEvents() {
    events.clear();
    notifyListeners();
  }

  void clearAlerts() {
    alerts.clear();
    notifyListeners();
  }

  void _triggerThreatAlert(ThreatCategory category, int accuracy, int db) {
    int notifCount = category.level == 3 ? 2 : 1;
    String priorityPrefix = category.level == 3 ? "URGENT: " : "";
    
    for (int i = 0; i < notifCount; i++) {
      Future.delayed(Duration(milliseconds: i * 400), () {
        _addAlert(
          category: category.name,
          accuracy: accuracy,
          level: category.level,
          title: "$priorityPrefix${category.name} Detected",
          msg: "${category.name} detected with level ${category.level} priority.",
        );
      });
    }
  }

  void _addAlert({
    required String category, 
    required int accuracy, 
    required int level, 
    required String title, 
    required String msg,
    bool isPersistence = false,
  }) {
    alerts.insert(0, AlertLog(
      title: title,
      message: msg,
      category: category,
      level: level,
      accuracy: accuracy,
      timestamp: DateTime.now(),
      isPersistence: isPersistence,
    ));
    
    NotificationService().showNotification(
      DateTime.now().millisecond, 
      title, 
      msg,
      critical: isPersistence || level == 3,
    );
    notifyListeners();
  }
}

// ==========================================
// UI WIDGETS
// ==========================================
class SoundWatchApp extends StatelessWidget {
  const SoundWatchApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SoundWatch',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0F172A),
        cardColor: const Color(0xFF1E293B),
        dividerColor: const Color(0xFF334155),
        fontFamily: 'Roboto',
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final TextEditingController _ipController = TextEditingController();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F172A),
        elevation: 0,
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.blue.withOpacity(0.2),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.security, color: Colors.blue),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text("SoundWatch", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                Text("Automatic Threat Detection", style: TextStyle(color: Colors.grey[400], fontSize: 12)),
              ],
            ),
          ],
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              child: Padding(
                padding: const EdgeInsets.all(12.0),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _ipController,
                        decoration: const InputDecoration(
                          hintText: "Enter PC IP (e.g., 192.168.1.5)",
                          border: InputBorder.none,
                          icon: Icon(Icons.wifi),
                        ),
                      ),
                    ),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.blue[700]),
                      onPressed: () {
                        Provider.of<SoundWatchProvider>(context, listen: false)
                            .connectToServer(_ipController.text.trim());
                      },
                      child: const Text("Connect", style: TextStyle(color: Colors.white)),
                    )
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            const StatusBadge(),
            const SizedBox(height: 24),
            const ThreatClassification(),
            const SizedBox(height: 16),
            const AlertsView(),
            const SizedBox(height: 16),
            const EventLogView(),
          ],
        ),
      ),
    );
  }
}

class StatusBadge extends StatelessWidget {
  const StatusBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<SoundWatchProvider>(
      builder: (context, provider, child) {
        Color badgeColor;
        Color dotColor;
        
        switch (provider.hardwareState) {
          case "TRIGGERED":
          case "PERSISTENT":
            badgeColor = Colors.amber.withOpacity(0.2);
            dotColor = Colors.amber;
            break;
          case "ANALYZING":
          case "CONNECTING":
            badgeColor = Colors.blue.withOpacity(0.2);
            dotColor = Colors.blue;
            break;
          case "DISCONNECTED":
            badgeColor = Colors.red.withOpacity(0.1);
            dotColor = Colors.red;
            break;
          default:
            badgeColor = const Color(0xFF1E293B);
            dotColor = Colors.green;
        }

        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          decoration: BoxDecoration(
            color: badgeColor,
            border: Border.all(color: provider.hardwareState == "IDLE" ? const Color(0xFF334155) : dotColor.withOpacity(0.5)),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              Container(
                width: 12, height: 12,
                decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
              ),
              const SizedBox(width: 16),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(provider.hardwareState, style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.grey[400], letterSpacing: 1.2)),
                  Text(provider.hardwareMessage, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                ],
              )
            ],
          ),
        );
      },
    );
  }
}

class ThreatClassification extends StatelessWidget {
  const ThreatClassification({super.key});

  @override
  Widget build(BuildContext context) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Consumer<SoundWatchProvider>(
          builder: (context, provider, child) {
            final sysCategories = provider.categories.values.where((c) => c.type == 'system').toList();
            final userCategories = provider.categories.values.where((c) => c.type == 'user').toList();

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.checklist, color: Colors.purpleAccent),
                    SizedBox(width: 8),
                    Text("Threat Classification", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  ],
                ),
                const SizedBox(height: 4),
                Text("Tap name to cycle level (Low-1, Med-2, High-3)", style: TextStyle(fontSize: 12, color: Colors.grey[500], fontStyle: FontStyle.italic)),
                const SizedBox(height: 16),
                
                Text("SYSTEM CATEGORIES", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.grey[400], letterSpacing: 1.2)),
                const SizedBox(height: 8),
                ...sysCategories.map((c) => CategoryRow(category: c)),
                
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12.0),
                  child: Divider(),
                ),
                
                Text("USER CATEGORIES", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.grey[400], letterSpacing: 1.2)),
                const SizedBox(height: 8),
                ...userCategories.map((c) => CategoryRow(category: c)),
              ],
            );
          },
        ),
      ),
    );
  }
}

class CategoryRow extends StatelessWidget {
  final ThreatCategory category;
  const CategoryRow({super.key, required this.category});

  Color _getLevelColor() {
    if (!category.enabled) return Colors.grey;
    if (category.level == 3) return Colors.red;
    if (category.level == 2) return Colors.amber;
    return Colors.blue;
  }

  String _getLevelText() {
    if (category.level == 3) return "HIGH";
    if (category.level == 2) return "MED";
    return "LOW";
  }

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<SoundWatchProvider>(context, listen: false);
    final levelColor = _getLevelColor();

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: category.enabled ? const Color(0xFF0F172A) : const Color(0xFF0F172A).withOpacity(0.5),
        border: Border.all(color: category.enabled ? const Color(0xFF334155) : Colors.transparent),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => provider.toggleCategory(category.name),
            child: Icon(
              category.enabled ? Icons.toggle_on : Icons.toggle_off,
              color: category.enabled ? Colors.blue : Colors.grey[600],
              size: 32,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: GestureDetector(
              onTap: () => provider.cycleLevel(category.name),
              behavior: HitTestBehavior.opaque,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(category.name, style: TextStyle(
                    color: category.enabled ? Colors.white : Colors.grey[500],
                    fontWeight: FontWeight.w500,
                  )),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: category.enabled ? levelColor.withOpacity(0.2) : Colors.transparent,
                      border: Border.all(color: category.enabled ? levelColor.withOpacity(0.5) : Colors.grey[700]!),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(_getLevelText(), style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: category.enabled ? levelColor : Colors.grey[600],
                    )),
                  )
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class AlertsView extends StatelessWidget {
  const AlertsView({super.key});

  @override
  Widget build(BuildContext context) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        height: 300,
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Row(
                  children: [
                    Icon(Icons.notifications_active, color: Colors.redAccent),
                    SizedBox(width: 8),
                    Text("Alerts", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  ],
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, color: Colors.grey, size: 20),
                  onPressed: () => Provider.of<SoundWatchProvider>(context, listen: false).clearAlerts(),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                )
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: Consumer<SoundWatchProvider>(
                builder: (context, provider, child) {
                  if (provider.alerts.isEmpty) {
                    return Center(child: Text("No alerts yet.", style: TextStyle(color: Colors.grey[600])));
                  }
                  return ListView.builder(
                    itemCount: provider.alerts.length,
                    itemBuilder: (context, index) {
                      final alert = provider.alerts[index];
                      Color bgColor = const Color(0xFF1E293B);
                      Color borderColor = const Color(0xFF334155);
                      Color iconColor = Colors.blue;
                      IconData icon = Icons.info_outline;

                      if (alert.isPersistence || alert.level == 3) {
                        bgColor = Colors.red.withOpacity(0.1);
                        borderColor = Colors.red.withOpacity(0.5);
                        iconColor = Colors.redAccent;
                        icon = alert.isPersistence ? Icons.restore : Icons.warning_amber;
                      } else if (alert.level == 2) {
                        bgColor = Colors.amber.withOpacity(0.1);
                        borderColor = Colors.amber.withOpacity(0.4);
                        iconColor = Colors.amber;
                        icon = Icons.warning;
                      }

                      return Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: bgColor,
                          border: Border.all(color: borderColor),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(icon, color: iconColor, size: 20),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      Expanded(child: Text(alert.title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13))),
                                      Text("${alert.timestamp.hour}:${alert.timestamp.minute.toString().padLeft(2, '0')}", 
                                        style: TextStyle(fontSize: 10, color: Colors.grey[500])),
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  Text(alert.message, style: TextStyle(fontSize: 12, color: Colors.grey[300])),
                                  const SizedBox(height: 8),
                                  Row(
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                        decoration: BoxDecoration(color: Colors.black38, borderRadius: BorderRadius.circular(4)),
                                        child: Text(alert.category, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                                      ),
                                      const SizedBox(width: 6),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                        decoration: BoxDecoration(color: Colors.black38, borderRadius: BorderRadius.circular(4)),
                                        child: Text("Acc: ${alert.accuracy}%", style: TextStyle(fontSize: 10, color: Colors.grey[400])),
                                      ),
                                    ],
                                  )
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class EventLogView extends StatelessWidget {
  const EventLogView({super.key});

  @override
  Widget build(BuildContext context) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        height: 250,
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Row(
                  children: [
                    Icon(Icons.mic, color: Colors.greenAccent),
                    SizedBox(width: 8),
                    Text("Detection Log", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  ],
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, color: Colors.grey, size: 20),
                  onPressed: () => Provider.of<SoundWatchProvider>(context, listen: false).clearEvents(),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                )
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: Consumer<SoundWatchProvider>(
                builder: (context, provider, child) {
                  if (provider.events.isEmpty) {
                    return Center(child: Text("Waiting for audio events...", style: TextStyle(color: Colors.grey[600])));
                  }
                  return ListView.builder(
                    itemCount: provider.events.length,
                    itemBuilder: (context, index) {
                      final ev = provider.events[index];
                      Color levelCol = ev.level == 3 ? Colors.red : (ev.level == 2 ? Colors.amber : Colors.blue);
                      
                      return Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0F172A).withOpacity(0.5),
                          border: Border.all(color: const Color(0xFF334155)),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Row(
                                  children: [
                                    Text(ev.category, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                                    const SizedBox(width: 8),
                                    Text("LV: ${ev.level}", style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: levelCol)),
                                  ],
                                ),
                                Text("${ev.timestamp.hour}:${ev.timestamp.minute.toString().padLeft(2, '0')}:${ev.timestamp.second.toString().padLeft(2, '0')}", 
                                  style: TextStyle(fontSize: 10, color: Colors.grey[500])),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(color: Colors.greenAccent.withOpacity(0.1), borderRadius: BorderRadius.circular(4)),
                                  child: Text("Acc: ${ev.confidence}%", style: const TextStyle(fontSize: 10, color: Colors.greenAccent)),
                                ),
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(color: Colors.blueAccent.withOpacity(0.1), borderRadius: BorderRadius.circular(4)),
                                  child: Text("Vol: ${ev.db} dB", style: const TextStyle(fontSize: 10, color: Colors.blueAccent)),
                                ),
                              ],
                            )
                          ],
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}