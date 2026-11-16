import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:camera/camera.dart' as cam;
import 'package:document_scan/document_scan.dart' as ds;
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:google_mlkit_document_scanner/google_mlkit_document_scanner.dart';
import 'package:image_picker/image_picker.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

// =====================================================================
//  إعدادات عامة
// =====================================================================

/// الأسماء والوحدات بتتبني جوه التطبيق من ملف data.xlsx وقت البناء (assets/data.json).
const kVersion = String.fromEnvironment('APP_VERSION', defaultValue: 'dev');

const kTagFont = 0.05; // حجم خط الورقة (نسبة من عرض الصورة)
const kTagTop = 0.03; // بُعد ورقة الباتش عن أعلى الصورة
const kBandPad = 0.02; // المسافة البيضاء حوالين الورقة في إيصالات الدفع
const kReceiptScanMode = ScannerMode.base; // قص فقط، والتحسين بيتعمل من التطبيق
const kBatchTagW = 0.7; // عرض الورقة في شريط الباتش (نسبة من عرض الصورة)
const kBatchBorder = 0.006; // سمك الإطار الأسود حوالين ورقة الباتش (نسبة من عرض الورقة)
const kBandGapNear = 0.004; // المسافة بين الورقة وصورة الباتش (الورقة لازقة في الصورة)
const kBandMaxScale = 1.3; // أقصى حجم للورقة في الشريط (أكتر من 1.0 = أعرض من الصورة وبتزيد هوامش بيضا على الجنب)
enum PerfMode { lite, balanced, pro }

/// الدقة الافتراضية لمعاينة الإيصال (نفس وضع balanced).
const kMaxSide = 1400;

/// سجل أخطاء بسيط في ملف (في مجلد منفصل عن الصور فمبيتمسحش مع التنظيف).
/// بيتبعت من زرار "إرسال سجل الأخطاء" في الإعدادات.
class AppLog {
  static File? _f;
  static const _max = 200 * 1024;

  static Future<void> init() async {
    try {
      final d = await getApplicationSupportDirectory();
      _f = File('${d.path}/a2r_log.txt');
    } catch (_) {}
  }

  static void e(String where, Object err, [StackTrace? st]) {
    final top = (st?.toString() ?? '')
        .split('\n')
        .where((l) => l.trim().isNotEmpty)
        .take(4)
        .join('\n');
    _write('[ERR] $where: $err${top.isEmpty ? '' : '\n$top'}');
  }

  /// علامة بتتكتب فورًا (متزامنة) عشان لو التطبيق اتقفل فجأة نعرف كان فين.
  static void i(String msg) => _write('[INF] $msg');

  static void _write(String line) {
    final f = _f;
    if (f == null) return;
    try {
      f.writeAsStringSync('${DateTime.now().toIso8601String()} v$kVersion $line\n',
          mode: FileMode.append, flush: true);
      if (f.lengthSync() > _max) {
        final t = f.readAsStringSync();
        f.writeAsStringSync(t.substring(t.length ~/ 2));
      }
    } catch (_) {}
  }

  static Future<void> share(BuildContext context) async {
    final f = _f;
    if (f == null || !f.existsSync() || f.lengthSync() == 0) {
      snack(context, 'السجل فاضي');
      return;
    }
    try {
      await Share.shareXFiles([XFile(f.path)]);
    } catch (_) {
      if (context.mounted) snack(context, 'تعذر إرسال السجل');
    }
  }
}

int getMaxSide(PerfMode mode) {
  switch (mode) {
    case PerfMode.lite:
      return 800;
    case PerfMode.balanced:
      return 1400;
    case PerfMode.pro:
      return 2400;
  }
}

// =====================================================================
//  البيانات (افتراضية مدمجة + تحديث من GitHub)
// =====================================================================

class Unit {
  final int num;
  final String name;
  final String tid;
  final List<String> buildings;
  const Unit(this.num, this.name, this.tid, [this.buildings = const []]);

  factory Unit.fromJson(Map<String, dynamic> j) => Unit(
        double.parse(j['num'].toString().trim()).toInt(),
        (j['name'] as String).trim(),
        j['tid'].toString().trim(),
        ((j['buildings'] as List?) ?? const []).map((e) => e.toString()).toList(),
      );

  /// اسم الوحدة للملفات: بدون همزات/أقواس، والمسافات نقط
  String get slug => name
      .replaceAll(RegExp('[أإآ]'), 'ا')
      .replaceAll(RegExp(r'[()\\/:*?"<>|]'), ' ')
      .trim()
      .split(RegExp(r'[\s.]+'))
      .join('.');
}

class Session {
  final String name;
  final Unit unit;
  final String? building;
  Session(this.name, this.unit, this.building);

  String get date {
    final n = DateTime.now();
    return '${n.day.toString().padLeft(2, '0')}/${n.month.toString().padLeft(2, '0')}/${n.year}';
  }

  /// مثال: 8.المنتزه.1.يوم.14.11
  String get pdfName {
    final n = DateTime.now();
    return '${unit.num}.${unit.slug}.يوم.${n.day}.${n.month}';
  }

  String get batchName => '${unit.num}';
}

const _defNames = <String>[
  'خالد محمد',
  'محمد السيد دندن',
  'احمد وليد',
  'محمد زكريا',
  'احمد مصطفى',
  'زياد أحمد',
  'مصطفى محمد',
  'ادهم ماهر',
  'احمد سعيد',
  'عبدالله محمد',
  'محمد مجدى',
  'سماح جمال',
  'امير حسين',
  'كريم صبرى',
  'احمد مجدى',
  'عمر فتحى',
  'محمد احمد',
  'احمد جابر',
  'باسم محمد',
  'باسم مصطفى',
  'احمد رمضان',
];

const _abis = ['تحت', 'فوق', 'المركز الزكي'];
const _borg = ['برج العرب', 'محرم بيك', 'ابيس', 'الرحلات', 'المنتزه'];
const _montaza = ['الاداري تحت', 'الاداري فوق', 'المركز الزكي'];
const _moharam = ['محرم بيك', 'محرم بيك 1', 'محرم بيك 2'];
const _agami = ['العجمي', 'الملاكي'];
const _qabbari = ['النقل'];

const _defUnits = <Unit>[
  Unit(1, 'أبيس 1', '50335710', _abis),
  Unit(2, 'أبيس 2', '50335993', _abis),
  Unit(3, 'أبيس 3', '50335987', _abis),
  Unit(4, 'برج العرب 1', '50325716', _borg),
  Unit(5, 'برج العرب 2', '50335998', _borg),
  Unit(6, 'برج العرب 3', '50335994', _borg),
  Unit(7, 'برج العرب 4', '50335711', _borg),
  Unit(8, 'المنتزه 1', '50382298', _montaza),
  Unit(9, 'المنتزه 2', '50382315', _montaza),
  Unit(10, 'المنتزه 3', '50383712', _montaza),
  Unit(11, 'محرم بك 1', '50382306', _moharam),
  Unit(12, 'محرم بك 2', '50382316', _moharam),
  Unit(13, 'العجمي 1', '50382308', _agami),
  Unit(14, 'العجمي 2', '50383706', _agami),
  Unit(15, 'أبيس (احتياطي)', '50325765', _abis),
  Unit(16, 'برج العرب (احتياطي 1)', '50322364', _borg),
  Unit(17, 'برج العرب (احتياطي 2)', '50322361', _borg),
  Unit(18, 'المنتزه (احتياطي)', '50382150', _montaza),
  Unit(19, 'محرم بك (احتياطي)', '50381092', _moharam),
  Unit(20, 'العجمي (احتياطي)', '50381077', _agami),
  Unit(21, 'القباري', '50382300', _qabbari),
  Unit(22, 'مصطفى كامل', '50383702'),
  Unit(23, 'مديرية الأمن', '50382312'),
  Unit(24, 'ميناء الإسكندرية', '50383699'),
  Unit(25, 'خدمات مصر', '50383700'),
];

/// البيانات الحالية: بتبدأ بالمدمجة وبعدين بتتحمّل من ملف الإكسل (assets/data.json).
/// لو الملف فيه غلط، التطبيق يكمل بالبيانات المدمجة.
class AppData {
  static List<String> names = List.of(_defNames);
  static List<Unit> units = List.of(_defUnits);
  static final ValueNotifier<int> rev = ValueNotifier(0);
  static final ValueNotifier<String> status = ValueNotifier('بيانات مدمجة');

  static bool _apply(String raw) {
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final n = (j['names'] as List)
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .toList();
      final u = (j['units'] as List)
          .map((e) => Unit.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
      if (n.isEmpty || u.isEmpty) return false;
      if (u.any((x) => x.name.isEmpty || x.tid.isEmpty)) return false;
      names = n;
      units = u;
      rev.value++;
      return true;
    } catch (e, st) {
      AppLog.e('_apply', e, st);
      return false;
    }
  }

  /// بيحمّل البيانات من ملف الإكسل اللي اتحوّل وقت البناء. لو فيه مشكلة بيكمل بالبيانات المدمجة.
  static Future<void> load() async {
    try {
      final raw = await rootBundle.loadString('assets/data.json');
      if (_apply(raw)) status.value = 'بيانات من ملف الإكسل';
    } catch (e, st) {
      AppLog.e('load', e, st);
    }
  }
}

// =====================================================================
//  أدوات الصور (خفيفة على الذاكرة)
// =====================================================================

// الفلتر بيتخزن بالرقم (index) في الإعدادات وفي EditParams: الأربعة الأولانيين مايتحركوش من مكانهم،
// وأي فلتر جديد بيتضاف في الآخر بس، عشان الصور والإعدادات القديمة تفضل شغالة.
enum ScanFilter {
  original,
  enhance,
  bw,
  receipt,
  gray,
  lighten,
  magic,
  document,
  sharpen,
  thermal,
  receiptBw,
  auto,
}

/// ترتيب وأسماء الفلاتر في الشاشة (الإيصالات الأول لأنها الأهم).
const kFilterOrder = <ScanFilter>[
  ScanFilter.original,
  ScanFilter.receipt,
  ScanFilter.thermal,
  ScanFilter.receiptBw,
  ScanFilter.auto,
  ScanFilter.enhance,
  ScanFilter.magic,
  ScanFilter.document,
  ScanFilter.bw,
  ScanFilter.gray,
  ScanFilter.lighten,
  ScanFilter.sharpen,
];

const kFilterLabels = <ScanFilter, String>{
  ScanFilter.original: 'أصلي',
  ScanFilter.receipt: 'إيصال',
  ScanFilter.thermal: 'حراري باهت',
  ScanFilter.receiptBw: 'إيصال أ/س',
  ScanFilter.auto: 'تلقائي',
  ScanFilter.enhance: 'تحسين',
  ScanFilter.magic: 'ألوان',
  ScanFilter.document: 'مستند',
  ScanFilter.bw: 'أ/س',
  ScanFilter.gray: 'رمادي',
  ScanFilter.lighten: 'تفتيح',
  ScanFilter.sharpen: 'حدة',
};

/// فلاتر الإيصال: بتعدي على _cleanJob (تقدير لون الورق وقسمة الصورة عليه) قبل أي مصفوفة ألوان.
bool isCleanFilter(ScanFilter f) =>
    f == ScanFilter.receipt || f == ScanFilter.thermal || f == ScanFilter.receiptBw;

/// الحراري الباهت وإيصال الأبيض والأسود بيستخدموا منحنى أقوى عشان الكتابة الخفيفة متختفيش.
bool usesThermalClean(ScanFilter f) => f == ScanFilter.thermal || f == ScanFilter.receiptBw;

/// قوة الحدة الفعلية: فلتر "حدة" بيضمن حد أدنى حتى لو السلايدر على صفر.
double effSharpness(ScanFilter f, double s) => f == ScanFilter.sharpen ? math.max(s, 0.7) : s;

/// شريط الفلاتر (بيتمرر أفقياً) ومشترك بين المحرر وشاشة الإيصالات.
class FilterBar extends StatelessWidget {
  final ScanFilter selected;
  final ValueChanged<ScanFilter>? onChanged;
  const FilterBar({super.key, required this.selected, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (final f in kFilterOrder)
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 6),
              child: ChoiceChip(
                label: Text(kFilterLabels[f] ?? f.name),
                selected: f == selected,
                onSelected: onChanged == null ? null : (_) => onChanged!(f),
              ),
            ),
        ],
      ),
    );
  }
}

String errText(Object e) {
  if (e is FileSystemException && (e.osError?.errorCode == 28)) {
    return 'مساحة التليفون ممتلئة، امسح ملفات وجرب تاني';
  }
  final s = e.toString();
  return s.startsWith('Exception: ') ? s.substring(11) : s;
}

/// بايتات ByteData بالظبط (من غير ما نسحب باقي الـ buffer لو الـ view مش كل الـ buffer).
Uint8List _bytesOf(ByteData bd) => bd.buffer.asUint8List(bd.offsetInBytes, bd.lengthInBytes);

Future<ui.Image> _imageFromRgba(Uint8List rgba, int w, int h) {
  final c = Completer<ui.Image>();
  ui.decodeImageFromPixels(rgba, w, h, ui.PixelFormat.rgba8888, c.complete);
  return c.future;
}

/// مصفوفة الألوان على الـ CPU (من غير رسم GPU) عشان الصورة متتشوهش.
Uint8List _matrixJob(Map<String, dynamic> a) {
  final src = a['src'] as Uint8List;
  final m = (a['m'] as List).cast<double>();
  final out = Uint8List(src.length);
  double cl(double v) => v < 0 ? 0 : (v > 255 ? 255 : v);
  for (var i = 0; i + 3 < src.length; i += 4) {
    final r = src[i].toDouble(), g = src[i + 1].toDouble(), b = src[i + 2].toDouble();
    out[i] = cl(m[0] * r + m[1] * g + m[2] * b + m[4]).round();
    out[i + 1] = cl(m[5] * r + m[6] * g + m[7] * b + m[9]).round();
    out[i + 2] = cl(m[10] * r + m[11] * g + m[12] * b + m[14]).round();
    out[i + 3] = 255;
  }
  return out;
}

/// حدة (Unsharp 3x3) على الـ CPU في Isolate. k من 0 لـ 1.
Uint8List _sharpenJob(Map<String, dynamic> a) {
  final src = a['src'] as Uint8List;
  final w = a['w'] as int, h = a['h'] as int;
  final k = ((a['k'] as num).toDouble() * 0.8).clamp(0.0, 0.9).toDouble();
  final out = Uint8List.fromList(src);
  final row = w * 4;
  for (var y = 1; y < h - 1; y++) {
    for (var x = 1; x < w - 1; x++) {
      final i = (y * w + x) * 4;
      for (var c = 0; c < 3; c++) {
        final j = i + c;
        final v = src[j] * (1 + 4 * k) - k * (src[j - 4] + src[j + 4] + src[j - row] + src[j + row]);
        out[j] = v < 0 ? 0 : (v > 255 ? 255 : v.round());
      }
    }
  }
  return out;
}

/// مستويات "التحسين التلقائي": أدنى قيمة للحبر، وأعلى قيمة لكل قناة (لون الورق) من نسخة مصغرة جداً (160px).
/// بيرجّع [أدنى، أعلى R، أعلى G، أعلى B] أو null.
Future<List<double>?> autoLevelsOf(Uint8List bytes) async {
  try {
    final img = await decodeImage(bytes, maxWidth: 160);
    final bd = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    img.dispose();
    if (bd == null) return null;
    final px = _bytesOf(bd);
    final n = px.length ~/ 4;
    if (n < 16) return null;
    final hl = List<int>.filled(256, 0);
    final hc = List.generate(3, (_) => List<int>.filled(256, 0));
    for (var i = 0; i < n; i++) {
      final r = px[i * 4], g = px[i * 4 + 1], b = px[i * 4 + 2];
      hl[(r * 54 + g * 183 + b * 19) >> 8]++;
      hc[0][r]++;
      hc[1][g]++;
      hc[2][b]++;
    }
    int pct(List<int> h, double p) {
      final target = (n * p).floor();
      var acc = 0;
      for (var t = 0; t < 256; t++) {
        acc += h[t];
        if (acc >= target) return t;
      }
      return 255;
    }

    final lo = pct(hl, 0.01).clamp(0, 90).toInt();
    final out = <double>[lo.toDouble()];
    for (var c = 0; c < 3; c++) {
      out.add(pct(hc[c], 0.85).clamp(lo + 70, 255).toDouble());
    }
    return out;
  } catch (e, st) {
    AppLog.e('autoLevelsOf', e, st);
    return null;
  }
}

/// قص الهوامش البيضاء الفاضية (بعد تنضيف الإيصال). بيرجّع {out, w, h}، أو {w: 0} لو مفيش داعي للقص.
Map<String, dynamic> _trimJob(Map<String, dynamic> a) {
  final src = a['src'] as Uint8List;
  final w = a['w'] as int, h = a['h'] as int;
  final rows = List<int>.filled(h, 0), cols = List<int>.filled(w, 0);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 4;
      if (src[i] + src[i + 1] + src[i + 2] < 3 * 235) {
        rows[y]++;
        cols[x]++;
      }
    }
  }
  var y0 = 0, y1 = h - 1, x0 = 0, x1 = w - 1;
  while (y0 < h && rows[y0] < 2) {
    y0++;
  }
  while (y1 > y0 && rows[y1] < 2) {
    y1--;
  }
  while (x0 < w && cols[x0] < 2) {
    x0++;
  }
  while (x1 > x0 && cols[x1] < 2) {
    x1--;
  }
  if (y0 >= y1 || x0 >= x1) return <String, dynamic>{'w': 0};
  final px = math.max(6, (w * 0.03).round()), py = math.max(6, (h * 0.02).round());
  x0 = math.max(0, x0 - px);
  x1 = math.min(w - 1, x1 + px);
  y0 = math.max(0, y0 - py);
  y1 = math.min(h - 1, y1 + py);
  final nw = x1 - x0 + 1, nh = y1 - y0 + 1;
  // لو الناتج صغير جداً (الصورة فاضية تقريباً) أو مفيش هوامش تستاهل: منقصش
  if (nw < w * 0.2 || nh < h * 0.1 || nw * nh > w * h * 0.97) return <String, dynamic>{'w': 0};
  final out = Uint8List(nw * nh * 4);
  for (var y = 0; y < nh; y++) {
    final s = ((y + y0) * w + x0) * 4;
    out.setRange(y * nw * 4, (y + 1) * nw * 4, src, s);
  }
  return <String, dynamic>{'out': out, 'w': nw, 'h': nh};
}

Uint8List _rotateJob(Map<String, dynamic> a) {
  final src = a['src'] as Uint8List;
  final w = a['w'] as int, h = a['h'] as int, t = a['t'] as int;
  final ow = t.isOdd ? h : w, oh = t.isOdd ? w : h;
  final out = Uint8List(ow * oh * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var nx = 0, ny = 0;
      if (t == 1) {
        nx = h - 1 - y;
        ny = x;
      } else if (t == 2) {
        nx = w - 1 - x;
        ny = h - 1 - y;
      } else {
        nx = y;
        ny = w - 1 - x;
      }
      final si = (y * w + x) * 4, di = (ny * ow + nx) * 4;
      out[di] = src[si];
      out[di + 1] = src[si + 1];
      out[di + 2] = src[si + 2];
      out[di + 3] = 255;
    }
  }
  return out;
}

Future<ui.Image> decodeImage(Uint8List b, {int? maxWidth}) async {
  final c = await ui.instantiateImageCodec(b, targetWidth: maxWidth);
  final f = await c.getNextFrame();
  c.dispose();
  return f.image;
}

/// أبعاد الصورة من غير ما نفك ضغطها (سريع وبيوفر ذاكرة).
Future<({int w, int h})> imageSize(Uint8List bytes) async {
  final buf = await ui.ImmutableBuffer.fromUint8List(bytes);
  try {
    final d = await ui.ImageDescriptor.encoded(buf);
    final r = (w: d.width, h: d.height);
    d.dispose();
    return r;
  } finally {
    buf.dispose();
  }
}

Future<double> imageAspect(String path) async {
  final s = await imageSize(await File(path).readAsBytes());
  return s.h / s.w;
}

/// مصفوفة الألوان النهائية: الفلتر الأساسي + تباين وسطوع (نفس المصفوفة للمعاينة وللحفظ).
/// y = k * (w·rgb + t0 - 127.5) + 127.5 + سطوع.  lv = مستويات "التلقائي": [أدنى، أعلى R، أعلى G، أعلى B].
List<double> editMatrix(ScanFilter f, double contrast, double brightness, [List<double>? lv]) {
  late List<List<double>> w;
  late List<double> t0; // إزاحة لكل قناة (R,G,B)
  const lr = 0.2126, lg = 0.7152, lb = 0.0722;

  List<List<double>> sat(double s, double c) => [
        [c * (lr * (1 - s) + s), c * lg * (1 - s), c * lb * (1 - s)],
        [c * lr * (1 - s), c * (lg * (1 - s) + s), c * lb * (1 - s)],
        [c * lr * (1 - s), c * lg * (1 - s), c * (lb * (1 - s) + s)],
      ];

  switch (f) {
    case ScanFilter.original:
    case ScanFilter.receipt: // المعالجة الحقيقية في _cleanJob، والمصفوفة هنا للتباين والسطوع بس
    case ScanFilter.thermal:
    case ScanFilter.sharpen: // الحدة بتتطبق في _sharpenJob
      w = [
        [1.0, 0.0, 0.0],
        [0.0, 1.0, 0.0],
        [0.0, 0.0, 1.0],
      ];
      t0 = [0.0, 0.0, 0.0];
      break;
    case ScanFilter.enhance:
      {
        const c = 1.3;
        w = [
          [c, 0.0, 0.0],
          [0.0, c, 0.0],
          [0.0, 0.0, c],
        ];
        t0 = List<double>.filled(3, 127.5 * (1 - c) + 10);
        break;
      }
    case ScanFilter.bw:
      {
        // أبيض وأسود عالي التباين (مناسب للإيصالات الحرارية الباهتة)
        const c = 1.7;
        const r = lr * c, g = lg * c, b = lb * c;
        w = [
          [r, g, b],
          [r, g, b],
          [r, g, b],
        ];
        t0 = List<double>.filled(3, 127.5 * (1 - c) + 40);
        break;
      }
    case ScanFilter.gray:
      w = [
        [lr, lg, lb],
        [lr, lg, lb],
        [lr, lg, lb],
      ];
      t0 = [0.0, 0.0, 0.0];
      break;
    case ScanFilter.lighten:
      {
        const c = 1.1;
        w = [
          [c, 0.0, 0.0],
          [0.0, c, 0.0],
          [0.0, 0.0, c],
        ];
        t0 = List<double>.filled(3, 38.0);
        break;
      }
    case ScanFilter.magic:
      {
        // ألوان أنشط وتباين أعلى
        const c = 1.2;
        w = sat(1.4, c);
        t0 = List<double>.filled(3, 127.5 * (1 - c) + 12);
        break;
      }
    case ScanFilter.document:
      {
        // ألوان أهدى وورق أنصع ونص أغمق
        const c = 1.35;
        w = sat(0.75, c);
        t0 = List<double>.filled(3, 127.5 * (1 - c) + 22);
        break;
      }
    case ScanFilter.receiptBw:
      {
        // بعد تنضيف الإيصال: أبيض وأسود بانتقال ناعم (مش قطع حاد) عشان الأرقام الصغيرة متتقطعش
        const lo = 150.0, hi = 215.0, s = 255 / (hi - lo);
        w = [
          [lr * s, lg * s, lb * s],
          [lr * s, lg * s, lb * s],
          [lr * s, lg * s, lb * s],
        ];
        t0 = List<double>.filled(3, -lo * s);
        break;
      }
    case ScanFilter.auto:
      {
        final l = (lv != null && lv.length == 4) ? lv : const <double>[0.0, 255.0, 255.0, 255.0];
        final lo = l[0];
        double sc(int c) => 255 / math.max(40.0, l[1 + c] - lo);
        w = [
          [sc(0), 0.0, 0.0],
          [0.0, sc(1), 0.0],
          [0.0, 0.0, sc(2)],
        ];
        t0 = [-sc(0) * lo, -sc(1) * lo, -sc(2) * lo];
        break;
      }
  }
  final k = 1 + contrast;
  return [
    for (var i = 0; i < 3; i++) ...[
      k * w[i][0],
      k * w[i][1],
      k * w[i][2],
      0.0,
      k * (t0[i] - 127.5) + 127.5 + brightness * 100,
    ],
    0.0, 0.0, 0.0, 1.0, 0.0, // صف الشفافية: ColorFilter.matrix لازم 20 رقم وإلا التطبيق يقفل
  ];
}

/// فلتر "إيصال": بيقسم الصورة بلاطات، يقدّر لون الورق في كل بلاطة (أفتح 20%)،
/// ويقسم الصورة عليه. النتيجة: ورق أبيض متساوي، الأزرق/الظلال بتروح، الحبر يفضل واضح.
/// بيشتغل في Isolate.
Uint8List _cleanJob(Map<String, dynamic> a) {
  final src = a['src'] as Uint8List;
  final w = a['w'] as int, h = a['h'] as int;
  final gray = a['gray'] as bool;
  final th = (a['th'] as bool?) ?? false; // حراري باهت: منحنى أقوى وحدة أعلى
  final bs = math.max(16, (math.max(w, h) / 40).round());
  final gw = (w + bs - 1) ~/ bs, gh = (h + bs - 1) ~/ bs;
  final bg = List.generate(3, (_) => List<double>.filled(gw * gh, 255.0));
  final hist = List<int>.filled(256, 0);

  for (var gy = 0; gy < gh; gy++) {
    for (var gx = 0; gx < gw; gx++) {
      final x0 = gx * bs, y0 = gy * bs;
      final x1 = math.min(w, x0 + bs), y1 = math.min(h, y0 + bs);
      hist.fillRange(0, 256, 0);
      for (var y = y0; y < y1; y++) {
        var i = (y * w + x0) * 4;
        for (var x = x0; x < x1; x++, i += 4) {
          hist[(src[i] * 54 + src[i + 1] * 183 + src[i + 2] * 19) >> 8]++;
        }
      }
      final target = ((x1 - x0) * (y1 - y0) * 0.8).floor();
      var acc = 0, thr = 255;
      for (var t = 0; t < 256; t++) {
        acc += hist[t];
        if (acc >= target) {
          thr = t;
          break;
        }
      }
      var sr = 0, sg = 0, sb = 0, n = 0;
      for (var y = y0; y < y1; y++) {
        var i = (y * w + x0) * 4;
        for (var x = x0; x < x1; x++, i += 4) {
          if (((src[i] * 54 + src[i + 1] * 183 + src[i + 2] * 19) >> 8) >= thr) {
            sr += src[i];
            sg += src[i + 1];
            sb += src[i + 2];
            n++;
          }
        }
      }
      if (n > 0) {
        final k = gy * gw + gx;
        bg[0][k] = sr / n;
        bg[1][k] = sg / n;
        bg[2][k] = sb / n;
      }
    }
  }

  List<double> blur(List<double> g) {
    final o = List<double>.filled(g.length, 0);
    for (var y = 0; y < gh; y++) {
      for (var x = 0; x < gw; x++) {
        var s = 0.0;
        for (var dy = -1; dy <= 1; dy++) {
          for (var dx = -1; dx <= 1; dx++) {
            final yy = (y + dy).clamp(0, gh - 1).toInt();
            final xx = (x + dx).clamp(0, gw - 1).toInt();
            s += g[yy * gw + xx];
          }
        }
        o[y * gw + x] = s / 9;
      }
    }
    return o;
  }

  for (var c = 0; c < 3; c++) {
    bg[c] = blur(blur(bg[c]));
  }

  // أي قيمة من 238 لفوق = أبيض صافي (بيضغط أحسن بكتير)، وجاما خفيفة بتغمّق الحبر
  final wp = th ? 245.0 : 238.0, gam = th ? 2.0 : 1.25;
  final lut = List<int>.generate(
      256, (i) => (255 * math.pow(math.min(1.0, i / wp), gam)).round().clamp(0, 255).toInt());

  final cx0 = List<int>.filled(w, 0), cx1 = List<int>.filled(w, 0);
  final ctx = List<double>.filled(w, 0);
  for (var x = 0; x < w; x++) {
    final fx = ((x + 0.5) / bs - 0.5).clamp(0.0, gw - 1.0).toDouble();
    cx0[x] = fx.floor();
    cx1[x] = math.min(gw - 1, cx0[x] + 1);
    ctx[x] = fx - cx0[x];
  }

  final out = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    final fy = ((y + 0.5) / bs - 0.5).clamp(0.0, gh - 1.0).toDouble();
    final y0 = fy.floor();
    final y1 = math.min(gh - 1, y0 + 1);
    final ty = fy - y0;
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 4;
      final tx = ctx[x];
      final a0 = y0 * gw + cx0[x], a1 = y0 * gw + cx1[x];
      final b0 = y1 * gw + cx0[x], b1 = y1 * gw + cx1[x];
      final res = [0, 0, 0];
      for (var c = 0; c < 3; c++) {
        final g = bg[c];
        final b = (g[a0] * (1 - tx) + g[a1] * tx) * (1 - ty) + (g[b0] * (1 - tx) + g[b1] * tx) * ty;
        var v = src[i + c] * 255 / (b < 40 ? 40 : b);
        if (v > 255) v = 255;
        res[c] = lut[v.round()];
      }
      if (gray) {
        final l = (res[0] * 54 + res[1] * 183 + res[2] * 19) >> 8;
        res[0] = res[1] = res[2] = l;
      }
      out[i] = res[0];
      out[i + 1] = res[1];
      out[i + 2] = res[2];
      out[i + 3] = 255;
    }
  }

  // حدة خفيفة (Unsharp) تحسّن النص المهتز شوية
  final k = th ? 0.6 : 0.35;
  final cp = Uint8List.fromList(out);
  final row = w * 4;
  for (var y = 1; y < h - 1; y++) {
    for (var x = 1; x < w - 1; x++) {
      final i = (y * w + x) * 4;
      for (var c = 0; c < 3; c++) {
        final j = i + c;
        final v = cp[j] * (1 + 4 * k) - k * (cp[j - 4] + cp[j + 4] + cp[j - row] + cp[j + row]);
        out[j] = v < 0 ? 0 : (v > 255 ? 255 : v.round());
      }
    }
  }
  return out;
}

