# LiveKit Deployment Guide

## 🚀 Production Deployment

### Build Configuration

#### Enabling LiveKit (Production)
```bash
# Set build flag in Xcode
Build Settings -> Swift Compiler - Custom Flags -> Other Swift Flags
Add: -D LIVEKIT_ENABLED
```

#### Disabling LiveKit (Fallback to ElementCall)
```bash
# Remove the LIVEKIT_ENABLED flag to use ElementCall
# No additional configuration needed
```

### Environment Setup

#### 1. LiveKit Server Configuration
```swift
// In LiveKitAuthService.swift
private let authURL = "https://livekit-auth.aibots.kz/api/auth"
private let liveKitServerURL = "https://video.aibots.kz"
```

#### 2. Matrix Integration
```swift
// OpenID token integration is automatic through clientProxy
// No additional configuration needed
```

### Pre-deployment Checklist

#### ✅ Required Permissions (Info.plist)
```xml
<key>NSCameraUsageDescription</key>
<string>Приложение использует камеру для видеозвонков</string>
<key>NSMicrophoneUsageDescription</key>
<string>Приложение использует микрофон для звонков</string>
```

#### ✅ CallKit Configuration
```swift
// Automatically configured in LiveKitCallKitService
// No manual setup required
```

#### ✅ Push Notifications Setup
```swift
// VoIP push notifications configured in LiveKitCallKitService
// PKPushRegistry handles incoming calls
```

## 🧪 Testing Instructions

### 1. Build Verification
```bash
# Test LiveKit build
xcodebuild -scheme ElementX -configuration Debug build -destination "platform=iOS Simulator,name=iPhone 16 Pro" -skipPackagePluginValidation

# Test ElementCall fallback build  
# (Remove LIVEKIT_ENABLED flag and rebuild)
```

### 2. Functional Testing

#### Test Case 1: Basic Call Flow
1. Launch app with LIVEKIT_ENABLED
2. Navigate to a room
3. Start a call
4. Verify LiveKitCallScreen appears
5. Test basic controls (mute, video, hangup)

#### Test Case 2: CallKit Integration
1. Make outgoing call - verify CallKit UI
2. Test incoming call simulation
3. Verify audio routing (speaker/earpiece)
4. Test call termination through CallKit

#### Test Case 3: Permissions
1. Fresh app install
2. Verify camera permission request
3. Verify microphone permission request
4. Test permission denial handling

#### Test Case 4: Error Handling
1. Test network disconnection during call
2. Test authentication failures
3. Verify retry mechanisms work
4. Test fallback to mock tokens

### 3. Performance Testing

#### Memory Usage
```bash
# Monitor memory usage during calls
# Expected: 50%+ reduction vs ElementCall WebView
```

#### Call Quality
```bash
# Test on real devices
# Monitor CPU usage, battery drain
# Verify video/audio quality
```

## 🔄 Rollback Plan

### If Issues Occur in Production

#### Option 1: Disable LiveKit (Immediate)
1. Remove `LIVEKIT_ENABLED` build flag
2. Rebuild and deploy
3. App automatically falls back to ElementCall

#### Option 2: Gradual Rollout
```swift
// Add server-side feature flag
if serverFeatureFlags.liveKitEnabled {
    // Use LiveKit
} else {
    // Use ElementCall  
}
```

## 📊 Monitoring

### Key Metrics to Track

#### Success Metrics
- Call connection success rate
- Time to connect (should be faster than ElementCall)
- Memory usage (should be lower than ElementCall)
- User satisfaction with call quality

#### Error Metrics
- Authentication failures
- Connection timeouts
- CallKit integration errors
- Permission denial rates

### Logging
```swift
// LiveKit calls are automatically logged with MXLog
// Monitor logs for errors starting with "LiveKit"
// Key events: connection, authentication, calls
```

## 🛠 Troubleshooting

### Common Issues

#### 1. Build Errors
**Problem**: Cannot find 'LiveKitCallCoordinator' in scope
**Solution**: Ensure LIVEKIT_ENABLED flag is set correctly

#### 2. Call Connection Fails
**Problem**: Timeout connecting to LiveKit server
**Solution**: 
- Check network connectivity
- Verify auth server is reachable
- Test on real device (not simulator)

#### 3. CallKit Not Working
**Problem**: Incoming calls don't show CallKit UI
**Solution**:
- Verify VoIP push certificate configuration
- Check PKPushRegistry setup
- Test with VoIP push simulation

#### 4. Permission Issues
**Problem**: Camera/microphone not working
**Solution**:
- Verify Info.plist descriptions
- Test permission request flow
- Check iOS privacy settings

### Debug Commands
```bash
# Check build configuration
xcodebuild -showBuildSettings -scheme ElementX | grep LIVEKIT

# Test auth server connectivity
curl -I https://livekit-auth.aibots.kz/api/auth

# Monitor logs during call
tail -f ~/Library/Logs/ElementX/app.log | grep LiveKit
```

## 📋 Post-Deployment Tasks

### Week 1 - Monitoring
- [ ] Monitor crash reports for LiveKit-related crashes
- [ ] Track call success/failure rates
- [ ] Collect user feedback on call quality
- [ ] Monitor server resource usage

### Week 2-4 - Optimization
- [ ] Analyze performance metrics
- [ ] Optimize based on real usage patterns
- [ ] Fine-tune retry mechanisms if needed
- [ ] Consider removing ElementCall code if stable

### Future Enhancements
- [ ] Group video calls support
- [ ] Advanced screen sharing features
- [ ] Call recording functionality
- [ ] Enhanced PiP experience

## 🎯 Success Criteria

### Technical
- ✅ 99%+ call connection success rate
- ✅ <3 seconds average connection time
- ✅ <50% memory usage vs ElementCall
- ✅ Zero LiveKit-related crashes

### User Experience
- ✅ Positive user feedback on call quality
- ✅ Smooth CallKit integration
- ✅ Intuitive call controls
- ✅ Reliable incoming call handling

## 📞 Support Contacts

### Development Team
- Primary: [Your Name] - LiveKit integration lead
- Backup: [Team Lead] - Architecture review

### Infrastructure
- LiveKit Server: admin@aibots.kz
- Auth Service: admin@aibots.kz
- Matrix Server: [Matrix Admin]

---

**Document Version**: 1.0  
**Last Updated**: 16.07.2025  
**Status**: ✅ Ready for Production Deployment