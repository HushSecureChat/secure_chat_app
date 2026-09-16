import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../services/crypto_service.dart';
import '../services/websocket_service.dart';
import '../models/chat_model.dart';
import '../my_qr_code_screen.dart';
import 'chat_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final CryptoService _cryptoService = CryptoService();
  final WebSocketService _wsService = WebSocketService();
  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  final String currentAppVersion = "16.09.26";
  final String versionUrl = 'https://ws-secure-chat.onrender.com/version.json';

Future<void> _checkForUpdates() async {
  debugPrint("🔍 Tentative de vérification des mises à jour..."); // 👈 Ajoute ça
  try {
    final response = await http.get(Uri.parse(versionUrl));
    debugPrint("📥 Réponse reçue du serveur : ${response.statusCode}"); // 👈 Ajoute ça
    
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      debugPrint("📦 Données JSON reçues : $data"); // 👈 Ajoute ça
      
      final String latestVersion = data['latestVersion'];
      final String releaseNotes = data['releaseNotes'];

      if (latestVersion != currentAppVersion) {
        setState(() {
          _conversations['system_update'] = Conversation(
            contactId: 'system_update',
            contactName: 'Mise à jour Hush (v$latestVersion)',
            publicKey: 'SYSTEM_UPDATE',
            messages: [
              ChatMessage(
                text: "🚀 Une nouvelle version ($latestVersion) est disponible !\n\nNouveautés :\n$releaseNotes\n\nCliquez ici pour télécharger la mise à jour.",
                isMe: false,
                timestamp: DateTime.now(),
              )
            ],
          );
        });
      }
    }
  } catch (e) {
    debugPrint("❌ Erreur critique lors de la vérification des mises à jour : $e"); // 👈 Ajoute ça
  }
}

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
    _checkForUpdates();
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
                      onTap: () async {
                      if (conversation.contactId == 'system_update') {
                        // URL directe de l'APK récupérée ou codée en dur
                        final Uri url = Uri.parse('https://github.com/d4nm0/Hush_web/releases/download/Beta.08092026/Hush.Beta.08092026.apk');
                        if (await canLaunchUrl(url)) {
                          await launchUrl(url, mode: LaunchMode.externalApplication);
                        }
                        return;
                      }

                      // Comportement normal pour un vrai contact...
                      _wsService.send(jsonEncode({
                        'type': 'check_status',
                        'targetId': conversation.contactId,
                      }));

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