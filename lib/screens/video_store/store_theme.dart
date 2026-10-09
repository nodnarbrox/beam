import '../../services/device_performance.dart' show StoreThemeSetting;
import '../../services/settings_service.dart';

/// Resolves whether the video store should render its Halloween ("spooky")
/// theme right now.
///
/// Precedence: an explicit user override wins; otherwise it's automatic —
/// spooky during October (the whole month), normal the rest of the year.
bool resolveHalloweenActive({DateTime? now}) {
  final setting = SettingsService.instanceOrNull?.read(SettingsService.storeTheme) ??
      StoreThemeSetting.auto;
  switch (setting) {
    case StoreThemeSetting.spooky:
      return true;
    case StoreThemeSetting.normal:
      return false;
    case StoreThemeSetting.auto:
      final d = now ?? DateTime.now();
      return d.month == DateTime.october;
  }
}
