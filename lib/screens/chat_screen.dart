import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:image_picker/image_picker.dart';

import '../services/crypto_service.dart';
import '../services/websocket_service.dart';
import '../models/chat_model.dart';

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

  Timer? _statusTimer;
  @override
  void initState() {
    super.initState();
    // Demander le statut initial
  _checkContactStatus();

  // Répéter la vérification toutes les 5 secondes
  _statusTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
    _checkContactStatus();
  });
  }

 void _checkContactStatus() {
  print('📤 Check status envoyé pour : ${widget.conversation.contactId}');
  widget.wsService.send(jsonEncode({
    'type': 'check_status',
    'targetId': widget.conversation.contactId,
  }));
}

  @override
  void dispose() {
    _statusTimer?.cancel(); // Ne pas oublier d'annuler le timer en quittant l'écran
    super.dispose();
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

                WidgetsBinding.instance.addPostFrameCallback((_) {
                  _scrollToBottom();
                });

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
                        child: message['imageBase64'] != null && message['imageBase64'].isNotEmpty
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Image.memory(
                            base64Decode(message['imageBase64']),
                            width: 200,
                            fit: BoxFit.cover,
                          ),
                        )
                      : Text(
                          text,
                          style: TextStyle(color: isMe ? Colors.white : Colors.black87, fontSize: 15),
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
                  IconButton(
                    icon: const Icon(Icons.image, color: Colors.deepPurple),
                    onPressed: _pickAndSendImage,
                    tooltip: 'Envoyer une photo',
                  ),
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

  Future<void> _pickAndSendImage() async {
  final ImagePicker picker = ImagePicker();
  final XFile? image = await picker.pickImage(source: ImageSource.gallery, imageQuality: 60);
  if (image == null) return;

  final bytes = await image.readAsBytes();
  final base64Str = base64Encode(bytes);

  try {
    // On préfixe pour identifier le payload image
    final payloadToSend = "IMG:$base64Str";
    final encryptedPayload = await widget.cryptoService.encryptMessage(payloadToSend, widget.conversation.publicKey);
    
    widget.wsService.sendMessage(widget.conversation.contactId, encryptedPayload, widget.myPubKey);

    _messagesBox.add({
      'text': 'Image',
      'isMe': true,
      'conversationId': widget.conversation.contactId,
      'timestamp': DateTime.now().toIso8601String(),
      'imageBase64': base64Str,
    });

    widget.conversation.messages.add(
      ChatMessage(text: 'Image', isMe: true, timestamp: DateTime.now(), imageBase64: base64Str),
    );

    _scrollToBottom();
  } catch (e) {
    print('Erreur chiffrement/envoi image : $e');
  }
}

}

