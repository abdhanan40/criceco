// Removes a failed auth callback's parameters from the web app's address
// (AUTH-04/05), so a reload doesn't report the same failure again. The SDK
// clears them only after a success. A no-op off the web.
export 'auth_url_cleanup_stub.dart'
    if (dart.library.js_interop) 'auth_url_cleanup_web.dart';
