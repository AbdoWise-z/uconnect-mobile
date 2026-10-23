// Raw dart:ffi bindings over uconnect_c.h (the uconnect library's flat C ABI).
// Hand-written against include/uconnect/uconnect_c.h at the pinned revision;
// see native/CMakeLists.txt. Everything here mirrors the header one to one --
// the Dart-friendly layer lives in uconnect.dart.
//
// ignore_for_file: camel_case_types, non_constant_identifier_names

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

const int ucDefaultTimeoutMs = 3000;
const int ucUriMax = 106;

// uconnect_topic_mode
const int ucTopicOpen = 0;
const int ucTopicKeyed = 1;

// uconnect_peer_state
const int ucPeerUnknown = 0;
const int ucPeerProbing = 1;
const int ucPeerHandshaking = 2;
const int ucPeerConnected = 3;
const int ucPeerFailed = 4;
const int ucPeerClosed = 5;

// uconnect_peer_gone
const int ucGoneLocal = 0;
const int ucGoneTimedOut = 1;
const int ucGoneGoingAway = 2;
const int ucGoneShuttingDown = 3;
const int ucGoneUnspecified = 4;

// uconnect_datagram_fallback
const int ucFallbackTcp = 0;
const int ucFallbackRelay = 1;
const int ucFallbackNone = 2;

// uconnect_datagram_path
const int ucPathNone = 0;
const int ucPathOpening = 1;
const int ucPathDirect = 2;
const int ucPathRelayed = 3;
const int ucPathTcp = 4;
const int ucPathFailed = 5;

// uconnect_event_kind
const int ucEventPeer = 0;
const int ucEventData = 1;
const int ucEventDatagram = 2;
const int ucEventDatagramPath = 3;
const int ucEventPeerClosed = 4;

final class UcTopicId extends Struct {
  @Array(16)
  external Array<Uint8> bytes;
}

final class UcDevId extends Struct {
  @Array(16)
  external Array<Uint8> bytes;
}

final class UcKey extends Struct {
  @Array(32)
  external Array<Uint8> bytes;
}

final class UcTopicCreds extends Struct {
  external UcTopicId id;
  @Bool()
  external bool keyed;
  external UcKey key;
}

final class UcEndpoint extends Struct {
  @Uint8()
  external int family;
  @Array(16)
  external Array<Uint8> addr;
  @Uint16()
  external int port;
}

final class UcTopicSummary extends Struct {
  external UcTopicId id;
  @Int32()
  external int mode;
  @Uint32()
  external int peers;
  @Uint32()
  external int freshPeers;
}

final class UcServerStats extends Struct {
  @Uint64()
  external int topicsTotal;
  @Uint64()
  external int topicsListed;
  @Uint64()
  external int entriesTotal;
  @Uint64()
  external int entriesFresh;
  @Uint64()
  external int registers;
  @Uint64()
  external int lookups;
  @Uint64()
  external int connects;
  @Uint64()
  external int expired;
  @Uint64()
  external int rejQuota;
  @Uint64()
  external int rejRateLimited;
  @Uint64()
  external int relaysOpen;
  @Uint64()
  external int relaysAllocated;
  @Uint64()
  external int relayBytes;
  @Uint64()
  external int connections;
}

final class UcLinkInfo extends Struct {
  @Bool()
  external bool relayed;
  @Uint64()
  external int messagesSent;
  @Uint64()
  external int messagesReceived;
  @Uint64()
  external int bytesSent;
  @Uint64()
  external int bytesReceived;
  @Uint64()
  external int datagramsSent;
  @Uint64()
  external int datagramsReceived;
}

final class UcPeerInfo extends Struct {
  external UcDevId devId;
  @Uint32()
  external int ageS;
  @Bool()
  external bool stale;
  external Pointer<Uint8> meta;
  @Size()
  external int metaLen;
}

final class NativeNodeConfig extends Struct {
  external Pointer<Utf8> server;
  @Uint16()
  external int bindPort;
  @Uint32()
  external int keepaliveS;
  @Size()
  external int maxTotalPeers;
  @Uint32()
  external int punchTimeoutS;
  @Bool()
  external bool forceRelay;
  @Bool()
  external bool verbose;
  @Int32()
  external int datagramFallback;
  @Uint8()
  external int rekeyShift;
}

