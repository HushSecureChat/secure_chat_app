import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';

class WebSocketService {
  late WebSocketChannel _channel;
  Function(Map<String, dynamic>)? onMessageReceived;

  void connect(String serverUrl, String userId) {
    _channel = WebSocketChannel.connect(Uri.parse(serverUrl));

    // 1. S'enregistrer auprès du serveur avec l'ID aléatoire dès la connexion
    _channel.sink.add(jsonEncode({
      'type': 'register',
      'userId': userId,
    }));

    // 2. Écouter les messages entrants
    _channel.stream.listen((data) {
      final decoded = jsonDecode(data);
      if (onMessageReceived != null) {
        onMessageReceived!(decoded);
      }
    }, onError: (error) {
      print('Erreur WebSocket : $error');
    });
  }

  void sendMessage(String recipientId, String encryptedPayload, String senderPublicKey) {
    _channel.sink.add(jsonEncode({
      'type': 'message',
      'recipientId': recipientId,
      'encryptedPayload': encryptedPayload,
      'senderPublicKey': senderPublicKey, // Transmis pour permettre le déchiffrement direct
    }));
  }

  void dispose() {
    _channel.sink.close();
  }
}