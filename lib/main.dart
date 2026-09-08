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

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

Future<void> _initNotifications() async {
  const AndroidInitializationSettings initializationSettingsAndroid =
      AndroidInitializationSettings('@mipmap/ic_launcher');

  const InitializationSettings initializationSettings =
      InitializationSettings(android: initializationSettingsAndroid);

  await flutterLocalNotificationsPlugin.initialize(initializationSettings);
}

Future<void> _showNotification(String senderName, String messageBody) async {
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

  await flutterLocalNotificationsPlugin.show(
    0,
    'Nouveau message de $senderName',
    messageBody,
    platformChannelSpecifics,
  );
}

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
      home: const HomeScreen(),
    );
  }
}

class ChatMessage {
  final String text;
  final bool isMe;
  final DateTime timestamp;

  ChatMessage({required this.text, required this.isMe, required this.timestamp});
}

class Conversation {
  final String contactId;
  String contactName;
  final String publicKey;
  final List<ChatMessage> messages;

  Conversation({
    required this.contactId,
    required this.contactName,
    required this.publicKey,
    List<ChatMessage>? messages,
  }) : messages = messages ?? [];
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final CryptoService _cryptoService = CryptoService();
  final WebSocketService _wsService = WebSocketService();
  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  final _messagesBox = Hive.box('chat_messages');
  
  bool _isLoading = true;
  String _myId = '';
  String _myPubKey = '';

  final Map<String, Conversation> _conversations = {};
  
  // Map de ValueNotifiers pour suivre le statut en ligne de chaque contact en direct
  final Map<String, ValueNotifier<bool>> _contactStatusNotifiers = {};

  ValueNotifier<bool> getStatusNotifier(String contactId) {
    if (!_contactStatusNotifiers.containsKey(contactId)) {
      _contactStatusNotifiers[contactId] = ValueNotifier<bool>(false);
    }
    return _contactStatusNotifiers[contactId]!;
  }

  @override
  void initState() {
    super.initState();
    _initializeApp();
  }

