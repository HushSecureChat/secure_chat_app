class ChatMessage {
  final String text;
  final bool isMe;
  final DateTime timestamp;
  final String? imageBase64;

  ChatMessage({required this.text, required this.isMe, required this.timestamp, this.imageBase64});
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