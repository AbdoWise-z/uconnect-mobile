// iOS keeps an app's files in a container whose directory name is a UUID the
// system picks: .../Containers/Data/Application/<UUID>/Documents/... A new
// one is assigned when the app is reinstalled or restored from a backup, and
// during development on every fresh install, so an absolute path saved in
// state.json (a shared folder, a synced folder) can point into a container
// that no longer exists. The files themselves move with the app; only the
// prefix changes.

final _container = RegExp(r'^.*/Data/Application/[0-9A-Fa-f-]{36}(?=/|$)');

/// The container directory `path` lies in, or null when it is not inside an
/// iOS app container.
String? iosContainerOf(String path) => _container.firstMatch(path)?.group(0);

/// `path` moved from whichever app container it was saved under to
/// `currentContainer`; unchanged when it is not inside a container.
String rebaseIosContainerPath(String path, String currentContainer) {
  final old = iosContainerOf(path);
  if (old == null || old == currentContainer) return path;
  return currentContainer + path.substring(old.length);
}