  Future<void> _initializeApp() async {
    await _initNotifications();
    final service = FlutterBackgroundService();
    bool isRunning = await service.isRunning();
    if (!isRunning) {
      service.startService();
    }
    await _cryptoService.initUserIdentity();
    _myId = _cryptoService.userId;
    _myPubKey = await _cryptoService.getPublicKeyString();

    await _loadSavedContacts();
    await _loadSavedMessages();

    setState(() {
      _isLoading = false;
    });

    const serverUrl = 'wss://ws-secure-chat.onrender.com';
    _wsService.connect(serverUrl, _myId);

    _wsService.onMessageReceived = (data) async {
      if (data['type'] == 'message') {
        final senderId = data['senderId'] ?? 'Inconnu';
        final encryptedPayload = data['encryptedPayload'];
        final senderPubKey = data['senderPublicKey'];

        try {
          final decryptedText = await _cryptoService.decryptMessage(encryptedPayload, senderPubKey);
          
          final messagesBox = Hive.box('chat_messages');
          messagesBox.add({
            'text': decryptedText,
            'isMe': false,
            'conversationId': senderId,
            'timestamp': DateTime.now().toIso8601String(),
          });

          await _showNotification('Hush', '🔒 Nouveau message chiffré reçu');

          setState(() {
            if (!_conversations.containsKey(senderId)) {
              _conversations[senderId] = Conversation(
                contactId: senderId,
                contactName: 'Contact ($senderId)',
                publicKey: senderPubKey ?? '',
              );
              _saveContactsToStorage();
            }

            _conversations[senderId]!.messages.add(
              ChatMessage(text: decryptedText, isMe: false, timestamp: DateTime.now()),
            );
          });
        } catch (e) {
          print('Erreur de déchiffrement : $e');
        }
      } 
      else if (data['type'] == 'info') {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(data['message']), backgroundColor: Colors.blue.shade700),
        );
      } 
      else if (data['type'] == 'status_response') {
        final String targetId = data['targetId'];
        final bool isOnline = data['isOnline'];
        
        // Mise à jour en direct du ValueNotifier
        getStatusNotifier(targetId).value = isOnline;
      }
      else if (data['type'] == 'error') {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erreur serveur : ${data['message']}'), backgroundColor: Colors.red),
        );
      }
    };
  }

  Future<void> _loadSavedContacts() async {
    final contactsBox = Hive.box('contacts_box');
    final savedData = contactsBox.get('saved_contacts');

    if (savedData != null) {
      final Map<String, dynamic> loadedMap = Map<String, dynamic>.from(savedData);
      
      setState(() {
        _conversations.clear();
        loadedMap.forEach((key, value) {
          final contactData = Map<String, dynamic>.from(value);
          _conversations[key] = Conversation(
            contactId: contactData['contactId'],
            contactName: contactData['contactName'],
            publicKey: contactData['publicKey'],
            messages: [],
          );
        });
      });
    }
  }

  Future<void> _loadSavedMessages() async {
    final messagesBox = Hive.box('chat_messages');
    
    for (var item in messagesBox.values) {
      final messageMap = Map<String, dynamic>.from(item as Map);
      
      final String? conversationId = messageMap['conversationId'];
      final String text = messageMap['text'];
      final bool isMe = messageMap['isMe'];
      final DateTime timestamp = DateTime.parse(messageMap['timestamp']);

      if (conversationId != null && _conversations.containsKey(conversationId)) {
        bool exists = _conversations[conversationId]!.messages.any(
          (m) => m.text == text && m.timestamp.isAtSameMomentAs(timestamp)
        );

        if (!exists) {
          _conversations[conversationId]!.messages.add(
            ChatMessage(text: text, isMe: isMe, timestamp: timestamp),
          );
        }
      }
    }
  }

  void _saveContactsToStorage() {
    final contactsBox = Hive.box('contacts_box');
    final contactsMap = _conversations.map((key, conversation) {
      return MapEntry(key, {
        'contactId': conversation.contactId,
        'contactName': conversation.contactName,
        'publicKey': conversation.publicKey,
      });
    });

    contactsBox.put('saved_contacts', contactsMap);
  }

  String get _myContactLink => 'securechat://$_myId/$_myPubKey';

  void _showAddContactDialog() {
    final TextEditingController nameController = TextEditingController();
    final TextEditingController linkController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Nouvelle conversation'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              OutlinedButton.icon(
                onPressed: () async {
                  final MobileScannerController cameraController = MobileScannerController(
                    facing: CameraFacing.back,
                    formats: const [BarcodeFormat.qrCode],
                  );

                  final scannedLink = await Navigator.push<String>(
                    context,
                    MaterialPageRoute(
                      builder: (context) => Scaffold(
                        appBar: AppBar(
                          title: const Text('Scannez le QR code'),
                          backgroundColor: Colors.deepPurple,
                          foregroundColor: Colors.white,
                        ),
                        body: MobileScanner(
                          controller: cameraController,
                          errorBuilder: (context, error, child) {
                            return Center(
                              child: Padding(
                                padding: const EdgeInsets.all(20.0),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    const Icon(Icons.error, color: Colors.red, size: 50),
                                    const SizedBox(height: 10),
                                    Text(
                                      'Erreur : ${error.errorCode}',
                                      style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold),
                                      textAlign: TextAlign.center,
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                          onDetect: (capture) {
                            final barcodes = capture.barcodes;
                            for (final barcode in barcodes) {
                              if (barcode.rawValue != null) {
                                cameraController.stop();
                                Navigator.pop(context, barcode.rawValue);
                                break;
                              }
                            }
                          },
                        ),
                      ),
                    ),
                  );

                  cameraController.dispose();

                  if (scannedLink != null) {
                    String cleanLink = scannedLink;
                    if (cleanLink.contains('securechat://')) {
                      final startIndex = cleanLink.indexOf('securechat://');
                      cleanLink = cleanLink.substring(startIndex).split(RegExp(r'["\s}]')).first;
                    }
                    linkController.text = cleanLink;
                  }
                },
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text('Scanner le QR code du contact'),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: nameController,
                decoration: const InputDecoration(labelText: 'Nom ou Surnom'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: linkController,
                decoration: const InputDecoration(labelText: 'Coller le lien'),
                maxLines: 2,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Annuler'),
            ),
            ElevatedButton(
              onPressed: () {
                final name = nameController.text.trim();
                final link = linkController.text.trim();

                if (name.isNotEmpty && link.startsWith('securechat://')) {
                  try {
                    final payload = link.replaceFirst('securechat://', '');
                    if (payload.length > 16) {
                      final id = payload.substring(0, 16);
                      final pubKey = payload.substring(17);

                      setState(() {
                        _conversations[id] = Conversation(
                          contactId: id,
                          contactName: name,
                          publicKey: pubKey,
                        );
                      });

                      _saveContactsToStorage();
                      Navigator.pop(context);
                    }
                  } catch (e) {
                    print('Erreur parsing lien: $e');
                  }
                }
              },
              child: const Text('Ajouter'),
            ),
          ],
        );
      },
    );
  }

  @override
  void dispose() {
    _wsService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Messagerie Hush'),
        actions: [
          IconButton(
            icon: const Icon(Icons.info_outline),
            tooltip: 'Mon lien de contact',
            onPressed: () {
              showModalBottomSheet(
                context: context,
                builder: (context) => Padding(
                  padding: const EdgeInsets.all(20.0),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Mon identité cryptographique', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 12),
                      const Text('Partagez ce lien unique à vos contacts :'),
                      const SizedBox(height: 8),
                      SelectableText(_myContactLink, style: const TextStyle(color: Colors.blue, fontWeight: FontWeight.w500)),
                      const SizedBox(height: 16),
                      ElevatedButton.icon(
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: _myContactLink));
                          Navigator.pop(context);
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Lien copié dans le presse-papier !')),
                          );
                        },
                        icon: const Icon(Icons.copy),
                        label: const Text('Copier mon lien'),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.qr_code),
            tooltip: 'Mon QR Code',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => MyQrCodeScreen(userId: _myContactLink),
                ),
              );
            },
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _conversations.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.chat_bubble_outline, size: 64, color: Colors.grey),
                      const SizedBox(height: 16),
                      const Text('Aucune conversation active.'),
                      const SizedBox(height: 12),
                      ElevatedButton.icon(
                        onPressed: _showAddContactDialog,
                        icon: const Icon(Icons.add),
                        label: const Text('Ajouter un contact'),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  itemCount: _conversations.length,
                  itemBuilder: (context, index) {
                    final conversation = _conversations.values.toList()[index];
                    final lastMessage = conversation.messages.isNotEmpty
                        ? conversation.messages.last.text
                        : 'Aucun message';
                    final initialLetter = conversation.contactName.isNotEmpty 
                        ? conversation.contactName[0].toUpperCase() 
                        : '?';

                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor: Colors.blue.shade100,
                        child: Text(initialLetter, style: const TextStyle(fontWeight: FontWeight.bold)),
                      ),
                      title: Text(conversation.contactName, style: const TextStyle(fontWeight: FontWeight.bold)),
                      subtitle: Text(lastMessage, maxLines: 1, overflow: TextOverflow.ellipsis),
                      onTap: () {
                        // 1. Demander le statut au serveur
                        _wsService.send(jsonEncode({
                          'type': 'check_status',
                          'targetId': conversation.contactId,
                        }));

                        // 2. Ouvrir le ChatScreen en passant le Notifier
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => ChatScreen(
                              conversation: conversation,
                              wsService: _wsService,
                              cryptoService: _cryptoService,
                              myPubKey: _myPubKey,
                              statusNotifier: getStatusNotifier(conversation.contactId),
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showAddContactDialog,
        backgroundColor: Colors.deepPurple,
        foregroundColor: Colors.white,
        child: const Icon(Icons.person_add),
        tooltip: 'Ajouter un contact',
      ),
    );
  }
}

