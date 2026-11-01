//==========================
// TẦNG 0: ÉP AOD ẨN LÊN ĐỜI THẤP
//==========================

%group Group_Aod_Setting

// 1. BacklightServices (Tầng kiểm tra phần cứng)
%hook BLSBacklight
+ (BOOL)isAlwaysOnEnabledByHardware { 
    return YES; 
}
%end

// 2. BacklightServicesHost (Tầng engine hiển thị AOD)
%hook BLSHAlwaysOnPresentationEngine
- (BOOL)isAlwaysOnSupported { 
    return YES; 
}
- (BOOL)isAlwaysOnActive { 
    return YES; 
}
%end

// 3. CoreBrightness / SpringBoard (Kiểm tra module màn hình)
%hook CBDisplayModule
- (BOOL)isAlwaysOnDisplaySupported { 
    return YES; 
}
%end

// 4. DisplayAndBrightnessSettings (Bundle Cài đặt hiển thị cell AOD)
%hook DBRDisplayController
- (BOOL)shouldShowAlwaysOnDisplaySpecifier { 
    return YES; 
}
- (BOOL)isAlwaysOnDisplaySupported { 
    return YES; 
}
%end

%end // Hết Group_Aod_Setting

%ctor {
    @autoreleasepool {
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        
        // Khởi tạo khi process là SpringBoard hoặc Settings
        if ([bundleID isEqualToString:@"com.apple.springboard"] || 
            [bundleID isEqualToString:@"com.apple.Preferences"]) {
            %init(Group_Aod_Setting);
        }
    }
}
