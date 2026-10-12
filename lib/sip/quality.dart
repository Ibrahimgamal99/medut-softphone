/// Call quality grade 0–4, as in Echo: MOS and the network weighed together,
/// so the bars, the word and their colour always agree.
///
/// 4 excellent · 3 good · 2 fair · 1 poor · 0 checking (no sample yet).
/// The network side is judged against the usual VoIP targets: round trip
/// under 150 ms, jitter under 20 ms, loss under 1 %. Missing a target counts
/// once, missing it twice over counts twice.
int callQualityLevel({double? mos, double? rttMs, double? jitterMs, double? lossPct}) {
  final int? byMos = mos == null || mos <= 0
      ? null
      : mos >= 4.3
          ? 4
          : mos >= 3.6
              ? 3
              : mos >= 3.1
                  ? 2
                  : 1;
  var measured = 0;
  var misses = 0;
  void judge(double? v, double target) {
    if (v == null) return;
    measured++;
    if (v >= target * 2) {
      misses += 2;
    } else if (v >= target) {
      misses += 1;
    }
  }

  judge(rttMs, 150);
  judge(jitterMs, 20);
  judge(lossPct, 1);
  final int? byNetwork = measured == 0 ? null : (misses == 0 ? 4 : (misses == 1 ? 2 : 1));
  // Excellent needs a MOS: clean counters alone are not evidence of one.
  if (byMos == null) return byNetwork == null ? 0 : (byNetwork > 3 ? 3 : byNetwork);
  if (byNetwork == null) return byMos;
  return byMos < byNetwork ? byMos : byNetwork;
}

/// Translation key for the grade's word.
String qualityWordKey(int level) => switch (level) {
      4 => 'signalExcellent',
      3 => 'signalGood',
      2 => 'signalFair',
      1 => 'signalPoor',
      _ => 'signalChecking',
    };