class ChatScreen extends StatefulWidget {
  final Conversation conversation;
  final WebSocketService wsService;
  final CryptoService cryptoService;
  final String myPubKey;
  final ValueNotifier<bool> statusNotifier;

  const ChatScreen({
    Key? key,
    required this.conversation,
    required this.wsService,
    required this.cryptoService,
    required this.myPubKey,
    required this.statusNotifier,
  }) : super(key: key);

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final _messagesBox = Hive.box('chat_messages');

  @override
  void initState() {
    super.initState();
    // Demander le statut au serveur dès l'ouverture
    widget.wsService.send(jsonEncode({
      'type': 'check_status',
      'targetId': widget.conversation.contactId,
    }));
  }

  void _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    try {
      final encryptedPayload = await widget.cryptoService.encryptMessage(text, widget.conversation.publicKey);
      widget.wsService.sendMessage(widget.conversation.contactId, encryptedPayload, widget.myPubKey);

      _messagesBox.add({
        'text': text,
        'isMe': true,
        'conversationId': widget.conversation.contactId,
        'timestamp': DateTime.now().toIso8601String(),
      });

      // Ajout en mémoire locale pour la cohérence instantanée de la conversation active
      widget.conversation.messages.add(
        ChatMessage(text: text, isMe: true, timestamp: DateTime.now()),
      );

      _messageController.clear();
      _scrollToBottom();
    } catch (e) {
      print('Erreur de chiffrement : $e');
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final initialLetter = widget.conversation.contactName.isNotEmpty 
        ? widget.conversation.contactName[0].toUpperCase() 
        : '?';

    return Scaffold(
      appBar: AppBar(
        title: ValueListenableBuilder<bool>(
          valueListenable: widget.statusNotifier,
          builder: (context, isOnline, child) {
            return Row(
              children: [
                Stack(
                  children: [
                    CircleAvatar(
                      radius: 16,
                      backgroundColor: Colors.blue.shade200,
                      child: Text(initialLetter, style: const TextStyle(fontSize: 14)),
                    ),
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: isOnline ? Colors.green : Colors.grey,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 1.5),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 10),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(widget.conversation.contactName, style: const TextStyle(fontSize: 16)),
                    Text(
                      isOnline ? 'En ligne' : 'Hors ligne',
                      style: TextStyle(
                        fontSize: 12,
                        color: isOnline ? Colors.green.shade400 : Colors.grey,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: ValueListenableBuilder(
              valueListenable: Hive.box('chat_messages').listenable(),
              builder: (context, Box box, _) {
                // Filtrer et mapper les messages spécifiques à cette conversation depuis Hive en temps réel
                final messages = box.values
                    .map((e) => Map<String, dynamic>.from(e as Map))
                    .where((m) => m['conversationId'] == widget.conversation.contactId)
                    .toList();

                messages.sort((a, b) => DateTime.parse(a['timestamp']).compareTo(DateTime.parse(b['timestamp'])));

                if (messages.isEmpty) {
                  return const Center(child: Text('Aucun message pour l\'instant'));
                }

                return ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.all(16),
                  itemCount: messages.length,
                  itemBuilder: (context, index) {
                    final message = messages[index];
                    final bool isMe = message['isMe'] ?? false;
                    final String text = message['text'] ?? '';

                    return Align(
                      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                      child: Container(
                        margin: const EdgeInsets.symmetric(vertical: 4),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
                        decoration: BoxDecoration(
                          color: isMe ? Colors.blue.shade600 : Colors.grey.shade200,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Text(
                          text,
                          style: TextStyle(
                            color: isMe ? Colors.white : Colors.black87,
                            fontSize: 15,
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 8.0, right: 8.0, bottom: 20.0, top: 8.0),
            child: Container(
              padding: const EdgeInsets.all(8.0),
              decoration: BoxDecoration(
                color: Theme.of(context).brightness == Brightness.dark 
                    ? const Color(0xFF1E1E1E) 
                    : Colors.grey.shade100,
                borderRadius: BorderRadius.circular(30),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _messageController,
                      decoration: InputDecoration(
                        hintText: 'Écrire un message...',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        filled: true,
                        fillColor: Theme.of(context).brightness == Brightness.dark 
                            ? const Color(0xFF2C2C2C) 
                            : Colors.white,
                      ),
                      onSubmitted: (_) => _sendMessage(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  CircleAvatar(
                    backgroundColor: Colors.deepPurple,
                    child: IconButton(
                      icon: const Icon(Icons.send, color: Colors.white, size: 18),
                      onPressed: _sendMessage,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

@pragma('vm:entry-point')
void onStartBackgroundService(ServiceInstance service) {
  WidgetsFlutterBinding.ensureInitialized();

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
        await _showNotification('Hush (Arrière-plan)', '🔒 Nouveau message chiffré reçu');
      } catch (e) {
        print('Erreur de déchiffrement en arrière-plan : $e');
      }
    }
  };
}