/// بتطبّق فلتر الإيصال على ui.Image وبترجّع صورة جديدة (الأصلية مبتتمسحش).
Future<ui.Image> cleanUiImage(ui.Image img, {bool gray = false, bool thermal = false}) async {
  final w = img.width, h = img.height;
  final bd = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (bd == null) throw Exception('تعذر قراءة الصورة');
  final rgba = await compute(_cleanJob, <String, dynamic>{
    'src': bd.buffer.asUint8List(bd.offsetInBytes, bd.lengthInBytes),
    'w': w,
    'h': h,
    'gray': gray,
    'th': thermal,
  });
  final comp = Completer<ui.Image>();
  ui.decodeImageFromPixels(rgba, w, h, ui.PixelFormat.rgba8888, comp.complete);
  return comp.future;
}

Future<Uint8List> applyFilter(Uint8List bytes, ScanFilter f) async {
  if (f == ScanFilter.original) return bytes;
  try {
    final img = await decodeImage(bytes);
    final w = img.width, h = img.height;
    ui.Image out;
    if (isCleanFilter(f)) {
      var c = await cleanUiImage(img, thermal: usesThermalClean(f));
      if (f == ScanFilter.receiptBw) {
        final raw = await c.toByteData(format: ui.ImageByteFormat.rawRgba);
        if (raw == null) throw Exception('تعذر قراءة الصورة');
        final bwRgba =
            await compute(_matrixJob, <String, dynamic>{'src': _bytesOf(raw), 'm': editMatrix(f, 0, 0)});
        c.dispose();
        c = await _imageFromRgba(bwRgba, w, h);
      }
      out = c;
    } else {
      final raw = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (raw == null) throw Exception('تعذر قراءة الصورة');
      final lv = f == ScanFilter.auto ? await autoLevelsOf(bytes) : null;
      var rgba = await compute(
          _matrixJob, <String, dynamic>{'src': _bytesOf(raw), 'm': editMatrix(f, 0, 0, lv)});
      if (f == ScanFilter.sharpen) {
        rgba = await compute(
            _sharpenJob, <String, dynamic>{'src': rgba, 'w': w, 'h': h, 'k': effSharpness(f, 0)});
      }
      out = await _imageFromRgba(rgba, w, h);
    }
    final bd = await out.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    out.dispose();
    return await FlutterImageCompress.compressWithList(
      _bytesOf(bd!),
      minWidth: w,
      minHeight: h,
      quality: await Store.jpegQuality(),
      format: CompressFormat.jpeg,
    );
  } catch (e, st) {
    AppLog.e('applyFilter', e, st);
    return bytes; // لو الفلتر فشل (ذاكرة) نكمل بالصورة الأصلية
  }
}

/// فحص سريع بعد التصوير: بيرجّع رسالة تحذير أو null لو الصورة تمام.
/// الأرقام بتتكتب في السجل (quality var / p90) عشان تضبط الحدود حسب موبايلات الموظفين.
Future<String?> qualityWarning(String path) async {
  try {
    final img = await decodeImage(await File(path).readAsBytes(), maxWidth: 800);
    final w = img.width, h = img.height;
    final bd = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    img.dispose();
    if (bd == null || w < 16 || h < 16) return null;
    final px = bd.buffer.asUint8List(bd.offsetInBytes, bd.lengthInBytes);
    final lum = Float32List(w * h);
    final hist = List<int>.filled(256, 0);
    for (var i = 0; i < w * h; i++) {
      final l = (px[i * 4] * 54 + px[i * 4 + 1] * 183 + px[i * 4 + 2] * 19) >> 8;
      lum[i] = l.toDouble();
      hist[l]++;
    }
    var acc = 0, p90 = 255;
    for (var t = 0; t < 256; t++) {
      acc += hist[t];
      if (acc >= w * h * 0.9) {
        p90 = t;
        break;
      }
    }
    var s = 0.0, s2 = 0.0, n = 0;
    for (var y = 1; y < h - 1; y++) {
      for (var x = 1; x < w - 1; x++) {
        final i = y * w + x;
        final v = 4 * lum[i] - lum[i - 1] - lum[i + 1] - lum[i - w] - lum[i + w];
        s += v;
        s2 += v * v;
        n++;
      }
    }
    final varL = n == 0 ? 999.0 : s2 / n - (s / n) * (s / n);
    AppLog.i('quality var=${varL.toStringAsFixed(1)} p90=$p90');
    if (p90 < 130) return 'الإضاءة ضعيفة، صوّر في مكان أنور';
    if (varL < 25) return 'الصورة شكلها مهزوزة، ثبّت إيدك وصوّر تاني لو الكلام مش واضح';
    return null;
  } catch (e, st) {
    AppLog.e('qualityWarning', e, st);
    return null;
  }
}

Future<bool> _decodesOk(Uint8List b) async {
  try {
    final s = await imageSize(b);
    return s.w > 0 && s.h > 0;
  } catch (e, st) {
    AppLog.e('_decodesOk', e, st);
    return false;
  }
}

/// نسخ الصورة من مكان الماسح المؤقت لمكان ثابت كـ JPEG واحد مضغوط (مرة واحدة بس).
/// وبعدها بيتطبق الفلتر لو الموظف اختاره.
Future<String> persistImage(String src, String name,
    {ScanFilter filter = ScanFilter.original}) async {
  final swPersist = Stopwatch()..start();
  final mode = await Store.perfMode();
  final maxSide = getMaxSide(mode);
  Uint8List? bytes;
  try {
    bytes = await FlutterImageCompress.compressWithFile(
      src,
      minWidth: maxSide,
      minHeight: maxSide,
      quality: await Store.jpegQuality(),
      format: CompressFormat.jpeg,
      keepExif: false,
    );
  } catch (e, st) {
    AppLog.e('persistImage', e, st);
  }
  AppLog.i('t persist.compress ${swPersist.elapsedMilliseconds}ms');
  if (bytes != null && !await _decodesOk(bytes)) bytes = null;
  if (bytes == null) {
    try {
      final raw = await File(src).readAsBytes();
      final img = await decodeImage(raw, maxWidth: maxSide);
      final bd = await img.toByteData(format: ui.ImageByteFormat.png);
      final w = img.width, h = img.height;
      img.dispose();
      bytes = await FlutterImageCompress.compressWithList(
        _bytesOf(bd!),
        minWidth: w,
        minHeight: h,
        quality: await Store.jpegQuality(),
        format: CompressFormat.jpeg,
      );
    } catch (e, st) {
      AppLog.e('persistImage', e, st);
    }
  }
  if (bytes == null || !await _decodesOk(bytes)) {
    throw Exception('الصورة دي مش مدعومة، صوّرها تاني');
  }
  final f = File('${(await Store.dir()).path}/$name');
  if (filter != ScanFilter.original) {
    // نسخة من غير فلتر عشان التعديل بعد كده يبقى ممكن يرجّع الأصلي
    await File(Store.baseOf(f.path)).writeAsBytes(bytes, flush: true);
    await Store.setEdit(f.path, EditParams(filter: filter));
  }
  final tFilter = swPersist.elapsedMilliseconds;
  bytes = await applyFilter(bytes, filter);
  await f.writeAsBytes(bytes, flush: true);
  AppLog.i('t persist.filter ${swPersist.elapsedMilliseconds - tFilter}ms total ${swPersist.elapsedMilliseconds}ms');
  return f.path;
}

// =====================================================================
//  ورقة البيانات
// =====================================================================

String _isoLtr(String s) => '\u2066$s\u2069';

TextPainter _tp(String t, double fs, TextDirection d) => TextPainter(
      text: TextSpan(
          text: t,
          style: TextStyle(color: Colors.black, fontSize: fs, fontWeight: FontWeight.bold)),
      textDirection: d,
    )..layout();

class Tag {
  final Uint8List png;
  final double w, h;
  Tag(this.png, this.w, this.h);
}

/// مكان وحجم الورقة. كل الأرقام نسب من عرض الصورة.
class TagPos {
  final double cx, cy, s;
  const TagPos(this.cx, this.cy, this.s);

  static TagPos initial(Tag ref) {
    final s0 = ref.w / 1000;
    return TagPos(0.5, kTagTop + s0 * ref.h / ref.w / 2, s0);
  }

  TagPos copyWith({double? cx, double? cy, double? s}) =>
      TagPos(cx ?? this.cx, cy ?? this.cy, s ?? this.s);

  String encode() => '$cx,$cy,$s';

  static TagPos? decode(String? v) {
    if (v == null) return null;
    final p = v.split(',');
    if (p.length != 3) return null;
    final a = double.tryParse(p[0]), b = double.tryParse(p[1]), c = double.tryParse(p[2]);
    if (a == null || b == null || c == null) return null;
    if (!a.isFinite || !b.isFinite || !c.isFinite) return null;
    return TagPos(a.clamp(0.0, 1.0).toDouble(), b.clamp(0.0, 10.0).toDouble(),
        c.clamp(0.1, 0.98).toDouble());
  }
}

/// بتتأكد إن الورقة كلها جوه الصورة، حتى لو مكانها المحفوظ كان لصورة بأبعاد تانية.
TagPos fitTagPos(TagPos p, Tag t, double aspect) {
  final th = p.s * t.h / t.w; // ارتفاع الورقة كنسبة من عرض الصورة
  final cx = p.cx.clamp(p.s / 2, 1 - p.s / 2).toDouble();
  final cy = th >= aspect ? aspect / 2 : p.cy.clamp(th / 2, aspect - th / 2).toDouble();
  return p.copyWith(cx: cx, cy: cy);
}

/// فحص إن صورة الورقة سليمة: الورقة أبيض وأسود بس، فأي ألوان كتير أو غياب الأبيض = تشويه من الرسم.
Future<bool> _tagLooksOk(Uint8List png) async {
  try {
    final img = await decodeImage(png);
    final w = img.width, h = img.height;
    final bd = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    img.dispose();
    if (bd == null) return false;
    final px = _bytesOf(bd);
    var total = 0, color = 0, white = 0;
    for (var i = 0; i < w * h; i++) {
      final j = i * 4;
      if (px[j + 3] < 200) continue;
      total++;
      final r = px[j], g = px[j + 1], b = px[j + 2];
      final mx = math.max(r, math.max(g, b)), mn = math.min(r, math.min(g, b));
      if (mx - mn > 60) color++;
      if (mn > 200) white++;
    }
    if (total == 0) return false;
    return color / total < 0.005 && white / total > 0.15;
  } catch (e, st) {
    AppLog.e('_tagLooksOk', e, st);
    return true;
  }
}

/// بترسم الورقة وتتأكد إنها سليمة، ولو طلعت مشوّهة بتعيد الرسم (لحد 3 مرات).
Future<Tag> receiptTag(double w, Session s, {bool batch = false}) async {
  late Tag t;
  for (var i = 0; i < 3; i++) {
    t = await _renderTag(w, s, batch: batch);
    if (await _tagLooksOk(t.png)) return t;
    AppLog.i('tag garbled, retry ${i + 1}');
  }
  return t;
}

Future<Tag> _renderTag(double w, Session s, {bool batch = false}) async {
  final fs = w * kTagFont;
  final unitLine = s.building == null ? s.unit.name : '${s.unit.name} - ${s.building}';
  final l1 = _tp('${s.name}  |  $unitLine', fs, TextDirection.rtl);
  final l2 = _tp(
      batch ? _isoLtr(s.date) : '${_isoLtr('TID: ${s.unit.tid}')}  |  ${_isoLtr(s.date)}',
      fs,
      TextDirection.rtl);
  final pad = fs * 0.6;
  final gap = fs * 0.25;
  final textW = l1.width > l2.width ? l1.width : l2.width;
  final cw = (textW + pad * 2).clamp(0.0, w * 0.96).toDouble();
  final ch = l1.height + l2.height + gap + pad * 2;
  final rec = ui.PictureRecorder();
  final c = Canvas(rec, Rect.fromLTWH(0, 0, cw, ch));
  // الإطار بيتحط جوه حدود الصورة بنص سمكه، عشان يظهر كامل من الأربع اتجاهات (من غير ما يتقص)
  final sw = w * (batch ? kBatchBorder : 0.004);
  final inset = batch ? sw / 2 : 0.0;
  final rr = RRect.fromRectAndRadius(
      Rect.fromLTWH(inset, inset, cw - inset * 2, ch - inset * 2), Radius.circular(fs * 0.5));
  c.drawRRect(rr, Paint()..color = Colors.white);
  c.drawRRect(
      rr,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = sw
        ..color = Colors.black);
  l1.paint(c, Offset((cw - l1.width) / 2, pad));
  l2.paint(c, Offset((cw - l2.width) / 2, pad + l1.height + gap));
  final img = await rec.endRecording().toImage(cw.ceil(), ch.ceil());
  final bd = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  return Tag(_bytesOf(bd!), cw, ch);
}

/// ورقة الباتش بحجم الشريط. w = عرض الصورة بالبكسل.
Future<Tag> batchBandTag(Session s, double w) async {
  final k = await Store.bandScale();
  final r = await receiptTag(1000, s, batch: true);
  return receiptTag(1000 * (w * k) / r.w, s, batch: true);
}

/// تركيب الباتش بيتم كله على الـ CPU (Isolate) من غير رسم GPU، لأن الرسم الكبير على GPU
/// كان بيطلّع صورة مشوّهة (ألوان وبلاطات) على الموبايلات الضعيفة.
Uint8List _composeJob(Map<String, dynamic> a) {
  final img = a['img'] as Uint8List;
  final iw = a['iw'] as int, ih = a['ih'] as int;
  final tag = a['tag'] as Uint8List;
  final tw = a['tw'] as int, th = a['th'] as int;
  final ow = a['ow'] as int, oh = a['oh'] as int;
  final ix = a['ix'] as int, iy = a['iy'] as int;
  final tx = a['tx'] as int, ty = a['ty'] as int;
  final out = Uint8List(ow * oh * 4)..fillRange(0, ow * oh * 4, 255);
  final sx0 = math.max(0, -ix), sx1 = math.min(iw, ow - ix);
  if (sx1 > sx0) {
    for (var y = 0; y < ih; y++) {
      final dy = y + iy;
      if (dy < 0 || dy >= oh) continue;
      out.setRange((dy * ow + ix + sx0) * 4, (dy * ow + ix + sx1) * 4, img, (y * iw + sx0) * 4);
    }
  }
  for (var y = 0; y < th; y++) {
    final dy = y + ty;
    if (dy < 0 || dy >= oh) continue;
    for (var x = 0; x < tw; x++) {
      final dx = x + tx;
      if (dx < 0 || dx >= ow) continue;
      final si = (y * tw + x) * 4, di = (dy * ow + dx) * 4;
      final al = tag[si + 3];
      if (al == 0) continue;
      if (al == 255) {
        out[di] = tag[si];
        out[di + 1] = tag[si + 1];
        out[di + 2] = tag[si + 2];
      } else {
        // الألوان من rawRgba بتيجي premultiplied
        final k = 1 - al / 255;
        for (var c = 0; c < 3; c++) {
          final v = tag[si + c] + out[di + c] * k;
          out[di + c] = v > 255 ? 255 : v.round();
        }
      }
      out[di + 3] = 255;
    }
  }
  return out;
}

/// متوسط السطوع (عينات) لفحص إن الصورة النهائية مش مشوّهة.
double _meanLum(Uint8List px, int w, int h) {
  final n = w * h;
  final step = math.max(1, n ~/ 20000) | 1;
  var sum = 0.0, cnt = 0;
  for (var i = 0; i < n; i += step) {
    final j = i * 4;
    sum += (px[j] * 54 + px[j + 1] * 183 + px[j + 2] * 19) >> 8;
    cnt++;
  }
  return cnt == 0 ? 0.0 : sum / cnt;
}

Future<double?> _jpegMeanLum(Uint8List jpg) async {
  try {
    final img = await decodeImage(jpg, maxWidth: 96);
    final w = img.width, h = img.height;
    final bd = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    img.dispose();
    if (bd == null) return null;
    return _meanLum(bd.buffer.asUint8List(bd.offsetInBytes, bd.lengthInBytes), w, h);
  } catch (e, st) {
    AppLog.e('_jpegMeanLum', e, st);
    return null;
  }
}

/// صورة الباتش + الورقة. layout 1: شريط أبيض تحت الصورة (الصورة كاملة من غير تغطية)،
/// layout 2: الورقة فوق الصورة في المكان اللي الموظف اختاره.
Future<Uint8List> composeBatch(String path, Session s) async {
  final src = await File(path).readAsBytes();
  if (await Store.noTag(path)) return src; // من غير ورقة
  final layout = await Store.batchLayout();
  final sz = await imageSize(src);
  final maxSide = getMaxSide(await Store.perfMode());
  final img = await decodeImage(src, maxWidth: sz.w > maxSide ? maxSide : null);
  final iw = img.width, ih = img.height;
  final w = iw.toDouble(), h = ih.toDouble();
  final Tag tag;
  final Offset tagAt;
  int imgY = 0, imgX = 0;
  final int oh;
  int ow = iw;
  if (layout == 2) {
    final ref = await receiptTag(1000, s, batch: true);
    final pos = fitTagPos(await Store.pos(path) ?? TagPos.initial(ref), ref, h / w);
    tag = await receiptTag(1000 * (w * pos.s) / ref.w, s, batch: true);
    tagAt = Offset(pos.cx * w - tag.w / 2, pos.cy * w - tag.h / 2);
    oh = ih;
  } else {
    tag = await batchBandTag(s, w);
    final pad = w * kBandPad; // الهامش الخارجي
    final gap = w * kBandGapNear; // الهامش اللي بين الورقة والصورة (صغير)
    final band = tag.h + pad + gap;
    ow = math.max(iw, tag.w.ceil());
    imgX = ((ow - iw) / 2).round();
    tagAt = Offset((ow - tag.w) / 2, h + gap);
    imgY = 0;
    oh = ih + band.ceil();
  }
  final tImg = await decodeImage(tag.png);
  final tw = tImg.width, th = tImg.height;
  final imgBd = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
  final tagBd = await tImg.toByteData(format: ui.ImageByteFormat.rawRgba);
  img.dispose();
  tImg.dispose();
  if (imgBd == null || tagBd == null) throw Exception('تعذر قراءة الصورة');
  final rgba = await compute(_composeJob, <String, dynamic>{
    'img': imgBd.buffer.asUint8List(imgBd.offsetInBytes, imgBd.lengthInBytes),
    'iw': iw,
    'ih': ih,
    'tag': tagBd.buffer.asUint8List(tagBd.offsetInBytes, tagBd.lengthInBytes),
    'tw': tw,
    'th': th,
    'ow': ow,
    'oh': oh,
    'ix': imgX,
    'iy': imgY,
    'tx': tagAt.dx.round(),
    'ty': tagAt.dy.round(),
  });
  final comp = Completer<ui.Image>();
  ui.decodeImageFromPixels(rgba, ow, oh, ui.PixelFormat.rgba8888, comp.complete);
  final outImg = await comp.future;
  final pngBd = await outImg.toByteData(format: ui.ImageByteFormat.png);
  outImg.dispose();
  if (pngBd == null) throw Exception('تعذر حفظ الصورة');
  final png = pngBd.buffer.asUint8List(pngBd.offsetInBytes, pngBd.lengthInBytes);
  final q = await Store.jpegQuality();
  final want = _meanLum(rgba, ow, oh);
  // أول محاولة بالأبعاد الكاملة، ولو الناتج مشوّه نجرّب أبعاد أصغر، ولو برضه مشوّه منبعتش صورة بايظة
  for (final k in const [1.0, 0.75]) {
    final jpg = await FlutterImageCompress.compressWithList(
      png,
      minWidth: (ow * k).round(),
      minHeight: (oh * k).round(),
      quality: q,
      format: CompressFormat.jpeg,
    );
    final got = await _jpegMeanLum(jpg);
    AppLog.i('compose ${ow}x$oh k=$k ${jpg.length ~/ 1024}KB lum want=${want.toStringAsFixed(0)} '
        'got=${got?.toStringAsFixed(0)}');
    if (got != null && (got - want).abs() < 25) return jpg;
  }
  throw Exception('الصورة النهائية طلعت مشوّهة، جرّب وضع الأداء Lite من الإعدادات وابعت تاني');
}

/// صورة الإيصال النهائية للمشاركة: نفس صفحة الـ PDF (شريط أبيض فيه الورقة فوق الإيصال).
/// من غير ورقة (إخفاء الورقة) بترجع الصورة زي ما هي.
Future<Uint8List> composeReceiptImage(String path, Session s) async {
  final src = await File(path).readAsBytes();
  if (await Store.noTag(path)) return src;
  final sz = await imageSize(src);
  final maxSide = getMaxSide(await Store.perfMode());
  final img = await decodeImage(src, maxWidth: sz.w > maxSide ? maxSide : null);
  final iw = img.width, ih = img.height;
  final tag = await receiptTag(iw.toDouble(), s);
  final pad = iw * kBandPad;
  final band = (tag.h + pad * 2).ceil();
  final oh = ih + band;
  final tImg = await decodeImage(tag.png);
  final tw = tImg.width, th = tImg.height;
  final imgBd = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
  final tagBd = await tImg.toByteData(format: ui.ImageByteFormat.rawRgba);
  img.dispose();
  tImg.dispose();
  if (imgBd == null || tagBd == null) throw Exception('تعذر قراءة الصورة');
  final rgba = await compute(_composeJob, <String, dynamic>{
    'img': imgBd.buffer.asUint8List(imgBd.offsetInBytes, imgBd.lengthInBytes),
    'iw': iw,
    'ih': ih,
    'tag': tagBd.buffer.asUint8List(tagBd.offsetInBytes, tagBd.lengthInBytes),
    'tw': tw,
    'th': th,
    'ow': iw,
    'oh': oh,
    'ix': 0,
    'iy': band,
    'tx': ((iw - tag.w) / 2).round(),
    'ty': pad.round(),
  });
  final comp = Completer<ui.Image>();
  ui.decodeImageFromPixels(rgba, iw, oh, ui.PixelFormat.rgba8888, comp.complete);
  final outImg = await comp.future;
  final pngBd = await outImg.toByteData(format: ui.ImageByteFormat.png);
  outImg.dispose();
  if (pngBd == null) throw Exception('تعذر حفظ الصورة');
  final png = pngBd.buffer.asUint8List(pngBd.offsetInBytes, pngBd.lengthInBytes);
  final q = await Store.jpegQuality();
  final want = _meanLum(rgba, iw, oh);
  for (final k in const [1.0, 0.75]) {
    final jpg = await FlutterImageCompress.compressWithList(
      png,
      minWidth: (iw * k).round(),
      minHeight: (oh * k).round(),
      quality: q,
      format: CompressFormat.jpeg,
    );
    final got = await _jpegMeanLum(jpg);
    if (got != null && (got - want).abs() < 25) return jpg;
  }
  throw Exception('الصورة النهائية طلعت مشوّهة، جرّب وضع الأداء Lite من الإعدادات وابعت تاني');
}

/// PDF الإيصالات: كل صفحة = جزء أبيض فيه الورقة + صورة الإيصال الأصلية (JPEG بيتحط في الـ PDF زي ما هو
/// من غير إعادة رسم ولا إعادة ضغط، فالجودة أحسن والذاكرة أقل بكتير).
Future<File> buildReceiptsPdf(Session s, List<String> receipts,
    {void Function(int done, int total)? onProgress}) async {
  Store.working++;
  try {
    final doc = pw.Document();
    const pageW = 595.0;
    final tag = await receiptTag(1000, s);
    final tagImg = pw.MemoryImage(tag.png);
    final tw = pageW * tag.w / 1000;
    final th = pageW * tag.h / 1000;
    final pad = pageW * kBandPad;
    final bandH = th + pad * 2;
    final compact = (await Store.pdfSize()) == 1;
    for (var i = 0; i < receipts.length; i++) {
      onProgress?.call(i, receipts.length);
      var bytes = await File(receipts[i]).readAsBytes();
      if (compact) {
        // PDF مضغوط: نسخة أصغر (عرض ~720 وجودة 70) لو طلعت أخف وسليمة، وإلا بنستخدم الأصلية
        try {
          final c = await FlutterImageCompress.compressWithList(bytes,
              minWidth: 720, minHeight: 720, quality: 70, format: CompressFormat.jpeg);
          if (c.isNotEmpty && c.length < bytes.length && await _decodesOk(c)) bytes = c;
        } catch (e, st) {
          AppLog.e('pdf.compact', e, st);
        }
      }
      final sz = await imageSize(bytes);
      final imgH = pageW * sz.h / sz.w;
      final hide = await Store.noTag(receipts[i]);
      final pageH = (hide ? 0.0 : bandH) + imgH + 1;
      final image = pw.MemoryImage(bytes);
      doc.addPage(pw.Page(
        pageFormat: PdfPageFormat(pageW, pageH),
        margin: pw.EdgeInsets.zero,
        build: (_) => pw.Column(children: [
          if (!hide)
            pw.Container(
              width: pageW,
              height: bandH,
              alignment: pw.Alignment.center,
              child: pw.Image(tagImg, width: tw, height: th),
            ),
          pw.Image(image, width: pageW, height: imgH),
        ]),
      ));
      await Future.delayed(Duration.zero); // نسيب الواجهة تتنفس على التليفونات الضعيفة
    }
    onProgress?.call(receipts.length, receipts.length);
    final dir = await Store.dir();
    final file = File('${dir.path}/${s.pdfName}.pdf');
    await file.writeAsBytes(await doc.save(), flush: true);
    return file;
  } finally {
    Store.working--;
  }
}

// =====================================================================
//  التخزين
// =====================================================================

String _dayKey() {
  final n = DateTime.now();
  return '${n.year}-${n.month}-${n.day}';
}

class Store {
  static const pdfLife = Duration(hours: 24);
  static int working = 0; // عدد العمليات الشغالة (بتمنع التنظيف أثناءها)
  static Future<SharedPreferences> get _p => SharedPreferences.getInstance();

  static Future<Directory> dir() async {
    final base = await getApplicationDocumentsDirectory();
    final d = Directory('${base.path}/a2r');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  static Future<void> del(String path) async {
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
      final bf = File(baseOf(path));
      if (await bf.exists()) await bf.delete();
      final p = await _p;
      await p.remove('pos:$path');
      await p.remove('edit:$path');
      await p.remove('notag:$path');
    } catch (e, st) {
      AppLog.e('del', e, st);
    }
  }

  // --- إعدادات الموظف ---

