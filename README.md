# Grapheion

**An all-encompassing, offline-first ship administration tool for a Navy ship —
maintenance (corrective + preventive), casualty reporting, watch organization &
qualifications, and more — mesh-synced across the crew's devices with no central
server.**

Grapheion is built on [peat](https://github.com/defenseunicorns/peat)'s
offline-first mesh: a ship's administrative records — maintenance jobs and their
chain of custody, casualty reports, the watchbill and qualifications, the org
chart — sync peer-to-peer across the crew's devices (handhelds + always-on
anchors) with no central server, and converge automatically as devices move
between spaces and drop in and out of range. It meshes over **Wi-Fi/LAN**, the
**n0 relay** (for off-ship reachback), **and Bluetooth LE** — so two handhelds
in a compartment with no network still converge.

## What it does today

### Navigation & layout
- **Responsive** — on wide screens (macOS / tablet) a **vertical feature rail**
  down the left edge with the content beside it; on phones (iOS / Android) a
  **feature menu** that opens each feature **full-screen** (back returns to the
  menu). Content switches on tap — no horizontal swiping.
- **Features**: **CSMP** (corrective), **SKED** (preventive + schedule),
  **CASREP**, **Watchbills** (watch organization + PQS), **Duty Section**
  (in-port duty + the watchbill approval chain), **Supply** (part requisitions),
  **Connection** (the mesh), plus "coming soon" stubs for **Training, Muster**.

### Roles & visibility
- Each device logs in as one role: Technician, Work Center Supervisor (WCS),
  Leading Petty Officer (LPO), Division Officer (DIVO), 3-M Coordinator,
  **Department Head (DH — universal for CHENG / WEPS / OPS / CSO / SUPPO)**, or
  (off-ship) Port Engineer. Logout / role switch is in the app bar.
- **Org-scoped visibility** — Tech & WCS see their **work center**, LPO & DIVO
  their **division**, DH their **department**, the 3-M Coordinator the whole
  **ship**, and the Port Engineer only **TA'd** jobs.

### CSMP — corrective maintenance (the job approval chain)
- A technician originates a job; it climbs the on-ship ladder **WCS → LPO →
  DIVO** (Approve advances, Return kicks it back with a comment). **The ladder
  starts at the rung above the submitter** — an LPO's job goes straight to the
  DIVO; a DIVO's needs no approval and goes straight to execution.
- **TA (Technical Assistance)** — only the **DIVO** can request off-ship
  assistance, which connects the **Port Engineer**; the PE engages or declines.
  This is the only way the PE enters a job.
- **Execution + close-out** — after DIVO approval the work center works it and
  marks it complete, then it climbs the close-out ladder **WCS → LPO → DIVO**
  before it's **Closed**.
- Four sub-tabs: **INBOX** (your action) · **PENDING** (in routing) · **ACTIVE**
  (approved / in work) · **COMPLETED**. Job cards carry **inline action buttons**
  (Approve / Return / Engage / Start / Mark complete) for whoever can act — no
  need to open each job.
- **Chain of custody** — every action is recorded in an append-only audit log on
  each job, and the next approver gets a "your turn" notification. A job's detail
  also shows its **linked parts** (from Supply) with status + expected delivery.

### SKED — preventive maintenance (PMS) + the weekly schedule
- **PMS checks (MRCs)** under a **MIP** (Maintenance Index Page): each carries a
  MIP number, an **MRC code** (periodicity + sequence, e.g. `M-1`), equipment
  EIN, and estimated minutes — matching the real 3-M MIP→MRC numbering.