final class UcEvent extends Struct {
  @Int32()
  external int kind;
  external UcTopicId topic;
  external UcDevId dev;
  @Int32()
  external int peerState;
  @Int32()
  external int datagramPath;
  @Int32()
  external int peerGone;
  external Pointer<Uint8> data;
  @Size()
  external int len;
}

// Opaque handles.
final class NativeNode extends Opaque {}

final class UcPeerList extends Opaque {}

/// Loads the uconnect_c shared library for the current platform.
///
/// `UCONNECT_C_LIBRARY` (an absolute path) overrides the lookup, which is how
/// host-side tests point at a locally built DLL/so.
DynamicLibrary openUconnectLibrary() {
  final override = Platform.environment['UCONNECT_C_LIBRARY'];
  if (override != null && override.isNotEmpty) {
    // MinGW builds depend on libwinpthread-1.dll, which sits next to the
    // library -- but Windows resolves dependencies from the process's PATH,
    // where an older copy may shadow it. Preloading the sibling pins it.
    final sep = override.contains('/') ? '/' : '\\';
    final dir = override.substring(0, override.lastIndexOf(sep));
    try {
      DynamicLibrary.open('$dir${sep}libwinpthread-1.dll');
    } on ArgumentError {
      // not a MinGW build; nothing to preload
    }
    return DynamicLibrary.open(override);
  }
  if (Platform.isAndroid) return DynamicLibrary.open('libuconnect_c.so');
  if (Platform.isIOS) return DynamicLibrary.process(); // statically linked
  if (Platform.isWindows) return DynamicLibrary.open('uconnect_c.dll');
  if (Platform.isMacOS) return DynamicLibrary.open('libuconnect_c.dylib');
  return DynamicLibrary.open('libuconnect_c.so');
}