  static Future<PerfMode> perfMode() async {
    final i = (await _p).getInt('perfMode') ?? 1;
    return PerfMode.values[i.clamp(0, 2)];
  }

  static Future<void> setPerfMode(PerfMode m) async => (await _p).setInt('perfMode', m.index);

  /// وضع الماسح: 0 تلقائي، 1 قص بس، 2 قص + فلتر، 3 كامل
  static Future<int> scanSetting() async => ((await _p).getInt('scanMode') ?? 0).clamp(0, 3);
  static Future<void> setScanSetting(int v) async => (await _p).setInt('scanMode', v);

  /// جودة الصورة: 0 صغيرة، 1 عادية، 2 عالية
  static Future<int> qualitySetting() async => ((await _p).getInt('jpegQ') ?? 1).clamp(0, 2);
  static Future<void> setQualitySetting(int v) async => (await _p).setInt('jpegQ', v);

  static Future<int> jpegQuality() async {
    switch (await qualitySetting()) {
      case 0:
        return 65;
      case 2:
        return 92;
      default:
        return (await perfMode()) == PerfMode.pro ? 90 : 82;
    }
  }

  /// شيل الصورة من المسودة من غير ما نمسح الملف (عشان "تراجع").
  static Future<void> unlistFromDraft(String path) async {
    final l = await draft();
    l.remove(path);
    await (await _p).setStringList('draft', l);
  }

  static Future<void> relistInDraft(String path, int index) async {
    if (!File(path).existsSync()) return;
    final l = await draft();
    if (!l.contains(path)) l.insert(index.clamp(0, l.length), path);
    await (await _p).setStringList('draft', l);
  }

  static Future<ScanFilter> filter() async {
    final i = (await _p).getInt('filter') ?? ScanFilter.receipt.index;
    return ScanFilter.values[i.clamp(0, ScanFilter.values.length - 1)];
  }

  static Future<void> setFilter(ScanFilter f) async => (await _p).setInt('filter', f.index);

  static Future<bool> continuous() async => (await _p).getBool('continuous') ?? true;
  static Future<void> setContinuous(bool v) async => (await _p).setBool('continuous', v);

  /// فتح شاشة الفلاتر والقص بعد كل صورة (تصوير أو معرض)
  /// قص الهوامش البيضاء الفاضية بعد تعديل الإيصال (مقفول افتراضياً)
  static Future<bool> trimMargins() async => (await _p).getBool('trim') ?? false;
  static Future<void> setTrimMargins(bool v) async => (await _p).setBool('trim', v);

  /// حجم الـ PDF: 0 كما هو، 1 مضغوط
  static Future<int> pdfSize() async => ((await _p).getInt('pdfSize') ?? 0).clamp(0, 1).toInt();
  static Future<void> setPdfSize(int v) async => (await _p).setInt('pdfSize', v);

  /// إعداد مفضل لكل فلتر: [تباين، سطوع، حدة]
  static Future<List<double>?> favOf(ScanFilter f) async {
    try {
      final s = (await _p).getString('fav:${f.name}');
      if (s == null) return null;
      final l = [for (final e in (jsonDecode(s) as List)) (e as num).toDouble()];
      return l.length == 3 ? l : null;
    } catch (_) {
      return null;
    }
  }

  static Future<void> setFav(ScanFilter f, List<double>? v) async {
    final p = await _p;
    if (v == null) {
      await p.remove('fav:${f.name}');
    } else {
      await p.setString('fav:${f.name}', jsonEncode(v));
    }
  }

  static Future<bool> autoEdit() async => (await _p).getBool('autoEdit') ?? false;
  static Future<void> setAutoEdit(bool v) async => (await _p).setBool('autoEdit', v);

  /// شكل ورقة الباتش: 1 شريط تحت الصورة، 2 على الصورة (الشريط فوق اتلغى، والقيمة القديمة 0 بتتحول لـ 1)
  static Future<int> batchLayout() async {
    final v = (await _p).getInt('batchLayout') ?? 1;
    return v == 2 ? 2 : 1;
  }
  static Future<void> setBatchLayout(int v) async => (await _p).setInt('batchLayout', v);

  /// حجم الورقة في وضع الشريط (نسبة من عرض الصورة)
  static Future<double> bandScale() async =>
      ((await _p).getDouble('bandScale2') ?? kBatchTagW).clamp(0.3, kBandMaxScale).toDouble();
  static Future<void> setBandScale(double v) async => (await _p).setDouble('bandScale2', v);

  // --- مكان وحجم الورقة ---
  static Future<TagPos?> pos(String path) async =>
      TagPos.decode((await _p).getString('pos:$path'));

  static Future<TagPos> assignPos(String path, Tag ref, bool batch) async {
    final p = await _p;
    var v = TagPos.decode(p.getString('pos:$path'));
    if (v == null) {
      v = TagPos.decode(p.getString(batch ? 'lastPos_b' : 'lastPos_r')) ?? TagPos.initial(ref);
      await p.setString('pos:$path', v.encode());
    }
    return v;
  }

  static Future<void> savePos(String path, TagPos v, bool batch) async {
    final p = await _p;
    await p.setString('pos:$path', v.encode());
    await p.setString(batch ? 'lastPos_b' : 'lastPos_r', v.encode());
  }

  // --- صورة الباتش ---
  static Future<String?> batchImg() async {
    final v = (await _p).getString('batchImg');
    if (v == null || !File(v).existsSync()) return null;
    return v;
  }

  static Future<void> setBatchImg(String path) async {
    final p = await _p;
    final old = p.getString('batchImg');
    if (old != null && old != path) await del(old);
    await p.setString('batchImg', path);
  }

  static Future<void> clearBatchImg() async {
    final p = await _p;
    final old = p.getString('batchImg');
    if (old != null) await del(old);
    await p.remove('batchImg');
  }

  static Future<void> afterBatchSent() async {
    await clearBatchImg();
    final p = await _p;
    for (final k in ['bi_count', 'bi_pi', 'bi_col', 'bi_total']) {
      await p.remove(k);
    }
    await setFlag('batch');
  }

  // --- صور الإيصالات ---
  static Future<void> setDraft(List<String> l) async => (await _p).setStringList('draft', l);

  static Future<List<String>> pdfImgs() async => (await _p).getStringList('pdfImgs') ?? [];

  static Future<List<String>> draft() async {
    final l = (await _p).getStringList('draft') ?? [];
    return l.where((e) => File(e).existsSync()).toList();
  }

  static Future<void> addToDraft(String path) async {
    final l = await draft();
    l.add(path);
    await (await _p).setStringList('draft', l);
  }

  static Future<void> removeFromDraft(String path) async {
    final l = await draft();
    l.remove(path);
    await del(path);
    await (await _p).setStringList('draft', l);
  }

  static Future<void> clearDraft() async {
    for (final e in await draft()) {
      await del(e);
    }
    await (await _p).setStringList('draft', []);
  }

  // --- نسخة الصورة الأصلية + إعدادات التعديل (تعديل غير مدمّر) ---
  static String baseOf(String path) => path.replaceFirst(RegExp(r'\.jpg$'), '_base.jpg');

  /// صورة معلّم عليها "من غير ورقة". الصورة الجديدة دايماً بتبدأ بالورقة.
  static Future<bool> noTag(String path) async => (await _p).getBool('notag:$path') ?? false;

  static Future<void> setNoTag(String path, bool v) async {
    final p = await _p;
    if (v) {
      await p.setBool('notag:$path', true);
    } else {
      await p.remove('notag:$path');
    }
  }

  static Future<EditParams?> editOf(String path) async =>
      EditParams.decode((await _p).getString('edit:$path'));

  static Future<void> setEdit(String path, EditParams e) async =>
      (await _p).setString('edit:$path', e.encode());

  /// بعد تعديل إيصال: الصورة الجديدة تاخد مكان القديمة في نفس الترتيب.
  static Future<void> replaceInDraft(String old, String neu) async {
    final l = await draft();
    final i = l.indexOf(old);
    if (i < 0) {
      l.add(neu);
    } else {
      l[i] = neu;
    }
    await (await _p).setStringList('draft', l);
    if (await noTag(old)) await setNoTag(neu, true); // الاختيار يفضل بعد التعديل
    await del(old);
  }

  // --- ملف الـ PDF (يفضل 24 ساعة) ---
  static Future<({File file, DateTime time})?> pdf() async {
    final p = await _p;
    final path = p.getString('pdfPath');
    final t = p.getInt('pdfTime');
    if (path == null || t == null) return null;
    final time = DateTime.fromMillisecondsSinceEpoch(t);
    final age = DateTime.now().difference(time);
    if (age > pdfLife || !File(path).existsSync()) {
      await clearPdf();
      return null;
    }
    return (file: File(path), time: time);
  }

  static Future<void> setPdf(File f, List<String> imgs) async {
    final p = await _p;
    final old = p.getString('pdfPath');
    if (old != null && old != f.path) await del(old);
    await p.setString('pdfPath', f.path);
    await p.setInt('pdfTime', DateTime.now().millisecondsSinceEpoch);
    await p.setStringList('pdfImgs', imgs);
  }

  static Future<void> clearPdf() async {
    final p = await _p;
    final old = p.getString('pdfPath');
    if (old != null) await del(old);
    await p.remove('pdfPath');
    await p.remove('pdfTime');
    await p.remove('pdfImgs');
  }

  static Future<void> afterPdfSent() async {
    final p = await _p;
    final used = p.getStringList('pdfImgs') ?? [];
    final left = await draft();
    for (final u in used) {
      await del(u);
      left.remove(u);
    }
    await p.setStringList('draft', left);
    await p.remove('pdfImgs');
    await setFlag('receipts');
  }

  // --- علامة ✓ (بتتصفّر كل يوم جديد) ---
  static Future<bool> flag(String k) async {
    final p = await _p;
    if (p.getString('flagDay') != _dayKey()) {
      await p.setString('flagDay', _dayKey());
      await p.setBool('f_batch', false);
      await p.setBool('f_receipts', false);
    }
    return p.getBool('f_$k') ?? false;
  }

  static Future<void> setFlag(String k) async {
    await flag(k);
    await (await _p).setBool('f_$k', true);
  }

  /// مسح أي ملفات مؤقتة مش تابعة لمسودة أو PDF شغّال. مبتشتغلش لو فيه عملية شغالة.
  static Future<void> cleanup() async {
    if (working > 0) return;
    final keep = <String>{...await draft(), ...await pdfImgs()};
    final bi = await batchImg();
    if (bi != null) keep.add(bi);
    final pdfPath = (await pdf())?.file.path;
    if (pdfPath != null) keep.add(pdfPath);
    keep.addAll(keep.map(baseOf).toList());
    await for (final e in (await dir()).list()) {
      if (working > 0) return;
      if (e is File && !keep.contains(e.path)) {
        try {
          if (DateTime.now().difference(e.lastModifiedSync()) < const Duration(minutes: 2)) {
            continue;
          }
        } catch (_) {
          continue;
        }
        await del(e.path);
      }
    }
  }
}

// =====================================================================
//  الكاميرا والمشاركة
// =====================================================================

Future<bool> askYesNo(BuildContext context, String title, String body,
    {String yes = 'تمام', String no = 'لا'}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (c) => Directionality(
      textDirection: TextDirection.rtl,
      child: AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(no)),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(yes)),
        ],
      ),
    ),
  );
  return r ?? false;
}

/// بيتطلب أول ما التطبيق يفتح. الكاميرا بس: المعرض بيشتغل من منتقي الصور بتاع النظام من غير إذن.
Future<void> requestAllPermissions() async {
  try {
    await Permission.camera.request();
  } catch (e, st) {
    AppLog.e('requestAllPermissions', e, st);
  }
}

Future<bool> ensureCamera(BuildContext context) async {
  var st = await Permission.camera.status;
  if (st.isGranted) return true;
  st = await Permission.camera.request();
  if (st.isGranted) return true;
  if (!context.mounted) return false;
  final go = await askYesNo(context, 'محتاج إذن الكاميرا',
      'من غير الإذن التطبيق مش هيقدر يصوّر. افتح الإعدادات > الأذونات > الكاميرا واختار "السماح".',
      yes: 'افتح الإعدادات', no: 'إلغاء');
  if (go) await openAppSettings();
  return false;
}

Future<List<String>> simplePick(BuildContext context, {bool multi = false}) async {
  final src = await showModalBottomSheet<ImageSource>(
    context: context,
    builder: (c) => SafeArea(
      child: Wrap(children: [
        ListTile(
            leading: const Icon(Icons.photo_camera),
            title: const Text('الكاميرا'),
            onTap: () => Navigator.pop(c, ImageSource.camera)),
        ListTile(
            leading: const Icon(Icons.photo_library),
            title: const Text('المعرض'),
            onTap: () => Navigator.pop(c, ImageSource.gallery)),
      ]),
    ),
  );
  if (src == null) return [];
  try {
    final picker = ImagePicker();
    if (src == ImageSource.gallery && multi) {
      final xs = await picker.pickMultiImage(maxWidth: 2000, imageQuality: 85);
      return xs.map((e) => e.path).toList();
    }
    final x = await picker.pickImage(source: src, maxWidth: 2000, imageQuality: 85);
    return x == null ? [] : [x.path];
  } catch (e, st) {
    AppLog.e('simplePick', e, st);
    if (context.mounted) snack(context, 'تعذر فتح الكاميرا أو المعرض');
    return [];
  }
}

/// لو أندرويد قفل التطبيق وهو في الكاميرا (رامات قليلة)، الصورة بتترجع هنا بعد ما التطبيق يفتح تاني.
Future<void> markPickTarget(String t) async {
  try {
    await (await SharedPreferences.getInstance()).setString('pickTarget', t);
  } catch (e, st) {
    AppLog.e('markPickTarget', e, st);
  }
}

Future<void> stashLostPick() async {
  try {
    final r = await ImagePicker().retrieveLostData();
    if (r.isEmpty || r.file == null) return;
    final d = Directory('${(await Store.dir()).path}/lost');
    await d.create(recursive: true);
    final f = await File(r.file!.path)
        .copy('${d.path}/${DateTime.now().microsecondsSinceEpoch}.jpg');
    await (await SharedPreferences.getInstance()).setString('lostPick', f.path);
  } catch (e, st) {
    AppLog.e('stashLostPick', e, st);
  }
}

/// بترجّع مسار الصورة الضايعة لو كانت تابعة للشاشة دي (مرة واحدة بس).
Future<String?> takeLostPick(String target) async {
  try {
    final p = await SharedPreferences.getInstance();
    final path = p.getString('lostPick');
    if (path == null || p.getString('pickTarget') != target) return null;
    await p.remove('lostPick');
    return await File(path).exists() ? path : null;
  } catch (e, st) {
    AppLog.e('takeLostPick', e, st);
    return null;
  }
}

/// كل التصوير (كاميرا أو معرض) بيعدي على ماسح المستندات (قص).
/// لو الماسح مش شغال على الموبايل بيتحول للكاميرا العادية تلقائياً.
List<Offset>? _shotQuad; // آخر تحديد حي وقت الضغط على زر التصوير (اقتراح فوري لشاشة التعديل، بيتستخدم مرة واحدة)
bool _lastScanManual = false; // آخر تصوير اتعمل بالكاميرا العادية (من غير ماسح ML Kit) فمحتاج شاشة القص
bool _scannerFailed = false; // فشل الماسح في الجلسة دي (بيتصفّر لما التطبيق يتقفل)

Future<List<String>> _manualPick(BuildContext context, {bool multi = false}) async {
  final r = await simplePick(context, multi: multi);
  _lastScanManual = r.isNotEmpty;
  return r;
}

ScannerMode _scanModeOf(int i, ScannerMode fallback) {
  switch (i) {
    case 1:
      return ScannerMode.base;
    case 2:
      // الوضع الأوسط (قص + فلتر): بنختاره بالترتيب عشان اسمه بيختلف بين نسخ الحزمة
      return ScannerMode.values.length > 2 ? ScannerMode.values[1] : ScannerMode.base;
    case 3:
      return ScannerMode.full;
    default:
      return fallback;
  }
}

const _scanOpts = <(int, String, String)>[
  (0, 'تلقائي', 'الباتش كامل والإيصالات قص بس (الافتراضي)'),
  (1, 'قص بس', 'أسرع وأخف، من غير تحسينات'),
  (2, 'قص + فلتر', 'قص مع تحسين تلقائي للألوان'),
  (3, 'كامل', 'قص وتنضيف الصورة وإزالة الصوابع'),
];

const _qualOpts = <(int, String, String)>[
  (0, 'صغيرة', 'ملف أخف وأسرع في الإرسال'),
  (1, 'عادية', 'متوازنة (الافتراضي)'),
  (2, 'عالية', 'أوضح وحجم أكبر'),
];

bool _scanBusy = false; // يمنع فتح الماسح مرتين (الضغط المزدوج كان بيقفل التطبيق)

Future<List<String>> scanImages(BuildContext context, int limit,
    {ScannerMode mode = ScannerMode.full}) async {
  if (_scanBusy) return [];
  _scanBusy = true;
  try {
    return await _scanImagesImpl(context, limit, mode: mode);
  } finally {
    _scanBusy = false;
  }
}

Future<List<String>> _scanImagesImpl(BuildContext context, int limit,
    {ScannerMode mode = ScannerMode.full}) async {
  _lastScanManual = false;
  if (!await ensureCamera(context)) return [];
  if (!context.mounted) return [];
  final perf = await Store.perfMode();
  if (_scannerFailed || perf == PerfMode.lite) return _manualPick(context, multi: limit > 1);
  final sm = await Store.scanSetting();
  final effMode = _scanModeOf(sm, perf == PerfMode.pro ? ScannerMode.full : mode);
  final scanner = DocumentScanner(
    options: DocumentScannerOptions(mode: effMode, pageLimit: limit, isGalleryImport: true),
  );
  try {
    final r = await scanner.scanDocument();
    return List<String>.from(r.images ?? const []);
  } catch (e) {
    if (e.toString().toLowerCase().contains('cancel')) return [];
    if (!context.mounted) return [];
    _scannerFailed = true;
    try {
      (await SharedPreferences.getInstance())
          .setInt('scannerFailedAt', DateTime.now().millisecondsSinceEpoch);
    } catch (e, st) {
      AppLog.e('scanImages.prefs', e, st);
    }
    if (!context.mounted) return [];
    await showDialog<void>(
      context: context,
      builder: (c) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('الماسح مش شغال على الموبايل ده'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('هنفتح الكاميرا العادية وبعدها شاشة القص. سبب المشكلة:'),
              const SizedBox(height: 8),
              SelectableText(e.toString(), textDirection: TextDirection.ltr, style: const TextStyle(fontSize: 12)),
            ]),
          ),
          actions: [FilledButton(onPressed: () => Navigator.pop(c), child: const Text('تمام'))],
        ),
      ),
    );
    if (!context.mounted) return [];
    return _manualPick(context, multi: limit > 1);
  } finally {
    scanner.close();
  }
}

/// قايمة المشاركة العادية: الموظف يختار واتساب أو أي تطبيق.
bool _shareBusy = false;

Future<bool> shareFiles(BuildContext context, List<String> paths, {String? text}) async {
  if (_shareBusy) return false;
  _shareBusy = true;
  try {
    if (text != null) await Clipboard.setData(ClipboardData(text: text));
    final r = await Share.shareXFiles(paths.map((p) => XFile(p)).toList(), text: text);
    if (text != null && context.mounted) {
      snack(context, 'الوصف اتنسخ، لو مظهرش في الواتساب الصقه');
    }
    if (r.status == ShareResultStatus.success) return true;
    if (r.status == ShareResultStatus.dismissed) return false;
    if (!context.mounted) return false;
    return await askYesNo(context, 'تم الإرسال؟', 'لو بعت الملف فعلاً اضغط "تم".',
        yes: 'تم', no: 'لا');
  } catch (e, st) {
    AppLog.e('shareFiles', e, st);
    if (context.mounted) snack(context, 'تعذر فتح قائمة المشاركة');
    return false;
  } finally {
    _shareBusy = false;
  }
}

// =====================================================================
//  وصف الباتش (واتساب)
// =====================================================================

class BatchInfo {
  final String count, piasters, collected, total;
  const BatchInfo(this.count, this.piasters, this.collected, this.total);
}

/// أرقام عربية/فارسية ← إنجليزي، وفاصلة عشرية موحّدة
String _digits(String s) {
  const ar = '٠١٢٣٤٥٦٧٨٩', fa = '۰۱۲۳۴۵۶۷۸۹';
  final b = StringBuffer();
  for (final ch in s.trim().split('')) {
    final i = ar.indexOf(ch), j = fa.indexOf(ch);
    b.write(i >= 0 ? i : (j >= 0 ? j : ch));
  }
  var t = b.toString().replaceAll(' ', '').replaceAll('٫', '.').replaceAll('،', ',');
  t = t.contains(',') && t.contains('.') ? t.replaceAll(',', '') : t.replaceAll(',', '.');
  return t;
}

String batchCaption(Session s, BatchInfo i) => [
      'الاسم: ${s.name}',
      'الوحده : ${s.unit.name}',
      if (s.building != null) 'اسم المبني : ${s.building}',
      'عدد المعاملات : ${i.count}',
      'عدد القروش الفاصله: ${i.piasters}',
      'عدد المعاملات المجمعه : ${i.collected}',
      'الاجمالي: ${i.total}',
    ].join('\n');

Future<BatchInfo?> askBatchInfo(BuildContext context) async {
  final p = await SharedPreferences.getInstance();
  final init = BatchInfo(p.getString('bi_count') ?? '', p.getString('bi_pi') ?? '',
      p.getString('bi_col') ?? '', p.getString('bi_total') ?? '');
  if (!context.mounted) return null;
  final r = await showModalBottomSheet<BatchInfo>(
    context: context,
    isScrollControlled: true,
    builder: (c) =>
        Directionality(textDirection: TextDirection.rtl, child: _BatchInfoSheet(init: init)),
  );
  if (r != null) {
    await p.setString('bi_count', r.count);
    await p.setString('bi_pi', r.piasters);
    await p.setString('bi_col', r.collected);
    await p.setString('bi_total', r.total);
  }
  return r;
}

class _BatchInfoSheet extends StatefulWidget {
  final BatchInfo init;
  const _BatchInfoSheet({required this.init});
  @override
  State<_BatchInfoSheet> createState() => _BatchInfoSheetState();
}

class _BatchInfoSheetState extends State<_BatchInfoSheet> {
  late final c1 = TextEditingController(text: widget.init.count);
  late final c2 =
      TextEditingController(text: widget.init.piasters.isEmpty ? '0' : widget.init.piasters);
  late final c3 =
      TextEditingController(text: widget.init.collected.isEmpty ? '0' : widget.init.collected);
  late final c4 = TextEditingController(text: widget.init.total);
  String? err;

  @override
  void dispose() {
    c1.dispose();
    c2.dispose();
    c3.dispose();
    c4.dispose();
    super.dispose();
  }

  void _ok() {
    final count = _digits(c1.text), pi = _digits(c2.text);
    final col = _digits(c3.text), tot = _digits(c4.text);
    bool isInt(String s) => RegExp(r'^\d+$').hasMatch(s);
    if (!isInt(count)) return setState(() => err = 'اكتب عدد المعاملات (أرقام بس)');
    if (pi.isNotEmpty && !isInt(pi)) {
      return setState(() => err = 'عدد القروش الفاصلة لازم يكون رقم');
    }
    if (col.isNotEmpty && !isInt(col)) {
      return setState(() => err = 'عدد المعاملات المجمعة لازم يكون رقم');
    }
    final t = double.tryParse(tot);
    if (t == null || t < 0) return setState(() => err = 'اكتب الإجمالي صح (مثال 28107.19)');
    Navigator.pop(
        context,
        BatchInfo('${int.parse(count)}', pi.isEmpty ? '0' : '${int.parse(pi)}',
            col.isEmpty ? '0' : '${int.parse(col)}', t.toStringAsFixed(2)));
  }

  Widget _f(TextEditingController c, String label, {bool dec = false, bool selectAll = false}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          controller: c,
          // الخانة اللي قيمتها 0 تتحدد كلها أول ما تدوس عليها، فأي رقم بتكتبه يحل محل الصفر
          onTap: selectAll
              ? () => c.selection = TextSelection(baseOffset: 0, extentOffset: c.text.length)
              : null,
          keyboardType: TextInputType.numberWithOptions(decimal: dec),
          decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
        ),
      );

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('بيانات الباتش',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            _f(c1, 'عدد المعاملات'),
            _f(c2, 'عدد القروش الفاصلة', selectAll: true),
            _f(c3, 'عدد المعاملات المجمعة', selectAll: true),
            _f(c4, 'الإجمالي', dec: true),
            if (err != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(err!, style: const TextStyle(color: Colors.red)),
              ),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: FilledButton(onPressed: _ok, child: const Text('متابعة للإرسال')),
            ),
          ]),
        ),
      );
}

Future<bool> sendBatchFile(BuildContext context, Session s, String img) async {
  final info = await askBatchInfo(context);
  if (info == null || !context.mounted) return false;
  final caption = batchCaption(s, info);
  Store.working++;
  File out;
  try {
    final bytes = await composeBatch(img, s);
    out = File('${(await Store.dir()).path}/${s.batchName}.jpg');
    await out.writeAsBytes(bytes, flush: true);
  } finally {
    Store.working--;
  }
  if (!context.mounted) return false;
  final ok = await shareFiles(context, [out.path], text: caption);
  if (ok) await Store.afterBatchSent();
  return ok;
}

// =====================================================================
//  عناصر العرض
// =====================================================================

class TaggedImage extends StatelessWidget {
  final String path;
  final Tag tag;
  final TagPos pos;
  final double? aspect;
  final ValueChanged<TagPos>? onChanged;
  final bool showTag;
  const TaggedImage(
      {super.key,
      required this.path,
      required this.tag,
      required this.pos,
      this.aspect,
      this.onChanged,
      this.showTag = true});

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (ctx, cons) {
        var cw = cons.maxWidth;
        double? ch;
        if (aspect != null) {
          ch = cw * aspect!;
          if (cons.hasBoundedHeight && ch > cons.maxHeight) {
            ch = cons.maxHeight;
            cw = ch / aspect!;
          }
        }
        final dw = cw * pos.s;
        final dh = dw * tag.h / tag.w;
        Widget t = Image.memory(tag.png,
            width: dw, height: dh, fit: BoxFit.fill, gaplessPlayback: true);
        if (onChanged != null) {
          t = _TagDrag(
            pos: pos,
            cw: cw,
            maxCy: aspect ?? 3,
            onChanged: onChanged!,
            child: DecoratedBox(
                decoration: BoxDecoration(border: Border.all(color: Colors.blue, width: 2)),
                child: t),
          );
        }
        Widget err(BuildContext _, Object __, StackTrace? ___) =>
            const Center(child: Text('تعذر عرض الصورة'));
        final img = ch != null
            ? Image.file(File(path),
                width: cw, height: ch, fit: BoxFit.fill, cacheWidth: 1000, errorBuilder: err)
            : Image.file(File(path),
                width: cw, fit: BoxFit.fitWidth, cacheWidth: 1000, errorBuilder: err);
        final stack = Stack(clipBehavior: Clip.hardEdge, children: [
          img,
          if (showTag)
            Positioned(
                left: pos.cx * cw - dw / 2,
                top: pos.cy * cw - dh / 2,
                width: dw,
                height: dh,
                child: t),
        ]);
        return Center(
            child: ch != null
                ? SizedBox(width: cw, height: ch, child: stack)
                : SizedBox(width: cw, child: stack));
      });
}

class _TagDrag extends StatefulWidget {
  final TagPos pos;
  final double cw, maxCy;
  final ValueChanged<TagPos> onChanged;
  final Widget child;
  const _TagDrag(
      {required this.pos,
      required this.cw,
      required this.maxCy,
      required this.onChanged,
      required this.child});
  @override
  State<_TagDrag> createState() => _TagDragState();
}

class _TagDragState extends State<_TagDrag> {
  double startS = 0.3;

  @override
  Widget build(BuildContext context) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onScaleStart: (_) => startS = widget.pos.s,
        onScaleUpdate: (d) {
          final p = widget.pos;
          final s = (startS * d.scale).clamp(0.1, 0.98).toDouble();
          final cx = (p.cx + d.focalPointDelta.dx / widget.cw).clamp(0.0, 1.0).toDouble();
          final cy =
              (p.cy + d.focalPointDelta.dy / widget.cw).clamp(0.0, widget.maxCy).toDouble();
          widget.onChanged(TagPos(cx, cy, s));
        },
        child: widget.child,
      );
}

