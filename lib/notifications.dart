// Copyright 2026 Defense Unicorns
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Thin wrapper over flutter_local_notifications for surfacing *remote* mesh
/// changes to the user.
///
/// The notability decision — which changes are worth a notification — lives in
/// the caller (it knows the domain). This class only renders. The substrate
/// (peat-ffi) tells us a change's [origin]; the app turns a remote change in a
/// watched collection into the notification below.
class PeatNotifications {
  PeatNotifications._();
  static final PeatNotifications instance = PeatNotifications._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _ready = false;
  int _id = 0;

  static const AndroidNotificationChannel _channel = AndroidNotificationChannel(
    'peat_mesh_changes',
    'Mesh updates',
    description: 'Updates synced from other nodes in the group',
    importance: Importance.defaultImportance,
  );

  /// Initialize the plugin, register the Android channel, and request
  /// permission. Idempotent; safe to await at startup.
  Future<void> init() async {
    if (_ready) return;
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const darwin = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: android,
        iOS: darwin,
        macOS: darwin,
      ),
    );
    final android13 = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (android13 != null) {
      await android13.createNotificationChannel(_channel);
      await android13.requestNotificationsPermission();
    }
    _ready = true;
  }

  /// Show a notification for a remote mesh change. No-op until [init] completes.
  /// [preview] is an optional short content summary; [peerId] the originating
  /// node (a short prefix is shown).
  Future<void> showRemoteChange({
    required String collection,
    String? preview,
    String? peerId,
  }) async {
    if (!_ready) return;
    final who =
        (peerId != null && peerId.length >= 6) ? peerId.substring(0, 6) : 'a peer';
    final title = 'Update in $collection';
    final body = (preview == null || preview.isEmpty)
        ? 'Synced from $who'
        : '$preview  ·  from $who';
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'peat_mesh_changes',
        'Mesh updates',
        channelDescription: 'Updates synced from other nodes in the group',
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
      ),
      iOS: DarwinNotificationDetails(),
      macOS: DarwinNotificationDetails(),
    );
    await _plugin.show(
      id: _id++,
      title: title,
      body: body,
      notificationDetails: details,
    );
  }
}