/// The raw C functions, resolved once per isolate.
class UcBindings {
  UcBindings(DynamicLibrary lib)
      : lastError = lib.lookupFunction<Pointer<Utf8> Function(),
            Pointer<Utf8> Function()>('uconnect_last_error'),
        maxMessage = lib.lookupFunction<Size Function(), int Function()>(
            'uconnect_max_message'),
        maxDatagram = lib.lookupFunction<Size Function(), int Function()>(
            'uconnect_max_datagram'),
        credsGenerate = lib.lookupFunction<
            Bool Function(Bool, Pointer<UcTopicCreds>),
            bool Function(bool, Pointer<UcTopicCreds>)>('uconnect_creds_generate'),
        credsParse = lib.lookupFunction<
            Bool Function(Pointer<Utf8>, Pointer<UcTopicCreds>),
            bool Function(
                Pointer<Utf8>, Pointer<UcTopicCreds>)>('uconnect_creds_parse'),
        credsToUri = lib.lookupFunction<
            Size Function(Pointer<UcTopicCreds>, Pointer<Utf8>, Size),
            int Function(Pointer<UcTopicCreds>, Pointer<Utf8>,
                int)>('uconnect_creds_to_uri'),
        nodeConfigInit = lib.lookupFunction<Void Function(Pointer<NativeNodeConfig>),
            void Function(Pointer<NativeNodeConfig>)>('uconnect_node_config_init'),
        nodeNew = lib.lookupFunction<
            Pointer<NativeNode> Function(Pointer<NativeNodeConfig>),
            Pointer<NativeNode> Function(Pointer<NativeNodeConfig>)>('uconnect_node_new'),
        nodeFree = lib.lookupFunction<Void Function(Pointer<NativeNode>),
            void Function(Pointer<NativeNode>)>('uconnect_node_free'),
        nodeRunInBackground = lib.lookupFunction<Void Function(Pointer<NativeNode>),
            void Function(Pointer<NativeNode>)>('uconnect_node_run_in_background'),
        nodeShutdown = lib.lookupFunction<Void Function(Pointer<NativeNode>),
            void Function(Pointer<NativeNode>)>('uconnect_node_shutdown'),
        nodeIsRunning = lib.lookupFunction<Bool Function(Pointer<NativeNode>),
            bool Function(Pointer<NativeNode>)>('uconnect_node_is_running'),
        nodeLocalPort = lib.lookupFunction<Uint16 Function(Pointer<NativeNode>),
            int Function(Pointer<NativeNode>)>('uconnect_node_local_port'),
        nodeReflexive = lib.lookupFunction<
            Bool Function(Pointer<NativeNode>, Pointer<UcEndpoint>),
            bool Function(
                Pointer<NativeNode>, Pointer<UcEndpoint>)>('uconnect_node_reflexive'),
        nodeServerConnected = lib.lookupFunction<Bool Function(Pointer<NativeNode>),
            bool Function(Pointer<NativeNode>)>('uconnect_node_server_connected'),
        nodePendingRequests = lib.lookupFunction<Size Function(Pointer<NativeNode>),
            int Function(Pointer<NativeNode>)>('uconnect_node_pending_requests'),
        nodeStats = lib.lookupFunction<
            Bool Function(Pointer<NativeNode>, Uint32, Pointer<UcServerStats>),
            bool Function(Pointer<NativeNode>, int,
                Pointer<UcServerStats>)>('uconnect_node_stats'),
        nodeJoin = lib.lookupFunction<
            Bool Function(Pointer<NativeNode>, Pointer<UcTopicCreds>),
            bool Function(
                Pointer<NativeNode>, Pointer<UcTopicCreds>)>('uconnect_node_join'),
        nodeCreate = lib.lookupFunction<
            Bool Function(Pointer<NativeNode>, Bool, Pointer<UcTopicCreds>),
            bool Function(Pointer<NativeNode>, bool,
                Pointer<UcTopicCreds>)>('uconnect_node_create'),
        nodeLeave = lib.lookupFunction<
            Void Function(Pointer<NativeNode>, UcTopicId),
            void Function(Pointer<NativeNode>, UcTopicId)>('uconnect_node_leave'),
        nodeTopics = lib.lookupFunction<
            Size Function(Pointer<NativeNode>, Pointer<UcTopicId>, Size),
            int Function(Pointer<NativeNode>, Pointer<UcTopicId>,
                int)>('uconnect_node_topics'),
        nodeCreds = lib.lookupFunction<
            Bool Function(Pointer<NativeNode>, UcTopicId, Pointer<UcTopicCreds>),
            bool Function(Pointer<NativeNode>, UcTopicId,
                Pointer<UcTopicCreds>)>('uconnect_node_creds'),
        topicPublish = lib.lookupFunction<
            Bool Function(Pointer<NativeNode>, UcTopicId, Pointer<Uint8>, Size, Bool),
            bool Function(Pointer<NativeNode>, UcTopicId, Pointer<Uint8>, int,
                bool)>('uconnect_topic_publish'),
        topicUnpublish = lib.lookupFunction<
            Void Function(Pointer<NativeNode>, UcTopicId),
            void Function(Pointer<NativeNode>, UcTopicId)>('uconnect_topic_unpublish'),
        topicSelf = lib.lookupFunction<
            Bool Function(Pointer<NativeNode>, UcTopicId, Pointer<UcDevId>),
            bool Function(Pointer<NativeNode>, UcTopicId,
                Pointer<UcDevId>)>('uconnect_topic_self'),
        topicPeers = lib.lookupFunction<
            Pointer<UcPeerList> Function(
                Pointer<NativeNode>, UcTopicId, Uint8, Bool, Uint32),
            Pointer<UcPeerList> Function(Pointer<NativeNode>, UcTopicId, int, bool,
                int)>('uconnect_topic_peers'),
        topicResolve = lib.lookupFunction<
            Pointer<UcPeerList> Function(
                Pointer<NativeNode>, UcTopicId, UcDevId, Uint32),
            Pointer<UcPeerList> Function(Pointer<NativeNode>, UcTopicId, UcDevId,
                int)>('uconnect_topic_resolve'),
        peerListSize = lib.lookupFunction<Size Function(Pointer<UcPeerList>),
            int Function(Pointer<UcPeerList>)>('uconnect_peer_list_size'),
        peerListGet = lib.lookupFunction<
            Bool Function(Pointer<UcPeerList>, Size, Pointer<UcPeerInfo>),
            bool Function(Pointer<UcPeerList>, int,
                Pointer<UcPeerInfo>)>('uconnect_peer_list_get'),
        peerListFree = lib.lookupFunction<Void Function(Pointer<UcPeerList>),
            void Function(Pointer<UcPeerList>)>('uconnect_peer_list_free'),
        topicConnect = lib.lookupFunction<
            Void Function(Pointer<NativeNode>, UcTopicId, UcDevId),
            void Function(
                Pointer<NativeNode>, UcTopicId, UcDevId)>('uconnect_topic_connect'),
        topicConnectAll = lib.lookupFunction<
            Void Function(Pointer<NativeNode>, UcTopicId, Size),
            void Function(
                Pointer<NativeNode>, UcTopicId, int)>('uconnect_topic_connect_all'),
        topicDisconnect = lib.lookupFunction<
            Void Function(Pointer<NativeNode>, UcTopicId, UcDevId),
            void Function(Pointer<NativeNode>, UcTopicId,
                UcDevId)>('uconnect_topic_disconnect'),
        topicDisconnectAll = lib.lookupFunction<
            Void Function(Pointer<NativeNode>, UcTopicId),
            void Function(
                Pointer<NativeNode>, UcTopicId)>('uconnect_topic_disconnect_all'),
        topicConnected = lib.lookupFunction<
            Size Function(Pointer<NativeNode>, UcTopicId, Pointer<UcDevId>, Size),
            int Function(Pointer<NativeNode>, UcTopicId, Pointer<UcDevId>,
                int)>('uconnect_topic_connected'),
        topicState = lib.lookupFunction<
            Int32 Function(Pointer<NativeNode>, UcTopicId, UcDevId),
            int Function(
                Pointer<NativeNode>, UcTopicId, UcDevId)>('uconnect_topic_state'),
        topicLink = lib.lookupFunction<
            Bool Function(Pointer<NativeNode>, UcTopicId, UcDevId, Pointer<UcLinkInfo>),
            bool Function(Pointer<NativeNode>, UcTopicId, UcDevId,
                Pointer<UcLinkInfo>)>('uconnect_topic_link'),
        topicPeerAddress = lib.lookupFunction<
            Bool Function(Pointer<NativeNode>, UcTopicId, UcDevId, Pointer<UcEndpoint>),
            bool Function(Pointer<NativeNode>, UcTopicId, UcDevId,
                Pointer<UcEndpoint>)>('uconnect_topic_peer_address'),
        topicSend = lib.lookupFunction<
            Bool Function(Pointer<NativeNode>, UcTopicId, UcDevId, Pointer<Uint8>, Size),
            bool Function(Pointer<NativeNode>, UcTopicId, UcDevId, Pointer<Uint8>,
                int)>('uconnect_topic_send'),
        topicBroadcast = lib.lookupFunction<
            Size Function(Pointer<NativeNode>, UcTopicId, Pointer<Uint8>, Size),
            int Function(Pointer<NativeNode>, UcTopicId, Pointer<Uint8>,
                int)>('uconnect_topic_broadcast'),
        topicOpenDatagrams = lib.lookupFunction<
            Bool Function(Pointer<NativeNode>, UcTopicId, UcDevId, Int32),
            bool Function(Pointer<NativeNode>, UcTopicId, UcDevId,
                int)>('uconnect_topic_open_datagrams'),
        topicCloseDatagrams = lib.lookupFunction<
            Void Function(Pointer<NativeNode>, UcTopicId, UcDevId),
            void Function(Pointer<NativeNode>, UcTopicId,
                UcDevId)>('uconnect_topic_close_datagrams'),
        topicDatagramPath = lib.lookupFunction<
            Int32 Function(Pointer<NativeNode>, UcTopicId, UcDevId),
            int Function(Pointer<NativeNode>, UcTopicId,
                UcDevId)>('uconnect_topic_datagram_path'),
        topicSendDatagram = lib.lookupFunction<
            Bool Function(Pointer<NativeNode>, UcTopicId, UcDevId, Pointer<Uint8>, Size),
            bool Function(Pointer<NativeNode>, UcTopicId, UcDevId, Pointer<Uint8>,
                int)>('uconnect_topic_send_datagram'),
        topicSendDatagramsOverTcp = lib.lookupFunction<
            Bool Function(Pointer<NativeNode>, UcTopicId, UcDevId),
            bool Function(Pointer<NativeNode>, UcTopicId,
                UcDevId)>('uconnect_topic_send_datagrams_over_tcp'),
        topicSetMaxPeers = lib.lookupFunction<
            Void Function(Pointer<NativeNode>, UcTopicId, Size),
            void Function(
                Pointer<NativeNode>, UcTopicId, int)>('uconnect_topic_set_max_peers'),
        topicSetAutoConnect = lib.lookupFunction<
            Void Function(Pointer<NativeNode>, UcTopicId, Bool),
            void Function(Pointer<NativeNode>, UcTopicId,
                bool)>('uconnect_topic_set_auto_connect'),
        topicIsAuthenticated = lib.lookupFunction<
            Bool Function(Pointer<NativeNode>, UcTopicId),
            bool Function(
                Pointer<NativeNode>, UcTopicId)>('uconnect_topic_is_authenticated'),
        topicSas = lib.lookupFunction<
            Size Function(Pointer<NativeNode>, UcTopicId, UcDevId, Pointer<Utf8>, Size),
            int Function(Pointer<NativeNode>, UcTopicId, UcDevId, Pointer<Utf8>,
                int)>('uconnect_topic_sas'),
        topicChannelBinding = lib.lookupFunction<
            Bool Function(Pointer<NativeNode>, UcTopicId, UcDevId, Pointer<Uint8>),
            bool Function(Pointer<NativeNode>, UcTopicId, UcDevId,
                Pointer<Uint8>)>('uconnect_topic_channel_binding'),
        topicQueueEvents = lib.lookupFunction<
            Void Function(Pointer<NativeNode>, UcTopicId),
            void Function(
                Pointer<NativeNode>, UcTopicId)>('uconnect_topic_queue_events'),
        nodeNextEvent = lib.lookupFunction<
            Pointer<UcEvent> Function(Pointer<NativeNode>, Uint32),
            Pointer<UcEvent> Function(
                Pointer<NativeNode>, int)>('uconnect_node_next_event'),
        eventFree = lib.lookupFunction<Void Function(Pointer<UcEvent>),
            void Function(Pointer<UcEvent>)>('uconnect_event_free');

