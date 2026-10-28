// Permissions this device can grant to others, each with a unique, stable
// name ("<service>.<action>"); the ids and semantics are the protocol's
// (docs/protocol.md section 4) and match uconnect-desktop's table. The UI is
// built from this table, so adding a permission is one entry here plus the
// check where the action is served.

class Perm {
  static const storageObserve = 'storage.observe';
  static const storageRead = 'storage.read';
  static const storageWrite = 'storage.write';
  static const storageUpload = 'storage.upload';
  static const cameraView = 'camera.view';
  static const cameraDirect = 'camera.direct';
  static const screenView = 'screen.view';
  static const screenDirect = 'screen.direct';
  static const controlInput = 'control.input';
  static const controlDirect = 'control.direct';
  static const displayShow = 'display.show';
  static const displayDirect = 'display.direct';
  static const syncOffer = 'sync.offer';
  static const syncReceive = 'sync.receive';
}

class PermissionInfo {
  const PermissionInfo({
    required this.id,
    required this.service,
    required this.label,
    required this.description,
    this.available = true,
    this.sensitive = false,
  });

  final String id;
  final String service; // as in hello's service names
  final String label; // short, shown next to a switch
  final String description; // one sentence: what the other device can do
  final bool available; // false while the action itself does not exist yet
  /// Camera, screen, control, display: worth a second thought before
  /// granting it widely (as a default or a broad network rule).
  final bool sensitive;
}

/// What this app can serve today: storage fully; screen/control/camera
/// hosting and being an extended display are not offered from a phone in this
/// version, so their grants are listed but unavailable.
const List<PermissionInfo> permissionTable = [
  PermissionInfo(
      id: Perm.storageObserve,
      service: 'storage',
      label: 'Observe',
      description:
          'Browse the shared folders and see the names, sizes and dates of the files in them.'),
  PermissionInfo(
      id: Perm.storageRead,
      service: 'storage',
      label: 'Read',
      description: 'Open files and save copies of them to their device.'),
  PermissionInfo(
      id: Perm.storageWrite,
      service: 'storage',
      label: 'Write',
      description: 'Rename, move, replace or delete existing files and folders.'),
  PermissionInfo(
      id: Perm.storageUpload,
      service: 'storage',
      label: 'Upload',
      description: 'Add new files and folders, and copy what is already there.'),
  PermissionInfo(
      id: Perm.cameraView,
      service: 'camera',
      label: 'View',
      description: 'Watch this device\'s camera.',
      available: true,
      sensitive: true),
  PermissionInfo(
      id: Perm.cameraDirect,
      service: 'camera',
      label: 'Without asking',
      description:
          'View the camera without a consent prompt.',
      available: true,
      sensitive: true),
  PermissionInfo(
      id: Perm.screenView,
      service: 'screen',
      label: 'View',
      description: 'Watch this device\'s screen.',
      available: true,
      sensitive: true),
  PermissionInfo(
      id: Perm.screenDirect,
      service: 'screen',
      label: 'Without asking',
      description:
          'View the screen without a consent prompt.',
      available: true,
      sensitive: true),
  PermissionInfo(
      id: Perm.controlInput,
      service: 'control',
      label: 'Control',
      description: 'Tap, swipe, scroll and type on this device while watching its screen.',
      available: true,
      sensitive: true),
  PermissionInfo(
      id: Perm.controlDirect,
      service: 'control',
      label: 'Without asking',
      description:
          'Control this device without a consent prompt.',
      available: true,
      sensitive: true),
  PermissionInfo(
      id: Perm.displayShow,
      service: 'display',
      label: 'Use as display',
      description: 'Ask to use this device\'s screen as an extra monitor.',
      available: false,
      sensitive: true),
  PermissionInfo(
      id: Perm.displayDirect,
      service: 'display',
      label: 'Without asking',
      description:
          'Use this device\'s screen as a monitor without a consent prompt.',
      available: false,
      sensitive: true),
  PermissionInfo(
      id: Perm.syncOffer,
      service: 'sync',
      label: 'Offer sync',
      description:
          "Be offered this device's synced folders, and be sent the folders it is a member of."),
  PermissionInfo(
      id: Perm.syncReceive,
      service: 'sync',
      label: 'Receive sync',
      description:
          'Have its synced folders offered here, so this device can join them.'),
];

/// A name for a service, as the permission editors head their groups.
String serviceLabel(String service) => switch (service) {
      'storage' => 'Storage',
      'camera' => 'Camera',
      'screen' => 'Screen sharing',
      'control' => 'Remote control',
      'display' => 'Extended display',
      'sync' => 'Folder sync',
      _ => service,
    };

/// Whether a device with these permissions takes part in folder sync at
/// all: it is offered folders, or its offers are taken, or both.
bool syncsWith(Iterable<String> perms) =>
    perms.contains(Perm.syncOffer) || perms.contains(Perm.syncReceive);

bool isKnownPermission(String id) => permissionTable.any((p) => p.id == id);


/// A saved grant of `storage.download`, from an earlier protocol revision,
/// means `storage.read`.
Set<String> normalizePermissions(Iterable<String> ids) => {
      for (final id in ids)
        if (id == 'storage.download') Perm.storageRead else id
    };

/// Sensitive permissions (camera, screen, control, display): any source may
/// grant them, but the UI warns when they reach many devices.
bool isSensitivePermission(String id) =>
    permissionTable.any((p) => p.id == id && p.sensitive);
