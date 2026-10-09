import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../focus/key_event_utils.dart';
import '../services/youtube/youtube_account.dart';
import '../services/youtube/youtube_service.dart';
import '../services/youtube/youtube_library.dart';
import '../services/youtube/youtube_accounts.dart';
import '../focus/focusable_wrapper.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../widgets/youtube_channel_avatar.dart';
import '../utils/app_logger.dart';

class YouTubeAccountScreen extends StatefulWidget {
  const YouTubeAccountScreen({
    super.key,
    required this.preferences,
    required this.profileId,
    required this.onPlay,
    required this.onChannel,
  });
  final SharedPreferences preferences;
  final String profileId;
  final Future<void> Function(YouTubeVideo) onPlay;
  final ValueChanged<String> onChannel;
  @override
  State<YouTubeAccountScreen> createState() => _YouTubeAccountScreenState();
}

class _YouTubeAccountScreenState extends State<YouTubeAccountScreen> {
  late var _account = YouTubeAccount(widget.preferences, widget.profileId);
  late final _accounts = YouTubeAccounts(widget.preferences, widget.profileId);
  YouTubeAccount? _pendingAccount;
  YouTubeDeviceCode? _code;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(
      _run(() async {
        await _account.refreshSubscriptionAvatars();
        if (mounted) await _accounts.rememberCurrent();
      }),
    );
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error, stack) {
      if (!mounted) return;
      appLogger.w('YouTube account operation failed', error: error, stackTrace: stack);
      _error = error is YouTubeAccountFailure ? error.message : 'YouTube could not complete this request. Try again.';
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _code = null;
        });
      }
    }
  }

  Future<void> _connect() => _run(() async {
    final profile = '${widget.profileId}.youtube-signin.${DateTime.now().microsecondsSinceEpoch}';
    final pending = _pendingAccount = YouTubeAccount(widget.preferences, profile);
    try {
      final code = await pending.begin();
      if (!mounted) return;
      setState(() => _code = code);
      await pending.finish(code);
      if (!mounted) return;
      await pending.sync();
      if (!mounted) return;
      _account.close();
      try {
        await _accounts.adopt(profile);
      } finally {
        _account = YouTubeAccount(widget.preferences, widget.profileId);
      }
    } finally {
      pending.close();
      _pendingAccount = null;
      await YouTubeAccounts(widget.preferences, profile).clearPending();
    }
  });

  Future<void> _switch(String id) => _run(() async {
    _account.close();
    try {
      await _accounts.select(id);
    } finally {
      _account = YouTubeAccount(widget.preferences, widget.profileId);
    }
  });

  Future<void> _remove() => _run(() async {
    _account.close();
    try {
      await _accounts.forgetCurrent();
    } finally {
      _account = YouTubeAccount(widget.preferences, widget.profileId);
    }
  });

  @override
  void dispose() {
    _account.close();
    _pendingAccount?.close();
    super.dispose();
  }

  List<Widget> _videos(String title, Object? raw) {
    final videos = (raw as List? ?? []).map((v) => YouTubeVideo.fromJson(v as Map<String, dynamic>)).toList();
    if (videos.isEmpty) return [];
    return [
      Padding(
        padding: const EdgeInsets.only(top: 24, bottom: 8),
        child: Text(title, style: Theme.of(context).textTheme.titleLarge),
      ),
      for (final video in videos)
        ListTile(
          leading: const Icon(Icons.play_circle_outline),
          title: Text(video.title, maxLines: 2, overflow: TextOverflow.ellipsis),
          subtitle: Text(video.author),
          onTap: () => unawaited(widget.onPlay(video)),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _account.snapshot;
    final code = _code;
    if (code != null) {
      return Focus(
        autofocus: true,
        skipTraversal: true,
        onKeyEvent: (_, event) => handleBackKeyNavigation(context, event),
        child: Scaffold(
          appBar: AppBar(title: const Text('Add YouTube account')),
          body: Center(
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Wrap(
                  spacing: 40,
                  runSpacing: 24,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Container(
                      color: Colors.white,
                      padding: const EdgeInsets.all(12),
                      child: QrImageView(data: code.qrUrl, size: 240, backgroundColor: Colors.white),
                    ),
                    SizedBox(
                      width: 320,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('Scan to sign in', style: Theme.of(context).textTheme.headlineMedium),
                          const SizedBox(height: 16),
                          const Text(
                            'Choose your Google account on your phone. This screen will update when you finish.',
                          ),
                          const SizedBox(height: 24),
                          const Text('If Google asks for a code'),
                          Text(code.userCode, style: Theme.of(context).textTheme.headlineLarge),
                          const SizedBox(height: 24),
                          TextButton(
                            autofocus: true,
                            onPressed: () => Navigator.of(context).pop(),
                            child: const Text('Cancel'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }
    return Focus(
      autofocus: true,
      skipTraversal: true,
      onKeyEvent: (_, event) => handleBackKeyNavigation(context, event),
      child: Scaffold(
        appBar: AppBar(title: const Text('Your YouTube')),
        body: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Row(
              children: [
                YouTubeChannelAvatar(
                  title: snapshot?['name'] as String? ?? 'YouTube',
                  url: snapshot?['avatarUrl'] as String?,
                  size: 72,
                ),
                const SizedBox(width: 20),
                Expanded(
                  child: Text(
                    snapshot?['name'] as String? ?? 'Your YouTube accounts',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                ),
              ],
            ),
            if (_accounts.accounts.isNotEmpty) ...[
              const SizedBox(height: 24),
              Text('Switch account', style: Theme.of(context).textTheme.titleLarge),
              for (final account in _accounts.accounts)
                FocusableWrapper(
                  onSelect: () {
                    if (!_busy) unawaited(_switch(account['id'] as String));
                  },
                  child: ExcludeFocus(
                    child: ListTile(
                      leading: YouTubeChannelAvatar(
                        title: account['name'] as String,
                        url: account['avatarUrl'] as String?,
                        size: 40,
                      ),
                      title: Text(account['name'] as String),
                      trailing: account['id'] == _accounts.activeId
                          ? Icon(Icons.check_circle, color: Theme.of(context).colorScheme.primary)
                          : const Icon(Icons.swap_horiz),
                      onTap: _busy ? null : () => _switch(account['id'] as String),
                    ),
                  ),
                ),
            ],
            const SizedBox(height: 12),
            const Text(
              'Bring your likes, uploads, and subscriptions into this Plezy profile. Your likes also help shape For you.',
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 16,
              runSpacing: 12,
              children: [
                FilledButton.icon(
                  autofocus: true,
                  onPressed: _busy ? null : _connect,
                  icon: const Icon(Icons.qr_code),
                  label: Text(_account.connected ? 'Add account with QR code' : 'Sign in with QR code'),
                ),
                if (_account.connected) ...[
                  FilledButton.icon(
                    autofocus: true,
                    onPressed: _busy ? null : () => _run(_account.sync),
                    icon: const Icon(Icons.refresh),
                    label: const Text('Refresh library'),
                  ),
                  TextButton(onPressed: _busy ? null : _remove, child: const Text('Remove this account')),
                ],
                if (_busy) TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
              ],
            ),
            if (_busy) const Padding(padding: EdgeInsets.symmetric(vertical: 20), child: LinearProgressIndicator()),
            if (_error != null) Padding(padding: const EdgeInsets.symmetric(vertical: 20), child: Text(_error!)),
            if (snapshot != null) ...[
              const SizedBox(height: 16),
              const Text(
                'Showing up to 50 recent likes, uploads, and subscribed channels. Private or restricted videos may not play.',
              ),
              ..._videos('Liked videos', snapshot['liked']),
              ..._videos('Your uploads', snapshot['uploads']),
              Padding(
                padding: const EdgeInsets.only(top: 24, bottom: 8),
                child: Text('Subscriptions', style: Theme.of(context).textTheme.titleLarge),
              ),
              for (final channel in YouTubeLibrary(
                widget.preferences,
                widget.profileId,
              ).sortSubscriptions(snapshot['subscriptions'] as List? ?? []))
                ListTile(
                  leading: YouTubeChannelAvatar(
                    title: channel['title'] as String,
                    url: channel['avatarUrl'] as String?,
                    size: 40,
                  ),
                  title: Text(channel['title'] as String),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Navigator.of(context).pop();
                    widget.onChannel(channel['id'] as String);
                  },
                ),
            ],
          ],
        ),
      ),
    );
  }
}