  final Pointer<Utf8> Function() lastError;
  final int Function() maxMessage;
  final int Function() maxDatagram;

  final bool Function(bool keyed, Pointer<UcTopicCreds> out) credsGenerate;
  final bool Function(Pointer<Utf8> uri, Pointer<UcTopicCreds> out) credsParse;
  final int Function(Pointer<UcTopicCreds>, Pointer<Utf8> buf, int cap)
      credsToUri;

  final void Function(Pointer<NativeNodeConfig>) nodeConfigInit;
  final Pointer<NativeNode> Function(Pointer<NativeNodeConfig>) nodeNew;
  final void Function(Pointer<NativeNode>) nodeFree;
  final void Function(Pointer<NativeNode>) nodeRunInBackground;
  final void Function(Pointer<NativeNode>) nodeShutdown;
  final bool Function(Pointer<NativeNode>) nodeIsRunning;
  final int Function(Pointer<NativeNode>) nodeLocalPort;
  final bool Function(Pointer<NativeNode>, Pointer<UcEndpoint>) nodeReflexive;
  final bool Function(Pointer<NativeNode>) nodeServerConnected;
  final int Function(Pointer<NativeNode>) nodePendingRequests;
  final bool Function(Pointer<NativeNode>, int timeoutMs, Pointer<UcServerStats>)
      nodeStats;

