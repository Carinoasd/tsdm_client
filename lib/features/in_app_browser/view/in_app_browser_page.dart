import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/in_app_browser/utils/forum_cookies.dart';
import 'package:tsdm_client/features/in_app_browser/utils/link_routing.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/utils/browser_launcher.dart';
import 'package:tsdm_client/utils/clipboard.dart';
import 'package:tsdm_client/utils/show_toast.dart';

enum _MenuAction { openExternal, copyUrl }

/// A web page in the app: the forum pages the app has no screen for, signed in with the account in use, and the other
/// links when the settings ask for it.
///
/// The web view's forum cookies are replaced by those of the account in use before the first page loads, so the page
/// is never shown as an earlier account. A forum page the app has a screen for, followed from here, opens in the app.
class InAppBrowserPage extends StatefulWidget {
  /// Constructor.
  const InAppBrowserPage(this.url, {super.key});

  /// The page to open, absolute `http` or `https`.
  final Uri url;

  @override
  State<InAppBrowserPage> createState() => _InAppBrowserPageState();
}

class _InAppBrowserPageState extends State<InAppBrowserPage> {
  InAppWebViewController? _controller;

  /// The page in view.
  late Uri _url = widget.url;

  String? _title;

  /// Loading progress, 0 to 100.
  int _progress = 0;

  bool _canGoBack = false;
  bool _canGoForward = false;

  /// The page the browser was opened with has not loaded yet: its navigation (and redirects) is not taken to the app.
  bool _initialPending = true;

  /// Replace the forum cookies of the web view with the session of the account in use.
  Future<void> _prepareCookies() async {
    final manager = CookieManager.instance();
    try {
      for (final host in forumHosts) {
        for (final domain in forumCookieDomains) {
          await manager.deleteCookies(url: WebUri('https://$host/'), domain: domain);
        }
      }
      final provider = getIt.get<CookieProvider>();
      if (provider.userLoginInfo.uid == null) {
        return;
      }
      for (final c in await forumWebViewCookies(provider)) {
        await manager.setCookie(
          url: WebUri.uri(c.url),
          name: c.name,
          value: c.value,
          domain: c.domain,
          path: c.path,
          isSecure: c.secure,
          isHttpOnly: c.httpOnly,
        );
      }
    } on Object catch (e, st) {
      // The page still loads, as a guest.
      talker.handle(e, st, 'failed to prepare the forum cookies of the in-app browser');
    }
  }

  Future<void> _onCreated(InAppWebViewController controller) async {
    _controller = controller;
    await _prepareCookies();
    if (!mounted) {
      return;
    }
    await controller.loadUrl(urlRequest: URLRequest(url: WebUri.uri(widget.url)));
  }

  Future<NavigationActionPolicy> _onNavigation(InAppWebViewController controller, NavigationAction action) async {
    final url = action.request.url;
    if (url == null) {
      return NavigationActionPolicy.ALLOW;
    }
    final uri = Uri.tryParse('$url');
    if (uri == null) {
      return NavigationActionPolicy.CANCEL;
    }
    final mainFrame = action.isForMainFrame;
    // The page asked for and its redirects stay here, also when the app has a screen for them.
    switch (browserNavigationOf(uri, mainFrame: mainFrame, initial: _initialPending)) {
      case BrowserNavigationAllow():
        return NavigationActionPolicy.ALLOW;
      case BrowserNavigationOpenInApp():
        if (mounted) {
          unawaited(context.dispatchAsUrl('$uri'));
        }
        return NavigationActionPolicy.CANCEL;
      case BrowserNavigationExternal():
        // Only when the user followed the link: a page must not start other apps on its own.
        if (action.hasGesture ?? true) {
          unawaited(_openExternal(uri));
        }
        return NavigationActionPolicy.CANCEL;
    }
  }

  void _update(VoidCallback change) {
    if (mounted) {
      setState(change);
    }
  }

  Future<void> _updateHistory(InAppWebViewController controller, WebUri? url) async {
    final back = await controller.canGoBack();
    final forward = await controller.canGoForward();
    if (!mounted) {
      return;
    }
    setState(() {
      if (url != null) {
        _url = url.uriValue;
      }
      _canGoBack = back;
      _canGoForward = forward;
    });
  }

  Future<void> _openExternal(Uri uri) async {
    var launched = false;
    try {
      launched = await openInExternalBrowser(uri);
    } on Object catch (e, st) {
      talker.handle(e, st, 'failed to open the in-app browser page externally');
    }
    if (!launched && mounted) {
      showSnackBar(context: context, message: context.t.openInAppPage.browserLaunchFailed, clearPrevious: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.inAppBrowserPage;
    return PopScope(
      canPop: !_canGoBack,
      onPopInvokedWithResult: (didPop, _) async {
        if (!didPop) {
          await _controller?.goBack();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          leading: CloseButton(onPressed: () => Navigator.of(context).maybePop()),
          title: Text(_title?.isNotEmpty ?? false ? _title! : _url.host, maxLines: 1, overflow: TextOverflow.ellipsis),
          actions: [
            IconButton(
              icon: const Icon(Icons.arrow_back),
              tooltip: tr.back,
              onPressed: _canGoBack ? () async => _controller?.goBack() : null,
            ),
            IconButton(
              icon: const Icon(Icons.arrow_forward),
              tooltip: tr.forward,
              onPressed: _canGoForward ? () async => _controller?.goForward() : null,
            ),
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: tr.refresh,
              onPressed: () async => _controller?.reload(),
            ),
            PopupMenuButton<_MenuAction>(
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: _MenuAction.openExternal,
                  child: ListTile(leading: const Icon(Icons.open_in_browser), title: Text(tr.openExternal)),
                ),
                PopupMenuItem(
                  value: _MenuAction.copyUrl,
                  child: ListTile(leading: const Icon(Icons.copy_outlined), title: Text(tr.copyUrl)),
                ),
              ],
              onSelected: (action) async => switch (action) {
                _MenuAction.openExternal => _openExternal(_url),
                _MenuAction.copyUrl => copyToClipboard(context, '$_url'),
              },
            ),
          ],
          bottom: _progress < 100
              ? PreferredSize(
                  preferredSize: const Size.fromHeight(2),
                  child: LinearProgressIndicator(value: _progress == 0 ? null : _progress / 100, minHeight: 2),
                )
              : null,
        ),
        body: SafeArea(
          top: false,
          child: InAppWebView(
            initialSettings: InAppWebViewSettings(useShouldOverrideUrlLoading: true, useOnDownloadStart: true),
            onWebViewCreated: _onCreated,
            shouldOverrideUrlLoading: _onNavigation,
            onTitleChanged: (_, title) => _update(() => _title = title),
            onProgressChanged: (_, progress) => _update(() => _progress = progress),
            onLoadStop: (controller, url) async {
              _initialPending = false;
              await _updateHistory(controller, url);
            },
            onUpdateVisitedHistory: (controller, url, _) async => _updateHistory(controller, url),
            // The web view does not save files: downloads (attachments) go to the external browser.
            onDownloadStartRequest: (_, request) async => _openExternal(request.url.uriValue),
          ),
        ),
      ),
    );
  }
}
