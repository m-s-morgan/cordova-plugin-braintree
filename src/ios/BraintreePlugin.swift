//
//  BraintreePlugin.swift
//
//  PayPal and Venmo through the Braintree iOS SDK (v7). Written in Swift because the v7 SDK's
//  app-context-switch routing (BTAppContextSwitcher) is not exposed to Objective-C.
//
//  The payer's return from the Venmo app (and from the PayPal app, when app switch is on) arrives
//  as a universal link. Under the cordova-ios 8 scene lifecycle CDVSceneDelegate hands those to
//  plugins through CDVPluginContinueUserActivityNotification, which this plugin observes; a custom
//  URL scheme return arrives through the standard handleOpenURL hook. Only URLs the SDK recognises
//  are consumed, so other plugins (universal links) keep theirs.
//

import Foundation
import UIKit
import Braintree

@objc(BraintreePlugin)
class BraintreePlugin: CDVPlugin {

    private var authorization: String?
    private var payPalClient: BTPayPalClient?
    private var venmoClient: BTVenmoClient?
    private var dataCollector: BTDataCollector?
    private var deviceData: String = ""
    private var busy = false

    // MARK: - Lifecycle

    override func pluginInitialize() {
        super.pluginInitialize()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onContinueUserActivity(_:)),
            name: NSNotification.Name("CDVPluginContinueUserActivityNotification"),
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // a custom-scheme return (scene:openURLContexts:)
    override func handleOpenURL(_ notification: Notification) {
        guard let url = notification.object as? URL else {
            return
        }

        BTAppContextSwitcher.sharedInstance.handleOpen(url)
    }

    // a universal-link return (scene:continueUserActivity:)
    @objc func onContinueUserActivity(_ notification: Notification) {
        guard let activity = notification.object as? NSUserActivity,
              activity.activityType == NSUserActivityTypeBrowsingWeb,
              let url = activity.webpageURL else {
            return
        }

        BTAppContextSwitcher.sharedInstance.handleOpen(url)
    }

    // MARK: - Commands

    @objc(initialize:)
    func initialize(_ command: CDVInvokedUrlCommand) {
        guard let token = command.arguments.first as? String, !token.isEmpty else {
            send(error: "A token is required.", for: command)
            return
        }

        guard let universalLink = universalLink() else {
            send(error: "BraintreeUniversalLink is missing from Info.plist.", for: command)
            return
        }

        authorization = token
        payPalClient = BTPayPalClient(authorization: token)
        venmoClient = BTVenmoClient(authorization: token, universalLink: universalLink)
        dataCollector = BTDataCollector(authorization: token)
        deviceData = ""

        dataCollector?.collectDeviceData { [weak self] data, _ in
            self?.deviceData = data ?? ""
        }

        send(ok: nil, for: command)
    }

    @objc(payPal:)
    func payPal(_ command: CDVInvokedUrlCommand) {
        guard let client = payPalClient else {
            send(error: "The Braintree client must first be initialized via BraintreePlugin.initialize(options)", for: command)
            return
        }

        guard !busy else {
            send(error: "A payment flow is already in progress.", for: command)
            return
        }

        let args = command.arguments ?? []
        let flow = string(args, 0) ?? "vault"
        let amount = string(args, 1)
        let currency = string(args, 2) ?? "USD"
        let description = string(args, 3)
        let email = string(args, 4)
        let offerCredit = bool(args, 5)

        busy = true

        let completion: (BTPayPalAccountNonce?, Error?) -> Void = { [weak self] nonce, error in
            guard let self = self else {
                return
            }

            self.busy = false

            if let error = error {
                let ns = error as NSError

                if ns.domain == BTPayPalError.errorDomain && ns.code == BTPayPalError.canceled.errorCode {
                    self.send(ok: ["userCancelled": true], for: command)
                } else {
                    self.send(error: error.localizedDescription, for: command)
                }
                return
            }

            guard let nonce = nonce else {
                self.send(error: "No PayPal account was returned.", for: command)
                return
            }

            var result: [String: Any] = [
                "userCancelled": false,
                "nonce": nonce.nonce,
                "type": nonce.type,
                "deviceData": self.deviceData
            ]

            result["email"] = nonce.email
            result["firstName"] = nonce.firstName
            result["lastName"] = nonce.lastName
            result["phone"] = nonce.phone
            result["payerId"] = nonce.payerID
            result["clientMetadataId"] = nonce.clientMetadataID

            self.send(ok: result, for: command)
        }

        if flow == "checkout", let amount = amount {
            let request = BTPayPalCheckoutRequest(
                amount: amount,
                intent: .sale,
                userAction: .payNow,
                billingAgreementDescription: description,
                currencyCode: currency,
                displayName: description,
                userAuthenticationEmail: email,
                offerCredit: offerCredit
            )

            client.tokenize(request, completion: completion)
        } else {
            let request = BTPayPalVaultRequest(
                offerCredit: offerCredit,
                billingAgreementDescription: description,
                displayName: description,
                userAuthenticationEmail: email
            )

            client.tokenize(request, completion: completion)
        }
    }

