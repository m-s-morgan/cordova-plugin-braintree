'use strict';

var exec = require('cordova/exec');

/**
 * The Cordova plugin ID for this plugin.
 */
var PLUGIN_ID = 'BraintreePlugin';

/**
 * PayPal and Venmo through the Braintree native SDKs. Every function takes optional success and
 * failure callbacks as its last two arguments; the failure callback receives an error string.
 *
 * A flow result is `{ userCancelled: true }` when the payer backed out, otherwise
 * `{ nonce, type, deviceData, ... }` with the account details listed in the typings.
 */
var BraintreePlugin = {};

function fail(failureCallback, message) {
    if (typeof failureCallback === 'function') {
        failureCallback(message);
    }
}

function money(amount) {
    if (amount === undefined || amount === null || amount === '') {
        return null;
    }

    var n = Number(amount);

    return isNaN(n) ? String(amount) : n.toFixed(2);
}

/**
 * Initializes the native clients with a client token (or tokenization key). Must be called before
 * any other function, and again with a fresh token whenever the server hands one out.
 *
 * @param {{ token: string; dark?: boolean; }} options
 */
BraintreePlugin.initialize = function initialize(options, successCallback, failureCallback) {
    if (!options) {
        options = {};
    }

    var token = options.token;

    if (!token || typeof token !== 'string') {
        fail(failureCallback, 'A non-null, non-empty string must be provided for the token parameter.');
        return;
    }

    exec(successCallback, failureCallback, PLUGIN_ID, 'initialize', [token, options.dark === true]);
};

/**
 * Starts the PayPal flow (the PayPal app when installed, otherwise a secure web sign-in).
 *
 * @param {{ flow?: 'vault'|'checkout'; amount?: string|number; currency?: string; description?: string; email?: string; offerCredit?: boolean; }} options
 *   `vault` (the default) approves a billing agreement the server can charge later; `checkout`
 *   approves one payment of `amount`.
 */
BraintreePlugin.payPal = function payPal(options, successCallback, failureCallback) {
    if (!options) {
        options = {};
    }

    var flow = options.flow === 'checkout' ? 'checkout' : 'vault',
        amount = money(options.amount);

    if (flow === 'checkout' && !amount) {
        fail(failureCallback, 'An amount is required for a checkout payment.');
        return;
    }

    exec(successCallback, failureCallback, PLUGIN_ID, 'payPal', [
        flow,
        amount,
        options.currency || 'USD',
        options.description || null,
        options.email || null,
        options.offerCredit === true
    ]);
};

/**
 * Starts the Venmo flow (the Venmo app when installed, otherwise a web sign-in).
 *
 * @param {{ usage?: 'multi_use'|'single_use'; amount?: string|number; displayName?: string; }} options
 *   `multi_use` (the default) lets the server keep the account for later charges.
 */
BraintreePlugin.venmo = function venmo(options, successCallback, failureCallback) {
    if (!options) {
        options = {};
    }

    exec(successCallback, failureCallback, PLUGIN_ID, 'venmo', [
        options.usage === 'single_use' ? 'single_use' : 'multi_use',
        money(options.amount),
        options.displayName || null
    ]);
};

/**
 * Whether Venmo can be offered on this device (the SDK falls back to a web sign-in without the
 * app, so this is about the platform's support, not the app being installed).
 */
BraintreePlugin.isVenmoAvailable = function isVenmoAvailable(successCallback, failureCallback) {
    exec(function (result) {
        if (typeof successCallback === 'function') {
            successCallback(result === true || result === 1 || result === 'true');
        }
    }, failureCallback, PLUGIN_ID, 'isVenmoAvailable', []);
};

/**
 * The device data Braintree's fraud tools read alongside a nonce (also carried on every flow
 * result as `deviceData`).
 */
BraintreePlugin.collectDeviceData = function collectDeviceData(successCallback, failureCallback) {
    exec(successCallback, failureCallback, PLUGIN_ID, 'collectDeviceData', []);
};

module.exports = BraintreePlugin;