class ZoomPage extends StatefulWidget {
  final Widget child;
  const ZoomPage({super.key, required this.child});
  @override
  State<ZoomPage> createState() => _ZoomPageState();
}

class _ZoomPageState extends State<ZoomPage> {
  final _tc = TransformationController();
  Offset _tap = Offset.zero;
  static const _zoom = 2.5;

  @override
  void dispose() {
    _tc.dispose();
    super.dispose();
  }

  /// نقرتين: لو متكبرة ترجع للحجم الطبيعي، ولو طبيعية تكبّر عند مكان النقر.
  void _toggle() {
    if (_tc.value.getMaxScaleOnAxis() > 1.05) {
      _tc.value = Matrix4.identity();
    } else {
      final tx = -_tap.dx * (_zoom - 1), ty = -_tap.dy * (_zoom - 1);
      _tc.value = Matrix4(_zoom, 0, 0, 0, 0, _zoom, 0, 0, 0, 0, 1, 0, tx, ty, 0, 1);
    }
  }

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white),
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onDoubleTapDown: (d) => _tap = d.localPosition,
        onDoubleTap: _toggle,
        child: InteractiveViewer(
          transformationController: _tc,
          constrained: false,
          minScale: 1,
          maxScale: 6,
          child: SizedBox(width: w, child: widget.child),
        ),
      ),
    );
  }
}

class ReceiptPreview extends StatelessWidget {
  final String path;
  final Tag tag;
  final int cacheWidth;
  final bool showTag;
  final bool bottom; // الشريط تحت الصورة بدل فوقها
  /// لو متحدد: الورقة بنسبة من عرض الصورة (زي ما بتتركب في الباتش) وملزوقة في الصورة،
  /// والـ tag بيكون نسخة مرجعية بتتكبّر وتتصغّر فوراً من غير إعادة رسم.
  final double? bandScale;
  const ReceiptPreview(
      {super.key,
      required this.path,
      required this.tag,
      this.cacheWidth = kMaxSide,
      this.showTag = true,
      this.bottom = false,
      this.bandScale});
  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (ctx, cons) {
        final k = bandScale;
        final full = cons.maxWidth;
        // عرض الصورة نفسها: لو الورقة أعرض من الصورة (k > 1) الصورة بتتوسّط بهوامش بيضا
        final cw = k == null ? full : full / math.max(1.0, k);
        Widget errW(BuildContext _, Object __, StackTrace? ___) =>
            const SizedBox(height: 120, child: Center(child: Text('تعذر عرض الصورة')));
        final pic = Image.file(File(path),
            width: cw, fit: BoxFit.fitWidth, cacheWidth: cacheWidth, errorBuilder: errW);
        if (k == null) {
          final band = Container(
            width: cw,
            color: Colors.white,
            padding: EdgeInsets.symmetric(vertical: cw * kBandPad),
            alignment: Alignment.center,
            child: Image.memory(tag.png,
                width: cw * tag.w / 1000, height: cw * tag.h / 1000, fit: BoxFit.fill),
          );
          return Column(
              mainAxisSize: MainAxisSize.min,
              children: bottom ? [pic, if (showTag) band] : [if (showTag) band, pic]);
        }
        final tw = cw * k;
        final th = tw * tag.h / tag.w;
        final pad = cw * kBandPad, gap = cw * kBandGapNear;
        final band = Container(
          width: full,
          color: Colors.white,
          padding: EdgeInsets.only(top: bottom ? gap : pad, bottom: bottom ? pad : gap),
          alignment: Alignment.center,
          child: Image.memory(tag.png,
              width: tw, height: th, fit: BoxFit.fill, gaplessPlayback: true),
        );
        final picBox = Container(
            width: full, color: Colors.white, alignment: Alignment.center, child: pic);
        return Column(
            mainAxisSize: MainAxisSize.min,
            children: bottom
                ? [picBox, if (showTag) band]
                : [if (showTag) band, picBox]);
      });
}

void snack(BuildContext context, String m) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

const kBrandDark = Color(0xFF0E131A); // نفس خلفية الأيقونة. الشعار أبيض فمحتاج خلفية غامقة.

Widget appLogo({double height = 36}) => Image.asset(
      'assets/logo.png',
      height: height,
      fit: BoxFit.contain,
      errorBuilder: (_, __, ___) => Text('A2R',
          style: TextStyle(
              color: Colors.white,
              fontSize: height * 0.8,
              fontWeight: FontWeight.w900,
              letterSpacing: 3)),
    );

// =====================================================================
//  التطبيق
// =====================================================================

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppLog.init();
  FlutterError.onError = (d) {
    FlutterError.presentError(d);
    AppLog.e('flutter', d.exception, d.stack);
  };
  ui.PlatformDispatcher.instance.onError = (err, st) {
    AppLog.e('async', err, st);
    return true;
  };
  await AppData.load();
  try {
    final sp = await SharedPreferences.getInstance();
    if (sp.getBool('apply_guard') == true) {
      await sp.setBool('apply_safe', true);
      await sp.setBool('apply_guard', false);
      AppLog.i('التطبيق اتقفل أثناء حفظ التعديل، اتفعّل الوضع الآمن (دقة أقل)');
    }
    if (sp.getBool('det_guard') == true) {
      await sp.setBool('det_off', true);
      await sp.setBool('det_guard', false);
      AppLog.i('الكشف الأصلي قفل التطبيق المرة اللي فاتت، اتوقف واتحوّل للكشف البسيط');
    }
    final t = sp.getInt('scannerFailedAt') ?? 0;
    _scannerFailed = DateTime.now().millisecondsSinceEpoch - t < 3 * 24 * 3600 * 1000;
  } catch (e, st) {
    AppLog.e('main', e, st);
  }
  await stashLostPick();
  String? resume;
  try {
    final sp = await SharedPreferences.getInstance();
    final lp = sp.getString('lostPick');
    if (lp != null && File(lp).existsSync()) resume = sp.getString('pickTarget');
  } catch (e, st) {
    AppLog.e('main.resume', e, st);
  }
  runApp(A2RApp(resumeTarget: resume));
}

ThemeData _theme(Brightness b) => ThemeData(
      colorSchemeSeed: const Color(0xFF0B5FA5),
      brightness: b,
      useMaterial3: true,
      appBarTheme: const AppBarTheme(
        backgroundColor: kBrandDark,
        foregroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        systemOverlayStyle: SystemUiOverlayStyle.light,
      ),
    );

class A2RApp extends StatelessWidget {
  final String? resumeTarget;
  const A2RApp({super.key, this.resumeTarget});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'A2R',
        debugShowCheckedModeBanner: false,
        theme: _theme(Brightness.light),
        darkTheme: _theme(Brightness.dark),
        themeMode: ThemeMode.system,
        locale: const Locale('ar'),
        supportedLocales: const [Locale('ar'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        builder: (c, w) => Directionality(textDirection: TextDirection.rtl, child: w!),
        home: LoginScreen(resumeTarget: resumeTarget),
      );
}

class LoginScreen extends StatefulWidget {
  final String? resumeTarget; // 'batch' أو 'receipts' لو التطبيق اتقفل أثناء التصوير
  const LoginScreen({super.key, this.resumeTarget});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  String? name;
  String? unitName;
  String? building;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    String? nz(String? v) => (v == null || v.isEmpty) ? null : v;
    if (!mounted) return;
    setState(() {
      name = nz(p.getString('name'));
      unitName = nz(p.getString('unit'));
      building = nz(p.getString('building'));
    });
    final rt = widget.resumeTarget;
    if (rt != null && _ready) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _resume(rt);
      });
    }
  }

  /// أندرويد قفل التطبيق وهو في الكاميرا (رامات قليلة): نرجّع الموظف لنفس الشاشة بدل شاشة الدخول.
  void _resume(String target) {
    final u = _unit;
    final n = _name;
    if (u == null || n == null) return;
    final b = _needsBuilding ? _building : (u.buildings.length == 1 ? u.buildings.first : null);
    final s = Session(n, u, b);
    final nav = Navigator.of(context);
    nav.push(MaterialPageRoute(builder: (_) => MainScreen(session: s)));
    nav.push(MaterialPageRoute(
        builder: (_) => target == 'batch' ? BatchScreen(session: s) : ReceiptsScreen(session: s)));
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('name', name ?? '');
    await p.setString('unit', unitName ?? '');
    await p.setString('building', building ?? '');
  }

  // قيم سليمة حتى لو البيانات اتغيرت من GitHub
  String? get _name => AppData.names.contains(name) ? name : null;
  Unit? get _unit {
    for (final u in AppData.units) {
      if (u.name == unitName) return u;
    }
    return null;
  }

  bool get _needsBuilding => _unit != null && _unit!.buildings.length > 1;
  String? get _building =>
      (_needsBuilding && _unit!.buildings.contains(building)) ? building : null;
  bool get _ready => _name != null && _unit != null && (!_needsBuilding || _building != null);

  bool _starting = false;

  void _start() {
    if (_starting) return;
    _starting = true;
    final u = _unit!;
    final b = _needsBuilding ? _building : (u.buildings.length == 1 ? u.buildings.first : null);
    name = _name;
    building = _building;
    _save();
    Navigator.push(
            context, MaterialPageRoute(builder: (_) => MainScreen(session: Session(name!, u, b))))
        .then((_) => _starting = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ValueListenableBuilder<int>(
          valueListenable: AppData.rev,
          builder: (context, _, __) {
            final u = _unit;
            return SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                    minHeight: MediaQuery.of(context).size.height -
                        MediaQuery.of(context).padding.vertical -
                        48),
                child: Column(children: [
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    decoration: BoxDecoration(
                      color: kBrandDark,
                      borderRadius: BorderRadius.circular(28),
                    ),
                    child: appLogo(height: 120),
                  ),
                  const SizedBox(height: 32),
                  DropdownButtonFormField<String>(
                    value: _name,
                    isExpanded: true,
                    decoration: const InputDecoration(
                        labelText: 'الاسم',
                        prefixIcon: Icon(Icons.person_outline),
                        border: OutlineInputBorder()),
                    items: AppData.names
                        .map((n) => DropdownMenuItem(value: n, child: Text(n)))
                        .toList(),
                    onChanged: (v) => setState(() => name = v),
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<String>(
                    value: u?.name,
                    isExpanded: true,
                    decoration: const InputDecoration(
                        labelText: 'الوحدة',
                        prefixIcon: Icon(Icons.location_on_outlined),
                        border: OutlineInputBorder()),
                    items: AppData.units
                        .map((x) => DropdownMenuItem(value: x.name, child: Text(x.name)))
                        .toList(),
                    onChanged: (v) => setState(() {
                      unitName = v;
                      building = null;
                    }),
                  ),
                  if (_needsBuilding) ...[
                    const SizedBox(height: 16),
                    DropdownButtonFormField<String>(
                      key: ValueKey(u!.name),
                      value: _building,
                      isExpanded: true,
                      decoration: const InputDecoration(
                          labelText: 'المبنى',
                          prefixIcon: Icon(Icons.apartment),
                          border: OutlineInputBorder()),
                      items: u.buildings
                          .map((b) => DropdownMenuItem(value: b, child: Text(b)))
                          .toList(),
                      onChanged: (v) => setState(() => building = v),
                    ),
                  ],
                  const SizedBox(height: 32),
                  SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: FilledButton(
                      onPressed: _ready ? _start : null,
                      child: const Text('ابدأ', style: TextStyle(fontSize: 20)),
                    ),
                  ),
                  const SizedBox(height: 16),
                  ValueListenableBuilder<String>(
                    valueListenable: AppData.status,
                    builder: (_, st, __) => Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Flexible(
                            child: Text('$st  •  v$kVersion',
                                style: const TextStyle(fontSize: 12, color: Colors.grey))),
                      ],
                    ),
                  ),
                ]),
              ),
            );
          },
        ),
      ),
    );
  }
}

// =====================================================================
//  الشاشة الرئيسية
// =====================================================================

class MainScreen extends StatefulWidget {
  final Session session;
  const MainScreen({super.key, required this.session});
  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with WidgetsBindingObserver {
  List<String> draft = [];
  String? batchImg;
  ({File file, DateTime time})? pdf;
  bool batchSent = false;
  bool receiptsSent = false;
  bool busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _reload();
  }

  Future<void> _init() async {
    await requestAllPermissions();
    try {
      await Store.cleanup();
    } catch (e, st) {
      AppLog.e('_init', e, st);
    }
    await _reload();
  }

  Future<void> _reload() async {
    final d = await Store.draft();
    final f = await Store.pdf();
    final bi = await Store.batchImg();
    final b = await Store.flag('batch');
    final r = await Store.flag('receipts');
    if (!mounted) return;
    setState(() {
      draft = d;
      pdf = f;
      batchImg = bi;
      batchSent = b;
      receiptsSent = r;
    });
  }

  Future<void> _showSettings() async {
    var mode = await Store.perfMode();
    var scan = await Store.scanSetting();
    var qual = await Store.qualitySetting();
    var autoEdit = await Store.autoEdit();
    var trim = await Store.trimMargins();
    var pdfSz = await Store.pdfSize();
    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (ctx, setS) => Directionality(
          textDirection: TextDirection.rtl,
          child: AlertDialog(
            title: const Text('إعدادات الأداء والكاميرا'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  RadioListTile<PerfMode>(
                    title: const Text('الوضع الاقتصادي (Lite)'),
                    subtitle: const Text('أسرع أداء للأجهزة القديمة، يستهلك رامات أقل ويعطل المؤثرات الثقيلة.'),
                    value: PerfMode.lite,
                    groupValue: mode,
                    onChanged: (v) {
                      setS(() => mode = v!);
                      Store.setPerfMode(v!);
                    },
                  ),
                  RadioListTile<PerfMode>(
                    title: const Text('الوضع المتوازن (Balanced)'),
                    subtitle: const Text('أداء جيد مع جودة ممتازة (الوضع الافتراضي).'),
                    value: PerfMode.balanced,
                    groupValue: mode,
                    onChanged: (v) {
                      setS(() => mode = v!);
                      Store.setPerfMode(v!);
                    },
                  ),
                  RadioListTile<PerfMode>(
                    title: const Text('الوضع الاحترافي (Pro)'),
                    subtitle: const Text('أعلى جودة تصوير ومعالجة (للأجهزة القوية فقط).'),
                    value: PerfMode.pro,
                    groupValue: mode,
                    onChanged: (v) {
                      setS(() => mode = v!);
                      Store.setPerfMode(v!);
                    },
                  ),
                  const Divider(),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    child: Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: Text('وضع الماسح', style: TextStyle(fontWeight: FontWeight.bold))),
                  ),
                  for (final o in _scanOpts)
                    RadioListTile<int>(
                      dense: true,
                      title: Text(o.$2),
                      subtitle: Text(o.$3),
                      value: o.$1,
                      groupValue: scan,
                      onChanged: (v) {
                        setS(() => scan = v!);
                        Store.setScanSetting(v!);
                      },
                    ),
                  const Divider(),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    child: Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: Text('جودة الصورة', style: TextStyle(fontWeight: FontWeight.bold))),
                  ),
                  for (final o in _qualOpts)
                    RadioListTile<int>(
                      dense: true,
                      title: Text(o.$2),
                      subtitle: Text(o.$3),
                      value: o.$1,
                      groupValue: qual,
                      onChanged: (v) {
                        setS(() => qual = v!);
                        Store.setQualitySetting(v!);
                      },
                    ),
                  const Divider(),
                  SwitchListTile(
                    dense: true,
                    title: const Text('أوضاع الفلتر بعد كل صورة'),
                    subtitle: const Text(
                        'بعد التصوير أو الاختيار من المعرض تظهر شاشة (أصلي / تحسين / أ/س / إيصال) والقص'),
                    value: autoEdit,
                    onChanged: (v) {
                      setS(() => autoEdit = v);
                      Store.setAutoEdit(v);
                    },
                  ),
                  SwitchListTile(
                    dense: true,
                    title: const Text('قص الهوامش البيضاء تلقائياً'),
                    subtitle: const Text(
                        'في فلاتر الإيصال: بيشيل البياض الفاضي حوالين الإيصال لما تضغط ✓ في التعديل'),
                    value: trim,
                    onChanged: (v) {
                      setS(() => trim = v);
                      Store.setTrimMargins(v);
                    },
                  ),
                  const Divider(),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    child: Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: Text('حجم ملف الـ PDF', style: TextStyle(fontWeight: FontWeight.bold))),
                  ),
                  RadioListTile<int>(
                    dense: true,
                    title: const Text('كما هو (أعلى جودة)'),
                    subtitle: const Text('الصور بتتحط في الـ PDF من غير أي ضغط إضافي'),
                    value: 0,
                    groupValue: pdfSz,
                    onChanged: (v) {
                      setS(() => pdfSz = v!);
                      Store.setPdfSize(v!);
                      Store.clearPdf();
                    },
                  ),
                  RadioListTile<int>(
                    dense: true,
                    title: const Text('مضغوط (حجم أصغر)'),
                    subtitle: const Text('أنسب للإرسال بالنت الضعيف، والكتابة الصغيرة ممكن تقل وضوحها شوية'),
                    value: 1,
                    groupValue: pdfSz,
                    onChanged: (v) {
                      setS(() => pdfSz = v!);
                      Store.setPdfSize(v!);
                      Store.clearPdf();
                    },
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => AppLog.share(ctx), child: const Text('إرسال سجل الأخطاء')),
              TextButton(
                  onPressed: () {
                    Navigator.pop(c);
                    _reload();
                  },
                  child: const Text('إغلاق'))
            ],
          ),
        ),
      ),
    );
  }

  bool _opening = false;

  Future<void> _open(Widget screen) async {
    if (_opening) return;
    _opening = true;
    try {
      await Navigator.push(context, MaterialPageRoute(builder: (_) => screen));
    } finally {
      _opening = false;
    }
    _reload();
  }

  Future<void> _sendBatch() async {
    final b = batchImg;
    if (b == null) return;
    setState(() => busy = true);
    try {
      final ok = await sendBatchFile(context, widget.session, b);
      if (ok) {
        HapticFeedback.mediumImpact();
        await _reload();
      }
    } catch (e) {
      if (mounted) snack(context, 'حصل خطأ: ${errText(e)}');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _trashBatch() async {
    if (!await askYesNo(context, 'مسح صورة الباتش؟', 'الصورة هتتمسح من التطبيق.',
        yes: 'امسح', no: 'إلغاء')) {
      return;
    }
    await Store.clearBatchImg();
    await _reload();
  }

  Future<void> _openPdf() async {
    final f = pdf;
    if (f == null) return;
    try {
      final r = await OpenFilex.open(f.file.path);
      if (r.type != ResultType.done && mounted) {
        snack(context, 'مفيش تطبيق يفتح ملفات PDF على التليفون');
      }
    } catch (e, st) {
      AppLog.e('_openPdf', e, st);
      if (mounted) snack(context, 'تعذر فتح الملف');
    }
  }

  Future<void> _sendPdf() async {
    final f = pdf;
    if (f == null) return;
    final used = <String>[];
    for (final x in await Store.pdfImgs()) {
      if (await File(x).exists()) used.add(x);
    }
    if (!mounted) return;
    if (used.isEmpty) {
      // مفيش صور نعرضها: مشاركة الـ PDF مباشرة زي الأول
      final ok = await shareFiles(context, [f.file.path]);
      if (ok) {
        HapticFeedback.mediumImpact();
        await Store.afterPdfSent();
        await _reload();
      }
      return;
    }
    await Navigator.push<bool>(
        context,
        MaterialPageRoute(
            builder: (_) =>
                PdfResultScreen(session: widget.session, pdf: f.file, imgs: used)));
    if (mounted) await _reload();
  }

  Future<void> _trashPdf() async {
    if (!await askYesNo(context, 'مسح ملف الـ PDF؟', 'الملف هيتمسح من التطبيق.',
        yes: 'امسح', no: 'إلغاء')) {
      return;
    }
    await Store.clearPdf();
    await _reload();
  }

  Future<void> _trashDraft() async {
    if (!await askYesNo(context, 'مسح صور الإيصالات؟', 'كل الصور اللي لسه متبعتتش هتتمسح.',
        yes: 'امسح', no: 'إلغاء')) {
      return;
    }
    await Store.clearDraft();
    await _reload();
  }

  Widget _statusChip(IconData icon, String label, bool done, String doneText, String todoText) {
    final color = done ? Colors.green : Colors.orange;
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: BoxDecoration(
          color: color.withAlpha(30),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withAlpha(120)),
        ),
        child: Row(children: [
          Icon(done ? Icons.check_circle : Icons.pending_outlined, color: color, size: 22),
          const SizedBox(width: 8),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
              Text(done ? doneText : todoText,
                  style: TextStyle(fontSize: 12, color: color.withAlpha(255))),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _big(IconData icon, String label, VoidCallback onTap) => SizedBox(
        height: 140,
        child: FilledButton.tonal(
          style: FilledButton.styleFrom(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
              padding: const EdgeInsets.all(8)),
          onPressed: onTap,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 44),
            const SizedBox(height: 8),
            Text(label,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 19, fontWeight: FontWeight.bold)),
          ]),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final s = widget.session;
    final cs = Theme.of(context).colorScheme;
    final unitLine = s.building == null ? s.unit.name : '${s.unit.name} - ${s.building}';
    final pf = pdf;
    final bi = batchImg;
    return Scaffold(
      appBar: AppBar(
        title: appLogo(height: 30),
        centerTitle: true,
        actions: [
          IconButton(
              tooltip: 'إعدادات الأداء',
              icon: const Icon(Icons.settings),
              onPressed: _showSettings),
          IconButton(
              tooltip: 'تغيير الحساب',
              icon: const Icon(Icons.switch_account),
              onPressed: () => Navigator.pop(context)),
        ],
      ),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        if (busy) const LinearProgressIndicator(),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            gradient: LinearGradient(
              begin: Alignment.topRight,
              end: Alignment.bottomLeft,
              colors: [kBrandDark, cs.primary],
            ),
          ),
          child: DefaultTextStyle(
            style: const TextStyle(color: Colors.white, fontSize: 16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Icon(Icons.person, color: Colors.white),
                const SizedBox(width: 8),
                Expanded(
                    child: Text(s.name,
                        style: const TextStyle(fontSize: 19, fontWeight: FontWeight.bold))),
              ]),
              const SizedBox(height: 8),
              Row(children: [
                const Icon(Icons.location_on_outlined, color: Colors.white),
                const SizedBox(width: 8),
                Expanded(child: Text(unitLine)),
              ]),
              const SizedBox(height: 8),
              Row(children: [
                const Icon(Icons.calendar_today, color: Colors.white, size: 20),
                const SizedBox(width: 8),
                Text(s.date,
                    textDirection: TextDirection.ltr,
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(width: 8),
                Expanded(
                    child: Text('(تاريخ التليفون - اتأكد إنه صح)',
                        style: TextStyle(fontSize: 11, color: Colors.white.withAlpha(200)))),
              ]),
            ]),
          ),
        ),
        const SizedBox(height: 14),
        Row(children: [
          _statusChip(Icons.receipt_long, 'الباتش', batchSent, 'اتبعت', 'لسه'),
          const SizedBox(width: 10),
          _statusChip(Icons.payments, 'الإيصالات', receiptsSent, 'اتبعت',
              draft.isEmpty ? 'لسه' : '${draft.length} صورة جاهزة'),
        ]),
        const SizedBox(height: 14),
        Row(children: [
          Expanded(
              child: _big(Icons.receipt_long, 'الباتش',
                  () => _open(BatchScreen(session: s, fresh: true)))),
          const SizedBox(width: 12),
          Expanded(
              child: _big(
                  Icons.payments, 'إيصالات الدفع', () => _open(ReceiptsScreen(session: s)))),
        ]),
        if (draft.isNotEmpty || pf != null || bi != null) ...[
          const SizedBox(height: 24),
          const Text('ملفاتي (لسه متبعتتش)',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          if (bi != null)
            Card(
              child: ListTile(
                leading: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.file(File(bi),
                      width: 48, height: 48, fit: BoxFit.cover, cacheWidth: 150),
                ),
                title: Text('الباتش - ${s.batchName}.jpg'),
                subtitle: const Text('اضغط للمعاينة'),
                onTap: () => _open(BatchScreen(session: s)),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(
                      tooltip: 'إرسال',
                      icon: const Icon(Icons.send),
                      onPressed: busy ? null : _sendBatch),
                  IconButton(
                      tooltip: 'مسح',
                      icon: const Icon(Icons.delete, color: Colors.red),
                      onPressed: busy ? null : _trashBatch),
                ]),
              ),
            ),
          if (draft.isNotEmpty)
            Card(
              child: ListTile(
                leading: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.file(File(draft.first),
                      width: 48, height: 48, fit: BoxFit.cover, cacheWidth: 150),
                ),
                title: Text('إيصالات الدفع (${draft.length} صورة)'),
                subtitle: const Text('اضغط للمعاينة أو لتكمل التصوير'),
                onTap: () => _open(ReceiptsScreen(session: s)),
                trailing: IconButton(
                    tooltip: 'مسح',
                    icon: const Icon(Icons.delete, color: Colors.red),
                    onPressed: _trashDraft),
              ),
            ),
          if (pf != null)
            Card(
              child: ListTile(
                leading: const Icon(Icons.picture_as_pdf, size: 36, color: Colors.red),
                title: Text(pf.file.path.split('/').last,
                    maxLines: 2, overflow: TextOverflow.ellipsis),
                subtitle: Text(
                    'اضغط لفتحه - يتمسح بعد ${(24 - DateTime.now().difference(pf.time).inHours).clamp(1, 24)} ساعة'),
                onTap: _openPdf,
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(
                      tooltip: 'إرسال', icon: const Icon(Icons.send), onPressed: _sendPdf),
                  IconButton(
                      tooltip: 'مسح',
                      icon: const Icon(Icons.delete, color: Colors.red),
                      onPressed: _trashPdf),
                ]),
              ),
            ),
        ],
        const SizedBox(height: 24),
        Center(
            child: Text('v$kVersion',
                style: const TextStyle(fontSize: 11, color: Colors.grey))),
      ]),
    );
  }
}

// =====================================================================
//  شاشة الباتش
// =====================================================================

class BatchScreen extends StatefulWidget {
  final Session session;
  final bool fresh; // true = تصوير باتش جديد (من غير ما نفتح القديم)
  const BatchScreen({super.key, required this.session, this.fresh = false});
  @override
  State<BatchScreen> createState() => _BatchScreenState();
}

class _BatchScreenState extends State<BatchScreen> {
  String? img;
  Tag? tag;
  Tag? bandTag;
  int layout = 1; // 1 تحت الصورة، 2 على الصورة
  double bandScale = kBatchTagW; // حجم الورقة في وضع الشريط
  Timer? _bandT;
  TagPos? pos;
  double? aspect;
  bool busy = false;
  bool noTag = false; // الصورة دي من غير ورقة بيانات

  @override
  void initState() {
    super.initState();
    unawaited(_warmTags());
    _init();
  }

  Future<void> _toggleTag(bool hide) async {
    final path = img;
    if (path == null) return;
    setState(() => noTag = hide);
    await Store.setNoTag(path, hide);
  }

  /// تكبير/تصغير الورقة لحظي أثناء السحب (من غير إعادة رسم)، والحفظ بيتأجل لحد ما الإيد تقف.
  void _setBand(double v) {
    setState(() => bandScale = v);
    _bandT?.cancel();
    _bandT = Timer(const Duration(milliseconds: 300), () {
      Store.setBandScale(v).catchError((Object e, StackTrace st) {
        AppLog.e('setBandScale', e, st);
      });
    });
  }

  Future<void> _setLayout(int v) async {
    setState(() => layout = v);
    await Store.setBatchLayout(v);
  }

  Future<void> _init() async {
    final lost = await takeLostPick('batch');
    if (lost != null && mounted) {
      try {
        final path = await persistImage(
            lost, 'batch_${DateTime.now().microsecondsSinceEpoch}.jpg',
            filter: ScanFilter.receipt);
        await Store.setBatchImg(path);
        await _show(path);
        _lastScanManual = true;
        if (mounted && img != null) await _edit(tab: 2);
        return;
      } catch (e) {
        if (mounted) snack(context, 'حصل خطأ: ${errText(e)}');
      }
    }
    final cur = await Store.batchImg();
    if (!mounted) return;
    if (cur != null && !widget.fresh) {
      await _show(cur);
    } else {
      _capture();
    }
  }

