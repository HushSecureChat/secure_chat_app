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