/**
 * Adding dark theme option
 */

//
//  BraintreePlugin.m
//
//  Copyright (c) 2016 Justin Unterreiner. All rights reserved.
//

#import "BraintreePlugin.h"
#import <objc/runtime.h>
#import <BraintreeDropIn/BraintreeDropIn.h>
#import <BraintreeDropIn/BTDropInController.h>
#import <Braintree/BTAPIClient.h>
#import <Braintree/BTPaymentMethodNonce.h>
#import <Braintree/BTCardNonce.h>
#import <Braintree/BraintreePayPal.h>
#import <Braintree/BraintreeApplePay.h>
#import <Braintree/BraintreeThreeDSecure.h>
#import <Braintree/BraintreeVenmo.h>
#import "AppDelegate.h"
#import <Braintree/BraintreeDataCollector.h>
#import <Braintree/BraintreePaymentFlow.h>

@interface BraintreePlugin() <PKPaymentAuthorizationViewControllerDelegate>

@property (nonatomic, strong) BTAPIClient *braintreeClient;
@property (nonatomic, strong) BTDataCollector *dataCollector;
@property (nonatomic, strong) NSString * _Nonnull deviceDataCollector;
@property (nonatomic, strong, readwrite) BTPaymentFlowDriver *paymentFlowDriver;
@property NSString* token;
@property BOOL darkTheme;

@end

@implementation AppDelegate(BraintreePlugin)

- (BOOL)application:(UIApplication *)application
            openURL:(NSURL *)url
            options:(NSDictionary<UIApplicationOpenURLOptionsKey,id> *)options {
    NSString *bundle_id = [NSBundle mainBundle].bundleIdentifier;
    bundle_id = [bundle_id stringByAppendingString:@"braintree.payments"];

    if ([url.scheme localizedCaseInsensitiveCompare:bundle_id] == NSOrderedSame) {
        return [BTAppContextSwitcher handleOpenURL:url];
    }

    // all plugins will get the notification, and their handlers will be called
    [[NSNotificationCenter defaultCenter] postNotification:[NSNotification notificationWithName:CDVPluginHandleOpenURLNotification object:url]];

    return NO;
}

@end

@implementation BraintreePlugin

NSString *dropInUIcallbackId;
bool applePaySuccess;
bool applePayInited = NO;
NSString *applePayMerchantID;
NSString *currencyCode;
NSString *countryCode;

#pragma mark - Cordova commands

- (void)initialize:(CDVInvokedUrlCommand *)command {

    // Ensure we have the correct number of arguments.
    if ([command.arguments count] < 1) {
        CDVPluginResult *res = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"A token is required."];
        [self.commandDelegate sendPluginResult:res callbackId:command.callbackId];
        return;
    }

    // Obtain the arguments.
    self.token = [command.arguments objectAtIndex:0];

    if (!self.token) {
        CDVPluginResult *res = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"A token is required."];
        [self.commandDelegate sendPluginResult:res callbackId:command.callbackId];
        return;
    }

    self.darkTheme = [[command argumentAtIndex:1 withDefault:@(NO)] boolValue];
    self.braintreeClient = [[BTAPIClient alloc] initWithAuthorization:self.token];

    if (!self.braintreeClient) {
        CDVPluginResult *res = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"The Braintree client failed to initialize."];
        [self.commandDelegate sendPluginResult:res callbackId:command.callbackId];
        return;
    }

    self.dataCollector = [[BTDataCollector alloc] initWithAPIClient:self.braintreeClient];
    [self.dataCollector collectDeviceData:^(NSString * _Nonnull deviceDataCollector) {
        // Save deviceData
        self.deviceDataCollector = deviceDataCollector;
    }];
    NSString *bundle_id = [NSBundle mainBundle].bundleIdentifier;
    bundle_id = [bundle_id stringByAppendingString:@"braintree.payments"];

    [BTAppContextSwitcher setReturnURLScheme:bundle_id];

    CDVPluginResult *res = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    [self.commandDelegate sendPluginResult:res callbackId:command.callbackId];
}

