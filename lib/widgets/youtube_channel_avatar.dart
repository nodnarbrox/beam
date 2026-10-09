import 'package:plezy/widgets/network_artwork.dart';
import 'package:flutter/material.dart';

class YouTubeChannelAvatar extends StatelessWidget {
  const YouTubeChannelAvatar({super.key, required this.title, this.url, this.size = 48});
  final String title;
  final String? url;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final fallback = ColoredBox(
      color: colors.primaryContainer,
      child: Center(
        child: Text(
          title.trim().isEmpty ? '?' : title.trim().characters.first.toUpperCase(),
          style: TextStyle(color: colors.onPrimaryContainer, fontSize: size * .42),
        ),
      ),
    );
    final source = url?.startsWith('//') == true ? 'https:$url' : url;
    return SizedBox.square(
      dimension: size,
      child: ClipOval(
        child: source == null || source.isEmpty
            ? fallback
            : NetworkArtwork(
                imageUrl: source,
                fit: BoxFit.cover,
                memCacheWidth: (size * 2).round(),
                placeholder: (_, _) => fallback,
                errorBuilder: (_, _, _) => fallback,
              ),
      ),
    );
  }
}
