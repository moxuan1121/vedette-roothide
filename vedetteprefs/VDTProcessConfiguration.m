//  Copyright (c) 2021 udevs
//
//  This file is subject to the terms and conditions defined in
//  file 'LICENSE', which is part of this source code package.

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

- (void)presentProtectionAlert{
    NSString *message = [NSString stringWithFormat:
        @"%@ 是受保护的关键进程。立即终止它可能导致 iOS 或 RootHide/Dopamine 环境异常，因此不能启用监控。",
        [self validIdentifier]];
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"已阻止危险操作"
        message:message
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (NSArray *)specifiers{
    if (!_specifiers){
        NSMutableArray *specifiers = [NSMutableArray array];
        NSString *identifier = [self validIdentifier];
        BOOL unavailable = [identifier isEqualToString:@"com.apple.Preferences"] ||
            VDTIsProtectedProcessIdentifier(identifier);

        PSSpecifier *group = [PSSpecifier
            preferenceSpecifierNamed:@"立即终止"
            target:nil set:nil get:nil detail:nil cell:PSGroupCell edit:nil];
        [group setProperty:
            @"新进程启动后有 1.5 秒宽限期。宽限期结束后，CPU 达到阈值一次即会在下一次检测时强制终止。检测周期可在 Vedette 主页面设置。100% 约等于占满一个 CPU 核。"
            forKey:@"footerText"];
        [specifiers addObject:group];

        PSSpecifier *enabled = [PSSpecifier
            preferenceSpecifierNamed:@"启用监控"
            target:self
            set:@selector(setProcessConfigValue:specifier:)
            get:@selector(readProcessConfigValue:)
            detail:nil cell:PSSwitchCell edit:nil];
        [enabled setProperty:@"enabled" forKey:@"key"];
        [enabled setProperty:@NO forKey:@"default"];
        [enabled setProperty:@(!unavailable) forKey:@"enabled"];
        [enabled setProperty:VEDETTE_IDENTIFIER forKey:@"defaults"];
        [enabled setProperty:PREFS_CHANGED_NN forKey:@"PostNotification"];
        [specifiers addObject:enabled];

        PSTextFieldSpecifier *percentage = [PSTextFieldSpecifier
            preferenceSpecifierNamed:@"CPU 阈值（%）"
            target:self
            set:@selector(setProcessConfigValue:specifier:)
            get:@selector(readProcessConfigValue:)
            detail:nil cell:PSEditTextCell edit:nil];
        [percentage setKeyboardType:UIKeyboardTypeNumberPad
                           autoCaps:UITextAutocapitalizationTypeNone
                     autoCorrection:UITextAutocorrectionTypeNo];
        [percentage setPlaceholder:@"80"];
        [percentage setProperty:@80 forKey:@"default"];
        [percentage setProperty:@"percentage" forKey:@"key"];
        [percentage setProperty:@(!unavailable) forKey:@"enabled"];
        [percentage setProperty:VEDETTE_IDENTIFIER forKey:@"defaults"];
        [percentage setProperty:PREFS_CHANGED_NN forKey:@"PostNotification"];
        [specifiers addObject:percentage];

        _specifiers = specifiers;
    }
    self.navigationItem.title = [self validIdentifier];
    return _specifiers;
}

- (void)setProcessConfigValue:(id)value specifier:(PSSpecifier *)specifier{
    NSString *key = [specifier propertyForKey:@"key"];
    if ([key isEqualToString:@"percentage"]){
        NSInteger percentage = [value integerValue];
        if (percentage < 1 || percentage > VDT_MAX_CPU_PERCENTAGE){
            UIAlertController *alert = [UIAlertController
                alertControllerWithTitle:@"阈值无效"
                message:@"请输入 1 到 800 之间的 CPU 百分比；100% 约等于占满一个 CPU 核。"
                preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleCancel handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
            [self reloadSpecifier:specifier animated:YES];
            return;
        }
        value = @(percentage);
    }

    if ([key isEqualToString:@"enabled"] && [value boolValue] &&
        VDTIsProtectedProcessIdentifier([self validIdentifier])){
        [self presentProtectionAlert];
        [self reloadSpecifier:specifier animated:YES];
        return;
    }

    setValueForProcessConfigKey([self validIdentifier], key, value, [self configurationType]);
    UIViewController *parent = (UIViewController *)[self valueForKey:@"_parentController"];
    if ([self configurationType] == VDTConfigTypeApp){
        PSSpecifier *parentSpecifier = [(VDTApplicationListSubcontrollerController *)parent
            specifierForApplicationWithIdentifier:[self validIdentifier]];
        if (parentSpecifier){
            [(VDTApplicationListSubcontrollerController *)parent reloadSpecifier:parentSpecifier animated:NO];
        }
    }else{
        [(CHPDaemonListController *)parent reloadValueOfSelectedSpecifier];
    }
}

- (id)readProcessConfigValue:(PSSpecifier *)specifier{
    return valueForProcessConfigKey(
        [self validIdentifier],
        [specifier propertyForKey:@"key"],
        [specifier propertyForKey:@"default"],
        [self configurationType]
    );
}

@end