- (void)setupApplePay:(CDVInvokedUrlCommand *)command {

    // Ensure the client has been initialized.
    if (!self.braintreeClient) {
        CDVPluginResult *res = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"The Braintree client must first be initialized via BraintreePlugin.initialize(token)"];
        [self.commandDelegate sendPluginResult:res callbackId:command.callbackId];
        return;
    }

    if ([command.arguments count] != 3) {
        CDVPluginResult *res = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Merchant id, Currency code and Country code are required."];
        [self.commandDelegate sendPluginResult:res callbackId:command.callbackId];
        return;
    }

    if ((PKPaymentAuthorizationViewController.canMakePayments) && ([PKPaymentAuthorizationViewController canMakePaymentsUsingNetworks:@[PKPaymentNetworkVisa, PKPaymentNetworkMasterCard, PKPaymentNetworkAmex, PKPaymentNetworkDiscover]])) {
        applePayMerchantID = [command.arguments objectAtIndex:0];
        currencyCode = [command.arguments objectAtIndex:1];
        countryCode = [command.arguments objectAtIndex:2];

        applePayInited = YES;

        CDVPluginResult *res = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
        [self.commandDelegate sendPluginResult:res callbackId:command.callbackId];
    } else {
        CDVPluginResult *res = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"ApplePay cannot be used."];
        [self.commandDelegate sendPluginResult:res callbackId:command.callbackId];
    }
}

