//
//  KYAAppController.m
//  KeepingYouAwake
//
//  Created by Marcel Dierkes on 17.10.14.
//  Copyright (c) 2014 Marcel Dierkes. All rights reserved.
//

#import "KYAAppController.h"
#import "KYADefines.h"
#import "KYALocalizedStrings.h"
#import "KYAStatusItemController.h"
#import "KYABatteryCapacityThreshold.h"
#import "KYAActivationDurationsMenuController.h"
#import "KYAActivationUserNotification.h"

// Deprecated!
#define KYA_MINUTES(m) (m * 60.0f)
#define KYA_HOURS(h) (h * 3600.0f)

@interface KYAAppController () <KYAStatusItemControllerDelegate, KYAActivationDurationsMenuControllerDelegate>
@property (nonatomic, readwrite) KYASleepWakeTimer *sleepWakeTimer;
@property (nonatomic, readwrite) KYAStatusItemController *statusItemController;
@property (nonatomic) KYAActivationDurationsMenuController *menuController;

// Battery Status
@property (nonatomic, getter=isBatteryOverrideEnabled) BOOL batteryOverrideEnabled;

// Menu
@property (weak, nonatomic) IBOutlet NSMenu *menu;
@property (weak, nonatomic) IBOutlet NSMenuItem *activationDurationsMenuItem;
@end

@implementation KYAAppController

#pragma mark - Life Cycle

- (instancetype)init
{
    self = [super init];
    if(self)
    {
        self.sleepWakeTimer = [KYASleepWakeTimer new];
        [self.sleepWakeTimer addObserver:self forKeyPath:@"scheduled" options:NSKeyValueObservingOptionNew context:NULL];

        self.statusItemController = [KYAStatusItemController new];
        self.statusItemController.delegate = self;
        
        [self configureUserNotificationCenter];

        // Check activate on launch state
        if([self shouldActivateOnLaunch])
        {
            [self activateTimer];
        }

        Auto center = NSNotificationCenter.defaultCenter;
        [center addObserver:self
                   selector:@selector(applicationWillFinishLaunching:)
                       name:NSApplicationWillFinishLaunchingNotification
                     object:nil];
        
        [self configureEventHandler];

        self.menuController = [KYAActivationDurationsMenuController new];
        self.menuController.delegate = self;
    }
    return self;
}

- (void)dealloc
{
    Auto center = NSNotificationCenter.defaultCenter;
    [center removeObserver:self name:NSApplicationDidFinishLaunchingNotification object:nil];
    [center removeObserver:self name:kKYABatteryCapacityThresholdDidChangeNotification object:nil];
}

- (void)awakeFromNib
{
    [super awakeFromNib];

    [self.menu setSubmenu:self.menuController.menu
                  forItem:self.activationDurationsMenuItem];
}

#pragma mark - State Handling

- (void)sleepWakeTimerWillActivate
{
    KYALog(@"Will activate: %@", self.sleepWakeTimer);
    
    Auto device = KYADevice.currentDevice;
    Auto center = NSNotificationCenter.defaultCenter;
    Auto defaults = NSUserDefaults.standardUserDefaults;
    
    // Check battery overrides and register for capacity changes.
    [self checkAndEnableBatteryOverride];
    
    [center addObserver:self
               selector:@selector(deviceParameterDidChange:)
                   name:KYADeviceParameterDidChangeNotification
                 object:device];
    
    if([defaults kya_isBatteryCapacityThresholdEnabled])
    {
        device.batteryMonitoringEnabled = YES;
    }
    if([defaults kya_isLowPowerModeMonitoringEnabled])
    {
        device.lowPowerModeMonitoringEnabled = YES;
    }
}

- (void)sleepWakeTimerDidDeactivate
{
    Auto device = KYADevice.currentDevice;
    Auto center = NSNotificationCenter.defaultCenter;
    
    [center removeObserver:self
                      name:KYADeviceParameterDidChangeNotification
                    object:device];
    
    device.batteryMonitoringEnabled = NO;
    device.lowPowerModeMonitoringEnabled = NO;
    
    KYALog(@"Did deactivate: %@", self.sleepWakeTimer);
}

#pragma mark - KVO

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if([object isEqual:self.sleepWakeTimer] && [keyPath isEqualToString:@"scheduled"])
    {
        AutoWeak weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            // Update the status item for scheduling changes
            BOOL active = [change[NSKeyValueChangeNewKey] boolValue];
            weakSelf.statusItemController.activeAppearanceEnabled = active;
        });
    }
}

