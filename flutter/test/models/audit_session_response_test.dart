import 'package:flutter_test/flutter_test.dart';
import 'package:camellia_remote_app/models/model.dart';

void main() {
  test('accepts only canonical active v3 audit leases for the requested event', () {
    const capability = '123e4567-e89b-42d3-a456-426614174000';
    const eventId = '223e4567-e89b-42d3-a456-426614174000';
    expect(
      auditSessionCapabilityFromResponseBody(
        '{"response_schema_version":1,"version":3,"audit_session_id":"$capability","acknowledged_event_id":"$eventId","event_revision":3,"state":"active","state_revision":2,"heartbeat_revision":1,"lease_remaining_seconds":89}',
        expectedEventId: eventId,
      ),
      capability,
    );

    for (final body in <String>[
      '{"version":3,"audit_session_id":"$capability","acknowledged_event_id":"$eventId","event_revision":3,"state":"active","state_revision":2,"heartbeat_revision":1,"lease_remaining_seconds":89}',
      '{"version":2,"audit_session_id":"$capability","acknowledged_event_id":"$eventId","event_revision":3,"state":"active","state_revision":2,"heartbeat_revision":1,"lease_remaining_seconds":89}',
      '{"version":3,"audit_session_id":"$capability","acknowledged_event_id":"323e4567-e89b-42d3-a456-426614174000","event_revision":3,"state":"active","state_revision":2,"heartbeat_revision":1,"lease_remaining_seconds":89}',
      '{"version":3,"audit_session_id":"$capability","acknowledged_event_id":"$eventId","event_revision":3,"state":"closed","state_revision":3,"heartbeat_revision":1,"lease_remaining_seconds":0}',
      '{"version":3,"audit_session_id":"$capability","acknowledged_event_id":"$eventId","event_revision":3,"state":"active","state_revision":2,"heartbeat_revision":1,"lease_remaining_seconds":0}',
      '{"version":3,"audit_session_id":"00000000-0000-0000-0000-000000000000","acknowledged_event_id":"$eventId","event_revision":3,"state":"active","state_revision":2,"heartbeat_revision":1,"lease_remaining_seconds":89}',
      '{"error":"Connection is closed"}',
      'not-json',
    ]) {
      expect(
        auditSessionCapabilityFromResponseBody(body, expectedEventId: eventId),
        isEmpty,
      );
    }
  });
}