- (void)presentDropInPaymentUI:(CDVInvokedUrlCommand *)command {

    // Ensure the client has been initialized.
    if (!self.braintreeClient) {
        CDVPluginResult *res = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"The Braintree client must first be initialized via BraintreePlugin.initialize(token)"];
        [self.commandDelegate sendPluginResult:res callbackId:command.callbackId];
        return;
    }

    // Ensure we have the correct number of arguments.
    if ([command.arguments count] < 1) {
        CDVPluginResult *res = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"amount required."];
        [self.commandDelegate sendPluginResult:res callbackId:command.callbackId];
        return;
    }

    // Obtain the arguments.

    NSString* amount = (NSString *)[command.arguments objectAtIndex:0];
    if ([amount isKindOfClass:[NSNumber class]]) {
        amount = [(NSNumber *)amount stringValue];
    }
    if (!amount) {
        CDVPluginResult *res = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"amount is required."];
        [self.commandDelegate sendPluginResult:res callbackId:command.callbackId];
        return;
    }

    NSString* primaryDescription = [command.arguments objectAtIndex:1];
    NSDictionary* threeDSecureOptions = [[NSDictionary alloc]init];
    threeDSecureOptions = [command argumentAtIndex:2];


    if (!threeDSecureOptions) {
        CDVPluginResult *res = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"threeDSecure are required."];
        [self.commandDelegate sendPluginResult:res callbackId:command.callbackId];
        return;
    }

    NSNumber* threeDSecureAmount = threeDSecureOptions[@"amount"];
    if (!threeDSecureAmount) {
        CDVPluginResult *res = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString: @"You must provide an amount for 3D Secure"];
        [self.commandDelegate sendPluginResult:res callbackId:command.callbackId];
        return;
    }

    NSString* threeDSecureEmail = threeDSecureOptions[@"email"];
    if (!threeDSecureEmail) {
        CDVPluginResult *res = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString: @"You must provide an email for 3D Secure"];
        [self.commandDelegate sendPluginResult:res callbackId:command.callbackId];
        return;
    }


    // Save off the Cordova callback ID so it can be used in the completion handlers.
    dropInUIcallbackId = command.callbackId;


    /* Drop-IN 9.x */
    BTDropInRequest *paymentRequest = [[BTDropInRequest alloc] init];
    paymentRequest.applePayDisabled = !applePayInited;
    paymentRequest.vaultManager = YES;

    BTThreeDSecureRequest *threeDSecureRequest = [[BTThreeDSecureRequest alloc] init];
    threeDSecureRequest.amount = [NSDecimalNumber decimalNumberWithString:amount];
    threeDSecureRequest.email = threeDSecureEmail;
    threeDSecureRequest.versionRequested = BTThreeDSecureVersion2;
    paymentRequest.threeDSecureRequest = threeDSecureRequest;

    BTDropInController *dropIn = [[BTDropInController alloc] initWithAuthorization:self.token request:paymentRequest handler:^(BTDropInController * _Nonnull controller, BTDropInResult * _Nullable result, NSError * _Nullable error) {
        [self.viewController dismissViewControllerAnimated:YES completion:nil];
        if (error != nil) {
            NSLog(@"ERROR: %@", [error localizedDescription]);
            CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:[error localizedDescription]];

            [self.commandDelegate sendPluginResult:pluginResult callbackId:dropInUIcallbackId];
            dropInUIcallbackId = nil;
        } else if (result.isCanceled) {
            if (dropInUIcallbackId) {

                NSDictionary *dictionary = @{ @"userCancelled": @YES };

                CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK
                                                              messageAsDictionary:dictionary];

                [self.commandDelegate sendPluginResult:pluginResult callbackId:dropInUIcallbackId];
                dropInUIcallbackId = nil;
            }
        } else {
            if (dropInUIcallbackId) {
                if (result.paymentMethodType == BTDropInPaymentMethodTypeApplePay ) {
                    PKPaymentRequest *apPaymentRequest = [[PKPaymentRequest alloc] init];
                    apPaymentRequest.paymentSummaryItems = @[
                                                             [PKPaymentSummaryItem summaryItemWithLabel:primaryDescription amount:[NSDecimalNumber decimalNumberWithString: amount]]
                                                             ];
                    apPaymentRequest.supportedNetworks = @[PKPaymentNetworkVisa, PKPaymentNetworkMasterCard, PKPaymentNetworkAmex, PKPaymentNetworkDiscover];
                    apPaymentRequest.merchantCapabilities = PKMerchantCapability3DS;
                    apPaymentRequest.currencyCode = currencyCode;
                    apPaymentRequest.countryCode = countryCode;

                    apPaymentRequest.merchantIdentifier = applePayMerchantID;

                    if ((PKPaymentAuthorizationViewController.canMakePayments) && ([PKPaymentAuthorizationViewController canMakePaymentsUsingNetworks:apPaymentRequest.supportedNetworks])) {
                        PKPaymentAuthorizationViewController *viewController = [[PKPaymentAuthorizationViewController alloc] initWithPaymentRequest:apPaymentRequest];
                        viewController.delegate = self;

                        applePaySuccess = NO;

                        /* display ApplePay ont the rootViewController */
                        UIViewController *rootViewController = [[[UIApplication sharedApplication] keyWindow] rootViewController];

                        [rootViewController presentViewController:viewController animated:YES completion:nil];
                    } else {
                        CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"ApplePay cannot be used."];

                        [self.commandDelegate sendPluginResult:pluginResult callbackId:dropInUIcallbackId];
                        dropInUIcallbackId = nil;
                    }
                } else {
                    if (threeDSecureOptions && [result.paymentMethod isKindOfClass:[BTCardNonce class]]) {
                        BTCardNonce *cardNonce = (BTCardNonce *)result.paymentMethod;
                        if (!cardNonce.threeDSecureInfo.liabilityShiftPossible && cardNonce.threeDSecureInfo.wasVerified) {
                            CDVPluginResult *res = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString: @"3D Secure liability cannot be shifted"];
                            [self.commandDelegate sendPluginResult:res callbackId:command.callbackId];
                            return;
                        } else if (!cardNonce.threeDSecureInfo.liabilityShifted && cardNonce.threeDSecureInfo.wasVerified) {
                            CDVPluginResult *res = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString: @"3D Secure liability was not shifted"];
                            [self.commandDelegate sendPluginResult:res callbackId:command.callbackId];
                            return;
                        }
                    }

                    NSDictionary *dictionary = [self getPaymentUINonceResult:result.paymentMethod];

                    CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:dictionary];

                    [self.commandDelegate sendPluginResult:pluginResult callbackId:dropInUIcallbackId];
                    dropInUIcallbackId = nil;
                }
            }
        }
    }];

    if (self.darkTheme) {
        paymentRequest.uiCustomization = [[BTDropInUICustomization alloc] initWithColorScheme:BTDropInColorSchemeDark];
    } else {
        paymentRequest.uiCustomization = [[BTDropInUICustomization alloc] initWithColorScheme:BTDropInColorSchemeLight];
    }

    [self.viewController presentViewController:dropIn animated:YES completion:nil];
}