  /// بيجهّز رسم الورقة مرة واحدة في الخلفية (ميتكررش بعد كل تصوير).
  Future<void> _warmTags() async {
    try {
      tag ??= await receiptTag(1000, widget.session, batch: true);
      bandTag ??= await receiptTag(2000, widget.session, batch: true);
    } catch (e, st) {
      AppLog.e('warmTags', e, st);
    }
  }

  Future<void> _show(String path) async {
    try {
      final t = tag ?? await receiptTag(1000, widget.session, batch: true);
      final a = await imageAspect(path);
      final p0 = await Store.assignPos(path, t, true);
      final p = fitTagPos(p0, t, a);
      if (p.cx != p0.cx || p.cy != p0.cy) await Store.savePos(path, p, true);
      final nt = await Store.noTag(path);
      final lay = await Store.batchLayout();
      final bt = bandTag ?? await receiptTag(2000, widget.session, batch: true); // نسخة مرجعية عالية الدقة للمعاينة (بتتعمل مرة واحدة)
      final bsc = await Store.bandScale();
      if (!mounted) return;
      setState(() {
        bandScale = bsc;
        noTag = nt;
        tag = t;
        bandTag = bt;
        layout = lay;
        img = path;
        aspect = a;
        pos = p;
      });
    } catch (e) {
      if (mounted) {
        snack(context, 'تعذر فتح الصورة: ${errText(e)}');
        Navigator.pop(context);
      }
    }
  }

  /// بيحفظ الصورة كباتش ويعرضها. بيرجّع true لو نجح.
  Future<bool> _ingest(String src) async {
    setState(() => busy = true);
    try {
      final path = await persistImage(
          src, 'batch_${DateTime.now().microsecondsSinceEpoch}.jpg',
          filter: ScanFilter.receipt);
      await Store.setBatchImg(path);
      await _show(path);
      unawaited(qualityWarning(path).then((warn) {
        if (warn != null && mounted) snack(context, warn);
      }));
      return true;
    } catch (e) {
      if (mounted) snack(context, 'حصل خطأ: ${errText(e)}');
      return false;
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  /// نسخة سريعة للتصوير بالكاميرا: بتحفظ الصورة بس وترجّع مسارها، من غير تجهيز المعاينة
  /// ولا فحص الجودة قبل شاشة التعديل (دول بيتعملوا بعد ما الموظف يخلّص التعديل).
  Future<String?> _ingestQuick(String src) async {
    try {
      final path = await persistImage(
          src, 'batch_${DateTime.now().microsecondsSinceEpoch}.jpg',
          filter: ScanFilter.receipt);
      await Store.setBatchImg(path);
      return path;
    } catch (e) {
      if (mounted) snack(context, 'حصل خطأ: ${errText(e)}');
      return null;
    }
  }

  /// كاميرا التطبيق: صورة واحدة بس، بعدها شاشة التعديل علطول (من غير عداد).
  Future<void> _capture() async {
    if (!await ensureCamera(context)) {
      if (mounted && img == null) Navigator.pop(context);
      return;
    }
    if (!mounted) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => A2RCameraScreen(
          title: 'الباتش',
          single: true,
          onShot: (p) async {
            _lastScanManual = true; // من غير قص: شاشة التعديل تحدد حدود الورقة تلقائياً
            final saved = await _ingestQuick(p);
            if (saved == null) return null;
            if (mounted && await _edit(tab: 2, fromCam: true, path: saved)) {
              // إعادة أخذ: نمسح الصورة دي والكاميرا تفضل مفتوحة
              await Store.clearBatchImg();
              if (mounted) setState(() => img = null);
              return null;
            }
            if (mounted && img == null) {
              // خرج من التعديل من غير حفظ: نعرض الصورة زي ما هي
              final cur = await Store.batchImg();
              if (cur != null) await _show(cur);
            }
            final shown = img;
            if (shown != null) {
              unawaited(qualityWarning(shown).then((warn) {
                if (warn != null && mounted) snack(context, warn);
              }));
            }
            return const A2RCamState(close: true);
          },
          onGallery: () async {
            final before = img;
            await _gallery();
            return img != before ? const A2RCamState(close: true) : null;
          },
        ),
      ),
    );
    if (mounted && img == null) Navigator.pop(context);
  }

  Timer? _saveT;

  void _set(TagPos p) {
    setState(() => pos = p);
    _saveT?.cancel();
    final path = img;
    if (path == null) return;
    _saveT = Timer(const Duration(milliseconds: 400), () {
      Store.savePos(path, p, true).catchError((Object e, StackTrace st) {
        AppLog.e('savePos', e, st);
      });
    });
  }

  Future<void> _flushPos() async {
    final t = _saveT;
    if (t != null && t.isActive) {
      t.cancel();
      final path = img, p = pos;
      if (path != null && p != null) await Store.savePos(path, p, true);
    }
  }

  @override
  void dispose() {
    if (_bandT?.isActive ?? false) {
      _bandT!.cancel();
      Store.setBandScale(bandScale);
    }
    final t = _saveT;
    if (t != null && t.isActive) {
      t.cancel();
      final path = img, p = pos;
      if (path != null && p != null) Store.savePos(path, p, true);
    }
    super.dispose();
  }

  /// معرض: يختار صورة، وبعدين شاشة القص (تعديل) تفتح لوحدها.
  Future<void> _gallery() async {
    XFile? x;
    await markPickTarget('batch');
    try {
      x = await ImagePicker()
          .pickImage(source: ImageSource.gallery, maxWidth: 2000, imageQuality: 90);
    } catch (e, st) {
      AppLog.e('_gallery', e, st);
      if (mounted) snack(context, 'تعذر فتح المعرض');
      return;
    }
    if (x == null || !mounted) return;
    setState(() => busy = true);
    try {
      final path = await persistImage(
          x.path, 'batch_${DateTime.now().microsecondsSinceEpoch}.jpg',
          filter: ScanFilter.receipt);
      await Store.setBatchImg(path);
      await _show(path);
      final warn = await qualityWarning(path);
      if (warn != null && mounted) snack(context, warn);
    } catch (e) {
      if (mounted) snack(context, 'حصل خطأ: ${errText(e)}');
    } finally {
      if (mounted) setState(() => busy = false);
    }
    _lastScanManual = true; // صورة معرض من غير قص: القص التلقائي يشتغل
    if (mounted && img != null) await _edit(tab: 2);
  }

  /// تعديل: قص بزوايا حرة وتدوير وفلاتر للصورة الحالية.
  Future<bool> _edit({int tab = 0, bool fromCam = false, String? path}) async {
    final cur = path ?? img;
    if (cur == null) return false;
    final out = await Navigator.push<String>(
        context, MaterialPageRoute(builder: (_) => EditorPage(path: cur, prefix: 'batch_', initialTab: tab, canRetake: fromCam)));
    if (out == kRetake) return true;
    if (out == null || !mounted) return false;
    setState(() => busy = true);
    try {
      if (noTag) await Store.setNoTag(out, true); // الاختيار يفضل بعد التعديل
      await Store.setBatchImg(out); // بتمسح القديمة
      await _show(out);
    } catch (e) {
      if (mounted) snack(context, 'حصل خطأ: ${errText(e)}');
    } finally {
      if (mounted) setState(() => busy = false);
    }
    return false;
  }

  Future<void> _send() async {
    setState(() => busy = true);
    try {
      await _flushPos();
      _bandT?.cancel();
      await Store.setBandScale(bandScale);
      final ok = await sendBatchFile(context, widget.session, img!);
      if (ok) HapticFeedback.mediumImpact();
      if (ok && mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) snack(context, 'حصل خطأ: ${errText(e)}');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ready = img != null && tag != null && pos != null && aspect != null && bandTag != null;
    return Scaffold(
      appBar: AppBar(title: const Text('الباتش')),
      body: !ready
          ? const Center(child: CircularProgressIndicator())
          : Column(children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: layout == 2
                      ? TaggedImage(
                          path: img!,
                          tag: tag!,
                          pos: pos!,
                          aspect: aspect,
                          showTag: !noTag,
                          onChanged: noTag ? null : _set)
                      : Center(
                          child: FittedBox(
                            fit: BoxFit.contain,
                            child: SizedBox(
                              width: 1000 * math.max(1.0, bandScale),
                              child: ReceiptPreview(
                                  path: img!,
                                  tag: bandTag!,
                                  bandScale: bandScale,
                                  bottom: layout == 1,
                                  showTag: !noTag),
                            ),
                          ),
                        ),
                ),
              ),
              SwitchListTile(
                dense: true,
                title: const Text('ورقة البيانات على الصورة دي'),
                subtitle: const Text('اقفلها لو الصورة مش محتاجة ورقة (الصورة الجاية بتبدأ بالورقة)',
                    style: TextStyle(fontSize: 11)),
                value: !noTag,
                onChanged: busy ? null : (v) => _toggleTag(!v),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<int>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: 1, label: Text('تحت الصورة')),
                      ButtonSegment(value: 2, label: Text('على الصورة')),
                    ],
                    selected: {layout},
                    onSelectionChanged: (busy || noTag) ? null : (v) => _setLayout(v.first),
                  ),
                ),
              ),
              if (layout != 2)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(children: [
                    const Icon(Icons.format_size),
                    Expanded(
                      child: Slider(
                        value: bandScale.clamp(0.3, kBandMaxScale).toDouble(),
                        min: 0.3,
                        max: kBandMaxScale,
                        onChanged: noTag ? null : _setBand,
                      ),
                    ),
                    SizedBox(
                        width: 44,
                        child: Text('${(bandScale * 100).round()}%',
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: 12, color: Colors.grey))),
                    IconButton(
                      tooltip: 'الحجم الأصلي',
                      icon: const Icon(Icons.restart_alt),
                      onPressed: noTag ? null : () => _setBand(kBatchTagW),
                    ),
                  ]),
                ),
              if (layout == 2) ...[
                const SizedBox(height: 4),
                const Text('اسحب الورقة لتحريكها، وبإصبعين لتكبيرها أو تصغيرها',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(children: [
                    const Icon(Icons.format_size),
                    Expanded(
                      child: Slider(
                        value: pos!.s.clamp(0.1, 0.98).toDouble(),
                        min: 0.1,
                        max: 0.98,
                        onChanged: noTag ? null : (v) => _set(pos!.copyWith(s: v)),
                      ),
                    ),
                    IconButton(
                      tooltip: 'المكان الأصلي',
                      icon: const Icon(Icons.restart_alt),
                      onPressed: noTag ? null : () => _set(TagPos.initial(tag!)),
                    ),
                  ]),
                ),
              ],
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Row(children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: busy ? null : _capture,
                          icon: const Icon(Icons.add_a_photo),
                          label: const Text('تصوير'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: busy ? null : _gallery,
                          icon: const Icon(Icons.photo_library),
                          label: const Text('معرض'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: busy ? null : _edit,
                          icon: const Icon(Icons.crop),
                          label: const Text('تعديل'),
                        ),
                      ),
                    ]),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: FilledButton.icon(
                        onPressed: busy ? null : _send,
                        icon: busy
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.send),
                        label: const Text('إرسال'),
                      ),
                    ),
                  ]),
                ),
              ),
            ]),
    );
  }
}

// =====================================================================
//  شاشة التعديل: قص بزوايا حرة + تدوير + فلاتر (للباتش والإيصالات)
// =====================================================================

/// إعدادات التعديل المحفوظة لكل صورة (عشان إعادة التعديل تبدأ من الأصل).
class EditParams {
  final List<Offset>? quad; // TL,TR,BR,BL كنسب من الصورة بعد التدوير
  final int turns; // لفّات 90 درجة مع عقارب الساعة
  final double angle; // تدوير دقيق بالدرجات
  final ScanFilter filter;
  final double contrast; // -0.5 .. 1
  final double brightness; // -1 .. 1
  final double sharp; // حدة 0 .. 1
  final List<double>? levels; // مستويات التحسين التلقائي
  const EditParams({
    this.quad,
    this.turns = 0,
    this.angle = 0,
    this.filter = ScanFilter.original,
    this.contrast = 0,
    this.brightness = 0,
    this.sharp = 0,
    this.levels,
  });

  String encode() => jsonEncode({
        if (quad != null)
          'q': [
            for (final p in quad!) ...[p.dx, p.dy]
          ],
        't': turns,
        'a': angle,
        'f': filter.index,
        'c': contrast,
        'b': brightness,
        if (sharp > 0) 's': sharp,
        if (levels != null) 'lv': levels,
      });

  static EditParams? decode(String? s) {
    if (s == null) return null;
    try {
      final m = jsonDecode(s) as Map<String, dynamic>;
      List<Offset>? q;
      final raw = m['q'];
      if (raw is List && raw.length == 8) {
        final d = raw.map((e) => (e as num).toDouble()).toList();
        q = [for (var i = 0; i < 8; i += 2) Offset(d[i], d[i + 1])];
      }
      final fi = ((m['f'] as num?) ?? 0).toInt().clamp(0, ScanFilter.values.length - 1).toInt();
      return EditParams(
        quad: q,
        turns: ((m['t'] as num?) ?? 0).toInt() % 4,
        angle: ((m['a'] as num?) ?? 0).toDouble(),
        filter: ScanFilter.values[fi],
        contrast: ((m['c'] as num?) ?? 0).toDouble(),
        brightness: ((m['b'] as num?) ?? 0).toDouble(),
        sharp: ((m['s'] as num?) ?? 0).toDouble().clamp(0.0, 1.0).toDouble(),
        levels: (m['lv'] is List && (m['lv'] as List).length == 4)
            ? [for (final e in (m['lv'] as List)) (e as num).toDouble()]
            : null,
      );
    } catch (e, st) {
      AppLog.e('EditParams.decode', e, st);
      return null;
    }
  }
}

/// الرباعي لازم يكون محدّب وبنفس ترتيب TL,TR,BR,BL (من غير تقاطع أو قلب).
bool _quadConvex(List<Offset> q) {
  for (var i = 0; i < 4; i++) {
    final a = q[i], b = q[(i + 1) % 4], c = q[(i + 2) % 4];
    final cr = (b.dx - a.dx) * (c.dy - b.dy) - (b.dy - a.dy) * (c.dx - b.dx);
    if (cr <= 1e-6) return false;
  }
  return true;
}

List<Offset> _turnCw(List<Offset> q) {
  Offset m(Offset p) => Offset(1 - p.dy, p.dx);
  return [m(q[3]), m(q[0]), m(q[1]), m(q[2])];
}

List<Offset> _turnCcw(List<Offset> q) {
  Offset m(Offset p) => Offset(p.dy, 1 - p.dx);
  return [m(q[1]), m(q[2]), m(q[3]), m(q[0])];
}

/// تحويل المربع (0..1) إلى الرباعي (Homography) بدقة المنظور.
/// الناتج: [a, b, c, d, e, f, g, h] حيث x=(a*u+b*v+c)/(g*u+h*v+1).
List<double> _homography(List<Offset> p) {
  final x0 = p[0].dx, y0 = p[0].dy, x1 = p[1].dx, y1 = p[1].dy;
  final x2 = p[2].dx, y2 = p[2].dy, x3 = p[3].dx, y3 = p[3].dy;
  final dx1 = x1 - x2, dx2 = x3 - x2, dy1 = y1 - y2, dy2 = y3 - y2;
  final sx = x0 - x1 + x2 - x3, sy = y0 - y1 + y2 - y3;
  var g = 0.0, h = 0.0;
  if (sx.abs() > 1e-9 || sy.abs() > 1e-9) {
    final den = dx1 * dy2 - dx2 * dy1;
    g = (sx * dy2 - dx2 * sy) / den;
    h = (dx1 * sy - sx * dy1) / den;
  }
  return [x1 - x0 + g * x1, x3 - x0 + h * x3, x0, y1 - y0 + g * y1, y3 - y0 + h * y3, y0, g, h];
}

/// تدوير صورة 90 درجة (turns مرة مع عقارب الساعة). لو turns=0 بترجّع نفس الصورة.
Future<ui.Image> _rotateUi(ui.Image src, int turns) async {
  final t = turns % 4;
  if (t == 0) return src;
  final w = src.width, h = src.height;
  final bd = await src.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (bd == null) throw Exception('تعذر قراءة الصورة');
  final rgba = await compute(_rotateJob, <String, dynamic>{'src': _bytesOf(bd), 'w': w, 'h': h, 't': t});
  src.dispose();
  return _imageFromRgba(rgba, t.isOdd ? h : w, t.isOdd ? w : h);
}

/// الصورة بعد التدوير بدقة محدودة (kMaxSide) عشان الذاكرة.
Future<ui.Image> _rotatedImage(String path, int turns) async {
  final mode = await Store.perfMode();
  final maxSide = getMaxSide(mode);
  final bytes = await File(path).readAsBytes();
  final sz = await imageSize(bytes);
  final src = await decodeImage(bytes, maxWidth: sz.w > maxSide ? maxSide : null);
  return _rotateUi(src, turns);
}

/// بيشتغل في Isolate: تحويل المنظور + التدوير الدقيق + الألوان، بيرجّع RGBA.
Uint8List _warpJob(Map<String, dynamic> a) {
  final src = a['src'] as Uint8List;
  final sw = a['sw'] as int, sh = a['sh'] as int;
  final ow = a['ow'] as int, oh = a['oh'] as int;
  final theta = a['theta'] as double;
  final hm = (a['h'] as List).cast<double>();
  final m = (a['m'] as List).cast<double>();
  final out = Uint8List(ow * oh * 4);
  final cx = sw / 2, cy = sh / 2;
  final cs = math.cos(theta), sn = math.sin(theta);
  final ha = hm[0], hb = hm[1], hc = hm[2], hd = hm[3], he = hm[4], hf = hm[5], hg = hm[6], hh = hm[7];
  double clamp255(double v) => v < 0 ? 0 : (v > 255 ? 255 : v);
  for (var j = 0; j < oh; j++) {
    final v = oh > 1 ? j / (oh - 1) : 0.0;
    for (var i = 0; i < ow; i++) {
      final u = ow > 1 ? i / (ow - 1) : 0.0;
      final den = hg * u + hh * v + 1;
      final X = (ha * u + hb * v + hc) / den;
      final Y = (hd * u + he * v + hf) / den;
      final dx = X - cx, dy = Y - cy;
      var sx = cx + cs * dx + sn * dy;
      var sy = cy - sn * dx + cs * dy;
      var r = 255.0, g = 255.0, b = 255.0;
      if (sx >= -1 && sy >= -1 && sx <= sw && sy <= sh) {
        if (sx < 0) sx = 0;
        if (sy < 0) sy = 0;
        if (sx > sw - 1) sx = sw - 1.0;
        if (sy > sh - 1) sy = sh - 1.0;
        final x0 = sx.floor(), y0 = sy.floor();
        final x1 = x0 + 1 < sw ? x0 + 1 : x0;
        final y1 = y0 + 1 < sh ? y0 + 1 : y0;
        final fx = sx - x0, fy = sy - y0;
        final i00 = (y0 * sw + x0) * 4, i10 = (y0 * sw + x1) * 4;
        final i01 = (y1 * sw + x0) * 4, i11 = (y1 * sw + x1) * 4;
        final w00 = (1 - fx) * (1 - fy), w10 = fx * (1 - fy);
        final w01 = (1 - fx) * fy, w11 = fx * fy;
        r = src[i00] * w00 + src[i10] * w10 + src[i01] * w01 + src[i11] * w11;
        g = src[i00 + 1] * w00 + src[i10 + 1] * w10 + src[i01 + 1] * w01 + src[i11 + 1] * w11;
        b = src[i00 + 2] * w00 + src[i10 + 2] * w10 + src[i01 + 2] * w01 + src[i11 + 2] * w11;
      }
      final o = (j * ow + i) * 4;
      out[o] = clamp255(m[0] * r + m[1] * g + m[2] * b + m[4]).round();
      out[o + 1] = clamp255(m[5] * r + m[6] * g + m[7] * b + m[9]).round();
      out[o + 2] = clamp255(m[10] * r + m[11] * g + m[12] * b + m[14]).round();
      out[o + 3] = 255;
    }
  }
  return out;
}

/// كشف حدود الورقة: أول حاجة المحرك الأصلي (OpenCV) من حزمة document_scan، أوفلاين ومن غير Play Services،
/// ولو فشل أو رجّع null بنرجع للكشف البسيط تحت. بيرجّع TL,TR,BR,BL كنسب، أو null.
Future<List<Offset>?> detectDocQuad(String path) async {
  final swDet = Stopwatch()..start();
  try {
    return await _detectDocQuadImpl(path);
  } finally {
    AppLog.i('t detect ${swDet.elapsedMilliseconds}ms');
  }
}

Future<List<Offset>?> _detectDocQuadImpl(String path) async {
  final mode = await Store.perfMode();
  List<Offset>? native;
  if (mode != PerfMode.lite && await _nativeDetectorAllowed()) {
    final sp = await SharedPreferences.getInstance();
    File? tmp;
    try {
      // لو التطبيق اتقفل وإحنا جوه الكشف الأصلي، العلامة دي بتفضل true وفي التشغيل الجاي بنوقفه تلقائيًا
      await sp.setBool('det_guard', true);
      var input = path;
      try {
        tmp = await _smallCopy(path);
        if (tmp != null) input = tmp.path;
      } catch (e, st) {
        AppLog.e('detectDocQuad.smallCopy', e, st);
      }
      AppLog.i('native detect start');
      final c = await ds.DocumentDetector()
          .detect(ds.ScanInput.file(input))
          .timeout(const Duration(seconds: 20));
      AppLog.i('native detect done');
      if (c != null) {
        final q = [
          for (final p in c.toList())
            Offset(p.x.clamp(0.0, 1.0).toDouble(), p.y.clamp(0.0, 1.0).toDouble())
        ];
        if (q.length == 4 && _quadConvex(q)) native = q;
      }
    } catch (e, st) {
      AppLog.e('detectDocQuad', e, st);
    } finally {
      try {
        await sp.setBool('det_guard', false);
        if (tmp != null && await tmp.exists()) await tmp.delete();
      } catch (_) {}
    }
  }
  final simple = await _detectDocQuadSimple(path);
  if (native == null) return simple;
  if (simple == null) return native;
  // المحرك الأصلي أحياناً بيمسك جزء جوه الإيصال (منطقة الكتابة بس): لو الكشف البسيط
  // لقى مساحة أكبر بوضوح (والأصلي جواه) نستخدم البسيط عشان القص يشمل الإيصال كامل.
  final an = _quadArea(native), asimple = _quadArea(simple);
  if (asimple < 0.97 && an < asimple * 0.85) return simple;
  return native;
}

double _quadArea(List<Offset> q) {
  var a = 0.0;
  for (var i = 0; i < 4; i++) {
    final p = q[i], n = q[(i + 1) % 4];
    a += p.dx * n.dy - n.dx * p.dy;
  }
  return a.abs() / 2;
}

Future<bool> _nativeDetectorAllowed() async {
  try {
    return !((await SharedPreferences.getInstance()).getBool('det_off') ?? false);
  } catch (_) {
    return true;
  }
}

/// نسخة مصغّرة (حوالي 720px) من الصورة للكشف بس: الإحداثيات نسب فمفيش فرق، والذاكرة أقل بكتير.
Future<File?> _smallCopy(String path) async {
  final b = await FlutterImageCompress.compressWithFile(path,
      minWidth: 720, minHeight: 720, quality: 80, format: CompressFormat.jpeg, keepExif: false);
  if (b == null) return null;
  final d = await getTemporaryDirectory();
  final f = File('${d.path}/det_${DateTime.now().microsecondsSinceEpoch}.jpg');
  await f.writeAsBytes(b, flush: true);
  return f;
}

/// كشف تقريبي بسيط: الورقة أفتح وأقل تشبعاً بالألوان من الخلفية (خشب/مكتب).
Future<List<Offset>?> _detectDocQuadSimple(String path) async {
  try {
    final img = await decodeImage(await File(path).readAsBytes(), maxWidth: 160);
    final w = img.width, h = img.height;
    final bd = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    img.dispose();
    if (bd == null || w < 8 || h < 8) return null;
    final px = bd.buffer.asUint8List(bd.offsetInBytes, bd.lengthInBytes);
    final n = w * h;
    final feat = Uint8List(n);
    for (var i = 0; i < n; i++) {
      final int r = px[i * 4], g = px[i * 4 + 1], b = px[i * 4 + 2];
      final int y = (r * 54 + g * 183 + b * 19) >> 8;
      final int hi = r > g ? (r > b ? r : b) : (g > b ? g : b);
      final int lo = r < g ? (r < b ? r : b) : (g < b ? g : b);
      final int v = y - 2 * (hi - lo); // الخشب ملوّن فبيبقى أغمق، والورقة رمادية فبتفضل فاتحة
      feat[i] = v < 0 ? 0 : (v > 255 ? 255 : v);
    }
    return _quadFromFeature(feat, w, h);
  } catch (e, st) {
    AppLog.e('_detectDocQuadSimple', e, st);
    return null;
  }
}

/// الجزء المشترك بين كشف الصورة المصوّرة والكشف الحي من الكاميرا.
/// feat: قيمة 0..255 لكل بكسل (الورقة غالباً أعلى من الخلفية). بيرجّع TL,TR,BR,BL كنسب.
List<Offset>? _quadFromFeature(Uint8List feat, int w, int h) {
  final n = w * h;
  final hist = List<int>.filled(256, 0);
  for (var i = 0; i < n; i++) {
    hist[feat[i]]++;
  }
  // Otsu
  var sum = 0.0;
  for (var t = 0; t < 256; t++) {
    sum += t * hist[t];
  }
  var sumB = 0.0, wB = 0.0, bestV = -1.0;
  var thr = 128;
  for (var t = 0; t < 256; t++) {
    wB += hist[t];
    if (wB == 0) continue;
    final wF = n - wB;
    if (wF == 0) break;
    sumB += t * hist[t];
    final mB = sumB / wB, mF = (sum - sumB) / wF;
    final v = wB * wF * (mB - mF) * (mB - mF);
    if (v > bestV) {
      bestV = v;
      thr = t;
    }
  }
  List<bool> maskOf(bool bright) =>
      List<bool>.generate(n, (i) => bright ? feat[i] > thr : feat[i] <= thr);
  bool onBorder(int i) {
    final x = i % w, y = i ~/ w;
    return x <= 2 || y <= 2 || x >= w - 3 || y >= h - 3;
  }

  double borderFrac(List<bool> m) {
    var c = 0, t = 0;
    for (var i = 0; i < n; i++) {
      if (!onBorder(i)) continue;
      t++;
      if (m[i]) c++;
    }
    return t == 0 ? 1 : c / t;
  }

  var mask = maskOf(true);
  final inv = maskOf(false);
  // الورقة هي اللي ما بتلزقش في حدود الصورة
  if (borderFrac(inv) < borderFrac(mask)) mask = inv;
  // قفل الثقوب الصغيرة (الكتابة) ثم تآكل بسيط لتنضيف النقط الصغيرة
  final dil = List<bool>.filled(n, false);
  for (var y = 1; y < h - 1; y++) {
    for (var x = 1; x < w - 1; x++) {
      final i = y * w + x;
      dil[i] = mask[i] || mask[i - 1] || mask[i + 1] || mask[i - w] || mask[i + w];
    }
  }
  final er = List<bool>.filled(n, false);
  for (var y = 2; y < h - 2; y++) {
    for (var x = 2; x < w - 2; x++) {
      final i = y * w + x;
      er[i] = dil[i] && dil[i - 1] && dil[i + 1] && dil[i - w] && dil[i + w] && mask[i];
    }
  }
  // أكبر مكوّن متصل
  final seen = List<bool>.filled(n, false);
  final queue = List<int>.filled(n, 0);
  var bestSize = 0;
  List<int>? best;
  for (var s0 = 0; s0 < n; s0++) {
    if (!er[s0] || seen[s0]) continue;
    var head = 0, tail = 0;
    queue[tail++] = s0;
    seen[s0] = true;
    var tl = s0, tr = s0, br = s0, bl = s0;
    while (head < tail) {
      final i = queue[head++];
      final x = i % w, y = i ~/ w;
      if (x + y < tl % w + tl ~/ w) tl = i;
      if (x + y > br % w + br ~/ w) br = i;
      if (x - y > tr % w - tr ~/ w) tr = i;
      if (x - y < bl % w - bl ~/ w) bl = i;
      if (x > 0 && er[i - 1] && !seen[i - 1]) {
        seen[i - 1] = true;
        queue[tail++] = i - 1;
      }
      if (x < w - 1 && er[i + 1] && !seen[i + 1]) {
        seen[i + 1] = true;
        queue[tail++] = i + 1;
      }
      if (y > 0 && er[i - w] && !seen[i - w]) {
        seen[i - w] = true;
        queue[tail++] = i - w;
      }
      if (y < h - 1 && er[i + w] && !seen[i + w]) {
        seen[i + w] = true;
        queue[tail++] = i + w;
      }
    }
    if (tail > bestSize) {
      bestSize = tail;
      best = [tl, tr, br, bl];
    }
  }
  if (best == null || bestSize < n * 0.08) return null;
  Offset pt(int i, double ex, double ey) => Offset(
        (((i % w) + 0.5 + ex) / w).clamp(0.0, 1.0).toDouble(),
        (((i ~/ w) + 0.5 + ey) / h).clamp(0.0, 1.0).toDouble(),
      );
  final q = [
    pt(best[0], -1.5, -1.5),
    pt(best[1], 1.5, -1.5),
    pt(best[2], 1.5, 1.5),
    pt(best[3], -1.5, 1.5),
  ];
  return _quadConvex(q) ? q : null;
}

