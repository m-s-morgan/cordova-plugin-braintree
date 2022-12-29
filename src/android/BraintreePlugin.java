/**
 * Fixing context confusion issues
 */

package net.justincredible;

import android.util.Log;

import org.apache.cordova.CallbackContext;
import org.apache.cordova.CordovaPlugin;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import com.braintreepayments.api.CardNonce;
import com.braintreepayments.api.DropInClient;
import com.braintreepayments.api.DropInListener;
import com.braintreepayments.api.DropInPaymentMethod;
import com.braintreepayments.api.DropInRequest;
import com.braintreepayments.api.DropInResult;
import com.braintreepayments.api.GooglePayRequest;
import com.braintreepayments.api.PayPalAccountNonce;
import com.braintreepayments.api.PayPalRequest;
import com.braintreepayments.api.PayPalVaultRequest;
import com.braintreepayments.api.PaymentMethodNonce;
import com.braintreepayments.api.ThreeDSecureInfo;
import com.braintreepayments.api.ThreeDSecurePostalAddress;
import com.braintreepayments.api.ThreeDSecureRequest;
import com.braintreepayments.api.UserCanceledException;
import com.braintreepayments.api.VenmoAccountNonce;
import com.braintreepayments.api.DataCollector;
import com.braintreepayments.api.VenmoPaymentMethodUsage;
import com.braintreepayments.api.VenmoRequest;
import com.google.android.gms.wallet.TransactionInfo;
import com.google.android.gms.wallet.WalletConstants;
import java.util.HashMap;
import java.util.Map;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.appcompat.app.AppCompatActivity;
import androidx.fragment.app.Fragment;
import androidx.fragment.app.FragmentManager;
import androidx.fragment.app.FragmentTransaction;

public final class BraintreePlugin extends CordovaPlugin implements DropInListener {

    private static final String TAG = "BraintreePlugin";
    private static final String FRAGMENT_TAG = "BraintreeFragment";

    private DropInClient dropInClient;
    // private PayPalRequest payPalRequest = null;
    private DropInRequest dropInRequest = null;
    private CallbackContext _callbackContext = null;
    private CallbackContext _resultContext = null;
    private String temporaryToken = null;

    @Override
    public synchronized boolean execute(String action, final JSONArray args, final CallbackContext callbackContext) throws JSONException {

        if (action == null) {
            Log.e(TAG, "execute ==> exiting for bad action");
            return false;
        }

        Log.w(TAG, "execute ==> " + action + " === " + args);

        _callbackContext = callbackContext;

        try {
            if (action.equals("initialize")) {
                this.initializeBT(args);
            }
            else if (action.equals("presentDropInPaymentUI")) {
                this.presentDropInPaymentUI(args);
                _resultContext = callbackContext;
            }
            else if (action.equals("paypalProcess")) {
                this.paypalProcess(args);
            }
            else if (action.equals("paypalProcessVaulted")) {
                this.paypalProcessVaulted();
            }
            else if (action.equals("setupApplePay")) {
                this.setupApplePay();
            }
            else {
                // The given action was not handled above.
                return false;
            }
        } catch (Exception exception) {
            callbackContext.error("BraintreePlugin uncaught exception: " + exception.getMessage());
        }

        return true;
    }

    public void onError(Exception error) {
        if (_callbackContext == null) {
            Log.e(TAG, "onError exiting ==> callbackContext is invalid");
            return;
        }

        Log.e(TAG, "Caught error from BraintreeSDK: " + error.getMessage());
        _callbackContext.error("BraintreePlugin uncaught exception: " + error.getMessage());
    }

    // Actions

    private synchronized void initializeBT(final JSONArray args) throws Exception {
        Log.d(TAG, "Initializing");
        if (_callbackContext == null) {
            Log.e(TAG, "initializeBT exiting ==> callbackContext is invalid");
            return;
        }

        // Ensure we have the correct number of arguments.
        if (args.length() < 1) { // ProFit MOD
            _callbackContext.error("A token is required.");
            return;
        }

        // Obtain the arguments.
        String token = args.getString(0);

        if (token == null || token.equals("")) {
            _callbackContext.error("A token is required.");
            return;
        }

        BraintreePlugin that = this;
        AppCompatActivity aActivity = this.cordova.getActivity();

        aActivity.runOnUiThread(new Runnable() {
           @Override
           public void run() {
               BraintreeFragment mActivity = new BraintreeFragment(token);

               mActivity.dropInClientCreated = new BTCallback() {
                   @Override
                   public void success() {
                       dropInClient = mActivity.dropInClient;
                       mActivity.setListener(that);
                       temporaryToken = token;
                       _callbackContext.success();
                       _callbackContext = null;
                   }
               };

               FragmentManager fm = aActivity.getSupportFragmentManager();
               Fragment f = fm.findFragmentByTag(FRAGMENT_TAG);
               FragmentTransaction ft = fm.beginTransaction();

               if (f != null) {
                   ft.remove(f);
               }

               ft.add(mActivity, FRAGMENT_TAG).commit();
            }
        });
    }