#pragma mark - PKPaymentAuthorizationViewControllerDelegate
- (void)paymentAuthorizationViewController:(PKPaymentAuthorizationViewController *)controller didAuthorizePayment:(PKPayment *)payment handler:(void (^)(PKPaymentAuthorizationResult *result))completion {
    applePaySuccess = YES;

    BTApplePayClient *applePayClient = [[BTApplePayClient alloc] initWithAPIClient:self.braintreeClient];
    [applePayClient tokenizeApplePayPayment:payment completion:^(BTApplePayCardNonce *tokenizedApplePayPayment, NSError *error) {
        if (tokenizedApplePayPayment) {
            // On success, send nonce to your server for processing.
            NSDictionary *dictionary = [self getPaymentUINonceResult:tokenizedApplePayPayment];

            CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK
                                                          messageAsDictionary:dictionary];

            [self.commandDelegate sendPluginResult:pluginResult callbackId:dropInUIcallbackId];
            dropInUIcallbackId = nil;

            // Then indicate success or failure via the completion callback, e.g.
            completion([[PKPaymentAuthorizationResult alloc] initWithStatus:PKPaymentAuthorizationStatusSuccess errors:[[NSMutableArray alloc] init]]);
        } else {
            // Tokenization failed. Check `error` for the cause of the failure.
            CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Apple Pay tokenization failed"];

            [self.commandDelegate sendPluginResult:pluginResult callbackId:dropInUIcallbackId];
            dropInUIcallbackId = nil;

            // Indicate failure via the completion callback:
            completion([[PKPaymentAuthorizationResult alloc] initWithStatus:PKPaymentAuthorizationStatusFailure errors:[NSArray arrayWithObjects:error, nil]]);
        }
    }];
}

- (void)paymentAuthorizationViewControllerDidFinish:(PKPaymentAuthorizationViewController *)controller {
    UIViewController *rootViewController = [[[UIApplication sharedApplication] keyWindow] rootViewController];

    [rootViewController dismissViewControllerAnimated:YES completion:nil];

    /* if not success, fire cancel event */
    if (!applePaySuccess) {
        NSDictionary *dictionary = @{ @"userCancelled": @YES };

        CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK  messageAsDictionary:dictionary];

        [self.commandDelegate sendPluginResult:pluginResult callbackId:dropInUIcallbackId];
        dropInUIcallbackId = nil;
    }
}


#pragma mark - Helpers
/**
 * Helper used to return a dictionary of values from the given payment method nonce.
 * Handles several different types of nonces (eg for cards, Apple Pay, PayPal, etc).
 */
