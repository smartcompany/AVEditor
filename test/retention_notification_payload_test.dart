import 'package:aveditor/services/retention_notification_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('payload parsing', () {
    expect(RetentionNotificationService.projectIdFromPayload('draft:abc'), 'abc');
    expect(RetentionNotificationService.projectIdFromPayload('share:xyz'), 'xyz');
    expect(RetentionNotificationService.projectIdFromPayload('catalog'), isNull);
  });
}