    private synchronized void setupApplePay() throws JSONException {

        if (_callbackContext == null) {
            Log.e(TAG, "setupApplePay exiting ==> callbackContext is invalid");
            return;
        }

        // Apple Pay available on iOS only
        _callbackContext.success();
    }

    /**
     *
     * @param dropInRequest
     * @param amount
     * @param currency
     * @param merchantId
     */
    private void enableGooglePay(DropInRequest dropInRequest, String amount, String currency, @Nullable String merchantId) {
        GooglePayRequest googlePaymentRequest = new GooglePayRequest();

        googlePaymentRequest.setTransactionInfo(TransactionInfo.newBuilder()
                        .setTotalPrice(amount)
                        .setTotalPriceStatus(WalletConstants.TOTAL_PRICE_STATUS_FINAL)
                        .setCurrencyCode(currency)
                        .build());

        googlePaymentRequest.setBillingAddressRequired(true);

        if (merchantId != null && merchantId.length() > 0) {
            googlePaymentRequest.setGoogleMerchantId(merchantId);
        }

        dropInRequest.setGooglePayRequest(googlePaymentRequest);
    }

    private synchronized void presentDropInPaymentUI(final JSONArray args) throws JSONException {
        if (_callbackContext == null) {
            Log.e(TAG, "presentDropInPaymentUI exiting ==> callbackContext is invalid");
            return;
        }

        // Ensure the client has been initialized.
        if (temporaryToken == null) {
            _callbackContext.error("The Braintree client must first be initialized via BraintreePlugin.initialize(token)");
            return;
        }

        temporaryToken = null;

        dropInRequest = new DropInRequest();

        if (dropInRequest == null) {
            _callbackContext.error("The Braintree client failed to initialize.");
            return;
        }

        // Ensure we have the correct number of arguments.
        if (args.length() < 1) {
            _callbackContext.error("amount is required.");
            return;
        }
        try {
            // Obtain the arguments.

            String amount = args.getString(0);

            if (amount == null) {
                _callbackContext.error("amount is required.");
            }

            String primaryDescription = args.getString(1);

            JSONObject threeDSecure = args.getJSONObject(2);
            JSONObject googlePay = args.getJSONObject(3);

            if (threeDSecure == null) {
                _callbackContext.error("threeDSecure is required.");
            }
            
            // dropInRequest.collectDeviceData(true);
            dropInRequest.setVaultManagerEnabled(true);

            ThreeDSecureRequest threeDSecureRequest = new ThreeDSecureRequest();
            threeDSecureRequest.setAmount(threeDSecure.getString("amount"));
            threeDSecureRequest.setEmail(threeDSecure.getString("email"));
            threeDSecureRequest.setVersionRequested(ThreeDSecureRequest.VERSION_2);
            ThreeDSecurePostalAddress address = new ThreeDSecurePostalAddress();
            address.setGivenName(threeDSecure.getString("firstName"));
            address.setSurname(threeDSecure.getString("lastName"));
            threeDSecureRequest.setBillingAddress(address);
            dropInRequest.setThreeDSecureRequest(threeDSecureRequest);

            PayPalVaultRequest payPalRequest = new PayPalVaultRequest();
            dropInRequest.setPayPalRequest(payPalRequest);
            dropInRequest.setVenmoRequest(new VenmoRequest(VenmoPaymentMethodUsage.MULTI_USE));

            if (googlePay != null) {
                enableGooglePay(dropInRequest, amount, googlePay.getString("currency"), googlePay.getString("merchantId"));
            }

            dropInClient.launchDropIn(dropInRequest);
        } catch (Exception e) {
            Log.e(TAG, "presentDropInPaymentUI failed with error ===> " + e.getMessage());
            _callbackContext.error(TAG + ": presentDropInPaymentUI failed with error ===> " + e.getMessage());
        }
    }