#pragma mark - Default Time Interval

- (NSTimeInterval)defaultTimeInterval
{
    return NSUserDefaults.standardUserDefaults.kya_defaultTimeInterval;
}

#pragma mark - Activate on Launch

- (BOOL)shouldActivateOnLaunch
{
    return [NSUserDefaults.standardUserDefaults kya_isActivatedOnLaunch];
}

- (IBAction)toggleActivateOnLaunch:(id)sender
{
    Auto defaults = NSUserDefaults.standardUserDefaults;
    defaults.kya_activateOnLaunch = ![defaults kya_isActivatedOnLaunch];
    [defaults synchronize];
}

#pragma mark - User Notification Center

- (void)configureUserNotificationCenter
{
    if(@available(macOS 11.0, *))
    {
        Auto center = KYAUserNotificationCenter.sharedCenter;
        [center requestAuthorizationIfUndetermined];
        [center clearAllDeliveredNotifications];
    }
}

#pragma mark - Sleep Wake Timer Handling

- (void)activateTimer
{
    [self activateTimerWithTimeInterval:self.defaultTimeInterval];
}

- (void)activateTimerWithTimeInterval:(NSTimeInterval)timeInterval
{
    // Do not allow negative time intervals
    if(timeInterval < 0)
    {
        return;
    }

    Auto defaults = NSUserDefaults.standardUserDefaults;
    
    [self sleepWakeTimerWillActivate];

    Auto timerCompletion = ^(BOOL cancelled) {
        // Post deactivation notification
        if(@available(macOS 11.0, *))
        {
            Auto notification = [[KYAActivationUserNotification alloc] initWithFireDate:nil
                                                                             activating:NO];
            [KYAUserNotificationCenter.sharedCenter postNotification:notification];
        }

        // Quit on timer expiration
        if(cancelled == NO && [defaults kya_isQuitOnTimerExpirationEnabled])
        {
            [NSApplication.sharedApplication terminate:nil];
        }
        
        [self sleepWakeTimerDidDeactivate];
    };
    [self.sleepWakeTimer scheduleWithTimeInterval:timeInterval completion:timerCompletion];

    // Post activation notification
    if(@available(macOS 11.0, *))
    {
        Auto fireDate = self.sleepWakeTimer.fireDate;
        Auto notification = [[KYAActivationUserNotification alloc] initWithFireDate:fireDate
                                                                         activating:YES];
        [KYAUserNotificationCenter.sharedCenter postNotification:notification];
    }
}

- (void)terminateTimer
{
    [self disableBatteryOverride];

    if([self.sleepWakeTimer isScheduled])
    {
        [self.sleepWakeTimer invalidate];
    }
}

#pragma mark - Device Power Monitoring

- (void)checkAndEnableBatteryOverride
{
    Auto batteryMonitor = KYADevice.currentDevice.batteryMonitor;
    CGFloat currentCapacity = batteryMonitor.currentCapacity;
    CGFloat threshold = NSUserDefaults.standardUserDefaults.kya_batteryCapacityThreshold;

    self.batteryOverrideEnabled = (currentCapacity <= threshold);
}

- (void)disableBatteryOverride
{
    self.batteryOverrideEnabled = NO;
}

- (void)deviceParameterDidChange:(NSNotification *)notification
{
    NSParameterAssert(notification);
    
    Auto device = (KYADevice *)notification.object;
    Auto defaults = NSUserDefaults.standardUserDefaults;
    
    Auto userInfo = notification.userInfo;
    Auto deviceParameter = (KYADeviceParameter)userInfo[KYADeviceParameterKey];
    if([deviceParameter isEqualToString:KYADeviceParameterBattery])
    {
        if([defaults kya_isBatteryCapacityThresholdEnabled] == NO) { return; }
        
        CGFloat threshold = defaults.kya_batteryCapacityThreshold;
        Auto capacity = device.batteryMonitor.currentCapacity;
        if([self.sleepWakeTimer isScheduled] && (capacity <= threshold) && ![self isBatteryOverrideEnabled])
        {
            [self terminateTimer];
        }
    }
    else if([deviceParameter isEqualToString:KYADeviceParameterLowPowerMode])
    {
        if([defaults kya_isLowPowerModeMonitoringEnabled] == NO) { return; }
        
        if([device.lowPowerModeMonitor isLowPowerModeEnabled] && [self.sleepWakeTimer isScheduled])
        {
            [self terminateTimer];
        }
    }
}

