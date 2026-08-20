#import "VDTProcessConfiguration.h"
#import "VDTApplicationListSubcontrollerController.h"
#import "../VDTShared.h"
#import "ChoicyPreferences/CHPDaemonListController.h"

@implementation VDTProcessConfiguration

- (NSString *)validIdentifier{
    return [self configurationType] == VDTConfigTypeApp
        ? [[self specifier] propertyForKey:@"applicationIdentifier"]
        : [[self specifier] propertyForKey:@"daemonName"];
}

- (VDTConfigType)configurationType{
    return (VDTConfigType)[[[self specifier] propertyForKey:@"configurationType"] unsignedIntegerValue];
}

- (BOOL)shouldAskForConsent:(NSString *)process{
    return [@[@"xpcproxy", @"backboardd", @"SpringBoard", @"launchd", @"sshd"] containsObject:process];
}

- (void)presentConsentPromptForProcess:(NSString *)process block:(void (^)(void))understoodBlock{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"危险操作警告"
        message:[NSString stringWithFormat:@"%@ 是 iOS 关键进程。限速或终止它可能导致系统崩溃，确定继续吗？", process]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"我已了解风险" style:UIAlertActionStyleDestructive
        handler:^(__unused UIAlertAction *action) { understoodBlock(); }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel
        handler:^(__unused UIAlertAction *action) { [self reloadSpecifier:self->_enabledSpecifier animated:YES]; }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)updateFieldsForPolicy:(VDTViolationPolicy)policy{
    BOOL isTemporary = policy == VDTViolationPolicyMonitorAndTemporaryThrottle;
    [_intervalSpecifier setProperty:@(policy != VDTViolationPolicyThrottle) forKey:@"enabled"];
    [_throttleLimitSpecifier setProperty:@(isTemporary) forKey:@"enabled"];
    [_recoveryCPUSpecifier setProperty:@(isTemporary) forKey:@"enabled"];
    [_intervalSpecifier setProperty:(isTemporary ? @10 : @120) forKey:@"default"];
}

- (NSArray *)specifiers{
    if (!_specifiers){
        NSMutableArray *items = [NSMutableArray array];
        BOOL unavailable = [[self validIdentifier] isEqualToString:@"com.apple.Preferences"];

        PSSpecifier *monitorGroup = [PSSpecifier preferenceSpecifierNamed:@"进程 CPU 控制" target:nil
            set:nil get:nil detail:nil cell:PSGroupCell edit:nil];
        [monitorGroup setProperty:@"原版的“监控并终止”和“限速”保持不变；“监控并临时限速”只在系统 CPU Monitor 违规后临时采样。" forKey:@"footerText"];
        [items addObject:monitorGroup];

        _enabledSpecifier = [PSSpecifier preferenceSpecifierNamed:@"启用" target:self
            set:@selector(setProcessConfigValue:specifier:) get:@selector(readProcessConfigValue:)
            detail:nil cell:PSSwitchCell edit:nil];
        [_enabledSpecifier setProperty:@"enabled" forKey:@"key"];
        [_enabledSpecifier setProperty:@NO forKey:@"default"];
        [_enabledSpecifier setProperty:@(!unavailable) forKey:@"enabled"];
        [_enabledSpecifier setProperty:VEDETTE_IDENTIFIER forKey:@"defaults"];
        [_enabledSpecifier setProperty:PREFS_CHANGED_NN forKey:@"PostNotification"];
        [items addObject:_enabledSpecifier];

        PSSpecifier *policy = [PSSpecifier preferenceSpecifierNamed:@"违规处理模式" target:self
            set:@selector(setProcessConfigValue:specifier:) get:@selector(readProcessConfigValue:)
            detail:nil cell:PSSegmentCell edit:nil];
        [policy setValues:@[@(VDTViolationPolicyMonitorAndTerminate), @(VDTViolationPolicyThrottle),
            @(VDTViolationPolicyMonitorAndTemporaryThrottle)]
            titles:@[@"监控并终止", @"限速", @"监控并临时限速"]];
        [policy setProperty:@(VDTViolationPolicyMonitorAndTerminate) forKey:@"default"];
        [policy setProperty:@"violationPolicy" forKey:@"key"];
        [policy setProperty:VEDETTE_IDENTIFIER forKey:@"defaults"];
        [policy setProperty:PREFS_CHANGED_NN forKey:@"PostNotification"];
        [items addObject:policy];

        PSSpecifier *params = [PSSpecifier preferenceSpecifierNamed:@"参数" target:nil set:nil get:nil
            detail:nil cell:PSGroupCell edit:nil];
        [params setProperty:@"临时限速模式默认：触发 CPU 80%、检测时间 10 秒、限速 40%、恢复 CPU 30%。连续 3 秒低于恢复值或限速满 20 秒会解除，冷却 5 秒后恢复系统 Monitor。" forKey:@"footerText"];
        [items addObject:params];

        PSTextFieldSpecifier *percentage = [PSTextFieldSpecifier preferenceSpecifierNamed:@"CPU 百分比（%）" target:self
            set:@selector(setProcessConfigValue:specifier:) get:@selector(readProcessConfigValue:)
            detail:nil cell:PSEditTextCell edit:nil];
        [percentage setKeyboardType:UIKeyboardTypeNumberPad autoCaps:UITextAutocapitalizationTypeNone autoCorrection:UITextAutocorrectionTypeNo];
        [percentage setPlaceholder:@"80"];
        [percentage setProperty:@80 forKey:@"default"];
        [percentage setProperty:@"percentage" forKey:@"key"];
        [percentage setProperty:@(!unavailable) forKey:@"enabled"];
        [items addObject:percentage];

        _intervalSpecifier = [PSTextFieldSpecifier preferenceSpecifierNamed:@"检测时间（秒）" target:self
            set:@selector(setProcessConfigValue:specifier:) get:@selector(readProcessConfigValue:)
            detail:nil cell:PSEditTextCell edit:nil];
        [(PSTextFieldSpecifier *)_intervalSpecifier setKeyboardType:UIKeyboardTypeNumberPad autoCaps:UITextAutocapitalizationTypeNone autoCorrection:UITextAutocorrectionTypeNo];
        [_intervalSpecifier setProperty:@120 forKey:@"default"];
        [_intervalSpecifier setProperty:@"interval" forKey:@"key"];
        [items addObject:_intervalSpecifier];

        _throttleLimitSpecifier = [PSTextFieldSpecifier preferenceSpecifierNamed:@"临时限速上限（%）" target:self
            set:@selector(setProcessConfigValue:specifier:) get:@selector(readProcessConfigValue:)
            detail:nil cell:PSEditTextCell edit:nil];
        [(PSTextFieldSpecifier *)_throttleLimitSpecifier setKeyboardType:UIKeyboardTypeNumberPad autoCaps:UITextAutocapitalizationTypeNone autoCorrection:UITextAutocorrectionTypeNo];
        [_throttleLimitSpecifier setProperty:@40 forKey:@"default"];
        [_throttleLimitSpecifier setProperty:@"throttleLimit" forKey:@"key"];
        [items addObject:_throttleLimitSpecifier];

        _recoveryCPUSpecifier = [PSTextFieldSpecifier preferenceSpecifierNamed:@"恢复 CPU（%）" target:self
            set:@selector(setProcessConfigValue:specifier:) get:@selector(readProcessConfigValue:)
            detail:nil cell:PSEditTextCell edit:nil];
        [(PSTextFieldSpecifier *)_recoveryCPUSpecifier setKeyboardType:UIKeyboardTypeNumberPad autoCaps:UITextAutocapitalizationTypeNone autoCorrection:UITextAutocorrectionTypeNo];
        [_recoveryCPUSpecifier setProperty:@30 forKey:@"default"];
        [_recoveryCPUSpecifier setProperty:@"recoveryCPU" forKey:@"key"];
        [items addObject:_recoveryCPUSpecifier];

        for (PSSpecifier *specifier in items){
            if ([specifier propertyForKey:@"key"]){
                [specifier setProperty:VEDETTE_IDENTIFIER forKey:@"defaults"];
                [specifier setProperty:PREFS_CHANGED_NN forKey:@"PostNotification"];
            }
        }
        _specifiers = items;
    }
    VDTViolationPolicy current = (VDTViolationPolicy)[valueForProcessConfigKey([self validIdentifier],
        @"violationPolicy", @(VDTViolationPolicyMonitorAndTerminate), [self configurationType]) unsignedIntegerValue];
    [self updateFieldsForPolicy:current];
    self.navigationItem.title = [self validIdentifier];
    return _specifiers;
}

