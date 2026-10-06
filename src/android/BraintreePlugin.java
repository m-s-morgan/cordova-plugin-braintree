/**
 * PayPal and Venmo through the Braintree Android SDK (v5): a client token in, a payment method
 * nonce out. The v5 SDK's launcher pattern runs each flow in three steps — build the request,
 * launch the browser / app switch, and finish it when the activity comes back (onNewIntent for the
 * app's singleInstance launch mode, onResume otherwise) — so the pending request is kept in
 * SharedPreferences across the switch, as the SDK asks.
 */

package net.justincredible;

import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.net.Uri;
import android.util.Log;

import androidx.activity.ComponentActivity;
import androidx.activity.result.ActivityResultCaller;
import androidx.annotation.NonNull;
import androidx.appcompat.app.AppCompatActivity;

import org.apache.cordova.CallbackContext;
import org.apache.cordova.CordovaPlugin;
import org.apache.cordova.PluginResult;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import com.braintreepayments.api.datacollector.DataCollector;
import com.braintreepayments.api.datacollector.DataCollectorRequest;
import com.braintreepayments.api.datacollector.DataCollectorResult;
import com.braintreepayments.api.paypal.PayPalAccountNonce;
import com.braintreepayments.api.paypal.PayPalCheckoutRequest;
import com.braintreepayments.api.paypal.PayPalClient;
import com.braintreepayments.api.paypal.PayPalLauncher;
import com.braintreepayments.api.paypal.PayPalPaymentAuthRequest;
import com.braintreepayments.api.paypal.PayPalPaymentAuthResult;
import com.braintreepayments.api.paypal.PayPalPaymentIntent;
import com.braintreepayments.api.paypal.PayPalPaymentUserAction;
import com.braintreepayments.api.paypal.PayPalPendingRequest;
import com.braintreepayments.api.paypal.PayPalRequest;
import com.braintreepayments.api.paypal.PayPalResult;
import com.braintreepayments.api.paypal.PayPalVaultRequest;
import com.braintreepayments.api.venmo.VenmoAccountNonce;
import com.braintreepayments.api.venmo.VenmoClient;
import com.braintreepayments.api.venmo.VenmoLauncher;
import com.braintreepayments.api.venmo.VenmoPaymentAuthRequest;
import com.braintreepayments.api.venmo.VenmoPaymentAuthResult;
import com.braintreepayments.api.venmo.VenmoPaymentMethodUsage;
import com.braintreepayments.api.venmo.VenmoPendingRequest;
import com.braintreepayments.api.venmo.VenmoRequest;
import com.braintreepayments.api.venmo.VenmoResult;

public final class BraintreePlugin extends CordovaPlugin {

    private static final String TAG = "BraintreePlugin";
    private static final String PREFS = "cordova-plugin-braintree";
    private static final String PENDING_PAYPAL = "pendingPayPal";
    private static final String PENDING_VENMO = "pendingVenmo";
    private static final String USER_CANCELLED = "userCancelled";

    private PayPalLauncher payPalLauncher;
    private VenmoLauncher venmoLauncher;
    private PayPalClient payPalClient;
    private VenmoClient venmoClient;
    private DataCollector dataCollector;
    private String authorization;
    private String deviceData = "";

    // the callback of the flow in progress, and which flow it is
    private CallbackContext flowCallback;
    private String flowKind;

    @Override
    protected void pluginInitialize() {
        // the launchers belong to the activity's onCreate; the plugin is created from it
        payPalLauncher = new PayPalLauncher((ActivityResultCaller) null);
        venmoLauncher = new VenmoLauncher((ActivityResultCaller) null);
    }

    @Override
    public boolean execute(String action, final JSONArray args, final CallbackContext callbackContext) throws JSONException {
        if (action == null) {
            return false;
        }

        try {
            switch (action) {
                case "initialize":
                    initialize(args, callbackContext);
                    return true;
                case "payPal":
                    payPal(args, callbackContext);
                    return true;
                case "venmo":
                    venmo(args, callbackContext);
                    return true;
                case "isVenmoAvailable":
                    callbackContext.sendPluginResult(new PluginResult(PluginResult.Status.OK, venmoClient != null));
                    return true;
                case "collectDeviceData":
                    collectDeviceData(callbackContext);
                    return true;
                default:
                    return false;
            }
        } catch (Exception e) {
            Log.e(TAG, "execute " + action + " failed", e);
            callbackContext.error("BraintreePlugin uncaught exception: " + e.getMessage());
            return true;
        }
    }

