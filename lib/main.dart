import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'services/crypto_service.dart';
import 'services/websocket_service.dart';
import 'my_qr_code_screen.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';


final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

Future<void> _initNotifications() async {
  const AndroidInitializationSettings initializationSettingsAndroid =
      AndroidInitializationSettings('@mipmap/ic_launcher'); // Utilise ton icône d'application

  const InitializationSettings initializationSettings =
      InitializationSettings(android: initializationSettingsAndroid);

  await flutterLocalNotificationsPlugin.initialize(initializationSettings);
}

// Fonction pour afficher la notification locale
Future<void> _showNotification(String senderName, String messageBody) async {
  const AndroidNotificationDetails androidPlatformChannelSpecifics =
      AndroidNotificationDetails(
    'hush_chat_channel', // ID du canal
    'Hush Messages',     // Nom du canal visible par l'utilisateur
    channelDescription: 'Notifications pour les messages chiffrés entrants',
    importance: Importance.max,
    priority: Priority.high,
    // Tu peux customiser la couleur de la LED/accent si tu veux du style cyberpunk
    color: Color(0xFF7C4DFF), 
  );

  const NotificationDetails platformChannelSpecifics =
      NotificationDetails(android: androidPlatformChannelSpecifics);

  await flutterLocalNotificationsPlugin.show(
    0, // ID de la notification
    'Nouveau message de $senderName', // Titre
    messageBody, // Corps du message (ou un texte générique si tu préfères garder le contenu masqué pour plus de vie privée : ex: "Nouveau message chiffré")
    platformChannelSpecifics,
  );
}
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // 1. Initialiser Hive pour Flutter
  await Hive.initFlutter();

  // 2. Créer ou récupérer une clé de chiffrement sécurisée
  const secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
    ),
  );
  String? encryptionKeyString = await secureStorage.read(key: 'hush_db_key');
  
  Uint8List encryptionKey;
  if (encryptionKeyString == null) {
    // Génère une clé aléatoire forte si elle n'existe pas encore
    final generatedKey = Hive.generateSecureKey();
    await secureStorage.write(
      key: 'hush_db_key', 
      value: base64UrlEncode(generatedKey),
    );
    encryptionKey = Uint8List.fromList(generatedKey);
  } else {
    encryptionKey = base64Url.decode(encryptionKeyString);
  }

  // 3. Ouvrir la boîte Hive des messages de manière chiffrée (AES-256)
  await Hive.openBox(
    'chat_messages',
    encryptionCipher: HiveAesCipher(encryptionKey),
  );

  // 4. Ouvrir la boîte Hive des contacts de manière chiffrée (AES-256) <--- AJOUTÉ ICI
  await Hive.openBox(
    'contacts_box',
    encryptionCipher: HiveAesCipher(encryptionKey),
  );

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {

  
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Messagerie Chiffrée Anonyme',
      // 1. Le thème clair (au cas où le téléphone est en mode clair)
    theme: ThemeData(
      brightness: Brightness.light,
      primarySwatch: Colors.deepPurple,
      scaffoldBackgroundColor: Colors.grey[100],
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.deepPurple,
        foregroundColor: Colors.white,
      ),
    ),
    
    // 2. Le thème sombre (élégant, avec des nuances de gris sombre/noir)
    darkTheme: ThemeData(
      brightness: Brightness.dark,
      primarySwatch: Colors.deepPurple,
      scaffoldBackgroundColor: const Color(0xFF121212), // Noir mat très propre
      cardColor: const Color(0xFF1E1E1E),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF1E1E1E),
        foregroundColor: Colors.white,
      ),
      dialogTheme: const DialogThemeData(
        backgroundColor: Color(0xFF1E1E1E),
      ),
    ),
    
    // 3. Suit automatiquement le réglage du téléphone (clair ou sombre)
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