- (NSDictionary*)getPaymentUINonceResult:(BTPaymentMethodNonce *)paymentMethodNonce {

    BTCardNonce *cardNonce;
    BTPayPalAccountNonce *payPalAccountNonce;
    BTApplePayCardNonce *applePayCardNonce;
    BTVenmoAccountNonce *venmoAccountNonce;

    if ([paymentMethodNonce isKindOfClass:[BTCardNonce class]]) {
        cardNonce = (BTCardNonce*)paymentMethodNonce;
    }

    if ([paymentMethodNonce isKindOfClass:[BTPayPalAccountNonce class]]) {
        payPalAccountNonce = (BTPayPalAccountNonce*)paymentMethodNonce;
    }

    if ([paymentMethodNonce isKindOfClass:[BTApplePayCardNonce class]]) {
        applePayCardNonce = (BTApplePayCardNonce*)paymentMethodNonce;
    }

    if ([paymentMethodNonce isKindOfClass:[BTVenmoAccountNonce class]]) {
        venmoAccountNonce = (BTVenmoAccountNonce*)paymentMethodNonce;
    }

    NSDictionary *dictionary = @{ @"userCancelled": @NO,

                                  // Standard Fields
                                  @"nonce": (paymentMethodNonce.nonce == nil ? [NSNull null] : paymentMethodNonce.nonce),
                                  @"type": (paymentMethodNonce.type == nil ? [NSNull null] : paymentMethodNonce.type),
                                  @"localizedDescription": !!venmoAccountNonce ? @"venmo" : !!applePayCardNonce ? @"apple pay" : !!payPalAccountNonce ? @"paypal" : @"card",

                                  // BTCardNonce Fields
                                  @"card": !cardNonce ? [NSNull null] : @{
                                        @"lastTwo": (cardNonce.lastTwo == nil ? [NSNull null] : cardNonce.lastTwo),
                                        @"lastFour": (cardNonce.lastFour == nil ? [NSNull null] : cardNonce.lastFour),
                                        @"expirationMonth": (cardNonce.expirationMonth == nil ? [NSNull null] : cardNonce.expirationMonth),
                                        @"expirationYear": (cardNonce.expirationYear == nil ? [NSNull null] : cardNonce.expirationYear),
                                        @"cardholderName": (cardNonce.cardholderName == nil ? [NSNull null] : cardNonce.cardholderName),
                                        @"network": [self formatCardNetwork:cardNonce.cardNetwork],
                                        @"threeDSecureInfo": !cardNonce.threeDSecureInfo ? [NSNull null] : @{
                                            @"liabilityShifted": cardNonce.threeDSecureInfo.liabilityShifted ? @YES : @NO,
                                            @"liabilityShiftPossible": cardNonce.threeDSecureInfo.liabilityShiftPossible ? @YES : @NO,
                                            @"wasVerified": cardNonce.threeDSecureInfo.wasVerified ? @YES : @NO,
                                        }
                                  },

                                  // BTPayPalAccountNonce
                                  @"payPalAccount": !payPalAccountNonce ? [NSNull null] : @{
                                        @"email": (payPalAccountNonce.email == nil ? [NSNull null] : payPalAccountNonce.email),
                                        @"firstName": (payPalAccountNonce.firstName == nil ? [NSNull null] : payPalAccountNonce.firstName),
                                        @"lastName": (payPalAccountNonce.lastName == nil ? [NSNull null] : payPalAccountNonce.lastName),
                                        @"phone": (payPalAccountNonce.phone == nil ? [NSNull null] : payPalAccountNonce.phone),
                                        //@"billingAddress" //TODO
                                        //@"shippingAddress" //TODO
                                        @"clientMetadataId":  (payPalAccountNonce.clientMetadataID == nil ? [NSNull null] : payPalAccountNonce.clientMetadataID),
                                        @"payerId": (payPalAccountNonce.payerID == nil ? [NSNull null] : payPalAccountNonce.payerID),
                                  },

                                  // BTApplePayCardNonce
                                  @"applePayCard": !applePayCardNonce ? [NSNull null] : @{
                                      @"binData": !applePayCardNonce.binData ? [NSNull null] : @{
                                          @"debit": applePayCardNonce.binData.debit ? @YES : @NO,
                                          @"countryOfIssuance" : (applePayCardNonce.binData.countryOfIssuance == nil ? [NSNull null] : applePayCardNonce.binData.countryOfIssuance),
                                      },
                                  },

                                  // BTThreeDSecureCardNonce Fields
                                  @"deviceData": self.deviceDataCollector,
                                  // BTVenmoAccountNonce Fields
                                  @"venmoAccount": !venmoAccountNonce ? [NSNull null] : @{
                                      @"username": (venmoAccountNonce.username == nil ? [NSNull null] : venmoAccountNonce.username)
                                  }
                              };
    return dictionary;
}

/**
 * Helper used to provide a string value for the given BTCardNetwork enumeration value.
 */
- (NSString*)formatCardNetwork:(BTCardNetwork)cardNetwork {
    NSString *result = nil;

    // TODO: This method should probably return the same values as the Android plugin for consistency.

    switch (cardNetwork) {
        case BTCardNetworkUnknown:
            result = @"BTCardNetworkUnknown";
            break;
        case BTCardNetworkAMEX:
            result = @"BTCardNetworkAMEX";
            break;
        case BTCardNetworkDinersClub:
            result = @"BTCardNetworkDinersClub";
            break;
        case BTCardNetworkDiscover:
            result = @"BTCardNetworkDiscover";
            break;
        case BTCardNetworkMasterCard:
            result = @"BTCardNetworkMasterCard";
            break;
        case BTCardNetworkVisa:
            result = @"BTCardNetworkVisa";
            break;
        case BTCardNetworkJCB:
            result = @"BTCardNetworkJCB";
            break;
        case BTCardNetworkLaser:
            result = @"BTCardNetworkLaser";
            break;
        case BTCardNetworkMaestro:
            result = @"BTCardNetworkMaestro";
            break;
        case BTCardNetworkUnionPay:
            result = @"BTCardNetworkUnionPay";
            break;
        case BTCardNetworkSolo:
            result = @"BTCardNetworkSolo";
            break;
        case BTCardNetworkSwitch:
            result = @"BTCardNetworkSwitch";
            break;
        case BTCardNetworkUKMaestro:
            result = @"BTCardNetworkUKMaestro";
            break;
        default:
            result = nil;
    }

    return result;
}

@end
