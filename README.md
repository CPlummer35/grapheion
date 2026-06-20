# Grapheion

**Mesh-synced corrective-maintenance approval chain — a proof-of-concept aiming
to replace the Navy's OMMS-NG + SKED (3-M) deckplate experience.**

Grapheion is built on [peat](https://github.com/defenseunicorns/peat)'s
offline-first mesh: maintenance jobs and their full chain-of-custody sync
peer-to-peer across a ship's devices (handhelds + always-on anchors) with no
central server, and converge automatically as devices move between spaces and
drop in and out of range. The off-ship Port Engineer is reached over the mesh
relay.

## What it does today

- **Roles** — each device logs in as one role: Technician, Work Center
  Supervisor (WCS), Leading Petty Officer (LPO), Division Officer (DIVO),
  3-M Coordinator, Chief Engineer, or (off-ship) Port Engineer. A logout / role
  switch is in the app bar.
- **Job approval chain** — a technician originates a job; it climbs the on-ship
  ladder **WCS → LPO → DIVO** (Approve advances, Return kicks it back with a
  comment).
- **TA (Technical Assistance)** — only the **DIVO** can "Request off-ship
  assistance," which connects the **Port Engineer**; the PE engages or declines.
  This is the only way the PE enters a job.
- **Execution + close-out** — after DIVO approval the work center starts work and
  marks it complete, then it climbs the close-out ladder **WCS → LPO → DIVO**
  before it's **Closed**. Closed jobs move to the **Completed** tab.
- **Chain of custody** — every action is recorded in an append-only audit log on
  each job.
- **Notifications** — the next approver gets a "your turn" alert; the originator
  hears when their job is approved, returned, or closed.
- **Mesh tab** — shows every other node, how it's connected (Wi-Fi/relay/BLE),
  and whether it's online (presence in the last 30s) or how long since last seen.
- **QR-gated join** — the DIVO hosts the mesh: it mints a formation key carried
  in a join QR. Everyone else scans that QR once to join (the key + the host are
  remembered, so it's a one-time join). No key = no mesh.

## Architecture

Grapheion is a Flutter app that depends on the `peat_flutter` package (the mesh
binding over the `peat-ffi` native library). It does not run its own server —
the device mesh *is* the backend. Jobs, the audit log, and presence sync as peat
documents over Iroh/QUIC (Wi-Fi/mDNS) and the n0 relay (for the off-ship PE).
*(BLE transport for in-space handhelds is in progress.)*

Repo layout this project expects (siblings under one parent):

```
code/
  peat/          # the Rust workspace (peat-ffi, peat-mesh, …)
  peat-flutter/  # the Flutter package + native build scripts
  grapheion/     # this app
```

## Run it on macOS

### Prerequisites

- **Flutter** (3.9+), with macOS desktop enabled
  (`flutter config --enable-macos-desktop`).
- **Xcode** + command-line tools.
- **Rust** with the macOS targets:
  ```sh
  rustup target add aarch64-apple-darwin x86_64-apple-darwin
  ```
- **protoc** (`brew install protobuf`).
- The `peat` and `peat-flutter` repos checked out as **siblings** of `grapheion`
  (see layout above).

### Steps

1. **Build the peat-ffi native library for macOS.** This produces the
   `libpeat_ffi.dylib` the app links, from the Rust workspace:
   ```sh
   cd ../peat-flutter
   bash macos/build-rust.sh
   ```
   (It writes `peat-flutter/macos/Frameworks/libpeat_ffi.dylib`.)

2. **Fetch Dart dependencies** for grapheion:
   ```sh
   cd ../grapheion
   flutter pub get
   ```

3. **Run the app on macOS:**
   ```sh
   flutter run -d macos
   ```

4. **Use it.** On first launch, sign in with a name, work center (default
   `CP01`), and a role:
   - Log in as **DIVO** on one instance → open the **MESH** tab → it shows the
     **join QR**.
   - Log in as another role on a second instance/device → **MESH** tab →
     **Scan join QR** → point at the DIVO's QR to join the mesh.
   - Originate a job as a technician and walk it up the chain (use the logout
     icon to switch roles on one machine).

> Tip: to drive the whole flow on a single Mac, run a second instance in another
> terminal with `flutter run -d macos` and log it in as a different role, or use
> the in-app role switch.

## Status

Proof-of-concept. Identity and the audit log are modeled, but role authority is
not yet *enforced* (gating is cooperative). Not for operational use.
