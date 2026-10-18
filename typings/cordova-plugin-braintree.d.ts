// Type definitions for cordova-plugin-braintree 1.0.0 (PayPal + Venmo through Braintree iOS v7 /
// Android v5). The plugin is a global, `BraintreePlugin`.

declare module BraintreePlugin {

    interface BraintreePluginStatic {

        /**
         * Initializes the native clients with a client token (or tokenization key). Must be
         * called before any other method, and again whenever the server hands out a new token.
         */
        initialize(options: InitializeOptions, successCallback?: () => void, failureCallback?: (error: string) => void): void;

        /**
         * Starts the PayPal flow (the PayPal app when installed, else a secure web sign-in).
         * The result is `{ userCancelled: true }` when the payer backed out.
         */
        payPal(options?: PayPalOptions, successCallback?: (result: PayPalResult) => void, failureCallback?: (error: string) => void): void;

        /**
         * Starts the Venmo flow (the Venmo app when installed, else a web sign-in).
         * The result is `{ userCancelled: true }` when the payer backed out.
         */
        venmo(options?: VenmoOptions, successCallback?: (result: VenmoResult) => void, failureCallback?: (error: string) => void): void;

        /**
         * Ends the flow in progress, if any (its callback receives `{ userCancelled: true }` and
         * is released), so the next one starts clean. Starting another flow, or initializing
         * again, ends it the same way.
         */
        cancel(successCallback?: () => void, failureCallback?: (error: string) => void): void;

        /**
         * Whether Venmo can be offered on this device.
         */
        isVenmoAvailable(successCallback?: (available: boolean) => void, failureCallback?: (error: string) => void): void;

        /**
         * The device data Braintree's fraud tools read alongside a nonce.
         */
        collectDeviceData(successCallback?: (deviceData: string) => void, failureCallback?: (error: string) => void): void;
    }

    interface InitializeOptions {
        /** The client token or tokenization key. */
        token: string;
        /** Dark-themed native sheets where the SDK offers them. */
        dark?: boolean;
    }

    interface PayPalOptions {
        /** `vault` (default): a billing agreement for later charges; `checkout`: one payment of `amount`. */
        flow?: 'vault' | 'checkout';
        /** The payment amount in major units ('12.34'); required for a checkout flow. */
        amount?: string | number;
        /** ISO 4217, default USD. */
        currency?: string;
        /** Shown to the payer as the merchant / agreement description. */
        description?: string;
        /** The payer's email, to prefill the PayPal sign-in. */
        email?: string;
        offerCredit?: boolean;
    }

    interface VenmoOptions {
        /** `multi_use` (default): the account may be kept for later charges; `single_use`: one payment. */
        usage?: 'multi_use' | 'single_use';
        /** The payment amount in major units, shown in the Venmo app. */
        amount?: string | number;
        /** The merchant name shown in the Venmo app. */
        displayName?: string;
    }

    interface FlowResult {
        userCancelled?: boolean;
        /**
         * With `userCancelled`: the plugin can no longer see the flow finishing (the payer came
         * back to the app without a word from the Venmo app or the browser, or nothing happened
         * for a minute). The callback is kept: a result the payer finishes after all still
         * arrives on it, unless another flow, `initialize` or `cancel` ended it.
         */
        idle?: boolean;
        /** The payment method nonce for the server. */
        nonce?: string;
        /** `PayPalAccount` or `VenmoAccount`. */
        type?: string;
        /** The Braintree device data collected alongside the nonce ('' when unavailable). */
        deviceData?: string;
    }

    interface PayPalResult extends FlowResult {
        email?: string;
        firstName?: string;
        lastName?: string;
        phone?: string;
        payerId?: string;
        clientMetadataId?: string;
    }

    interface VenmoResult extends FlowResult {
        username?: string;
        email?: string;
        firstName?: string;
        lastName?: string;
        phoneNumber?: string;
        externalId?: string;
    }
}

declare var BraintreePlugin: BraintreePlugin.BraintreePluginStatic;
