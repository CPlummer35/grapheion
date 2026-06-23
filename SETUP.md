# Setting up grapheion (macOS)

> **A bare `git clone grapheion` will not build on its own.** grapheion
> path-depends on its sibling **`peat-flutter`**, which links a native Rust
> library (**`peat-ffi`**) built from a third sibling repo, **`peat`**. You need
> all three repos in the right layout, plus the Rust toolchain, to build the
> native pieces. This doc (and the bootstrap script) set that up.

## TL;DR — one command

From inside a fresh `grapheion` clone:

```sh
./scripts/bootstrap-macos.sh
```

It checks/installs prerequisites, clones `peat` + `peat-flutter` as siblings on
the right branches, builds the native libraries, and runs `flutter pub get`.
Then:

```sh
flutter run -d macos
```

The rest of this doc is the manual version + troubleshooting.

## The repo layout

All three repos must sit **side by side** under one parent directory:

```
code/
├── grapheion/      # this app          (CPlummer35/grapheion, branch main)
├── peat-flutter/   # Flutter FFI plugin (defenseunicorns/peat-flutter, branch feat/reconnect-supervisor-wiring)
└── peat/           # Rust workspace     (defenseunicorns/peat,         branch feat/roster-store)
```

`grapheion/pubspec.yaml` references `peat_flutter` via `path: ../peat-flutter`,
and `peat-flutter`'s native build script reads the `peat` workspace from
`../peat`. The names and relative positions matter.

> These are private repos — you need GitHub access and working auth (SSH or a
> token) to clone them.

## Prerequisites

| Tool | Install | Why |
|------|---------|-----|
| **Flutter** (stable, 3.9+) | <https://docs.flutter.dev/get-started/install/macos> | builds the app |
| **Xcode** + CLI tools | App Store, then `xcode-select --install` | macOS/iOS native build |
| **CocoaPods** | `brew install cocoapods` | Flutter runs `pod install` for plugins |
| **Rust** + macOS targets | `rustup` (see below) | compiles `peat-ffi` / `peat-btle` |
| **protoc** | `brew install protobuf` | `peat-ffi` build generates protobuf |

```sh
flutter config --enable-macos-desktop
rustup target add aarch64-apple-darwin x86_64-apple-darwin
```

## Manual steps

```sh
# 1. Clone all three repos as siblings.
mkdir -p ~/code && cd ~/code
git clone https://github.com/CPlummer35/grapheion.git
git clone -b feat/reconnect-supervisor-wiring https://github.com/defenseunicorns/peat-flutter.git
git clone -b feat/roster-store               https://github.com/defenseunicorns/peat.git

# 2. Build the native peat-ffi dylib (writes peat-flutter/macos/Frameworks/libpeat_ffi.dylib).
cd ~/code/peat-flutter
PEAT_WORKSPACE_DIR=../peat bash macos/build-rust.sh

# 3. Build the macOS BLE xcframework (writes grapheion/macos/Frameworks/PeatBtle.xcframework).
#    Run AFTER step 2 — that cargo build populates the registry cache this needs.
cd ~/code/grapheion
PEAT_WORKSPACE_DIR=../peat bash macos/build-btle.sh

# 4. Fetch Dart deps and run.
flutter pub get
flutter run -d macos
```

## Troubleshooting

- **`flutter pub get` can't find `../peat-flutter`** — the siblings aren't cloned
  in the right place. See the layout above.
- **`peat-btle-<version> not in the cargo registry cache`** (build-btle.sh) — run
  step 2 (`build-rust.sh`) first; its cargo build fetches the crate. Or run
  `cargo fetch` inside `../peat`.
- **`protoc: command not found`** — `brew install protobuf`.
- **`linker / target ... not installed`** — run the `rustup target add …` line.
- **CocoaPods errors during `flutter run`** — `brew install cocoapods`, then
  `cd macos && pod install --repo-update`.
- **First launch shows default fonts** — `google_fonts` fetches Teko/Inter on
  first run; it needs internet once, then caches them.

## Other platforms

- **iOS:** same three repos + Rust; build with `peat-flutter/ios/build-rust.sh`
  and the iOS BLE framework, then `flutter run -d <device>`. Wired deploy is more
  reliable than wireless.
- **Android:** Gradle cross-compiles `peat-ffi` automatically (no manual native
  build), but needs the Android SDK/NDK + a JDK and the Rust Android targets +
  `cargo-ndk`. See the project notes for the toolchain specifics.
