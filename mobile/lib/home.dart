import 'package:flutter/material.dart';
import 'package:mobile/widgets/header.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key}); // done to avoid rebuilding
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text("Bridge")),
      body: Column(
        children: [
          Center(child: Text("Welcome to the Home Screen!")),
          const Header(),
        ],
      ),
    );
  }
}
