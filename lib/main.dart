import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'bluetooth.dart';
import 'display_helper.dart';

void main() => runApp(const MainApp());

/// basic State Machine for the app; mostly for bluetooth lifecycle,
/// all app activity expected to take place during "running" state
enum ApplicationState {
  disconnected,
  scanning,
  connecting,
  ready,
  running,
  stopping,
  disconnecting,
}

final _log = Logger("MainApp");

class MainApp extends StatefulWidget {
  const MainApp({super.key});

  @override
  MainAppState createState() => MainAppState();
}

class MainAppState extends State<MainApp> {
  late ApplicationState _currentState;
  // Finnhub.io connection
  WebSocketChannel? _channel;

  // ticker subscription details
  final TextEditingController _tokenController = TextEditingController.fromValue(const TextEditingValue(text: 'put your free Finnhub token here'));
  final TextEditingController _symbolController = TextEditingController.fromValue(const TextEditingValue(text: 'BINANCE:BTCUSDT'));
  String _tickerText = '';

  // Use BrilliantBluetooth for communications with Frame
  BrilliantDevice? _connectedDevice;
  StreamSubscription? _scanStream;
  StreamSubscription<BrilliantDevice>? _deviceStateSubs;

  MainAppState() {
    Logger.root.level = Level.ALL;
    Logger.root.onRecord.listen((record) {
      debugPrint('${record.level.name}: ${record.time}: ${record.message}');
    });

    _currentState = ApplicationState.disconnected;
  }

  Future<void> _scanForFrame() async {
    _currentState = ApplicationState.scanning;
    if (mounted) setState(() {});

    await BrilliantBluetooth.requestPermission();

    await _scanStream?.cancel();
    _scanStream = BrilliantBluetooth.scan()
      .timeout(const Duration(seconds: 5), onTimeout: (sink) {
        // Scan timeouts can occur without having found a Frame, but also
        // after the Frame is found and being connected to, even though
        // the first step after finding the Frame is to stop the scan.
        // In those cases we don't want to change the application state back
        // to disconnected
        switch (_currentState) {
          case ApplicationState.scanning:
            _log.fine('Scan timed out after 5 seconds');
            _currentState = ApplicationState.disconnected;
            if (mounted) setState(() {});
            break;
          case ApplicationState.connecting:
            // found a device and started connecting, just let it play out
            break;
          case ApplicationState.ready:
          case ApplicationState.running:
            // already connected, nothing to do
            break;
          default:
            _log.fine('Unexpected state on scan timeout: $_currentState');
            if (mounted) setState(() {});
        }
      })
      .listen((device) {
        _log.fine('Frame found, connecting');
        _currentState = ApplicationState.connecting;
        if (mounted) setState(() {});

        _connectToScannedFrame(device);
      });
  }

  Future<void> _connectToScannedFrame(BrilliantScannedDevice device) async {
    try {
      _log.fine('connecting to scanned device: $device');
      _connectedDevice = await BrilliantBluetooth.connect(device);
      _log.fine('device connected: ${_connectedDevice!.device.remoteId}');

      // subscribe to connection state for the device to detect disconnections
      // so we can transition the app to a disconnected state
      await _deviceStateSubs?.cancel();
      _deviceStateSubs = _connectedDevice!.connectionState.listen((bd) {
        _log.fine('Frame connection state change: ${bd.state.name}');
        if (bd.state == BrilliantConnectionState.disconnected) {
          _currentState = ApplicationState.disconnected;
          _log.fine('Frame disconnected: currentState: $_currentState');
          if (mounted) setState(() {});
        }
      });

      try {
        // terminate the main.lua (if currently running) so we can run our lua code
        // TODO looks like if the signal comes too early after connection, it isn't registered
        await Future.delayed(const Duration(milliseconds: 500));
        await _connectedDevice!.sendBreakSignal();

        // Application is ready to go!
        _currentState = ApplicationState.ready;
        if (mounted) setState(() {});

      } catch (e) {
        _currentState = ApplicationState.disconnected;
        _log.fine('Error while sending break signal: $e');
        if (mounted) setState(() {});

        _disconnectFrame();
      }
    } catch (e) {
      _currentState = ApplicationState.disconnected;
      _log.fine('Error while connecting and/or discovering services: $e');
    }
  }

