import 'package:flutter/material.dart';

import '../../mixins/refreshable.dart';
import 'beam_discover_search.dart';
import 'settings/beam_settings_screen.dart';

/// Top-level host for the Beam tab. Presents the search experience with a
/// settings entry in the app bar. This is the widget wired into the Plezy
/// navigation shell (see [NavigationTabId.beam] and main_screen).
///
/// This MUST be a [StatefulWidget] implementing [FocusableTab]: main_screen
/// hands D-pad focus to a tab by calling `focusActiveTabIfReady()` on its
/// State via `_onScreen<FocusableTab>`. A plain StatelessWidget satisfies
/// nothing, so focus has nowhere to land and the remote is stranded on the
/// sidebar — the tab looks unselectable.
class BeamHome extends StatefulWidget {
  const BeamHome({super.key});

  @override
  State<BeamHome> createState() => BeamHomeState();
}

class BeamHomeState extends State<BeamHome>
    with FocusableTab, SearchInputFocusable {
  /// Lets us drive focus/search inside the child search screen without
  /// rebuilding it (the child owns the TextField + its FocusNode).
  final GlobalKey<BeamDiscoverSearchState> _searchKey = GlobalKey();

  @override
  void focusActiveTabIfReady() =>
      _searchKey.currentState?.focusActiveTabIfReady();

  @override
  void focusSearchInput() => _searchKey.currentState?.focusSearchInput();

  @override
  void submitSearchQuery(String query) =>
      _searchKey.currentState?.submitSearchQuery(query);

  @override
  Widget build(BuildContext context) {
    return BeamDiscoverSearch(
      key: _searchKey,
      appBarActions: [
        IconButton(
          tooltip: 'Beam settings',
          icon: const Icon(Icons.settings_rounded),
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const BeamSettingsScreen()),
          ),
        ),
      ],
    );
  }
}