/// كشف حي من إطار الكاميرا (YUV420): بيلف الإطار لوضع رأسي ويصغّره لشبكة صغيرة.
List<Offset>? _liveDetect(cam.CameraImage f, int rot) {
  if (f.planes.length < 3) return null;
  final W = f.width, H = f.height;
  final swap = rot == 90 || rot == 270;
  final upW = swap ? H : W, upH = swap ? W : H;
  const gw = 96;
  final gh = math.max(8, (gw * upH / upW).round());
  final yp = f.planes[0], up = f.planes[1], vp = f.planes[2];
  final ub = up.bytesPerPixel ?? 1, vb = vp.bytesPerPixel ?? 1;
  final feat = Uint8List(gw * gh);
  for (var gy = 0; gy < gh; gy++) {
    final int yu = math.min(upH - 1, math.max(0, ((gy + 0.5) * upH / gh).floor()));
    for (var gx = 0; gx < gw; gx++) {
      final int xu = math.min(upW - 1, math.max(0, ((gx + 0.5) * upW / gw).floor()));
      int sx, sy;
      switch (rot) {
        case 90:
          sx = yu;
          sy = H - 1 - xu;
          break;
        case 270:
          sx = W - 1 - yu;
          sy = xu;
          break;
        case 180:
          sx = W - 1 - xu;
          sy = H - 1 - yu;
          break;
        default:
          sx = xu;
          sy = yu;
      }
      final y = yp.bytes[sy * yp.bytesPerRow + sx];
      final cx = sx >> 1, cy = sy >> 1;
      final ci = cy * up.bytesPerRow + cx * ub;
      final vi = cy * vp.bytesPerRow + cx * vb;
      var chroma = 0;
      if (ci < up.bytes.length && vi < vp.bytes.length) {
        chroma = (up.bytes[ci] - 128).abs() + (vp.bytes[vi] - 128).abs();
      }
      final int v = y - (chroma * 1.5).round();
      feat[gy * gw + gx] = v < 0 ? 0 : (v > 255 ? 255 : v);
    }
  }
  final q = _quadFromFeature(feat, gw, gh);
  if (q == null || _quadArea(q) > 0.97) return null;
  return q;
}

class _LiveQuadPainter extends CustomPainter {
  final List<Offset> q;
  const _LiveQuadPainter(this.q);
  @override
  void paint(Canvas canvas, Size size) {
    final pts = [for (final o in q) Offset(o.dx * size.width, o.dy * size.height)];
    final path = Path()..addPolygon(pts, true);
    const col = Color(0xFF1EC8A5);
    canvas.drawPath(path, Paint()..color = col.withValues(alpha: 0.18));
    canvas.drawPath(
        path,
        Paint()
          ..color = col
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..strokeJoin = StrokeJoin.round);
    for (final p in pts) {
      canvas.drawCircle(p, 6, Paint()..color = Colors.white);
      canvas.drawCircle(
          p,
          6,
          Paint()
            ..color = col
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2);
    }
  }

  @override
  bool shouldRepaint(covariant _LiveQuadPainter old) => old.q != q;
}

/// بترجّع مسار الصورة الجديدة بعد التعديل، أو null لو الموظف رجع من غير تأكيد.
/// التعديل دايماً بيبدأ من النسخة الأصلية، فتقدر تكبّر القص أو ترجّع الفلتر في أي وقت.
const kRetake = '__retake__'; // EditorPage بترجّعه لما الموظف يدوس "إعادة أخذ"
const kDelete = '__delete__'; // حذف الصفحة الحالية
const kAllPrefix = '__all__'; // __all__|<EditParams json>|<path>: حفظ الصفحة الحالية وتطبيق الفلتر على كل الصفحات
const kNavPrefix = '__nav__'; // __nav__|next|<path> أو __nav__|prev|<path>: انتقال لصفحة تانية بعد حفظ التعديل

/// بيرسم صفحة بعد التعديل (قص + تدوير + فلتر) من نسختها الأصلية وبيرجّع مسار الصورة الجديدة.
/// بيستخدمه المحرر (زر ✓) و"طبّق على كل الصفحات".
Future<String> renderEditedPage(String path, String prefix, EditParams e) async {
  final sp = await SharedPreferences.getInstance();
  Store.working++;
  try {
    // علامة: لو التطبيق اتقفل جوه "تم"، في التشغيل الجاي بنشغّل وضع آمن بدقة أقل
    await sp.setBool('apply_guard', true);
    final baseF = File(Store.baseOf(path));
    final src = await baseF.exists() ? baseF.path : path;
    final turns = e.turns, angle = e.angle, filter = e.filter;
    final contrast = e.contrast, brightness = e.brightness, sharp = e.sharp;
    var levels = e.levels;
    final quad = (e.quad != null && _quadConvex(e.quad!))
        ? e.quad!
        : const [Offset(0, 0), Offset(1, 0), Offset(1, 1), Offset(0, 1)];
    AppLog.i('apply start turns=$turns angle=${angle.toStringAsFixed(1)} filter=${filter.name}');
    if (filter == ScanFilter.auto && levels == null) {
      levels = await autoLevelsOf(await File(src).readAsBytes());
    }
    final r = await _rotatedImage(src, turns);
    final rw = r.width, rh = r.height;
    AppLog.i('apply decoded ${rw}x$rh');
    final bd = await r.toByteData(format: ui.ImageByteFormat.rawRgba);
    r.dispose();
    if (bd == null) throw Exception('تعذر قراءة الصورة');
    final pts = [for (final q in quad) Offset(q.dx * rw, q.dy * rh)];
    final topW = (pts[1] - pts[0]).distance, botW = (pts[2] - pts[3]).distance;
    final leftH = (pts[3] - pts[0]).distance, rightH = (pts[2] - pts[1]).distance;
    var ow = math.max(topW, botW), oh = math.max(leftH, rightH);
    final mode = await Store.perfMode();
    final safe = sp.getBool('apply_safe') ?? false;
    final maxSide = safe ? math.min(900, getMaxSide(mode)) : getMaxSide(mode);
    final k = math.min(1.0, maxSide / math.max(ow, oh));
    ow *= k;
    oh *= k;
    final w = math.max(8, ow.round()), h = math.max(8, oh.round());
    AppLog.i('apply warp ${w}x$h safe=$safe');
    var rgba = await compute(_warpJob, <String, dynamic>{
      'src': bd.buffer.asUint8List(bd.offsetInBytes, bd.lengthInBytes),
      'sw': rw,
      'sh': rh,
      'ow': w,
      'oh': h,
      'theta': angle * math.pi / 180,
      'h': _homography(pts),
      // فلاتر الإيصال: التباين والسطوع بيتطبقوا بعد التنضيف (زي المعاينة بالظبط)
      'm': isCleanFilter(filter)
          ? editMatrix(ScanFilter.original, 0, 0)
          : editMatrix(filter, contrast, brightness, levels),
    });
    AppLog.i('apply warp done');
    if (isCleanFilter(filter)) {
      rgba = await compute(_cleanJob, <String, dynamic>{
        'src': rgba,
        'w': w,
        'h': h,
        'gray': false,
        'th': usesThermalClean(filter),
      });
      AppLog.i('apply clean done');
      if (contrast != 0 || brightness != 0 || filter == ScanFilter.receiptBw) {
        rgba = await compute(_matrixJob, <String, dynamic>{
          'src': rgba,
          'm': editMatrix(filter, contrast, brightness),
        });
      }
    }
    final sk = effSharpness(filter, sharp);
    if (sk > 0) {
      rgba = await compute(_sharpenJob, <String, dynamic>{'src': rgba, 'w': w, 'h': h, 'k': sk});
      AppLog.i('apply sharpen done');
    }
    var fw = w, fh = h;
    if (isCleanFilter(filter) && await Store.trimMargins()) {
      final tr = await compute(_trimJob, <String, dynamic>{'src': rgba, 'w': w, 'h': h});
      final tw = tr['w'] as int;
      if (tw > 0) {
        rgba = tr['out'] as Uint8List;
        fw = tw;
        fh = tr['h'] as int;
        AppLog.i('apply trim ${w}x$h -> ${fw}x$fh');
      }
    }
    final comp = Completer<ui.Image>();
    ui.decodeImageFromPixels(rgba, fw, fh, ui.PixelFormat.rgba8888, comp.complete);
    final outImg = await comp.future;
    final png = await outImg.toByteData(format: ui.ImageByteFormat.png);
    outImg.dispose();
    if (png == null) throw Exception('تعذر حفظ الصورة');
    AppLog.i('apply png ${png.lengthInBytes ~/ 1024}KB');
    final jpg = await FlutterImageCompress.compressWithList(
      png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
      minWidth: fw,
      minHeight: fh,
      quality: await Store.jpegQuality(),
      format: CompressFormat.jpeg,
    );
    final dir = (await Store.dir()).path;
    final nf = File('$dir/$prefix${DateTime.now().microsecondsSinceEpoch}.jpg');
    await nf.writeAsBytes(jpg, flush: true);
    AppLog.i('apply jpg ${jpg.length ~/ 1024}KB saved');
    // النسخة الأصلية بتنتقل للصورة الجديدة (أو بتتعمل أول مرة من الصورة الحالية)
    final oldBase = File(Store.baseOf(path));
    final newBase = Store.baseOf(nf.path);
    if (await oldBase.exists()) {
      await oldBase.rename(newBase);
    } else {
      await File(path).copy(newBase);
    }
    await Store.setEdit(
        nf.path,
        EditParams(
            quad: quad,
            turns: turns,
            angle: angle,
            filter: filter,
            contrast: contrast,
            brightness: brightness,
            sharp: sharp,
            levels: levels));
    AppLog.i('apply done');
    return nf.path;
  } finally {
    try {
      await sp.setBool('apply_guard', false);
    } catch (_) {}
    Store.working--;
  }
}

/// لقطة من إعدادات المحرر (للتراجع والإعادة).
class _EditSnap {
  final List<Offset> quad;
  final int turns;
  final double angle;
  final ScanFilter filter;
  final double contrast, brightness, sharp;
  final String sig;
  _EditSnap(this.quad, this.turns, this.angle, this.filter, this.contrast, this.brightness,
      this.sharp, this.sig);
}

class _GridPainter extends CustomPainter {
  const _GridPainter();
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = Colors.white54
      ..strokeWidth = 1;
    for (var i = 1; i < 3; i++) {
      final x = size.width * i / 3, y = size.height * i / 3;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), p);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
    }
  }

  @override
  bool shouldRepaint(_GridPainter o) => false;
}

class EditorPage extends StatefulWidget {
  final bool canRetake; // بيظهر زر إعادة الأخذ لما الشاشة تتفتح من الكاميرا
  final int pageIndex; // ترتيب الصفحة (من 0)
  final int pageCount; // عدد الصفحات (0 = من غير تنقل، زي الباتش)
  final bool canDelete; // زر حذف الصفحة
  final String path;
  final String prefix; // 'batch_' أو 'r_'
  final int initialTab; // 0 قص، 1 تدوير، 2 ألوان/فلاتر
  const EditorPage(
      {super.key,
      required this.path,
      this.prefix = 'r_',
      this.initialTab = 0,
      this.canRetake = false,
      this.pageIndex = 0,
      this.pageCount = 0,
      this.canDelete = false});
  @override
  State<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends State<EditorPage> {
  // الصورة كلها بالظبط (محاذية للحواف): مفيش هامش، فمفيش أي جزء بيتقص
  static const _full = [
    Offset(0, 0),
    Offset(1, 0),
    Offset(1, 1),
    Offset(0, 1),
  ];
  String? src; // النسخة الأصلية لو موجودة
  double? aspect; // ارتفاع/عرض الصورة الأصلية (قبل التدوير)
  int turns = 0;
  double angle = 0;
  List<Offset> quad = List.of(_full);
  ScanFilter filter = ScanFilter.original;
  double contrast = 0;
  double brightness = 0;
  late int tab = widget.initialTab; // 0 قص، 1 تدوير، 2 ألوان
  int drag = -1; // 0..3 زوايا، 4..7 حواف، 8 تحريك الكل
  // تكبير/تصغير منطقة القص: قرصة بإصبعين، أو نقرتين، وسحب بإصبع واحد لتحريك الصورة وهي مكبّرة
  double _zm = 1;
  Offset _pan = Offset.zero;
  final Map<int, Offset> _ptrs = {};
  double _pinchD0 = 0, _pinchZ0 = 1;
  Offset _pinchFocalImg = Offset.zero;
  Offset _lastPtr = Offset.zero;
  Offset _downPos = Offset.zero;
  bool _movedFar = false;
  bool _pinched = false;
  DateTime _downAt = DateTime(2000);
  DateTime _lastTapAt = DateTime(2000);
  Offset _lastTapPos = Offset.zero;
  static const _maxZoom = 6.0;
  bool _swipeOk = false;
  String _sig0 = '';
  bool busy = false;
  bool _quadTouched = false; // الموظف حدد الإطار بنفسه: القص التلقائي المتأخر ميلمسوش
  ui.Image? view; // نسخة خفيفة للعرض بس (بعد التدوير 90)
  int _viewGen = 0;
  ui.Image? cleaned; // نسخة منضّفة للمعاينة لما الفلتر من فلاتر الإيصال
  bool _cleanedThermal = false; // النسخة المنضّفة دي بالمنحنى الحراري ولا العادي
  int _cleanGen = 0;
  double sharp = 0; // حدة يدوية 0..1
  List<double>? levels; // مستويات التحسين التلقائي (بتتحسب مرة واحدة من نسخة مصغرة)
  ui.Image? sharpImg; // نسخة المعاينة بعد الحدة (بتتحدّث لما السلايدر يقف)
  ui.Image? _sharpBase; // الصورة اللي اتحسبت منها sharpImg
  int _sharpGen = 0;

  // تراجع/إعادة
  final List<_EditSnap> _hist = [];
  int _hi = -1;
  bool get _canUndo => _hi > 0;
  bool get _canRedo => _hi >= 0 && _hi < _hist.length - 1;
  bool _peek = false; // ضغط مطوّل على زر المقارنة = عرض الصورة الأصلية
  final Map<ScanFilter, List<double>> _favs = {};

  void _mark() {
    final sg = _sig();
    if (_hi >= 0 && _hist[_hi].sig == sg) return;
    _hist.removeRange(_hi + 1, _hist.length);
    _hist.add(_EditSnap(List.of(quad), turns, angle, filter, contrast, brightness, sharp, sg));
    if (_hist.length > 40) _hist.removeAt(0);
    _hi = _hist.length - 1;
    if (mounted) setState(() {});
  }

  void _restore(_EditSnap s) {
    final turnsChanged = s.turns != turns;
    final filterChanged = s.filter != filter;
    setState(() {
      quad = List.of(s.quad);
      turns = s.turns;
      angle = s.angle;
      filter = s.filter;
      contrast = s.contrast;
      brightness = s.brightness;
      sharp = s.sharp;
    });
    if (turnsChanged) {
      _loadView();
    } else if (filterChanged) {
      _afterFilter(s.filter);
    } else {
      _resharp();
    }
  }

  void _undo() {
    if (!_canUndo) return;
    _hi--;
    _restore(_hist[_hi]);
  }

  void _redo() {
    if (!_canRedo) return;
    _hi++;
    _restore(_hist[_hi]);
  }

  Future<void> _loadFavs() async {
    for (final f in ScanFilter.values) {
      final v = await Store.favOf(f);
      if (v != null) _favs[f] = v;
    }
  }

  Future<void> _toggleFav(bool isFav) async {
    final f = filter;
    if (isFav) {
      await Store.setFav(f, null);
      _favs.remove(f);
    } else {
      final v = [contrast, brightness, sharp];
      await Store.setFav(f, v);
      _favs[f] = v;
    }
    if (!mounted) return;
    setState(() {});
    snack(context, isFav ? 'اتمسح الإعداد المفضل' : 'اتحفظ الإعداد المفضل لفلتر ${kFilterLabels[f]}');
  }

  Widget _favBtn() {
    final fv = _favs[filter];
    final isFav = fv != null &&
        (fv[0] - contrast).abs() < 0.001 &&
        (fv[1] - brightness).abs() < 0.001 &&
        (fv[2] - sharp).abs() < 0.001;
    return IconButton(
      visualDensity: VisualDensity.compact,
      tooltip: isFav ? 'مسح الإعداد المفضل' : 'حفظ السطوع والتباين والحدة كإعداد مفضل للفلتر ده',
      icon: Icon(isFav ? Icons.star : Icons.star_border, size: 22),
      onPressed: busy ? null : () => _toggleFav(isFav),
    );
  }

  Widget _peekBtn() => Listener(
        onPointerDown: busy ? null : (_) => setState(() => _peek = true),
        onPointerUp: (_) {
          if (_peek) setState(() => _peek = false);
        },
        onPointerCancel: (_) {
          if (_peek) setState(() => _peek = false);
        },
        child: Tooltip(
          message: 'اضغط مطوّلاً لرؤية الأصل',
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Icon(Icons.compare, color: _peek ? const Color(0xFF1EC8A5) : null),
          ),
        ),
      );

  bool get _cleanReady =>
      isCleanFilter(filter) && cleaned != null && _cleanedThermal == usesThermalClean(filter);
  ui.Image get _base => _cleanReady ? cleaned! : view!;
  ui.Image get _shownNow => _peek ? view! : _shown;

