import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'frame_helper.dart';
import 'simple_frame_app.dart';

void main() => runApp(const MainApp());

final _log = Logger("MainApp");

class MainApp extends StatefulWidget {
  const MainApp({super.key});

  @override
  MainAppState createState() => MainAppState();
}

/// SimpleFrameAppState mixin helps to manage the lifecycle of the Frame connection outside of this file
class MainAppState extends State<MainApp> with SimpleFrameAppState {
  // Finnhub.io connection
  WebSocketChannel? _channel;

  // ticker subscription details
  final TextEditingController _tokenController = TextEditingController.fromValue(const TextEditingValue(text: 'put your free Finnhub token here'));
  final TextEditingController _symbolController = TextEditingController.fromValue(const TextEditingValue(text: 'BINANCE:BTCUSDT'));
  String _tickerText = '';

  MainAppState() {
    Logger.root.level = Level.INFO;
    Logger.root.onRecord.listen((record) {
      debugPrint('${record.level.name}: ${record.time}: ${record.message}');
    });

    currentState = ApplicationState.disconnected;
  }

  /// subscribe to a ticker feed for the user's selected ticker using their API token
  Future<void> run() async {
    currentState = ApplicationState.running;
    if (mounted) setState(() {});

    try {
      // create websocket
      if (_tokenController.text.isNotEmpty) {
        _log.fine('connecting: wss://ws.finnhub.io?token=${_tokenController.text}');
        _channel = WebSocketChannel.connect(Uri.parse('wss://ws.finnhub.io?token=${_tokenController.text}'));
        await _channel!.ready;

        // subscribe to ticker
        // first wait for controller to be ready
        if (_channel != null && _symbolController.text.isNotEmpty) {
          _log.fine('About to subscribe for: ${_symbolController.text}');
          subscribe(_channel!, _symbolController.text);
        }

        String prevTickerText = '';

        // loop and poll for periodically for user-initiated stop
        while (currentState == ApplicationState.running) {
          // only update the frame display if the ticker value has changed
          if (_tickerText != prevTickerText) {
            await FrameHelper.writeText(frame!, _tickerText);
            await Future.delayed(const Duration(milliseconds: 100));
            await FrameHelper.show(frame!);
            prevTickerText = _tickerText;
          }
          await Future.delayed(const Duration(milliseconds: 2000));
        }

        // when canceled, close websocket and clear the display
        _channel?.sink.close();
        FrameHelper.clear(frame!);
      }
    } catch (e) {
      _log.fine('Error executing application logic: $e');
    }

    currentState = ApplicationState.ready;
    if (mounted) setState(() {});
  }

  Future<void> cancel() async {
    currentState = ApplicationState.ready;
    if (mounted) setState(() {});
  }

  void subscribe(WebSocketChannel channel, String symbol) {
    _log.fine('Subscribing for ticker for $symbol');
    // Finnhub-specific subscription message
    channel.sink.add('{"type":"subscribe", "symbol":"$symbol"}');
  }

  @override
  void dispose() {
    _channel?.sink.close();
    _tokenController.dispose();
    _symbolController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // work out the states of the footer buttons based on the app state
    List<Widget> pfb = [];

    switch (currentState) {
      case ApplicationState.disconnected:
        pfb.add(TextButton(onPressed: scanOrReconnectFrame, child: const Text('Connect')));
        pfb.add(const TextButton(onPressed: null, child: Text('Start')));
        pfb.add(const TextButton(onPressed: null, child: Text('Stop')));
        pfb.add(const TextButton(onPressed: null, child: Text('Disconnect')));
        break;

      case ApplicationState.initializing:
      case ApplicationState.scanning:
      case ApplicationState.connecting:
      case ApplicationState.running:
      case ApplicationState.stopping:
      case ApplicationState.disconnecting:
        pfb.add(const TextButton(onPressed: null, child: Text('Connect')));
        pfb.add(const TextButton(onPressed: null, child: Text('Start')));
        pfb.add(const TextButton(onPressed: null, child: Text('Stop')));
        pfb.add(const TextButton(onPressed: null, child: Text('Disconnect')));
        break;

      case ApplicationState.connected:
        pfb.add(const TextButton(onPressed: null, child: Text('Connect')));
        pfb.add(TextButton(onPressed: startApplication, child: const Text('Start')));
        pfb.add(const TextButton(onPressed: null, child: Text('Stop')));
        pfb.add(TextButton(onPressed: disconnectFrame, child: const Text('Disconnect')));
        break;

      case ApplicationState.ready:
        pfb.add(const TextButton(onPressed: null, child: Text('Connect')));
        pfb.add(const TextButton(onPressed: null, child: Text('Start')));
        pfb.add(TextButton(onPressed: stopApplication, child: const Text('Stop')));
        pfb.add(const TextButton(onPressed: null, child: Text('Disconnect')));
        break;
    }

    return MaterialApp(
      title: 'Frame Flutter Ticker',
      theme: ThemeData.dark(),
      home: Scaffold(
        appBar: AppBar(
          title: const Text("Frame Flutter Ticker"),
        ),
        body: Center(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              children: <Widget>[
                // Finnhub.io subscription
                Form(child: TextFormField(controller: _tokenController,
                    decoration: const InputDecoration(labelText: 'Finnhub free access token:')),
                ),
                const SizedBox(height: 24),
                // Finnhub ticker symbol
                Form(child: TextFormField(controller: _symbolController,
                    decoration: const InputDecoration(labelText: 'Ticker Symbol to Subscribe to:')),
                ),
                const SizedBox(height: 24),

                if (_channel != null)
                  StreamBuilder(
                    stream: _channel!.stream,
                    builder: (context, snapshot) {
                      // update the displayed 'Symbol: Price' when a trade comes through the web socket
                      // but return blank for ping messages (filtering the stream would be better)
                      if (snapshot.hasData) {
                        var data = jsonDecode(snapshot.data);
                        if (data["type"] == 'trade') {
                          var firstTrade = data["data"][0];
                          _tickerText = '${firstTrade["s"]}: \$${firstTrade["p"].toStringAsFixed(2)}';
                        }
                      }
                      return Text(_tickerText);
                    },
                  ),
              ]
            ),
          )
        ),
        floatingActionButton:
          currentState == ApplicationState.ready ?
            FloatingActionButton(onPressed: run, child: const Icon(Icons.auto_graph)) :
          currentState == ApplicationState.running ?
          FloatingActionButton(onPressed: cancel, child: const Icon(Icons.cancel)) : null,
        persistentFooterButtons: pfb,
      ),
    );
  }
}
