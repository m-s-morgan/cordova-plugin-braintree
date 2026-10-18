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
//  One flow at a time, and never a stuck one. The SDK only finishes a Venmo flow from a return URL:
//  a payer who leaves the Venmo app some other way (home, the app switcher, closing Venmo) never
//  produces one, and the SDK's completion never fires; a PayPal web session that fails to start
//  never completes either. So the flow in progress is tracked here (`pending`) and watched:
//
//   - a Venmo flow whose app came back from the background without a return URL (after a short
//     grace for the link to arrive), or any flow with no word for a minute, is reported IDLE to
//     the page: `{ userCancelled: true, idle: true }`, with the callback kept. The page shows its
//     buttons again, but the flow stays claimable — a payer who only peeked back at the app and
//     then approved in Venmo still gets that approval delivered, on the same callback.
//   - a flow ends for good (`{ userCancelled: true }`, callback released) when the page starts
//     another, re-initializes, or says it is done (`cancel`); an SDK result for a flow that ended
//     is dropped (`generation`).
//

import Foundation
import UIKit
import Braintree

@objc(BraintreePlugin)
class BraintreePlugin: CDVPlugin {

    private static let kindPayPal = "paypal"
    private static let kindVenmo = "venmo"

    // how long a return URL gets to arrive after the app came back from the background before an
    // out-of-app (Venmo) flow is reported idle
    private static let returnGrace: TimeInterval = 2.5
    // how long any flow gets without a word (the SDK's own network timeouts are 30 s a call), and
    // how long one gets to finish after its return URL arrived, before it is reported idle
    private static let backstop: TimeInterval = 60
    private static let returnBackstop: TimeInterval = 70

    private var authorization: String?
    private var payPalClient: BTPayPalClient?
    private var venmoClient: BTVenmoClient?
    private var dataCollector: BTDataCollector?
    private var deviceData: String = ""

    // the flow in progress: its command (to answer), which flow it is, and whether the page was
    // already told it looks idle
    private var pending: (command: CDVInvokedUrlCommand, kind: String, idled: Bool)?
    // bumped whenever a flow starts or ends: an SDK completion for an older generation is for a
    // flow already answered
    private var generation = 0
    // a return URL the SDK accepted since the pending flow started
    private var returnURLSeen = false
    // the app went to the background since the pending flow started (an app switch, not a
    // Control Center pull or a call banner, which only resign active)
    private var leftApp = false
    // a watch fired while the app was not in front (nothing is idle while the payer is away):
    // re-armed, short, when it comes back
    private var watchMissed = false

    // MARK: - Lifecycle