  ui.Image get _shown {
    final b = _base;
    return (effSharpness(filter, sharp) > 0 && sharpImg != null && identical(_sharpBase, b))
        ? sharpImg!
        : b;
  }

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    view?.dispose();
    cleaned?.dispose();
    sharpImg?.dispose();
    super.dispose();
  }

  Future<void> _makeClean() async {
    final v = view;
    if (v == null) return;
    final gen = ++_cleanGen;
    final th = usesThermalClean(filter);
    try {
      final c = await cleanUiImage(v, thermal: th);
      if (!mounted || gen != _cleanGen || view != v) {
        c.dispose();
        return;
      }
      final old = cleaned;
      setState(() {
        cleaned = c;
        _cleanedThermal = th;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => old?.dispose());
      _resharp();
    } catch (e, st) {
      AppLog.e('_makeClean', e, st);
    }
  }

  /// نسخة معاينة الحدة: بتتحسب على الصورة المعروضة في Isolate، ولما السلايدر يقف بس (مش مع كل حركة).
  Future<void> _resharp() async {
    final v = view;
    if (v == null) return;
    final k = effSharpness(filter, sharp);
    final gen = ++_sharpGen;
    if (k <= 0) {
      final old = sharpImg;
      if (old != null && mounted) {
        setState(() {
          sharpImg = null;
          _sharpBase = null;
        });
        WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
      }
      return;
    }
    final b = _base;
    try {
      final bd = await b.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (bd == null) return;
      final rgba = await compute(_sharpenJob,
          <String, dynamic>{'src': _bytesOf(bd), 'w': b.width, 'h': b.height, 'k': k});
      final img = await _imageFromRgba(rgba, b.width, b.height);
      if (!mounted || gen != _sharpGen || !identical(b, _base)) {
        img.dispose();
        return;
      }
      final old = sharpImg;
      setState(() {
        sharpImg = img;
        _sharpBase = b;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => old?.dispose());
    } catch (e, st) {
      AppLog.e('_resharp', e, st);
    }
  }

  /// مصفوفة المعاينة: لحد ما النسخة المنضّفة تجهز بنعرض الصورة من غير فلتر الإيصال (عشان مايظهرش أسود فجأة).
  List<double> _matrixNow() => (_peek || (isCleanFilter(filter) && !_cleanReady))
      ? editMatrix(ScanFilter.original, 0, 0)
      : editMatrix(filter, contrast, brightness, levels);

  Future<void> _makeLevels() async {
    final p = src;
    if (p == null) return;
    try {
      final lv = await autoLevelsOf(await File(p).readAsBytes());
      if (!mounted || lv == null) return;
      setState(() => levels = lv);
    } catch (e, st) {
      AppLog.e('_makeLevels', e, st);
    }
  }

  void _onFilter(ScanFilter f) {
    setState(() {
      filter = f;
      final fv = _favs[f]; // الإعداد المفضل للفلتر (لو محفوظ)
      if (fv != null) {
        contrast = fv[0];
        brightness = fv[1];
        sharp = fv[2];
      }
      if (f == ScanFilter.sharpen && sharp < 0.7) sharp = 0.7;
    });
    _afterFilter(f);
    _mark();
  }

  void _afterFilter(ScanFilter f) {
    if (isCleanFilter(f)) {
      if (cleaned == null || _cleanedThermal != usesThermalClean(f)) {
        _makeClean();
      } else {
        _resharp();
      }
    } else {
      _resharp();
      if (f == ScanFilter.auto && levels == null) _makeLevels();
    }
  }

  Future<void> _loadView() async {
    final gen = ++_viewGen;
    try {
      final img = await decodeImage(await File(src!).readAsBytes(), maxWidth: 1000);
      final r = await _rotateUi(img, turns);
      if (!mounted || gen != _viewGen) {
        r.dispose();
        return;
      }
      final old = view;
      final oldClean = cleaned;
      setState(() {
        view = r;
        cleaned = null;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        old?.dispose();
        oldClean?.dispose();
      });
      if (isCleanFilter(filter)) {
        _makeClean();
      } else {
        _resharp();
      }
      if (filter == ScanFilter.auto && levels == null) _makeLevels();
      _mark();
    } catch (e, st) {
      AppLog.e('_loadView', e, st);
      if (mounted) {
        snack(context, 'تعذر فتح الصورة');
        Navigator.pop(context);
      }
    }
  }

  Future<void> _init() async {
    try {
      AppLog.i('editor open');
      await _loadFavs();
      final base = File(Store.baseOf(widget.path));
      final s = await base.exists() ? base.path : widget.path;
      final a = await imageAspect(s);
      final e = await Store.editOf(widget.path);
      if (!mounted) return;
      setState(() {
        src = s;
        aspect = a;
        if (e != null) {
          turns = e.turns;
          angle = e.angle;
          filter = e.filter;
          contrast = e.contrast;
          brightness = e.brightness;
          sharp = e.sharp;
          levels = e.levels;
          if (e.quad != null && _quadConvex(e.quad!)) quad = List.of(e.quad!);
        }
      });
      await _loadView();
      _sig0 = _sig();
      AppLog.i('editor view loaded');
      WidgetsBinding.instance.addPostFrameCallback((_) => AppLog.i('editor first frame'));
      if (mounted && (e == null || e.quad == null) && _lastScanManual) {
        final live = widget.canRetake ? _shotQuad : null;
        _shotQuad = null;
        if (live != null && live.length == 4 && _quadConvex(live) && turns == 0) {
          setState(() => quad = List.of(live)); // اقتراح فوري من المعاينة الحية
          _mark();
          unawaited(_refineQuad()); // الكشف الدقيق بيشتغل في الخلفية ويحدّث الإطار بهدوء
        } else {
          await _auto(silent: true);
        }
      }
    } catch (e, st) {
      AppLog.e('_init', e, st);
      if (mounted) {
        snack(context, 'تعذر فتح الصورة');
        Navigator.pop(context);
      }
    }
  }

  // ---------- اللمس ----------

  String _sig() =>
      '${quad.map((o) => '${o.dx.toStringAsFixed(4)},${o.dy.toStringAsFixed(4)}').join(';')}|$turns|${angle.toStringAsFixed(2)}|${filter.name}|${contrast.toStringAsFixed(2)}|${brightness.toStringAsFixed(2)}|${sharp.toStringAsFixed(2)}';

  bool _quadFull() {
    for (var i = 0; i < 4; i++) {
      if ((quad[i] - _full[i]).distance > 0.002) return false;
    }
    return true;
  }

  /// انتقال لصفحة تانية (dir: next / prev) مع حفظ التعديل الحالي لو اتغيّر.
  Future<void> _nav(String dir) async {
    if (busy || widget.pageCount <= 0 || aspect == null) return;
    if (dir == 'prev' && widget.pageIndex <= 0) return;
    if (_sig() == _sig0) {
      Navigator.pop(context, '$kNavPrefix|$dir|${widget.path}');
      return;
    }
    await _apply(nav: dir);
  }

  Future<void> _confirmDelete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('حذف الصفحة؟'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('إلغاء')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('حذف')),
        ],
      ),
    );
    if (ok == true && mounted) Navigator.pop(context, kDelete);
  }

  Offset _clampPan(Offset p, Size s) => Offset(
        p.dx.clamp(s.width - s.width * _zm, 0.0).toDouble(),
        p.dy.clamp(s.height - s.height * _zm, 0.0).toDouble(),
      );

  /// p: إحداثيات على الشاشة (جوه منطقة العرض).
  void _down(Offset p, Size s) {
    final pan = _clampPan(_pan, s);
    final pts = [
      for (final q in quad) Offset(q.dx * s.width * _zm + pan.dx, q.dy * s.height * _zm + pan.dy)
    ];
    var best = -1;
    var bd = 44.0;
    for (var i = 0; i < 4; i++) {
      final d = (pts[i] - p).distance;
      if (d < bd) {
        bd = d;
        best = i;
      }
    }
    if (best == -1) {
      bd = 34.0;
      for (var i = 0; i < 4; i++) {
        final d = ((pts[i] + pts[(i + 1) % 4]) / 2 - p).distance;
        if (d < bd) {
          bd = d;
          best = 4 + i;
        }
      }
    }
    if (best == -1 && _inside(p, pts)) best = 8;
    if (best != -1) _quadTouched = true;
    setState(() => drag = best);
  }

  bool _inside(Offset p, List<Offset> v) {
    var c = false;
    for (var i = 0, j = v.length - 1; i < v.length; j = i++) {
      if (((v[i].dy > p.dy) != (v[j].dy > p.dy)) &&
          (p.dx < (v[j].dx - v[i].dx) * (p.dy - v[i].dy) / (v[j].dy - v[i].dy) + v[i].dx)) {
        c = !c;
      }
    }
    return c;
  }

  void _move(Offset delta, Size s) {
    if (drag < 0) return;
    final idx = drag < 4
        ? <int>[drag]
        : drag < 8
            ? <int>[drag - 4, (drag - 3) % 4]
            : <int>[0, 1, 2, 3];
    var dx = delta.dx / s.width, dy = delta.dy / s.height;
    for (final i in idx) {
      dx = dx.clamp(-quad[i].dx, 1 - quad[i].dx).toDouble();
      dy = dy.clamp(-quad[i].dy, 1 - quad[i].dy).toDouble();
    }
    final q = List.of(quad);
    for (final i in idx) {
      q[i] = q[i] + Offset(dx, dy);
    }
    setState(() => quad = q);
  }

  void _ptrDown(PointerDownEvent e, Offset origin, Size s) {
    final p = e.localPosition - origin;
    _ptrs[e.pointer] = p;
    if (_ptrs.length == 1) {
      _pinched = false;
      _movedFar = false;
      _downPos = p;
      _lastPtr = p;
      _downAt = DateTime.now();
      _down(p, s);
      _swipeOk = widget.pageCount > 0 && !busy && _zm <= 1.001 && (drag == -1 || (drag == 8 && _quadFull()));
    } else if (_ptrs.length == 2) {
      // إصبعين: تكبير/تصغير (وبنوقف سحب الزوايا)
      if (drag != -1) setState(() => drag = -1);
      _pinched = true;
      final v = _ptrs.values.toList();
      _pinchD0 = math.max((v[0] - v[1]).distance, 1);
      _pinchZ0 = _zm;
      final mid = (v[0] + v[1]) / 2;
      final pan = _clampPan(_pan, s);
      _pinchFocalImg = Offset((mid.dx - pan.dx) / _zm, (mid.dy - pan.dy) / _zm);
    }
  }

  void _ptrMove(PointerMoveEvent e, Offset origin, Size s) {
    if (!_ptrs.containsKey(e.pointer)) return;
    final p = e.localPosition - origin;
    _ptrs[e.pointer] = p;
    if (_ptrs.length >= 2) {
      final v = _ptrs.values.toList();
      final mid = (v[0] + v[1]) / 2;
      final z = (_pinchZ0 * (v[0] - v[1]).distance / _pinchD0).clamp(1.0, _maxZoom).toDouble();
      setState(() {
        _zm = z;
        _pan = _clampPan(Offset(mid.dx - _pinchFocalImg.dx * z, mid.dy - _pinchFocalImg.dy * z), s);
      });
      return;
    }
    final delta = p - _lastPtr;
    _lastPtr = p;
    if ((p - _downPos).distance > 12) _movedFar = true;
    if (_pinched) {
      // آخر إصبع بعد القرصة: بيحرك الصورة بس
      if (_zm > 1.001) setState(() => _pan = _clampPan(_pan + delta, s));
      return;
    }
    if (drag >= 0 && drag < 8) {
      _move(delta / _zm, s);
    } else if (_zm > 1.001) {
      setState(() => _pan = _clampPan(_pan + delta, s)); // سحب الصورة وهي مكبّرة
    } else if (drag == 8) {
      _move(delta / _zm, s);
    }
  }

  void _ptrUp(PointerEvent e, Size s, {bool cancel = false}) {
    final lastP = _ptrs.remove(e.pointer);
    if (lastP == null) return;
    if (_ptrs.isNotEmpty) {
      _lastPtr = _ptrs.values.first;
      return;
    }
    final wasDrag = drag;
    if (drag != -1) setState(() => drag = -1);
    if (wasDrag != -1 && !cancel) _mark();
    if (cancel || _pinched) return;
    if (_swipeOk) {
      // سويب أفقي: يمين = الصفحة اللي بعدها (أو إضافة صورة)، شمال = اللي قبلها
      final d = lastP - _downPos;
      if (d.dx.abs() > 80 &&
          d.dx.abs() > d.dy.abs() * 2 &&
          DateTime.now().difference(_downAt).inMilliseconds < 900) {
        _nav(d.dx > 0 ? 'next' : 'prev');
        return;
      }
    }
    if (_movedFar) return;
    // نقرة سريعة: نقرتين ورا بعض = تكبير/رجوع
    final now = DateTime.now();
    if (now.difference(_downAt).inMilliseconds > 300) return;
    final onHandle = wasDrag >= 0 && wasDrag < 8;
    if (onHandle) return;
    final pos = _downPos;
    if (now.difference(_lastTapAt).inMilliseconds < 350 && (pos - _lastTapPos).distance < 40) {
      _lastTapAt = DateTime(2000);
      setState(() {
        if (_zm > 1.05) {
          _zm = 1;
          _pan = Offset.zero;
        } else {
          final pan = _clampPan(_pan, s);
          final fi = Offset((pos.dx - pan.dx) / _zm, (pos.dy - pan.dy) / _zm);
          _zm = 2.5;
          _pan = _clampPan(Offset(pos.dx - fi.dx * _zm, pos.dy - fi.dy * _zm), s);
        }
      });
    } else {
      _lastTapAt = now;
      _lastTapPos = pos;
    }
  }

  Offset? _focus(Size s) {
    if (drag < 0 || drag > 7) return null;
    final n = drag < 4 ? quad[drag] : (quad[drag - 4] + quad[(drag - 3) % 4]) / 2;
    return Offset(n.dx * s.width, n.dy * s.height);
  }

  // ---------- العرض ----------

  Widget _img(double w, double h) => view == null
      ? SizedBox(width: w, height: h)
      : CustomPaint(
          size: Size(w, h),
          painter: _ViewPainter(_shownNow, Size(w, h), angle * math.pi / 180,
              _matrixNow()),
        );

  /// عدسة مكبّرة بتظهر فوق الإصبع وقت سحب الزاوية.
  Widget _loupe(Offset f, Size s) {
    const d = 112.0, z = 2.6;
    final fx = f.dx * _zm + _clampPan(_pan, s).dx;
    final left = fx < s.width / 2 ? s.width - d - 6 : 6.0;
    return Positioned(
      left: left,
      top: 6,
      width: d,
      height: d,
      child: IgnorePointer(
        child: Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 3),
            boxShadow: const [BoxShadow(blurRadius: 6, color: Colors.black45)],
          ),
          child: ClipOval(
            child: Stack(children: [
              if (view != null)
                CustomPaint(
                  size: const Size(d, d),
                  painter: _ViewPainter(_shownNow, s, angle * math.pi / 180,
                      _matrixNow(),
                      focus: f, zoom: z),
                ),
              const Center(child: Icon(Icons.add, size: 22, color: Colors.redAccent)),
            ]),
          ),
        ),
      ),
    );
  }

  /// تحسين هادي للإطار بعد ما الاقتراح الفوري ظهر: من غير مؤشر انتظار، ومبيلمسش لو الموظف عدّل بإيده.
  Future<void> _refineQuad() async {
    try {
      final q = await detectDocQuad(src!);
      if (!mounted || _quadTouched || q == null) return;
      var r = q;
      for (var i = 0; i < turns; i++) {
        r = _turnCw(r);
      }
      setState(() => quad = r);
      _mark();
    } catch (e, st) {
      AppLog.e('_refineQuad', e, st);
    }
  }

  Future<void> _auto({bool silent = false}) async {
    if (!silent) _quadTouched = false;
    setState(() => busy = true);
    try {
      final q = await detectDocQuad(src!);
      if (!mounted) return;
      if (silent && _quadTouched) return;
      if (q == null) {
        if (!silent) snack(context, 'مقدرتش أحدد حدود الورقة تلقائياً، حددها بإيدك');
      } else {
        var r = q;
        for (var i = 0; i < turns; i++) {
          r = _turnCw(r);
        }
        setState(() {
          quad = r;
          angle = 0;
        });
        _mark();
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _apply({String? nav, bool all = false}) async {
    if (!_quadConvex(quad)) {
      snack(context, 'حدود القص متداخلة، عدّل الزوايا');
      return;
    }
    setState(() => busy = true);
    try {
      final ep = EditParams(
          quad: quad,
          turns: turns,
          angle: angle,
          filter: filter,
          contrast: contrast,
          brightness: brightness,
          sharp: sharp,
          levels: levels);
      final np = await renderEditedPage(widget.path, widget.prefix, ep);
      if (mounted) {
        final style =
            EditParams(filter: filter, contrast: contrast, brightness: brightness, sharp: sharp);
        Navigator.pop(
            context,
            all
                ? '$kAllPrefix|${style.encode()}|$np'
                : (nav == null ? np : '$kNavPrefix|$nav|$np'));
      }
    } catch (e, st) {
      AppLog.e('editor._apply', e, st);
      if (mounted) snack(context, 'حصل خطأ: ${errText(e)}');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _confirmApplyAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('تطبيق على كل الصفحات'),
        content: const Text(
            'هيتطبق الفلتر والسطوع والتباين والحدة على كل الصفحات. القص والتدوير بتاع كل صفحة هيفضلوا زي ما هما.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('إلغاء')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('طبّق')),
        ],
      ),
    );
    if (ok == true && mounted) await _apply(all: true);
  }

  // ---------- لوحات التحكم ----------

  Widget _panel() {
    switch (tab) {
      case 0:
        return Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          const Text('اسحب الزوايا أو منتصف الحواف، واسحب جوه الإطار لتحريكه',
              textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: busy ? null : _auto,
                icon: const Icon(Icons.auto_fix_high),
                label: const Text('تلقائي'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: busy
                    ? null
                    : () {
                        HapticFeedback.selectionClick();
                        setState(() {
                          _quadTouched = true;
                          angle = 0;
                          quad = List.of(_full);
                        });
                        _mark();
                      },
                icon: const Icon(Icons.crop_free),
                label: const Text('الصورة كلها'),
              ),
            ),
          ]),
        ]);
      case 1:
        return Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            IconButton.filledTonal(
              tooltip: 'لفّ يسار',
              icon: const Icon(Icons.rotate_left),
              onPressed: busy
                  ? null
                  : () => setState(() {
                        turns = (turns + 3) % 4;
                        quad = _turnCcw(quad);
                        _loadView();
                      }),
            ),
            const SizedBox(width: 16),
            IconButton.filledTonal(
              tooltip: 'لفّ يمين',
              icon: const Icon(Icons.rotate_right),
              onPressed: busy
                  ? null
                  : () => setState(() {
                        turns = (turns + 1) % 4;
                        quad = _turnCw(quad);
                        _loadView();
                      }),
            ),
          ]),
          Row(children: [
            const Icon(Icons.straighten),
            Expanded(
              child: Slider(
                value: angle,
                min: -20,
                max: 20,
                divisions: 80,
                label: '${angle.toStringAsFixed(1)}°',
                onChanged: busy ? null : (v) => setState(() => angle = v),
                onChangeEnd: busy ? null : (_) => _mark(),
              ),
            ),
            TextButton(
              onPressed: (busy || angle == 0)
                  ? null
                  : () {
                      setState(() => angle = 0);
                      _mark();
                    },
              child: const Text('0°'),
            ),
          ]),
        ]);
      default:
        return Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Row(children: [
            _peekBtn(),
            Expanded(child: FilterBar(selected: filter, onChanged: busy ? null : _onFilter)),
          ]),
          Row(children: [
            const Icon(Icons.brightness_6, size: 20),
            Expanded(
              child: Slider(
                value: brightness,
                min: -1,
                max: 1,
                onChanged: busy ? null : (v) => setState(() => brightness = v),
                onChangeEnd: busy ? null : (_) => _mark(),
              ),
            ),
            const Icon(Icons.contrast, size: 20),
            Expanded(
              child: Slider(
                value: contrast,
                min: -0.5,
                max: 1,
                onChanged: busy ? null : (v) => setState(() => contrast = v),
                onChangeEnd: busy ? null : (_) => _mark(),
              ),
            ),
            IconButton(
              tooltip: 'إعادة ضبط',
              icon: const Icon(Icons.restart_alt),
              onPressed: busy
                  ? null
                  : () {
                      setState(() {
                        brightness = 0;
                        contrast = 0;
                        sharp = 0;
                      });
                      _resharp();
                      _mark();
                    },
            ),
          ]),
          Row(children: [
            const Icon(Icons.deblur, size: 20),
            Expanded(
              child: Slider(
                value: sharp,
                min: 0,
                max: 1,
                onChanged: busy ? null : (v) => setState(() => sharp = v),
                onChangeEnd: busy
                    ? null
                    : (_) {
                        _resharp();
                        _mark();
                      },
              ),
            ),
            const Text('حدة', style: TextStyle(fontSize: 12, color: Colors.grey)),
            _favBtn(),
          ]),
        ]);
    }
  }

  Widget _barBtn(IconData i, String label, bool on, VoidCallback? onTap) {
    final col = on ? const Color(0xFF1EC8A5) : Theme.of(context).colorScheme.onSurface;
    return InkResponse(
      onTap: onTap,
      radius: 36,
      child: SizedBox(
        width: 62,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(i, color: onTap == null ? Colors.grey : col, size: 27),
          const SizedBox(height: 3),
          Text(label,
              maxLines: 1,
              style: TextStyle(fontSize: 11, color: onTap == null ? Colors.grey : col)),
        ]),
      ),
    );
  }

  Widget _pagerBtn(IconData i, VoidCallback? onTap) => InkResponse(
        onTap: onTap,
        radius: 26,
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: onTap == null ? Colors.black12 : Colors.black26,
          ),
          child: Icon(i, size: 24, color: onTap == null ? Colors.grey : null),
        ),
      );

  /// عداد الصفحات (زي كام اسكنر): < 1/3 >. السهم اليمين في آخر صفحة = إضافة صورة.
  Widget _pager() {
    final last = widget.pageIndex >= widget.pageCount - 1;
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          _pagerBtn(Icons.chevron_left, (busy || widget.pageIndex <= 0) ? null : () => _nav('prev')),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Text('${widget.pageIndex + 1}/${widget.pageCount}',
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
          ),
          _pagerBtn(last ? Icons.add_a_photo_outlined : Icons.chevron_right, busy ? null : () => _nav('next')),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('تعديل الصورة'),
        actions: [
          IconButton(
            tooltip: 'تراجع',
            icon: const Icon(Icons.undo),
            onPressed: (busy || !_canUndo) ? null : _undo,
          ),
          IconButton(
            tooltip: 'إعادة',
            icon: const Icon(Icons.redo),
            onPressed: (busy || !_canRedo) ? null : _redo,
          ),
          if (widget.pageCount > 1)
            PopupMenuButton<String>(
              tooltip: 'المزيد',
              enabled: !busy,
              onSelected: (_) => _confirmApplyAll(),
              itemBuilder: (_) => const [
                PopupMenuItem<String>(value: 'all', child: Text('طبّق الفلتر على كل الصفحات')),
              ],
            ),
          if (widget.canDelete)
            IconButton(
              tooltip: 'حذف الصفحة',
              icon: const Icon(Icons.delete_outline),
              onPressed: busy ? null : _confirmDelete,
            ),
        ],
      ),
      body: (aspect == null || view == null)
          ? const Center(child: CircularProgressIndicator())
          : Column(children: [
              Expanded(
                child: Padding(
                  padding: EdgeInsets.zero,
                  child: LayoutBuilder(builder: (ctx, cons) {
                    const pad = 14.0;
                    final asp = turns.isOdd ? 1 / aspect! : aspect!;
                    final maxW = cons.maxWidth - 2 * pad, maxH = cons.maxHeight - 2 * pad;
                    var w = maxW, h = w * asp;
                    if (h > maxH) {
                      h = maxH;
                      w = h / asp;
                    }
                    final size = Size(w, h);
                    final focus = _focus(size);
                    final pan = _clampPan(_pan, size);
                    final zoomed = _zm > 1.001;
                    const origin = Offset(pad, pad);
                    return Center(
                      child: SizedBox(
                        width: w + 2 * pad,
                        height: h + 2 * pad,
                        child: Listener(
                          behavior: HitTestBehavior.opaque,
                          onPointerDown: (e) => _ptrDown(e, origin, size),
                          onPointerMove: (e) => _ptrMove(e, origin, size),
                          onPointerUp: (e) => _ptrUp(e, size),
                          onPointerCancel: (e) => _ptrUp(e, size, cancel: true),
                          child: Padding(
                            padding: const EdgeInsets.all(pad),
                            child: Stack(clipBehavior: zoomed ? Clip.hardEdge : Clip.none, children: [
                              Transform(
                                transform: Matrix4.translationValues(pan.dx, pan.dy, 0) *
                                    Matrix4.diagonal3Values(_zm, _zm, 1),
                                child: _img(w, h),
                              ),
                              Positioned.fill(child: CustomPaint(painter: _QuadPainter(quad, _zm, pan))),
                              if (focus != null) _loupe(focus, size),
                              if (zoomed)
                                Positioned(
                                  left: 6,
                                  bottom: 6,
                                  child: GestureDetector(
                                    onTap: () => setState(() {
                                      _zm = 1;
                                      _pan = Offset.zero;
                                    }),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                      decoration: BoxDecoration(
                                          color: Colors.black54, borderRadius: BorderRadius.circular(16)),
                                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                                        const Icon(Icons.zoom_out_map, size: 16, color: Colors.white),
                                        const SizedBox(width: 4),
                                        Text('×${_zm.toStringAsFixed(1)}',
                                            style: const TextStyle(color: Colors.white, fontSize: 12)),
                                      ]),
                                    ),
                                  ),
                                ),
                            ]),
                          ),
                        ),
                      ),
                    );
                  }),
                ),
              ),
              if (widget.pageCount > 0) _pager(),
              SizedBox(
                height: tab == 2 ? 150 : 112,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: _panel(),
                ),
              ),
              SafeArea(
                top: false,
                child: Container(
                  color: Colors.black12,
                  padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
                  child: Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
                    if (widget.canRetake)
                      _barBtn(Icons.cameraswitch_outlined, 'إعادة أخذ', false,
                          busy ? null : () => Navigator.pop(context, kRetake)),
                    _barBtn(Icons.rotate_left, 'يسار', tab == 1, busy
                        ? null
                        : () => setState(() {
                              tab = 1;
                              turns = (turns + 3) % 4;
                              quad = _turnCcw(quad);
                              _loadView();
                            })),
                    _barBtn(Icons.auto_awesome, 'فلتر', tab == 2, () => setState(() => tab = 2)),
                    _barBtn(Icons.crop, 'قص', tab == 0, () => setState(() => tab = 0)),
                    InkResponse(
                      onTap: (busy || aspect == null) ? null : _apply,
                      radius: 40,
                      child: Container(
                        width: 78,
                        height: 46,
                        decoration: BoxDecoration(
                          color: const Color(0xFF1EC8A5),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: busy
                            ? const Center(
                                child: SizedBox(
                                    width: 22,
                                    height: 22,
                                    child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white)))
                            : const Icon(Icons.check, color: Colors.white, size: 30),
                      ),
                    ),
                  ]),
                ),
              ),
            ]),
    );
  }
}

/// بيرسم الصورة (تدوير دقيق + ألوان) من غير ColorFiltered ولا Image.file، فالذاكرة قليلة.
/// لو focus موجود بيرسم عدسة مكبّرة حوالين النقطة دي.
class _ViewPainter extends CustomPainter {
  final ui.Image img;
  final Size box;
  final double angle; // راديان
  final List<double> m;
  final Offset? focus;
  final double zoom;
  _ViewPainter(this.img, this.box, this.angle, this.m, {this.focus, this.zoom = 1});

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    if (focus != null) {
      canvas.translate(size.width / 2 - focus!.dx * zoom, size.height / 2 - focus!.dy * zoom);
      canvas.scale(zoom);
    }
    final r = Offset.zero & box;
    canvas.clipRect(r);
    canvas.drawRect(
        r,
        Paint()
          ..color = Colors.white
          ..colorFilter = ColorFilter.matrix(m));
    canvas.translate(box.width / 2, box.height / 2);
    canvas.rotate(angle);
    canvas.translate(-box.width / 2, -box.height / 2);
    canvas.drawImageRect(
        img,
        Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
        r,
        Paint()
          ..colorFilter = ColorFilter.matrix(m)
          ..filterQuality = FilterQuality.medium);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ViewPainter o) => true;
}

class _QuadPainter extends CustomPainter {
  final List<Offset> q;
  final double zm;
  final Offset pan;
  _QuadPainter(this.q, [this.zm = 1, this.pan = Offset.zero]);

  @override
  void paint(Canvas canvas, Size s) {
    final pts = [for (final p in q) Offset(p.dx * s.width * zm + pan.dx, p.dy * s.height * zm + pan.dy)];
    final poly = Path()..addPolygon(pts, true);
    canvas.drawPath(
        Path.combine(PathOperation.difference, Path()..addRect(Offset.zero & s), poly),
        Paint()..color = Colors.black54);
    canvas.drawPath(
        poly,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = Colors.white);
    final fill = Paint()..color = Colors.white;
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = const Color(0xFF0B5FA5);
    for (var i = 0; i < 4; i++) {
      final m = (pts[i] + pts[(i + 1) % 4]) / 2;
      canvas.drawCircle(m, 7, fill);
      canvas.drawCircle(m, 7, ring);
    }
    for (final p in pts) {
      canvas.drawCircle(p, 11, fill);
      canvas.drawCircle(p, 11, ring);
    }
  }

  @override
  bool shouldRepaint(_QuadPainter o) => o.q != q || o.zm != zm || o.pan != pan;
}

// =====================================================================
//  معاينة ملف الـ PDF بعد إنشائه (كل الصفحات) + مشاركة PDF / صور
// =====================================================================

class PdfResultScreen extends StatefulWidget {
  final Session session;
  final File pdf;
  final List<String> imgs; // نفس ترتيب صفحات الـ PDF
  const PdfResultScreen({super.key, required this.session, required this.pdf, required this.imgs});
  @override
  State<PdfResultScreen> createState() => _PdfResultScreenState();
}

