import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'services/crypto_service.dart';
import 'services/websocket_service.dart';
import 'my_qr_code_screen.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter/foundation.dart'; // Pour kIsWeb
import 'dart:io' show Platform;
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'screens/home_screen.dart';





Future<void> initializeBackgroundService() async {
  final service = FlutterBackgroundService();

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStartBackgroundService,
      autoStart: false,
      isForegroundMode: true,
      notificationChannelId: 'hush_foreground_channel',
      initialNotificationTitle: 'Hush Sécurisé',
      initialNotificationContent: 'La messagerie écoute en arrière-plan',
      foregroundServiceNotificationId: 888,
    ),
    iosConfiguration: IosConfiguration(
      autoStart: true,
      onForeground: onStartBackgroundService,
    ),
  );
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kIsWeb && Platform.isAndroid) {
    const AndroidNotificationChannel channel = AndroidNotificationChannel(
      'hush_foreground_channel', // id
      'Hush Service Arrière-plan', // nom
      description: 'Canal utilisé pour maintenir Hush actif en arrière-plan',
      importance: Importance.low, // Important pour un service de fond (évite les sons intempestifs en boucle)
    );
    final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
        FlutterLocalNotificationsPlugin();

    await flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);
    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      await initializeBackgroundService();
    }
  }
  await Hive.initFlutter();

  const secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
    ),
  );
  String? encryptionKeyString = await secureStorage.read(key: 'hush_db_key');
  
  Uint8List encryptionKey;
  if (encryptionKeyString == null) {
    final generatedKey = Hive.generateSecureKey();
    await secureStorage.write(
      key: 'hush_db_key', 
      value: base64UrlEncode(generatedKey),
    );
    encryptionKey = Uint8List.fromList(generatedKey);
  } else {
    encryptionKey = base64Url.decode(encryptionKeyString);
  }

  await Hive.openBox(
    'chat_messages',
    encryptionCipher: HiveAesCipher(encryptionKey),
  );

  await Hive.openBox(
    'contacts_box',
    encryptionCipher: HiveAesCipher(encryptionKey),
  );

  const AndroidInitializationSettings initializationSettingsAndroid =
      AndroidInitializationSettings('@mipmap/ic_launcher');
  
  const InitializationSettings initializationSettings =
      InitializationSettings(android: initializationSettingsAndroid);

  await flutterLocalNotificationsPlugin.initialize(initializationSettings);

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Messagerie Chiffrée Anonyme',
      theme: ThemeData(
        brightness: Brightness.light,
        primarySwatch: Colors.deepPurple,
        scaffoldBackgroundColor: Colors.grey[100],
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.deepPurple,
          foregroundColor: Colors.white,
        ),
      ),
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        primarySwatch: Colors.deepPurple,
        scaffoldBackgroundColor: const Color(0xFF121212),
        cardColor: const Color(0xFF1E1E1E),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF1E1E1E),
          foregroundColor: Colors.white,
        ),
        dialogTheme: const DialogThemeData(
          backgroundColor: Color(0xFF1E1E1E),
        ),
      ),
      themeMode: ThemeMode.system,
      home: HomeScreen(),
    );
  }
}



@pragma('vm:entry-point')
void onStartBackgroundService(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();

  final FlutterLocalNotificationsPlugin bgNotificationsPlugin =
      FlutterLocalNotificationsPlugin();
  
  const AndroidInitializationSettings initializationSettingsAndroid =
      AndroidInitializationSettings('@mipmap/ic_launcher');
  const InitializationSettings initializationSettings =
      InitializationSettings(android: initializationSettingsAndroid);
  await bgNotificationsPlugin.initialize(initializationSettings);

  if (service is AndroidServiceInstance) {
    service.on('setAsForeground').listen((event) {
      service.setAsForegroundService();
    });

    service.on('setAsBackground').listen((event) {
      service.setAsBackgroundService();
    });
  }

  service.on('stopService').listen((event) {
    service.stopSelf();
  });

  final WebSocketService bgWsService = WebSocketService();
  final CryptoService bgCryptoService = CryptoService();

  bgWsService.onMessageReceived = (data) async {
    if (data['type'] == 'message') {
      final encryptedPayload = data['encryptedPayload'];
      final senderPubKey = data['senderPublicKey'];

      try {
        await bgCryptoService.decryptMessage(encryptedPayload, senderPubKey);
        
        // Affichage direct de la notification en arrière-plan
        const AndroidNotificationDetails androidPlatformChannelSpecifics =
            AndroidNotificationDetails(
          'hush_chat_channel',
          'Hush Messages',
          channelDescription: 'Notifications pour les messages chiffrés entrants',
          importance: Importance.max,
          priority: Priority.high,
          color: Color(0xFF7C4DFF),
        );
        const NotificationDetails platformChannelSpecifics =
            NotificationDetails(android: androidPlatformChannelSpecifics);

        await bgNotificationsPlugin.show(
          0,
          'Hush (Arrière-plan)',
          '🔒 Nouveau message chiffré reçu',
          platformChannelSpecifics,
        );
      } catch (e) {
        print('Erreur de déchiffrement en arrière-plan : $e');
      }
    }
  };
}