    override func pluginInitialize() {
        super.pluginInitialize()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onContinueUserActivity(_:)),
            name: NSNotification.Name("CDVPluginContinueUserActivityNotification"),
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onDidEnterBackground(_:)),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onDidBecomeActive(_:)),
            name: UIApplication.didBecomeActiveNotification,
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

        handleReturn(url)
    }

    // a universal-link return (scene:continueUserActivity:)
    @objc func onContinueUserActivity(_ notification: Notification) {
        guard let activity = notification.object as? NSUserActivity,
              activity.activityType == NSUserActivityTypeBrowsingWeb,
              let url = activity.webpageURL else {
            return
        }

        handleReturn(url)
    }

    private func handleReturn(_ url: URL) {
        guard BTAppContextSwitcher.sharedInstance.handleOpen(url) else {
            return
        }

        returnURLSeen = true

        // the SDK accepted the URL, but may still have nothing to finish with it (a flow it no
        // longer holds), and finishing takes network calls: watched again, longer
        if pending != nil {
            watch(after: BraintreePlugin.returnBackstop)
        }
    }

    @objc func onDidEnterBackground(_ notification: Notification) {
        if pending != nil {
            leftApp = true
        }
    }

    // back from the background: a Venmo flow left for the Venmo app (or Safari), and comes back
    // through a return URL — or not at all, when the payer just switched back. The URL arrives
    // around the same activation, so after a short grace without one the flow is reported idle.
    // (A PayPal flow runs in an in-app web session: its consent alert and its PayPal-app hops
    // activate the app with the sheet still up, so it is only ever watched by the backstop.)
    @objc func onDidBecomeActive(_ notification: Notification) {
        guard let pending = pending, !pending.idled else {
            return
        }

        if watchMissed {
            watchMissed = false
            watch(after: BraintreePlugin.returnGrace)
            return
        }

        guard pending.kind == BraintreePlugin.kindVenmo, leftApp, !returnURLSeen else {
            return
        }

        watch(after: BraintreePlugin.returnGrace)
    }

    // reports the flow idle when, by then, it is still the same flow, no return URL arrived since
    // and the app is in front (a payer back in Venmo within the grace is not idle)
    private func watch(after delay: TimeInterval) {
        let generation = self.generation
        let returned = returnURLSeen

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, generation == self.generation, let pending = self.pending, !pending.idled else {
                return
            }

            if !returned && self.returnURLSeen {
                // the return arrived meanwhile: its own, longer watch is on
                return
            }

            if UIApplication.shared.applicationState != .active {
                self.watchMissed = true
                return
            }

            self.pending = (command: pending.command, kind: pending.kind, idled: true)

            let result = CDVPluginResult(status: .ok, messageAs: ["userCancelled": true, "idle": true])

            result.setKeepCallbackAs(true)
            self.commandDelegate.send(result, callbackId: pending.command.callbackId)
        }
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

        // new clients: whatever the old ones had in flight is over
        settleCancelled()

        authorization = token
        // (the PayPal client is made per flow: see payPal)
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
        guard payPalClient != nil, let authorization = authorization else {
            send(error: "The Braintree client must first be initialized via BraintreePlugin.initialize(options)", for: command)
            return
        }

        // a fresh client every time: a web session that failed to start (the app not in front
        // when the sheet was due) stays "current" in its client for good, and every later
        // tokenize on that client is refused as a duplicate without a word
        let client = BTPayPalClient(authorization: authorization)

        payPalClient = client

        let args = command.arguments ?? []
        let flow = string(args, 0) ?? "vault"
        let amount = string(args, 1)
        let currency = string(args, 2) ?? "USD"
        let description = string(args, 3)
        let email = string(args, 4)
        let offerCredit = bool(args, 5)

        let generation = begin(BraintreePlugin.kindPayPal, command)

        let completion: (BTPayPalAccountNonce?, Error?) -> Void = { [weak self] nonce, error in
            guard let self = self, let command = self.current(generation) else {
                return
            }

            if let error = error {
                let ns = error as NSError

                if ns.domain == BTPayPalError.errorDomain && ns.code == BTPayPalError.canceled.errorCode {
                    self.settleCancelled()
                } else {
                    self.settle(error: error.localizedDescription, for: command)
                }
                return
            }

            guard let nonce = nonce else {
                self.settle(error: "No PayPal account was returned.", for: command)
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

            self.settle(ok: result, for: command)
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

        let generation = begin(BraintreePlugin.kindVenmo, command)

        client.tokenize(request) { [weak self] nonce, error in
            guard let self = self, let command = self.current(generation) else {
                return
            }

            if let error = error {
                let ns = error as NSError

                if ns.domain == BTVenmoError.errorDomain && ns.code == BTVenmoError.canceled.errorCode {
                    self.settleCancelled()
                } else {
                    self.settle(error: error.localizedDescription, for: command)
                }
                return
            }

            guard let nonce = nonce else {
                self.settle(error: "No Venmo account was returned.", for: command)
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

            self.settle(ok: result, for: command)
        }
    }

    // the page is done with the flow in progress (its modal closed, its state left): answered as
    // cancelled so the next one starts clean. Nothing in progress is fine.
    @objc(cancel:)
    func cancel(_ command: CDVInvokedUrlCommand) {
        settleCancelled()
        send(ok: nil, for: command)
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

    // MARK: - The flow in progress

    // starts a flow: one already in progress is over (answered as cancelled) — the page could not
    // tap a button while it ran unless its result never came, and the new tap is what the payer
    // wants now
    private func begin(_ kind: String, _ command: CDVInvokedUrlCommand) -> Int {
        settleCancelled()

        generation += 1
        pending = (command: command, kind: kind, idled: false)
        returnURLSeen = false
        leftApp = false
        watchMissed = false
        watch(after: BraintreePlugin.backstop)

        return generation
    }

    // the pending command, when the completion calling belongs to the flow still in progress
    private func current(_ generation: Int) -> CDVInvokedUrlCommand? {
        guard generation == self.generation, let pending = pending else {
            return nil
        }

        return pending.command
    }

    private func settleCancelled() {
        guard let pending = pending else {
            return
        }

        end()
        send(ok: ["userCancelled": true], for: pending.command)
    }

    private func settle(ok result: [String: Any], for command: CDVInvokedUrlCommand) {
        end()
        send(ok: result, for: command)
    }

    private func settle(error message: String, for command: CDVInvokedUrlCommand) {
        end()
        send(error: message, for: command)
    }

    private func end() {
        pending = nil
        generation += 1
        returnURLSeen = false
        leftApp = false
        watchMissed = false
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
