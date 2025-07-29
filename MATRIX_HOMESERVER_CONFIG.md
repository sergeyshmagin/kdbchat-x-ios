# Matrix Homeserver Configuration for LiveKit Integration

## ⚠️ CRITICAL UPDATE: Sygnal Limitation Discovered

**IMPORTANT**: The `include_application_data` parameter referenced in previous documentation **DOES NOT EXIST** in any released version of Sygnal (as of 2025). The official Sygnal repository has been archived without implementing this feature.

## Available Solutions

### Solution 1: Sygnal default_payload Template (Recommended)

Use Sygnal's existing `default_payload` feature to inject LiveKit server information:

```yaml
# sygnal.yaml
apps:
  io.sergeyshmagin.kdbchat.voip:
    type: apns
    platform: ios
    cert: path/to/voip-cert.pem
    key: path/to/voip-key.pem
    topic: io.sergeyshmagin.kdbchat.voip
    sandbox: false
    default_payload:
      aps:
        alert: "{{notification.body}}"
        sound: "default"
        mutable-content: 1
      # Static LiveKit server info
      livekit_server_url: "wss://video.aibots.kz"
      # Dynamic fields require server-side webhook integration
    max_payload_size: 4096
```

**Limitation**: `default_payload` only supports static values and basic templating. Cannot access Matrix event `application_data`.

### Solution 2: Server-Side Webhook Middleware

Create a custom push service that intercepts Matrix events and generates LiveKit-enhanced payloads:

1. **Matrix Event Handler**:
   ```python
   # webhook_handler.py
   @app.route('/matrix/push', methods=['POST'])
   def handle_matrix_push():
       event = request.json
       if event['type'] == 'm.call.invite':
           # Extract application_data
           app_data = event['content'].get('application_data', {})
           # Generate LiveKit credentials
           livekit_token = generate_livekit_jwt(event)
           # Send enhanced push notification
           send_apns_with_livekit_data(app_data, livekit_token)
   ```

2. **Enhanced Push Payload**:
   ```json
   {
     "aps": {"alert": "Incoming call", "sound": "default"},
     "livekit_access_token": "generated_jwt_here",
     "livekit_server_url": "wss://video.aibots.kz",
     "event_id": "$matrix_event_id"
   }
   ```

### Solution 3: Fallback-Only Implementation (Current State)

Accept that auto-connect cannot work reliably and rely on fallback authentication:

```swift
// In LiveKitCallService.swift - current implementation
func answerCall(roomId: String, callId: String) async throws {
    // Try to get credentials from push (will likely fail)
    let credentials = await extractCredentialsFromPush()
    
    if let creds = credentials, isValidToken(creds.accessToken) {
        // Rare success case
        try await connectWithCredentials(creds)
    } else {
        // Standard fallback (expected path)
        try await connectWithStandardAuth(roomId: roomId)
    }
}
```

## Revised Task 4 Assessment

**Task 4: Auto-Connect to LiveKit** - **Status: NOT ACHIEVABLE** with current Sygnal

- ❌ Sygnal cannot pass `application_data` from Matrix events
- ❌ No released version supports `include_application_data`
- ✅ Fallback authentication works correctly
- ✅ Code is ready if server-side solution is implemented

## Recommendations

1. **Immediate**: Use Solution 3 (fallback-only) for production
2. **Medium-term**: Implement Solution 2 (webhook middleware) 
3. **Long-term**: Contribute to Sygnal or use community fork

## Updated Production Checklist

- [ ] Accept that auto-connect requires custom server implementation
- [ ] Verify fallback authentication flow works reliably
- [ ] Test call quality with standard LiveKit authentication
- [ ] Monitor call connection times (may be slightly longer without auto-connect)
- [ ] Document limitation for users/support team

## Testing

Current implementation can be tested but auto-connect will fail gracefully:

```swift
// This will fall back to standard auth
await LiveKitCallKitService.shared.testMatrixCallEventWithLiveKitData()
```

Expected result: Call connects successfully after user joins room manually.