#pragma mark - Battery Capacity Threshold Changes

- (void)batteryCapacityThresholdDidChange:(NSNotification *)notification
{
    Auto batteryMonitor = KYADevice.currentDevice.batteryMonitor;
    if([batteryMonitor hasBattery] == NO) { return; }

    [self terminateTimer];
}

#pragma mark - Apple Event Manager

- (void)applicationWillFinishLaunching:(NSNotification *)notification
{
    Auto eventManager = NSAppleEventManager.sharedAppleEventManager;
    [eventManager setEventHandler:self
                      andSelector:@selector(handleGetURLEvent:withReplyEvent:)
                    forEventClass:kInternetEventClass
                       andEventID:kAEGetURL];
}

- (void)handleGetURLEvent:(NSAppleEventDescriptor *)event withReplyEvent:(NSAppleEventDescriptor *)reply
{
    Auto parameter = [event paramDescriptorForKeyword:keyDirectObject].stringValue;
    [KYAEventHandler.defaultHandler handleEventForURL:[NSURL URLWithString:parameter]];
}

- (void)configureEventHandler
{
    AutoWeak weakSelf = self;
    [KYAEventHandler.defaultHandler registerActionNamed:@"activate"
                                                  block:^(KYAEvent *event) {
                                                      typeof(self) strongSelf = weakSelf;
                                                      [strongSelf handleActivateActionForEvent:event];
                                                  }];

    [KYAEventHandler.defaultHandler registerActionNamed:@"deactivate"
                                                  block:^(KYAEvent *event) {
                                                      [weakSelf terminateTimer];
                                                  }];

    [KYAEventHandler.defaultHandler registerActionNamed:@"toggle"
                                                  block:^(KYAEvent *event) {
                                                      [weakSelf.statusItemController toggle];
                                                  }];
}

- (void)handleActivateActionForEvent:(KYAEvent *)event
{
    Auto parameters = event.arguments;
    NSString *seconds = parameters[@"seconds"];
    NSString *minutes = parameters[@"minutes"];
    NSString *hours = parameters[@"hours"];

    [self terminateTimer];

    // Activate indefinitely if there are no parameters
    if(parameters.count == 0)
    {
        [self activateTimer];
    }
    else if(seconds)
    {
        [self activateTimerWithTimeInterval:(NSTimeInterval)ceil(seconds.doubleValue)];
    }
    else if(minutes)
    {
        [self activateTimerWithTimeInterval:(NSTimeInterval)KYA_MINUTES(ceil(minutes.doubleValue))];
    }
    else if(hours)
    {
        [self activateTimerWithTimeInterval:(NSTimeInterval)KYA_HOURS(ceil(hours.doubleValue))];
    }
}

#pragma mark - KYAStatusItemControllerDelegate

- (void)statusItemControllerShouldPerformMainAction:(KYAStatusItemController *)controller
{
    if([self.sleepWakeTimer isScheduled])
    {
        [self terminateTimer];
    }
    else
    {
        [self activateTimer];
    }
}

- (void)statusItemControllerShouldPerformAlternativeAction:(KYAStatusItemController *)controller
{
    [self.statusItemController showMenu:self.menu];
}

#pragma mark - KYAActivationDurationsMenuControllerDelegate

- (KYAActivationDuration *)currentActivationDuration
{
    Auto sleepWakeTimer = self.sleepWakeTimer;
    if(![sleepWakeTimer isScheduled])
    {
        return nil;
    }

    NSTimeInterval seconds = sleepWakeTimer.scheduledTimeInterval;
    return [[KYAActivationDuration alloc] initWithSeconds:seconds];
}

- (void)activationDurationsMenuController:(KYAActivationDurationsMenuController *)controller didSelectActivationDuration:(KYAActivationDuration *)activationDuration
{
    [self terminateTimer];

    AutoWeak weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSTimeInterval seconds = activationDuration.seconds;
        [weakSelf activateTimerWithTimeInterval:seconds];
    });
}

- (NSDate *)fireDateForMenuController:(KYAActivationDurationsMenuController *)controller
{
    return self.sleepWakeTimer.fireDate;
}

@end
