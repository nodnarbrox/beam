import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:http/http.dart' as http;

import 'image_cache_service.dart';
import 'artwork_memory.dart';

/// Network artwork decoded directly into Flutter's bounded RAM image cache.
/// No cache manager, path provider, or filesystem participates in loading.
class NetworkArtworkProvider extends ImageProvider<NetworkArtworkProvider> {
  @visibleForTesting
  static http.Client? clientOverride;

  NetworkArtworkProvider(
    this.url, {
    this.cacheKey,
    Map<String, String> headers = const {'User-Agent': 'Plezy'},
    this.scale = 1,
    this.isBrowsingArtwork = false,
    @visibleForTesting http.Client? client,
    this.timeout = const Duration(seconds: 30),
    this.maxResponseBytes = 16 * 1024 * 1024,
  }) : headers = Map.unmodifiable(headers),
       client = client ?? clientOverride;

  final String url;
  final String? cacheKey;
  final Map<String, String> headers;
  final double scale;
  final bool isBrowsingArtwork;
  final Duration timeout;
  final int maxResponseBytes;
  final http.Client? client;

  @override
  Future<NetworkArtworkProvider> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(NetworkArtworkProvider key, ImageDecoderCallback decode) =>
      MultiFrameImageStreamCompleter(codec: _load(decode), scale: scale, debugLabel: 'Network artwork');

  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
    final abort = Completer<void>();
    var cancelled = false;
    void cancel() {
      cancelled = true;
      if (!abort.isCompleted) abort.complete();
    }

    final unregister = isBrowsingArtwork ? ArtworkMemory.registerBrowseAbort(cancel) : null;
    try {
      if (isBrowsingArtwork && ArtworkMemory.isSuspended) throw const NetworkArtworkException();
      final bytes = await Future.any<Uint8List>([
        _download(abort.future),
        abort.future.then<Uint8List>((_) => throw const NetworkArtworkException()),
      ]).timeout(timeout);
      if (cancelled) throw const NetworkArtworkException();
      final codec = await decode(await ui.ImmutableBuffer.fromUint8List(bytes));
      if (cancelled || (isBrowsingArtwork && ArtworkMemory.isSuspended)) {
        codec.dispose();
        throw const NetworkArtworkException();
      }
      return codec;
    } catch (_) {
      // HTTP exceptions and decoder diagnostics can include signed URLs. Do
      // not expose transport messages or token-bearing cache keys to the UI.
      scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(this));
      throw const NetworkArtworkException();
    } finally {
      unregister?.call();
      if (!abort.isCompleted) abort.complete();
    }
  }

  Future<Uint8List> _download(Future<void> abort) async {
    final uri = Uri.parse(url);
    if (uri.scheme != 'http' && uri.scheme != 'https') throw const NetworkArtworkException();
    final request = http.AbortableRequest('GET', uri, abortTrigger: abort)..headers.addAll(headers);
    final response = await (client ?? networkArtworkHttpClient).send(request);
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.stream) {
      if ((response.statusCode != 200 && response.statusCode != 202) ||
          (response.contentLength ?? 0) > maxResponseBytes ||
          bytes.length + chunk.length > maxResponseBytes) {
        throw const NetworkArtworkException();
      }
      bytes.add(chunk);
    }
    if (bytes.isEmpty || (response.statusCode != 200 && response.statusCode != 202)) {
      throw const NetworkArtworkException();
    }
    return bytes.takeBytes();
  }

  @override
  bool operator ==(Object other) =>
      other is NetworkArtworkProvider &&
      url == other.url &&
      cacheKey == other.cacheKey &&
      scale == other.scale &&
      isBrowsingArtwork == other.isBrowsingArtwork &&
      mapEquals(headers, other.headers) &&
      identical(client, other.client);

  @override
  int get hashCode => Object.hash(
    url,
    cacheKey,
    scale,
    isBrowsingArtwork,
    Object.hashAllUnordered(headers.entries.map((entry) => Object.hash(entry.key, entry.value))),
    client,
  );

  @override
  String toString() => 'NetworkArtworkProvider(scale: $scale)';
}

class NetworkArtworkException implements Exception {
  const NetworkArtworkException();
  @override
  String toString() => 'Artwork could not be loaded';
}
