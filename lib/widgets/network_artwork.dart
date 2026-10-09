import 'package:flutter/material.dart';

import '../services/network_artwork_provider.dart';
import '../services/artwork_memory.dart';
import '../services/device_performance.dart';
import '../utils/media_image_helper.dart';

/// Media artwork with memory-only caching and bounded image decoding.
class NetworkArtwork extends StatelessWidget {
  const NetworkArtwork({
    super.key,
    required this.imageUrl,
    this.width,
    this.height,
    this.fit,
    this.alignment = Alignment.center,
    this.memCacheWidth,
    this.memCacheHeight,
    this.cacheKey,
    this.httpHeaders = const {'User-Agent': 'Plezy'},
    this.placeholder,
    this.errorBuilder,
  });

  final String imageUrl;
  final double? width;
  final double? height;
  final BoxFit? fit;
  final AlignmentGeometry alignment;
  final int? memCacheWidth;
  final int? memCacheHeight;
  final String? cacheKey;
  final Map<String, String> httpHeaders;
  final Widget Function(BuildContext, String)? placeholder;
  final Widget Function(BuildContext, Object, StackTrace?)? errorBuilder;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: ArtworkMemory.suspended,
    builder: (context, suspended, _) => suspended ? SizedBox(width: width, height: height) : _buildArtwork(context),
  );

  Widget _buildArtwork(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final dpr = MediaImageHelper.effectiveDevicePixelRatio(context);
      int bound(int? explicit, double? size, double limit, int fallback) {
        if (explicit != null && explicit > 0) return explicit.clamp(1, fallback);
        final logical = size != null && size.isFinite && size > 0 ? size : limit;
        return logical.isFinite && logical > 0 ? (logical * dpr).ceil().clamp(1, fallback) : fallback;
      }

      final provider = ResizeImage(
        NetworkArtworkProvider(imageUrl, cacheKey: cacheKey, headers: httpHeaders, isBrowsingArtwork: true),
        width: bound(memCacheWidth, width, constraints.maxWidth, DevicePerformance.isReduced ? 1280 : 1920),
        height: bound(memCacheHeight, height, constraints.maxHeight, DevicePerformance.isReduced ? 720 : 1080),
        policy: ResizeImagePolicy.fit,
      );
      return Image(
        image: provider,
        width: width,
        height: height,
        fit: fit,
        alignment: alignment,
        frameBuilder: placeholder == null
            ? null
            : (context, child, frame, synchronous) =>
                  frame != null || synchronous ? child : placeholder!(context, imageUrl),
        errorBuilder: errorBuilder,
      );
    },
  );
}