- **Periodicities** — D / W / 2W / M / Q / S / A, plus **R (situational, "as
  required")**. Calendar checks derive **scheduled / due / overdue** from their
  periodicity + last-done, so the schedule never goes stale.
- **Weekly board** — the current **Mon–Sun** week. Drag (click-drag on desktop,
  long-press-drag on touch) or tap to place **PMS checks and active jobs** onto
  specific days; an **Unscheduled** pool holds what's not yet placed.
- **Daily checks appear on every day** and are signed off **per day** — the dot
  reads 🟢 done · 🔴 missed · 🟠 upcoming for each day independently.
- **Checklist MRCs + signed completion** — an MRC carries its **procedure steps**
  (each with a standard); completing one walks the steps marking **SAT/UNSAT**
  with a reading, then **signs** it. The accomplishment is recorded per check +
  day, with the signer.
- **Discrepancy → corrective work** — marking a step **UNSAT** raises a
  **corrective CSMP job _and_ a linked Supply part request** in one flow, the
  request **pre-filled from the parts baked into the MRC** (the specific item +
  NSN — e.g. this bike's 12-speed chain, not a generic "chain").
- **WCS spot-check** — a supervisor reviews signed work in a **Spot checks**
  queue and **verifies** it or **kicks it back** with a reason (the performer
  and supervisor are notified).
- **PMS compliance %** — a live "in good standing ÷ total" pill on the SKED
  header (the standard maintenance KPI), with an overdue count.
- **Deferral** — defer a check (parts / ops / access) with a reason; it stops
  reading overdue until the deferral lapses.
- **Recurring auto-placement** — set a check to land on a chosen weekday every
  week so the board fills itself; **situational (R)** checks carry a
  **trigger/condition** ("when: pad < 1.5 mm").
- **Weekly board close-out** — at the start of each work week the **DIVO
  certifies the prior week's board** for their division: the sheet flags which
  scheduled checks slipped, the DIVO explains each and signs off, and the
  **DH** is notified and can read the certification + the incomplete reasons.
- **The WCS assigns** a work-center member to each task. A one-tap **Bicycle PMS
  example** — with real procedure steps and baked-in parts — seeds a relatable,
  self-demonstrating schedule (one MRC per periodicity + a situational one).

### CASREP
- A **CASREP**'s category is derived from job priority (pri 1 → CAT 4, severity-
  aligned); high-priority jobs prompt the DIVO to originate one. The classified
  DIVO → DH → XO → CO release chain is intentionally **deferred** for now.

### Watchbills & PQS (qualification tree)
- **PQS and the watchbill are one system**: PQS says who's *qualified*; the
  watchbill *assigns* qualified people — and **won't let you post someone who
  isn't qualified** for the station. That constraint is the point.
- **Qualification tree** — one model spans **watch stations** (POOW, OOD…),
  **knowledge** quals (3M, Damage Control…), **letters** (CDO, EOOW, TAO), and
  capstone **designations** (**SWO**). A designation sits atop a **prerequisite
  tree**; the PQS view shows a person's live progress (e.g. SWO `5/7 prereqs ·
  ready to board`) across stages *not started → in progress → board pending →
  qualified*, with a **qualifier** flag for sign-off authority. (Notably, **3M
  is a SWO prerequisite** — the maintenance side feeds the pin.)
- **In-port watchbill** — pick a day + watch period (Mid…Evening, incl. dog
  watches); a row per station shows who's posted, drawing only from PQS-qualified
  people. A one-tap seed loads the default in-port stations + the SWO quals.
- *Scaffolded, awaiting fidelity:* PQS **line-items** (100/200/300) and the
  **underway** bill are the next depth passes.

### Duty Section — in-port duty + the watchbill approval chain
- **Duty positions** are a second axis on top of a person's rank/role —
  **Section Leader**, **CDO**, or watchstander — and they grant section-level
  authority *additively* (a Section Leader who's also a divisional chief keeps
  their role's access and gains the section's).
- **Watchbill approval chain** — the Section Leader builds the section watchbill
  and **submits it to the CDO** (a two-tap confirm), who **approves** or
  **returns** it with a reason. Then, at the end of the duty day, the leader
  **finalizes** it (logging events that occurred — fire, AT/FP, casualty…) and
  the CDO approves again, which **records the watches** (everyone's watch counter
  ticks) and drops the day into a **History** tab. A status chip shows the whole
  section where the bill is (draft / in routing / approved / finalized), and each
  transition notifies the right person.
- **Night-watch fairness** — auto-fill balances who's stood the mids from the
  signed watch history, not just head-count.

### Supply — part requisitions
- A worn part — often straight off a **PMS discrepancy** — becomes a requisition
  that routes for approval before it's ordered: a work center **requests** it →
  the **DIVO approves** (releases it to Supply) → **Supply orders** it (Supply's
  approval _is_ the order) → **Received** → **Issued** back to the work center.
  Either approver can **reject** with a reason.
- **Order authority** is **LPO-and-above inside the Supply department** — a
  supply tech or WCS can't order parts. Supply sees every request; a **DIVO sees
  their whole division's**; everyone else sees their own chain's. Each step
  notifies the right party.
- **Expected delivery + traceability** — when Supply orders, it sets an
  **expected-delivery date** shown on the request; and because each request links
  back to its **PMS check + corrective job**, opening the job shows its parts,
  their status, and when they're due.

### Demo feedback
- Anyone trying the demo can tap the **feedback** button in the app bar on any
  screen and send a quick note — captured with the feature they were on — which
  **syncs over the mesh (including the relay)**, so it reaches the demo owner
  even when the phone is on cellular. Lets you gather impressions live while
  people tap through the app.

### Mesh / Connection
- **QR-gated join** — the DIVO hosts the mesh: it mints a formation key carried
  in a join QR. Everyone else scans that QR once to join (key + host remembered,
  so it's a one-time join). No key = no mesh.
- **Connection tab** — shows every other node, how it's connected
  (Wi-Fi / relay / BLE), and whether it's online (presence in the last 30s) or
  how long since last seen.
- **Dual transport** — syncs over Iroh/QUIC (Wi-Fi/mDNS + relay) **and Bluetooth
  LE** in parallel, so handhelds in a space with no Wi-Fi still converge over BLE.
- **Mesh security** — the formation key gates membership on *both* transports.
  Over Iroh it's peat's formation handshake; over BLE every frame is sealed with
  **AES-256-GCM** under that key (encrypted **and** authenticated), so only
  same-mesh nodes can read or inject frames. (FIPS-approved primitive.)

## Architecture

Grapheion is a Flutter app that depends on the `peat_flutter` package (the mesh
binding over the `peat-ffi` native library). It does not run its own server —
the device mesh *is* the backend. Everything syncs as peat documents: **jobs**,
the **audit log**, **accounts**, the **org chart** (departments / divisions /
work centers), **CASREPs**, **PMS checks (with steps + parts) + signed
accomplishments + weekly board close-outs**, **supply requests**,
**qualifications + PQS progress**, the **watchbill + its approval routing +
duty-day events**, and **presence** — over **two transports in parallel**:

- **Iroh/QUIC** — Wi-Fi/mDNS on the LAN, plus the n0 relay for the off-ship Port
  Engineer. Key-gated by peat's formation handshake.
- **Bluetooth LE** — a CRDT-over-BLE `0xAF`-frame bridge (peat's node-layer sync
  is Iroh-only, so BLE rides alongside it). Each frame body is AES-256-GCM
  sealed under the formation key. iOS/macOS only.

Because every change is a CRDT document, the two transports converge harmlessly
— a job edited over BLE and the same job synced over Wi-Fi merge to the same
state.

Synced state and the inbound-apply / visibility / notification logic live in a
pure, node-free **`MeshStore`** (`lib/mesh_store.dart`); the widget reads it
through thin getters and delegates to it. That keeps the logic unit-testable: a
host-run **`flutter test`** suite (~152 tests, sub-second — the job lifecycle +
rung-skipping ladder, role-scoped visibility, CASREP categories, the PMS
periodicity/MIP-MRC/schedule model, MRC steps + parts + signed accomplishments +
spot-check + compliance, the weekly board close-out, the duty-position axis +
watchbill approval chain, the supply requisition chain, last-write-wins sync
guards, serialization, and a UI smoke test) is the regression net. Run it before
changes.

Repo layout this project expects (siblings under one parent):

```
code/
  peat/          # the Rust workspace (peat-ffi, peat-mesh, …)
  peat-flutter/  # the Flutter package + native build scripts
  grapheion/     # this app
```

## Run it on macOS

grapheion path-depends on the sibling `peat-flutter` package (tracking upstream
`main`), which links a native Rust library — its `rust/` wrapper builds the
**published `peat-ffi` crate** into `libpeat_ffi.dylib` / `PeatFFI.xcframework`.
So a bare clone won't build until the sibling is in place and that native lib is
built. **The fastest path is the bootstrap script** (it clones the siblings,
installs prerequisites, builds the native libraries, and fetches deps):

```sh
./scripts/bootstrap-macos.sh
flutter run -d macos
```

For the manual steps, prerequisites, and troubleshooting, see **[SETUP.md](SETUP.md)**.

**Use it.** On first launch, sign in with a name, work center, and a role:
- Log in as **DIVO** on one instance → open the **Connection** feature → it shows
  the **join QR** and a **Copy join code** button.
- On a second instance/device → **Connection → Scan join QR** (same network), or
  on the start screen **Enter a join code** to join from anywhere over the relay.
- Originate a job as a technician in **CSMP** and walk it up the chain (use the
  logout icon to switch roles on one machine). Try **SKED → Load example:
  Bicycle PMS**, then drag a check onto a day.

> Tip: to drive the whole flow on a single Mac, run a second instance in another
> terminal with `flutter run -d macos` and log it in as a different role, or use
> the in-app role switch.

## Running on a phone (iOS & Android)

The app also runs on **iPhone** and **Android** — on phones the UI switches to
the full-screen feature-menu layout automatically.

- **iOS** — build the iOS framework with `bash ios/build-rust.sh` from
  `peat-flutter`, then `flutter run -d <device>`. BLE is supported on iOS.
- **Android** — build the Android libraries with `bash android/build-rust.sh`
  from `peat-flutter`, then `flutter run -d <device>`. Android meshes over
  **Iroh/Wi-Fi + relay** (the BLE bridge is iOS/macOS only). Cable-free deploys
  work over **wireless adb**: `adb tcpip 5555 && adb connect <phone-ip>:5555`,
  then `flutter run -d <phone-ip>:5555`. (If the debug session drops at attach,
  the APK still installs and the app runs standalone.)

To test **Bluetooth-only** sync (iOS/macOS): join both devices (scan the DIVO's
QR), turn **Wi-Fi off on both**, keep them in BLE range, and a job created on one
appears on the other over Bluetooth.

## Status

Proof-of-concept, running on **macOS, iOS, and Android**. Working: the full
corrective-maintenance (CSMP) job lifecycle with a rung-skipping approval ladder,
preventive PMS (SKED) with the drag-and-drop weekly schedule, **checklist MRCs +
parts + signed completion + WCS spot-check + compliance % + deferral +
auto-placement + the weekly board close-out (DIVO → DH)**, **PMS-discrepancy →
corrective job + a part requisition pre-filled from the MRC**, the **Supply
requisition chain** (DIVO → Supply, LPO-and-above gated, with expected-delivery
dates), the **Duty Section watchbill approval chain** (Section Leader → CDO, with
finalize/record + history), CASREP-from-priority, the in-port watchbill + PQS
qualification tree (incl. SWO prerequisites), in-app demo feedback over the mesh,
org-scoped visibility, QR-gated join, role switching, notifications, a dual Iroh +
BLE transport (BLE AES-256-GCM encrypted, both transports formation-key gated),
and an ~152-test host-run regression suite.

Not done / not for operational use:

- **Role authority is modeled but not enforced** — the audit log records who did
  what, and the approval/order gates are checked, but the UI is still largely
  cooperative (it doesn't hard-stop every wrong-role action).
- **PQS line-items (100/200/300) and the underway bill** are scaffolded but not
  yet built (awaiting the real SWO PQS structure).
- **Training, Muster** are navigation stubs ("coming soon").
- The CASREP **release chain** (DIVO → DH → XO → CO) is deferred (it crosses into
  classified territory); CASREP is wired to jobs only for now.
- The off-ship Port Engineer is reached over the **relay**, but the QR join
  itself is same-LAN today (cross-network PE onboarding is a follow-up).
- BLE confidentiality is in place; broader hardening (RMF/ATO posture, key
  rotation, upstream integration with the authoritative 3-M databases) is out of
  scope for the prototype.
