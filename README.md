# cordova-plugin-braintree (v7 branch)

PayPal and Venmo through the Braintree native SDKs: [braintree_ios](https://github.com/braintree/braintree_ios) v7 and [braintree_android](https://github.com/braintree/braintree_android) v5. A client token goes in, a payment method nonce comes out, and the server does the rest.

This branch replaces the Drop-in based plugin (the `pods` branch). Braintree retired every Drop-in SDK on 2026-09-01 and the current native SDKs have none, so the plugin now renders nothing of its own: the app shows its own PayPal / Venmo buttons and calls one method per flow.

Platforms: iOS 15+ (cordova-ios 8+, Swift), Android API 23+ (cordova-android 12+).

## Install

```bash
cordova plugin add https://github.com/m-s-morgan/cordova-plugin-braintree#v7 \
  --variable BRAINTREE_RETURN_HOST=pr.fit \
  --variable BRAINTREE_RETURN_PATH=/braintree-payments
```

The two variables form the universal link / App Link `https://<host><path>` the Venmo app (and the PayPal app, when app switch is enabled) returns to:

- iOS: the host must serve an `apple-app-site-association` whose paths include `<path>/*`, and the app must have the `applinks:<host>` associated domain.
- Android: `https://<host>/.well-known/assetlinks.json` must list the app's signing certificate; the plugin adds the `autoVerify` intent filter. It also registers the `<applicationId>.braintree` scheme the SDK falls back to.

Both apps' bundle ids are queried (`paypal`, `com.venmo.touch.v2` on iOS; `com.venmo` on Android) so the SDKs can app-switch when installed. Without the app, PayPal opens a secure web sign-in and Venmo a web login.

## Usage

```js
BraintreePlugin.initialize({ token: clientToken, dark: true }, onReady, onError);

BraintreePlugin.payPal({ flow: 'vault', description: 'ProFit', email: 'payer@example.com' }, function (result) {
    if (result.userCancelled) { return; }
    // result.nonce, result.deviceData, result.email ...
}, onError);

BraintreePlugin.venmo({ usage: 'multi_use', amount: '12.34', displayName: 'ProFit' }, function (result) {
    if (result.userCancelled) { return; }
    // result.nonce, result.deviceData, result.username ...
}, onError);

BraintreePlugin.cancel();   // the page is done with the flow in progress (its modal closed)
BraintreePlugin.isVenmoAvailable(function (available) { ... });
BraintreePlugin.collectDeviceData(function (deviceData) { ... });
```

`flow: 'vault'` (the default) approves a billing agreement the server can charge now and later; `flow: 'checkout'` approves a single payment of `amount`. `usage: 'multi_use'` (the default) lets the server keep the Venmo account for later charges.

Send `nonce` (and `deviceData`) to the server for `transaction.sale` or `paymentMethod.create`.

One flow runs at a time, and none gets stuck. The SDKs only finish a flow from its return (a
universal link / App Link, or the web session closing): a payer who leaves the Venmo app some other
way never produces one. When the app comes back from the background without a return (after a short
grace for the link), or nothing happens for a minute, the flow's callback receives
`{ userCancelled: true, idle: true }` and is kept: offer the buttons again, and a result the payer
finishes after all still arrives on it. Starting another flow, `initialize`, or `cancel` ends the
flow in progress for good (`{ userCancelled: true }`, callback released); the SDK's late word on an
ended flow is dropped.

## Return handling

- iOS (cordova-ios 8 scene lifecycle): the plugin observes `CDVPluginContinueUserActivityNotification` and the standard `handleOpenURL` hook and hands URLs to `BTAppContextSwitcher`, which only consumes the ones the SDK recognises. No `AppDelegate` category is installed, so other universal-link plugins keep working.
- Android: the pending request is stored in `SharedPreferences` and finished from `onNewIntent` / `onResume`, as the v5 SDK requires.

TypeScript definitions are in `typings/`.
