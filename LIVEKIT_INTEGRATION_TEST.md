# LiveKit Integration Testing Guide

## Overview
This document provides a comprehensive testing strategy for the LiveKit call integration with automatic connection via VoIP push notifications.

## Prerequisites

### 1. Matrix Homeserver Configuration
- Ensure your Matrix homeserver includes `application_data` in push notifications
- Verify Sygnal configuration includes `include_application_data: true`
- See `MATRIX_HOMESERVER_CONFIG.md` for detailed setup

### 2. LiveKit Server Setup
- LiveKit server running at `wss://video.aibots.kz`
- Valid JWT token generation endpoint
- Room creation capability

## Testing Scenarios

### Test 1: Basic Call Message Rendering
**Expected Result**: Raw JSON events should be replaced with user-friendly messages

```swift
// Run in Xcode debugger or main app
// Look for timeline items showing:
// "📹 Видеовызов начат" instead of raw JSON
```

**Validation Steps:**
1. Send a test `m.call.invite` event to a room
2. Check chat timeline shows friendly message
3. Verify timestamp and sender name are displayed
4. Confirm different states (started, ended, missed, declined) show correct messages

### Test 2: Push Notification Message Format
**Expected Result**: Messages should show "Sender Name: Content"

**Test Commands:**
```bash
# Send test message via Matrix API
curl -X PUT "https://matrix.org/_matrix/client/r0/rooms/!room:domain/send/m.room.message/txn1" \
  -H "Authorization: Bearer ACCESS_TOKEN" \
  -d '{"msgtype":"m.text","body":"Test message"}'
```

**Expected Notification:**
```
Title: Room Name
Body: Sender Name: Test message
```

### Test 3: VoIP Call Notification Format
**Expected Result**: VoIP notifications should show "Входящий вызов от Display Name"

**Test Matrix Event:**
```json
{
  "type": "m.call.invite",
  "content": {
    "call_id": "test_call_123",
    "version": "1",
    "lifetime": 60000,
    "type": "video",
    "application_data": {
      "livekit_access_token": "eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.test",
      "livekit_server_url": "wss://video.aibots.kz",
      "livekit_room_url": "test_room"
    }
  }
}
```

**Expected CallKit Display:**
```
Caller: Display Name
Title: Входящий вызов от Display Name
Body: Коснитесь для ответа
```

### Test 4: Auto-Connect Flow (CRITICAL)
**The most important test - verifies seamless VoIP → LiveKit connection**

**Steps:**
1. **Initiate Test Call:**
   ```swift
   // In main app - call this method for testing
   await LiveKitCallKitService.shared.testMatrixCallEventWithLiveKitData()
   ```

2. **Verify NSE Processing:**
   - Check logs for `[NSE-PUSH-EXTRACT]` entries
   - Confirm credentials extraction: `Token: [PRESENT]`
   - Verify App Group storage: `Successfully stored test data`

3. **Verify CallKit Integration:**
   - CallKit should show incoming call
   - Check logs for `[CALLKIT-CREDENTIALS]` entries
   - Confirm credentials retrieval from payload

4. **Test Auto-Connect:**
   - Answer the CallKit call
   - Should see: `🎬 Using LiveKit credentials for auto-connect`
   - Should connect without manual room join
   - If fails, should see fallback: `🔄 Falling back to standard auth flow`

## Debug Commands

### View Current State
```swift
// In Xcode debugger or developer menu
print(LiveKitCallKitService.shared.getVoIPDiagnostics())
```

### Check App Group Data
```swift
// Verify stored credentials
if let appGroup = UserDefaults(suiteName: "group.io.kdbchat") {
    print("Stored VoIP events: \(appGroup.dictionaryRepresentation())")
}
```

### Test Credential Extraction
```swift
// Test credential parsing
let testPayload = [
    "application_data": [
        "livekit_access_token": "test_token",
        "livekit_server_url": "wss://test.server"
    ]
]
// Should extract credentials successfully
```

## Expected Log Patterns

### Successful Auto-Connect Flow
```
📞 LiveKit received incoming VoIP push notification
📞 Found application_data in payload: [credentials]
🎬 Found stored LiveKit credentials from VoIP push
🎬 Using LiveKit credentials for auto-connect
🔑 Server: wss://video.aibots.kz, Token: [PRESENT]
✅ Auto-connect with credentials successful
```

### Fallback Flow (When No Credentials)
```
⚠️ CRITICAL: No LiveKit credentials found!
⚠️ Check Matrix homeserver configuration
🔄 Using standard auth flow as fallback
```

## Common Issues & Solutions

### Issue 1: No Credentials Found
**Symptoms:** Logs show `[MISSING]` for access token
**Solution:** Check Matrix homeserver/Sygnal configuration

### Issue 2: Invalid JWT Token
**Symptoms:** Connection fails with auth error
**Solution:** Verify LiveKit JWT generation and expiration

### Issue 3: CallKit Not Triggered
**Symptoms:** No CallKit UI on VoIP push
**Solution:** Check VoIP certificate and push registration

### Issue 4: Manual Join Required
**Symptoms:** CallKit answers but doesn't auto-connect
**Solution:** Verify application_data in push payload

## Production Deployment Checklist

- [ ] Matrix homeserver includes application_data in push notifications
- [ ] Sygnal configured with `include_application_data: true`
- [ ] LiveKit server accessible and JWT generation working
- [ ] VoIP certificates valid and not expired
- [ ] App Group entitlement configured: `group.io.kdbchat`
- [ ] All test scenarios pass
- [ ] Fallback flows work when credentials unavailable
- [ ] Call message rendering shows friendly text instead of JSON
- [ ] Push notification formats correct for both messages and calls

## Performance Considerations

- App Group storage is cleaned after use to prevent memory bloat
- Credentials have 2-minute expiration to prevent stale data usage
- Multiple fallback mechanisms ensure calls work even if auto-connect fails
- Detailed logging for production debugging without compromising security