class _PdfResultScreenState extends State<PdfResultScreen> {
  Tag? tag;
  final Set<String> noTags = {};
  bool busy = false;
  bool shared = false; // اتبعت PDF أو الصور فعلاً
  String? progress;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final t = await receiptTag(1000, widget.session);
      final nts = <String>{};
      for (final x in widget.imgs) {
        if (await Store.noTag(x)) nts.add(x);
      }
      if (!mounted) return;
      setState(() {
        tag = t;
        noTags
          ..clear()
          ..addAll(nts);
      });
    } catch (e, st) {
      AppLog.e('PdfResultScreen._load', e, st);
      if (mounted) snack(context, 'تعذر تجهيز المعاينة');
    }
  }

  void _markShared() {
    HapticFeedback.mediumImpact();
    if (!mounted) return;
    setState(() => shared = true);
    snack(context, 'اتبعت ✓ اضغط "تم" لما تخلص');
  }

  Future<void> _sharePdf() async {
    if (busy) return;
    final ok = await shareFiles(context, [widget.pdf.path]);
    if (ok) _markShared();
  }

  Future<void> _shareImages() async {
    if (busy) return;
    final n = widget.imgs.length;
    setState(() {
      busy = true;
      progress = '0/$n';
    });
    final files = <String>[];
    try {
      final dir = await getTemporaryDirectory();
      for (var i = 0; i < n; i++) {
        final bytes = await composeReceiptImage(widget.imgs[i], widget.session);
        final f = File('${dir.path}/${widget.session.pdfName}_${i + 1}.jpg');
        await f.writeAsBytes(bytes, flush: true);
        files.add(f.path);
        if (mounted) setState(() => progress = '${i + 1}/$n');
      }
    } catch (e, st) {
      AppLog.e('PdfResultScreen._shareImages', e, st);
      if (mounted) snack(context, 'حصل خطأ: ${errText(e)}');
      files.clear();
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
          progress = null;
        });
      }
    }
    if (files.isEmpty || !mounted) return;
    final ok = await shareFiles(context, files);
    if (ok) _markShared();
  }

  Future<void> _done() async {
    await Store.afterPdfSent();
    if (mounted) Navigator.pop(context, true);
  }

  Widget _page(int i) {
    final path = widget.imgs[i];
    final show = !noTags.contains(path);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text('صفحة ${i + 1} من ${widget.imgs.length}',
              style: const TextStyle(color: Colors.grey, fontSize: 12)),
        ),
        GestureDetector(
          onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => ZoomPage(
                      child: ReceiptPreview(path: path, tag: tag!, showTag: show)))),
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: Colors.black26),
              boxShadow: const [BoxShadow(blurRadius: 4, color: Colors.black12)],
            ),
            child: ReceiptPreview(path: path, tag: tag!, cacheWidth: 900, showTag: show),
          ),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.imgs.length;
    return Scaffold(
      appBar: AppBar(
        title: Text('معاينة الملف ($n صفحة)'),
        actions: [
          if (shared)
            TextButton.icon(
              onPressed: busy ? null : _done,
              icon: const Icon(Icons.check),
              label: const Text('تم'),
            ),
        ],
      ),
      body: Column(children: [
        Expanded(
          child: tag == null
              ? const Center(child: CircularProgressIndicator())
              : ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: n,
                  itemBuilder: (_, i) => _page(i),
                ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            child: Row(children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: busy ? null : _sharePdf,
                  icon: const Icon(Icons.picture_as_pdf),
                  label: const Text('مشاركة PDF'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: busy ? null : _shareImages,
                  icon: busy
                      ? const SizedBox(
                          width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.image),
                  label: Text(progress != null ? 'تجهيز $progress' : 'مشاركة صور'),
                ),
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}

// =====================================================================
//  شاشة إيصالات الدفع
// =====================================================================

// =====================================================================
//  كاميرا التطبيق (شكل كام اسكنر): كل الأدوات أيقونات تحت، وعداد الصور على المصغّرة
// =====================================================================

/// حالة الكاميرا بعد ما الشاشة اللي فوقها (تعديل / معرض) تخلص.
class A2RCamState {
  final int count; // عدد الصور المحفوظة لحد دلوقتي
  final String? thumb; // آخر صورة (للمصغّرة)
  final bool close; // اقفل الكاميرا (الباتش بعد أول صورة)
  const A2RCamState({this.count = 0, this.thumb, this.close = false});
}

class A2RCameraScreen extends StatefulWidget {
  final String title; // مكتوب تحت المعاينة (إيصالات / باتش)
  final bool single; // true: تقفل بعد أول صورة (الباتش)
  final int count;
  final String? thumb;
  final Future<A2RCamState?> Function(String path) onShot;
  final Future<A2RCamState?> Function()? onGallery;
  const A2RCameraScreen({
    super.key,
    required this.title,
    required this.onShot,
    this.onGallery,
    this.single = false,
    this.count = 0,
    this.thumb,
  });
  @override
  State<A2RCameraScreen> createState() => _A2RCameraScreenState();
}

class _A2RCameraScreenState extends State<A2RCameraScreen> with WidgetsBindingObserver {
  cam.CameraController? _c;
  String? _err;
  bool _ready = false;
  bool _starting = false; // يمنع تشغيل الكاميرا مرتين في نفس الوقت
  bool _shooting = false;
  bool _hd = true;
  int _flash = 0; // 0 مقفول، 1 تلقائي، 2 فلاش، 3 كشاف
  bool _grid = false; // شبكة الأثلاث للمحاذاة
  late int _count = widget.count;
  String? _thumb;
  double _minZoom = 1, _maxZoom = 1, _zoom = 1, _zoom0 = 1;
  Offset? _focusAt;
  List<Offset>? _liveQuad; // التحديد التلقائي الحي فوق المعاينة
  bool _live = false, _liveBusy = false;
  int _lastLive = 0, _liveMiss = 0;

  static const _flashIcons = [Icons.flash_off, Icons.flash_auto, Icons.flash_on, Icons.highlight];
  static const _flashNames = ['الفلاش مقفول', 'فلاش تلقائي', 'فلاش', 'كشاف'];

  @override
  void initState() {
    super.initState();
    _thumb = widget.thumb;
    WidgetsBinding.instance.addObserver(this);
    SharedPreferences.getInstance().then((p) {
      _hd = p.getBool('camHd') ?? true;
      _flash = p.getInt('camFlash') ?? 0;
      _grid = p.getBool('camGrid') ?? false;
      _start();
    }).catchError((Object e, StackTrace st) {
      AppLog.e('cam.prefs', e, st);
      _start();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _c?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_c == null && !_starting) _start();
      return;
    }
    final c = _c;
    if (c == null) return;
    if (state == AppLifecycleState.inactive) {
      _c = null;
      _live = false;
      _liveQuad = null;
      c.dispose();
      if (mounted) setState(() => _ready = false);
    }
  }

  Future<void> _start() async {
    if (_starting) return;
    _starting = true;
    try {
      final old = _c;
      _c = null;
      _live = false;
      _liveQuad = null;
      if (mounted) setState(() => _ready = false);
      await old?.dispose();
      final cams = await cam.availableCameras();
      if (cams.isEmpty) throw Exception('مفيش كاميرا على الجهاز');
      final back = cams.firstWhere((x) => x.lensDirection == cam.CameraLensDirection.back,
          orElse: () => cams.first);
      final perf = await Store.perfMode();
      final slow = (await SharedPreferences.getInstance()).getBool('camSlow') ?? false;
      // الصورة بتتحفظ بحد أقصى 800/1400/2400، فمفيش داعي لـ 4K غير في الوضع "برو".
      // الجهاز اللي التصوير فيه بطيء بيتنزّل له درجة تلقائياً.
      late final cam.ResolutionPreset preset;
      if (perf == PerfMode.pro) {
        preset = _hd && !slow ? cam.ResolutionPreset.ultraHigh : cam.ResolutionPreset.veryHigh;
      } else if (perf == PerfMode.balanced) {
        preset = _hd && !slow ? cam.ResolutionPreset.veryHigh : cam.ResolutionPreset.high;
      } else {
        preset = cam.ResolutionPreset.high;
      }
      // YUV420 عشان نقدر نحلل الإطارات للتحديد الحي (التصوير نفسه لسه JPEG)
      final c = cam.CameraController(back, preset,
          enableAudio: false,
          imageFormatGroup:
              Platform.isAndroid ? cam.ImageFormatGroup.yuv420 : cam.ImageFormatGroup.bgra8888);
      await c.initialize();
      try {
        await c.lockCaptureOrientation(DeviceOrientation.portraitUp);
      } catch (_) {}
      await _applyFlash(c);
      try {
        await c.setFocusMode(cam.FocusMode.auto);
      } catch (_) {}
      _minZoom = await c.getMinZoomLevel();
      _maxZoom = math.min(await c.getMaxZoomLevel(), 6.0);
      _zoom = _minZoom;
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() {
        _c = c;
        _ready = true;
        _err = null;
      });
      unawaited(_startLive(c));
    } catch (e, st) {
      AppLog.e('cam.start', e, st);
      if (mounted) setState(() => _err = errText(e));
    } finally {
      _starting = false;
    }
  }

  Future<void> _startLive(cam.CameraController c) async {
    if (_live || !mounted || !c.value.isInitialized || c.value.isStreamingImages) return;
    try {
      if (await Store.perfMode() == PerfMode.lite) return;
      _liveMiss = 0;
      await c.startImageStream(_onFrame);
      _live = true;
    } catch (e, st) {
      AppLog.e('cam.live', e, st);
    }
  }

  Future<void> _stopLive() async {
    final c = _c;
    _live = false;
    _liveQuad = null;
    if (c == null) return;
    try {
      if (c.value.isStreamingImages) await c.stopImageStream();
    } catch (_) {}
  }

  void _onFrame(cam.CameraImage f) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!_live || _liveBusy || now - _lastLive < 200 || !mounted) return;
    _liveBusy = true;
    _lastLive = now;
    try {
      var q = _liveDetect(f, _c?.description.sensorOrientation ?? 90);
      final prev = _liveQuad;
      if (q == null) {
        if (++_liveMiss <= 3) return; // نثبّت آخر تحديد شوية بدل ما يومض
      } else {
        _liveMiss = 0;
        if (prev != null) {
          q = [for (var i = 0; i < 4; i++) Offset.lerp(prev[i], q[i], 0.5)!];
        }
      }
      if (mounted && _live) setState(() => _liveQuad = q);
    } catch (e, st) {
      AppLog.e('cam.liveFrame', e, st);
    } finally {
      _liveBusy = false;
    }
  }

  Future<void> _applyFlash(cam.CameraController c) async {
    try {
      await c.setFlashMode(const [
        cam.FlashMode.off,
        cam.FlashMode.auto,
        cam.FlashMode.always,
        cam.FlashMode.torch,
      ][_flash]);
    } catch (_) {}
  }

  Future<void> _toggleGrid() async {
    HapticFeedback.selectionClick();
    setState(() => _grid = !_grid);
    try {
      (await SharedPreferences.getInstance()).setBool('camGrid', _grid);
    } catch (_) {}
  }

  Future<void> _cycleFlash() async {
    final c = _c;
    if (c == null) return;
    HapticFeedback.selectionClick();
    setState(() => _flash = (_flash + 1) % 4);
    await _applyFlash(c);
    try {
      (await SharedPreferences.getInstance()).setInt('camFlash', _flash);
    } catch (_) {}
    if (mounted) snack(context, _flashNames[_flash]);
  }

  Future<void> _toggleHd() async {
    HapticFeedback.selectionClick();
    setState(() => _hd = !_hd);
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setBool('camHd', _hd);
      await sp.remove('camSlow'); // اختيار الموظف بيلغي التنزيل التلقائي
    } catch (_) {}
    await _start();
  }

  void _apply(A2RCamState? s) {
    if (s == null || !mounted) return;
    if (s.close) {
      Navigator.pop(context);
      return;
    }
    setState(() {
      _count = s.count;
      _thumb = s.thumb;
    });
  }

  Future<void> _shot() async {
    final c = _c;
    if (c == null || !c.value.isInitialized || _shooting) return;
    setState(() => _shooting = true);
    try {
      HapticFeedback.mediumImpact();
      final lq = _liveQuad;
      _shotQuad = lq == null ? null : List<Offset>.of(lq);
      final swShot = Stopwatch()..start();
      await _stopLive();
      final x = await c.takePicture();
      final shotMs = swShot.elapsedMilliseconds;
      AppLog.i('t takePicture ${shotMs}ms');
      if (shotMs > 2500) {
        try {
          (await SharedPreferences.getInstance()).setBool('camSlow', true);
        } catch (_) {}
      }
      try {
        await c.pausePreview();
      } catch (_) {}
      final s = await widget.onShot(x.path);
      AppLog.i('t shot+edit total ${swShot.elapsedMilliseconds}ms');
      if (!mounted) return;
      try {
        await c.resumePreview();
      } catch (_) {}
      if (widget.single && s == null) return; // الموظف رجع من التعديل: يصوّر تاني
      _apply(s);
    } catch (e, st) {
      AppLog.e('cam.shot', e, st);
      if (mounted) snack(context, 'تعذر التصوير: ${errText(e)}');
    } finally {
      if (mounted) {
        setState(() => _shooting = false);
        final cc = _c;
        if (cc != null) unawaited(_startLive(cc));
      }
    }
  }

  /// لو كاميرا التطبيق مش شغالة على الموبايل ده: كاميرا النظام بدالها.
  Future<void> _systemCamera() async {
    try {
      final x = await ImagePicker().pickImage(source: ImageSource.camera, maxWidth: 2000, imageQuality: 90);
      if (x == null || !mounted) return;
      _apply(await widget.onShot(x.path));
    } catch (e, st) {
      AppLog.e('cam.system', e, st);
      if (mounted) snack(context, 'تعذر فتح الكاميرا');
    }
  }

  Future<void> _gallery() async {
    final g = widget.onGallery;
    if (g == null) return;
    final c = _c;
    await _stopLive();
    try {
      await c?.pausePreview();
    } catch (_) {}
    final s = await g();
    if (!mounted) return;
    try {
      await c?.resumePreview();
    } catch (_) {}
    if (c != null && identical(c, _c)) unawaited(_startLive(c));
    _apply(s);
  }

  Future<void> _tapFocus(TapDownDetails d, Size box) async {
    final c = _c;
    if (c == null || !c.value.isInitialized) return;
    final p = Offset(d.localPosition.dx / box.width, d.localPosition.dy / box.height);
    setState(() => _focusAt = d.localPosition);
    try {
      await c.setFocusPoint(p);
      await c.setExposurePoint(p);
    } catch (_) {}
    Future.delayed(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _focusAt = null);
    });
  }

  Widget _icon(IconData i, String label, VoidCallback? onTap, {bool on = false}) {
    final col = on ? const Color(0xFF1EC8A5) : Colors.white;
    return InkResponse(
      onTap: onTap,
      radius: 32,
      child: SizedBox(
        width: 64,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(i, color: col, size: 28),
          const SizedBox(height: 2),
          Text(label, style: TextStyle(color: col, fontSize: 11), maxLines: 1),
        ]),
      ),
    );
  }

  Widget _thumbBox() {
    final t = _thumb;
    return GestureDetector(
      onTap: (_count > 0 && !_shooting) ? () => Navigator.pop(context) : null,
      child: SizedBox(
        width: 64,
        height: 64,
        child: Stack(clipBehavior: Clip.none, children: [
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.white54, width: 1.5),
                color: Colors.white10,
              ),
              clipBehavior: Clip.antiAlias,
              child: t != null
                  ? Image.file(File(t), fit: BoxFit.cover, cacheWidth: 160, errorBuilder: (_, __, ___) => const SizedBox())
                  : const Icon(Icons.photo_library_outlined, color: Colors.white38),
            ),
          ),
          if (_count > 0)
            Positioned(
              top: -8,
              left: -8,
              child: Container(
                constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                padding: const EdgeInsets.symmetric(horizontal: 6),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: const Color(0xFFFF6A4D),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.black, width: 1.5),
                ),
                child: Text('$_count',
                    style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
              ),
            ),
        ]),
      ),
    );
  }

  Widget _preview() {
    if (_err != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.no_photography, color: Colors.white54, size: 48),
            const SizedBox(height: 12),
            Text('كاميرا التطبيق مش شغالة على الموبايل ده\n$_err',
                textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 16),
            FilledButton(onPressed: _systemCamera, child: const Text('استخدم كاميرا النظام')),
            TextButton(onPressed: _start, child: const Text('حاول تاني')),
          ]),
        ),
      );
    }
    final c = _c;
    if (!_ready || c == null || !c.value.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }
    return LayoutBuilder(builder: (ctx, cons) {
      final box = Size(cons.maxWidth, cons.maxHeight);
      final ar = 1 / c.value.aspectRatio; // عرض/طول في الوضع الرأسي
      final pw0 = ar * 1000, ph0 = 1000.0;
      final sc = math.min(box.width / pw0, box.height / ph0);
      final pvW = pw0 * sc, pvH = ph0 * sc;
      final pvL = (box.width - pvW) / 2, pvT = (box.height - pvH) / 2;
      return GestureDetector(
        onTapDown: (d) => _tapFocus(d, box),
        onScaleStart: (_) => _zoom0 = _zoom,
        onScaleUpdate: (d) async {
          if (d.pointerCount < 2) return;
          final z = (_zoom0 * d.scale).clamp(_minZoom, _maxZoom).toDouble();
          if ((z - _zoom).abs() < 0.02) return;
          _zoom = z;
          try {
            await c.setZoomLevel(z);
          } catch (_) {}
        },
        child: Stack(alignment: Alignment.center, children: [
          ClipRect(
            child: FittedBox(
              fit: BoxFit.contain,
              child: SizedBox(width: ar * 1000, height: 1000, child: cam.CameraPreview(c)),
            ),
          ),
          if (_grid) const Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: _GridPainter()))),
          if (_liveQuad != null)
            Positioned(
              left: pvL,
              top: pvT,
              width: pvW,
              height: pvH,
              child: IgnorePointer(child: CustomPaint(painter: _LiveQuadPainter(_liveQuad!))),
            ),
          if (_focusAt != null)
            Positioned(
              left: _focusAt!.dx - 30,
              top: _focusAt!.dy - 30,
              child: IgnorePointer(
                child: Container(
                  width: 60,
                  height: 60,
                  decoration: BoxDecoration(
                    border: Border.all(color: const Color(0xFF1EC8A5), width: 2),
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ),
        ]),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Column(children: [
            Expanded(child: _preview()),
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(widget.title,
                  style: const TextStyle(color: Color(0xFF1EC8A5), fontSize: 15, fontWeight: FontWeight.w600)),
            ),
            // صف الأيقونات: إغلاق، فلاش، جودة، معرض
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
              child: Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
                _icon(Icons.close, 'إغلاق', () => Navigator.pop(context)),
                _icon(_flashIcons[_flash], 'فلاش', _cycleFlash, on: _flash != 0),
                _icon(Icons.hd, _hd ? 'جودة عالية' : 'جودة عادية', _toggleHd, on: _hd),
                _icon(Icons.grid_3x3, 'شبكة', _toggleGrid, on: _grid),
                if (widget.onGallery != null) _icon(Icons.photo_library_outlined, 'معرض', _gallery),
              ]),
            ),
            // صف التصوير: المصغّرة بالعداد، الزر، تم
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 14, 28, 18),
              child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                _thumbBox(),
                GestureDetector(
                  onTap: _shot,
                  child: Container(
                    width: 78,
                    height: 78,
                    padding: const EdgeInsets.all(5),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: const Color(0xFF1EC8A5), width: 4),
                    ),
                    child: Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _shooting ? Colors.white54 : Colors.white,
                      ),
                    ),
                  ),
                ),
                SizedBox(
                  width: 64,
                  child: (!widget.single && _count > 0)
                      ? InkResponse(
                          onTap: _shooting ? null : () => Navigator.pop(context),
                          radius: 36,
                          child: Container(
                            height: 48,
                            decoration: BoxDecoration(
                                color: const Color(0xFF1EC8A5), borderRadius: BorderRadius.circular(10)),
                            child: const Icon(Icons.check, color: Colors.white, size: 30),
                          ),
                        )
                      : const SizedBox(),
                ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

class ReceiptsScreen extends StatefulWidget {
  final Session session;
  const ReceiptsScreen({super.key, required this.session});
  @override
  State<ReceiptsScreen> createState() => _ReceiptsScreenState();
}

class _ReceiptsScreenState extends State<ReceiptsScreen> {
  List<String> imgs = [];
  Tag? tag;
  File? built;
  bool busy = false;
  bool loaded = false;
  bool continuous = true;
  ScanFilter filter = ScanFilter.receipt;
  String? progress;
  final Set<String> noTags = {}; // إيصالات من غير ورقة

  Future<void> _toggleTag(String path) async {
    final hide = !noTags.contains(path);
    await Store.setNoTag(path, hide);
    if (built != null) await Store.clearPdf(); // الـ PDF القديم مبقاش مظبوط
    if (!mounted) return;
    setState(() {
      if (hide) {
        noTags.add(path);
      } else {
        noTags.remove(path);
      }
      built = null;
    });
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final d = await Store.draft();
    final t = await receiptTag(1000, widget.session);
    final f = await Store.pdf();
    final used = await Store.pdfImgs();
    final fl = await Store.filter();
    final co = await Store.continuous();
    final nts = <String>{};
    for (final x in d) {
      if (await Store.noTag(x)) nts.add(x);
    }
    File? b;
    if (f != null && d.isNotEmpty && used.length == d.length) {
      var same = true;
      for (var i = 0; i < d.length; i++) {
        if (d[i] != used[i]) same = false;
      }
      if (same) b = f.file;
    }
    if (!mounted) return;
    setState(() {
      noTags
        ..clear()
        ..addAll(nts);
      imgs = d;
      tag = t;
      built = b;
      filter = fl;
      continuous = co;
      loaded = true;
    });
    final lost = await takeLostPick('receipts');
    if (lost != null && mounted) {
      await _saveAll([lost]);
      _lastScanManual = true;
      if (mounted && imgs.isNotEmpty) await _edit(imgs.length - 1, tab: 2);
      return;
    }
    if (d.isEmpty && mounted) await _chooseSource();
  }

  /// أول ما تفتح إيصالات الدفع وهي فاضية: اختار كاميرا ولا معرض.
  Future<void> _chooseSource() async {
    final c = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.add_a_photo),
            title: const Text('كاميرا'),
            onTap: () => Navigator.pop(ctx, 'camera'),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library),
            title: const Text('معرض'),
            onTap: () => Navigator.pop(ctx, 'gallery'),
          ),
          const SizedBox(height: 8),
        ]),
      ),
    );
    if (!mounted) return;
    if (c == 'camera') {
      await _add();
    } else if (c == 'gallery') {
      await _addGallery();
    }
  }

  A2RCamState _camState({bool close = false}) =>
      A2RCamState(count: imgs.length, thumb: imgs.isEmpty ? null : imgs.last, close: close);

  /// كاميرا التطبيق (شكل كام اسكنر): كل صورة بتتحفظ وتتفتح للتعديل، والكاميرا تفضل مفتوحة والعداد بيزيد.
  Future<void> _add() async {
    if (!await ensureCamera(context)) return;
    if (!mounted) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => A2RCameraScreen(
          title: 'إيصالات الدفع',
          single: !continuous,
          count: imgs.length,
          thumb: imgs.isEmpty ? null : imgs.last,
          onShot: (p) async {
            _lastScanManual = true; // من غير قص: شاشة التعديل تحدد حدود الورقة تلقائياً
            final before = imgs.length;
            await _saveAll([p]);
            if (mounted && imgs.length > before) {
              final retake = await _edit(imgs.length - 1, tab: 2, fromCam: true);
              if (retake && mounted) return _camState(); // إعادة أخذ: الصفحة اتمسحت والكاميرا مفتوحة
            }
            return _camState(close: !continuous && imgs.length > before);
          },
          onGallery: () async {
            await _addGallery();
            return _camState();
          },
        ),
      ),
    );
  }

  /// من المعرض: منتقي الصور بتاع النظام مباشرة وتقدر تحدد أكتر من صورة.
  /// كل صورة بتتحفظ الأول، وبعدين شاشة التعديل بتفتح لكل واحدة (ارجع لتتخطاها وتفضل محفوظة).
  Future<void> _addGallery() async {
    await markPickTarget('receipts');
    List<XFile> xs;
    try {
      xs = await ImagePicker().pickMultiImage(maxWidth: 2000, imageQuality: 90);
    } catch (e, st) {
      AppLog.e('_addGallery', e, st);
      if (mounted) snack(context, 'تعذر فتح المعرض');
      return;
    }
    if (xs.isEmpty || !mounted) return;
    _lastScanManual = true; // صور من غير قص: شاشة التعديل تحدد حدود الورقة تلقائياً
    final start = imgs.length;
    await _saveAll(xs.map((e) => e.path).toList());
    for (var i = start; i < imgs.length; i++) {
      if (!mounted) break;
      await _edit(i, tab: 2);
    }
  }

  Future<void> _saveAll(List<String> r) async {
    setState(() => busy = true);
    var added = 0;
    try {
      for (final p in r) {
        final saved = await persistImage(
            p, 'r_${DateTime.now().microsecondsSinceEpoch}.jpg',
            filter: filter);
        await Store.addToDraft(saved);
        imgs.add(saved);
        added++;
      }
      built = null;
      HapticFeedback.lightImpact();
      if (imgs.isNotEmpty) {
        unawaited(qualityWarning(imgs.last).then((warn) {
          if (warn != null && mounted) snack(context, warn);
        }));
      }
    } catch (e) {
      if (mounted) snack(context, 'حصل خطأ: ${errText(e)}');
    } finally {
      if (mounted) setState(() => busy = false);
    }
    if (added > 0 && mounted && r.length > 1) snack(context, 'اتضاف $added إيصال');
  }

  /// مسح مع "تراجع": الملف بيتمسح فعلاً بعد ما الرسالة تختفي من غير ما تضغط تراجع.
  Future<void> _remove(int i) async {
    if (i < 0 || i >= imgs.length) return;
    final path = imgs[i];
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    await Store.unlistFromDraft(path);
    if (!mounted) {
      await Store.del(path);
      return;
    }
    setState(() {
      imgs.remove(path);
      built = null;
    });
    final ctrl = messenger.showSnackBar(SnackBar(
      content: const Text('اتمسح الإيصال'),
      duration: const Duration(seconds: 6),
      action: SnackBarAction(
        label: 'تراجع',
        onPressed: () async {
          await Store.relistInDraft(path, i);
          if (!mounted) return;
          setState(() {
            if (!imgs.contains(path)) imgs.insert(i.clamp(0, imgs.length), path);
            built = null;
          });
        },
      ),
    ));
    final reason = await ctrl.closed;
    if (reason != SnackBarClosedReason.action) await Store.del(path);
  }

  Future<void> _reorder(int oldI, int newI) async {
    if (newI > oldI) newI -= 1;
    setState(() {
      final x = imgs.removeAt(oldI);
      imgs.insert(newI, x);
      built = null;
    });
    await Store.setDraft(imgs);
  }

  Future<void> _create() async {
    setState(() {
      busy = true;
      progress = '0/${imgs.length}';
    });
    try {
      final f = await buildReceiptsPdf(widget.session, imgs, onProgress: (d, t) {
        if (mounted) setState(() => progress = '$d/$t');
      });
      await Store.setPdf(f, List.of(imgs));
      HapticFeedback.mediumImpact();
      if (mounted) setState(() => built = f);
    } catch (e) {
      if (mounted) snack(context, 'حصل خطأ: ${errText(e)}');
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
          progress = null;
        });
      }
    }
  }

  /// ضغطة واحدة: يجهّز الـ PDF وبعدها يفتح شاشة المعاينة (مشاركة PDF / مشاركة صور).
  Future<void> _createAndSend() async {
    await _create();
    if (!mounted || built == null) return;
    await _send();
  }

  Future<void> _send() async {
    final f = built;
    if (f == null) return;
    final done = await Navigator.push<bool>(
        context,
        MaterialPageRoute(
            builder: (_) =>
                PdfResultScreen(session: widget.session, pdf: f, imgs: List.of(imgs))));
    if (done == true && mounted) Navigator.pop(context);
  }

  /// تطبيق الفلتر والسطوع والتباين والحدة على كل الصفحات (القص والتدوير بتاع كل صفحة زي ما هما).
  Future<void> _applyToAll(EditParams style, String exceptPath) async {
    if (!mounted) return;
    setState(() {
      busy = true;
      progress = '0/${imgs.length}';
    });
    var failed = 0;
    try {
      for (var i = 0; i < imgs.length; i++) {
        final p = imgs[i];
        if (p == exceptPath) continue;
        if (mounted) setState(() => progress = '${i + 1}/${imgs.length}');
        try {
          final old = await Store.editOf(p);
          final ep = EditParams(
            quad: old?.quad,
            turns: old?.turns ?? 0,
            angle: old?.angle ?? 0,
            filter: style.filter,
            contrast: style.contrast,
            brightness: style.brightness,
            sharp: style.sharp,
          );
          final np = await renderEditedPage(p, 'r_', ep);
          await Store.replaceInDraft(p, np);
          if (mounted) {
            setState(() {
              imgs[i] = np;
              built = null;
            });
          }
        } catch (e, st) {
          failed++;
          AppLog.e('applyToAll', e, st);
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
          progress = null;
        });
      }
    }
    if (mounted) {
      snack(context, failed == 0 ? 'اتطبق على كل الصفحات' : 'اتطبق، و$failed صفحة فشلت');
    }
  }

  /// تعديل إيصال بعد التصوير (قص، تدوير، فلتر) من النسخة الأصلية، مع التنقل بين الصفحات
  /// (أسهم / سويب)، والحذف، وإضافة صورة. بترجّع true لو الموظف داس "إعادة أخذ".
  Future<bool> _edit(int i, {int tab = 0, bool fromCam = false}) async {
    var idx = i;
    while (mounted && imgs.isNotEmpty) {
      idx = idx.clamp(0, imgs.length - 1);
      final old = imgs[idx];
      final out = await Navigator.push<String>(
        context,
        PageRouteBuilder<String>(
          transitionDuration: const Duration(milliseconds: 160),
          reverseTransitionDuration: const Duration(milliseconds: 120),
          pageBuilder: (_, __, ___) => EditorPage(
              path: old,
              prefix: 'r_',
              initialTab: tab,
              canRetake: fromCam,
              pageIndex: idx,
              pageCount: imgs.length,
              canDelete: true),
          transitionsBuilder: (_, a, __, child) => FadeTransition(opacity: a, child: child),
        ),
      );
      tab = 0; // الصفحات اللي بننتقل ليها بتفتح على القص
      if (!mounted || out == null) return false;
      if (out == kRetake || out == kDelete) {
        await Store.unlistFromDraft(old);
        await Store.del(old);
        if (mounted) {
          setState(() {
            imgs.remove(old);
            built = null;
          });
        }
        if (out == kRetake) return true;
        continue; // بعد الحذف: يفضل في التعديل على الصفحة اللي جنبها
      }
      var path = out;
      String? dir;
      EditParams? allStyle;
      if (out.startsWith('$kAllPrefix|')) {
        final parts = out.split('|');
        allStyle = EditParams.decode(parts[1]);
        path = parts.sublist(2).join('|');
      }
      if (out.startsWith('$kNavPrefix|')) {
        final parts = out.split('|');
        dir = parts[1];
        path = parts.sublist(2).join('|');
      }
      if (path != old) {
        try {
          await Store.replaceInDraft(old, path);
          if (!mounted) return false;
          setState(() {
            imgs[idx] = path;
            built = null;
          });
        } catch (e) {
          if (mounted) snack(context, 'حصل خطأ: ${errText(e)}');
          return false;
        }
      }
      if (allStyle != null) {
        await _applyToAll(allStyle, path);
        return false;
      }
      if (dir == null) return false; // ✓ تم
      if (dir == 'prev') {
        idx -= 1;
        continue;
      }
      idx += 1;
      if (idx >= imgs.length) {
        // آخر صفحة + "التالي": إضافة صورة جديدة
        if (fromCam) return false; // الكاميرا تحت: نرجعلها
        if (mounted) await _add();
        return false;
      }
    }
    return false;
  }

  Widget _item(int i) {
    final path = imgs[i];
    final cs = Theme.of(context).colorScheme;
    return Card(
      key: ValueKey(path),
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) => ZoomPage(
                    child: ReceiptPreview(
                        path: path, tag: tag!, showTag: !noTags.contains(path))))),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Row(children: [
            CircleAvatar(
                radius: 14,
                backgroundColor: cs.primary,
                child: Text('${i + 1}', style: TextStyle(color: cs.onPrimary, fontSize: 13))),
            const SizedBox(width: 10),
            // المصغّرة = الناتج النهائي: شريط أبيض بعرض الصورة والورقة في منتصفه فوق الإيصال
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Container(
                width: 96,
                height: 128,
                decoration: BoxDecoration(border: Border.all(color: Colors.black12)),
                child: FittedBox(
                  fit: BoxFit.cover,
                  alignment: Alignment.topCenter,
                  clipBehavior: Clip.hardEdge,
                  child: SizedBox(
                      width: 300,
                      child: ReceiptPreview(
                          path: path,
                          tag: tag!,
                          cacheWidth: 300,
                          showTag: !noTags.contains(path))),
                ),
              ),
            ),
            const SizedBox(width: 12),
            const Expanded(child: Text('اضغط للمعاينة', style: TextStyle(color: Colors.grey))),
            IconButton(
                tooltip: noTags.contains(path) ? 'إظهار الورقة' : 'إخفاء الورقة',
                icon: Icon(noTags.contains(path) ? Icons.label_off_outlined : Icons.label_outline),
                onPressed: busy ? null : () => _toggleTag(path)),
            IconButton(
                tooltip: 'تعديل',
                icon: const Icon(Icons.tune),
                onPressed: busy ? null : () => _edit(i)),
            IconButton(
                tooltip: 'مسح',
                icon: const Icon(Icons.delete_outline, color: Colors.red),
                onPressed: busy ? null : () => _remove(i)),
            ReorderableDragStartListener(
                index: i,
                child:
                    const Padding(padding: EdgeInsets.all(8), child: Icon(Icons.drag_handle))),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('إيصالات الدفع (${imgs.length})')),
      body: Column(children: [
        Expanded(
          child: !loaded
              ? const Center(child: CircularProgressIndicator())
              : imgs.isEmpty
                  ? Center(
                      child: busy
                          ? const CircularProgressIndicator()
                          : const Text('لسه مفيش صور', style: TextStyle(fontSize: 16)))
                  : ReorderableListView.builder(
                      padding: const EdgeInsets.all(12),
                      buildDefaultDragHandles: false,
                      itemCount: imgs.length,
                      onReorder: _reorder,
                      itemBuilder: (_, i) => _item(i),
                    ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              SizedBox(
                width: double.infinity,
                child: FilterBar(
                  selected: filter,
                  onChanged: busy
                      ? null
                      : (f) {
                          setState(() => filter = f);
                          Store.setFilter(f);
                        },
                ),
              ),
              Row(children: [
                const SizedBox(width: 4),
                const Expanded(
                    child: Text('تصوير متتالي (يفتح الكاميرا تاني بعد كل إيصال)',
                        style: TextStyle(fontSize: 12))),
                Switch(
                    value: continuous,
                    onChanged: (v) {
                      setState(() => continuous = v);
                      Store.setContinuous(v);
                    }),
              ]),
              Row(children: [
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: busy ? null : _add,
                    icon: const Icon(Icons.add_a_photo),
                    label: const Text('تصوير'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: busy ? null : _addGallery,
                    icon: const Icon(Icons.photo_library),
                    label: const Text('من المعرض'),
                  ),
                ),
              ]),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: FilledButton.icon(
                  onPressed: (busy || imgs.isEmpty) ? null : (built == null ? _createAndSend : _send),
                  icon: busy
                      ? const SizedBox(
                          width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : Icon(built == null ? Icons.picture_as_pdf : Icons.visibility),
                  label: Text(progress != null
                      ? 'جارى التجهيز $progress'
                      : (built == null ? 'إنشاء ومعاينة PDF' : 'معاينة ومشاركة')),
                ),
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}
