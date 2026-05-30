import 'package:flutter/widgets.dart';
import 'allstak.dart';

/// Drops an AllStak `navigation` breadcrumb every time a route is pushed or
/// popped. Attach to your MaterialApp via `navigatorObservers: [AllStakNavigatorObserver()]`.
class AllStakNavigatorObserver extends NavigatorObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _crumb('push', route, previousRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _crumb('pop', route, previousRoute);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _crumb('replace', newRoute, oldRoute);
  }

  void _crumb(String kind, Route<dynamic>? to, Route<dynamic>? from) {
    try {
      AllStak.instance?.addBreadcrumb(
        'navigation',
        'Route $kind: ${from?.settings.name ?? '?'} → ${to?.settings.name ?? '?'}',
        data: {
          'from': from?.settings.name,
          'to': to?.settings.name,
          'kind': kind,
        },
      );
    } catch (_) {}
  }
}
