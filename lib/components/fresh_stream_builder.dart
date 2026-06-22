import 'dart:async';
import 'package:flutter/material.dart';

/// A custom wrapper around [StreamBuilder] that creates a fresh [Stream] instance
/// upon widget initialization.
///
/// For Firebase Realtime Database broadcast streams (`.onValue`), this widget
/// ensures a clean subscription. Use [ValueKey] on this widget to force a
/// full stream reconnect when needed (e.g., after upload or delete operations).
class FreshStreamBuilder<T> extends StatefulWidget {
  final Stream<T> Function() streamFactory;
  final AsyncWidgetBuilder<T> builder;

  const FreshStreamBuilder({
    super.key,
    required this.streamFactory,
    required this.builder,
  });

  @override
  State<FreshStreamBuilder<T>> createState() => _FreshStreamBuilderState<T>();
}

class _FreshStreamBuilderState<T> extends State<FreshStreamBuilder<T>> {
  late Stream<T> _stream;

  @override
  void initState() {
    super.initState();
    _stream = widget.streamFactory();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<T>(
      stream: _stream,
      builder: widget.builder,
    );
  }
}
