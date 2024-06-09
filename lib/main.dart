import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() => runApp(const MainApp());

class MainApp extends StatelessWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context) {
    const title = 'Frame Flutter Ticker';
    return const MaterialApp(
      title: title,
      home: HomePage(
        title: title,
      ),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.title,
  });

  final String title;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const String _accessToken = 'YOUR_FREE_TOKEN_HERE'; // TODO put your free Finnhub token here
  final _channel = WebSocketChannel.connect(Uri.parse('wss://ws.finnhub.io?token=$_accessToken'));
  final TextEditingController _controller = TextEditingController(text: 'BINANCE:BTCUSDT');

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Form(
              child: TextFormField(
                controller: _controller,
                decoration: const InputDecoration(labelText: 'Ticker Symbol to Subscribe to:')
              ),
            ),
            const SizedBox(height: 24),
            StreamBuilder(
              stream: _channel.stream,
              builder: (context, snapshot) {
                // update the displayed 'Symbol: Price' when a trade comes through the web socket
                // but return blank for ping messages (filtering the stream would be better)
                if (snapshot.hasData) {
                  var data = jsonDecode(snapshot.data);
                  if (data["type"] == 'trade') {
                    var firstTrade = data["data"][0];
                    return Text('${firstTrade["s"]}: \$${firstTrade["p"].toStringAsFixed(2)}');
                  }
                  else {
                    return const Text('');
                  }
                }
                else {
                  return const Text('');
                }
              },
            )
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _sendMessage,
        tooltip: 'Send message',
        child: const Icon(Icons.send),
      ),
    );
  }

  void _sendMessage() {
    if (_controller.text.isNotEmpty) {
      // Finnhub-specific subscription message
      _channel.sink.add('{"type":"subscribe", "symbol":"${_controller.text}"}');
    }
  }

  @override
  void dispose() {
    _channel.sink.close();
    _controller.dispose();
    super.dispose();
  }
}