  final bool Function(Pointer<NativeNode>, Pointer<UcTopicCreds>) nodeJoin;
  final bool Function(Pointer<NativeNode>, bool keyed, Pointer<UcTopicCreds>)
      nodeCreate;
  final void Function(Pointer<NativeNode>, UcTopicId) nodeLeave;
  final int Function(Pointer<NativeNode>, Pointer<UcTopicId>, int cap) nodeTopics;
  final bool Function(Pointer<NativeNode>, UcTopicId, Pointer<UcTopicCreds>)
      nodeCreds;

  final bool Function(
          Pointer<NativeNode>, UcTopicId, Pointer<Uint8>, int, bool unlisted)
      topicPublish;
  final void Function(Pointer<NativeNode>, UcTopicId) topicUnpublish;
  final bool Function(Pointer<NativeNode>, UcTopicId, Pointer<UcDevId>) topicSelf;

  final Pointer<UcPeerList> Function(
          Pointer<NativeNode>, UcTopicId, int max, bool wantMeta, int timeoutMs)
      topicPeers;
  final Pointer<UcPeerList> Function(
      Pointer<NativeNode>, UcTopicId, UcDevId, int timeoutMs) topicResolve;
  final int Function(Pointer<UcPeerList>) peerListSize;
  final bool Function(Pointer<UcPeerList>, int, Pointer<UcPeerInfo>)
      peerListGet;
  final void Function(Pointer<UcPeerList>) peerListFree;

