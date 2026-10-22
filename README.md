<h1 align="center">uConnect Mobile</h1>

<p align="center">
  Your phone, connected to your computers: browse, download and upload files
  on your devices' shared folders, end-to-end encrypted. The Flutter companion
  to <a href="https://github.com/AbdoWise-z/uconnect-desktop">uConnect Desktop</a>.
</p>

> **Beta.** uConnect is in public beta: expect rough edges.

## Features

- **Devices you trust.** Devices meet in a *topic*, shared by an invite link
  (paste it, or read the QR code from another device's settings). Each
  verifies the others' fingerprints, then decides exactly what they may do:
  every service is behind a permission.
- **Storage, both ways.** Browse, download and upload files in the folders
  your computers share — and share a folder from the phone, with read-only
  shares and per-device permissions, speaking the same protocol
  (storage 1.3) as the desktop app.
- **Resumable, verified transfers.** Downloads resume where they stopped and
  every file is checked against its SHA-256 before it is kept.
- **Same trust model as the desktop.** Ed25519 device identities bound to each
  encrypted session; trusted-only grants never apply to devices you have not
  verified.

Screen sharing, remote control, camera and extended display are desktop
features that this version of the mobile app does not implement yet; the
protocol leaves room for them, and the permission editor lists them as
unavailable.

### Screenshots

<p align="center">
  <img src="docs/images/connect-page.png" width="260"
       alt="The first-run page: rendezvous server, invite link, Connect">
</p>

## How it works

Devices find each other through a **rendezvous server**, which introduces
them and then gets out of the way: they connect directly, punching through
NAT where they can, or fall back to the server's relay — which carries only
ciphertext it cannot read. Networking comes from the
[uconnect](https://github.com/AbdoWise-z/uconnect) library, compiled into the
app and driven over Dart FFI; the app protocol on top is specified in
[uconnect-desktop's docs/protocol.md](https://github.com/AbdoWise-z/uconnect-desktop/blob/master/docs/protocol.md).

## Getting started

1. Set up [uConnect Desktop](https://github.com/AbdoWise-z/uconnect-desktop)
   on your computers, with a rendezvous server both it and the phone can reach.
2. Install uConnect Mobile and give it the server's address (`host:port`).
3. Paste the topic's **invite link** from the desktop app (or create the topic
   on the phone and paste its link into the desktop app). Send invite links
   privately: anyone who has one can join the topic.
4. **Trust** each device after checking its fingerprint, then grant the
   permissions you want under each device.

## Building

Requirements: Flutter 3.47+, the Android SDK with NDK r27 and CMake (the
uconnect C library is cross-compiled into the app by Gradle), and for the
host-side tests a desktop C++20 toolchain.

```sh
flutter pub get
flutter build apk            # or: flutter run
```

### Tests

Protocol and FFI tests run on the host against a real uconnect build,
rendezvous server included:

```powershell
powershell -File scripts/build-host.ps1   # builds uconnect_c + the server
powershell -File scripts/test.ps1         # unit + loopback E2E
```

End to end on a connected Android device (everything runs over the USB cable
via `adb reverse`): the suite builds the app, installs it, and drives the real
device through identity verification, listing, download, upload and file
operations against a host peer.

```powershell
powershell -File scripts/e2e-android.ps1
```

This suite is green on a physical arm64 device against a Windows host peer; add
Mac/iOS devices with `-DeviceId` once the iOS framework (below) is built.

## Platforms

|                               | Android 9+ | iOS |
|-------------------------------|:----------:|:---:|
| Browse / download / upload    | ✓ | planned |
| Offer a shared folder         | ✓ | planned |
| Folder sync                   | — | — |
| Watch a shared screen         | — | — |

iOS needs the uconnect library built as a static XCFramework and a Mac to
build on; the Dart side is platform-independent and ready for it.

## License

MIT, like the rest of uConnect. See [LICENSE](LICENSE).
