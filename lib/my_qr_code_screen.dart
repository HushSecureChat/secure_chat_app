import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

class MyQrCodeScreen extends StatelessWidget {
  final String userId;
  final String? publicKey; // Optionnel, si vous voulez inclure la clé publique de chiffrement

  const MyQrCodeScreen({
    Key? key,
    required this.userId,
    this.publicKey,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    // On crée un format JSON contenant les infos du contact à scanner
    final contactData = jsonEncode({
      'userId': userId,
      if (publicKey != null) 'publicKey': publicKey,
    });

    return Scaffold(
      appBar: AppBar(
        title: const Text('Mon QR Code de contact'),
        backgroundColor: Colors.deepPurple,
        foregroundColor: Colors.white,
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text(
                'Faites scanner ce QR code par un ami pour qu\'il puisse vous ajouter instantanément.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16, color: Colors.grey),
              ),
              const SizedBox(height: 30),
              
              // Conteneur du QR Code avec un design propre
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.1),
                      blurRadius: 10,
                      spreadRadius: 5,
                    ),
                  ],
                ),
                child: QrImageView(
                  data: contactData,
                  version: QrVersions.auto,
                  size: 220.0,
                  backgroundColor: Colors.white,
                ),
              ),
              
              const SizedBox(height: 30),
              const Text(
                'Votre ID unique :',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 5),
              SelectableText(
                userId,
                style: const TextStyle(fontSize: 14, color: Colors.deepPurple),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}