- (void)setProcessConfigValue:(id)value specifier:(PSSpecifier *)specifier{
    NSString *key = [specifier propertyForKey:@"key"];
    if (![@"enabled" isEqualToString:key]){
        NSInteger number = [value integerValue];
        if (([key isEqualToString:@"percentage"] || [key isEqualToString:@"throttleLimit"] || [key isEqualToString:@"recoveryCPU"]) &&
            (number < 1 || number > 100)){
            [self reloadSpecifier:specifier animated:YES];
            return;
        }
        if ([key isEqualToString:@"interval"] && number < 1){
            [self reloadSpecifier:specifier animated:YES];
            return;
        }
        if (![key isEqualToString:@"violationPolicy"]) value = @(number);
    }
    void (^save)(void) = ^{
        setValueForProcessConfigKey([self validIdentifier], key, value, [self configurationType]);
        UIViewController *parent = (UIViewController *)[self valueForKey:@"_parentController"];
        if ([self configurationType] == VDTConfigTypeApp){
            PSSpecifier *parentSpecifier = [(VDTApplicationListSubcontrollerController *)parent specifierForApplicationWithIdentifier:[self validIdentifier]];
            if (parentSpecifier) [(VDTApplicationListSubcontrollerController *)parent reloadSpecifier:parentSpecifier animated:NO];
        }else{
            [(CHPDaemonListController *)parent reloadValueOfSelectedSpecifier];
        }
    };
    if ([key isEqualToString:@"enabled"] && [value boolValue] && [self shouldAskForConsent:[self validIdentifier]]){
        [self presentConsentPromptForProcess:[self validIdentifier] block:save];
        return;
    }
    if ([key isEqualToString:@"violationPolicy"]){
        [self updateFieldsForPolicy:(VDTViolationPolicy)[value unsignedIntegerValue]];
        [self reloadSpecifier:_intervalSpecifier animated:YES];
        [self reloadSpecifier:_throttleLimitSpecifier animated:YES];
        [self reloadSpecifier:_recoveryCPUSpecifier animated:YES];
    }
    save();
}

- (id)readProcessConfigValue:(PSSpecifier *)specifier{
    NSString *key = [specifier propertyForKey:@"key"];
    id defaultValue = [specifier propertyForKey:@"default"];
    if ([key isEqualToString:@"interval"]){
        VDTViolationPolicy policy = (VDTViolationPolicy)[valueForProcessConfigKey([self validIdentifier],
            @"violationPolicy", @(VDTViolationPolicyMonitorAndTerminate), [self configurationType]) unsignedIntegerValue];
        defaultValue = policy == VDTViolationPolicyMonitorAndTemporaryThrottle ? @10 : @120;
    }
    return valueForProcessConfigKey([self validIdentifier], key, defaultValue, [self configurationType]);
}
@end