  final void Function(Pointer<NativeNode>, UcTopicId, UcDevId) topicConnect;
  final void Function(Pointer<NativeNode>, UcTopicId, int maxPeers) topicConnectAll;
  final void Function(Pointer<NativeNode>, UcTopicId, UcDevId) topicDisconnect;
  final void Function(Pointer<NativeNode>, UcTopicId) topicDisconnectAll;
  final int Function(Pointer<NativeNode>, UcTopicId, Pointer<UcDevId>, int cap)
      topicConnected;
  final int Function(Pointer<NativeNode>, UcTopicId, UcDevId) topicState;
  final bool Function(Pointer<NativeNode>, UcTopicId, UcDevId, Pointer<UcLinkInfo>)
      topicLink;
  // Where the peer's direct connection comes from; false when relayed or none.
  final bool Function(Pointer<NativeNode>, UcTopicId, UcDevId, Pointer<UcEndpoint>)
      topicPeerAddress;

  final bool Function(Pointer<NativeNode>, UcTopicId, UcDevId, Pointer<Uint8>, int)
      topicSend;
  final int Function(Pointer<NativeNode>, UcTopicId, Pointer<Uint8>, int)
      topicBroadcast;

  final bool Function(Pointer<NativeNode>, UcTopicId, UcDevId, int fallback)
      topicOpenDatagrams;
  final void Function(Pointer<NativeNode>, UcTopicId, UcDevId) topicCloseDatagrams;
  final int Function(Pointer<NativeNode>, UcTopicId, UcDevId) topicDatagramPath;
  final bool Function(Pointer<NativeNode>, UcTopicId, UcDevId, Pointer<Uint8>, int)
      topicSendDatagram;
  final bool Function(Pointer<NativeNode>, UcTopicId, UcDevId) topicSendDatagramsOverTcp;

  final void Function(Pointer<NativeNode>, UcTopicId, int) topicSetMaxPeers;
  final void Function(Pointer<NativeNode>, UcTopicId, bool) topicSetAutoConnect;

  final bool Function(Pointer<NativeNode>, UcTopicId) topicIsAuthenticated;
  final int Function(Pointer<NativeNode>, UcTopicId, UcDevId, Pointer<Utf8>, int)
      topicSas;
  final bool Function(Pointer<NativeNode>, UcTopicId, UcDevId, Pointer<Uint8>)
      topicChannelBinding;

  final void Function(Pointer<NativeNode>, UcTopicId) topicQueueEvents;
  final Pointer<UcEvent> Function(Pointer<NativeNode>, int timeoutMs) nodeNextEvent;
  final void Function(Pointer<UcEvent>) eventFree;
}
