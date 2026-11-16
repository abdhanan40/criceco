import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Where the backend's email links (password recovery, AUTH-04) and Google
/// sign-in (AUTH-05) return to. Every value here must be on the Supabase
/// project's Authentication → URL Configuration → Redirect URLs list.
///
/// Android: the app's own scheme, opened by the intent filter in
/// `android/app/src/main/AndroidManifest.xml`. Web: the app's own address
/// (`Supabase.initialize` reads the result from the page's URL).
const kAuthCallbackScheme = 'com.criceco.criceco';
const kAuthCallbackHost = 'login-callback';
const kNativeAuthCallbackUrl = '$kAuthCallbackScheme://$kAuthCallbackHost';

/// The callback for this platform.
String authCallbackUrl({bool web = kIsWeb, Uri? base}) =>
    web ? '${(base ?? Uri.base).origin}/' : kNativeAuthCallbackUrl;

final authCallbackUrlProvider = Provider<String>((ref) => authCallbackUrl());