  Future<void> _reconnectFrame() async {
    if (_connectedDevice != null) {
      try {
        _log.fine('connecting to existing device: $_connectedDevice');
        await BrilliantBluetooth.reconnect(_connectedDevice!.uuid);
        _log.fine('device connected: $_connectedDevice');

        // subscribe to connection state for the device to detect disconnections
        // and transition the app to a disconnected state
        await _deviceStateSubs?.cancel();
        _deviceStateSubs = _connectedDevice!.connectionState.listen((bd) {
          _log.fine('Frame connection state change: ${bd.state.name}');
          if (bd.state == BrilliantConnectionState.disconnected) {
            _currentState = ApplicationState.disconnected;
            _log.fine('Frame disconnected');
            if (mounted) setState(() {});
          }
        });

        try {
          // terminate the main.lua (if currently running) so we can run our lua code
          // TODO looks like if the signal comes too early after connection, it isn't registered
          await Future.delayed(const Duration(milliseconds: 500));
          await _connectedDevice!.sendBreakSignal();

          // Application is ready to go!
          _currentState = ApplicationState.ready;
          if (mounted) setState(() {});

        } catch (e) {
          _currentState = ApplicationState.disconnected;
          _log.fine('Error while sending break signal: $e');
          if (mounted) setState(() {});

        _disconnectFrame();
        }
      } catch (e) {
        _currentState = ApplicationState.disconnected;
        _log.fine('Error while connecting and/or discovering services: $e');
        if (mounted) setState(() {});
      }
    }
    else {
      _currentState = ApplicationState.disconnected;
      _log.fine('Current device is null, reconnection not possible');
      if (mounted) setState(() {});
    }
  }

  Future<void> _disconnectFrame() async {
    if (_connectedDevice != null) {
      try {
        _log.fine('Disconnecting from Frame');
        // break first in case it's sleeping - otherwise the reset won't work
        await _connectedDevice!.sendBreakSignal();
        _log.fine('Break signal sent');
        // TODO the break signal needs some more time to be processed before we can reliably send the reset signal, by the looks of it
        await Future.delayed(const Duration(milliseconds: 500));

        // try to reset device back to running main.lua
        await _connectedDevice!.sendResetSignal();
        _log.fine('Reset signal sent');
        // TODO the reset signal doesn't seem to be processed in time if we disconnect immediately, so we introduce a delay here to give it more time
        // The sdk's sendResetSignal actually already adds 100ms delay
        // perhaps it's not quite enough.
        await Future.delayed(const Duration(milliseconds: 500));

      } catch (e) {
          _log.fine('Error while sending reset signal: $e');
      }

      try{
          // try to disconnect cleanly if the device allows
          await _connectedDevice!.disconnect();
      } catch (e) {
          _log.fine('Error while calling disconnect(): $e');
      }
    }
    else {
      _log.fine('Current device is null, disconnection not possible');
    }

    _currentState = ApplicationState.disconnected;
    if (mounted) setState(() {});
  }

  /// subscribe to a ticker feed for the user's selected ticker using their API token
  Future<void> _runApplication() async {
    _currentState = ApplicationState.running;
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
          _subscribe(_channel!, _symbolController.text);
        }

        String prevTickerText = '';

        // loop and poll for periodically for user-initiated stop
        while (_currentState == ApplicationState.running) {
          // only update the frame display if the ticker value has changed
          if (_tickerText != prevTickerText) {
            DisplayHelper.writeText(_connectedDevice!, _tickerText);
            await Future.delayed(const Duration(milliseconds: 100));
            DisplayHelper.show(_connectedDevice!);
            prevTickerText = _tickerText;
          }
          await Future.delayed(const Duration(milliseconds: 2000));
        }

        // when canceled, close websocket and clear the display
        _channel?.sink.close();
        DisplayHelper.clear(_connectedDevice!);
      }
    } catch (e) {
      _log.fine('Error executing application logic: $e');
    }

    _currentState = ApplicationState.ready;
    if (mounted) setState(() {});
  }

  Future<void> _stopApplication() async {
    _currentState = ApplicationState.stopping;
    if (mounted) setState(() {});
  }

  void _subscribe(WebSocketChannel channel, String symbol) {
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

    switch (_currentState) {
      case ApplicationState.disconnected:
        pfb.add(TextButton(onPressed: _connectedDevice != null ? _reconnectFrame : _scanForFrame, child: const Text('Connect Frame')));
        pfb.add(const TextButton(onPressed: null, child: Text('Start Ticker')));
        pfb.add(const TextButton(onPressed: null, child: Text('Finish')));
        break;

      case ApplicationState.scanning:
      case ApplicationState.connecting:
      case ApplicationState.stopping:
      case ApplicationState.disconnecting:
        pfb.add(const TextButton(onPressed: null, child: Text('Connect Frame')));
        pfb.add(const TextButton(onPressed: null, child: Text('Start Ticker')));
        pfb.add(const TextButton(onPressed: null, child: Text('Finish')));
        break;

      case ApplicationState.ready:
        pfb.add(const TextButton(onPressed: null, child: Text('Connect Frame')));
        pfb.add(TextButton(onPressed: _runApplication, child: const Text('Start Ticker')));
        pfb.add(TextButton(onPressed: _disconnectFrame, child: const Text('Finish')));
        break;

      case ApplicationState.running:
        pfb.add(const TextButton(onPressed: null, child: Text('Connect Frame')));
        pfb.add(TextButton(onPressed: _stopApplication, child: const Text('Stop Ticker')));
        pfb.add(const TextButton(onPressed: null, child: Text('Finish')));
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
        persistentFooterButtons: pfb,
      ),
    );
  }
}
