# Sourced by the release scripts. Leaves in "$@" the xcodebuild arguments
# that sign in with an App Store Connect API key, or nothing when no key was
# named and the Apple ID that Xcode is signed in with is to be used.
#
#   APP_STORE_CONNECT_KEY     the key file, AuthKey_<key id>.p8
#   APP_STORE_CONNECT_ISSUER  the issuer ID shown above the list of keys
set --
if [ -n "${APP_STORE_CONNECT_KEY:-}" ]; then
    [ -f "$APP_STORE_CONNECT_KEY" ] || {
        echo "APP_STORE_CONNECT_KEY names no file: $APP_STORE_CONNECT_KEY" >&2; exit 1; }
    [ -n "${APP_STORE_CONNECT_ISSUER:-}" ] || {
        echo "Set APP_STORE_CONNECT_ISSUER to the key's issuer ID as well." >&2; exit 1; }
    # xcodebuild wants the whole path, and the key's ID is in its file name.
    key_path="$(cd "$(dirname "$APP_STORE_CONNECT_KEY")" && pwd)/$(basename "$APP_STORE_CONNECT_KEY")"
    key_id="$(basename "$APP_STORE_CONNECT_KEY" .p8)"
    set -- -authenticationKeyPath "$key_path" \
        -authenticationKeyID "${key_id#AuthKey_}" \
        -authenticationKeyIssuerID "$APP_STORE_CONNECT_ISSUER"
fi
