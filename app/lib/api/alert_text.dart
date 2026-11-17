/// Plain-language alert copy (docs/product/indicators.md: no medical claims, compare with
/// the dog's own normal). Pure, unit-tested.
library;

import 'api_client.dart';
import 'day_summary.dart';

class AlertCopy {
  const AlertCopy(this.title, this.body);
  final String title;
  final String body;
}

AlertCopy alertCopy(AlertItem a, String dogName) {
  switch (a.metric) {
    case 'scratching':
      final ratio = a.median > 0 ? (a.value / a.median) : 0;
      final times = ratio >= 1.5
          ? '${ratio.toStringAsFixed(ratio >= 10 ? 0 : 1)}× '
          : '';
      return AlertCopy(
        'Scratched ${times}more than usual',
        '$dogName scratched for ${formatDuration(a.value.round())} on ${a.day}. '
            'His normal is about ${formatDuration(a.median.round())}. Worth checking his skin and ears.',
      );
    case 'activity':
      final low = a.direction == 'low';
      final pct = a.median > 0
          ? ((1 - a.value / a.median).abs() * 100).round()
          : 0;
      return AlertCopy(
        low ? 'Activity $pct% below normal' : 'Activity $pct% above normal',
        '$dogName was active for ${formatDuration(a.value.round())} on ${a.day}; '
        'his normal is about ${formatDuration(a.median.round())}.'
        '${low ? ' If he also seems tired or off for a few days, talk to your vet.' : ''}',
      );
    case 'night_wakeups':
      return AlertCopy(
        'Restless night',
        '$dogName got up ${a.value.round()} times during the night before ${a.day} '
            '(normal: about ${a.median.round()}).',
      );
    default:
      return AlertCopy(
        'Unusual day',
        '$dogName had an unusual ${a.metric} on ${a.day}.',
      );
  }
}