    @objc(venmo:)
    func venmo(_ command: CDVInvokedUrlCommand) {
        guard let client = venmoClient else {
            send(error: "The Braintree client must first be initialized via BraintreePlugin.initialize(options)", for: command)
            return
        }

        guard !busy else {
            send(error: "A payment flow is already in progress.", for: command)
            return
        }

        let args = command.arguments ?? []
        let usage: BTVenmoPaymentMethodUsage = (string(args, 0) ?? "multi_use") == "single_use" ? .singleUse : .multiUse
        let amount = string(args, 1)
        let displayName = string(args, 2)

        let request = BTVenmoRequest(
            paymentMethodUsage: usage,
            vault: usage == .multiUse,
            displayName: displayName,
            isFinalAmount: amount != nil,
            totalAmount: amount
        )

        busy = true

        client.tokenize(request) { [weak self] nonce, error in
            guard let self = self else {
                return
            }

            self.busy = false

            if let error = error {
                let ns = error as NSError

                if ns.domain == BTVenmoError.errorDomain && ns.code == BTVenmoError.canceled.errorCode {
                    self.send(ok: ["userCancelled": true], for: command)
                } else {
                    self.send(error: error.localizedDescription, for: command)
                }
                return
            }

            guard let nonce = nonce else {
                self.send(error: "No Venmo account was returned.", for: command)
                return
            }

            var result: [String: Any] = [
                "userCancelled": false,
                "nonce": nonce.nonce,
                "type": nonce.type,
                "deviceData": self.deviceData
            ]

            result["username"] = nonce.username
            result["email"] = nonce.email
            result["firstName"] = nonce.firstName
            result["lastName"] = nonce.lastName
            result["phoneNumber"] = nonce.phoneNumber
            result["externalId"] = nonce.externalID

            self.send(ok: result, for: command)
        }
    }

    // Venmo is always offerable on iOS 15+: the SDK opens the Venmo app when installed and a web
    // sign-in otherwise. Reported as "the client is ready" so a call before initialize says no.
    @objc(isVenmoAvailable:)
    func isVenmoAvailable(_ command: CDVInvokedUrlCommand) {
        let result = CDVPluginResult(status: .ok, messageAs: venmoClient != nil)

        commandDelegate.send(result, callbackId: command.callbackId)
    }

    @objc(collectDeviceData:)
    func collectDeviceData(_ command: CDVInvokedUrlCommand) {
        guard let collector = dataCollector else {
            send(error: "The Braintree client must first be initialized via BraintreePlugin.initialize(options)", for: command)
            return
        }

        if !deviceData.isEmpty {
            send(ok: deviceData, for: command)
            return
        }

        collector.collectDeviceData { [weak self] data, error in
            if let error = error {
                self?.send(error: error.localizedDescription, for: command)
                return
            }

            self?.deviceData = data ?? ""
            self?.send(ok: data ?? "", for: command)
        }
    }

    // MARK: - Helpers

    private func universalLink() -> URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "BraintreeUniversalLink") as? String,
              let url = URL(string: value) else {
            return nil
        }

        return url
    }

    private func string(_ args: [Any], _ index: Int) -> String? {
        guard index < args.count else {
            return nil
        }

        if let value = args[index] as? String, !value.isEmpty {
            return value
        } else if let value = args[index] as? NSNumber {
            return value.stringValue
        }

        return nil
    }

    private func bool(_ args: [Any], _ index: Int) -> Bool {
        guard index < args.count else {
            return false
        }

        if let value = args[index] as? Bool {
            return value
        } else if let value = args[index] as? NSNumber {
            return value.boolValue
        }

        return false
    }

    private func send(ok message: Any?, for command: CDVInvokedUrlCommand) {
        let result: CDVPluginResult

        if let dictionary = message as? [String: Any] {
            result = CDVPluginResult(status: .ok, messageAs: dictionary)
        } else if let text = message as? String {
            result = CDVPluginResult(status: .ok, messageAs: text)
        } else {
            result = CDVPluginResult(status: .ok)
        }

        commandDelegate.send(result, callbackId: command.callbackId)
    }

    private func send(error message: String, for command: CDVInvokedUrlCommand) {
        let result = CDVPluginResult(status: .error, messageAs: message)

        commandDelegate.send(result, callbackId: command.callbackId)
    }
}