    // -- returns from the browser / app switch -------------------------------------------------

    @Override
    public void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        handleReturn(intent);
    }

    @Override
    public void onResume(boolean multitasking) {
        super.onResume(multitasking);

        AppCompatActivity activity = cordova.getActivity();

        if (activity != null) {
            handleReturn(activity.getIntent());
        }
    }

    private void handleReturn(Intent intent) {
        if (intent == null) {
            return;
        }

        SharedPreferences prefs = prefs();
        String pendingPayPal = prefs.getString(PENDING_PAYPAL, null);
        String pendingVenmo = prefs.getString(PENDING_VENMO, null);

        if (pendingPayPal != null && payPalClient != null) {
            PayPalPaymentAuthResult result = payPalLauncher.handleReturnToApp(new PayPalPendingRequest.Started(pendingPayPal), intent);

            if (result instanceof PayPalPaymentAuthResult.Success) {
                prefs.edit().remove(PENDING_PAYPAL).apply();
                payPalClient.tokenize((PayPalPaymentAuthResult.Success) result, this::onPayPalResult);
            } else if (result instanceof PayPalPaymentAuthResult.Failure) {
                prefs.edit().remove(PENDING_PAYPAL).apply();
                failFlow(((PayPalPaymentAuthResult.Failure) result).getError().getMessage());
            }
            // NoResult: the activity resumed for another reason; the switch is still pending
        }

        if (pendingVenmo != null && venmoClient != null) {
            VenmoPaymentAuthResult result = venmoLauncher.handleReturnToApp(new VenmoPendingRequest.Started(pendingVenmo), intent);

            if (result instanceof VenmoPaymentAuthResult.Success) {
                prefs.edit().remove(PENDING_VENMO).apply();
                venmoClient.tokenize((VenmoPaymentAuthResult.Success) result, this::onVenmoResult);
            } else if (result instanceof VenmoPaymentAuthResult.Failure) {
                prefs.edit().remove(PENDING_VENMO).apply();
                failFlow(((VenmoPaymentAuthResult.Failure) result).getError().getMessage());
            }
        }
    }

    // -- commands ------------------------------------------------------------------------------

    private void initialize(JSONArray args, CallbackContext callbackContext) throws JSONException {
        String token = args.length() > 0 ? args.optString(0, null) : null;

        if (token == null || token.isEmpty()) {
            callbackContext.error("A token is required.");
            return;
        }

        Context context = cordova.getContext();
        // the App Link the SDK returns to, from the plugin's install variables (res/xml/config.xml)
        String host = preferences.getString("BraintreeReturnHost", "pr.fit");
        String path = preferences.getString("BraintreeReturnPath", "/braintree-payments");
        Uri appLink = Uri.parse("https://" + host + path);
        String fallbackScheme = context.getPackageName() + ".braintree";

        authorization = token;
        payPalClient = new PayPalClient(context, token, appLink, fallbackScheme);
        venmoClient = new VenmoClient(context, token, appLink, fallbackScheme);
        dataCollector = new DataCollector(context, token);
        deviceData = "";

        // any switch left over from an earlier session can't be finished without its callback
        prefs().edit().remove(PENDING_PAYPAL).remove(PENDING_VENMO).apply();

        dataCollector.collectDeviceData(context, new DataCollectorRequest(false), (DataCollectorResult result) -> {
            if (result instanceof DataCollectorResult.Success) {
                deviceData = ((DataCollectorResult.Success) result).getDeviceData();
            }
        });

        callbackContext.success();
    }

    private void payPal(JSONArray args, CallbackContext callbackContext) {
        if (payPalClient == null) {
            callbackContext.error("The Braintree client must first be initialized via BraintreePlugin.initialize(options)");
            return;
        } else if (flowCallback != null) {
            callbackContext.error("A payment flow is already in progress.");
            return;
        }

        String flow = args.optString(0, "vault");
        String amount = args.isNull(1) ? null : args.optString(1, null);
        String currency = args.isNull(2) ? "USD" : args.optString(2, "USD");
        String description = args.isNull(3) ? null : args.optString(3, null);
        String email = args.isNull(4) ? null : args.optString(4, null);
        boolean offerCredit = args.optBoolean(5, false);

        PayPalRequest request;

        if ("checkout".equals(flow) && amount != null && !amount.isEmpty()) {
            PayPalCheckoutRequest checkout = new PayPalCheckoutRequest(amount, false);
            checkout.setIntent(PayPalPaymentIntent.SALE);
            checkout.setUserAction(PayPalPaymentUserAction.USER_ACTION_COMMIT);
            checkout.setCurrencyCode(currency);
            checkout.setDisplayName(description);
            checkout.setBillingAgreementDescription(description);
            checkout.setUserAuthenticationEmail(email);
            checkout.setShouldOfferCredit(offerCredit);
            request = checkout;
        } else {
            PayPalVaultRequest vault = new PayPalVaultRequest(false);
            vault.setBillingAgreementDescription(description);
            vault.setUserAuthenticationEmail(email);
            vault.setShouldOfferCredit(offerCredit);
            request = vault;
        }

        final AppCompatActivity activity = cordova.getActivity();

        flowCallback = callbackContext;
        flowKind = PENDING_PAYPAL;

        payPalClient.createPaymentAuthRequest(activity, request, (PayPalPaymentAuthRequest authRequest) -> {
            if (authRequest instanceof PayPalPaymentAuthRequest.ReadyToLaunch) {
                PayPalPendingRequest pending = payPalLauncher.launch((ComponentActivity) activity, (PayPalPaymentAuthRequest.ReadyToLaunch) authRequest);

                if (pending instanceof PayPalPendingRequest.Started) {
                    prefs().edit().putString(PENDING_PAYPAL, ((PayPalPendingRequest.Started) pending).getPendingRequestString()).apply();
                } else if (pending instanceof PayPalPendingRequest.Failure) {
                    failFlow(((PayPalPendingRequest.Failure) pending).getError().getMessage());
                }
            } else if (authRequest instanceof PayPalPaymentAuthRequest.Failure) {
                failFlow(((PayPalPaymentAuthRequest.Failure) authRequest).getError().getMessage());
            }
        });
    }

    private void onPayPalResult(PayPalResult result) {
        if (result instanceof PayPalResult.Success) {
            PayPalAccountNonce nonce = ((PayPalResult.Success) result).getNonce();
            JSONObject json = new JSONObject();

            try {
                json.put(USER_CANCELLED, false);
                json.put("nonce", nonce.getString());
                json.put("type", "PayPalAccount");
                json.put("deviceData", deviceData);
                json.putOpt("email", nonce.getEmail());
                json.putOpt("firstName", nonce.getFirstName());
                json.putOpt("lastName", nonce.getLastName());
                json.putOpt("phone", nonce.getPhone());
                json.putOpt("payerId", nonce.getPayerId());
                json.putOpt("clientMetadataId", nonce.getClientMetadataId());
            } catch (JSONException e) {
                failFlow(e.getMessage());
                return;
            }

            finishFlow(json);
        } else if (result instanceof PayPalResult.Cancel) {
            cancelFlow();
        } else if (result instanceof PayPalResult.Failure) {
            failFlow(((PayPalResult.Failure) result).getError().getMessage());
        }
    }

    private void venmo(JSONArray args, CallbackContext callbackContext) {
        if (venmoClient == null) {
            callbackContext.error("The Braintree client must first be initialized via BraintreePlugin.initialize(options)");
            return;
        } else if (flowCallback != null) {
            callbackContext.error("A payment flow is already in progress.");
            return;
        }

        String usage = args.optString(0, "multi_use");
        String amount = args.isNull(1) ? null : args.optString(1, null);
        String displayName = args.isNull(2) ? null : args.optString(2, null);
        boolean multiUse = !"single_use".equals(usage);

        VenmoRequest request = new VenmoRequest(multiUse ? VenmoPaymentMethodUsage.MULTI_USE : VenmoPaymentMethodUsage.SINGLE_USE);
        request.setShouldVault(multiUse);
        request.setDisplayName(displayName);

        if (amount != null && !amount.isEmpty()) {
            request.setTotalAmount(amount);
            request.setFinalAmount(true);
        }

        final AppCompatActivity activity = cordova.getActivity();

        flowCallback = callbackContext;
        flowKind = PENDING_VENMO;

        venmoClient.createPaymentAuthRequest(activity, request, (VenmoPaymentAuthRequest authRequest) -> {
            if (authRequest instanceof VenmoPaymentAuthRequest.ReadyToLaunch) {
                VenmoPendingRequest pending = venmoLauncher.launch((ComponentActivity) activity, (VenmoPaymentAuthRequest.ReadyToLaunch) authRequest);

                if (pending instanceof VenmoPendingRequest.Started) {
                    prefs().edit().putString(PENDING_VENMO, ((VenmoPendingRequest.Started) pending).getPendingRequestString()).apply();
                } else if (pending instanceof VenmoPendingRequest.Failure) {
                    failFlow(((VenmoPendingRequest.Failure) pending).getError().getMessage());
                }
            } else if (authRequest instanceof VenmoPaymentAuthRequest.Failure) {
                failFlow(((VenmoPaymentAuthRequest.Failure) authRequest).getError().getMessage());
            }
        });
    }

    private void onVenmoResult(VenmoResult result) {
        if (result instanceof VenmoResult.Success) {
            VenmoAccountNonce nonce = ((VenmoResult.Success) result).getNonce();
            JSONObject json = new JSONObject();

            try {
                json.put(USER_CANCELLED, false);
                json.put("nonce", nonce.getString());
                json.put("type", "VenmoAccount");
                json.put("deviceData", deviceData);
                json.putOpt("username", nonce.getUsername());
                json.putOpt("email", nonce.getEmail());
                json.putOpt("firstName", nonce.getFirstName());
                json.putOpt("lastName", nonce.getLastName());
                json.putOpt("phoneNumber", nonce.getPhoneNumber());
                json.putOpt("externalId", nonce.getExternalId());
            } catch (JSONException e) {
                failFlow(e.getMessage());
                return;
            }

            finishFlow(json);
        } else if (result instanceof VenmoResult.Cancel) {
            cancelFlow();
        } else if (result instanceof VenmoResult.Failure) {
            failFlow(((VenmoResult.Failure) result).getError().getMessage());
        }
    }

    private void collectDeviceData(CallbackContext callbackContext) {
        if (dataCollector == null) {
            callbackContext.error("The Braintree client must first be initialized via BraintreePlugin.initialize(options)");
            return;
        } else if (!deviceData.isEmpty()) {
            callbackContext.success(deviceData);
            return;
        }

        dataCollector.collectDeviceData(cordova.getContext(), new DataCollectorRequest(false), (DataCollectorResult result) -> {
            if (result instanceof DataCollectorResult.Success) {
                deviceData = ((DataCollectorResult.Success) result).getDeviceData();
                callbackContext.success(deviceData);
            } else if (result instanceof DataCollectorResult.Failure) {
                callbackContext.error(((DataCollectorResult.Failure) result).getError().getMessage());
            } else {
                callbackContext.success("");
            }
        });
    }

    // -- flow bookkeeping ----------------------------------------------------------------------

    private void finishFlow(JSONObject json) {
        CallbackContext callback = flowCallback;

        flowCallback = null;
        flowKind = null;

        if (callback != null) {
            callback.success(json);
        }
    }

    private void cancelFlow() {
        CallbackContext callback = flowCallback;

        flowCallback = null;
        flowKind = null;

        if (callback != null) {
            JSONObject json = new JSONObject();

            try {
                json.put(USER_CANCELLED, true);
            } catch (JSONException ignored) { /* a literal */ }

            callback.success(json);
        }
    }

    private void failFlow(String message) {
        CallbackContext callback = flowCallback;

        if (flowKind != null) {
            prefs().edit().remove(flowKind).apply();
        }

        flowCallback = null;
        flowKind = null;

        Log.e(TAG, "flow failed: " + message);

        if (callback != null) {
            callback.error(message == null ? "The payment could not be approved." : message);
        }
    }

    private SharedPreferences prefs() {
        return cordova.getContext().getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }
}
