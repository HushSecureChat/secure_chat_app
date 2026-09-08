import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';

class WebSocketService {
  late WebSocketChannel _channel;
  Function(Map<String, dynamic>)? onMessageReceived;

Future<void> connect(String serverUrl, String userId) async {
  _channel = WebSocketChannel.connect(Uri.parse(serverUrl));

  try {
    // 1. Attendre que la connexion WebSocket soit réellement établie
    await _channel.ready;

    // 2. S'enregistrer auprès du serveur une fois la connexion ouverte
    _channel.sink.add(jsonEncode({
      'type': 'register',
      'userId': userId,
    }));
    print('Enregistrement envoyé au serveur pour l\'ID : $userId');
  } catch (e) {
    print('Erreur lors de l\'établissement du WebSocket : $e');
  }

  // 3. Écouter les messages entrants
  _channel.stream.listen((data) {
    final decoded = jsonDecode(data);
    if (onMessageReceived != null) {
      onMessageReceived!(decoded);
    }
  }, onError: (error) {
    print('Erreur WebSocket : $error');
  }, onDone: () {
    print('Connexion WebSocket fermée');
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

  void send(String data) {
  _channel.sink.add(data);
}
}