@override
  void initState() {
    super.initState();
    _initializeApp();
  }

  Future<void> _initializeApp() async {
    await _initNotifications();
    await _cryptoService.initUserIdentity();
    _myId = _cryptoService.userId;
    _myPubKey = await _cryptoService.getPublicKeyString();

    // Charger les contacts sauvegardés localement
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
          
          // 1. Sauvegarde locale chiffrée (Hive) pour le message reçu
          final messagesBox = Hive.box('chat_messages');
          messagesBox.add({
            'text': decryptedText,
            'isMe': false,
            'conversationId': senderId, // Utile pour retrouver à quelle conversation il appartient
            'timestamp': DateTime.now().toIso8601String(),
          });

          await _showNotification('Hush', '🔒 Nouveau message chiffré reçu');

          setState(() {
            if (!_conversations.containsKey(senderId)) {
              // Si le contact n'existe pas, on le crée et on le sauvegarde automatiquement
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
      } else if (data['type'] == 'error') {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erreur serveur : ${data['message']}'), backgroundColor: Colors.red),
        );
      }
    };
  }

  // Charger les contacts depuis le stockage sécurisé
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
          messages: [], // Les messages seront chargés par _loadSavedMessages juste après
        );
      });
    });
  }
}

Future<void> _loadSavedMessages() async {
  final messagesBox = Hive.box('chat_messages');
  
  // Parcourir tous les messages enregistrés dans la base locale
  for (var item in messagesBox.values) {
    final messageMap = Map<String, dynamic>.from(item as Map);
    
    final String? conversationId = messageMap['conversationId'];
    final String text = messageMap['text'];
    final bool isMe = messageMap['isMe'];
    final DateTime timestamp = DateTime.parse(messageMap['timestamp']);

    // Si on trouve une conversation correspondante en mémoire
    if (conversationId != null && _conversations.containsKey(conversationId)) {
      // Vérifier si le message n'est pas déjà présent pour éviter les doublons
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

  // Sauvegarder les contacts dans le stockage sécurisé
void _saveContactsToStorage() {
  final contactsBox = Hive.box('contacts_box');
  
  // On convertit vos contacts sous forme de map pour les stocker proprement
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
            // Bouton pour lancer le scanner de QR Code (Mobile Scanner)
            OutlinedButton.icon(
              onPressed: () async {
                // 1. On configure le contrôleur pour cibler uniquement les QR codes 
                // et forcer la caméra arrière (évite certains crashs d'initialisation)
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
                      // L'écran de scan avec gestion d'erreur intégrée
                      body: MobileScanner(
                        controller: cameraController,
                        // 2. ON INTERCEPTE L'ERREUR POUR REMPLACER LE POINT D'EXCLAMATION
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
                                  const SizedBox(height: 10),
                                  Text(
                                    error.errorDetails?.message ?? 'Pas de détails fournis par Android',
                                    style: const TextStyle(color: Colors.grey, fontSize: 14),
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
                              cameraController.stop(); // On arrête la caméra proprement
                              Navigator.pop(context, barcode.rawValue);
                              break; // On sort de la boucle dès qu'on a un résultat
                            }
                          }
                        },
                      ),
                    ),
                  ),
                );

                // 3. Libération des ressources de la caméra à la fermeture de l'écran
                cameraController.dispose();

                // Injection du lien scanné dans le champ texte
                if (scannedLink != null) {
                  String cleanLink = scannedLink;
                  
                  // Nettoyage basique sécurisé pour extraire le lien securechat://
                  if (cleanLink.contains('securechat://')) {
                    final startIndex = cleanLink.indexOf('securechat://');
                    // On coupe les éventuels caractères indésirables autour
                    cleanLink = cleanLink.substring(startIndex).split(RegExp(r'["\s}]')).first;
                  }

                  linkController.text = cleanLink;
                  
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('QR code scanné avec succès !'),
                      backgroundColor: Colors.green,
                    ),
                  );
                }
              },
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Scanner le QR code du contact'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(double.infinity, 45),
              ),
            ),
            const SizedBox(height: 16),
            const Divider(),
            const SizedBox(height: 8),

            // Saisie manuelle ou remplie par le scanner
            TextField(
              controller: nameController,
              decoration: const InputDecoration(labelText: 'Nom ou Surnom (ex: Alice)'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: linkController,
              decoration: const InputDecoration(labelText: 'Coller le lien (securechat://...)'),
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

                    // Sauvegarde permanente
                    _saveContactsToStorage();

                    Navigator.pop(context);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Contact ajouté et sauvegardé !'), backgroundColor: Colors.green),
                    );
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
        title: const Text('Messagerie Chiffrée Anonyme'),
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
                  builder: (context) => MyQrCodeScreen(userId: _myContactLink), // Assurez-vous que c'est bien le nom de votre variable d'ID
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
                      const Text('Aucune conversation active.', style: TextStyle(color: Colors.grey, fontSize: 16)),
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
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => ChatScreen(
                              conversation: conversation,
                              cryptoService: _cryptoService,
                              wsService: _wsService,
                              myPubKey: _myPubKey,
                            ),
                          ),
                        ).then((_) => setState(() {}));
                      },
                    );
                  },
                ),
      floatingActionButton: _conversations.isNotEmpty
          ? FloatingActionButton(
              onPressed: _showAddContactDialog,
              child: const Icon(Icons.person_add),
            )
          : null,
    );
  }
}