    private synchronized void paypalProcess(final JSONArray args) throws Exception {
        // MAYBE TODO
        // payPalRequest = new PayPalRequest(args.getString(0));
        // payPalRequest.currencyCode(args.getString(1));
        // PayPal.requestOneTimePayment(braintreeFragment, payPalRequest);
    }

    private synchronized void paypalProcessVaulted() throws Exception {
        // MAYBE TODO
        // PayPal.requestBillingAgreement(braintreeFragment, payPalRequest);
    }

    @Override
    public void onDropInSuccess(@NonNull DropInResult dropInResult) {
        PaymentMethodNonce nonce = dropInResult.getPaymentMethodNonce();

        if (_resultContext == null) {
            Log.e(TAG, "handleDropInPaymentUiResult exiting ==> callbackContext is invalid");
            return;
        } else if (nonce == null) {
            _resultContext.error("Result was not RESULT_CANCELED, but no PaymentMethodNonce was returned from the Braintree SDK.");
            _resultContext = null;
            return;
        }

        Map<String, Object> resultMap = new HashMap<String, Object>();

        resultMap.put("nonce", nonce.getString());
        resultMap.put("deviceData", dropInResult.getDeviceData());
        resultMap.put("localizedDescription", dropInResult.getPaymentDescription());

        DropInPaymentMethod paymentMethodType = dropInResult.getPaymentMethodType();

        if (paymentMethodType != null) {
            resultMap.put("type", paymentMethodType.getLocalizedName());
        }

        // Card
        if (nonce instanceof CardNonce) {
            CardNonce cardNonce = (CardNonce) nonce;

            Map<String, Object> innerMap = new HashMap<String, Object>();
            innerMap.put("lastTwo", cardNonce.getLastTwo());
            innerMap.put("lastFour", cardNonce.getLastFour());
            innerMap.put("expirationMonth", cardNonce.getExpirationMonth());
            innerMap.put("expirationYear", cardNonce.getExpirationYear());
            innerMap.put("cardholderName", cardNonce.getCardholderName());
            innerMap.put("network", cardNonce.getCardType());

            resultMap.put("card", innerMap);
        }

        // PayPal
        if (nonce instanceof PayPalAccountNonce) {
            PayPalAccountNonce payPalAccountNonce = (PayPalAccountNonce) nonce;

            Map<String, Object> innerMap = new HashMap<String, Object>();
            resultMap.put("email", payPalAccountNonce.getEmail());
            resultMap.put("firstName", payPalAccountNonce.getFirstName());
            resultMap.put("lastName", payPalAccountNonce.getLastName());
            resultMap.put("phone", payPalAccountNonce.getPhone());
            resultMap.put("clientMetadataId", payPalAccountNonce.getClientMetadataId());
            resultMap.put("payerId", payPalAccountNonce.getPayerId());

            resultMap.put("paypalAccount", innerMap);
        }

        // 3D Secure
        if (nonce instanceof CardNonce) {
            CardNonce cardNonce = (CardNonce) nonce;
            ThreeDSecureInfo threeDSecureInfo = cardNonce.getThreeDSecureInfo();

            if (threeDSecureInfo != null) {
                Map<String, Object> innerMap = new HashMap<String, Object>();
                innerMap.put("liabilityShifted", threeDSecureInfo.isLiabilityShifted());
                innerMap.put("liabilityShiftPossible", threeDSecureInfo.isLiabilityShiftPossible());
                innerMap.put("wasVerified", threeDSecureInfo.wasVerified());

                resultMap.put("threeDSecureInfo", innerMap);
            }
        }

        // Venmo
        if (nonce instanceof VenmoAccountNonce) {
            VenmoAccountNonce venmoAccountNonce = (VenmoAccountNonce) nonce;

            Map<String, Object> innerMap = new HashMap<String, Object>();
            innerMap.put("username", venmoAccountNonce.getUsername());

            resultMap.put("venmoAccount", innerMap);
        }

        Log.i(TAG, "handleDropInPaymentUiResult nonce = " + nonce.getString());

        _resultContext.success(new JSONObject(resultMap));
        _resultContext = null;
    }

    @Override
    public void onDropInFailure(@NonNull Exception error) {
        boolean isUserCanceled = (error instanceof UserCanceledException);
        if (!isUserCanceled) {
            this.onError(error);
            return;
        }

        Map<String, Object> resultMap = new HashMap<String, Object>();
        resultMap.put("userCancelled", true);
        _resultContext.success(new JSONObject(resultMap));
        _resultContext = null;
    }
}