class ChatScreen extends StatefulWidget {
  final Conversation conversation;
  final CryptoService cryptoService;
  final WebSocketService wsService;
  final String myPubKey;

  const ChatScreen({
    super.key,
    required this.conversation,
    required this.cryptoService,
    required this.wsService,
    required this.myPubKey,
  });

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
    final previousListener = widget.wsService.onMessageReceived;
    widget.wsService.onMessageReceived = (data) async {
      if (previousListener != null) {
        await previousListener(data);
      }
      if (data['type'] == 'message' && data['senderId'] == widget.conversation.contactId) {
        if (mounted) {
          setState(() {});
          _scrollToBottom();
        }
      }
    };
  }

void _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    try {
      final encryptedPayload = await widget.cryptoService.encryptMessage(text, widget.conversation.publicKey);

      widget.wsService.sendMessage(widget.conversation.contactId, encryptedPayload, widget.myPubKey);

      // 1. Sauvegarde locale chiffrée (Hive)
      final messageData = {
        'text': text,
        'isMe': true,
        'conversationId': widget.conversation.contactId,
        'timestamp': DateTime.now().toIso8601String(),
        // Vous pouvez aussi stocker l'ID de la conversation si vous en avez plusieurs :
        // 'conversationId': widget.conversation.contactId, 
      };
      _messagesBox.add(messageData);

      // 2. Mise à jour de l'interface existante
      setState(() {
        widget.conversation.messages.add(
          ChatMessage(text: text, isMe: true, timestamp: DateTime.now()),
        );
      });

      _messageController.clear();
      _scrollToBottom();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Erreur de chiffrement : $e'), backgroundColor: Colors.red),
      );
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
        title: Row(
          children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: Colors.blue.shade200,
              child: Text(initialLetter, style: const TextStyle(fontSize: 14)),
            ),
            const SizedBox(width: 10),
            Text(widget.conversation.contactName),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.all(16),
              itemCount: widget.conversation.messages.length,
              itemBuilder: (context, index) {
                final message = widget.conversation.messages[index];
                return Align(
                  alignment: message.isMe ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
                    decoration: BoxDecoration(
                      color: message.isMe ? Colors.blue.shade600 : Colors.grey.shade200,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Text(
                      message.text,
                      style: TextStyle(
                        color: message.isMe ? Colors.white : Colors.black87,
                        fontSize: 15,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          Padding(
            // C'est ce padding qui va surélever toute la barre du bas
            padding: const EdgeInsets.only(left: 8.0, right: 8.0, bottom: 20.0, top: 8.0),
            child: Container(
              padding: const EdgeInsets.all(8.0),
              // S'adapte au mode sombre ou clair de manière fluide
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
                        // Fond du champ texte adapté au mode sombre
                        fillColor: Theme.of(context).brightness == Brightness.dark 
                            ? const Color(0xFF2C2C2C) 
                            : Colors.white,
                      ),
                      onSubmitted: (_) => _sendMessage(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  CircleAvatar(
                    backgroundColor: Colors.deepPurple, // Garde votre couleur de thème
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