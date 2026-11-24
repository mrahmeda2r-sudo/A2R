import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:camera/camera.dart' as cam;
import 'package:flutter/foundation.dart' show compute, listEquals;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:google_mlkit_document_scanner/google_mlkit_document_scanner.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart' as mlt;
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
const kImageQualityRevision = 'receipt-q5-smooth';

const kTagFont = 0.05; // حجم خط الورقة (نسبة من عرض الصورة)
const kTagTop = 0.03; // بُعد ورقة الباتش عن أعلى الصورة
/// تصغير ورقة بيانات إيصالات الدفع (الباتش مش متأثر): الخط والهوامش بالنسبة دي.
const kReceiptTagScale = 1.0;
const kTagMinScale = 0.05; // أصغر حجم لورقة الباتش (نسبة من عرض الصورة)
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
          mode: FileMode.append);
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

/// مستوى الدقة اللي الموظف اختاره: 0 تلقائي (حسب وضع الأداء)، 1..4 من kResLevels.
int gResLevel = 0;

/// Receipt quality is independent of global performance/resolution preferences.
/// Persisted per image and passed explicitly to capture and export.
/// بدون تصغير تلقائي: الباتش والإيصالات بتتحفظ وتتعدّل وتتبعت بدقة الأصل.
const kNoResizeSide = 100000;

class ImageQualityProfile {
  final String id;
  final int maxSide;
  final int jpegQuality;
  const ImageQualityProfile(this.id, this.maxSide, this.jpegQuality);
  static const receipts = ImageQualityProfile('receipts-v1', kNoResizeSide, 100);
  static const detailedCapture = ImageQualityProfile('camera-detail-v1', 3200, 92);
  static const batch = ImageQualityProfile('batch-v1', kNoResizeSide, 100);
}

// Per-shot handoff only. Persisted on the image as soon as ingest consumes it.
final _captureProfiles = <String, ImageQualityProfile>{};
void _rememberCaptureProfile(String path, ImageQualityProfile profile) {
  if (_captureProfiles.length >= 8) _captureProfiles.remove(_captureProfiles.keys.first);
  _captureProfiles[path] = profile;
}

/// (رقم، الاسم، الرقم المختصر، أقصى ضلع بالبكسل)
const kResLevels = <(int, String, String, int)>[
  (1, 'صغيرة', '720p', 1000),
  (2, 'متوسطة', '1080p', 1600),
  (3, 'عالية', '4K', 2400),
  (4, 'أعلى', 'أقصى دقة', 3200),
];

String resShort(int l) => l <= 0 || l > kResLevels.length ? 'تلقائي' : kResLevels[l - 1].$3;

int getMaxSide(PerfMode mode, {ImageQualityProfile? profile}) =>
    profile?.maxSide ?? _getMaxSideBase(mode);

int _getMaxSideBase(PerfMode mode) {
  if (gResLevel > 0 && gResLevel <= kResLevels.length) {
    final v = kResLevels[gResLevel - 1].$4;
    return mode == PerfMode.lite ? math.min(v, 1400) : v;
  }
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
  clean,
  adaptive, // Append only: existing saved filter indices stay valid.
  gentle, // Fast color-preserving enhancement, append only.
}

/// ترتيب وأسماء الفلاتر في الشاشة (الإيصالات الأول لأنها الأهم).
// الفلاتر الظاهرة في شاشة التعديل. (enhance وmagic وgray وbw اتخفّوا من القايمة: مكررين أو ضعاف
// للإيصالات، لكن لسه موجودين في الكود عشان الصور والإعدادات القديمة اللي اتخزنت بأرقامهم تفضل شغالة)
const kFilterOrder = <ScanFilter>[
  ScanFilter.receipt,
  ScanFilter.thermal,
  ScanFilter.receiptBw,
  ScanFilter.adaptive,
  ScanFilter.original,
  ScanFilter.gentle,
  ScanFilter.clean,
  ScanFilter.auto,
  ScanFilter.document,
  ScanFilter.lighten,
  ScanFilter.sharpen,
];

const kFilterLabels = <ScanFilter, String>{
  ScanFilter.original: 'أصلي',
  ScanFilter.gentle: 'تحسين خفيف',
  ScanFilter.receipt: 'إيصال',
  ScanFilter.thermal: 'حراري باهت',
  ScanFilter.receiptBw: 'فوتوكوبي',
  ScanFilter.auto: 'ضبط مستويات',
  ScanFilter.adaptive: 'تلقائي · إيصال / حراري / فوتوكوبي',
  ScanFilter.enhance: 'تحسين',
  ScanFilter.magic: 'ألوان',
  ScanFilter.document: 'مستند',
  ScanFilter.bw: 'أ/س',
  ScanFilter.gray: 'رمادي',
  ScanFilter.lighten: 'تفتيح',
  ScanFilter.sharpen: 'حدة',
  ScanFilter.clean: 'تنضيف',
};

/// فلاتر الإيصال: بتعدي على _cleanJob (تقدير لون الورق وقسمة الصورة عليه) قبل أي مصفوفة ألوان.
bool isCleanFilter(ScanFilter f) =>
    f == ScanFilter.receipt ||
    f == ScanFilter.thermal ||
    f == ScanFilter.receiptBw ||
    f == ScanFilter.clean;

/// الحراري الباهت وإيصال الأبيض والأسود بيستخدموا منحنى أقوى عشان الكتابة الخفيفة متختفيش.
bool usesThermalClean(ScanFilter f) => f == ScanFilter.thermal || f == ScanFilter.receiptBw;

/// قوة الحدة الفعلية: فلتر "حدة" بيضمن حد أدنى حتى لو السلايدر على صفر.
double effSharpness(ScanFilter f, double s) => f == ScanFilter.sharpen ? math.max(s, 0.7) : s;

/// شريط الفلاتر (بيتمرر أفقياً) ومشترك بين المحرر وشاشة الإيصالات.
class FilterBar extends StatelessWidget {
  final ScanFilter selected;
  final ValueChanged<ScanFilter>? onChanged;
  final ScanFilter? automaticChoice;
  const FilterBar({super.key, required this.selected, required this.onChanged, this.automaticChoice});

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
                label: Text(f == ScanFilter.adaptive && automaticChoice != null
                    ? 'تلقائي: ${kFilterLabels[automaticChoice]}'
                    : (kFilterLabels[f] ?? f.name)),
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

/// Save only already-observed state. Never await on the capture path.
void _rememberDiagnostic(String key, String value) {
  unawaited(SharedPreferences.getInstance().then((p) async {
    await p.setString(key, value);
  }).catchError((Object e, StackTrace st) {AppLog.e('diagnostic', e, st);}));
}

final _adaptiveCache = <String, ScanFilter>{};
/// Conservative per-image selection on a small preview. No OCR or network.
ScannerMode receiptScannerMode(ScanFilter filter,bool full) =>
    filter == ScanFilter.adaptive ? ScannerMode.base : (full ? ScannerMode.full : ScannerMode.base);

const automaticReceiptFilters = <ScanFilter>{ScanFilter.receipt, ScanFilter.thermal, ScanFilter.receiptBw};
/// One tiny-sample histogram. Select only the three receipt treatments requested.
ScanFilter chooseImageFilter(Uint8List rgba, int w, int h) {
  final hist=List<int>.filled(256,0);
  var n=0,colored=0,dark=0,ink=0;
  final x0=(w*.12).floor(),x1=(w*.88).ceil();
  final y0=(h*.12).floor(),y1=(h*.88).ceil();
  for(var y=y0;y<y1;y++)for(var x=x0;x<x1;x++) {
    final i=(y*w+x)*4;if(i+2>=rgba.length)continue;
    final r=rgba[i],g=rgba[i+1],b=rgba[i+2];
    final lum=(r*54+g*183+b*19)>>8;hist[lum]++;
    if(math.max(r,math.max(g,b))-math.min(r,math.min(g,b))>38)colored++;
    if(lum<120)dark++;if(lum<210)ink++;n++;
  }
  if(n<16)return ScanFilter.receipt;
  final low=_histPct(hist,n,.08),mid=_histPct(hist,n,.50),high=_histPct(hist,n,.92);
  // Warm/shadowed receipts need local paper normalization, not a mild RGB tint.
  if(colored/n>.07 || mid<170 || high<205)return ScanFilter.receipt;
  // Faint ink: use the thermal curve, without the harder photocopy threshold.
  if(high-low<65 || (dark/n<.015 && ink/n>.015))return ScanFilter.thermal;
  // Neutral bright paper with genuinely dark strokes suits photocopy.
  if(mid>218 && dark/n>=.015)return ScanFilter.receiptBw;
  return ScanFilter.receipt;
}

Future<ScanFilter> resolveImageFilter(String path) async {
  final cached = _adaptiveCache[path];
  if (cached != null) return cached;
  final sw = Stopwatch()..start();
  try {
    final bytes = (_hotImgPath == path ? _hotImgBytes : null) ?? await File(path).readAsBytes();
    final sz = await imageSize(bytes);
    final width = math.max(1, (sz.w * math.min(1.0, 160 / math.max(sz.w,sz.h))).round());
    final img = await decodeImage(bytes, maxWidth: width);
    final w = img.width, h = img.height;
    final bd = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    img.dispose();
    final choice = bd == null ? ScanFilter.receipt : chooseImageFilter(_bytesOf(bd),w,h);
    if (_adaptiveCache.length >= 32) _adaptiveCache.remove(_adaptiveCache.keys.first);
    _adaptiveCache[path] = choice;
    AppLog.i('filter-select choice=${choice.name} sample=${w}x$h ${sw.elapsedMilliseconds}ms');
    return choice;
  } catch (e,st) {
    AppLog.e('filter-select',e,st);
    return ScanFilter.receipt;
  }
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
      // حساسية أعلى للكتابة الحرارية الرمادية الخفيفة عند أطراف الإيصال.
      if (src[i] + src[i + 1] + src[i + 2] < 3 * 248) {
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

Future<void> logImageQuality(String stage, Uint8List bytes,
    {ImageQualityProfile? profile}) async {
  try {
    final sz = await imageSize(bytes);
    AppLog.i('quality $kImageQualityRevision $stage ${sz.w}x${sz.h} '
        '${bytes.lengthInBytes}B profile=${profile?.id ?? "standard"}');
  } catch (e, st) {
    AppLog.e('quality.$stage', e, st);
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
    case ScanFilter.adaptive: // Resolved before preview/render; identity is the safe fallback.
    case ScanFilter.original:
    case ScanFilter.receipt: // المعالجة الحقيقية في _cleanJob، والمصفوفة هنا للتباين والسطوع بس
    case ScanFilter.thermal:
    case ScanFilter.clean:
    case ScanFilter.sharpen: // الحدة بتتطبق في _sharpenJob
      w = [
        [1.0, 0.0, 0.0],
        [0.0, 1.0, 0.0],
        [0.0, 0.0, 1.0],
      ];
      t0 = [0.0, 0.0, 0.0];
      break;
    case ScanFilter.gentle:
      w = [[1.08, 0.0, 0.0], [0.0, 1.08, 0.0], [0.0, 0.0, 1.08]];
      t0 = List<double>.filled(3, -7.0);
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
      // Photocopy tone and grayscale are applied once inside _cleanJob.
      w = sat(1.0, 1.0);
      t0 = List<double>.filled(3, 0.0);
      break;
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
  final photocopy = (a['photocopy'] as bool?) ?? false;
  final th = (a['th'] as bool?) ?? false; // Thermal paper: finer background grid and its own smooth curve.
  final plain = (a['plain'] as bool?) ?? false; // تنضيف بس: إزالة ظلال وإضاءة من غير منحنى ألوان
  final bs = math.max(th ? 12 : 16, (math.max(w, h) / (th ? 48 : 40)).round());
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

  // One smooth tone curve after local paper normalization. No stacked
  // thermal + threshold curve, and no discontinuity around pale strokes.
  final wp = th ? 242.0 : (plain ? 255.0 : 238.0);
  final gam = photocopy ? 1.25 : (th ? 1.65 : (plain ? 1.0 : 1.25));
  final black = photocopy ? 45.0 : 0.0;
  final lut = List<int>.generate(256, (i) {
    final t = ((i - black) / (wp - black)).clamp(0.0, 1.0);
    return (255.0 * math.pow(t, gam)).round().clamp(0, 255).toInt();
  });

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
      // حساب القنوات مباشرة بدون إنشاء List أو دالة محلية لكل بكسل.
      final paperR = (bg[0][a0] * (1 - tx) + bg[0][a1] * tx) * (1 - ty) +
          (bg[0][b0] * (1 - tx) + bg[0][b1] * tx) * ty;
      final paperG = (bg[1][a0] * (1 - tx) + bg[1][a1] * tx) * (1 - ty) +
          (bg[1][b0] * (1 - tx) + bg[1][b1] * tx) * ty;
      final paperB = (bg[2][a0] * (1 - tx) + bg[2][a1] * tx) * (1 - ty) +
          (bg[2][b0] * (1 - tx) + bg[2][b1] * tx) * ty;
      var vr = src[i] * 255 / (paperR < 40 ? 40 : paperR);
      var vg = src[i + 1] * 255 / (paperG < 40 ? 40 : paperG);
      var vb = src[i + 2] * 255 / (paperB < 40 ? 40 : paperB);
      if (vr > 255) vr = 255;
      if (vg > 255) vg = 255;
      if (vb > 255) vb = 255;
      int r, g, b;
      if (photocopy) {
        final lum = ((vr * 54 + vg * 183 + vb * 19) / 256).round().clamp(0, 255);
        r = g = b = lut[lum];
      } else {
        r = lut[vr.round()]; g = lut[vg.round()]; b = lut[vb.round()];
        if (gray) {
          final l = (r * 54 + g * 183 + b * 19) >> 8;
          r = g = b = l;
        }
      }
      out[i] = r;
      out[i + 1] = g;
      out[i + 2] = b;
      out[i + 3] = 255;
    }
  }

  // حدة ذكية تحسّن النص وتمنع تشويش الورق الأبيض
  final k = th ? 0.30 : (plain ? 0.15 : 0.35);
  final cp = Uint8List.fromList(out);
  final row = w * 4;
  for (var y = 1; y < h - 1; y++) {
    for (var x = 1; x < w - 1; x++) {
      final i = (y * w + x) * 4;
      if (th && cp[i] > 246 && cp[i + 1] > 246 && cp[i + 2] > 246) continue;
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
Future<ui.Image> cleanUiImage(ui.Image img,
    {bool gray = false, bool thermal = false, bool plain = false, bool photocopy = false}) async {
  final w = img.width, h = img.height;
  final bd = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (bd == null) throw Exception('تعذر قراءة الصورة');
  final rgba = await compute(_cleanJob, <String, dynamic>{
    'src': bd.buffer.asUint8List(bd.offsetInBytes, bd.lengthInBytes),
    'plain': plain,
    'w': w,
    'h': h,
    'gray': gray,
    'th': thermal,
    'photocopy': photocopy,
  });
  final comp = Completer<ui.Image>();
  ui.decodeImageFromPixels(rgba, w, h, ui.PixelFormat.rgba8888, comp.complete);
  return comp.future;
}

Future<Uint8List> applyFilter(Uint8List bytes, ScanFilter f,
    {ImageQualityProfile? profile}) async {
  if (f == ScanFilter.adaptive) {
    try {
    // Byte-based callers do not have a path. Select on a tiny decode first.
    final sz = await imageSize(bytes);
    final width = math.max(1, (sz.w * math.min(1.0, 160 / math.max(sz.w,sz.h))).round());
    final sample = await decodeImage(bytes, maxWidth: width);
    final bd = await sample.toByteData(format: ui.ImageByteFormat.rawRgba);
    final choice = bd == null ? ScanFilter.receipt : chooseImageFilter(_bytesOf(bd),sample.width,sample.height);
    sample.dispose();
    return await applyFilter(bytes, choice, profile: profile);
    } catch (e,st) {
      AppLog.e('filter-select.bytes',e,st);
      return bytes;
    }
  }
  if (f == ScanFilter.original) return bytes;
  try {
    final img = await decodeImage(bytes);
    final w = img.width, h = img.height;
    ui.Image out;
    if (isCleanFilter(f)) {
      final c = await cleanUiImage(img, thermal: usesThermalClean(f),
          plain: f == ScanFilter.clean, photocopy: f == ScanFilter.receiptBw);
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
      quality: await Store.jpegQuality(profile: profile),
      format: CompressFormat.jpeg,
    );
  } catch (e, st) {
    AppLog.e('applyFilter', e, st);
    return bytes; // لو الفلتر فشل (ذاكرة) نكمل بالصورة الأصلية
  }
}

/// فحص جودة الصورة (Isolate). اتعاير على صور باتش حقيقية مع اهتزاز/ضبابية صناعية:
/// - الحدة: لكل مربع فيه كتابة في نص الصورة (70%) بنقيس نسبة طاقة المشتقة التانية للأولى
///   (مش متأثرة بالتباين ولا الإضاءة)، والضبابية بتنزّلها. بناخد ربيع المربعات الأحدّ.
/// - الاهتزاز في اتجاه واحد: طاقة الحواف الأفقية مقابل الرأسية بتختل جامد.
/// - اللمعة: بقعة محروقة (≥250) جوه ورقة مش محروقة كلها.
Map<String, dynamic> _qualityJob(Map<String, dynamic> a) {
  final px = a['px'] as Uint8List;
  final w = a['w'] as int, h = a['h'] as int;
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
  final x0 = (w * 0.15).floor(), y0 = (h * 0.15).floor();
  final x1 = (w * 0.85).floor(), y1 = (h * 0.85).floor();
  const tile = 48;
  final ratios = <double>[];
  var ex = 0.0, ey = 0.0;
  for (var ty = y0; ty + tile <= y1; ty += tile) {
    for (var tx = x0; tx + tile <= x1; tx += tile) {
      var s = 0.0, s2 = 0.0;
      for (var y = ty; y < ty + tile; y++) {
        for (var x = tx; x < tx + tile; x++) {
          final v = lum[y * w + x];
          s += v;
          s2 += v * v;
        }
      }
      const n = tile * tile;
      final sd = math.sqrt(math.max(0.0, s2 / n - (s / n) * (s / n)));
      if (sd < 14) continue; // مربع فاضي (ورق أبيض أو خلفية سادة)
      var dx2 = 0.0, dy2 = 0.0, dxx2 = 0.0, dyy2 = 0.0;
      var ndx = 0, ndy = 0, ndxx = 0, ndyy = 0;
      for (var y = ty; y < ty + tile; y++) {
        final r = y * w;
        for (var x = tx; x < tx + tile; x++) {
          final c = lum[r + x];
          if (x + 1 < tx + tile) { final d = lum[r + x + 1] - c; dx2 += d * d; ndx++; }
          if (y + 1 < ty + tile) { final d = lum[r + w + x] - c; dy2 += d * d; ndy++; }
          if (x > tx && x + 1 < tx + tile) {
            final d = 2 * c - lum[r + x - 1] - lum[r + x + 1]; dxx2 += d * d; ndxx++;
          }
          if (y > ty && y + 1 < ty + tile) {
            final d = 2 * c - lum[r - w + x] - lum[r + w + x]; dyy2 += d * d; ndyy++;
          }
        }
      }
      final mdx = dx2 / ndx, mdy = dy2 / ndy;
      ex += mdx;
      ey += mdy;
      final rx = (dxx2 / ndxx) / math.max(1e-6, mdx);
      final ry = (dyy2 / ndyy) / math.max(1e-6, mdy);
      ratios.add(math.min(rx, ry));
    }
  }
  double? sharp;
  double? aniso;
  if (ratios.length >= 4) {
    ratios.sort();
    sharp = ratios[(ratios.length * 0.75).floor()];
    aniso = math.min(ex, ey) / math.max(1e-6, math.max(ex, ey));
  }
  // اللمعة: نسبة البكسلات المحروقة في نص الصورة، بشرط إن الورقة نفسها مش بيضا محروقة كلها
  final rh = List<int>.filled(256, 0);
  var rn = 0, sat = 0;
  for (var y = y0; y < y1; y++) {
    for (var x = x0; x < x1; x++) {
      final v = lum[y * w + x].toInt();
      rh[v]++;
      rn++;
      if (v >= 250) sat++;
    }
  }
  var p75 = 255;
  acc = 0;
  for (var t = 0; t < 256; t++) {
    acc += rh[t];
    if (acc >= rn * 0.75) {
      p75 = t;
      break;
    }
  }
  final satFrac = rn == 0 ? 0.0 : sat / rn;
  return <String, dynamic>{
    'p90': p90,
    'sharp': sharp,
    'aniso': aniso,
    'tiles': ratios.length,
    'sat': satFrac,
    'p75': p75,
  };
}

/// قرار التحذير من نتيجة الفحص (منفصل عشان يتجرّب لوحده).
String? qualityVerdict(Map<String, dynamic> r) {
  final p90 = r['p90'] as int;
  final sharp = (r['sharp'] as num?)?.toDouble();
  final aniso = (r['aniso'] as num?)?.toDouble();
  final sat = (r['sat'] as num).toDouble();
  final p75 = r['p75'] as int;
  if (p90 < 130) return 'الإضاءة ضعيفة، صوّر في مكان أنور';
  if (sharp != null && sharp < 0.42) {
    return 'الصورة مش حادة (مهزوزة أو الفوكس مش مظبوط). ثبّت إيدك واضغط على الورقة للفوكس وصوّر تاني';
  }
  if (aniso != null && aniso < 0.26) {
    return 'الصورة مهزوزة (الإيد اتحركت وقت التصوير). ثبّت الموبايل وصوّر تاني';
  }
  if (sat >= 0.01 && sat < 0.6 && p75 < 240) {
    return 'في لمعة على الورقة ممكن تمسح أرقام. ميّل الموبايل شوية أو اطفي الكشاف وصوّر تاني';
  }
  return null;
}

/// فحص سريع بعد التصوير داخل Isolate (بدون تجميد الواجهة): بيرجّع رسالة تحذير أو null لو الصورة تمام.
/// بيتعمل على نسخة لحد 1200 بكسل (مش 400) عشان الكلام الصغير في الإيصال يبان لو مهزوز.
Future<String?> qualityWarning(String path) async {
  try {
    final raw = await File(path).readAsBytes();
    final sz = await imageSize(raw);
    final img = await decodeImage(raw, maxWidth: sz.w > 1200 ? 1200 : null);
    final w = img.width, h = img.height;
    final bd = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    img.dispose();
    if (bd == null || w < 16 || h < 16) return null;
    final r = await compute(_qualityJob, <String, dynamic>{
      'px': _bytesOf(bd),
      'w': w,
      'h': h,
    });
    AppLog.i('quality ${w}x$h p90=${r['p90']} sharp=${(r['sharp'] as num?)?.toStringAsFixed(2)} '
        'aniso=${(r['aniso'] as num?)?.toStringAsFixed(2)} tiles=${r['tiles']} '
        'sat=${((r['sat'] as num) * 100).toStringAsFixed(1)}% p75=${r['p75']}');
    return qualityVerdict(r);
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

/// كاش مؤقت في الرام لآخر صورة اتصوّرت عشان شاشة التعديل تعرضها فوراً بدون إعادة قراءة من الذاكرة.
String? _hotImgPath;
Uint8List? _hotImgBytes;

Uint8List? _takeHotBytes(String path) {
  if (_hotImgPath == path && _hotImgBytes != null) {
    final b = _hotImgBytes;
    _hotImgPath = null;
    _hotImgBytes = null;
    return b;
  }
  return null;
}

/// بينسخ المصدر لمجلد التطبيق الدائم ويضيفه للمحفوظات (مسح يدوي بس) لما التحويل يفشل.
Future<void> _retainFailedCapture(String src) async {
  try {
    final dir = (await Store.dir()).path;
    var keep = src;
    if (!src.startsWith(dir)) {
      final dot = src.lastIndexOf('.');
      final ext = dot > src.lastIndexOf('/') ? src.substring(dot) : '.jpg';
      keep = '$dir/capture_${DateTime.now().microsecondsSinceEpoch}$ext';
      await File(src).copy(keep);
    }
    final p = await SharedPreferences.getInstance();
    final a = p.getStringList('archive') ?? [];
    if (!a.contains(keep)) a.add(keep);
    await p.setStringList('archive', a);
  } catch (e, st) {
    AppLog.e('retainFailedCapture', e, st);
  }
}

bool _isJpegHeader(Uint8List b) => b.length > 100 && b[0] == 0xFF && b[1] == 0xD8;

/// نسخ الصورة من مكان الماسح المؤقت لمكان ثابت كـ JPEG واحد مضغوط (مرة واحدة بس).
/// وبعدها بيتطبق الفلتر لو الموظف اختاره.
Future<String> persistImage(String src, String name,
    {ScanFilter filter = ScanFilter.original,
    bool applyNow = true,
    bool keepOriginal = false,
    ImageQualityProfile? profile}) async {
  final automaticFilter = filter == ScanFilter.adaptive;
  if (automaticFilter) filter = await resolveImageFilter(src);
  final swPersist = Stopwatch()..start();
  final capturedProfile = _captureProfiles.remove(src);
  profile ??= capturedProfile;
  final mode = await Store.perfMode();
  final maxSide = getMaxSide(mode, profile: profile);
  Uint8List? bytes;
  // Receipt input keeps its real source JPEG. Filtering/cropping encodes once later.
  if (keepOriginal || profile != null) {
    // صور ماسح جوجل بتيجي مقصوصة ومعدولة جاهزة: نحفظها بأصلها بدون إعادة ضغط أو تصغير عشان متقلش جودتها
    try {
      final raw = await File(src).readAsBytes();
      if (_isJpegHeader(raw)) {
        final sz = await imageSize(raw);
        if (sz.w > 0 && sz.h > 0 && (profile != null || math.max(sz.w, sz.h) <= 4096)) {
          bytes = raw;
          await logImageQuality('source-preserved', raw, profile: profile);
        }
      }
    } catch (e, st) {
      AppLog.e('persistImage.orig', e, st);
    }
  }
  if (bytes == null) {
    try {
      bytes = await FlutterImageCompress.compressWithFile(
        src,
        minWidth: maxSide,
        minHeight: maxSide,
        quality: await Store.jpegQuality(profile: profile),
        format: CompressFormat.jpeg,
        keepExif: false,
      );
    } catch (e, st) {
      AppLog.e('persistImage', e, st);
    }
  }
  AppLog.i('t persist.compress ${swPersist.elapsedMilliseconds}ms');
  if (bytes != null && !_isJpegHeader(bytes)) bytes = null;
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
        quality: await Store.jpegQuality(profile: profile),
        format: CompressFormat.jpeg,
      );
    } catch (e, st) {
      AppLog.e('persistImage', e, st);
    }
  }
  if (bytes == null || !_isJpegHeader(bytes)) {
    // اللقطة متضيعش: بنحفظ المصدر في مجلد التطبيق (ويظهر تحت «ملفاتي») قبل ما نبلّغ بالفشل
    await _retainFailedCapture(src);
    throw Exception('الصورة دي ماتحوّلتش لـ JPEG، الأصل اتحفظ تحت «ملفاتي». جرّب تاني أو افتحه من هناك');
  }
  await logImageQuality('ingest', bytes, profile: profile);
  final f = File('${(await Store.dir()).path}/$name');
  if (profile != null) await Store.setQualityProfile(f.path, profile);
  if (filter != ScanFilter.original) {
    // نسخة من غير فلتر عشان التعديل بعد كده يبقى ممكن يرجّع الأصلي (بدون flush لعدم تعطيل الواجهة)
    // Receipt ingest keeps one source file until the first final render.
    // Standard/legacy images retain their existing base-file behavior.
    if (profile == null) await File(Store.baseOf(f.path)).writeAsBytes(bytes);
    await Store.setEdit(f.path, EditParams(filter: automaticFilter ? ScanFilter.adaptive : filter));
    if (profile != null && !applyNow) await Store.setEditPending(f.path, true);
  }
  final tFilter = swPersist.elapsedMilliseconds;
  // applyNow=false: بنحفظ الصورة من غير فلتر (شاشة التعديل بتطبّقه على المعاينة) عشان الانتقال يبقى فوري
  if (applyNow) {
    // Receipt sources remain untouched until the final crop/filter render.
    if (profile != null && filter != ScanFilter.original) {
      await f.writeAsBytes(bytes);
      final rendered = await renderEditedPage(f.path, 'ingest_', EditParams(filter: filter));
      final renderedBase = File(Store.baseOf(rendered));
      if (await renderedBase.exists()) await renderedBase.rename(Store.baseOf(f.path));
      await File(rendered).rename(f.path);
      await Store.del(rendered);
    } else {
      bytes = await applyFilter(bytes, filter, profile: profile);
      await f.writeAsBytes(bytes);
    }
  } else {
    _hotImgPath = f.path;
    _hotImgBytes = bytes;
    await f.writeAsBytes(bytes);
  }
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
        c.clamp(kTagMinScale, 1.0).toDouble());
  }
}

/// بتتأكد إن الورقة كلها جوه الصورة، حتى لو مكانها المحفوظ كان لصورة بأبعاد تانية.
TagPos fitTagPos(TagPos p, Tag t, double aspect) {
  final th = p.s * t.h / t.w; // ارتفاع الورقة كنسبة من عرض الصورة
  final cx = p.cx.clamp(p.s / 2, 1 - p.s / 2).toDouble();
  final cy = th >= aspect ? aspect / 2 : p.cy.clamp(th / 2, aspect - th / 2).toDouble();
  return p.copyWith(cx: cx, cy: cy);
}

/// ورقة الباتش: في أسفل الصورة خالص وبعرض الصورة كلها، وبتتكيف تلقائياً مع أي حجم أو أبعاد للصورة.
/// [aspect] = ارتفاع الصورة ÷ عرضها.
TagPos bottomTagPos(Tag t, double aspect) {
  final th = t.h / t.w; // ارتفاع الورقة كنسبة من عرضها
  final sc = th >= aspect ? aspect / th : 1.0; // لو الصورة قصيرة جداً بنصغّر الورقة عشان تفضل جوه الصورة
  return TagPos(0.5, aspect - sc * th / 2, sc);
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
Future<Tag> receiptTag(double w, Session s, {bool batch = false, String? pageLabel}) async {
  late Tag t;
  for (var i = 0; i < 3; i++) {
    t = await _renderTag(w, s, batch: batch, pageLabel: pageLabel);
    if (await _tagLooksOk(t.png)) return t;
    AppLog.i('tag garbled, retry ${i + 1}');
  }
  return t;
}

Future<Tag> _renderTag(double w, Session s, {bool batch = false, String? pageLabel}) async {
  final fs = w * kTagFont * (batch ? 1.0 : kReceiptTagScale);
  final unitLine = s.building == null ? s.unit.name : '${s.unit.name} - ${s.building}';
  final l1 = _tp('${s.name}  |  $unitLine', fs, TextDirection.rtl);
  final baseL2 = batch ? _isoLtr(s.date) : '${_isoLtr('TID: ${s.unit.tid}')}  |  ${_isoLtr(s.date)}';
  final l2 = _tp(baseL2, fs, TextDirection.rtl);
  // رقم الصفحة بترتيبها: سطر لوحده بخط متوسط (أكبر من سطور البيانات) جوه ورقة البيانات
  final l3 = pageLabel == null ? null : _tp(_isoLtr(pageLabel), fs * 1.5, TextDirection.ltr);
  final pad = fs * (batch ? 0.6 : 0.3);
  final gap = fs * (batch ? 0.25 : 0.12);
  final textW = math.max(l1.width, l2.width);
  // رقم الصفحة في جنب الورقة (شمال) بدل سطر زيادة، فارتفاع الورقة زي ما هو
  final numW = l3 == null ? 0.0 : l3.width + pad * 2;
  final cw = batch ? (textW + pad * 2 + numW).clamp(0.0, w * 0.96).toDouble() : w * 0.96;
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
  final tx0 = numW; // البيانات في باقي العرض
  l1.paint(c, Offset(tx0 + (cw - tx0 - l1.width) / 2, pad));
  l2.paint(c, Offset(tx0 + (cw - tx0 - l2.width) / 2, pad + l1.height + gap));
  if (l3 != null) {
    l3.paint(c, Offset((numW - l3.width) / 2, (ch - l3.height) / 2));
    c.drawLine(Offset(numW, ch * 0.18), Offset(numW, ch * 0.82),
        Paint()..color = Colors.black..strokeWidth = math.max(1.0, sw * 0.6));
  }
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

/// تركيب مباشر بصيغة BMP 24 بت (من غير نسخة RGBA كاملة تانية ولا ضغط PNG): الصورة + الورقة، صف صف.
/// بيرجّع BMP جاهز للضغط JPEG ومتوسط السطوع بنفس عينات _meanLum.
Map<String, dynamic> _composeBmpJob(Map<String, dynamic> a) {
  final img = a['img'] as Uint8List;
  final iw = a['iw'] as int, ih = a['ih'] as int;
  final tag = a['tag'] as Uint8List;
  final tw = a['tw'] as int, th = a['th'] as int;
  final ow = a['ow'] as int, oh = a['oh'] as int;
  final ix = a['ix'] as int, iy = a['iy'] as int;
  final tx = a['tx'] as int, ty = a['ty'] as int;
  final rowBytes = ((ow * 3 + 3) ~/ 4) * 4;
  final dataSize = rowBytes * oh;
  final bmp = Uint8List(54 + dataSize);
  final hd = ByteData.view(bmp.buffer);
  bmp[0] = 0x42;
  bmp[1] = 0x4D;
  hd.setUint32(2, 54 + dataSize, Endian.little);
  hd.setUint32(10, 54, Endian.little);
  hd.setUint32(14, 40, Endian.little);
  hd.setInt32(18, ow, Endian.little);
  hd.setInt32(22, oh, Endian.little); // موجب = الصفوف من تحت لفوق
  hd.setUint16(26, 1, Endian.little);
  hd.setUint16(28, 24, Endian.little);
  hd.setUint32(34, dataSize, Endian.little);
  final row = Uint8List(ow * 4);
  final sx0 = math.max(0, -ix), sx1 = math.min(iw, ow - ix);
  final n = ow * oh;
  final step = math.max(1, n ~/ 20000) | 1;
  var lumSum = 0.0, lumCnt = 0;
  for (var y = 0; y < oh; y++) {
    row.fillRange(0, row.length, 255);
    final sy = y - iy;
    if (sy >= 0 && sy < ih && sx1 > sx0) {
      row.setRange((ix + sx0) * 4, (ix + sx1) * 4, img, (sy * iw + sx0) * 4);
    }
    final ty0 = y - ty;
    if (ty0 >= 0 && ty0 < th) {
      for (var x = 0; x < tw; x++) {
        final dx = x + tx;
        if (dx < 0 || dx >= ow) continue;
        final si = (ty0 * tw + x) * 4, di = dx * 4;
        final al = tag[si + 3];
        if (al == 0) continue;
        if (al == 255) {
          row[di] = tag[si];
          row[di + 1] = tag[si + 1];
          row[di + 2] = tag[si + 2];
        } else {
          final k = 1 - al / 255;
          for (var c = 0; c < 3; c++) {
            final v = tag[si + c] + row[di + c] * k;
            row[di + c] = v > 255 ? 255 : v.round();
          }
        }
      }
    }
    var o = 54 + (oh - 1 - y) * rowBytes;
    for (var x = 0, j = 0; x < ow; x++, j += 4) {
      bmp[o++] = row[j + 2];
      bmp[o++] = row[j + 1];
      bmp[o++] = row[j];
    }
    // عينات السطوع: نفس الفهارس i = y*ow + x اللي بتقبل القسمة على step
    final base = y * ow;
    var x0 = (step - base % step) % step;
    for (var x = x0; x < ow; x += step) {
      final j = x * 4;
      lumSum += (row[j] * 54 + row[j + 1] * 183 + row[j + 2] * 19) >> 8;
      lumCnt++;
    }
  }
  return {'bmp': bmp, 'lum': lumCnt == 0 ? 0.0 : lumSum / lumCnt};
}

/// بيركّب الصورة والورقة ويطلّع JPEG بنفس الأبعاد من غير أي تصغير. المسار الأساسي BMP (أقل ذاكرة)،
/// ولو فشل ضغطه بيرجع للمسار القديم (PNG) بنفس الأبعاد. لو الناتج مشوّه بنفشل بدل ما نصغّر أو نبعت صورة بايظة.
Future<Uint8List> _composeEncode(ui.Image img, Tag tag,
    {required int ow, required int oh, required int ix, required int iy, required int tx, required int ty,
    required int q, required String label}) async {
  final iw = img.width, ih = img.height;
  final tImg = await decodeImage(tag.png);
  final tw = tImg.width, th = tImg.height;
  final imgBd = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
  final tagBd = await tImg.toByteData(format: ui.ImageByteFormat.rawRgba);
  img.dispose();
  tImg.dispose();
  if (imgBd == null || tagBd == null) throw Exception('تعذر قراءة الصورة');
  final args = <String, dynamic>{
    'img': imgBd.buffer.asUint8List(imgBd.offsetInBytes, imgBd.lengthInBytes),
    'iw': iw,
    'ih': ih,
    'tag': tagBd.buffer.asUint8List(tagBd.offsetInBytes, tagBd.lengthInBytes),
    'tw': tw,
    'th': th,
    'ow': ow,
    'oh': oh,
    'ix': ix,
    'iy': iy,
    'tx': tx,
    'ty': ty,
  };
  try {
    final r = await compute(_composeBmpJob, args);
    final jpg = await FlutterImageCompress.compressWithList(
      r['bmp'] as Uint8List,
      minWidth: ow,
      minHeight: oh,
      quality: q,
      format: CompressFormat.jpeg,
    );
    final got = await _jpegMeanLum(jpg);
    final want = r['lum'] as double;
    AppLog.i('$label bmp ${ow}x$oh ${jpg.length ~/ 1024}KB lum want=${want.toStringAsFixed(0)} got=${got?.toStringAsFixed(0)}');
    if (_isJpegHeader(jpg) && got != null && (got - want).abs() < 25) return jpg;
  } catch (e, st) {
    AppLog.e('$label.bmp', e, st);
  }
  // المسار القديم (PNG) بنفس الأبعاد الكاملة، من غير تصغير
  final rgba = await compute(_composeJob, args);
  final comp = Completer<ui.Image>();
  ui.decodeImageFromPixels(rgba, ow, oh, ui.PixelFormat.rgba8888, comp.complete);
  final outImg = await comp.future;
  final pngBd = await outImg.toByteData(format: ui.ImageByteFormat.png);
  outImg.dispose();
  if (pngBd == null) throw Exception('تعذر حفظ الصورة');
  final want = _meanLum(rgba, ow, oh);
  final jpg = await FlutterImageCompress.compressWithList(
    pngBd.buffer.asUint8List(pngBd.offsetInBytes, pngBd.lengthInBytes),
    minWidth: ow,
    minHeight: oh,
    quality: q,
    format: CompressFormat.jpeg,
  );
  final got = await _jpegMeanLum(jpg);
  if (_isJpegHeader(jpg) && got != null && (got - want).abs() < 25) return jpg;
  throw Exception('الصورة النهائية طلعت مشوّهة، الأصل محفوظ. جرّب تاني أو وضع الأداء Lite');
}


/// صورة الباتش + الورقة. layout 1: شريط أبيض تحت الصورة (الصورة كاملة من غير تغطية)،
/// layout 2: الورقة فوق الصورة في المكان اللي الموظف اختاره.
Future<Uint8List> composeBatch(String path, Session s) async {
  final src = await File(path).readAsBytes();
  if (await Store.noTag(path)) return src; // من غير ورقة
  final layout = await Store.batchLayout();
  final sz = await imageSize(src);
  final profile = await Store.qualityProfile(path);
  final maxSide = getMaxSide(await Store.perfMode(), profile: profile);
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
    final pos = fitTagPos(await Store.pos(path) ?? bottomTagPos(ref, h / w), ref, h / w);
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
  final q = await Store.jpegQuality(profile: profile);
  return _composeEncode(img, tag,
      ow: ow, oh: oh, ix: imgX, iy: imgY, tx: tagAt.dx.round(), ty: tagAt.dy.round(), q: q, label: 'batchImg');
}

/// صورة الإيصال النهائية للمشاركة: نفس صفحة الـ PDF (شريط أبيض فيه الورقة فوق الإيصال).
/// من غير ورقة (إخفاء الورقة) بترجع الصورة زي ما هي.
/// تركيب وش وضهر البطاقة على ورقة واحدة بيضا (فوق بعض بالطول، بنفس العرض).
Future<Uint8List> composeIdCard(String frontPath, String backPath) async {
  final f = await decodeImage(await File(frontPath).readAsBytes());
  final b = await decodeImage(await File(backPath).readAsBytes());
  try {
    // بدقة الأصل من غير تصغير: العرض = أعرض وش + هوامش، والطول = الاتنين + فاصل صغير
    final inner = math.max(f.width, b.width).toDouble();
    final m = (inner * 0.03).roundToDouble(), gap = (inner * 0.03).roundToDouble();
    final w = inner + 2 * m;
    final h = m + f.height + gap + b.height + m;
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    c.drawRect(Rect.fromLTWH(0, 0, w, h), Paint()..color = const Color(0xFFFFFFFF));
    c.drawImage(f, Offset((w - f.width) / 2, m), Paint());
    c.drawImage(b, Offset((w - b.width) / 2, m + f.height + gap), Paint());
    // خط فاصل خفيف بين الوش والضهر
    final ly = m + f.height + gap / 2;
    c.drawLine(Offset(m, ly), Offset(w - m, ly), Paint()
      ..color = const Color(0xFFE0E0E0)
      ..strokeWidth = math.max(2.0, inner / 600));
    final img = await rec.endRecording().toImage(w.round(), h.round());
    final bd = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    if (bd == null) throw Exception('تعذر تركيب صورة البطاقة');
    return _bytesOf(bd);
  } finally {
    f.dispose();
    b.dispose();
  }
}

/// أقصى ضلع لنسخة الواتساب: 1600 (مقاس واتساب العادي) — التطبيق يصغّر بمرشح جيد ويطبّق
/// المستويات والحدة على النسخة، فتوصل واضحة حتى من غير ما الموظف يختار HD.
const kWaMaxSide = 1600;

/// نسخة إرسال واتساب في Isolate: تصغير بمتوسط المساحة (لو أكبر من kWaMaxSide بس) + اختياريًا
/// مستويات تلقائية (سحق الحبر وقص الورق)، والحدة بس لو حصل تصغير. الأصل لا يُمس.
Map<String, dynamic> _waCopyJob(Map<String, dynamic> a) {
  final src = a['src'] as Uint8List;
  final sw = a['sw'] as int, sh = a['sh'] as int;
  final enhance = a['enhance'] as bool;
  final cap = (a['max'] as int?) ?? kWaMaxSide;
  final k = math.min(1.0, cap / math.max(sw, sh));
  final ow = math.max(8, (sw * k).round()), oh = math.max(8, (sh * k).round());
  final out = Uint8List(ow * oh * 4);
  for (var y = 0; y < oh; y++) {
    final sy0 = y / k, sy1 = (y + 1) / k;
    final iy0 = sy0.floor(), iy1 = math.min(sh, sy1.ceil());
    for (var x = 0; x < ow; x++) {
      final sx0 = x / k, sx1 = (x + 1) / k;
      final ix0 = sx0.floor(), ix1 = math.min(sw, sx1.ceil());
      double r = 0, g = 0, b = 0, al = 0, acc = 0;
      for (var yy = iy0; yy < iy1; yy++) {
        final wy = math.min(sy1, yy + 1.0) - math.max(sy0, yy.toDouble());
        if (wy <= 0) continue;
        for (var xx = ix0; xx < ix1; xx++) {
          final wx = math.min(sx1, xx + 1.0) - math.max(sx0, xx.toDouble());
          if (wx <= 0) continue;
          final wgt = wx * wy;
          final si = (yy * sw + xx) * 4;
          r += src[si] * wgt;
          g += src[si + 1] * wgt;
          b += src[si + 2] * wgt;
          al += src[si + 3] * wgt;
          acc += wgt;
        }
      }
      final di = (y * ow + x) * 4;
      out[di] = (r / acc).round();
      out[di + 1] = (g / acc).round();
      out[di + 2] = (b / acc).round();
      out[di + 3] = (al / acc).round();
    }
  }
  if (!enhance) return {'rgba': out, 'w': ow, 'h': oh};
  // مستويات تلقائية من هيستوجرام اللمعان: سحق الحبر وقص الورق
  final hist = List<int>.filled(256, 0);
  for (var i = 0; i < ow * oh; i++) {
    final p = i * 4;
    hist[(out[p] * 77 + out[p + 1] * 150 + out[p + 2] * 29) >> 8]++;
  }
  int pctl(double q) {
    var acc = 0;
    final t = (ow * oh * q).round();
    for (var i = 0; i < 256; i++) {
      acc += hist[i];
      if (acc >= t) return i;
    }
    return 255;
  }

  final lo = math.max(0, pctl(0.02) - 30);
  final hi = math.min(255, math.max(lo + 30, pctl(0.90) + 25));
  final scale = 255.0 / (hi - lo);
  for (var i = 0; i < ow * oh; i++) {
    final p = i * 4;
    for (var c = 0; c < 3; c++) {
      final v = (out[p + c] - lo) * scale;
      out[p + c] = v < 0 ? 0 : (v > 255 ? 255 : v.round());
    }
  }
  // حدة معتدلة بس لو الصورة اتصغرت (تعويض التصغير). من غير تصغير الحدة التانية بتعمل هالات حوالين الأرقام
  // فوق فلتر التعديل اللي اتطبق قبل كده.
  if (k >= 1.0) return {'rgba': out, 'w': ow, 'h': oh};
  final blur = Uint8List(ow * oh * 3);
  for (var y = 0; y < oh; y++) {
    for (var x = 0; x < ow; x++) {
      var r = 0, g = 0, b = 0, n = 0;
      for (var dy = -1; dy <= 1; dy++) {
        final yy = y + dy;
        if (yy < 0 || yy >= oh) continue;
        for (var dx = -1; dx <= 1; dx++) {
          final xx = x + dx;
          if (xx < 0 || xx >= ow) continue;
          final si = (yy * ow + xx) * 4;
          r += out[si];
          g += out[si + 1];
          b += out[si + 2];
          n++;
        }
      }
      final di = (y * ow + x) * 3;
      blur[di] = r ~/ n;
      blur[di + 1] = g ~/ n;
      blur[di + 2] = b ~/ n;
    }
  }
  const amt = 0.9, thr = 2;
  for (var i = 0; i < ow * oh; i++) {
    final p = i * 4, q = i * 3;
    for (var c = 0; c < 3; c++) {
      final diff = out[p + c] - blur[q + c];
      if (diff.abs() > thr) {
        final v = out[p + c] + (amt * diff).round();
        out[p + c] = v < 0 ? 0 : (v > 255 ? 255 : v);
      }
    }
  }
  return {'rgba': out, 'w': ow, 'h': oh};
}

int _waSeq = 0;

/// نسخة الإرسال للواتساب: نفس الصورة بمقاس واتساب وجودة جيدة، ولو enhance بتحسين مستند.
/// عند أي فشل نرجع مسار الأصل كما هو (الإرسال لا يتعطل أبدًا بسبب النسخة).
/// fullRes: من غير تصغير وجودة 100، وأي فشل بيرمي استثناء (مبنرجعش ملف تاني بدل المطلوب).
Future<String> waShareCopy(String path, {required bool enhance, bool fullRes = false}) async {
  try {
    final dir = (await Store.dir()).path;
    // Keep every prepared attachment alive until the share operation has
    // consumed the entire group. Preparing the system photo must not delete
    // the batch copy created by the preceding call.
    final raw = await File(path).readAsBytes();
    final sz = await imageSize(raw);
    // من غير تحسين ومن غير تصغير: نبعت الأصل زي ما هو (مفيش أي إعادة ضغط تقلل الجودة)
    if (!enhance && (fullRes || math.max(sz.w, sz.h) <= kWaMaxSide)) return path;
    final img = await decodeImage(raw);
    final w = img.width, h = img.height;
    final bd = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    img.dispose();
    if (bd == null) {
      if (fullRes) throw Exception('تعذر قراءة الصورة');
      return path;
    }
    final res = await compute(_waCopyJob, <String, dynamic>{
      'src': _bytesOf(bd),
      'sw': w,
      'sh': h,
      'enhance': enhance,
      'max': fullRes ? kNoResizeSide : kWaMaxSide,
    });
    final rgba = res['rgba'] as Uint8List;
    final ow = res['w'] as int, oh = res['h'] as int;
    // الضاغط محتاج صورة مشفّرة (PNG)، مش بكسلات خام: قبل كده كان بيفشل وبيرجع الأصل من غير التحسين
    final comp = Completer<ui.Image>();
    ui.decodeImageFromPixels(rgba, ow, oh, ui.PixelFormat.rgba8888, comp.complete);
    final outImg = await comp.future;
    final pngBd = await outImg.toByteData(format: ui.ImageByteFormat.png);
    outImg.dispose();
    if (pngBd == null) {
      if (fullRes) throw Exception('تعذر تجهيز نسخة الإرسال');
      return path;
    }
    final jpg = await FlutterImageCompress.compressWithList(
      pngBd.buffer.asUint8List(pngBd.offsetInBytes, pngBd.lengthInBytes),
      minWidth: ow,
      minHeight: oh,
      quality: fullRes ? 100 : 95,
      format: CompressFormat.jpeg,
    );
    if (!_isJpegHeader(jpg)) {
      if (fullRes) throw Exception('نسخة الإرسال طلعت غير سليمة');
      return path;
    }
    final f = File('${dir}/wa_${DateTime.now().microsecondsSinceEpoch}_${_waSeq++}.jpg');
    await f.writeAsBytes(jpg, flush: true);
    AppLog.i('waCopy ${w}x$h -> ${ow}x$oh ${jpg.length ~/ 1024}KB enhance=$enhance');
    return f.path;
  } catch (e, st) {
    AppLog.e('waCopy', e, st);
    if (fullRes) rethrow;
    return path;
  }
}

// ───── شريط صورة السيستم (A2R SYS) ─────
// كود الوحدة بالإنجليزي بالترمنل (نفس جدول الكونسول v96 و POS2). بيتكتب في شريط أبيض تحت صورة السيستم
// علشان POS2 يعرف الماكينة من غير ما يعتمد على قراءة رقم الترمنل من صورة الشاشة (رقم واحد غلط = ماكينة تانية).
const Map<String, String> kUnitCodeByTid = {
  '50335710': 'ABIS-1',
  '50335993': 'ABIS-2',
  '50335987': 'ABIS-3',
  '50325716': 'BORG-1',
  '50335998': 'BORG-2',
  '50335994': 'BORG-3',
  '50335711': 'BORG-4',
  '50382298': 'MONTAZA-1',
  '50382315': 'MONTAZA-2',
  '50383712': 'MONTAZA-3',
  '50382306': 'MOHARRAM-1',
  '50382316': 'MOHARRAM-2',
  '50382308': 'AGAMY-1',
  '50383706': 'AGAMY-2',
  '50382300': 'QABBARY',
  '50383702': 'MKAMEL',
  '50382312': 'AMN',
  '50383699': 'PORT',
  '50383700': 'KHADAMAT',
  '50325765': 'ABIS-S',
  '50322364': 'BORG-S1',
  '50322361': 'BORG-S2',
  '50382150': 'MONTAZA-S',
  '50381092': 'MOHARRAM-S',
  '50381077': 'AGAMY-S',
};

// احتياطي لو الترمنل اتغير في data.xlsx: بالاسم بعد التوحيد (أ/ا، ة/ه، ى/ي، المسافات والأقواس)
const Map<String, String> _kUnitCodeByName = {
  'ابيس1': 'ABIS-1',
  'ابيس2': 'ABIS-2',
  'ابيس3': 'ABIS-3',
  'برجالعرب1': 'BORG-1',
  'برجالعرب2': 'BORG-2',
  'برجالعرب3': 'BORG-3',
  'برجالعرب4': 'BORG-4',
  'المنتزه1': 'MONTAZA-1',
  'المنتزه2': 'MONTAZA-2',
  'المنتزه3': 'MONTAZA-3',
  'محرمبك1': 'MOHARRAM-1',
  'محرمبك2': 'MOHARRAM-2',
  'العجمي1': 'AGAMY-1',
  'العجمي2': 'AGAMY-2',
  'القباري': 'QABBARY',
  'مصطفيكامل': 'MKAMEL',
  'مديريهالامن': 'AMN',
  'ميناءالاسكندريه': 'PORT',
  'خدماتمصر': 'KHADAMAT',
  'مجمعخدماتمصر': 'KHADAMAT',
  'ابيساحتياطي': 'ABIS-S',
  'برجالعرباحتياطي1': 'BORG-S1',
  'برجالعرباحتياطي2': 'BORG-S2',
  'المنتزهاحتياطي': 'MONTAZA-S',
  'محرمبكاحتياطي': 'MOHARRAM-S',
  'العجمياحتياطي': 'AGAMY-S',
};

String _unitNameKey(String n) => n
    .replaceAll(RegExp('[أإآ]'), 'ا')
    .replaceAll('ة', 'ه')
    .replaceAll('ى', 'ي')
    .replaceAll(RegExp(r'[\s()\-_.]+'), '');

String unitLatinCode(Unit u) => kUnitCodeByTid[u.tid] ?? _kUnitCodeByName[_unitNameKey(u.name)] ?? '';

/// نص الشريط: A2R SYS 50383702 MKAMEL 23.11.2026
String sysStripText(Unit u, DateTime d) {
  final code = unitLatinCode(u);
  final dt = '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';
  return ['A2R', 'SYS', u.tid, if (code.isNotEmpty) code, dt].join(' ');
}

int _tidDigitDiff(String a, String b) {
  if (a.length != b.length) return 99;
  var d = 0;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) d++;
  }
  return d;
}

/// أرقام الترمنل (50xxxxxx) في نص صورة السيستم، متساهل مع غلطات الـ OCR (O/0 ، I/l/1 ، S/5).
List<String> sysPhotoTids(String text) {
  final out = <String>[];
  final re = RegExp(r'(?<![0-9A-Za-z])([5S][0Oo][0-9OoIlS|]{6})(?![0-9A-Za-z])');
  for (final m in re.allMatches(text)) {
    final t = m
        .group(1)!
        .replaceAll(RegExp('[Oo]'), '0')
        .replaceAll(RegExp('[Il|]'), '1')
        .replaceAll('S', '5');
    if (RegExp(r'^50\d{6}$').hasMatch(t) && !out.contains(t)) out.add(t);
  }
  return out;
}

/// تنبيه بس (عمره ما يمنع الإرسال): الترمنل المقروء من صورة السيستم مختلف عن الوحدة المختارة.
/// لو الفرق رقم واحد بس بنعتبره غلطة قراءة (زي 50383702 تتقرا 50383700) ومش بننبّه.
String? sysTidWarning(List<String> read, Unit sel, List<Unit> units) {
  if (read.isEmpty) return null;
  if (read.any((t) => _tidDigitDiff(t, sel.tid) <= 1)) return null;
  final t = read.first;
  Unit? other;
  for (final u in units) {
    if (u.tid == t) other = u;
  }
  final what = other == null ? t : '${other.name} · $t';
  return 'رقم الترمنل في صورة السيستم ($what) مختلف عن الوحدة المختارة (${sel.name} · ${sel.tid}). '
      'اتأكد إنك مختار الوحدة الصح وصورت سيستم نفس الماكينة — لو كله صح كمّل عادي';
}

/// نسخة واتساب لصورة السيستم + شريط أبيض تحتها فيه A2R SYS والترمنل والكود والتاريخ.
/// الشريط بيتضاف تحت الصورة (مش فوقها)، والصورة نفسها بنفس بكسلاتها (أو نفس تصغير واتساب القديم لو أكبر
/// من kWaMaxSide). عند أي فشل بنرجع للنسخة القديمة من غير شريط (الإرسال لا يتعطل أبدًا).
Future<String> sysShareCopy(String path, Session s) async {
  try {
    final dir = (await Store.dir()).path;
    final raw = await File(path).readAsBytes();
    final sz = await imageSize(raw);
    // من غير تصغير: صورة السيستم بتتبعت بمقاسها المخزّن
    final src = await decodeImage(raw);
    final w = src.width, h = src.height;
    final text = sysStripText(s.unit, DateTime.now());
    TextPainter mk(double f) => TextPainter(
          text: TextSpan(
            text: text,
            style: TextStyle(
              color: const Color(0xFF000000),
              fontSize: f,
              fontWeight: FontWeight.w700,
              fontFamily: 'monospace',
              letterSpacing: f * 0.08,
              height: 1.0,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
    // الخط كبير على قد عرض الصورة (حوالي 92%) علشان يتقري حتى بعد ضغط واتساب العادي
    var fs = math.max(18.0, w / 16.0);
    var tp = mk(fs);
    if (tp.width > w * 0.92) {
      fs = fs * (w * 0.92) / tp.width;
      tp = mk(fs);
    }
    final pad = math.max(8.0, fs * 0.5);
    final band = (tp.height + pad * 2).ceil();
    final oh = h + band;
    // الشريط بس بيترسم (صغير)، والصورة الكاملة بتتركّب صف صف من غير نسخ RGBA/PNG كاملة زيادة
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    c.drawRect(Rect.fromLTWH(0, 0, w.toDouble(), band.toDouble()), Paint()..color = const Color(0xFFFFFFFF));
    c.drawRect(Rect.fromLTWH(0, 0, w.toDouble(), math.max(1.0, fs * 0.06)),
        Paint()..color = const Color(0xFF000000));
    tp.paint(c, Offset((w - tp.width) / 2, pad));
    final pic = rec.endRecording();
    final stripImg = await pic.toImage(w, band);
    pic.dispose();
    final stripPng = await stripImg.toByteData(format: ui.ImageByteFormat.png);
    stripImg.dispose();
    if (stripPng == null) throw Exception('تعذر تجهيز صورة السيستم بالجودة الكاملة');
    final jpg = await _composeEncode(src, Tag(_bytesOf(stripPng), w.toDouble(), band.toDouble()),
        ow: w, oh: oh, ix: 0, iy: 0, tx: 0, ty: h, q: 100, label: 'sysCopy');
    final f = File('$dir/wa_sys_${DateTime.now().microsecondsSinceEpoch}_${_waSeq++}.jpg');
    await f.writeAsBytes(jpg, flush: true);
    AppLog.i('sysCopy ${sz.w}x${sz.h} -> ${w}x$oh strip="$text" ${jpg.length ~/ 1024}KB');
    return f.path;
  } catch (e, st) {
    AppLog.e('sysCopy', e, st);
    rethrow;
  }
}

Future<Uint8List> composeReceiptImage(String path, Session s, {String? pageLabel}) async {
  final src = await File(path).readAsBytes();
  if (await Store.noTag(path)) return src;
  final sz = await imageSize(src);
  final maxSide = getMaxSide(await Store.perfMode(), profile: ImageQualityProfile.receipts);
  final img = await decodeImage(src, maxWidth: sz.w > maxSide ? maxSide : null);
  final iw = img.width, ih = img.height;
  final tag = await receiptTag(iw.toDouble(), s, pageLabel: pageLabel);
  final pad = iw * kBandPad;
  final band = (tag.h + pad * 2).ceil();
  final oh = ih + band;
  final q = await Store.jpegQuality(profile: ImageQualityProfile.receipts);
  final jpg = await _composeEncode(img, tag,
      ow: iw, oh: oh, ix: 0, iy: band, tx: ((iw - tag.w) / 2).round(), ty: pad.round(), q: q, label: 'receiptImg');
  await logImageQuality('share-photo', jpg, profile: ImageQualityProfile.receipts);
  return jpg;
}
/// PDF الإيصالات: كل صفحة = جزء أبيض فيه الورقة + صورة الإيصال الأصلية (JPEG بيتحط في الـ PDF زي ما هو
/// من غير إعادة رسم ولا إعادة ضغط، فالجودة أحسن والذاكرة أقل بكتير).
Future<File> buildReceiptsPdf(Session s, List<String> receipts,
    {bool? forceCompact, void Function(int done, int total)? onProgress}) async {
  Store.working++;
  try {
    final doc = pw.Document();
    const pageW = 595.0;
    final pad = pageW * kBandPad;
    final compact = forceCompact ?? false;
    final swPdf = Stopwatch()..start();
    for (var i = 0; i < receipts.length; i++) {
      onProgress?.call(i, receipts.length);
      var bytes = await File(receipts[i]).readAsBytes();
      if (compact) {
        // PDF مضغوط: نسخة أصغر (عرض ~720 وجودة 70) لو طلعت أخف وسليمة، وإلا بنستخدم الأصلية
        try {
          // صورة فيها ١٥ إيصال: الضغط لـ 720 هيمسح الأرقام، فبنخلّي دقة أعلى بكتير
          final c = await FlutterImageCompress.compressWithList(bytes,
              minWidth: 2200,
              minHeight: 2200,
              quality: 78,
              format: CompressFormat.jpeg);
          if (c.isNotEmpty && c.length < bytes.length && await _decodesOk(c)) bytes = c;
        } catch (e, st) {
          AppLog.e('pdf.compact', e, st);
        }
      }
      await logImageQuality(compact ? 'pdf-compact' : 'pdf-original', bytes,
          profile: ImageQualityProfile.receipts);
      final sz = await imageSize(bytes);
      final imgH = pageW * sz.h / sz.w;
      final hide = await Store.noTag(receipts[i]);
      Tag? pTag;
      pw.MemoryImage? pTagImg;
      var tw = 0.0, th = 0.0, bandH = 0.0;
      if (!hide) {
        pTag = await receiptTag(1000, s, pageLabel: '${i + 1} / ${receipts.length}');
        pTagImg = pw.MemoryImage(pTag.png);
        tw = pageW * pTag.w / 1000;
        th = pageW * pTag.h / 1000;
        bandH = th + pad * 2;
      }
      final pageH = (hide ? 0.0 : bandH) + imgH + 1;
      final image = pw.MemoryImage(bytes);
      doc.addPage(pw.Page(
        pageFormat: PdfPageFormat(pageW, pageH),
        margin: pw.EdgeInsets.zero,
        build: (_) => pw.Column(children: [
          if (!hide && pTagImg != null)
            pw.Container(
              width: pageW,
              height: bandH,
              alignment: pw.Alignment.center,
              child: pw.Image(pTagImg, width: tw, height: th),
            ),
          pw.Image(image, width: pageW, height: imgH),
        ]),
      ));
      await Future.delayed(Duration.zero); // نسيب الواجهة تتنفس على التليفونات الضعيفة
    }
    onProgress?.call(receipts.length, receipts.length);
    final dir = await Store.dir();
    final suffix = compact ? '_compact' : '';
    final file = File('${dir.path}/${s.pdfName}$suffix.pdf');
    final sp = await SharedPreferences.getInstance();
    if (sp.getString('pdfPath') == file.path) {
      await Store._archiveSentPdf(sp, file.path); // cam: PDF بنفس الاسم: ميتكتبش فوقه
    }
    await file.writeAsBytes(await doc.save(), flush: true);
    AppLog.i('t pdf compact=$compact ${swPdf.elapsedMilliseconds}ms ${await file.length()}B');
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

  /// مدة الاحتفاظ بالباتش والإيصالات بعد الإرسال (قابلة للتعديل وإعادة الإرسال).
  /// بتتمسح تلقائياً مع فتح التطبيق لما المدة تعدّي.
  static const sentLife = Duration(hours: 12);
  static int working = 0; // عدد العمليات الشغالة (بتمنع التنظيف أثناءها)
  static Future<SharedPreferences> get _p => SharedPreferences.getInstance();

  static Future<Directory> dir() async {
    final base = await getApplicationDocumentsDirectory();
    final d = Directory('${base.path}/a2r');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  static Future<void> del(String path) async {
    _adaptiveCache.remove(path);
    if (_hotImgPath == path) {
      _hotImgPath = null;
      _hotImgBytes = null;
    }
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
      final bf = File(baseOf(path));
      if (await bf.exists()) await bf.delete();
      final p = await _p;
      await p.remove('pos:$path');
      await p.remove('edit:$path');
      await p.remove('notag:$path');
      await p.remove('enh:$path');
      await p.remove('ocr:$path');
      await p.remove('quality:$path');
      await p.remove('pendingEdit:$path');
      final kept = p.getStringList('kept');
      if (kept != null && kept.remove(path)) await p.setStringList('kept', kept);
      final arch = p.getStringList('archive');
      if (arch != null && arch.remove(path)) await p.setStringList('archive', arch);
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

  /// محرك التصوير: 0 كاميرا A2R المخصصة، 1 ماسح جوجل (ML Kit) — الافتراضي ماسح جوجل
  /// محرك التصوير الافتراضي للتطبيق كله (والباتش): 1 ماسح جوجل (الافتراضي)، 0 كاميرا A2R. من الإعدادات بس.
  static Future<int> scanEngine() async {
    final p = await _p;
    // مرة واحدة: النسخ القديمة كانت بتغيّر المحرك العام لما تختار كاميرا A2R في إيصالات الدفع، فبنرجّعه لماسح جوجل
    if (p.getBool('engMig1') != true) {
      await p.setInt('scanEngine', 1);
      await p.setBool('engMig1', true);
    }
    return (p.getInt('scanEngine') ?? 1).clamp(0, 2);
  }

  static Future<void> setScanEngine(int v) async => (await _p).setInt('scanEngine', v);

  /// محرك التصوير بتاع إيصالات الدفع بس (اختيارك في أول الملف). مبيأثرش على الباتش ولا على باقي التطبيق.
  /// 2 = ماسح جوجل الكامل (قص + تحسين زي CamScanner)، 1 = ماسح جوجل قص بس، 0 = كاميرا A2R.
  static Future<int> scanEngineReceipts() async {
    final p = await _p;
    // مرة واحدة: الوضع الكامل بقى الافتراضي لإيصالات الدفع (اللي اختار كاميرا A2R بيفضل زي ما هو)
    if (p.getBool('engMig2') != true) {
      if ((p.getInt('scanEngineR') ?? 1) == 1) await p.setInt('scanEngineR', 2);
      await p.setBool('engMig2', true);
    }
    return (p.getInt('scanEngineR') ?? 2).clamp(0, 2);
  }

  static Future<void> setScanEngineReceipts(int v) async => (await _p).setInt('scanEngineR', v);

  /// جودة الصورة: 0 صغيرة، 1 عادية، 2 عالية
  static Future<int> qualitySetting() async => ((await _p).getInt('jpegQ') ?? 1).clamp(0, 2);
  static Future<void> setQualitySetting(int v) async => (await _p).setInt('jpegQ', v);

  /// دقة الصورة: 0 تلقائي (حسب وضع الأداء)، 1 صغيرة 720p، 2 متوسطة 1080p، 3 عالية 4K، 4 أعلى
  static Future<int> resSetting() async => ((await _p).getInt('resLevel') ?? 0).clamp(0, kResLevels.length);
  static Future<void> setResSetting(int v) async {
    gResLevel = v.clamp(0, kResLevels.length);
    await (await _p).setInt('resLevel', gResLevel);
  }

  static Future<int> jpegQuality({ImageQualityProfile? profile}) async {
    final b = await _jpegQualityBase();
    return profile == null ? b : math.max(b, profile.jpegQuality);
  }

  static Future<int> _jpegQualityBase() async {
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
  // cam: تعديلات قايمة المسودة بتتنفّذ واحدة ورا التانية، عشان حفظ لقطة ومسح لقطة في نفس الوقت ميضيّعوش تعديل بعض
  static Future<void> _draftTail = Future<void>.value();
  static Future<void> _draftLocked(Future<void> Function() f) {
    final r = _draftTail.then((_) => f());
    _draftTail = r.then((_) {}, onError: (_) {});
    return r;
  }

  static Future<void> unlistFromDraft(String path) => _draftLocked(() => _unlistFromDraftRaw(path));

  static Future<void> _unlistFromDraftRaw(String path) async {
    final l = await draft();
    l.remove(path);
    await (await _p).setStringList('draft', l);
  }

  static Future<void> relistInDraft(String path, int index) => _draftLocked(() => _relistInDraftRaw(path, index));

  static Future<void> _relistInDraftRaw(String path, int index) async {
    if (!File(path).existsSync()) return;
    final l = await draft();
    if (!l.contains(path)) l.insert(index.clamp(0, l.length), path);
    await (await _p).setStringList('draft', l);
  }

  static Future<ScanFilter> filter() async {
    final p = await _p;
    // New automatic policy is the default once, then explicit manual choices persist.
    if (p.getBool('adaptiveReceiptV2') != true) {
      await p.setInt('filter', ScanFilter.adaptive.index);
      await p.setBool('adaptiveFilterV1', true);
      await p.setBool('adaptiveReceiptV2', true);
    }
    final i = p.getInt('filter') ?? ScanFilter.adaptive.index;
    return ScanFilter.values[i.clamp(0, ScanFilter.values.length - 1)];
  }

  static Future<void> setFilter(ScanFilter f) async => (await _p).setInt('filter', f.index);

  /// المظهر: 0 داكن (الافتراضي)، 1 زي النظام، 2 فاتح
  static Future<int> themeSetting() async => ((await _p).getInt('themeMode') ?? 0).clamp(0, 2).toInt();
  static Future<void> setThemeSetting(int v) async => (await _p).setInt('themeMode', v);

  /// اللون: 0 ذهبي (الافتراضي)، 1 فضي، 2 أزرق
  static Future<int> paletteSetting() async =>
      ((await _p).getInt('palette') ?? 0).clamp(0, AppPalette.values.length - 1).toInt();
  static Future<void> setPaletteSetting(int v) async => (await _p).setInt('palette', v);

  /// القص التلقائي: 0 ذكي (الافتراضي)، 1 مستطيل دايماً، 2 منظور دايماً
  static Future<int> autoCropSetting() async =>
      ((await _p).getInt('autoCrop') ?? 0).clamp(0, 2).toInt();
  static Future<void> setAutoCropSetting(int v) async => (await _p).setInt('autoCrop', v);

  static Future<bool> continuous() async => (await _p).getBool('continuous') ?? true;
  static Future<void> setContinuous(bool v) async => (await _p).setBool('continuous', v);

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

  /// ورقة الباتش بقت على الصورة بس (الشريط تحت وفوق اتلغوا)، فالقيمة دايماً 2.
  static Future<int> batchLayout() async => 2;
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

  /// مكان الورقة لصورة باتش: بيتحفظ للصورة دي، وكمان كأساس للباتشات الجاية.
  /// اللي بيتحفظ هو المسافة من أسفل الصورة (مش من فوق) عشان المكان يتكيف مع أي ارتفاع للصورة.
  static Future<void> saveBatchPos(String path, TagPos v, double aspect) async {
    final p = await _p;
    await p.setString('pos:$path', v.encode());
    await p.setString('lastBot_b', '${v.cx},${aspect - v.cy},${v.s}');
  }

  /// آخر مكان ظبطه الموظف للورقة، متحوّل لصورة بالارتفاع ده (null لو لسه محدش حركها).
  static Future<TagPos?> lastBatchPos(double aspect) async {
    final v = (await _p).getString('lastBot_b')?.split(',');
    if (v == null || v.length != 3) return null;
    final a = double.tryParse(v[0]), b = double.tryParse(v[1]), c = double.tryParse(v[2]);
    if (a == null || b == null || c == null || !a.isFinite || !b.isFinite || !c.isFinite) return null;
    return TagPos(a.clamp(0.0, 1.0).toDouble(), aspect - b, c.clamp(kTagMinScale, 1.0).toDouble());
  }

  /// بيحفظ مكان الورقة لصورة واحدة بس من غير ما يغيّر المكان الافتراضي المحفوظ للباتشات الجاية.
  static Future<void> setPosFor(String path, TagPos v) async =>
      (await _p).setString('pos:$path', v.encode());

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

  /// [fresh] = true لما تكون صورة باتش جديدة (تصوير/معرض)، false لما تكون نتيجة تعديل نفس الباتش.
  /// الباتش الجديد بعد باتش اتبعت بيبدأ من الأول (علامة الإرسال وبيانات الباتش القديمة بتتصفّر).
  static Future<void> setBatchImg(String path, {bool fresh = false}) async {
    final p = await _p;
    final old = p.getString('batchImg');
    if (old != null && old != path) {
      if (fresh && File(old).existsSync()) {
        // cam: باتش جديد مبيمسحش القديم، بيروح للأرشيف (المسح يدوي بس)
        final arch = p.getStringList('archive') ?? [];
        if (!arch.contains(old)) arch.add(old);
        await p.setStringList('archive', arch);
      } else {
        await del(old);
      }
    }
    await p.setString('batchImg', path);
    // باتش جديد من الكاميرا/المعرض: صورة السيستم القديمة متتعادلش معاه
    if (fresh && old != null && old != path) await _clearSystemPhoto(p, archive: true);
    if (fresh && p.getInt('batchSentAt') != null) await _resetBatchMeta(p, archive: true);
  }

  static Future<void> _resetBatchMeta(SharedPreferences p, {bool archive = false}) async {
    await p.remove('batchSentAt');
    for (final k in ['bi_count', 'bi_pi', 'bi_col', 'bi_total']) {
      await p.remove(k);
    }
    await _clearSystemPhoto(p, archive: archive);
  }

  /// صورة السيستم المرفقة بالباتش الحالي (بتتبعت معاه كصورة مستقلة بنفس الوصف).
  static Future<String?> systemPhoto() async {
    final p = await _p;
    final s = p.getString('systemImg');
    if (s != null && !File(s).existsSync()) {
      await p.remove('systemImg');
      return null;
    }
    return s;
  }

  static Future<void> archivePath(String path) async => _archivePath(await _p, path);

  static Future<void> setSystemPhoto(String path) async {
    final p = await _p;
    final old = p.getString('systemImg');
    if (old != null && old != path) await _archivePath(p, old); // cam: القديمة للأرشيف مش بتتمسح
    await p.setString('systemImg', path);
  }

  /// cam: بينقل ملف للأرشيف من غير ما يمسحه (المسح يدوي بس من شاشة الأرشيف).
  static Future<void> _archivePath(SharedPreferences p, String path) async {
    if (!File(path).existsSync()) return;
    final arch = p.getStringList('archive') ?? [];
    if (!arch.contains(path)) arch.add(path);
    await p.setStringList('archive', arch);
  }

  static Future<void> _clearSystemPhoto(SharedPreferences p, {bool archive = false}) async {
    final old = p.getString('systemImg');
    if (old != null) {
      if (archive) {
        await _archivePath(p, old);
      } else {
        await del(old);
      }
    }
    await p.remove('systemImg');
  }

  /// cam: إعادة أخذ للباتش: الصورة والسيستم بيروحوا للأرشيف مش بيتمسحوا.
  static Future<void> retireBatchImg() async {
    final p = await _p;
    final old = p.getString('batchImg');
    if (old != null) await _archivePath(p, old);
    await p.remove('batchImg');
    await _resetBatchMeta(p, archive: true);
  }

  /// cam: الـPDF المتبعت بيتنقل لأرشيف بإسم فيه الوقت بدل ما يتمسح أو يتكتب فوقه.
  static Future<void> _archiveSentPdf(SharedPreferences p, String path) async {
    final f = File(path);
    if (!f.existsSync()) return;
    final dir = (await dir_()).path;
    final base = path.split('/').last;
    final pre = p.getInt('rcSentAt') != null ? 'sent' : 'pdf';
    final dst = '$dir/${pre}_${DateTime.now().millisecondsSinceEpoch}_$base';
    await f.rename(dst);
    final arch = p.getStringList('archive') ?? [];
    arch.add(dst);
    await p.setStringList('archive', arch);
  }

  static Future<Directory> dir_() => dir();

  static Future<void> clearBatchImg() async {
    final p = await _p;
    final old = p.getString('batchImg');
    if (old != null) await del(old);
    await p.remove('batchImg');
    await _resetBatchMeta(p);
  }

  /// بعد إرسال الباتش: الصورة وبياناتها بيفضلوا ١٢ ساعة (قابلين للتعديل وإعادة الإرسال).
  static Future<void> afterBatchSent() async {
    final p = await _p;
    await p.setInt('batchSentAt', DateTime.now().millisecondsSinceEpoch);
    await setFlag('batch');
  }

  /// وقت إرسال الباتش (null لو لسه متبعتش).
  static Future<DateTime?> batchSentAt() async {
    final p = await _p;
    final t = p.getInt('batchSentAt');
    if (t == null || p.getString('batchImg') == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(t);
  }

  // --- صور الإيصالات ---
  static Future<void> setDraft(List<String> l) async => (await _p).setStringList('draft', l);

  static Future<List<String>> pdfImgs() async => (await _p).getStringList('pdfImgs') ?? [];

  static Future<List<String>> draft() async {
    final l = (await _p).getStringList('draft') ?? [];
    return l.where((e) => File(e).existsSync()).toList();
  }

  static Future<void> addToDraft(String path) => _draftLocked(() => _addToDraftRaw(path));

  static Future<void> _addToDraftRaw(String path) async {
    final l = await draft();
    final p = await _p;
    if (l.isEmpty) {
      // مسودة جديدة بعد ما اتمسح كل حاجة: متفضلش علامة "اتبعت" قديمة
      await p.remove('rcSentAt');
      await p.remove('rcSentImgs');
    }
    l.add(path);
    await p.setStringList('draft', l);
  }

  static Future<void> removeFromDraft(String path) => _draftLocked(() => _removeFromDraftRaw(path));

  static Future<void> _removeFromDraftRaw(String path) async {
    final l = await draft();
    l.remove(path);
    await del(path);
    await (await _p).setStringList('draft', l);
  }

  static Future<void> clearDraft() async {
    for (final e in await draft()) {
      await del(e);
    }
    final p = await _p;
    await p.setStringList('draft', []);
    await p.remove('rcSentAt');
    await p.remove('rcSentImgs');
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

  /// صورة متحسّنة من ماسح جوجل الكامل: منطبّقش عليها فلتر الإيصال تاني (منع التحسين المزدوج).
  static Future<bool> enhanced(String path) async => (await _p).getBool('enh:$path') ?? false;

  static Future<void> setEnhanced(String path, bool v) async {
    final p = await _p;
    if (v) {
      await p.setBool('enh:$path', true);
    } else {
      await p.remove('enh:$path');
    }
  }

  static Future<bool> editPending(String path) async =>
      (await _p).getBool('pendingEdit:$path') ?? false;

  static Future<void> setEditPending(String path, bool value) async =>
      (await _p).setBool('pendingEdit:$path', value);

  static Future<ImageQualityProfile?> qualityProfile(String path) async {
    final p = await _p;
    if (p.getString('quality:$path') == ImageQualityProfile.detailedCapture.id) {
      return ImageQualityProfile.detailedCapture;
    }
    if (p.getString('quality:$path') == ImageQualityProfile.receipts.id) {
      return ImageQualityProfile.receipts;
    }
    if (p.getString('quality:$path') == ImageQualityProfile.batch.id) {
      return ImageQualityProfile.batch;
    }
    // Existing receipt drafts and PDFs get the receipt profile on first use.
    if ((p.getStringList('draft') ?? []).contains(path) ||
        (p.getStringList('pdfImgs') ?? []).contains(path) ||
        (p.getStringList('rcSentImgs') ?? []).contains(path)) {
      await p.setString('quality:$path', ImageQualityProfile.receipts.id);
      return ImageQualityProfile.receipts;
    }
    return null;
  }

  static Future<void> setQualityProfile(String path, ImageQualityProfile profile) async =>
      (await _p).setString('quality:$path', profile.id);

  /// نص الصورة المقروء بالـ OCR (بيتخزن أول مرة قراءة عشان البحث يبقى سريع).
  static Future<String?> ocrText(String path) async => (await _p).getString('ocr:$path');

  static Future<void> setOcrText(String path, String t) async =>
      (await _p).setString('ocr:$path', t);

  // --- الأرشيف: صور متعلّم عليها "احتفظ بيها" بتتنقل هنا بدل المسح بعد ١٢ ساعة من الإرسال ---
  static Future<List<String>> archive() async {
    final l = (await _p).getStringList('archive') ?? [];
    return l.where((e) => File(e).existsSync()).toList();
  }

  static Future<bool> isKept(String path) async =>
      ((await _p).getStringList('kept') ?? []).contains(path);

  /// تعليم/إلغاء تعليم صورة "احتفظ بيها". بيتطبق لما تتبعت وتعدّي ١٢ ساعة.
  static Future<void> setKept(String path, bool v) async {
    final p = await _p;
    final l = p.getStringList('kept') ?? [];
    if (v && !l.contains(path)) {
      l.add(path);
      await p.setStringList('kept', l);
    } else if (!v && l.remove(path)) {
      await p.setStringList('kept', l);
    }
  }

  /// مسح صورة من الأرشيف نهائياً.
  static Future<void> unarchive(String path) async {
    final p = await _p;
    final l = p.getStringList('archive') ?? [];
    if (l.remove(path)) await p.setStringList('archive', l);
    await del(path);
  }

  static Future<EditParams?> editOf(String path) async =>
      EditParams.decode((await _p).getString('edit:$path'));

  static Future<void> setEdit(String path, EditParams e) async =>
      (await _p).setString('edit:$path', e.encode());

  /// بعد تعديل إيصال: الصورة الجديدة تاخد مكان القديمة في نفس الترتيب.
  static Future<void> replaceInDraft(String old, String neu) => _draftLocked(() => _replaceInDraftRaw(old, neu));

  static Future<void> _replaceInDraftRaw(String old, String neu) async {
    final l = await draft();
    final i = l.indexOf(old);
    if (i < 0) {
      l.add(neu);
    } else {
      l[i] = neu;
    }
    final p = await _p;
    await p.setStringList('draft', l);
    if (await noTag(old)) await setNoTag(neu, true); // الاختيار يفضل بعد التعديل
    if (await enhanced(old)) await setEnhanced(neu, true);
    final profile = await qualityProfile(old);
    if (profile != null) await setQualityProfile(neu, profile);
    // لو الصورة كانت من اللي اتبعتوا: الصورة المعدّلة تاخد مكانها في قايمة "اتبعت"
    final sent = p.getStringList('rcSentImgs');
    if (sent != null && sent.contains(old)) {
      await p.setStringList('rcSentImgs', [for (final x in sent) x == old ? neu : x]);
    }
    // الـ PDF القديم مبقاش مظبوط بعد التعديل
    if ((p.getStringList('pdfImgs') ?? []).contains(old)) await clearPdf();
    await del(old);
  }

  // --- ملف الـ PDF (يفضل 24 ساعة) ---
  static Future<({File file, DateTime time})?> pdf() async {
    final p = await _p;
    final path = p.getString('pdfPath');
    final t = p.getInt('pdfTime');
    if (path == null || t == null) return null;
    final time = DateTime.fromMillisecondsSinceEpoch(t);
    // لو الإيصالات اتبعتت: المدة ١٢ ساعة من وقت الإرسال، وإلا ٢٤ ساعة من وقت إنشاء الـ PDF
    final sentT = p.getInt('rcSentAt');
    final age = DateTime.now()
        .difference(sentT == null ? time : DateTime.fromMillisecondsSinceEpoch(sentT));
    final life = sentT == null ? pdfLife : sentLife;
    if (!File(path).existsSync()) {
      await clearPdf();
      return null;
    }
    return (file: File(path), time: time);
  }

  static Future<void> setPdf(File f, List<String> imgs) async {
    final p = await _p;
    final old = p.getString('pdfPath');
    if (old != null && old != f.path) await _archiveSentPdf(p, old); // cam: أي PDF بيتبدّل بيتحفظ
    await p.setString('pdfPath', f.path);
    await p.setInt('pdfTime', DateTime.now().millisecondsSinceEpoch);
    await p.setStringList('pdfImgs', imgs);
  }

  static Future<void> clearPdf() async {
    final p = await _p;
    final old = p.getString('pdfPath');
    if (old != null) await _archiveSentPdf(p, old); // cam: أي PDF بيتنضّف بيتحفظ في الأرشيف
    await p.remove('pdfPath');
    await p.remove('pdfTime');
    await p.remove('pdfImgs');
  }

  /// بعد إرسال الإيصالات: الصور والـ PDF بيفضلوا ١٢ ساعة (قابلين للتعديل وإعادة الإرسال).
  static Future<void> afterPdfSent() async {
    final p = await _p;
    final used = (p.getStringList('pdfImgs') ?? []).where((e) => File(e).existsSync()).toList();
    if (used.isNotEmpty) {
      await p.setInt('rcSentAt', DateTime.now().millisecondsSinceEpoch);
      await p.setStringList('rcSentImgs', used);
    }
    await setFlag('receipts');
  }

  /// وقت إرسال الإيصالات (null لو مفيش إيصالات متبعتة محتفظ بيها).
  static Future<DateTime?> receiptsSentAt() async {
    final p = await _p;
    final t = p.getInt('rcSentAt');
    if (t == null) return null;
    final sent = (p.getStringList('rcSentImgs') ?? []).where((e) => File(e).existsSync());
    if (sent.isEmpty) {
      await p.remove('rcSentAt');
      await p.remove('rcSentImgs');
      return null;
    }
    return DateTime.fromMillisecondsSinceEpoch(t);
  }

  /// بيمسح الإيصالات اللي اتبعتت بس (الصور اللي لسه متبعتتش بتفضل) مع الـ PDF بتاعها.
  static Future<void> discardSentReceipts() async {
    final p = await _p;
    final sent = p.getStringList('rcSentImgs') ?? [];
    final left = await draft();
    final arch = p.getStringList('archive') ?? [];
    for (final u in sent) {
      // cam: «ابدأ جديد» مبيمسحش المتبعت، بينقله للأرشيف (المسح يدوي بس)
      if (File(u).existsSync() && !arch.contains(u)) arch.add(u);
      left.remove(u);
    }
    await p.setStringList('archive', arch);
    await p.setStringList('draft', left);
    await clearPdf(); // قبل ما نمسح علامة الإرسال، عشان الـPDF المتبعت يتحفظ
    await p.remove('rcSentAt');
    await p.remove('rcSentImgs');
  }

  /// بيتنفّذ مع فتح التطبيق: بيمسح الباتش والإيصالات اللي عدّى عليهم أكتر من ١٢ ساعة من الإرسال.
  static Future<void> expireSent() async {
    return; // cam: الملفات بتفضل محفوظة ومبتتمسحش تلقائياً، المسح يدوي بس
    // ignore: dead_code
    if (working > 0) return;
    final p = await _p;
    final now = DateTime.now();
    final bt = p.getInt('batchSentAt');
    if (bt != null && now.difference(DateTime.fromMillisecondsSinceEpoch(bt)) > sentLife) {
      final bi = p.getString('batchImg');
      if (bi != null && await isKept(bi)) {
        // محفوظ: يروح للأرشيف بدل المسح (ميفضلش باتش حالي)
        final arch = p.getStringList('archive') ?? [];
        if (!arch.contains(bi)) arch.add(bi);
        await p.setStringList('archive', arch);
        await setKept(bi, false);
        await p.remove('batchImg');
        await _resetBatchMeta(p);
      } else {
        await clearBatchImg();
      }
    }
    final rt = p.getInt('rcSentAt');
    if (rt != null && now.difference(DateTime.fromMillisecondsSinceEpoch(rt)) > sentLife) {
      // الإيصالات المحفوظة تروح للأرشيف الأول، والباقي يتمسح عادي
      final sent = p.getStringList('rcSentImgs') ?? [];
      final arch = p.getStringList('archive') ?? [];
      final left = await draft();
      var changed = false;
      for (final u in List.of(sent)) {
        if (await isKept(u)) {
          if (!arch.contains(u)) arch.add(u);
          changed = true;
          await setKept(u, false);
          sent.remove(u);
          left.remove(u);
        }
      }
      if (changed) {
        await p.setStringList('archive', arch);
        await p.setStringList('rcSentImgs', sent);
        await p.setStringList('draft', left);
      }
      await discardSentReceipts();
    }
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

  // --- سجل الإرسال (بيفضل ٣٠ يوم، ومبيتمسحش مع تنظيف الصور) ---
  static const logKeep = Duration(days: 30);
  static const _logMax = 300;

  static Future<List<SendLogEntry>> readLog() async {
    final raw = (await _p).getString('sendLog');
    if (raw == null) return [];
    try {
      final l = <SendLogEntry>[];
      for (final e in jsonDecode(raw) as List) {
        try {
          l.add(SendLogEntry.fromJson(Map<String, dynamic>.from(e as Map)));
        } catch (_) {}
      }
      final cut = DateTime.now().subtract(logKeep);
      l.removeWhere((e) => e.time.isBefore(cut));
      l.sort((a, b) => b.time.compareTo(a.time));
      return l;
    } catch (e, st) {
      AppLog.e('readLog', e, st);
      return [];
    }
  }

  /// [kind]: batch | receipts. بيتسجل بعد ما الإرسال يتأكد بس.
  static Future<void> addLog(Session s, String kind, String detail) async {
    try {
      final l = await readLog();
      l.insert(
          0,
          SendLogEntry(
              time: DateTime.now(),
              kind: kind,
              name: s.name,
              unit: s.unit.name,
              building: s.building,
              detail: detail));
      if (l.length > _logMax) l.removeRange(_logMax, l.length);
      await (await _p).setString('sendLog', jsonEncode([for (final e in l) e.toJson()]));
    } catch (e, st) {
      AppLog.e('addLog', e, st);
    }
  }

  static Future<void> clearLog() async => (await _p).remove('sendLog');

  /// مسح أي ملفات مؤقتة مش تابعة لمسودة أو PDF شغّال. مبتشتغلش لو فيه عملية شغالة.
  static Future<void> cleanup() async {
    if (working > 0) return;
    final keep = <String>{...await draft(), ...await pdfImgs(), ...await archive()};
    final bi = await batchImg();
    if (bi != null) keep.add(bi);
    // cam: صفحات السكانر وصورة السيستم متتمسحش في التنضيف التلقائي
    final pp = await _p;
    keep.addAll(pp.getStringList('scanPages') ?? []);
    final sysI = pp.getString('systemImg');
    if (sysI != null) keep.add(sysI);
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

Future<List<String>> simplePick(BuildContext context,
    {bool multi = false, ImageQualityProfile? profile}) async {
  final src = await showModalBottomSheet<ImageSource>(
    context: context,
    builder: (c) => SafeArea(
      child: Wrap(children: [
        ListTile(
            leading: const Icon(Icons.photo_camera_rounded),
            title: const Text('الكاميرا'),
            onTap: () => Navigator.pop(c, ImageSource.camera)),
        ListTile(
            leading: const Icon(Icons.photo_library_rounded),
            title: const Text('المعرض'),
            onTap: () => Navigator.pop(c, ImageSource.gallery)),
      ]),
    ),
  );
  if (src == null) return [];
  try {
    final picker = ImagePicker();
    if (src == ImageSource.gallery && multi) {
      final xs = await picker.pickMultiImage(); // الأصل من غير تصغير أو إعادة ضغط
      return xs.map((e) => e.path).toList();
    }
    final x = await picker.pickImage(source: src); // الأصل من غير تصغير أو إعادة ضغط
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

Future<List<String>> _manualPick(BuildContext context,
    {bool multi = false, ImageQualityProfile? profile}) async {
  final r = await simplePick(context, multi: multi, profile: profile);
  _lastScanManual = r.isNotEmpty;
  return r;
}

const _engineOpts = <(int, String, String)>[
  (2, 'ماسح جوجل الكامل', 'قص وتحسين من جوجل، وإعادة تصوير من شاشة الماسح'),
  (1, 'ماسح جوجل', 'قص ذكي بالذكاء الاصطناعي، والتحسين بيتعمل من التطبيق'),
  (0, 'كاميرا A2R', 'كاميرا التطبيق المخصصة مع القص اليدوي/التلقائي'),
];

const _qualOpts = <(int, String, String)>[
  (0, 'صغيرة', 'ملف أخف وأسرع في الإرسال'),
  (1, 'عادية', 'متوازنة (الافتراضي)'),
  (2, 'عالية', 'أوضح وحجم أكبر'),
];

const _resOpts = <(int, String, String)>[
  (0, 'تلقائي', 'حسب وضع الأداء (الافتراضي)'),
  (1, 'صغيرة · 720p', 'أخف ملف وأسرع إرسال'),
  (2, 'متوسطة · 1080p', 'متوازنة'),
  (3, 'عالية · 4K', 'أوضح تفاصيل وحجم أكبر'),
  (4, 'أعلى · أقصى دقة', 'أكبر دقة ممكنة، ممكن يبطّأ على الموبايلات الضعيفة'),
];

bool _scanBusy = false; // يمنع فتح الماسح مرتين (الضغط المزدوج كان بيقفل التطبيق)
/// آخر صور رجعت من ماسح جوجل: هل اتعملها تحسين الوضع الكامل؟ (متحسّمة = ميتحطش عليها فلتر تاني)
bool _lastScanEnhanced = false;

Future<List<String>> scanImages(BuildContext context, int limit,
    {ScannerMode mode = ScannerMode.base, bool camFallback = false, ImageQualityProfile? profile}) async {
  if (_scanBusy) return [];
  _scanBusy = true;
  try {
    return await _scanImagesImpl(context, limit, mode: mode, camFallback: camFallback, profile: profile);
  } finally {
    _scanBusy = false;
  }
}

Future<List<String>> _scanImagesImpl(BuildContext context, int limit,
    {ScannerMode mode = ScannerMode.base, bool camFallback = false, ImageQualityProfile? profile}) async {
  _lastScanManual = false;
  _lastScanEnhanced = false;
  if (!await ensureCamera(context)) return [];
  if (!context.mounted) return [];
  final perf = await Store.perfMode();
  if (_scannerFailed || perf == PerfMode.lite) return _manualPick(context, multi: limit > 1, profile: profile);
  Object? lastErr;

  // بيرجّع قائمة الصور، أو قائمة فاضية لو المستخدم لغى، أو null لو الماسح فشل.
  Future<List<String>?> tryScan(ScannerMode m) async {
    // ماسح جوجل: الوضع الأساسي (base) قص بس عشان يرجّع الصورة الأصلية من غير فلتر مزدوج،
    // والوضع الكامل (full) قص + تحسين من جوجل نفسها زي CamScanner.
    final scanner = DocumentScanner(
      options: DocumentScannerOptions(mode: m, pageLimit: limit, isGalleryImport: true),
    );
    try {
      final r = await scanner.scanDocument();
      _rememberDiagnostic('lastScannerDiagnostic', 'آخر محاولة: اشتغل (${m.name})');
      return List<String>.from(r.images ?? const []);
    } catch (e) {
      if (e.toString().toLowerCase().contains('cancel')) return const <String>[];
      lastErr = e;
      _rememberDiagnostic('lastScannerDiagnostic', 'آخر محاولة: غير متاح أو فشلت. بديل A2R أو المعرض موجود');
      AppLog.e('scanImages.$m', e, StackTrace.current);
      return null;
    } finally {
      scanner.close();
    }
  }

  var usedMode = mode;
  var imgs = await tryScan(mode);
  if (imgs == null && mode != ScannerMode.base) {
    // الوضع الكامل ممكن يكون مش مدعوم على الموبايل ده (خدمات جوجل قديمة أو رامات قليلة): نرجع للأساسي
    usedMode = ScannerMode.base;
    imgs = await tryScan(usedMode);
  }
  if (imgs != null && imgs.isNotEmpty && usedMode != ScannerMode.base) _lastScanEnhanced = true;
  if (imgs != null) {
    AppLog.i('scanner requested=$mode used=$usedMode pages=${imgs.length}');
    return imgs;
  }
  if (!context.mounted) return [];
  _scannerFailed = true;
  try {
    (await SharedPreferences.getInstance())
        .setInt('scannerFailedAt', DateTime.now().millisecondsSinceEpoch);
  } catch (e, st) {
    AppLog.e('scanImages.prefs', e, st);
  }
  if (!context.mounted) return [];
  if (camFallback) {
    // الطالب بيحول لكاميرا A2R بنفسه: نرجّع فاضي من غير ما نفتح المعرض
    snack(context, 'ماسح جوجل مش متاح على الموبايل ده، هنستخدم كاميرا A2R');
    return [];
  }
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
            SelectableText('$lastErr', textDirection: TextDirection.ltr, style: const TextStyle(fontSize: 12)),
          ]),
        ),
        actions: [FilledButton(onPressed: () => Navigator.pop(c), child: const Text('تمام'))],
      ),
    ),
  );
  if (!context.mounted) return [];
  return _manualPick(context, multi: limit > 1, profile: profile);
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

/// نتيجة قراءة ورقة إغلاق الباتش من الصورة (أي قيمة ممكن تكون null لو متقرتش)
class BatchOcr {
  final String? count, total;
  final int parts; // عدد الأوراق اللي اتجمعت (1 = ورقة واحدة)
  final int missing; // عدد الأوراق اللي اتشافت بس متقرتش كويس
  final String detail; // تفاصيل الجمع لما يكون في أكتر من ورقة
  final List<String> tids; // أرقام الماكينات المقروءة من الورقة
  final String? receiptDate; // تاريخ الباتش المقروء من الورقة (DD/MM/YYYY)
  final bool dateIsToday; // هل تاريخ الورقة يطابق تاريخ النهارده
  final bool isReprint; // هل مكتوب عليها REPRINT
  final bool isSummaryReport; // هل مكتوب عليها SUMMARY REPORT (سمري مش إغلاق باتش)
  final bool isBatchClosed; // هل مكتوب عليها BATCH CLOSED SUCCESSFULLY
  final bool hasText; // هل الـ OCR قرأ نص من الورقة
  const BatchOcr(
    this.count,
    this.total, {
    this.parts = 1,
    this.missing = 0,
    this.detail = '',
    this.tids = const [],
    this.receiptDate,
    this.dateIsToday = true,
    this.isReprint = false,
    this.isSummaryReport = false,
    this.isBatchClosed = false,
    this.hasText = false,
  });

  BatchOcr withMeta({
    List<String>? tids,
    String? receiptDate,
    bool? dateIsToday,
    bool? isReprint,
    bool? isSummaryReport,
    bool? isBatchClosed,
    bool? hasText,
  }) =>
      BatchOcr(
        count,
        total,
        parts: parts,
        missing: missing,
        detail: detail,
        tids: tids ?? this.tids,
        receiptDate: receiptDate ?? this.receiptDate,
        dateIsToday: dateIsToday ?? this.dateIsToday,
        isReprint: isReprint ?? this.isReprint,
        isSummaryReport: isSummaryReport ?? this.isSummaryReport,
        isBatchClosed: isBatchClosed ?? this.isBatchClosed,
        hasText: hasText ?? this.hasText,
      );
}

final RegExp _ocrTidKw = RegExp(r'(?:terminal|tid)\s*(?:id)?\s*[:#\-]?\s*(\d{8})', caseSensitive: false);
final RegExp _ocrTid50 = RegExp(r'(?<!\d)(50\d{6})(?!\d)');
final RegExp _ocrDateIso = RegExp(r'(?<!\d)(20\d{2})[-/.](\d{1,2})[-/.](\d{1,2})(?!\d)');
final RegExp _ocrDateDmy = RegExp(r'(?<!\d)(\d{1,2})[-/.](\d{1,2})[-/.](20\d{2})(?!\d)');
final RegExp _ocrReprint = RegExp(r'reprint|duplicate', caseSensitive: false);
final RegExp _ocrSummaryReport = RegExp(r'summary\s*(?:report)?', caseSensitive: false);
final RegExp _ocrBatchClosed = RegExp(r'batch\s*closed\s*success\w*', caseSensitive: false);

BatchOcr _attachBatchMeta(BatchOcr base, List<String> rows) {
  final joined = rows.join('\n');
  final tidSet = <String>{};
  for (final m in _ocrTidKw.allMatches(joined)) {
    tidSet.add(m.group(1)!);
  }
  for (final m in _ocrTid50.allMatches(joined)) {
    tidSet.add(m.group(1)!);
  }
  String? rDate;
  var isToday = true;
  final now = DateTime.now();
  final mIso = _ocrDateIso.firstMatch(joined);
  final mDmy = _ocrDateDmy.firstMatch(joined);
  int? y, mo, d;
  if (mIso != null) {
    y = int.tryParse(mIso.group(1)!);
    mo = int.tryParse(mIso.group(2)!);
    d = int.tryParse(mIso.group(3)!);
  } else if (mDmy != null) {
    d = int.tryParse(mDmy.group(1)!);
    mo = int.tryParse(mDmy.group(2)!);
    y = int.tryParse(mDmy.group(3)!);
  }
  if (y != null && mo != null && d != null && mo >= 1 && mo <= 12 && d >= 1 && d <= 31) {
    rDate = '${d.toString().padLeft(2, '0')}/${mo.toString().padLeft(2, '0')}/$y';
    isToday = (y == now.year && mo == now.month && d == now.day);
  }
  return base.withMeta(
    tids: tidSet.toList(),
    receiptDate: rDate,
    dateIsToday: isToday,
    isReprint: _ocrReprint.hasMatch(joined),
    isSummaryReport: _ocrSummaryReport.hasMatch(joined),
    isBatchClosed: _ocrBatchClosed.hasMatch(joined),
    hasText: rows.isNotEmpty,
  );
}

/// تحذيرات ذكية لمطابقة ورقة الباتش: لازم يكون مكتوب عليها BATCH CLOSED SUCCESSFULLY
/// غير كده (زي SUMMARY REPORT أو REPRINT أو أي إيصال تاني) يطلع تنبيه فوري.
List<String> batchOcrWarnings(BatchOcr r, Session s) {
  final w = <String>[];
  if (r.isSummaryReport) {
    w.add('الورقة دي SUMMARY REPORT (سمري) ومش إغلاق باتش صحيح!');
  }
  if (r.isReprint) {
    w.add('الورقة مكتوب عليها REPRINT (إعادة طباعة) وليست إغلاق باتش أصلي!');
  }
  if (r.hasText && !r.isBatchClosed && !r.isSummaryReport) {
    w.add('لم يتم العثور على جملة "BATCH CLOSED SUCCESSFULLY" — اتأكد إن الورقة إغلاق باتش صحيح');
  }
  if (r.tids.isNotEmpty && !r.tids.contains(s.unit.tid)) {
    w.add('رقم الماكينة في الصورة (${r.tids.join('، ')}) مختلف عن الوحدة المختارة (${s.unit.name} · ${s.unit.tid})');
  }
  if (r.receiptDate != null && !r.dateIsToday) {
    w.add('تاريخ الباتش في الصورة (${r.receiptDate}) مختلف عن تاريخ النهارده (${s.date})');
  }
  return w;
}

final RegExp _ocrDec = RegExp(r'(?<![\d.,])\d[\d,]*[.,]\d{2}(?![\d.,])');
final RegExp _ocrCountKw =
    RegExp(r'count|cnt|txn|trans|no\.?\s*of|number|qty|عدد', caseSensitive: false);
final RegExp _ocrTotalKw =
    RegExp(r'total|amount|amt|sum|sales?|net|egp|اجمالي|إجمالي|مبلغ', caseSensitive: false);
final RegExp _ocrInt = RegExp(r'(?<![\d.,:/\-])\d{1,6}(?![\d.,:/\-])');

double? _ocrNum(String raw) {
  var t = raw;
  final m = RegExp(r'[.,](\d{2})$').firstMatch(t);
  if (m == null) return null;
  final intPart = t.substring(0, m.start).replaceAll(RegExp(r'[.,]'), '');
  return double.tryParse('$intPart.${m.group(1)}');
}

/// بيحلل أسطر النص (كل سطر = صف واحد من الورقة) ويطلع عدد المعاملات والإجمالي
BatchOcr _parseGeneric(List<String> rowsRaw) {
  final rows = rowsRaw;
  // أرقام عربية ← إنجليزي من غير ما نمس الفواصل
  String norm(String r) {
    const ar = '٠١٢٣٤٥٦٧٨٩', fa = '۰۱۲۳۴۵۶۷۸۹';
    final b = StringBuffer();
    for (final ch in r.split('')) {
      final i = ar.indexOf(ch), j = fa.indexOf(ch);
      b.write(i >= 0 ? i : (j >= 0 ? j : (ch == '٫' ? '.' : ch)));
    }
    return b.toString();
  }

  final rs = rows.map(norm).toList();

  // --- الإجمالي: أكبر رقم بكسور في الصفوف اللي فيها كلمة total/amount، وإلا أكبر رقم بكسور في الورقة
  double? best;
  int? bestRow;
  void scan(bool onlyKw) {
    for (var i = 0; i < rs.length; i++) {
      if (onlyKw && !_ocrTotalKw.hasMatch(rs[i])) continue;
      for (final m in _ocrDec.allMatches(rs[i])) {
        final v = _ocrNum(m.group(0)!);
        if (v != null && (best == null || v > best!)) {
          best = v;
          bestRow = i;
        }
      }
    }
  }

  scan(true);
  if (best == null) scan(false);

  // --- العدد
  String? count;
  var sawCountLabel = false;
  String? firstInt(String r) {
    final cleaned = r.replaceAll(_ocrDec, ' ');
    final matches = _ocrInt.allMatches(cleaned).toList();
    if (matches.length != 1) return null; // Split digits or several counts: ask, do not guess.
    final m = matches.single;
    if ((m.start > 0 && RegExp(r'[A-Za-z0-9]').hasMatch(cleaned[m.start - 1])) ||
        (m.end < cleaned.length && RegExp(r'[A-Za-z0-9]').hasMatch(cleaned[m.end]))) return null;
    return m.group(0);
  }

  for (var i = 0; i < rs.length && count == null; i++) {
    if (!_ocrCountKw.hasMatch(rs[i])) continue;
    sawCountLabel = true;
    count = firstInt(rs[i]);
    // القيمة ممكن تكون في السطر اللي بعده
    if (count == null && !RegExp(r'\d').hasMatch(rs[i]) && i + 1 < rs.length) {
      final nx = rs[i + 1];
      if (!_ocrCountKw.hasMatch(nx) && !_ocrTotalKw.hasMatch(nx)) count = firstInt(nx);
    }
  }
  // لو مفيش كلمة عدد: رقم صحيح قبل الإجمالي في نفس الصف
  if (count == null && !sawCountLabel && bestRow != null) {
    final r = rs[bestRow!];
    final dm = _ocrDec.firstMatch(r);
    if (dm != null) {
      count = firstInt(r.substring(0, dm.start));
    }
  }

  return BatchOcr(
    count == null ? null : '${int.parse(count)}',
    best == null ? null : best!.toStringAsFixed(2),
  );
}

final RegExp _ocrParen = RegExp(r'[(\[{]([^)\]}\r\n]*)[)\]}]');
final RegExp _ocrWholeCount = RegExp(r'^[0-9OoIl]{1,6}$');
final RegExp _ocrGrand = RegExp(r'grand', caseSensitive: false);
final RegExp _ocrEnd = RegExp(r'thank|hotline|nbe', caseSensitive: false);

/// ورقة NBE واحدة: من سطر GRAND TOTALS لحد سطر THANK. العدد بين أقواس (015) والمبلغ جنبه.
/// أي قيمة متقرتش بترجع null.
BatchOcr _parseGrandBlock(List<String> rows, int from, int to) {
  final counts = <String>{};
  var uncertainCount = false;
  double? best;
  for (var i = from; i < to; i++) {
    final r = rows[i];
    if (_ocrEnd.hasMatch(r)) break;
    final matches = _ocrParen.allMatches(r).toList();
    if (RegExp(r'[(\[{]').hasMatch(r) && matches.isEmpty) uncertainCount = true;
    for (final m in matches) {
      final token = m.group(1)!.trim();
      if (!_ocrWholeCount.hasMatch(token)) {
        uncertainCount = true; // Never accept 11 from (11B) or (11 8).
        continue;
      }
      final d = token.replaceAll(RegExp(r'[Oo]'), '0').replaceAll(RegExp(r'[Il]'), '1');
      counts.add('${int.parse(d)}');
    }
    for (final m in _ocrDec.allMatches(r)) {
      final v = _ocrNum(m.group(0)!);
      if (v != null && (best == null || v > best)) best = v;
    }
  }
  // Repeated Sale/Total counts must agree. A missing/ambiguous count stays empty.
  final count = !uncertainCount && counts.length == 1 ? counts.single : null;
  return BatchOcr(count, best?.toStringAsFixed(2));
}

/// كل ورقة في الصفوف دي (ممكن أكتر من ورقة فوق بعض): كل GRAND TOTALS ليه عدد وإجمالي.
List<BatchOcr> parseBatchSheets(List<String> rows) {
  final gis = <int>[
    for (var i = 0; i < rows.length; i++)
      if (_ocrGrand.hasMatch(rows[i])) i
  ];
  return [
    for (var k = 0; k < gis.length; k++)
      _parseGrandBlock(rows, gis[k], k + 1 < gis.length ? gis[k + 1] : rows.length)
  ];
}

/// جمع الأوراق: العدد والإجمالي (بالقروش عشان مفيش خطأ في الكسور).
BatchOcr sumBatchSheets(List<BatchOcr> sheets) {
  var n = 0, cents = 0, parts = 0, missing = 0;
  final cs = <String>[], ts = <String>[];
  for (final x in sheets) {
    if (x.count == null || x.total == null) {
      missing++;
      continue;
    }
    n += int.parse(x.count!);
    cents += (double.parse(x.total!) * 100).round();
    parts++;
    cs.add(x.count!);
    ts.add(x.total!);
  }
  if (parts == 0) return BatchOcr(null, null, missing: missing);
  return BatchOcr('$n', (cents / 100).toStringAsFixed(2),
      parts: parts,
      missing: missing,
      detail: parts > 1 ? 'العدد ${cs.join(' + ')} - الإجمالي ${ts.join(' + ')}' : '');
}

/// صفوف نص الباتش (ورقة أو أكتر فوق بعض). لو مفيش GRAND TOTALS واضح بنرجع للطريقة العامة.
BatchOcr parseBatchRows(List<String> rows) {
  final sheets = parseBatchSheets(rows);
  if (sheets.length > 1) return sumBatchSheets(sheets);
  final a = sheets.isEmpty ? const BatchOcr(null, null) : sheets.first;
  // Do not revive a rejected GRAND TOTALS count via the generic fallback.
  if (sheets.isNotEmpty) return a;
  final g = _parseGeneric(rows);
  return BatchOcr(a.count ?? g.count, a.total ?? g.total);
}

/// قراءة صورة الباتش بـ ML Kit وتجميع النص في صفوف حسب الموقع الرأسي.
/// لو في أكتر من ورقة باتش في الصورة (جنب بعض أو فوق بعض) بيقرا كل ورقة لوحدها ويجمعهم.
/// قراءة سطور النص الخام من صورة بـ ML Kit (المحرك بيقفل بعد كل قراءة).
Future<List<mlt.TextLine>> _ocrLinesOf(String path) async {
  final rec = mlt.TextRecognizer(script: mlt.TextRecognitionScript.latin);
  try {
    final res = await rec.processImage(mlt.InputImage.fromFilePath(path));
    final lines = <mlt.TextLine>[];
    for (final b in res.blocks) {
      lines.addAll(b.lines);
    }
    return lines;
  } finally {
    await rec.close();
  }
}

/// تجميع سطور ML Kit اللي على نفس المستوى في سطر نصي واحد (فوق لتحت، ومن الشمال لليمين).
List<String> _ocrRowsOfLines(List<mlt.TextLine> ls) {
  ls.sort((a, b) => a.boundingBox.center.dy.compareTo(b.boundingBox.center.dy));
  final groups = <List<mlt.TextLine>>[];
  double? cy, ch;
  for (final l in ls) {
    final c = l.boundingBox.center.dy, h = l.boundingBox.height;
    if (cy != null && ch != null && (c - cy).abs() < math.max(ch, h) * 0.6) {
      groups.last.add(l);
      cy = (cy + c) / 2;
    } else {
      groups.add([l]);
      cy = c;
      ch = h;
    }
  }
  final out = <String>[];
  for (final g in groups) {
    g.sort((a, b) => a.boundingBox.left.compareTo(b.boundingBox.left));
    out.add(g.map((l) => l.text).join(' '));
  }
  return out;
}

/// استخراج كل نص الصورة سطور مرتبة زي الورقة (للبحث في الإيصالات واستخراج النص).
Future<List<String>> readAllTextRows(String path) async {
  final lines = await _ocrLinesOf(path);
  if (lines.isEmpty) return <String>[];
  return _ocrRowsOfLines(lines);
}

Future<BatchOcr> readBatchInfo(String path) async {
  final lines = await _ocrLinesOf(path);
  {
    List<String> toRows(List<mlt.TextLine> ls) => _ocrRowsOfLines(ls);

    // قراءة الصورة كلها (بتغطي الورقة الواحدة، والأوراق اللي فوق بعض)
    final allRows = toRows(List.of(lines));
    AppLog.i('batch ocr rows: ${allRows.join(' || ')}');
    final whole = parseBatchRows(allRows);

    // لو في أكتر من ورقة جنب بعض: نفصلهم بالفراغ الأفقي بينهم ونقرا كل واحدة لوحدها ونجمع
    final spans = lines.map((l) => [l.boundingBox.left, l.boundingBox.right]).toList()
      ..sort((a, b) => a[0].compareTo(b[0]));
    final segs = <List<double>>[];
    for (final sp in spans) {
      if (segs.isNotEmpty && sp[0] <= segs.last[1]) {
        segs.last[1] = math.max(segs.last[1], sp[1]);
      } else {
        segs.add([sp[0], sp[1]]);
      }
    }
    if (segs.length > 1) {
      final found = <BatchOcr>[];
      var broken = false;
      for (final sg in segs) {
        final ls = lines
            .where((l) => l.boundingBox.center.dx >= sg[0] && l.boundingBox.center.dx <= sg[1])
            .toList();
        if (ls.length < 6) continue;
        for (final x in parseBatchSheets(toRows(ls))) {
          if (x.count == null || x.total == null) {
            broken = true; // الورقة اتقسمت بالغلط، نعتمد على القراءة الكاملة
          } else {
            found.add(x);
          }
        }
      }
      if (!broken && found.isNotEmpty) {
        final r = sumBatchSheets(found);
        AppLog.i('batch ocr segments: ${r.parts} parts ${r.count} / ${r.total}');
        if (r.parts >= whole.parts) return _attachBatchMeta(r, allRows);
      }
    }
    return _attachBatchMeta(whole, allRows);
  }
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

Future<BatchInfo?> askBatchInfo(BuildContext context, String img, Session s) async {
  final p = await SharedPreferences.getInstance();
  final init = BatchInfo(p.getString('bi_count') ?? '', p.getString('bi_pi') ?? '',
      p.getString('bi_col') ?? '', p.getString('bi_total') ?? '');
  if (!context.mounted) return null;
  final r = await Navigator.of(context).push<BatchInfo>(
    MaterialPageRoute(
      builder: (c) => Directionality(
          textDirection: TextDirection.rtl, child: _BatchInfoSheet(init: init, img: img, session: s)),
    ),
  );
  if (r != null) await rememberBatchInfo(r);
  return r;
}

Future<void> rememberBatchInfo(BatchInfo r) async {
  final p = await SharedPreferences.getInstance();
  await p.setString('bi_count', r.count);
  await p.setString('bi_pi', r.piasters);
  await p.setString('bi_col', r.collected);
  await p.setString('bi_total', r.total);
}

/// صورة بتتكبّر وتتصغّر بإصبعين، ونقرتين بتكبّر عند مكان النقر (ونقرتين تاني بترجّع).
class _ZoomImage extends StatefulWidget {
  final String path;
  const _ZoomImage({required this.path});
  @override
  State<_ZoomImage> createState() => _ZoomImageState();
}

class _ZoomImageState extends State<_ZoomImage> {
  final _tc = TransformationController();
  Offset _tap = Offset.zero;
  static const _zoom = 2.5;

  @override
  void dispose() {
    _tc.dispose();
    super.dispose();
  }

  void _toggle(Size size) {
    if (_tc.value.getMaxScaleOnAxis() > 1.05) {
      _tc.value = Matrix4.identity();
    } else {
      final tx = (-_tap.dx * (_zoom - 1)).clamp(-size.width * (_zoom - 1), 0.0).toDouble();
      final ty = (-_tap.dy * (_zoom - 1)).clamp(-size.height * (_zoom - 1), 0.0).toDouble();
      _tc.value = Matrix4(_zoom, 0, 0, 0, 0, _zoom, 0, 0, 0, 0, 1, 0, tx, ty, 0, 1);
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (ctx, cons) {
        final size = Size(cons.maxWidth, cons.maxHeight);
        return Container(
          color: Colors.black,
          child: Stack(fit: StackFit.expand, children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onDoubleTapDown: (d) => _tap = d.localPosition,
              onDoubleTap: () => _toggle(size),
              child: InteractiveViewer(
                transformationController: _tc,
                minScale: 1,
                maxScale: 8,
                child: Center(
                  child: Image.file(
                    File(widget.path),
                    fit: BoxFit.contain,
                    cacheWidth: 2200,
                    filterQuality: FilterQuality.medium,
                    errorBuilder: (_, __, ___) =>
                        const Center(child: Text('تعذر عرض الصورة', style: TextStyle(color: Colors.white))),
                  ),
                ),
              ),
            ),
            const Positioned(
              left: 0,
              right: 0,
              bottom: 4,
              child: IgnorePointer(
                child: Text('إصبعين للتكبير والتصغير - نقرتين للتقريب',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white54, fontSize: 11)),
              ),
            ),
          ]),
        );
      });
}

class _BatchInfoSheet extends StatefulWidget {
  final BatchInfo init;
  final String img;
  final Session session;
  const _BatchInfoSheet({required this.init, required this.img, required this.session});
  @override
  State<_BatchInfoSheet> createState() => _BatchInfoSheetState();
}

class _BatchInfoSheetState extends State<_BatchInfoSheet> {
  late final c1 = TextEditingController(); // New photo: never prefill an old count.
  late final c2 =
      TextEditingController(text: widget.init.piasters.isEmpty ? '0' : widget.init.piasters);
  late final c3 =
      TextEditingController(text: widget.init.collected.isEmpty ? '0' : widget.init.collected);
  late final c4 = TextEditingController(); // New photo: never prefill an old total.
  String? err;
  bool reading = true, d1 = false, d4 = false;
  String? note;
  List<String> alerts = const [];
  String? sysImg; // صورة السيستم المرفقة بالباتش (إجباري قبل الإرسال)
  bool sysBusy = false;
  String? sysWarn; // تنبيه بس: الترمنل في صورة السيستم مختلف عن الوحدة المختارة (مبيمنعش الإرسال)

  @override
  void initState() {
    super.initState();
    _ocr();
    Store.systemPhoto().then((s) {
      if (mounted && s != null) {
        setState(() => sysImg = s);
        _checkSysTid(s);
      }
    });
  }

  /// تصوير أو اختيار صورة السيستم: بتتحفظ زي ما هي من غير فلاتر ولا دمج.
  /// الضغطة التانية على نفس الزرار بتبدّل الصورة (إعادة التصوير).
  Future<void> _pickSystem(ImageSource src) async {
    if (sysBusy) return;
    setState(() => sysBusy = true);
    try {
      final x = await ImagePicker().pickImage(source: src); // الأصل زي ما اتصور
      if (x == null || !mounted) return;
      final dest =
          '${(await Store.dir()).path}/system_${DateTime.now().microsecondsSinceEpoch}.jpg';
      await File(x.path).copy(dest);
      await Store.setSystemPhoto(dest);
      if (mounted) {
        setState(() {
          sysImg = dest;
          sysWarn = null;
        });
        _checkSysTid(dest); // في الخلفية: مبيأخرش التصوير
      }
    } catch (e) {
      if (mounted) snack(context, 'حصل خطأ: ${errText(e)}');
    } finally {
      if (mounted) setState(() => sysBusy = false);
    }
  }

  /// قراءة رقم الترمنل من صورة السيستم في الخلفية ومقارنته بالوحدة المختارة. تنبيه بس.
  Future<void> _checkSysTid(String path) async {
    try {
      final lines = await _ocrLinesOf(path).timeout(const Duration(seconds: 20));
      final tids = sysPhotoTids(lines.map((l) => l.text).join('\n'));
      if (!mounted || sysImg != path) return;
      final w = sysTidWarning(tids, widget.session.unit, AppData.units);
      AppLog.i('sys tid read=${tids.join(',')} unit=${widget.session.unit.tid} warn=${w != null}');
      if (w != null) HapticFeedback.vibrate();
      setState(() => sysWarn = w);
    } catch (e) {
      AppLog.i('sys tid ocr failed: $e');
    }
  }

  void _previewSystem() {
    final s = sysImg;
    if (s == null) return;
    Navigator.push(context,
        MaterialPageRoute(builder: (_) => ZoomPage(child: Image.file(File(s)))));
  }

  Future<void> _ocr() async {
    BatchOcr? r;
    try {
      r = await readBatchInfo(widget.img).timeout(const Duration(seconds: 25));
    } catch (e) {
      AppLog.i('batch ocr failed: $e');
    }
    if (!mounted) return;
    final ws = r == null ? const <String>[] : batchOcrWarnings(r, widget.session);
    if (ws.isNotEmpty) HapticFeedback.vibrate();
    setState(() {
      reading = false;
      alerts = ws;
      if (!d1) c1.text = r?.count ?? ''; // Failed/ambiguous read must stay empty.
      if (!d4) c4.text = r?.total ?? '';
      if (r?.count == null && r?.total == null) {
        note = 'معرفتش أقرا الأرقام من الصورة، اكتبها بإيدك';
      } else if (r?.count == null || r?.total == null) {
        note = 'اتقرا جزء بس من الصورة، كمّل الباقي وراجع القيم';
      } else if ((r?.missing ?? 0) > 0) {
        note = 'في ورقة باتش مش واضحة في الصورة، الإجمالي والعدد ممكن يكونوا ناقصين. راجعهم من الصورة';
      } else if ((r?.parts ?? 1) > 1) {
        note = 'اتقرا ${r!.parts} أوراق باتش في الصورة واتجمعوا (${r!.detail}). راجع القيم قبل الإرسال';
      } else {
        note = 'اتقرا من الصورة، راجع القيم قبل الإرسال';
      }
    });
  }

  @override
  void dispose() {
    c1.dispose();
    c2.dispose();
    c3.dispose();
    c4.dispose();
    super.dispose();
  }

  Future<void> _ok() async {
    if (sysImg == null) {
      return setState(() => err = 'صوّر أو اختار صورة السيستم الأول');
    }
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
    if (alerts.isNotEmpty) {
      final go = await confirmWarnings(context, alerts, title: 'تنبيه في ورقة الباتش', go: 'متابعة برضه');
      if (!go || !mounted) return;
    }
    Navigator.pop(
        context,
        BatchInfo('${int.parse(count)}', pi.isEmpty ? '0' : '${int.parse(pi)}',
            col.isEmpty ? '0' : '${int.parse(col)}', t.toStringAsFixed(2)));
  }

  Widget _f(TextEditingController c, String label,
          {bool dec = false, bool selectAll = false, VoidCallback? onEdit}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          controller: c,
          onChanged: onEdit == null ? null : (_) => onEdit(),
          // الخانة اللي قيمتها 0 تتحدد كلها أول ما تدوس عليها، فأي رقم بتكتبه يحل محل الصفر
          onTap: selectAll
              ? () => c.selection = TextSelection(baseOffset: 0, extentOffset: c.text.length)
              : null,
          keyboardType: TextInputType.numberWithOptions(decimal: dec),
          decoration: InputDecoration(labelText: label, border: kFieldBorder),
        ),
      );

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('بيانات الباتش')),
        body: LayoutBuilder(builder: (ctx, cons) {
          // الصورة فوق (قابلة للتكبير) والخانات تحتها ظاهرة طول الوقت
          return Column(children: [
            Expanded(child: _ZoomImage(path: widget.img)),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: cons.maxHeight * 0.6),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
                child: SafeArea(
                  top: false,
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    if (reading)
                      const Padding(
                        padding: EdgeInsets.only(bottom: 10),
                        child: Row(children: [
                          SizedBox(
                              width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                          SizedBox(width: 10),
                          Expanded(child: Text('جاري قراءة الأرقام من صورة الباتش...')),
                        ]),
                      )
                    else if (note != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(note!, style: const TextStyle(color: Colors.grey, fontSize: 13)),
                      ),
                    if (alerts.isNotEmpty)
                      Container(
                        width: double.infinity,
                        margin: const EdgeInsets.only(bottom: 10),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.red.withAlpha(28),
                          border: Border.all(color: Colors.redAccent.withAlpha(170)),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            for (final a in alerts)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 4),
                                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  const Icon(Icons.warning_amber_rounded, color: Colors.redAccent, size: 17),
                                  const SizedBox(width: 6),
                                  Expanded(child: Text(a, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600))),
                                ]),
                              ),
                          ],
                        ),
                      ),
                    Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Expanded(child: _f(c1, 'عدد المعاملات', onEdit: () => d1 = true)),
                      const SizedBox(width: 10),
                      Expanded(child: _f(c4, 'الإجمالي', dec: true, onEdit: () => d4 = true)),
                    ]),
                    Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Expanded(child: _f(c2, 'القروش الفاصلة', selectAll: true)),
                      const SizedBox(width: 10),
                      Expanded(child: _f(c3, 'المعاملات المجمعة', selectAll: true)),
                    ]),
                    Row(children: [
                      Expanded(
                          child: OutlinedButton.icon(
                        onPressed: sysBusy ? null : () => _pickSystem(ImageSource.camera),
                        icon: const Icon(Icons.add_a_photo_rounded, size: 18),
                        label: const Text('صوّر السيستم',
                            style: TextStyle(fontSize: 12.5)),
                      )),
                      const SizedBox(width: 8),
                      Expanded(
                          child: OutlinedButton.icon(
                        onPressed: sysBusy ? null : () => _pickSystem(ImageSource.gallery),
                        icon: const Icon(Icons.photo_library_rounded, size: 18),
                        label: const Text('معرض'),
                      )),
                      const SizedBox(width: 8),
                      Expanded(
                          child: OutlinedButton.icon(
                        onPressed: sysImg == null || sysBusy ? null : _previewSystem,
                        icon: const Icon(Icons.visibility_rounded, size: 18),
                        label: Text(sysImg == null ? 'معاينة' : '✓ معاينة'),
                      )),
                    ]),
                    if (sysWarn != null)
                      Container(
                        width: double.infinity,
                        margin: const EdgeInsets.only(top: 8),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.orange.withAlpha(30),
                          border: Border.all(color: Colors.orange.withAlpha(190)),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          const Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 18),
                          const SizedBox(width: 6),
                          Expanded(
                              child: Text(sysWarn!,
                                  style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600))),
                        ]),
                      ),
                    const SizedBox(height: 10),
                    if (err != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(err!, style: const TextStyle(color: Colors.red)),
                      ),
                    SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: FilledButton(
                          onPressed: sysImg == null ? null : _ok,
                          child: const Text('متابعة للإرسال')),
                    ),
                  ]),
                ),
              ),
            ),
          ]);
        }),
      );
}

// =====================================================================
//  تنبيه قبل الإرسال
// =====================================================================

/// بيعرض دايلوج تحميل أثناء تنفيذ [job] وبيقفله لما يخلص.
Future<T> _runWithProgress<T>(BuildContext context, String text, Future<T> Function() job) async {
  final nav = Navigator.of(context, rootNavigator: true);
  unawaited(showDialog<void>(
    context: context,
    barrierDismissible: false,
    useRootNavigator: true,
    builder: (_) => Directionality(
      textDirection: TextDirection.rtl,
      child: PopScope(
        canPop: false,
        child: AlertDialog(
          content: Row(children: [
            const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5)),
            const SizedBox(width: 16),
            Expanded(child: Text(text)),
          ]),
        ),
      ),
    ),
  ));
  try {
    return await job();
  } finally {
    nav.pop();
  }
}

/// لو فيه تحذيرات يعرضها ويسأل: نكمل ولا نرجع. من غير تحذيرات بيكمّل علطول.
/// الخروج بالضغط بره الدايلوج = رجوع (آمن).
Future<bool> confirmWarnings(BuildContext context, List<String> warnings,
    {String title = 'راجع قبل الإرسال', String go = 'ابعت برضه'}) async {
  if (warnings.isEmpty) return true;
  final r = await showDialog<bool>(
    context: context,
    builder: (c) => Directionality(
      textDirection: TextDirection.rtl,
      child: AlertDialog(
        title: Row(children: [
          const Icon(Icons.warning_amber_rounded, color: Colors.orange),
          const SizedBox(width: 8),
          Expanded(child: Text(title)),
        ]),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final w in warnings)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 2),
                    child: Icon(Icons.circle, size: 8, color: Colors.orange),
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: Text(w)),
                ]),
              ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('رجوع')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(go)),
        ],
      ),
    ),
  );
  return r ?? false;
}

/// فحص الباتش قبل الإرسال. بيرجّع true لو نكمل.
Future<bool> preSendCheckBatch(BuildContext context, Session s, String img) async {
  if (!File(img).existsSync()) {
    snack(context, 'صورة الباتش مش موجودة');
    return false;
  }
  final w = <String>[];
  try {
    final q = await _runWithProgress<String?>(context, 'بنراجع صورة الباتش...', () => qualityWarning(img));
    if (q != null) w.add('صورة الباتش: $q');
    if (await Store.noTag(img)) w.add('ورقة البيانات (الاسم والوحدة) مخفية في صورة الباتش');
    if (await Store.flag('batch')) {
      w.add('الباتش اتبعت النهارده قبل كده. لو بتبعت نسخة معدّلة تمام، غير كده اتأكد إنه مش مكرر');
    }
  } catch (e, st) {
    AppLog.e('preSendCheckBatch', e, st);
  }
  if (!context.mounted) return false;
  return confirmWarnings(context, w);
}

/// فحص إيصالات الدفع قبل الإرسال. بيرجّع true لو نكمل.
Future<bool> preSendCheckReceipts(BuildContext context, Session s, List<String> imgs) async {
  final w = <String>[];
  try {
    final blur = <String, List<int>>{};
    final hidden = <int>[];
    await _runWithProgress<void>(context, 'بنراجع الإيصالات...', () async {
      for (var i = 0; i < imgs.length; i++) {
        final q = await qualityWarning(imgs[i]);
        if (q != null) blur.putIfAbsent(q, () => []).add(i + 1);
        if (await Store.noTag(imgs[i])) hidden.add(i + 1);
        await Future<void>.delayed(Duration.zero); // عشان الدايلوج يفضل بيتحرك
      }
    });
    blur.forEach((msg, nums) => w.add('إيصال رقم ${nums.join('، ')}: $msg'));
    if (hidden.isNotEmpty) {
      w.add('إيصال رقم ${hidden.join('، ')}: من غير ورقة البيانات (الاسم والوحدة)');
    }
    if (await Store.flag('receipts')) {
      w.add('إيصالات الدفع اتبعتت النهارده قبل كده. لو بتبعت نسخة معدّلة تمام، غير كده اتأكد إنها مش مكررة');
    }
  } catch (e, st) {
    AppLog.e('preSendCheckReceipts', e, st);
  }
  if (!context.mounted) return false;
  return confirmWarnings(context, w);
}

Future<bool> sendBatchFile(BuildContext context, Session s, String img, {BatchInfo? info}) async {
  if (info != null) {
    await rememberBatchInfo(info);
  } else {
    info = await askBatchInfo(context, img, s);
  }
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
  final sys = await Store.systemPhoto();
  // نسخ مضبوطة لواتساب: الباتش بتحسين مستند، وصورة السيستم تصغير جيد فقط (زي ما اتصورت) + شريط تحتها
  // بالجودة الكاملة من غير تصغير؛ لو التجهيز فشل مبنبعتش حاجة تانية بدالها، والملفات المحفوظة زي ما هي
  final String outShare;
  final String? sysShare;
  try {
    outShare = await waShareCopy(out.path, enhance: true, fullRes: true);
    // صورة السيستم + شريط A2R SYS تحتها (الترمنل وكود الوحدة) علشان POS2 يعرف الماكينة صح
    sysShare = sys == null ? null : await sysShareCopy(sys, s);
  } catch (e) {
    if (context.mounted) {
      snack(context, 'ما اتبعتش حاجة: تجهيز الصورة بالجودة الكاملة فشل (${errText(e)}). الملفات المحفوظة زي ما هي');
    }
    return false;
  }
  final ok = await shareFiles(context, [outShare, if (sysShare != null) sysShare],
      text: caption);
  if (ok) {
    await Store.afterBatchSent();
    await Store.addLog(s, 'batch', 'عدد المعاملات ${info.count} - الإجمالي ${info.total}');
  }
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
  final double zoom;
  const TaggedImage(
      {super.key,
      required this.path,
      required this.tag,
      required this.pos,
      this.aspect,
      this.onChanged,
      this.showTag = true,
      this.zoom = 1});

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
            zoom: zoom,
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
  final double zoom; // تكبير العرض (محفوظ للتوافق: فلتر الحركة بيتحول لإحداثيات الورقة تلقائياً)
  final ValueChanged<TagPos> onChanged;
  final Widget child;
  const _TagDrag(
      {required this.pos,
      required this.cw,
      required this.maxCy,
      required this.onChanged,
      required this.child,
      this.zoom = 1});
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
          final s = (startS * d.scale).clamp(kTagMinScale, 1.0).toDouble();
          final cx = (p.cx + d.focalPointDelta.dx / widget.cw).clamp(0.0, 1.0).toDouble();
          final cy =
              (p.cy + d.focalPointDelta.dy / widget.cw).clamp(0.0, widget.maxCy).toDouble();
          widget.onChanged(TagPos(cx, cy, s));
        },
        child: widget.child,
      );
}

/// شاشة استخراج النص: تقرأ نص الصورة بالـ OCR (أول مرة بس، بعدين من الكاش) وتعرضه للنسخ أو المشاركة.
Future<void> showOcrTextSheet(BuildContext context, String path,
    {String title = 'النص المستخرج'}) async {
  var text = await Store.ocrText(path);
  if (text == null && context.mounted) {
    text = await _runWithProgress(context, 'بنقرأ النص من الصورة…', () async {
      final t = (await readAllTextRows(path)).join('\n');
      await Store.setOcrText(path, t);
      return t;
    });
  }
  if (!context.mounted || text == null) return;
  final display = text.trim().isEmpty ? 'مفيش نص مقروء في الصورة دي' : text;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Flexible(
            child: SingleChildScrollView(
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(ctx).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: SelectableText(display, textDirection: TextDirection.ltr),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: FilledButton.tonalIcon(
                icon: const Icon(Icons.copy_rounded),
                label: const Text('نسخ'),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: text!));
                  if (ctx.mounted) Navigator.pop(ctx);
                  if (context.mounted) snack(context, 'النص اتنسخ');
                },
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.share_rounded),
                label: const Text('مشاركة'),
                onPressed: () => Share.share(text!),
              ),
            ),
          ]),
        ]),
      ),
    ),
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

/// الألوان المتاحة. الشعار أبيض فمحتاج خلفية غامقة (dark) في كل لون.
enum AppPalette { gold, silver, blue }

class Pal {
  final String name;
  final Color seed, accent, dark, mid, bg, onAccent;
  const Pal(this.name, this.seed, this.accent, this.dark, this.mid, this.bg, this.onAccent);
}

const kPalettes = <AppPalette, Pal>{
  AppPalette.gold: Pal('ذهبي', Color(0xFFC9A227), Color(0xFFE3B94A), Color(0xFF15120B),
      Color(0xFF4A3A12), Color(0xFF0D0C09), Color(0xFF15120B)),
  AppPalette.silver: Pal('فضي', Color(0xFF8E9AA8), Color(0xFFD3DAE3), Color(0xFF14171C),
      Color(0xFF3C444F), Color(0xFF0C0D10), Color(0xFF14171C)),
  AppPalette.blue: Pal('أزرق', Color(0xFF0B5FA5), Color(0xFF1EC8A5), Color(0xFF0E131A),
      Color(0xFF0B5FA5), Color(0xFF0A0E13), Colors.white),
};

/// اللون الحالي (الافتراضي ذهبي).
final ValueNotifier<AppPalette> appPalette = ValueNotifier(AppPalette.gold);
Pal get pal => kPalettes[appPalette.value]!;
Color get kAccent => pal.accent;
Color get kBrandDark => pal.dark;

const kFieldBorder = OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(14)));
const kCardShape = RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(18)));

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
    appThemeMode.value = _themeOf(await Store.themeSetting());
    appPalette.value = AppPalette.values[await Store.paletteSetting()];
    autoCropMode = await Store.autoCropSetting();
  } catch (_) {}
  try {
    final sp = await SharedPreferences.getInstance();
    if (sp.getBool('apply_guard') == true) {
      await sp.setBool('apply_safe', true);
      await sp.setBool('apply_guard', false);
      AppLog.i('التطبيق اتقفل أثناء حفظ التعديل، اتفعّل الوضع الآمن مؤقتاً');
    } else if (sp.getBool('apply_safe') == true) {
      // نفك الوضع الآمن القديم عشان ميفضلش مقلل الجودة للأبد
      await sp.setBool('apply_safe', false);
    }
    if (sp.getBool('det_guard') == true) {
      await sp.setBool('det_off', true);
      await sp.setBool('det_guard', false);
      AppLog.i('الكشف الأصلي قفل التطبيق المرة اللي فاتت، اتوقف واتحوّل للكشف البسيط');
    }
    gResLevel = (sp.getInt('resLevel') ?? 0).clamp(0, kResLevels.length);
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

ThemeData _theme(Brightness b) {
  final p = pal;
  final dark = b == Brightness.dark;
  final cs = ColorScheme.fromSeed(seedColor: p.seed, brightness: b);
  RoundedRectangleBorder rr(double r) =>
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(r));
  return ThemeData(
    useMaterial3: true,
    colorScheme: cs,
    scaffoldBackgroundColor: dark ? p.bg : null,
    appBarTheme: AppBarTheme(
      backgroundColor: p.dark,
      foregroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      centerTitle: true,
      elevation: 0,
      iconTheme: IconThemeData(color: p.accent),
      actionsIconTheme: IconThemeData(color: p.accent),
      titleTextStyle:
          const TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.bold),
      systemOverlayStyle: SystemUiOverlayStyle.light,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 48),
        shape: rr(14),
        textStyle: const TextStyle(fontWeight: FontWeight.bold),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 46),
        shape: rr(14),
        side: BorderSide(color: dark ? p.accent.withAlpha(120) : cs.outline),
      ),
    ),
    chipTheme: const ChipThemeData(shape: StadiumBorder()),
    snackBarTheme: SnackBarThemeData(behavior: SnackBarBehavior.floating, shape: rr(14)),
    bottomSheetTheme: const BottomSheetThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(26))),
    ),
    dividerTheme: DividerThemeData(color: cs.outlineVariant),
  );
}

/// المظهر: الافتراضي داكن. الإعدادات: 0 داكن، 1 زي النظام، 2 فاتح.
final ValueNotifier<ThemeMode> appThemeMode = ValueNotifier(ThemeMode.dark);

ThemeMode _themeOf(int i) =>
    i == 1 ? ThemeMode.system : (i == 2 ? ThemeMode.light : ThemeMode.dark);

class A2RApp extends StatelessWidget {
  final String? resumeTarget;
  const A2RApp({super.key, this.resumeTarget});
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: Listenable.merge([appThemeMode, appPalette]),
        builder: (_, __) => MaterialApp(
          title: 'A2R',
          debugShowCheckedModeBanner: false,
          theme: _theme(Brightness.light),
          darkTheme: _theme(Brightness.dark),
          themeMode: appThemeMode.value,
          // اللغة حسب لغة التليفون: عربي لو التليفون عربي، وغير كده إنجليزي (واتجاه الشاشة بيتبع اللغة)
          supportedLocales: const [Locale('ar'), Locale('en')],
          localeResolutionCallback: (l, supported) =>
              (l != null && l.languageCode == 'ar') ? const Locale('ar') : const Locale('en'),
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: LoginScreen(resumeTarget: resumeTarget),
        ),
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
                      border: Border.all(color: kAccent.withAlpha(120), width: 1.5),
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
                        prefixIcon: Icon(Icons.person_rounded), border: kFieldBorder),
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
                        prefixIcon: Icon(Icons.location_on_rounded), border: kFieldBorder),
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
                          prefixIcon: Icon(Icons.apartment_rounded), border: kFieldBorder),
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
//  شاشة الإعدادات
// =====================================================================

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  PerfMode mode = PerfMode.balanced;
  int qual = 1, theme = 0, crop = 0, engine = 1, receiptEngine = 2, res = 0;
  bool trim = false, slow = false;
  String cameraDiagnostic = 'لم تُفتح كاميرا A2R بعد';
  String scannerDiagnostic = 'لم يُجرّب ماسح جوجل بعد';
  AppPalette palSel = AppPalette.gold;
  bool loaded = false;

  static const _perfOpts = <(PerfMode, String, String)>[
    (PerfMode.lite, 'اقتصادي (Lite)', 'دقة أقل وبدون كشف حي، للتليفونات القديمة'),
    (PerfMode.balanced, 'متوازن (Balanced)', 'الوضع الافتراضي'),
    (PerfMode.pro, 'احترافي (Pro)', 'أعلى جودة، للتليفونات القوية بس'),
  ];

  // Presets affect processing/JPEG settings, never disable receipt protection.
  static const _presets = <(PerfMode, int)>[
    (PerfMode.lite, 0), (PerfMode.balanced, 1), (PerfMode.pro, 2),
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final m = await Store.perfMode();
    final en = await Store.scanEngine();
    final re = await Store.scanEngineReceipts();
    final q = await Store.qualitySetting();
    final rs = await Store.resSetting();
    final tr = await Store.trimMargins();
    final th = await Store.themeSetting();
    final pl = await Store.paletteSetting();
    final cr = await Store.autoCropSetting();
    var sl = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      sl = prefs.getBool('camSlow') ?? false;
      cameraDiagnostic = prefs.getString('lastCameraDiagnostic') ?? cameraDiagnostic;
      scannerDiagnostic = prefs.getString('lastScannerDiagnostic') ?? scannerDiagnostic;
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      mode = m;
      engine = en;
      receiptEngine = re;
      qual = q;
      res = rs;
      trim = tr;
      theme = th;
      palSel = AppPalette.values[pl];
      crop = cr;
      slow = sl;
      loaded = true;
    });
  }

  /// 0 خفيف جداً، 1 متوازن، 2 أعلى جودة، -1 مخصص
  int get _preset {
    for (var i = 0; i < _presets.length; i++) {
      final p = _presets[i];
      if (mode == p.$1 && qual == p.$2 && res == 0) return i;
    }
    return -1;
  }

  Future<void> _setPreset(int i) async {
    final p = _presets[i];
    setState(() {mode = p.$1; qual = p.$2; res = 0; slow = false;});
    await Store.setPerfMode(p.$1);
    await Store.setQualitySetting(p.$2);
    await Store.setResSetting(0);
    await (await SharedPreferences.getInstance()).remove('camSlow');
    if (i == 0 && mounted) snack(context, 'وضع خفيف للمعاينة والمعالجة. جودة الإيصالات المحمية محفوظة');
  }

  Future<void> _setMode(PerfMode v) async {
    setState(() => mode = v);
    await Store.setPerfMode(v);
  }

  Future<void> _setEngine(int v) async {
    setState(() => engine = v);
    await Store.setScanEngine(v);
  }

  Future<void> _setReceiptEngine(int v) async {
    setState(() => receiptEngine = v);
    await Store.setScanEngineReceipts(v);
  }

  Future<void> _setQual(int v) async {
    setState(() => qual = v);
    await Store.setQualitySetting(v);
  }

  Future<void> _setRes(int v) async {
    setState(() {res = v; slow = false;});
    await Store.setResSetting(v);
    try {
      (await SharedPreferences.getInstance()).remove('camSlow'); // اختيار الموظف بيلغي التنزيل التلقائي
    } catch (_) {}
  }

  Future<void> _setTheme(int v) async {
    setState(() => theme = v);
    await Store.setThemeSetting(v);
    appThemeMode.value = _themeOf(v);
  }

  Future<void> _setCrop(int v) async {
    setState(() => crop = v);
    autoCropMode = v;
    await Store.setAutoCropSetting(v);
  }

  Future<void> _setPalette(AppPalette v) async {
    setState(() => palSel = v);
    await Store.setPaletteSetting(v.index);
    appPalette.value = v;
  }

  Future<void> _reset() async {
    if (!await askYesNo(context, 'إعادة الضبط؟', 'إعدادات الصفحة دي والفلتر الافتراضي هترجع للافتراضي. الصور والمسودات والحساب وسجل الإرسال مش هيتمسحوا.',
        yes: 'إعادة ضبط', no: 'إلغاء')) {
      return;
    }
    await _setPreset(1);
    setState(() => trim = false);
    await Store.setTrimMargins(false);
    await _setEngine(1);
    await _setReceiptEngine(2);
    await Store.setFilter(ScanFilter.adaptive);
    await (await SharedPreferences.getInstance()).setBool('adaptiveFilterV1', true);
    await Store.setAutoEdit(false);
    await Store.setPdfSize(0);
    await _setTheme(0);
    await _setPalette(AppPalette.gold);
    await _setCrop(0);
    if (mounted) snack(context, 'اتعمل إعادة ضبط');
  }

  // ---------- عناصر ----------

  Widget _sec(String t, {String? sub}) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 22, 4, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t, style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: kAccent)),
          if (sub != null)
            Text(sub, style: const TextStyle(fontSize: 12, color: Colors.grey)),
        ]),
      );

  /// أيقونة التليفون الضعيف: تليفون وفوقه ورقة شجر (خفيف).
  Widget _weakIcon() => SizedBox(
        width: 32,
        height: 32,
        child: Stack(clipBehavior: Clip.none, children: [
          Center(child: Icon(Icons.phone_android_rounded, size: 30, color: kAccent)),
          Positioned(right: -3, bottom: -3, child: Icon(Icons.eco_rounded, size: 16, color: kAccent)),
        ]),
      );

  Widget _presetCard(
      {required Widget icon,
      required String title,
      required String sub,
      required bool on,
      required VoidCallback onTap}) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: on ? kAccent.withAlpha(28) : cs.surfaceContainerHigh,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: on ? kAccent : cs.outlineVariant, width: on ? 1.6 : 1),
        ),
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(children: [
              Container(
                width: 52,
                height: 52,
                alignment: Alignment.center,
                decoration: BoxDecoration(shape: BoxShape.circle, color: kAccent.withAlpha(30)),
                child: icon,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 2),
                  Text(sub, style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
                ]),
              ),
              if (on) Icon(Icons.check_circle_rounded, color: kAccent),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _paletteRow() {
    final cs = Theme.of(context).colorScheme;
    return Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
      for (final pp in AppPalette.values)
        InkResponse(
          onTap: () => _setPalette(pp),
          radius: 40,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 50,
              height: 50,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: kPalettes[pp]!.accent,
                border: Border.all(color: pp == palSel ? cs.onSurface : Colors.transparent, width: 3),
              ),
              child: pp == palSel ? Icon(Icons.check_rounded, color: kPalettes[pp]!.onAccent) : null,
            ),
            const SizedBox(height: 6),
            Text(kPalettes[pp]!.name, style: const TextStyle(fontSize: 12)),
          ]),
        ),
    ]);
  }

  Widget _radioGroup<T>(List<(T, String, String)> opts, T cur, ValueChanged<T> on) => Column(children: [
        for (final o in opts)
          RadioListTile<T>(
            dense: true,
            title: Text(o.$2),
            subtitle: Text(o.$3),
            value: o.$1,
            groupValue: cur,
            onChanged: (v) => on(v as T),
          ),
      ]);

  Widget _sub(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 2),
        child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: Text(t, style: const TextStyle(fontWeight: FontWeight.bold))),
      );

  @override
  Widget build(BuildContext context) {
    final cur = _preset;
    return Scaffold(
      appBar: AppBar(title: const Text('الإعدادات')),
      body: !loaded
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              child: ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 24), children: [
                if (slow && cur != 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Card(
                      shape: kCardShape,
                      color: Colors.orange.withAlpha(30),
                      child: ListTile(
                        leading: const Icon(Icons.hourglass_bottom_rounded, color: Colors.orange),
                        title: const Text('الكاميرا بطيئة على تليفونك؟'),
                        subtitle: const Text('جرّب وضع التليفون الضعيف تحت'),
                      ),
                    ),
                  ),
                _sec('نمط الاستخدام', sub: 'للمعاينة والصور العادية. الإيصالات تحتفظ بجودتها المحمية'),
                _presetCard(
                  icon: _weakIcon(),
                  title: 'تليفون ضعيف جداً',
                  sub: 'معاينة أخف وبدون كشف حي. الإيصالات تفضل بجودتها المحمية',
                  on: cur == 0,
                  onTap: () => _setPreset(0),
                ),
                _presetCard(
                  icon: Icon(Icons.balance_rounded, size: 28, color: kAccent),
                  title: 'متوازن',
                  sub: 'الافتراضي: أداء كويس وجودة مناسبة',
                  on: cur == 1,
                  onTap: () => _setPreset(1),
                ),
                _presetCard(
                  icon: Icon(Icons.diamond_rounded, size: 28, color: kAccent),
                  title: 'أعلى جودة',
                  sub: 'أوضح صورة وأكبر حجم، للتليفونات القوية',
                  on: cur == 2,
                  onTap: () => _setPreset(2),
                ),
                if (cur == -1)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 4),
                    child: Text('إعداداتك الحالية مخصصة (من قسم متقدم)',
                        style: TextStyle(fontSize: 12, color: Colors.grey)),
                  ),
                _sec('المظهر'),
                SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<int>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(
                          value: 0, label: Text('داكن'), icon: Icon(Icons.dark_mode_rounded)),
                      ButtonSegment(
                          value: 1, label: Text('النظام'), icon: Icon(Icons.brightness_auto_rounded)),
                      ButtonSegment(
                          value: 2, label: Text('فاتح'), icon: Icon(Icons.light_mode_rounded)),
                    ],
                    selected: {theme},
                    onSelectionChanged: (v) => _setTheme(v.first),
                  ),
                ),
                const SizedBox(height: 16),
                _paletteRow(),
                _sec('التصوير'),
                Card(
                  shape: kCardShape,
                  child: Column(children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        const Text('القص التلقائي', style: TextStyle(fontWeight: FontWeight.bold)),
                        const SizedBox(height: 2),
                        Text(
                            crop == 0
                                ? 'يحافظ على منظور الورقة الصحيح. لو الحدود مش مؤكدة يسيب الصورة كاملة للتعديل اليدوي'
                                : (crop == 1
                                    ? 'مستطيل مستقيم دايماً، من غير ميلان'
                                    : 'أربع أركان حرة مع تصحيح المنظور'),
                            style: const TextStyle(fontSize: 12, color: Colors.grey)),
                        const SizedBox(height: 10),
                        SizedBox(
                          width: double.infinity,
                          child: SegmentedButton<int>(
                            showSelectedIcon: false,
                            segments: const [
                              ButtonSegment(value: 0, label: Text('ذكي')),
                              ButtonSegment(value: 1, label: Text('مستطيل')),
                              ButtonSegment(value: 2, label: Text('منظور')),
                            ],
                            selected: {crop},
                            onSelectionChanged: (v) => _setCrop(v.first),
                          ),
                        ),
                      ]),
                    ),
                    SwitchListTile(
                      title: const Text('قص الهوامش البيضاء تلقائياً'),
                      subtitle: const Text('في فلاتر الإيصال: بيشيل البياض الفاضي حوالين الإيصال'),
                      value: trim,
                      onChanged: (v) {
                        setState(() => trim = v);
                        Store.setTrimMargins(v);
                      },
                    ),
                  ]),
                ),
                _sec('متقدم'),
                Card(
                  shape: kCardShape,
                  clipBehavior: Clip.antiAlias,
                  child: ExpansionTile(
                    shape: const Border(),
                    collapsedShape: const Border(),
                    leading: const Icon(Icons.tune_rounded),
                    title: const Text('إعدادات متقدمة'),
                    subtitle: const Text('الأداء وكاميرا الباتش والإيصالات وجودة الصور العادية'),
                    children: [
                      _sub('الأداء'),
                      _radioGroup<PerfMode>(_perfOpts, mode, _setMode),
                      const Divider(),
                      _sub('كاميرا الباتش'),
                      const Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: Text('الوضع الاقتصادي يستخدم كاميرا A2R بدل جوجل. لو جوجل فشل، التطبيق يوفّر البديل.', style: TextStyle(fontSize: 12))),
                      _radioGroup<int>(const [
                        (1, 'ماسح جوجل الأساسي', 'قص من جوجل، والتحسين من التطبيق'),
                        (0, 'كاميرا A2R', 'كاميرا التطبيق مع القص والفلاتر'),
                      ], engine == 0 ? 0 : 1, _setEngine),
                      const Divider(),
                      _sub('كاميرا إيصالات الدفع'),
                      _radioGroup<int>(_engineOpts, receiptEngine, _setReceiptEngine),

                      const Divider(),
                      _sub('جودة الصور العادية'),
                      const Padding(padding: EdgeInsets.symmetric(horizontal: 16),
                        child: Text('الإيصالات والصور عالية التفاصيل لها حد جودة محمي. الاختيار المنخفض هنا لا يقلل جودة أصل الإيصال.', style: TextStyle(fontSize: 12))),
                      _radioGroup<int>(_qualOpts, qual, _setQual),
                      const Divider(),
                      _sub('دقة الصورة'),
                      const Padding(
                        padding: EdgeInsets.fromLTRB(16, 0, 16, 4),
                        child: Text(
                            'للصور العادية: كاميرا A2R تطلب الدقة المختارة حسب دعم الجهاز. الإيصالات والجودة الأعلى تستخدم دقتها المحمية. ماسح جوجل يتحكم في دقة الالتقاط بنفسه.',
                            style: TextStyle(fontSize: 12)),
                      ),
                      _radioGroup<int>(_resOpts, res, _setRes),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Card(shape: kCardShape, child: ExpansionTile(
                  leading: const Icon(Icons.info_outline_rounded),
                  title: const Text('معلومات الجهاز والتصوير'),
                  subtitle: const Text('آخر حالة مسجلة، من غير تشغيل الكاميرا أو فحص جديد'),
                  children: [
                    ListTile(title: const Text('النظام كما يبلّغه الجهاز'),
                      subtitle: Text('${Platform.operatingSystem}: ${Platform.operatingSystemVersion}')),
                    ListTile(title: const Text('كاميرا A2R'), subtitle: Text(cameraDiagnostic)),
                    ListTile(title: const Text('ماسح جوجل'), subtitle: Text(scannerDiagnostic)),
                    const Padding(padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
                      child: Text('حالة جوجل دي آخر محاولة، مش ضمان إنه متاح دلوقتي. النسخة الأصغر للـ PDF بتتعمل من شاشة الملف، والأصل بيفضل محفوظ.', style: TextStyle(fontSize: 12))),
                  ],
                )),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: () => AppLog.share(context),
                  icon: const Icon(Icons.bug_report_rounded),
                  label: const Text('إرسال سجل الأخطاء'),
                ),
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: _reset,
                  icon: const Icon(Icons.restart_alt_rounded),
                  label: const Text('إعادة الضبط للافتراضي'),
                ),
                const SizedBox(height: 8),
                Center(
                    child: Text('v$kVersion',
                        style: const TextStyle(fontSize: 11, color: Colors.grey))),
              ]),
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
  List<String> saved = []; // cam: الملفات المحفوظة (اللي اتبدّلت أو اتبعتت) تحت «ملفاتي»
  int scanCount = 0;
  String? batchImg;
  ({File file, DateTime time})? pdf;
  bool batchSent = false;
  bool receiptsSent = false;
  DateTime? batchSentAt; // لو الباتش اتبعت وسايبينه ١٢ ساعة للتعديل
  DateTime? receiptsSentAt; // نفس الكلام للإيصالات
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
    if (state == AppLifecycleState.resumed) unawaited(_onResume());
  }

  Future<void> _onResume() async {
    // التنظيف بعد ١٢ ساعة بس لو الشاشة الرئيسية هي اللي قدام (مش وإحنا في تعديل)
    if (mounted && (ModalRoute.of(context)?.isCurrent ?? false)) {
      try {
        await Store.expireSent();
      } catch (e, st) {
        AppLog.e('expireSent', e, st);
      }
    }
    await _reload();
  }

  /// الوقت المتبقي قبل مسح الملف المتبعت.
  String _leftText(DateTime sent) {
    final left = Store.sentLife - DateTime.now().difference(sent);
    if (left.inMinutes <= 0) return 'أقل من دقيقة';
    final h = left.inHours, m = left.inMinutes % 60;
    if (h == 0) return '$m دقيقة';
    return m == 0 ? '$h ساعة' : '$h ساعة و$m دقيقة';
  }

  Future<void> _init() async {
    await requestAllPermissions();
    try {
      await Store.expireSent(); // مسح اللي عدّى عليه ١٢ ساعة من الإرسال
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
    final bs = await Store.batchSentAt();
    final rs = await Store.receiptsSentAt();
    final sv = await Store.archive();
    sv.sort((a, b) {
      try {
        return File(b).lastModifiedSync().compareTo(File(a).lastModifiedSync());
      } catch (_) {
        return 0;
      }
    });
    final sp = await SharedPreferences.getInstance();
    final sc = (sp.getStringList('scanPages') ?? []).where((e) => File(e).existsSync()).length;
    if (!mounted) return;
    setState(() {
      saved = sv;
      scanCount = sc;
      draft = d;
      pdf = f;
      batchImg = bi;
      batchSent = b;
      receiptsSent = r;
      batchSentAt = bs;
      receiptsSentAt = rs;
    });
  }

  String _savedKind(String path) {
    final n = path.split('/').last;
    if (n.toLowerCase().endsWith('.pdf')) return n.startsWith('sent_') ? 'ملف PDF متبعت' : 'ملف PDF';
    if (n.startsWith('batch')) return 'باتش محفوظ';
    if (n.startsWith('scan')) return 'سكانر محفوظ';
    if (n.startsWith('r_')) return 'إيصال محفوظ';
    return 'صورة محفوظة';
  }

  String _savedDate(String path) {
    try {
      final t = File(path).lastModifiedSync();
      return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
    } catch (_) {
      return '';
    }
  }

  Widget _savedCard(String path) {
    final pdfFile = path.toLowerCase().endsWith('.pdf');
    return Card(
      key: ValueKey('saved:$path'),
      shape: kCardShape,
      child: ListTile(
        leading: pdfFile
            ? const Icon(Icons.picture_as_pdf_rounded, size: 36, color: Colors.red)
            : ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.file(File(path),
                    width: 48, height: 48, fit: BoxFit.cover, cacheWidth: 150),
              ),
        title: Text(_savedKind(path)),
        subtitle: Text(_savedDate(path)),
        onTap: () => pdfFile
            ? OpenFilex.open(path)
            : Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => ZoomPage(child: Image.file(File(path))))),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          IconButton(
              tooltip: 'مشاركة',
              icon: const Icon(Icons.share_rounded),
              onPressed: () => shareFiles(context, [path])),
          IconButton(
              tooltip: 'مسح',
              icon: const Icon(Icons.delete_rounded, color: Colors.red),
              onPressed: () async {
                if (!await askYesNo(context, 'مسح الملف؟', 'هيتمسح نهائياً من التطبيق.',
                    yes: 'امسح', no: 'إلغاء')) {
                  return;
                }
                await Store.unarchive(path);
                if (mounted) _reload();
              }),
        ]),
      ),
    );
  }

  Future<void> _showSettings() async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen()));
    if (mounted) _reload();
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

  /// باتش جديد: لو فيه باتش اتبعت محتفظين بيه، نأكد قبل ما يتبدل.
  Future<void> _newBatch() async {
    if (batchSentAt != null &&
        !await askYesNo(context, 'باتش جديد؟',
            'الباتش اللي اتبعت هيتمسح لما تصوّر باتش جديد. لو عايز تعدّله افتحه من "ملفاتي".',
            yes: 'باتش جديد', no: 'إلغاء')) {
      return;
    }
    if (!mounted) return;
    await _open(BatchScreen(session: widget.session, fresh: true));
  }

  /// إيصالات الدفع: لو فيه إيصالات اتبعتت محتفظين بيها، نسأل: نعدّلها ولا نبدأ جديد.
  Future<void> _openReceipts() async {
    if (receiptsSentAt != null) {
      final c = await showDialog<String>(
        context: context,
        builder: (ctx) => Directionality(
          textDirection: TextDirection.rtl,
          child: AlertDialog(
            title: const Text('إيصالات اتبعتت'),
            content: const Text(
                'عندك إيصالات اتبعتت ومحتفظ بيها للتعديل. تفتحها تعدّل وتبعت تاني، ولا تبدأ إيصالات جديدة؟ (البدء من جديد بينقل اللي اتبعت للأرشيف)'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
              TextButton(onPressed: () => Navigator.pop(ctx, 'new'), child: const Text('ابدأ جديد')),
              FilledButton(
                  onPressed: () => Navigator.pop(ctx, 'edit'), child: const Text('فتح للتعديل')),
            ],
          ),
        ),
      );
      if (c == null || !mounted) return;
      if (c == 'new') {
        await Store.discardSentReceipts();
        await _reload();
      }
    }
    if (!mounted) return;
    await _open(ReceiptsScreen(session: widget.session));
  }

  Future<void> _sendBatch() async {
    final b = batchImg;
    if (b == null) return;
    setState(() => busy = true);
    try {
      if (!await preSendCheckBatch(context, widget.session, b)) return;
      if (!mounted) return;
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
    if (!await preSendCheckReceipts(context, widget.session, used)) return;
    if (!mounted) return;
    if (used.isEmpty) {
      // مفيش صور نعرضها: مشاركة الـ PDF مباشرة زي الأول
      final ok = await shareFiles(context, [f.file.path]);
      if (ok) {
        HapticFeedback.mediumImpact();
        await Store.afterPdfSent();
        await Store.addLog(widget.session, 'receipts', 'PDF');
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

  Widget _big(IconData icon, String label, VoidCallback onTap, {required bool sent, bool compact = false}) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surfaceContainerHigh,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: BorderSide(color: kAccent.withAlpha(110), width: 1.2),
      ),
      child: InkWell(
        onTap: onTap,
        child: compact
            ? Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                child: Row(children: [
                  Container(
                    width: 38, height: 38,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      color: kAccent.withAlpha(32),
                      border: Border.all(color: kAccent.withAlpha(100)),
                    ),
                    child: Icon(icon, size: 22, color: kAccent),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                      child: Semantics(
                    label: '$label: ${sent ? "تم الإرسال" : "لم يُرسل"}',
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                      Text(label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                      Text(sent ? 'تم الإرسال' : 'لم يُرسل',
                          style: TextStyle(
                              fontSize: 10,
                              color: sent ? Colors.green.shade400 : cs.onSurfaceVariant)),
                    ]),
                  )),
                ]),
              )
            : ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 158),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 13),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Semantics(
                label: '$label: ${sent ? "تم الإرسال" : "لم يُرسل"}',
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(sent ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                      color: sent ? Colors.green.shade400 : cs.onSurfaceVariant, size: 16),
                  const SizedBox(width: 4),
                  Flexible(child: Text(sent ? 'تم الإرسال' : 'لم يُرسل',
                      style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant))),
                ]),
              ),
              const SizedBox(height: 10),
              Container(
                width: 52, height: 52,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  color: kAccent.withAlpha(32),
                  border: Border.all(color: kAccent.withAlpha(100)),
                ),
                child: Icon(icon, size: 29, color: kAccent),
              ),
              const SizedBox(height: 10),
              Text(label, textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
            ]),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.session;
    final unitLine = s.building == null ? s.unit.name : '${s.unit.name} - ${s.building}';
    final pf = pdf;
    final bi = batchImg;
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        leadingWidth: 56,
        leading: IconButton(
          tooltip: 'الإعدادات',
          icon: const Icon(Icons.settings_rounded),
          onPressed: _showSettings,
        ),
        title: appLogo(height: 40),
        centerTitle: true,
        toolbarHeight: 68,
        actions: [
          SizedBox(width: 56, child: PopupMenuButton<String>(
            tooltip: 'المزيد',
            icon: const Icon(Icons.more_horiz_rounded),
            onSelected: (value) {
              if (value == 'history') _open(const SendLogScreen());
              if (value == 'account') Navigator.pop(context);
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'history', child: Text('سجل الإرسال')),
              PopupMenuItem(value: 'account', child: Text('تغيير الحساب')),
            ],
          )),
        ],
      ),
      body: LayoutBuilder(builder: (ctx, bc) {
        // شاشة قصيرة: الجزء الثابت بيصغّر (مضغوط) بدل ما كله يتحرك، عشان «ملفاتي» تفضل ظاهرة.
        final compact = bc.maxHeight < 700;
        final top = <Widget>[
        if (busy) const LinearProgressIndicator(),
        Container(
          padding: EdgeInsets.all(compact ? 9 : 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(compact ? 16 : 22),
            gradient: LinearGradient(
              begin: Alignment.topRight,
              end: Alignment.bottomLeft,
              colors: [kBrandDark, pal.mid],
            ),
            border: Border.all(color: kAccent.withAlpha(110), width: 1.2),
          ),
          child: DefaultTextStyle.merge(
            style: const TextStyle(color: Colors.white, fontSize: 16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(Icons.person_rounded, color: kAccent),
                const SizedBox(width: 8),
                Expanded(
                    child: Text(s.name,
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
              ]),
              SizedBox(height: compact ? 2 : 6),
              Row(children: [
                Icon(Icons.location_on_rounded, color: kAccent),
                const SizedBox(width: 8),
                Expanded(child: Text(unitLine)),
              ]),
              SizedBox(height: compact ? 2 : 6),
              Wrap(spacing: 7, runSpacing: 3, crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Icon(Icons.calendar_today_rounded, color: kAccent, size: 18),
                  Text(s.date, textDirection: TextDirection.ltr,
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                  Text('تاريخ التليفون، اتأكد إنه صح',
                    style: TextStyle(fontSize: 10, color: Colors.white.withAlpha(200))),
                ],
              ),
            ]),
          ),
        ),
        SizedBox(height: compact ? 8 : 14),
        IntrinsicHeight(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(
              child: _big(Icons.receipt_long_rounded, 'الباتش',
                  _newBatch, sent: batchSent, compact: compact)),
          const SizedBox(width: 12),
          Expanded(
              child: _big(
                  Icons.payments_rounded, 'إيصالات الدفع', _openReceipts, sent: receiptsSent, compact: compact)),
        ])),
        SizedBox(height: compact ? 8 : 12),
        Card(
          shape: kCardShape,
          child: ListTile(
            dense: compact,
            visualDensity: compact ? VisualDensity.compact : null,
            leading: Icon(Icons.document_scanner_rounded, color: kAccent),
            title: const Text('سكانر', style: TextStyle(fontWeight: FontWeight.bold)),
            subtitle: const Text('مستند أو بطاقة وش وضهر، تصدير PDF أو صور'),
            onTap: () async {
              await _open(const ScannerScreen(autoStart: true));
              if (mounted) _reload();
            },
          ),
        ),
        ];
        final files = <Widget>[
        if (draft.isNotEmpty || pf != null || bi != null || saved.isNotEmpty || scanCount > 0) ...[
          const SizedBox(height: 24),
          const Text('ملفاتي',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          if (bi != null)
            Card(
      shape: kCardShape,
              child: ListTile(
                leading: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.file(File(bi),
                      width: 48, height: 48, fit: BoxFit.cover, cacheWidth: 150),
                ),
                title: Text('الباتش - ${s.batchName}.jpg'),
                subtitle: Text(batchSentAt == null
                    ? 'اضغط للمعاينة'
                    : 'اتبعت ✓ - اضغط للتعديل'),
                onTap: () => _open(BatchScreen(session: s)),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(
                      tooltip: 'إرسال',
                      icon: const Icon(Icons.send_rounded),
                      onPressed: busy ? null : _sendBatch),
                  IconButton(
                      tooltip: 'مسح',
                      icon: const Icon(Icons.delete_rounded, color: Colors.red),
                      onPressed: busy ? null : _trashBatch),
                ]),
              ),
            ),
          if (draft.isNotEmpty)
            Card(
      shape: kCardShape,
              child: ListTile(
                leading: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.file(File(draft.first),
                      width: 48, height: 48, fit: BoxFit.cover, cacheWidth: 150),
                ),
                title: Text('إيصالات الدفع (${draft.length} صورة)'),
                subtitle: Text(receiptsSentAt == null
                    ? 'اضغط للمعاينة أو لتكمل التصوير'
                    : 'اتبعت ✓ - اضغط للتعديل'),
                onTap: _openReceipts,
                trailing: IconButton(
                    tooltip: 'مسح',
                    icon: const Icon(Icons.delete_rounded, color: Colors.red),
                    onPressed: _trashDraft),
              ),
            ),
          if (pf != null)
            Card(
      shape: kCardShape,
              child: ListTile(
                leading: const Icon(Icons.picture_as_pdf_rounded, size: 36, color: Colors.red),
                title: Text(pf.file.path.split('/').last,
                    maxLines: 2, overflow: TextOverflow.ellipsis),
                subtitle: Text(receiptsSentAt != null
                    ? 'اتبعت ✓ - اضغط لفتحه'
                    : 'اضغط لفتحه'),
                onTap: _openPdf,
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(
                      tooltip: 'إرسال', icon: const Icon(Icons.send_rounded), onPressed: _sendPdf),
                  IconButton(
                      tooltip: 'مسح',
                      icon: const Icon(Icons.delete_rounded, color: Colors.red),
                      onPressed: _trashPdf),
                ]),
              ),
            ),
          if (scanCount > 0)
            Card(
              shape: kCardShape,
              child: ListTile(
                leading: Icon(Icons.document_scanner_rounded, size: 36, color: kAccent),
                title: Text('سكانر ($scanCount صفحة)'),
                subtitle: const Text('اضغط للفتح'),
                onTap: () async {
                  await _open(const ScannerScreen());
                  if (mounted) _reload();
                },
              ),
            ),
          for (final sp in saved) _savedCard(sp),
        ],
        const SizedBox(height: 24),
        Center(
            child: Text('v$kVersion',
                style: const TextStyle(fontSize: 11, color: Colors.grey))),
        ];
        // الجزء اللي فوق (لحد السكانر) ثابت و«ملفاتي» بس هي اللي بتتحرك (والجزء الثابت بيتضغط على الشاشات القصيرة).
        return Column(children: [
          Padding(
              padding: EdgeInsets.fromLTRB(14, compact ? 8 : 14, 14, 0),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: top)),
          Expanded(child: ListView(padding: const EdgeInsets.fromLTRB(14, 0, 14, 14), children: files)),
        ]);
      }),
    );
  }
}

// =====================================================================
//  شاشة الباتش
// =====================================================================

/// نموذج بيانات الباتش جوه شاشة الباتش نفسها (بدل شاشة منفصلة). نفس القراءة والتحقق القديمين.
class _BatchInfoPanel extends StatefulWidget {
  final BatchInfo init;
  final String img;
  final Session session;
  final ValueNotifier<bool> sysReady;
  const _BatchInfoPanel(
      {super.key, required this.init, required this.img, required this.session, required this.sysReady});
  @override
  State<_BatchInfoPanel> createState() => _BatchInfoPanelState();
}

final ButtonStyle kSysBtn = OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8));

class _BatchInfoPanelState extends State<_BatchInfoPanel> {
  late final c1 = TextEditingController(); // صورة جديدة: عمرنا ما نملّا عدد قديم
  late final c2 =
      TextEditingController(text: widget.init.piasters.isEmpty ? '0' : widget.init.piasters);
  late final c3 =
      TextEditingController(text: widget.init.collected.isEmpty ? '0' : widget.init.collected);
  late final c4 = TextEditingController(); // صورة جديدة: عمرنا ما نملّا إجمالي قديم
  String? err;
  bool reading = true, d1 = false, d4 = false, alertsOpen = false;
  String? note;
  List<String> alerts = const [];
  String? sysImg;
  bool sysBusy = false;
  String? sysWarn;

  @override
  void initState() {
    super.initState();
    widget.sysReady.value = false;
    _ocr();
    Store.systemPhoto().then((s) {
      if (mounted && s != null) {
        setState(() => sysImg = s);
        widget.sysReady.value = true;
        _checkSysTid(s);
      }
    });
  }

  Future<void> _pickSystem(ImageSource src) async {
    if (sysBusy) return;
    setState(() => sysBusy = true);
    try {
      final x = await ImagePicker().pickImage(source: src); // الأصل زي ما اتصور
      if (x == null || !mounted) return;
      final dest =
          '${(await Store.dir()).path}/system_${DateTime.now().microsecondsSinceEpoch}.jpg';
      await File(x.path).copy(dest);
      await Store.setSystemPhoto(dest);
      if (mounted) {
        setState(() {
          sysImg = dest;
          sysWarn = null;
          err = null;
        });
        widget.sysReady.value = true;
        _checkSysTid(dest);
      }
    } catch (e) {
      if (mounted) snack(context, 'حصل خطأ: ${errText(e)}');
    } finally {
      if (mounted) setState(() => sysBusy = false);
    }
  }

  Future<void> _checkSysTid(String path) async {
    try {
      final lines = await _ocrLinesOf(path).timeout(const Duration(seconds: 20));
      final tids = sysPhotoTids(lines.map((l) => l.text).join('\n'));
      if (!mounted || sysImg != path) return;
      final w = sysTidWarning(tids, widget.session.unit, AppData.units);
      AppLog.i('sys tid read=${tids.join(',')} unit=${widget.session.unit.tid} warn=${w != null}');
      if (w != null) HapticFeedback.vibrate();
      setState(() => sysWarn = w);
    } catch (e) {
      AppLog.i('sys tid ocr failed: $e');
    }
  }

  void _previewSystem() {
    final s = sysImg;
    if (s == null) return;
    Navigator.push(context,
        MaterialPageRoute(builder: (_) => ZoomPage(child: Image.file(File(s)))));
  }

  Future<void> _ocr() async {
    BatchOcr? r;
    try {
      r = await readBatchInfo(widget.img).timeout(const Duration(seconds: 25));
    } catch (e) {
      AppLog.i('batch ocr failed: $e');
    }
    if (!mounted) return;
    final ws = r == null ? const <String>[] : batchOcrWarnings(r, widget.session);
    if (ws.isNotEmpty) HapticFeedback.vibrate();
    setState(() {
      reading = false;
      alerts = ws;
      if (!d1) c1.text = r?.count ?? ''; // قراءة فاشلة/ملتبسة تفضل فاضية
      if (!d4) c4.text = r?.total ?? '';
      if (r?.count == null && r?.total == null) {
        note = 'معرفتش أقرا الأرقام من الصورة، اكتبها بإيدك';
      } else if (r?.count == null || r?.total == null) {
        note = 'اتقرا جزء بس من الصورة، كمّل الباقي وراجع القيم';
      } else if ((r?.missing ?? 0) > 0) {
        note = 'في ورقة باتش مش واضحة في الصورة، الإجمالي والعدد ممكن يكونوا ناقصين. راجعهم من الصورة';
      } else if ((r?.parts ?? 1) > 1) {
        note = 'اتقرا ${r!.parts} أوراق باتش في الصورة واتجمعوا (${r!.detail}). راجع القيم قبل الإرسال';
      } else {
        note = 'اتقرا من الصورة، راجع القيم قبل الإرسال';
      }
    });
  }

  @override
  void dispose() {
    c1.dispose();
    c2.dispose();
    c3.dispose();
    c4.dispose();
    super.dispose();
  }

  /// نفس تحققات الشاشة القديمة بالظبط. بيرجّع null لو في خطأ (والرسالة بتظهر) أو المستخدم ما كملش.
  Future<BatchInfo?> submit() async {
    if (sysImg == null) {
      setState(() => err = 'صوّر أو اختار صورة السيستم الأول');
      return null;
    }
    final count = _digits(c1.text), pi = _digits(c2.text);
    final col = _digits(c3.text), tot = _digits(c4.text);
    bool isInt(String s) => RegExp(r'^\d+$').hasMatch(s);
    String? e;
    if (!isInt(count)) {
      e = 'اكتب عدد المعاملات (أرقام بس)';
    } else if (pi.isNotEmpty && !isInt(pi)) {
      e = 'عدد القروش الفاصلة لازم يكون رقم';
    } else if (col.isNotEmpty && !isInt(col)) {
      e = 'عدد المعاملات المجمعة لازم يكون رقم';
    }
    final t = double.tryParse(tot);
    if (e == null && (t == null || t < 0)) e = 'اكتب الإجمالي صح (مثال 28107.19)';
    if (e != null) {
      setState(() => err = e);
      snack(context, e);
      return null;
    }
    setState(() => err = null);
    if (alerts.isNotEmpty) {
      final go = await confirmWarnings(context, alerts, title: 'تنبيه في ورقة الباتش', go: 'متابعة برضه');
      if (!go || !mounted) return null;
    }
    return BatchInfo('${int.parse(count)}', pi.isEmpty ? '0' : '${int.parse(pi)}',
        col.isEmpty ? '0' : '${int.parse(col)}', t!.toStringAsFixed(2));
  }

  Widget _f(TextEditingController c, String label,
          {bool dec = false, bool selectAll = false, VoidCallback? onEdit}) =>
      Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: TextField(
            controller: c,
            onChanged: onEdit == null ? null : (_) => onEdit(),
            onTap: selectAll
                ? () => c.selection = TextSelection(baseOffset: 0, extentOffset: c.text.length)
                : null,
            keyboardType: TextInputType.numberWithOptions(decimal: dec),
            decoration: InputDecoration(labelText: label, isDense: true, border: kFieldBorder),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (reading)
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Row(children: [
                SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                SizedBox(width: 10),
                Expanded(child: Text('جاري قراءة الأرقام من صورة الباتش...')),
              ]),
            )
          else if (note != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(note!, style: const TextStyle(color: Colors.grey, fontSize: 12.5)),
            ),
          if (alerts.isNotEmpty)
            InkWell(
              onTap: () => setState(() => alertsOpen = !alertsOpen),
              child: Container(
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.red.withAlpha(28),
                  border: Border.all(color: Colors.redAccent.withAlpha(170)),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Icon(Icons.warning_amber_rounded, color: Colors.redAccent, size: 17),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      for (final a in (alertsOpen ? alerts : alerts.take(1)))
                        Padding(
                          padding: const EdgeInsets.only(bottom: 3),
                          child: Text(a,
                              maxLines: alertsOpen ? null : 2,
                              overflow: alertsOpen ? null : TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                        ),
                    ]),
                  ),
                  if (alerts.length > 1) Text(alertsOpen ? '▴' : '${alerts.length} ▾', style: const TextStyle(fontSize: 12)),
                ]),
              ),
            ),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _f(c1, 'عدد المعاملات', onEdit: () => d1 = true),
            _f(c4, 'الإجمالي', dec: true, onEdit: () => d4 = true),
          ]),
          const SizedBox(height: 10),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _f(c2, 'القروش الفاصلة', selectAll: true),
            _f(c3, 'المعاملات المجمعة', selectAll: true),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
                child: OutlinedButton.icon(
              onPressed: sysBusy ? null : () => _pickSystem(ImageSource.camera),
              icon: const Icon(Icons.add_a_photo_rounded, size: 18),
              label: const FittedBox(fit: BoxFit.scaleDown, child: Text('صوّر السيستم', maxLines: 1, style: TextStyle(fontSize: 12.5))),
              style: kSysBtn,
            )),
            const SizedBox(width: 6),
            Expanded(
                child: OutlinedButton.icon(
              onPressed: sysBusy ? null : () => _pickSystem(ImageSource.gallery),
              icon: const Icon(Icons.photo_library_rounded, size: 18),
              label: const FittedBox(fit: BoxFit.scaleDown, child: Text('معرض', maxLines: 1, style: TextStyle(fontSize: 12.5))),
              style: kSysBtn,
            )),
            const SizedBox(width: 6),
            Expanded(
                child: OutlinedButton.icon(
              onPressed: sysImg == null || sysBusy ? null : _previewSystem,
              icon: const Icon(Icons.visibility_rounded, size: 18),
              label: FittedBox(fit: BoxFit.scaleDown, child: Text(sysImg == null ? 'معاينة' : '✓ معاينة', maxLines: 1, style: const TextStyle(fontSize: 12.5))),
              style: kSysBtn,
            )),
          ]),
          if (sysWarn != null)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(top: 8),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.orange.withAlpha(30),
                border: Border.all(color: Colors.orange.withAlpha(190)),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 18),
                const SizedBox(width: 6),
                Expanded(
                    child: Text(sysWarn!,
                        style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600))),
              ]),
            ),
          if (err != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(err!, style: const TextStyle(color: Colors.red)),
            ),
        ]),
      );
}

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
  TagPos? pos;
  double? aspect;
  bool busy = false;
  bool noTag = false; // الصورة دي من غير ورقة بيانات
  bool kept = false; // الصورة دي محفوظة للأرشيف بعد الإرسال
  final _panelKey = GlobalKey<_BatchInfoPanelState>();
  final _sysReady = ValueNotifier<bool>(false);
  final _viewTc = TransformationController(); // تكبير عرض الصورة بس (مش بيأثر على الملف المبعوت)
  BatchInfo? _binit;

  @override
  void initState() {
    super.initState();
    unawaited(_warmTags());
    unawaited(_loadBatchInit());
    _init();
  }

  Future<void> _loadBatchInit() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => _binit = BatchInfo(p.getString('bi_count') ?? '', p.getString('bi_pi') ?? '',
        p.getString('bi_col') ?? '', p.getString('bi_total') ?? ''));
  }

  Future<void> _toggleTag(bool hide) async {
    final path = img;
    if (path == null) return;
    setState(() => noTag = hide);
    await Store.setNoTag(path, hide);
  }

  /// حفظ الباتش في الأرشيف بعد الإرسال (بدل المسح بعد ١٢ ساعة).
  Future<void> _toggleKeep() async {
    final path = img;
    if (path == null) return;
    final v = !kept;
    setState(() => kept = v);
    await Store.setKept(path, v);
    if (mounted) snack(context, v ? 'هيتحفظ في الأرشيف بعد الإرسال' : 'اتشال من المحفوظات');
  }

  Future<void> _init() async {
    final lost = await takeLostPick('batch');
    if (lost != null && mounted) {
      try {
        final path = await persistImage(
            lost, 'batch_${DateTime.now().microsecondsSinceEpoch}.jpg',
            filter: ScanFilter.adaptive, profile: ImageQualityProfile.batch);
        await Store.setBatchImg(path, fresh: true);
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
    } catch (e, st) {
      AppLog.e('warmTags', e, st);
    }
  }

  Future<void> _show(String path) async {
    try {
      final t = tag ?? await receiptTag(1000, widget.session, batch: true);
      final a = await imageAspect(path);
      var p0 = await Store.pos(path);
      if (p0 == null) {
        final last = await Store.lastBatchPos(a);
        if (last != null) {
          p0 = last;
          await Store.setPosFor(path, last);
        } else {
          p0 = bottomTagPos(t, a); // أول مرة: أسفل الصورة بعرضها كله (من غير حفظ، بيتحسب مع كل صورة)
        }
      }
      final p = fitTagPos(p0, t, a);
      if (p.cx != p0.cx || p.cy != p0.cy) await Store.setPosFor(path, p);
      final nt = await Store.noTag(path);
      final kp = await Store.isKept(path);
      if (!mounted) return;
      _viewTc.value = Matrix4.identity();
      setState(() {
        noTag = nt;
        kept = kp;
        tag = t;
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
          filter: ScanFilter.adaptive, applyNow: false,
          profile: ImageQualityProfile.batch);
      await Store.setBatchImg(path, fresh: true);
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
  Future<String?> _ingestQuick(String src, {bool keepOriginal = false}) async {
    try {
      final path = await persistImage(
          src, 'batch_${DateTime.now().microsecondsSinceEpoch}.jpg',
          filter: ScanFilter.adaptive, applyNow: false, keepOriginal: keepOriginal,
          profile: ImageQualityProfile.batch);
      await Store.setBatchImg(path, fresh: true);
      return path;
    } catch (e) {
      if (mounted) snack(context, 'حصل خطأ: ${errText(e)}');
      return null;
    }
  }

  /// لو الموظف خرج من شاشة التعديل بدون حفظ: بنطبّق فلتر الإيصال قبل العرض.
  Future<void> _ensureBatchFiltered(String path) async {
    try {
      final f = File(path);
      if (await f.exists()) {
        await f.writeAsBytes(await applyFilter(await f.readAsBytes(),
          await resolveImageFilter(path),
          profile: await Store.qualityProfile(path)));
        await FileImage(f).evict();
      }
    } catch (e, st) {
      AppLog.e('batch.lateFilter', e, st);
    }
  }

  /// كاميرا التطبيق: صورة واحدة بس، بعدها شاشة التعديل علطول (من غير عداد).
  Future<void> _capture() async {
    final engine = await Store.scanEngine();
    final perf = await Store.perfMode();
    if (!mounted) return;
    // الباتش يفضل على ماسح جوجل الأساسي (قص بس) حتى لو الإيصالات على الوضع الكامل: صورة خام أنضف للـ OCR
    if (engine >= 1 && !_scannerFailed && perf != PerfMode.lite) {
      await _captureGoogle();
      // لو الماسح فشل دلوقتي (مش متاح) نكمل بكاميرا A2R تلقائياً
      if (_scannerFailed && mounted) await _captureA2R();
    } else {
      await _captureA2R();
    }
  }

  /// ماسح جوجل الذكي: صورة واحدة مقصوصة، وبعدها شاشة التعديل على الفلاتر.
  Future<void> _captureGoogle() async {
    final paths = await scanImages(context, 1, camFallback: true);
    if (paths.isEmpty || !mounted) {
      if (_scannerFailed) return; // الدالة اللي فوق هتفتح كاميرا A2R
      if (mounted && img == null) Navigator.pop(context);
      return;
    }
    final manual = _lastScanManual; // true لو الماسح فشل واتحوّلنا للمعرض
    final saved = await _ingestQuick(paths.first, keepOriginal: !manual);
    if (saved == null) {
      if (mounted && img == null) Navigator.pop(context);
      return;
    }
    _lastScanManual = manual;
    if (mounted && await _edit(tab: manual ? 0 : 2, fromCam: true, path: saved)) {
      await Store.retireBatchImg();
      if (mounted) setState(() => img = null);
      await _captureGoogle(); // إعادة أخذ
      return;
    }
    if (mounted && img == null) {
      final cur = await Store.batchImg();
      if (cur != null) {
        if (cur == saved) await _ensureBatchFiltered(cur);
        await _show(cur);
      }
    }
    final shown = img;
    if (shown != null) {
      unawaited(qualityWarning(shown).then((warn) {
        if (warn != null && mounted) snack(context, warn);
      }));
    }
    if (mounted && img == null) Navigator.pop(context);
  }

  Future<void> _captureA2R() async {
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
              await Store.retireBatchImg();
              if (mounted) setState(() => img = null);
              return null;
            }
            if (mounted && img == null) {
              // خرج من التعديل من غير حفظ: نطبّق فلتر الإيصال ونعرضها
              final cur = await Store.batchImg();
              if (cur != null) {
                if (cur == saved) await _ensureBatchFiltered(cur);
                await _show(cur);
              }
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
    final path = img, a = aspect;
    if (path == null || a == null) return;
    _saveT = Timer(const Duration(milliseconds: 400), () {
      Store.saveBatchPos(path, p, a).catchError((Object e, StackTrace st) {
        AppLog.e('saveBatchPos', e, st);
      });
    });
  }

  Future<void> _flushPos() async {
    final t = _saveT;
    if (t != null && t.isActive) {
      t.cancel();
      final path = img, p = pos, a = aspect;
      if (path != null && p != null && a != null) await Store.saveBatchPos(path, p, a);
    }
  }

  @override
  void dispose() {
    final t = _saveT;
    if (t != null && t.isActive) {
      t.cancel();
      final path = img, p = pos, a = aspect;
      if (path != null && p != null && a != null) Store.saveBatchPos(path, p, a);
    }
    _viewTc.dispose();
    _sysReady.dispose();
    super.dispose();
  }

  /// معرض: يختار صورة، وبعدين شاشة القص (تعديل) تفتح لوحدها.
  Future<void> _gallery() async {
    XFile? x;
    await markPickTarget('batch');
    try {
      x = await ImagePicker()
          .pickImage(source: ImageSource.gallery); // الأصل من غير تصغير
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
          filter: ScanFilter.adaptive, applyNow: false,
          profile: ImageQualityProfile.batch);
      await Store.setBatchImg(path, fresh: true);
      await _show(path);
    } catch (e) {
      if (mounted) snack(context, 'حصل خطأ: ${errText(e)}');
    } finally {
      if (mounted) setState(() => busy = false);
    }
    _lastScanManual = true; // صورة معرض من غير قص: القص التلقائي يشتغل
    final beforeEdit = img;
    if (mounted && beforeEdit != null) {
      await _edit(tab: 2);
      if (mounted && img == beforeEdit) {
        await _ensureBatchFiltered(beforeEdit);
        await _show(beforeEdit);
      }
    }
  }

  /// تعديل: قص بزوايا حرة وتدوير وفلاتر للصورة الحالية.
  Future<bool> _edit({int tab = 0, bool fromCam = false, String? path}) async {
    final cur = path ?? img;
    if (cur == null) return false;
    final out = await Navigator.push<String>(
      context,
      PageRouteBuilder<String>(
        transitionDuration: const Duration(milliseconds: 110),
        reverseTransitionDuration: const Duration(milliseconds: 100),
        pageBuilder: (_, __, ___) =>
            EditorPage(path: cur, prefix: 'batch_', initialTab: tab, canRetake: fromCam),
        transitionsBuilder: (_, a, __, child) => FadeTransition(opacity: a, child: child),
      ),
    );
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
      if (!mounted) return;
      final info = await _panelKey.currentState?.submit();
      if (info == null || !mounted) return;
      if (!await preSendCheckBatch(context, widget.session, img!)) return;
      if (!mounted) return;
      final ok = await sendBatchFile(context, widget.session, img!, info: info);
      if (ok) HapticFeedback.mediumImpact();
      if (ok && mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) snack(context, 'حصل خطأ: ${errText(e)}');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  /// شيت «الورقة»: إظهار/إخفاء + حجم + رجوع لأسفل الصورة. السحب والتكبير بإصبعين شغالين على الورقة نفسها.
  Future<void> _paperSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: StatefulBuilder(builder: (ctx, setSheet) {
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('الورقة', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('ورقة البيانات على الصورة دي'),
                  subtitle: const Text('اقفلها لو الصورة مش محتاجة ورقة (الصورة الجاية بتبدأ بالورقة)',
                      style: TextStyle(fontSize: 11)),
                  value: !noTag,
                  onChanged: busy
                      ? null
                      : (v) async {
                          await _toggleTag(!v);
                          setSheet(() {});
                        },
                ),
                const Text('حجم الورقة: من 5% إلى 100% من عرض الصورة', style: TextStyle(fontSize: 12)),
                Row(children: [
                  const Icon(Icons.format_size_rounded),
                  Expanded(
                    child: Slider(
                      value: pos!.s.clamp(kTagMinScale, 1.0).toDouble(),
                      min: kTagMinScale,
                      max: 1.0,
                      onChanged: noTag
                          ? null
                          : (v) {
                              _set(fitTagPos(pos!.copyWith(s: v), tag!, aspect!));
                              setSheet(() {});
                            },
                    ),
                  ),
                  IconButton(
                    tooltip: 'أسفل الصورة بعرضها كله',
                    icon: const Icon(Icons.restart_alt_rounded),
                    onPressed: noTag
                        ? null
                        : () {
                            _set(bottomTagPos(tag!, aspect!));
                            setSheet(() {});
                          },
                  ),
                ]),
                const Text(
                    'حرّك الورقة لمكان فاضي من الصورة وماتغطيش أي بيانات (خصوصًا العدد والإجمالي). '
                    'تقدر تسحب الورقة نفسها وتكبّرها وتصغّرها بإصبعين.',
                    style: TextStyle(fontSize: 11.5, color: Colors.orange)),
              ]),
            ),
          );
        }),
      ),
    );
  }

  Widget _pill(IconData i, String t, VoidCallback? f) => OutlinedButton.icon(
        onPressed: f,
        icon: Icon(i, size: 16),
        label: Text(t, style: const TextStyle(fontSize: 12)),
        style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 10), visualDensity: VisualDensity.compact),
      );

  @override
  Widget build(BuildContext context) {
    final ready = img != null && tag != null && pos != null && aspect != null && _binit != null;
    return Scaffold(
      appBar: AppBar(title: const Text('الباتش'), toolbarHeight: 52, actions: [
        IconButton(
            tooltip: 'تصوير',
            icon: const Icon(Icons.add_a_photo_rounded),
            onPressed: busy ? null : _capture),
        IconButton(
            tooltip: 'معرض',
            icon: const Icon(Icons.photo_library_rounded),
            onPressed: busy ? null : _gallery),
        if (img != null)
          IconButton(
              tooltip: 'استخراج النص',
              icon: const Icon(Icons.text_snippet_outlined),
              onPressed: busy ? null : () => showOcrTextSheet(context, img!, title: 'نص الباتش')),
      ]),
      // الزر في bottomNavigationBar عشان رسائل الخطأ (snackbar) تظهر فوقه مش عليه
      bottomNavigationBar: !ready
          ? null
          : SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: ValueListenableBuilder<bool>(
              valueListenable: _sysReady,
              builder: (_, sysOk, __) => SizedBox(
                width: double.infinity,
                height: 50,
                child: FilledButton.icon(
                  onPressed: busy || !sysOk ? null : _send,
                  icon: busy
                      ? const SizedBox(
                          width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.send_rounded),
                  label: const Text('إرسال'),
                ),
              ),
            ),
          ),
        ),
      body: !ready
          ? const Center(child: CircularProgressIndicator())
          : LayoutBuilder(builder: (ctx, cons) {
              // الصورة ثابتة فوق (سحب الورقة مش بيتحوّل لتمرير)، والتمرير للي تحتها بس. الزر ثابت تحت.
              const fixedBelow = 0.0, toolbarH = 46.0, minPanel = 96.0;
              final total = cons.maxHeight;
              final ih = (total * 0.45).clamp(110.0, 420.0).clamp(0.0, math.max(70.0, total - fixedBelow - toolbarH - minPanel)).toDouble();
              return Column(children: [
                SizedBox(
                  height: toolbarH,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    children: [
                      _pill(Icons.crop_rounded, 'تعديل', busy ? null : _edit),
                      const SizedBox(width: 6),
                      ListenableBuilder(
                        listenable: _viewTc,
                        builder: (_, __) {
                          final z = _viewTc.value.getMaxScaleOnAxis();
                          return _pill(Icons.zoom_in_rounded, 'عرض ×${z.toStringAsFixed(1)}  ↺',
                              z > 1.01 ? () => _viewTc.value = Matrix4.identity() : null);
                        },
                      ),
                      const SizedBox(width: 6),
                      _pill(Icons.badge_outlined, 'الورقة', busy ? null : _paperSheet),
                    ],
                  ),
                ),
                SizedBox(
                  height: ih,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
                    child: ClipRect(
                      child: InteractiveViewer(
                        transformationController: _viewTc,
                        minScale: 1,
                        maxScale: 6,
                        child: AnimatedBuilder(
                          animation: _viewTc,
                          builder: (_, __) => TaggedImage(
                              path: img!,
                              tag: tag!,
                              pos: pos!,
                              aspect: aspect,
                              showTag: !noTag,
                              zoom: _viewTc.value.getMaxScaleOnAxis(),
                              onChanged: noTag ? null : _set),
                        ),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                    child: KeyedSubtree(
                      key: ValueKey(img),
                      child: _BatchInfoPanel(
                          key: _panelKey,
                          init: _binit!,
                          img: img!,
                          session: widget.session,
                          sysReady: _sysReady),
                    ),
                  ),
                ),
              ]);
            }),
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
Future<ui.Image> _rotatedImage(String path, int turns,
    {ImageQualityProfile? profile, int? maxDecodeSide}) async {
  final mode = await Store.perfMode();
  final maxSide = maxDecodeSide ?? getMaxSide(mode, profile: profile);
  final bytes = _takeHotBytes(path) ?? await File(path).readAsBytes();
  final sz = await imageSize(bytes);
  // Bound the decode by the longer side, including portrait sources.
  final longest = math.max(sz.w, sz.h);
  final decodeWidth = profile == null && maxDecodeSide == null
      ? (sz.w > maxSide ? maxSide : null)
      : (longest > maxSide ? math.max(1, (sz.w * maxSide / longest).round()) : null);
  final src = await decodeImage(bytes, maxWidth: decodeWidth);
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
    final q = await _detectDocQuadImpl(path);
    if (q == null) return null;
    return _shapeQuad(q, await imageAspect(path));
  } finally {
    AppLog.i('t detect ${swDet.elapsedMilliseconds}ms');
  }
}

Future<List<Offset>?> _detectDocQuadImpl(String path) async {
  // تم إيقاف المحرك الأصلي (document_scan) لأنه كان بيسبب ClassNotFoundException (JNI) بعد التصوير.
  // بنستخدم الكشف البسيط (Dart) بس.
  return _detectDocQuadSimple(path);
}

double _quadArea(List<Offset> q) {
  var a = 0.0;
  for (var i = 0; i < 4; i++) {
    final p = q[i], n = q[(i + 1) % 4];
    a += p.dx * n.dy - n.dx * p.dy;
  }
  return a.abs() / 2;
}

/// أصغر مستطيل مستقيم (من غير ميلان) بيحتوي الرباعي: ده شكل القص التلقائي.
/// بيرجّع TL,TR,BR,BL كنسب.
List<Offset> _rectOf(List<Offset> q) {
  var l = 1.0, t = 1.0, r = 0.0, b = 0.0;
  for (final p in q) {
    l = math.min(l, p.dx);
    t = math.min(t, p.dy);
    r = math.max(r, p.dx);
    b = math.max(b, p.dy);
  }
  return [Offset(l, t), Offset(r, t), Offset(r, b), Offset(l, b)];
}

/// شكل القص التلقائي: 0 ذكي (الافتراضي)، 1 مستطيل دايماً، 2 منظور (4 أركان) دايماً.
int autoCropMode = 0;

/// بيقرر شكل الإطار التلقائي. aspect = ارتفاع/عرض الصورة.
/// الذكي: لو الأركان الأربعة شكلها مستطيل فعلاً (حتى لو ملفوف) بنحتفظ بيها عشان تتعدّل الورقة،
/// ولو الشكل مائل أو مشوّه (غالباً الكشف غلط أو منظور قوي) بنرجع لمستطيل مستقيم.
List<Offset> _shapeQuad(List<Offset> q, double aspect, [int? mode]) {
  final m = mode ?? autoCropMode;
  if (m == 2) return q;
  if (m == 1) return _rectOf(q);
  // A valid perspective quad is not made more accurate by its bounding box.
  // Only the explicit rectangle preference may expand it to background.
  return q;
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
    final img = await decodeImage(await File(path).readAsBytes(), maxWidth: 320);
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
      // نغمّق الألوان الدافية بس (الخشب/المكتب)، ومنلمسش الأزرق الفاتح بتاع الورق الحراري
      final int warm = r > b ? (r - b) : 0;
      final int v = y - ((warm * 6) >> 3);
      feat[i] = v < 0 ? 0 : (v > 255 ? 255 : v);
    }
    return await compute(_stillQuadJob, <String, dynamic>{'feat': feat, 'w': w, 'h': h});
  } catch (e, st) {
    AppLog.e('_detectDocQuadSimple', e, st);
    return null;
  }
}

/// الجزء المشترك بين كشف الصورة المصوّرة والكشف الحي من الكاميرا.
/// feat: قيمة 0..255 لكل بكسل (الورقة غالباً أعلى من الخلفية). بيرجّع TL,TR,BR,BL كنسب.
List<Offset>? _stillQuadJob(Map<String, dynamic> a) =>
    _quadFromFeature(a['feat'] as Uint8List, a['w'] as int, a['h'] as int);

/// A crop needs a visible, continuous edge on every side. A frame edge is
/// not evidence of the paper edge. Return no crop rather than guess/cut text.
bool _supportedQuad(Uint16List mag, List<Offset> q, int w, int h) {
  for (var i = 0; i < 4; i++) {
    final a = q[i], b = q[(i + 1) % 4];
    if ((a.dx < 0.018 && b.dx < 0.018) ||
        (a.dx > 0.982 && b.dx > 0.982) ||
        (a.dy < 0.018 && b.dy < 0.018) ||
        (a.dy > 0.982 && b.dy > 0.982)) return false;
    var supported = 0;
    const steps = 28;
    for (var k = 0; k < steps; k++) {
      final t = 0.08 + 0.84 * k / (steps - 1);
      final x = ((a.dx + (b.dx - a.dx) * t) * w).round();
      final y = ((a.dy + (b.dy - a.dy) * t) * h).round();
      var best = 0;
      for (var yy = math.max(1, y - 1); yy <= math.min(h - 2, y + 1); yy++) {
        for (var xx = math.max(1, x - 1); xx <= math.min(w - 2, x + 1); xx++) {
          best = math.max(best, mag[yy * w + xx]);
        }
      }
      if (best >= 48) supported++;
    }
    if (supported < steps * 0.55) return false;
  }
  return true;
}

/// Low-cost focus proxy for automatic capture, not proof of hardware AF lock.
/// Measures sharp edge transitions on the already-sampled luminance feature.
bool _frameHasDetail(Uint8List feat, int w, int h) {
  var edgeCount = 0;
  for (var y = 1; y < h - 1; y++) {
    for (var x = 1; x < w - 1; x++) {
      final i = y * w + x;
      final lap = (4 * feat[i] - feat[i-1] - feat[i+1] - feat[i-w] - feat[i+w]).abs();
      if (lap >= 32) edgeCount++;
    }
  }
  return edgeCount >= w * h * 0.012;
}

/// نسبة البكسلات المحروقة (≥250) جوه الورقة في المعاينة الحية (شبكة صغيرة ~72 بكسل).
/// q: أركان الورقة كنسب. بنصغّر المستطيل 10% عشان حواف الورقة/الخلفية متتحسبش.
double _liveGlareFrac(Uint8List feat, int w, int h, List<Offset> q) {
  var l = 1.0, t = 1.0, r = 0.0, b = 0.0;
  for (final p in q) {
    l = math.min(l, p.dx);
    t = math.min(t, p.dy);
    r = math.max(r, p.dx);
    b = math.max(b, p.dy);
  }
  final iw = (r - l) * 0.1, ih = (b - t) * 0.1;
  final x0 = ((l + iw) * w).floor().clamp(0, w - 1), x1 = ((r - iw) * w).ceil().clamp(1, w);
  final y0 = ((t + ih) * h).floor().clamp(0, h - 1), y1 = ((b - ih) * h).ceil().clamp(1, h);
  var n = 0, sat = 0;
  for (var y = y0; y < y1; y++) {
    for (var x = x0; x < x1; x++) {
      n++;
      if (feat[y * w + x] >= 250) sat++;
    }
  }
  if (n < 20) return 0;
  final f = sat / n;
  return f > 0.6 ? 0 : f; // الورقة كلها بيضا محروقة = تعريض عالي، مش بقعة لمعة
}

List<bool> _dilate4(List<bool> m, int w, int h) {
  final o = List<bool>.filled(w * h, false);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = y * w + x;
      o[i] = m[i] ||
          (x > 0 && m[i - 1]) ||
          (x < w - 1 && m[i + 1]) ||
          (y > 0 && m[i - w]) ||
          (y < h - 1 && m[i + w]);
    }
  }
  return o;
}

/// تآكل: بكسلات حدود الصورة بتتحسب "فاضية" فالتآكل بيبعد عن الحدود كمان.
List<bool> _erode4(List<bool> m, int w, int h) {
  final o = List<bool>.filled(w * h, false);
  for (var y = 1; y < h - 1; y++) {
    for (var x = 1; x < w - 1; x++) {
      final i = y * w + x;
      o[i] = m[i] && m[i - 1] && m[i + 1] && m[i - w] && m[i + w];
    }
  }
  return o;
}

/// الجزء المشترك بين كشف الصورة المصوّرة والكشف الحي من الكاميرا.
/// feat: قيمة 0..255 لكل بكسل (الورقة غالباً أعلى من الخلفية). بيرجّع TL,TR,BR,BL كنسب.
///
/// الفكرة: الورقة الفاتحة على خشب فاتح بتبقى متصلة بالخلفية من خلال فجوات رفيعة (ظل الحافة).
/// فبنقفل ثقوب الكتابة، وبعدين بنأكّل المنطقة بدرجات مختلفة عشان الورقة تنفصل عن الخلفية،
/// وبنختار أحسن مكوّن: مستطيلي الشكل (مليان)، مش ملزوق في الحدود، وقريب من نص الصورة.
/// كشف حدود الورقة الهجين: يدمج كشف Otsu (فرق السطوع واللون) مع كشف الحواف (Sobel Edge-Barrier)
/// عشان يقدر يمسك حدود الورقة البيضا حتى لو محطوطة على مكتب فاتح أو قريب من لونها.
/// حساب قوة الحواف (Sobel 3x3) على الصورة المصغرة مرة واحدة لتقييم كل المرشحين.
Uint16List _sobelMag(Uint8List feat, int w, int h) {
  final mag = Uint16List(w * h);
  for (var y = 1; y < h - 1; y++) {
    final row = y * w;
    for (var x = 1; x < w - 1; x++) {
      final i = row + x;
      final tl = feat[i - w - 1], t = feat[i - w], tr = feat[i - w + 1];
      final l = feat[i - 1], r = feat[i + 1];
      final bl = feat[i + w - 1], b = feat[i + w], br = feat[i + w + 1];
      final gx = -tl + tr - 2 * l + 2 * r - bl + br;
      final gy = -tl - 2 * t - tr + bl + 2 * b + br;
      mag[i] = gx.abs() + gy.abs();
    }
  }
  return mag;
}

/// قياس حدة الحافة الفعلية على طول الأضلاع الأربعة للرباعي (الضلع الوهمي على المكتب يأخذ درجة ضعيفة جداً).
double _edgeScoreQuad(Uint16List mag, List<Offset> pts, int w, int h) {
  var sumSide = 0.0;
  var minSide = 1e9;
  for (var i = 0; i < 4; i++) {
    final p0 = pts[i], p1 = pts[(i + 1) % 4];
    final dist = math.sqrt((p1.dx - p0.dx) * (p1.dx - p0.dx) + (p1.dy - p0.dy) * (p1.dy - p0.dy));
    final steps = math.max(8, dist.round());
    var acc = 0.0;
    var cnt = 0;
    for (var s = 1; s < steps; s++) {
      final t = s / steps;
      final cx = (p0.dx + (p1.dx - p0.dx) * t).round();
      final cy = (p0.dy + (p1.dy - p0.dy) * t).round();
      final x0 = math.max(0, cx - 1), x1 = math.min(w - 1, cx + 1);
      final y0 = math.max(0, cy - 1), y1 = math.min(h - 1, cy + 1);
      var mx = 0;
      for (var y = y0; y <= y1; y++) {
        final r = y * w;
        for (var x = x0; x <= x1; x++) {
          final v = mag[r + x];
          if (v > mx) mx = v;
        }
      }
      acc += mx;
      cnt++;
    }
    final avg = cnt == 0 ? 0.0 : acc / cnt;
    sumSide += avg;
    if (avg < minSide) minSide = avg;
  }
  return 0.5 * (sumSide / 4.0) + 0.5 * minSide;
}

int _otsuOf(List<int> hist, int totalN, int from, int to) {
  if (totalN <= 0) return (from + to) ~/ 2;
  var sum = 0.0;
  for (var t = from; t <= to; t++) {
    sum += t * hist[t];
  }
  var sumB = 0.0, wB = 0.0, bestV = -1.0;
  var thr = (from + to) ~/ 2;
  for (var t = from; t <= to; t++) {
    wB += hist[t];
    if (wB == 0) continue;
    final wF = totalN - wB;
    if (wF == 0) break;
    sumB += t * hist[t];
    final mB = sumB / wB, mF = (sum - sumB) / wF;
    final v = wB * wF * (mB - mF) * (mB - mF);
    if (v > bestV) {
      bestV = v;
      thr = t;
    }
  }
  return thr;
}

int _histPct(List<int> hist, int n, double p) {
  final target = (n * p).floor();
  var acc = 0;
  for (var t = 0; t < 256; t++) {
    acc += hist[t];
    if (acc >= target) return t;
  }
  return 255;
}

/// كشف حدود الورقة السريع والدقيق: عتبات متعددة + تقييم كل مرشح بحدة الحواف الفعلية (Sobel) على الأضلاع الأربعة.
List<Offset>? _quadFromFeature(Uint8List feat, int w, int h) {
  if (w < 12 || h < 12) return null;
  final n = w * h;
  final hist = List<int>.filled(256, 0);
  for (var i = 0; i < n; i++) {
    hist[feat[i]]++;
  }
  final mag = _sobelMag(feat, w, h);
  // تقدير مرجع الحواف (أقوى 5%) للتطبيع
  var sumM = 0;
  for (var i = 0; i < n; i++) {
    sumM += mag[i];
  }
  final magRef = math.max(40.0, (sumM / n) * 3.5);

  final tOtsu = _otsuOf(hist, n, 0, 255);
  var upperN = 0;
  for (var t = tOtsu + 1; t < 256; t++) {
    upperN += hist[t];
  }
  final tUpper = upperN > n * 0.08 ? _otsuOf(hist, upperN, tOtsu + 1, 255) : tOtsu;
  final med = _histPct(hist, n, 0.50);
  final p75 = _histPct(hist, n, 0.75);
  final p82 = _histPct(hist, n, 0.82);
  final p88 = _histPct(hist, n, 0.88);
  final thresholds = <int>{tOtsu, tUpper, (tOtsu + tUpper) ~/ 2, p75, p82, p88}.toList()..sort();

  final seen = List<bool>.filled(n, false);
  final queue = List<int>.filled(n, 0);
  List<Offset>? bestQ;
  var bestScore = 0.0;
  var bestThr = -1;
  var bestSeed = -1;

  for (final thr in thresholds) {
    final rawMask = List<bool>.generate(n, (i) => feat[i] > thr);
    final er = _erode4(_dilate4(rawMask, w, h), w, h);
    for (var i = 0; i < n; i++) {
      seen[i] = false;
    }
    for (var s0 = 0; s0 < n; s0++) {
      if (!er[s0] || seen[s0]) continue;
      var head = 0, tail = 0;
      queue[tail++] = s0;
      seen[s0] = true;
      var tl = s0, tr = s0, br = s0, bl = s0;
      var sx = 0, sy = 0, sFeat = 0;
      var minX = w, maxX = 0, minY = h, maxY = 0;
      while (head < tail) {
        final i = queue[head++];
        final x = i % w, y = i ~/ w;
        sx += x;
        sy += y;
        sFeat += feat[i];
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
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
      if (tail < n * 0.04) continue;
      final compMean = sFeat / tail;
      if (compMean < med + 6) continue;
      Offset raw(int i) => Offset((i % w).toDouble(), (i ~/ w).toDouble());
      final rq = [raw(tl), raw(tr), raw(br), raw(bl)];
      var a2 = 0.0;
      for (var i = 0; i < 4; i++) {
        final p = rq[i], q2 = rq[(i + 1) % 4];
        a2 += p.dx * q2.dy - q2.dx * p.dy;
      }
      final qaPx = a2.abs() / 2;
      if (qaPx < 4) continue;
      final fill = math.min(1.0, tail / qaPx);
      if (fill < 0.72) continue;
      final q = [
        Offset(((rq[0].dx + 0.5) / w).clamp(0.0, 1.0), ((rq[0].dy + 0.5) / h).clamp(0.0, 1.0)),
        Offset(((rq[1].dx + 0.5) / w).clamp(0.0, 1.0), ((rq[1].dy + 0.5) / h).clamp(0.0, 1.0)),
        Offset(((rq[2].dx + 0.5) / w).clamp(0.0, 1.0), ((rq[2].dy + 0.5) / h).clamp(0.0, 1.0)),
        Offset(((rq[3].dx + 0.5) / w).clamp(0.0, 1.0), ((rq[3].dy + 0.5) / h).clamp(0.0, 1.0)),
      ];
      if (!_quadConvex(q) || !_supportedQuad(mag, q, w, h)) continue;
      final area = _quadArea(q);
      if (area < 0.05 || area > 0.90) continue;
      var touch = 0;
      if (minX <= 2) touch++;
      if (maxX >= w - 3) touch++;
      if (minY <= 2) touch++;
      if (maxY >= h - 3) touch++;
      final borderPen = touch == 0 ? 1.0 : (touch == 1 ? 0.80 : (touch == 2 ? 0.20 : 0.05));
      final cx = sx / tail / w, cy = sy / tail / h;
      final cen = (cx - 0.5).abs() + (cy - 0.5).abs();
      final es = _edgeScoreQuad(mag, rq, w, h);
      final edgeFactor = math.min(1.8, (es / magRef) * 2.0 + 0.15);
      final contrastBoost = ((compMean - med) / 40.0 + 0.5).clamp(0.2, 1.5).toDouble();
      final score = math.pow(area, 0.30) *
          math.pow(fill, 3) *
          math.max(0.15, 1.0 - cen * 0.6) *
          borderPen *
          contrastBoost *
          math.pow(edgeFactor, 1.5);
      if (score > bestScore + 1e-9) {
        bestScore = score;
        bestQ = q;
        bestThr = thr;
        bestSeed = s0;
      }
    }
  }
  if (bestQ == null) return null;
  // تحسين الأركان: تركيب خط مستقيم على كل ضلع من بكسلات حدود المكوّن الفائز،
  // والركن هو تقاطع الخطوط (أدق بكتير من نقاط الحواف الخام خصوصاً مع الدوران والميل)
  final refined = _refineQuadLines(feat, w, h, bestThr, bestSeed, bestQ);
  // تحسين نهائي (Edge Snapping): تحريك كل ضلع ±2 بكسل نحو أقوى حافة فعلية (Sobel) ليلتصق بحدود الورقة بدقة
  final snapped = _snapQuadToSobel(mag, refined ?? bestQ, w, h);
  if (_supportedQuad(mag, snapped, w, h)) return snapped;
  return _supportedQuad(mag, bestQ, w, h) ? bestQ : null;
}

/// تركيب خط مستقيم على كل ضلع من أضلاع الرباعي الأولي باستخدام بكسلات حدود المكوّن الفائز،
/// وإرجاع الأركان الأربعة كتقاطعات الخطوط المتجاورة. بيرجّع null لو التحسين مش واثق (نرجع للرباعي الأصلي).
List<Offset>? _refineQuadLines(
    Uint8List feat, int w, int h, int thr, int seed, List<Offset> q0) {
  try {
    final n = w * h;
    if (seed < 0 || seed >= n) return null;
    final rawMask = List<bool>.generate(n, (i) => feat[i] > thr);
    final er = _erode4(_dilate4(rawMask, w, h), w, h);
    if (!er[seed]) return null;
    // تجميع المكوّن الفائز من البذرة
    final inComp = List<bool>.filled(n, false);
    final queue = List<int>.filled(n, 0);
    var head = 0, tail = 0, count = 0;
    queue[tail++] = seed;
    inComp[seed] = true;
    while (head < tail) {
      final i = queue[head++];
      count++;
      final x = i % w, y = i ~/ w;
      if (x > 0 && er[i - 1] && !inComp[i - 1]) {
        inComp[i - 1] = true;
        queue[tail++] = i - 1;
      }
      if (x < w - 1 && er[i + 1] && !inComp[i + 1]) {
        inComp[i + 1] = true;
        queue[tail++] = i + 1;
      }
      if (y > 0 && er[i - w] && !inComp[i - w]) {
        inComp[i - w] = true;
        queue[tail++] = i - w;
      }
      if (y < h - 1 && er[i + w] && !inComp[i + w]) {
        inComp[i + w] = true;
        queue[tail++] = i + w;
      }
    }
    if (count < n * 0.04) return null;
    // بكسلات الحدود: بكسل من المكوّن له جار خارجه (أو على حرف الصورة)
    final bx = <int>[], by = <int>[];
    for (var i = 0; i < n; i++) {
      if (!inComp[i]) continue;
      final x = i % w, y = i ~/ w;
      if (x == 0 ||
          y == 0 ||
          x == w - 1 ||
          y == h - 1 ||
          !inComp[i - 1] ||
          !inComp[i + 1] ||
          !inComp[i - w] ||
          !inComp[i + w]) {
        bx.add(x);
        by.add(y);
      }
    }
    if (bx.length < 16) return null;
    // نقاط الرباعي الأولي بالبكسل
    final pts = [for (final o in q0) Offset(o.dx * w - 0.5, o.dy * h - 0.5)];
    // خط ax + by = c لكل ضلع
    final lines = <List<double>>[];
    for (var e = 0; e < 4; e++) {
      final a = pts[e], b = pts[(e + 1) % 4];
      final dx = b.dx - a.dx, dy = b.dy - a.dy;
      final len = math.sqrt(dx * dx + dy * dy);
      if (len < 8) return null;
      final ux = dx / len, uy = dy / len; // اتجاه الضلع
      final nx = -uy, ny = ux; // العمودي عليه
      final margin = math.max(3.0, len * 0.06);
      final xs = <double>[], ys = <double>[];
      for (var i = 0; i < bx.length; i++) {
        final rx = bx[i] - a.dx, ry = by[i] - a.dy;
        final t = rx * ux + ry * uy;
        if (t < len * 0.08 || t > len * 0.92) continue; // نتجنب منطقة الأركان
        if ((rx * nx + ry * ny).abs() > margin) continue;
        xs.add(bx[i].toDouble());
        ys.add(by[i].toDouble());
      }
      final m = xs.length;
      if (m < 6) return null;
      // مربعات صغرى: الضلع الأفقي نركّب y على x، والرأسي x على y
      if (dx.abs() >= dy.abs()) {
        var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0;
        for (var i = 0; i < m; i++) {
          sx += xs[i];
          sy += ys[i];
          sxx += xs[i] * xs[i];
          sxy += xs[i] * ys[i];
        }
        final den = m * sxx - sx * sx;
        if (den.abs() < 1e-6) return null;
        final k = (m * sxy - sx * sy) / den;
        final c0 = (sy - k * sx) / m;
        // k*x - y + c0 = 0
        lines.add([k, -1.0, -c0]);
      } else {
        var sx = 0.0, sy = 0.0, syy = 0.0, sxy = 0.0;
        for (var i = 0; i < m; i++) {
          sx += xs[i];
          sy += ys[i];
          syy += ys[i] * ys[i];
          sxy += xs[i] * ys[i];
        }
        final den = m * syy - sy * sy;
        if (den.abs() < 1e-6) return null;
        final k = (m * sxy - sx * sy) / den;
        final c0 = (sx - k * sy) / m;
        // -x + k*y + c0 = 0
        lines.add([-1.0, k, -c0]);
      }
    }
    // الأركان = تقاطعات الخطوط المتجاورة
    final out = <Offset>[];
    for (var i = 0; i < 4; i++) {
      final l1 = lines[(i + 3) % 4], l2 = lines[i];
      final det = l1[0] * l2[1] - l2[0] * l1[1];
      if (det.abs() < 1e-9) return null;
      // حل النظام a1*x+b1*y=c1 ، a2*x+b2*y=c2
      final x = (l1[2] * l2[1] - l2[2] * l1[1]) / det;
      final y = (l1[0] * l2[2] - l2[0] * l1[2]) / det;
      out.add(Offset(x, y));
    }
    final norm = [
      for (final p in out)
        Offset(((p.dx + 0.5) / w).clamp(0.0, 1.0), ((p.dy + 0.5) / h).clamp(0.0, 1.0))
    ];
    if (!_quadConvex(norm)) return null;
    final ar = _quadArea(norm);
    if (ar < 0.04 || ar > 0.93) return null;
    // لو أي ركن اتحرك أكتر من 12% من أبعاد الصورة نعتبر التحسين غلط ونرجع للأصلي
    for (var i = 0; i < 4; i++) {
      if ((norm[i] - q0[i]).distance > 0.12) return null;
    }
    return norm;
  } catch (e, st) {
    AppLog.e('refineQuad', e, st);
    return null;
  }
}

List<Offset> _snapQuadToSobel(Uint16List mag, List<Offset> q, int w, int h) {
  final pts = [for (final o in q) Offset(o.dx * w - 0.5, o.dy * h - 0.5)];
  double sideAvg(Offset a, Offset b) {
    final dist = math.sqrt((b.dx - a.dx) * (b.dx - a.dx) + (b.dy - a.dy) * (b.dy - a.dy));
    final steps = math.max(8, dist.round());
    var acc = 0.0;
    for (var s = 1; s < steps; s++) {
      final t = s / steps;
      final cx = (a.dx + (b.dx - a.dx) * t).round().clamp(0, w - 1).toInt();
      final cy = (a.dy + (b.dy - a.dy) * t).round().clamp(0, h - 1).toInt();
      acc += mag[cy * w + cx];
    }
    return acc / (steps - 1);
  }

  for (var i = 0; i < 4; i++) {
    final j = (i + 1) % 4;
    final p0 = pts[i], p1 = pts[j];
    final dx = p1.dx - p0.dx, dy = p1.dy - p0.dy;
    final len = math.sqrt(dx * dx + dy * dy);
    if (len < 6) continue;
    final nx = -dy / len, ny = dx / len;
    var bestShift = 0.0;
    var bestVal = sideAvg(p0, p1);
    final step = math.min(1.0, math.min(w, h) * 0.01);
    for (final sh in [-2 * step, -step, step, 2 * step]) {
      final a = Offset(p0.dx + nx * sh, p0.dy + ny * sh);
      final b = Offset(p1.dx + nx * sh, p1.dy + ny * sh);
      final v = sideAvg(a, b);
      if (v > bestVal * 1.06) {
        bestVal = v;
        bestShift = sh;
      }
    }
    if (bestShift != 0) {
      pts[i] = Offset((p0.dx + nx * bestShift).clamp(0.0, w - 1.0), (p0.dy + ny * bestShift).clamp(0.0, h - 1.0));
      pts[j] = Offset((p1.dx + nx * bestShift).clamp(0.0, w - 1.0), (p1.dy + ny * bestShift).clamp(0.0, h - 1.0));
    }
  }
  final out = [
    for (final p in pts) Offset(((p.dx + 0.5) / w).clamp(0.0, 1.0), ((p.dy + 0.5) / h).clamp(0.0, 1.0))
  ];
  return _quadConvex(out) ? out : q;
}

/// استخراج شبكة مصغّرة (72px) + متوسط السطوع من إطار الكاميرا (سريع جداً < 1ms).
({Uint8List feat, int w, int h, double meanY})? _liveExtract(cam.CameraImage f, int rot) {
  if (f.planes.length < 3) return null;
  final W = f.width, H = f.height;
  final swap = rot == 90 || rot == 270;
  final upW = swap ? H : W, upH = swap ? W : H;
  const gw = 72;
  final gh = math.max(8, (gw * upH / upW).round());
  final yp = f.planes[0], up = f.planes[1], vp = f.planes[2];
  final ub = up.bytesPerPixel ?? 1, vb = vp.bytesPerPixel ?? 1;
  final feat = Uint8List(gw * gh);
  var sumY = 0;
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
      sumY += y;
      final cx = sx >> 1, cy = sy >> 1;
      final ci = cy * up.bytesPerRow + cx * ub;
      final vi = cy * vp.bytesPerRow + cx * vb;
      var warm = 0;
      if (ci < up.bytes.length && vi < vp.bytes.length) {
        final diff = ((vp.bytes[vi] - 128) * 14 - (up.bytes[ci] - 128) * 14) ~/ 10;
        if (diff > 0) warm = diff;
      }
      final int v = y - ((warm * 6) >> 3);
      feat[gy * gw + gx] = v < 0 ? 0 : (v > 255 ? 255 : v);
    }
  }
  return (feat: feat, w: gw, h: gh, meanY: sumY / (gw * gh));
}

/// عامل خلفي ثابت (Persistent Isolate) لكشف الحدود الحي بدون إعادة إنشاء Isolate كل فريم (أسرع 5x).
void _liveDetEntry(SendPort mainPort) {
  final port = ReceivePort();
  mainPort.send(port.sendPort);
  port.listen((msg) {
    if (msg is List && msg.length == 5) {
      final reply = msg[0] as SendPort;
      final feat = (msg[1] as TransferableTypedData).materialize().asUint8List();
      final w = msg[2] as int, h = msg[3] as int, mode = msg[4] as int;
      final q = _quadFromFeature(feat, w, h);
      if (q == null || _quadArea(q) > 0.97) {
        reply.send(null);
      } else {
        final shaped = _shapeQuad(q, h / w, mode);
        reply.send(<double>[
          for (final o in shaped) ...[o.dx, o.dy]
        ]);
      }
    }
  });
}

class _LiveDetWorker {
  Isolate? _iso;
  SendPort? _send;
  bool _starting = false;

  Future<void> start() async {
    if (_send != null || _starting) return;
    _starting = true;
    try {
      final rp = ReceivePort();
      _iso = await Isolate.spawn(_liveDetEntry, rp.sendPort);
      _send = await rp.first as SendPort;
      rp.close();
    } catch (e, st) {
      AppLog.e('liveWorker.start', e, st);
    } finally {
      _starting = false;
    }
  }

  Future<List<double>?> detect(Uint8List feat, int w, int h, int mode) async {
    final s = _send;
    if (s == null) return null;
    final rp = ReceivePort();
    s.send([rp.sendPort, TransferableTypedData.fromList([feat]), w, h, mode]);
    final res = await rp.first;
    rp.close();
    return res is List ? res.cast<double>() : null;
  }

  void dispose() {
    _iso?.kill(priority: Isolate.immediate);
    _iso = null;
    _send = null;
  }
}

/// ميزان استقامة حي في منتصف الشاشة: يتحول للأخضر لما الموبايل يكون موازي تماماً للمكتب.
class _TiltLevelPainter extends CustomPainter {
  final double ax, ay; // م/ث² من حساس التسارع
  final bool aligned;
  const _TiltLevelPainter(this.ax, this.ay, this.aligned);
  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final col = aligned ? Colors.greenAccent : Colors.white70;
    // الدائرة المرجعية الثابتة في المنتصف
    canvas.drawCircle(
        c,
        18,
        Paint()
          ..color = col.withValues(alpha: aligned ? 0.9 : 0.45)
          ..style = PaintingStyle.stroke
          ..strokeWidth = aligned ? 2.5 : 1.5);
    // علامة + صغيرة في المركز
    final cross = Paint()
      ..color = col.withValues(alpha: 0.6)
      ..strokeWidth = 1.2;
    canvas.drawLine(Offset(c.dx - 7, c.dy), Offset(c.dx + 7, c.dy), cross);
    canvas.drawLine(Offset(c.dx, c.dy - 7), Offset(c.dx, c.dy + 7), cross);
    // النقطة المتحركة حسب ميل الموبايل
    final dx = (-ax / 9.81).clamp(-1.0, 1.0) * 34.0;
    final dy = (ay / 9.81).clamp(-1.0, 1.0) * 34.0;
    final dot = Offset(c.dx + dx, c.dy + dy);
    canvas.drawCircle(dot, 6, Paint()..color = aligned ? Colors.greenAccent : kAccent);
    canvas.drawCircle(
        dot,
        6,
        Paint()
          ..color = Colors.black45
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1);
  }

  @override
  bool shouldRepaint(covariant _TiltLevelPainter old) =>
      (old.ax - ax).abs() > 0.05 || (old.ay - ay).abs() > 0.05 || old.aligned != aligned;
}

/// إطار إرشادي بنسبة ورقة A4 لتظبيط تصوير عدة إيصالات (حتى 15 إيصال) في صورة واحدة بدون قص الحواف.
class _A4GuidePainter extends CustomPainter {
  const _A4GuidePainter();
  @override
  void paint(Canvas canvas, Size size) {
    const a4Ratio = 1.0 / 1.4142; // عرض / ارتفاع
    final padX = size.width * 0.04;
    final padY = size.height * 0.04;
    final availW = size.width - padX * 2;
    final availH = size.height - padY * 2;
    var w = availW;
    var h = w / a4Ratio;
    if (h > availH) {
      h = availH;
      w = h * a4Ratio;
    }
    final rect = Rect.fromCenter(
      center: Offset(size.width / 2, size.height / 2),
      width: w,
      height: h,
    );
    // تظليل خفيف خارج إطار A4
    final outer = Path()..addRect(Offset.zero & size);
    final inner = Path()..addRect(rect);
    canvas.drawPath(
      Path.combine(PathOperation.difference, outer, inner),
      Paint()..color = Colors.black.withValues(alpha: 0.32),
    );
    // حدود الإطار
    canvas.drawRect(
      rect,
      Paint()
        ..color = Colors.white70
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
    // زوايا واضحة بلون التطبيق
    final corner = Paint()
      ..color = kAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round;
    const cl = 22.0;
    // أعلى يسار
    canvas.drawLine(rect.topLeft, rect.topLeft + const Offset(cl, 0), corner);
    canvas.drawLine(rect.topLeft, rect.topLeft + const Offset(0, cl), corner);
    // أعلى يمين
    canvas.drawLine(rect.topRight, rect.topRight + const Offset(-cl, 0), corner);
    canvas.drawLine(rect.topRight, rect.topRight + const Offset(0, cl), corner);
    // أسفل يسار
    canvas.drawLine(rect.bottomLeft, rect.bottomLeft + const Offset(cl, 0), corner);
    canvas.drawLine(rect.bottomLeft, rect.bottomLeft + const Offset(0, -cl), corner);
    // أسفل يمين
    canvas.drawLine(rect.bottomRight, rect.bottomRight + const Offset(-cl, 0), corner);
    canvas.drawLine(rect.bottomRight, rect.bottomRight + const Offset(0, -cl), corner);
  }

  @override
  bool shouldRepaint(covariant _A4GuidePainter old) => false;
}

class _LiveQuadPainter extends CustomPainter {
  final List<Offset> q;
  final double lockProgress; // 0..1 تقدم الثبات في وضع التصوير التلقائي
  const _LiveQuadPainter(this.q, {this.lockProgress = 0});
  @override
  void paint(Canvas canvas, Size size) {
    final pts = [for (final o in q) Offset(o.dx * size.width, o.dy * size.height)];
    final path = Path()..addPolygon(pts, true);
    final col = lockProgress > 0
        ? Color.lerp(kAccent, Colors.greenAccent, lockProgress.clamp(0.0, 1.0))!
        : kAccent;
    canvas.drawPath(path, Paint()..color = col.withValues(alpha: 0.18 + 0.08 * lockProgress));
    canvas.drawPath(
        path,
        Paint()
          ..color = col
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3 + lockProgress * 1.5
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
  bool shouldRepaint(covariant _LiveQuadPainter old) =>
      old.q != q || (old.lockProgress - lockProgress).abs() > 0.01;
}

/// بترجّع مسار الصورة الجديدة بعد التعديل، أو null لو الموظف رجع من غير تأكيد.
/// التعديل دايماً بيبدأ من النسخة الأصلية، فتقدر تكبّر القص أو ترجّع الفلتر في أي وقت.
const kRetake = '__retake__'; // EditorPage بترجّعه لما الموظف يدوس "إعادة أخذ"
const kDelete = '__delete__'; // حذف الصفحة الحالية
const kAllPrefix = '__all__'; // __all__|<EditParams json>|<path>: حفظ الصفحة الحالية وتطبيق الفلتر على كل الصفحات
const kNavPrefix = '__nav__'; // __nav__|next|<path> أو __nav__|prev|<path>: انتقال لصفحة تانية بعد حفظ التعديل

/// دمج كل خطوات معالجة الصورة (منظور + فلتر إيصال + ألوان + حدة + قص هوامش) في Isolate واحد
/// بدل 4 Isolates منفصلة — أسرع بكتير واستهلاك رامات أقل بـ 50%.
Map<String, dynamic> _renderPipelineJob(Map<String, dynamic> a) {
  var rgba = a['src'] as Uint8List;
  final sw = a['sw'] as int, sh = a['sh'] as int;
  var w = a['ow'] as int, h = a['oh'] as int;
  final needWarp = a['needWarp'] as bool;
  final clean = a['clean'] as bool;
  final thermal = a['thermal'] as bool;
  final plain = (a['plain'] as bool?) ?? false;
  final postMatrix = a['postMatrix'] as List<double>?;
  final photocopy = (a['photocopy'] as bool?) ?? false;
  final sk = (a['sk'] as num).toDouble();
  final doTrim = a['doTrim'] as bool;

  if (needWarp) {
    rgba = _warpJob(a);
  } else {
    final m = (a['m'] as List).cast<double>();
    final isIdentity = (m[0] - 1).abs() < 1e-6 &&
        m[1].abs() < 1e-6 &&
        m[2].abs() < 1e-6 &&
        m[4].abs() < 1e-6 &&
        m[5].abs() < 1e-6 &&
        (m[6] - 1).abs() < 1e-6 &&
        m[7].abs() < 1e-6 &&
        m[9].abs() < 1e-6 &&
        m[10].abs() < 1e-6 &&
        m[11].abs() < 1e-6 &&
        (m[12] - 1).abs() < 1e-6 &&
        m[14].abs() < 1e-6;
    if (!isIdentity) {
      rgba = _matrixJob(<String, dynamic>{'src': rgba, 'm': m});
    }
    w = sw;
    h = sh;
  }

  if (clean) {
    rgba = _cleanJob(<String, dynamic>{
      'src': rgba,
      'w': w,
      'h': h,
      'gray': false,
      'th': thermal,
      'plain': plain,
      'photocopy': photocopy,
    });
    if (postMatrix != null) {
      rgba = _matrixJob(<String, dynamic>{'src': rgba, 'm': postMatrix});
    }
  }
  if (sk > 0) {
    rgba = _sharpenJob(<String, dynamic>{'src': rgba, 'w': w, 'h': h, 'k': sk});
  }
  if (clean && doTrim) {
    final tr = _trimJob(<String, dynamic>{'src': rgba, 'w': w, 'h': h});
    final tw = tr['w'] as int;
    if (tw > 0) {
      rgba = tr['out'] as Uint8List;
      w = tw;
      h = tr['h'] as int;
    }
  }
  return <String, dynamic>{'rgba': rgba, 'w': w, 'h': h};
}

/// بيرسم صفحة بعد التعديل (قص + تدوير + فلتر) من نسختها الأصلية وبيرجّع مسار الصورة الجديدة.
/// بيستخدمه المحرر (زر ✓) و"طبّق على كل الصفحات".
Future<String> renderEditedPage(String path, String prefix, EditParams e,
    {bool allowSafeReceiptOutput = false}) async {
  final sp = await SharedPreferences.getInstance();
  Store.working++;
  try {
    // علامة: لو التطبيق اتقفل جوه "تم"، في التشغيل الجاي بنشغّل وضع آمن بدقة أقل
    await sp.setBool('apply_guard', true);
    final baseF = File(Store.baseOf(path));
    final src = await baseF.exists() ? baseF.path : path;
    final turns = e.turns, angle = e.angle;
    final filter = e.filter == ScanFilter.adaptive ? await resolveImageFilter(src) : e.filter;
    final contrast = e.contrast, brightness = e.brightness, sharp = e.sharp;
    var levels = e.levels;
    final quad = (e.quad != null && _quadConvex(e.quad!))
        ? e.quad!
        : const [Offset(0, 0), Offset(1, 0), Offset(1, 1), Offset(0, 1)];
    AppLog.i('apply start turns=$turns angle=${angle.toStringAsFixed(1)} filter=${filter.name}');
    if (filter == ScanFilter.auto && levels == null) {
      levels = await autoLevelsOf(await File(src).readAsBytes());
    }
    final profile = await Store.qualityProfile(path);
    final safe = sp.getBool('apply_safe') ?? false;
    if (profile != null && safe && !allowSafeReceiptOutput) {
      throw Exception('حماية الذاكرة شغالة. افتح التعديل واختر الحفظ الآمن، أو أعد تشغيل التطبيق للمحاولة بالدقة العالية');
    }
    final decodeLimit = safe ? math.min(1400, getMaxSide(await Store.perfMode(), profile: profile)) : null;
    final swRender = Stopwatch()..start();
    final r = await _rotatedImage(src, turns, profile: profile, maxDecodeSide: decodeLimit);
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
    final maxSide = safe ? math.min(1400, getMaxSide(mode, profile: profile)) : getMaxSide(mode, profile: profile);
    final k = math.min(1.0, maxSide / math.max(ow, oh));
    ow *= k;
    oh *= k;
    final w = math.max(8, ow.round()), h = math.max(8, oh.round());
    final fullQuad = (quad[0] - const Offset(0, 0)).distance < 0.002 &&
        (quad[1] - const Offset(1, 0)).distance < 0.002 &&
        (quad[2] - const Offset(1, 1)).distance < 0.002 &&
        (quad[3] - const Offset(0, 1)).distance < 0.002;
    final needWarp = !fullQuad || angle.abs() > 0.05 || w != rw || h != rh;
    final clean = isCleanFilter(filter);
    final doTrim = clean && await Store.trimMargins();
    AppLog.i('apply pipeline ${w}x$h warp=$needWarp safe=$safe');
    final res = await compute(_renderPipelineJob, <String, dynamic>{
      'src': bd.buffer.asUint8List(bd.offsetInBytes, bd.lengthInBytes),
      'sw': rw,
      'sh': rh,
      'ow': w,
      'oh': h,
      'theta': angle * math.pi / 180,
      'h': _homography(pts),
      'm': clean
          ? editMatrix(ScanFilter.original, 0, 0)
          : editMatrix(filter, contrast, brightness, levels),
      'needWarp': needWarp,
      'clean': clean,
      'thermal': usesThermalClean(filter),
      'photocopy': filter == ScanFilter.receiptBw,
      'plain': filter == ScanFilter.clean,
      'postMatrix': (clean && (contrast != 0 || brightness != 0))
          ? editMatrix(filter, contrast, brightness)
          : null,
      'sk': effSharpness(filter, sharp),
      'doTrim': doTrim,
    });
    final rgba = res['rgba'] as Uint8List;
    final fw = res['w'] as int, fh = res['h'] as int;
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
      quality: await Store.jpegQuality(profile: profile),
      format: CompressFormat.jpeg,
    );
    final dir = (await Store.dir()).path;
    final nf = File('$dir/$prefix${DateTime.now().microsecondsSinceEpoch}.jpg');
    await nf.writeAsBytes(jpg);
    await logImageQuality('edited', jpg, profile: profile);
    AppLog.i('t render ${swRender.elapsedMilliseconds}ms');
    if (profile != null) await Store.setQualityProfile(nf.path, profile);
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
    if (safe) await sp.setBool('apply_safe', false);
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

bool _bytesEq(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// هل الملفين ليهم نفس المحتوى؟ (حجم + عينات من الأول والآخر — بتميّز نسختين كُتبوا من نفس البايتس)
Future<bool> _sameFileBytes(String a, String b) async {
  try {
    final fa = File(a), fb = File(b);
    final la = await fa.length(), lb = await fb.length();
    if (la != lb) return false;
    if (la == 0) return true;
    const n = 4096;
    final ra = await fa.open();
    final rb = await fb.open();
    try {
      if (!_bytesEq(await ra.read(n), await rb.read(n))) return false;
      if (la > n) {
        await ra.setPosition(math.max(0, la - n));
        await rb.setPosition(math.max(0, lb - n));
        if (!_bytesEq(await ra.read(n), await rb.read(n))) return false;
      }
      return true;
    } finally {
      await ra.close();
      await rb.close();
    }
  } catch (_) {
    return false;
  }
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
  // إعدادات تعديل متسجلة على الصورة بس لسه مش متنفذة على الملف نفسه (persistImage بتحفظ الفلتر من غير ما ترسمه).
  // لما تكون true: "تم" والتنقل لازم يرسموا حتى لو مفيش تغيير، وإلا الفلتر الظاهر في المعاينة مش بيتطبق.
  bool _seedUnbaked = false;
  bool busy = false;
  bool _quadTouched = false; // الموظف حدد الإطار بنفسه: القص التلقائي المتأخر ميلمسوش
  ui.Image? view; // نسخة خفيفة للعرض بس (بعد التدوير 90)
  int _viewGen = 0;
  bool _receiptQuality = false;
  bool _detailPreview = false;
  Timer? _detailTimer;
  ui.Image? cleaned; // نسخة منضّفة للمعاينة لما الفلتر من فلاتر الإيصال
  // النسخة المنضّفة المعروضة اتعملت بأي وضع تنضيف: 0 إيصال، 1 حراري باهت، 2 تنضيف بس
  int _cleanedMode = 0;
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
      icon: Icon(isFav ? Icons.star_rounded : Icons.star_border_rounded, size: 22),
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
            child: Icon(Icons.compare_rounded, color: _peek ? kAccent : null),
          ),
        ),
      );

  /// وضع التنضيف: 0 إيصال، 1 حراري، 2 تنضيف، 3 فوتوكوبي مستقل.
  static int _cleanModeOf(ScanFilter f) =>
      f == ScanFilter.clean ? 2 : (f == ScanFilter.receiptBw ? 3 : (usesThermalClean(f) ? 1 : 0));
  bool get _cleanReady =>
      isCleanFilter(filter) && cleaned != null && _cleanedMode == _cleanModeOf(filter);
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
    _detailTimer?.cancel();
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
      final c = await cleanUiImage(v, thermal: th, plain: filter == ScanFilter.clean,
          photocopy: filter == ScanFilter.receiptBw);
      if (!mounted || gen != _cleanGen || view != v) {
        c.dispose();
        return;
      }
      final old = cleaned;
      setState(() {
        cleaned = c;
        _cleanedMode = _cleanModeOf(filter);
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

  bool _automaticFilter = false;
  int _filterChoiceGen = 0;
  void _onFilter(ScanFilter f, {bool autoChosen = false}) {
    final gen = ++_filterChoiceGen;
    if (f == ScanFilter.adaptive) {
      final path = src;
      if (path == null) return;
      unawaited(resolveImageFilter(path).then((chosen) {
        if (!mounted || busy || gen != _filterChoiceGen) return;
        _onFilter(chosen, autoChosen: true);
        snack(context, 'اختيار تلقائي: ${kFilterLabels[chosen]}، تقدر تغيّره بإيدك');
      }));
      return;
    }
    setState(() {
      _automaticFilter = autoChosen;
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
      if (cleaned == null || _cleanedMode != _cleanModeOf(f)) {
        _makeClean();
      } else {
        _resharp();
      }
    } else {
      _resharp();
      if (f == ScanFilter.auto && levels == null) _makeLevels();
    }
  }

  // Do not decode a large preview on entry or on every pinch frame.
  // Upgrade only after a receipt zoom gesture finishes, at most once per editor.
  void _requestDetailPreview() {
    if (!_receiptQuality || _detailPreview || _zm < 1.4 || busy) return;
    _detailTimer?.cancel();
    _detailTimer = Timer(const Duration(milliseconds: 250), () {
      if (!mounted || busy || _zm < 1.4 || _detailPreview) return;
      _detailPreview = true;
      unawaited(_loadView());
    });
  }

  Future<void> _loadView({Uint8List? preloadedBytes}) async {
    final gen = ++_viewGen;
    try {
      final lite = await Store.perfMode() == PerfMode.lite;
      final raw = preloadedBytes ?? await File(src!).readAsBytes();
      int? previewWidth = lite ? 700 : 1200;
      if (_detailPreview && _receiptQuality) {
        final sz = await imageSize(raw);
        final limit = lite ? 1800 : 3200;
        final longest = math.max(sz.w, sz.h);
        previewWidth = longest > limit ? math.max(1, (sz.w * limit / longest).round()) : null;
      }
      final img = await decodeImage(raw, maxWidth: previewWidth);
      AppLog.i('preview detail=$_detailPreview ${img.width}x${img.height}');
      final baseAspect = img.height / img.width;
      final r = await _rotateUi(img, turns);
      if (!mounted || gen != _viewGen) {
        r.dispose();
        return;
      }
      final old = view;
      final oldClean = cleaned;
      setState(() {
        aspect ??= baseAspect;
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
      unawaited(_loadFavs()); // متوقفش فتح الصورة عشان قراءة المفضلة
      final hot = _takeHotBytes(widget.path);
      final base = File(Store.baseOf(widget.path));
      final s = await base.exists() ? base.path : widget.path;
      final e = await Store.editOf(widget.path);
      _receiptQuality = await Store.qualityProfile(widget.path) != null;
      if (!mounted) return;
      if (e != null) {
        // لو الصورة الحالية والنسخة الأصلية نفس البايتس: الفلتر متسجّل بس مش مرسوم على الملف لسه.
        final bf = File(Store.baseOf(widget.path));
        if (await Store.editPending(widget.path) ||
            (await bf.exists() && await _sameFileBytes(widget.path, bf.path))) {
          _seedUnbaked = true;
        }
        if (!mounted) return;
      }
      src = s;
      if (e == null && !await Store.enhanced(widget.path) &&
          await Store.filter() == ScanFilter.adaptive) {
        _automaticFilter = true;
        _seedUnbaked = true; // automatic preview must be baked even with no touch
        filter = await resolveImageFilter(s);
        if (!mounted) return;
      }
      if (e != null) {
        turns = e.turns;
        angle = e.angle;
        _automaticFilter = e.filter == ScanFilter.adaptive;
        filter = _automaticFilter ? await resolveImageFilter(s) : e.filter;
        contrast = e.contrast;
        brightness = e.brightness;
        sharp = e.sharp;
        levels = e.levels;
        if (e.quad != null && _quadConvex(e.quad!)) quad = List.of(e.quad!);
      }
      if ((e == null || e.quad == null) && _lastScanManual) {
        final live = widget.canRetake ? _shotQuad : null;
        _shotQuad = null;
        if (live != null && live.length == 4 && _quadConvex(live) && turns == 0) {
          quad = List.of(live); // اقتراح فوري جاهز من أول فريم
        }
      }
      await _loadView(preloadedBytes: hot);
      _sig0 = _sig();
      AppLog.i('editor view loaded');
      WidgetsBinding.instance.addPostFrameCallback((_) => AppLog.i('editor first frame'));
      if (mounted && (e == null || e.quad == null) && _lastScanManual) {
        if (!_quadFull()) {
          unawaited(_refineQuad());
        } else {
          unawaited(_auto(silent: true));
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
    if (_sig() == _sig0 && !_seedUnbaked) {
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
    if (!cancel) _requestDetailPreview();
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
    _requestDetailPreview();
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
              const Center(child: Icon(Icons.add_rounded, size: 22, color: Colors.redAccent)),
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
    if (!silent) setState(() => busy = true);
    try {
      final q = await detectDocQuad(src!);
      if (!mounted) return;
      if (silent && _quadTouched) return;
      if (q == null) {
        snack(context, 'حدود الإيصال مش واضحة. قرّب الورقة وخلي خلفيتها مختلفة، أو حدد الأركان بإيدك');
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
      if (mounted && !silent) setState(() => busy = false);
    }
  }

  Future<void> _apply({String? nav, bool all = false}) async {
    if (!_quadConvex(quad)) {
      snack(context, 'حدود القص متداخلة، عدّل الزوايا');
      return;
    }
    // مفيش أي تغيير من فتح الصفحة والفلتر متنفذ على الملف أصلاً: نرجّع الملف زي ما هو (من غير إعادة رسم أو ضغط)
    if (_sig() == _sig0 && !_seedUnbaked) {
      if (all) {
        final style =
            EditParams(filter: _automaticFilter ? ScanFilter.adaptive : filter, contrast: contrast, brightness: brightness, sharp: sharp);
        Navigator.pop(context, '$kAllPrefix|${style.encode()}|${widget.path}');
      } else {
        Navigator.pop(context, nav == null ? widget.path : '$kNavPrefix|$nav|${widget.path}');
      }
      return;
    }
    setState(() => busy = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool('apply_safe') == true &&
          await Store.qualityProfile(widget.path) != null) {
        if (!mounted) return;
        final proceed = await askYesNo(context, 'حماية الذاكرة',
            'آخر تعديل اتوقف. الحفظ الآمن هيقلل دقة النسخة إلى 1400 بكسل، والأصل هيفضل محفوظ. نكمل؟',
            yes: 'حفظ آمن', no: 'إلغاء');
        if (!proceed || !mounted) return;
      }
      final ep = EditParams(
          quad: quad,
          turns: turns,
          angle: angle,
          filter: filter,
          contrast: contrast,
          brightness: brightness,
          sharp: sharp,
          levels: levels);
      final np = await renderEditedPage(widget.path, widget.prefix, ep,
          allowSafeReceiptOutput: prefs.getBool('apply_safe') == true);
      if (mounted) {
        final style =
            EditParams(filter: _automaticFilter ? ScanFilter.adaptive : filter, contrast: contrast, brightness: brightness, sharp: sharp);
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
                icon: const Icon(Icons.auto_fix_high_rounded),
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
                icon: const Icon(Icons.crop_free_rounded),
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
              icon: const Icon(Icons.rotate_left_rounded),
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
              icon: const Icon(Icons.rotate_right_rounded),
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
            const Icon(Icons.straighten_rounded),
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
            Expanded(child: FilterBar(selected: filter, automaticChoice: _automaticFilter ? filter : null, onChanged: busy ? null : _onFilter)),
          ]),
          Row(children: [
            const Icon(Icons.brightness_6_rounded, size: 20),
            Expanded(
              child: Slider(
                value: brightness,
                min: -1,
                max: 1,
                onChanged: busy ? null : (v) => setState(() => brightness = v),
                onChangeEnd: busy ? null : (_) => _mark(),
              ),
            ),
            const Icon(Icons.contrast_rounded, size: 20),
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
              icon: const Icon(Icons.restart_alt_rounded),
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
            const Icon(Icons.deblur_rounded, size: 20),
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
            ActionChip(
              visualDensity: VisualDensity.compact,
              label: Text(sharp >= 0.5 ? 'وضوح ✓' : 'وضوح نص', style: const TextStyle(fontSize: 11)),
              onPressed: busy
                  ? null
                  : () {
                      setState(() => sharp = sharp >= 0.5 ? 0.0 : 0.6);
                      _resharp();
                      _mark();
                    },
            ),
            _favBtn(),
          ]),
        ]);
    }
  }

  Widget _barBtn(IconData i, String label, bool on, VoidCallback? onTap) {
    final col = on ? kAccent : Theme.of(context).colorScheme.onSurface;
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
          _pagerBtn(Icons.chevron_left_rounded, (busy || widget.pageIndex <= 0) ? null : () => _nav('prev')),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Text('${widget.pageIndex + 1}/${widget.pageCount}',
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
          ),
          _pagerBtn(last ? Icons.add_a_photo_rounded : Icons.chevron_right_rounded, busy ? null : () => _nav('next')),
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
            icon: const Icon(Icons.undo_rounded),
            onPressed: (busy || !_canUndo) ? null : _undo,
          ),
          IconButton(
            tooltip: 'إعادة',
            icon: const Icon(Icons.redo_rounded),
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
              icon: const Icon(Icons.delete_outline_rounded),
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
                            child: ClipRect(
                              clipBehavior: zoomed ? Clip.hardEdge : Clip.none,
                              child: Stack(children: [
                              Transform(
                                transform: Matrix4.translationValues(pan.dx, pan.dy, 0) *
                                    Matrix4.diagonal3Values(_zm, _zm, 1),
                                child: RepaintBoundary(child: _img(w, h)),
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
                                        const Icon(Icons.zoom_out_map_rounded, size: 16, color: Colors.white),
                                        const SizedBox(width: 4),
                                        Text('×${_zm.toStringAsFixed(1)}',
                                            style: const TextStyle(color: Colors.white, fontSize: 12)),
                                      ]),
                                    ),
                                  ),
                                ),
                            ])),
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
                      _barBtn(Icons.cameraswitch_rounded, 'إعادة أخذ', false,
                          busy ? null : () => Navigator.pop(context, kRetake)),
                    _barBtn(Icons.rotate_left_rounded, 'يسار', tab == 1, busy
                        ? null
                        : () => setState(() {
                              tab = 1;
                              turns = (turns + 3) % 4;
                              quad = _turnCcw(quad);
                              _loadView();
                            })),
                    _barBtn(Icons.auto_awesome_rounded, 'فلتر', tab == 2, () => setState(() => tab = 2)),
                    _barBtn(Icons.crop_rounded, 'قص', tab == 0, () => setState(() => tab = 0)),
                    InkResponse(
                      onTap: (busy || aspect == null) ? null : _apply,
                      radius: 40,
                      child: Container(
                        width: 78,
                        height: 46,
                        decoration: BoxDecoration(
                          color: kAccent,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: busy
                            ? Center(
                                child: SizedBox(
                                    width: 22,
                                    height: 22,
                                    child: CircularProgressIndicator(strokeWidth: 2.5, color: pal.onAccent)))
                            : Icon(Icons.check_rounded, color: pal.onAccent, size: 30),
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
  bool shouldRepaint(_ViewPainter o) =>
      !identical(o.img, img) ||
      o.box != box ||
      o.angle != angle ||
      o.focus != focus ||
      o.zoom != zoom ||
      !listEquals(o.m, m);
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
      ..color = pal.mid;
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
  late File _pdf = widget.pdf;
  int? _pdfBytes;
  bool _compressed = false;
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

  String _fmtBytes(int b) {
    if (b >= 1024 * 1024) return '${(b / (1024 * 1024)).toStringAsFixed(2)} MB';
    return '${(b / 1024).round()} KB';
  }

  Future<void> _load() async {
    try {
      final t = await receiptTag(1000, widget.session);
      final nts = <String>{};
      for (final x in widget.imgs) {
        if (await Store.noTag(x)) nts.add(x);
      }
      final sz = await _pdf.exists() ? await _pdf.length() : null;
      final isComp = false;
      if (!mounted) return;
      setState(() {
        tag = t;
        _pdfBytes = sz;
        _compressed = isComp;
        noTags
          ..clear()
          ..addAll(nts);
      });
    } catch (e, st) {
      AppLog.e('PdfResultScreen._load', e, st);
      if (mounted) snack(context, 'تعذر تجهيز المعاينة');
    }
  }

  Future<void> _compressNow() async {
    if (busy) return;
    if (!await askYesNo(context, 'إنشاء نسخة أصغر؟',
        'الأصل العالي الجودة هيفضل محفوظ. النسخة الأصغر ممكن تقلل وضوح الأرقام الصغيرة.',
        yes: 'نسخة أصغر', no: 'إلغاء')) return;
    if (!mounted) return;
    final before = _pdfBytes ?? 0;
    setState(() {
      busy = true;
      progress = '0/${widget.imgs.length}';
    });
    try {
      final f = await buildReceiptsPdf(widget.session, widget.imgs, forceCompact: true,
          onProgress: (d, t) {
        if (mounted) setState(() => progress = '$d/$t');
      });
      final after = await f.length();
      if (!mounted) return;
      setState(() {
        _pdf = f;
        _pdfBytes = after;
        _compressed = true;
      });
      snack(context,
          before > 0 ? 'اتضغط الملف من ${_fmtBytes(before)} إلى ${_fmtBytes(after)}' : 'اتعملت نسخة أصغر والأصل محفوظ');
    } catch (e) {
      if (mounted) snack(context, 'تعذر الضغط: ${errText(e)}');
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
          progress = null;
        });
      }
    }
  }

  Future<void> _useOriginalPdf() async {
    if (busy) return;
    final bytes = await widget.pdf.length();
    if (!mounted) return;
    setState(() {
      _pdf = widget.pdf;
      _pdfBytes = bytes;
      _compressed = false;
    });
  }

  void _markShared(String how) {
    HapticFeedback.mediumImpact();
    unawaited(Store.addLog(widget.session, 'receipts', '${widget.imgs.length} صفحة - $how'));
    if (!mounted) return;
    setState(() => shared = true);
    snack(context, 'اتبعت ✓ اضغط "تم" لما تخلص');
  }

  Future<void> _sharePdf() async {
    if (busy) return;
    final ok = await shareFiles(context, [_pdf.path]);
    if (ok) _markShared('PDF');
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
        final bytes = await composeReceiptImage(widget.imgs[i], widget.session,
            pageLabel: '${i + 1} / $n');
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
    if (ok) _markShared('صور');
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
    final sz = _pdfBytes;
    return Scaffold(
      appBar: AppBar(
        title: Text('معاينة الملف ($n صفحة)'),
        actions: [
          if (shared)
            TextButton.icon(
              onPressed: busy ? null : _done,
              icon: const Icon(Icons.check_rounded),
              label: const Text('تم'),
            ),
        ],
      ),
      body: Column(children: [
        if (sz != null)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            color: Theme.of(context).colorScheme.surfaceContainerHigh,
            child: Row(children: [
              const Icon(Icons.picture_as_pdf_rounded, size: 18, color: Colors.redAccent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'حجم الـ PDF: ${_fmtBytes(sz)}${n > 1 ? '  •  مرقّم تلقائياً (1 / $n)' : ''}',
                  style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                ),
              ),
              if (_compressed)
                TextButton(onPressed: busy ? null : _useOriginalPdf,
                    child: const Text('رجوع للأصل')),
              if (!_compressed && sz > 500 * 1024)
                TextButton.icon(
                  onPressed: busy ? null : _compressNow,
                  icon: const Icon(Icons.compress_rounded, size: 17),
                  label: const Text('نسخة أصغر'),
                ),
            ]),
          ),
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
                  icon: const Icon(Icons.picture_as_pdf_rounded),
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
                      : const Icon(Icons.image_rounded),
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
  final String? warning; // تنبيه جودة/اهتزاز فوري بعد اللقطة السريعة
  const A2RCamState({this.count = 0, this.thumb, this.close = false, this.warning});
}

class A2RCameraScreen extends StatefulWidget {
  final String title; // مكتوب تحت المعاينة (إيصالات / باتش)
  final bool receiptQuality;
  final bool single; // true: تقفل بعد أول صورة (الباتش)
  final int count;
  final String? thumb;
  final Future<A2RCamState?> Function(String path) onShot;
  /// للتصوير السريع المتتالي: بيقص ويحفظ الصورة مباشرة في الخلفية بدون فتح شاشة التعديل.
  final Future<A2RCamState?> Function(String path, List<Offset>? quad)? onFastShot;
  /// مسح آخر صورة اتلقطت من جوه الكاميرا مباشرة.
  final Future<A2RCamState?> Function()? onUndoLast;
  final Future<A2RCamState?> Function()? onGallery;
  const A2RCameraScreen({
    super.key,
    required this.title,
    required this.onShot,
    this.onFastShot,
    this.onUndoLast,
    this.onGallery,
    this.receiptQuality = false,
    this.single = false,
    this.count = 0,
    this.thumb,
  });
  @override
  State<A2RCameraScreen> createState() => _A2RCameraScreenState();
}

List<cam.ResolutionPreset> cameraFallbackPresets(cam.ResolutionPreset requested) {
  const order = [cam.ResolutionPreset.max, cam.ResolutionPreset.ultraHigh,
      cam.ResolutionPreset.veryHigh, cam.ResolutionPreset.high];
  final index = order.indexOf(requested);
  return index < 0 ? [requested] : order.sublist(index);
}

int nextDetectionInterval(int current, int processingMs) {
  // Reduce preview analysis work, never saved-photo quality, on busy phones.
  if (processingMs > current) return math.min(300, math.max(current + 20, processingMs));
  return current;
}

class _A2RCameraScreenState extends State<A2RCameraScreen> with WidgetsBindingObserver {
  cam.CameraController? _c;
  String? _err;
  bool _ready = false;
  bool _starting = false; // يمنع تشغيل الكاميرا مرتين في نفس الوقت
  bool _shooting = false;
  bool _shutterFlash = false; // وميض أبيض سريع عند الالتقاط في الوضع السريع
  String? _lastShot; // أبعاد آخر صورة اتصوّرت فعلاً (للتأكد من الدقة)
  bool _detailedCapture = false; // Explicit per-session opt-in, never a slower default.
  int _flash = 0; // 0 مقفول، 1 تلقائي، 2 فلاش، 3 كشاف
  bool _grid = false; // شبكة الأثلاث للمحاذاة
  bool _a4Frame = false; // إطار إرشادي A4 لتصوير شيت الإيصالات
  bool _fastMode = false; // وضع التصوير السريع المتتالي (للإيصالات)
  bool _autoCap = false; // التصوير التلقائي عند ثبات الورقة
  bool _lowLight = false; // تنبيه الإضاءة الضعيفة الحي
  bool _glare = false; // تنبيه اللمعة الحي (بقعة محروقة جوه الورقة)
  int _glareHits = 0;
  Offset? _meterAt; // آخر نقطة قياس إضاءة اتحطت على الورقة
  int _meterTs = 0;
  bool _aeAfLocked = false; // قفل الفوكس والإضاءة بالضغط المطوّل
  bool _warningCanUndo = true;
  String? _camWarning; // تنبيه الاهتزاز/الإضاءة الفوري بعد اللقطة السريعة
  Timer? _warnTimer;
  bool _showLevel = true; // ميزان الاستقامة (التوازي مع المكتب)
  bool _tiltFlat = false;
  double _tiltX = 0, _tiltY = 0;
  static const _hwChannel = MethodChannel('a2r/cam_hw');
  static const _tiltChannel = EventChannel('a2r/tilt');
  StreamSubscription<dynamic>? _tiltSub;
  late int _count = widget.count;
  String? _thumb;
  double _minZoom = 1, _maxZoom = 1, _zoom = 1, _zoom0 = 1;
  double _minExp = 0, _maxExp = 0, _exp = 0;
  bool _showExp = false;
  Offset? _focusAt;
  List<Offset>? _liveQuad; // التحديد التلقائي الحي فوق المعاينة
  List<Offset>? _stableRef; // مرجع الثبات للتصوير التلقائي
  int _stableHits = 0;
  int _lastAutoShot = 0;
  int _stableSince = 0;
  int _focusChangedAt = 0;
  int _liveEpoch = 0;
  bool _live = false, _liveBusy = false;
  final _LiveDetWorker _detWorker = _LiveDetWorker();
  int _lastLive = 0, _liveMiss = 0;
  int _liveIntervalMs = 85;
  bool _supportsFocusPoint = true;
  bool _supportsExposurePoint = true;
  Future<void> _saveQueue = Future.value();
  int _pendingCount = 0;

  bool get _canFast => widget.onFastShot != null && !widget.single;

  static const _flashIcons = [
    Icons.flash_off_rounded,
    Icons.flash_auto_rounded,
    Icons.flash_on_rounded,
    Icons.highlight_rounded
  ];
  static const _flashNames = ['الفلاش مقفول', 'فلاش تلقائي', 'فلاش', 'كشاف'];

  @override
  void initState() {
    super.initState();
    _thumb = widget.thumb;
    WidgetsBinding.instance.addObserver(this);
    SharedPreferences.getInstance().then((p) {
      _flash = p.getInt('camFlash') ?? 0;
      _grid = p.getBool('camGrid') ?? false;
      _a4Frame = p.getBool('camA4Frame') ?? false;
      _fastMode = _canFast && (p.getBool('camFastMode') ?? true);
      // التصوير التلقائي شغال افتراضيًا في كاميرا الباتش (لو الموظف قفله قبل كده بيفضل مقفول)
      _autoCap = p.getBool('camAutoCap') ?? widget.single;
      _showLevel = p.getBool('camLevel') ?? true;
      _setVolumeCapture(true);
      if (_showLevel) _startTilt();
      _start();
    }).catchError((Object e, StackTrace st) {
      AppLog.e('cam.prefs', e, st);
      _start();
    });
  }

  Future<void> _setVolumeCapture(bool on) async {
    try {
      if (on) {
        _hwChannel.setMethodCallHandler((call) async {
          if (call.method == 'volumeShot' && mounted) unawaited(_shot());
        });
      } else {
        _hwChannel.setMethodCallHandler(null);
      }
      await _hwChannel.invokeMethod<void>('setVolumeCapture', on);
    } catch (_) {}
  }

  void _startTilt() {
    _tiltSub?.cancel();
    _tiltSub = null;
    try {
      _tiltSub = _tiltChannel.receiveBroadcastStream().listen((ev) {
        if (!mounted || !_showLevel) return;
        if (ev is List && ev.length >= 3) {
          final ax = (ev[0] as num).toDouble();
          final ay = (ev[1] as num).toDouble();
          final az = (ev[2] as num).toDouble();
          final flat = az > 5.0; // الموبايل موجّه لتحت ناحية المكتب
          if (flat != _tiltFlat || (ax - _tiltX).abs() > 0.12 || (ay - _tiltY).abs() > 0.12) {
            setState(() {
              _tiltFlat = flat;
              _tiltX = ax;
              _tiltY = ay;
            });
          }
        }
      }, onError: (_) {});
    } catch (_) {}
  }

  void _stopTilt() {
    _tiltSub?.cancel();
    _tiltSub = null;
  }

  Future<void> _toggleLevel() async {
    HapticFeedback.selectionClick();
    setState(() {
      _showLevel = !_showLevel;
      if (!_showLevel) _tiltFlat = false;
    });
    if (_showLevel) {
      _startTilt();
    } else {
      _stopTilt();
    }
    try {
      (await SharedPreferences.getInstance()).setBool('camLevel', _showLevel);
    } catch (_) {}
  }

  Future<void> _toggleDetailedCapture() async {
    if (_shooting || _starting) return;
    if (!_detailedCapture && !await askYesNo(context, 'جودة أعلى لكاميرا A2R',
        'تصوير بأقصى دقة وحفظ حتى 3200 بكسل بجودة 92. ممكن يكون أبطأ أو يحتاج ذاكرة أكتر. الوضع السريع يفضل زي ما هو لو مش مفعّله.',
        yes: 'تفعيل الجودة الأعلى', no: 'إلغاء')) return;
    if (!mounted) return;
    setState(() => _detailedCapture = !_detailedCapture);
    await _start();
  }

  Future<void> _toggleA4Frame() async {
    HapticFeedback.selectionClick();
    setState(() => _a4Frame = !_a4Frame);
    try {
      (await SharedPreferences.getInstance()).setBool('camA4Frame', _a4Frame);
    } catch (_) {}
  }

  void _showCamWarning(String msg, {bool canUndo = true}) {
    _warnTimer?.cancel();
    HapticFeedback.vibrate();
    if (!mounted) return;
    setState(() {
      _camWarning = msg;
      _warningCanUndo = canUndo;
    });
    _warnTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _camWarning = null);
    });
  }

  @override
  void dispose() {
    _warnTimer?.cancel();
    _detWorker.dispose();
    _setVolumeCapture(false);
    _stopTilt();
    WidgetsBinding.instance.removeObserver(this);
    _c?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _setVolumeCapture(true);
      if (_showLevel) _startTilt();
      if (_c == null && !_starting) _start();
      return;
    }
    final c = _c;
    if (c == null) return;
    if (state == AppLifecycleState.inactive) {
      _setVolumeCapture(false);
      _stopTilt();
      _c = null;
      _live = false;
      _liveQuad = null;
      _aeAfLocked = false;
      _stableHits = 0;
      _stableRef = null;
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
      _aeAfLocked = false;
      _stableHits = 0;
      _stableRef = null;
      if (mounted) setState(() => _ready = false);
      await old?.dispose();
      final cams = await cam.availableCameras();
      if (cams.isEmpty) throw Exception('مفيش كاميرا على الجهاز');
      final back = cams.firstWhere((x) => x.lensDirection == cam.CameraLensDirection.back,
          orElse: () => cams.first);
      late final cam.ResolutionPreset preset;
      // أقصى دقة التقاط افتراضيًا لكل الكاميرات (إيصالات وباتش)؛ اختيار «دقة» من شاشة الكاميرا يكسب على الافتراضي.
      // الاسكنر والقص التلقائي شغالين على نفس الدقة دي في مسار الإيصالات أصلًا.
      if (gResLevel > 0) {
        preset = const [
          cam.ResolutionPreset.high,
          cam.ResolutionPreset.veryHigh,
          cam.ResolutionPreset.ultraHigh,
          cam.ResolutionPreset.max,
        ][(gResLevel - 1).clamp(0, 3)];
      } else {
        preset = cam.ResolutionPreset.max;
      }
      cam.CameraController? initialized;
      var actualPreset = preset;
      Object? lastStartError;
      for (final candidate in cameraFallbackPresets(preset)) {
        final trial = cam.CameraController(back, candidate,
            enableAudio: false,
            imageFormatGroup:
                Platform.isAndroid ? cam.ImageFormatGroup.yuv420 : cam.ImageFormatGroup.bgra8888);
        try {
          await trial.initialize();
          initialized = trial;
          actualPreset = candidate;
          break;
        } catch (e, st) {
          lastStartError = e;
          AppLog.e('cam.initialize.${candidate.name}', e, st);
          try { await trial.dispose(); } catch (_) {}
          // Permission failures cannot be fixed by trying another resolution.
          if (e is cam.CameraException && e.code.toLowerCase().contains('access')) rethrow;
        }
      }
      if (initialized == null) throw lastStartError ?? Exception('تعذر تشغيل الكاميرا');
      final c = initialized;
      _supportsFocusPoint = c.value.focusPointSupported;
      _meterAt = null;
      _meterTs = 0;
      _glare = false;
      _glareHits = 0;
      _supportsExposurePoint = c.value.exposurePointSupported;
      _liveIntervalMs = 85;
      if (actualPreset != preset) {
        AppLog.i('camera-adapt requested=${preset.name} actual=${actualPreset.name}');
        _showCamWarning('الموبايل مش قادر يشغّل الدقة المطلوبة. اشتغلنا بدقة أقل مدعومة، راجع الأرقام قبل الحفظ', canUndo: false);
      }
      _rememberDiagnostic('lastCameraDiagnostic', 'آخر تشغيل ناجح: مطلوب ${preset.name}، المستخدم ${actualPreset.name}\nمعاينة ${c.value.previewSize} (مش دقة الصورة المحفوظة)');
      AppLog.i('cam name=${back.name} lens=${back.lensDirection} sensor=${back.sensorOrientation} preset=$actualPreset requested=$preset preview=${c.value.previewSize} receipt=${widget.receiptQuality} detail=$_detailedCapture');
      try {
        await c.lockCaptureOrientation(DeviceOrientation.portraitUp);
      } catch (_) {}
      await _applyFlash(c);
      // A missing focus-point feature must not skip exposure or camera startup.
      try { await c.setFocusMode(cam.FocusMode.auto); } catch (_) {}
      try { await c.setExposureMode(cam.ExposureMode.auto); } catch (_) {}
      if (_supportsFocusPoint) {
        try { await c.setFocusPoint(const Offset(0.5, 0.5)); } catch (_) { _supportsFocusPoint = false; }
      }
      if (_supportsExposurePoint) {
        try { await c.setExposurePoint(const Offset(0.5, 0.5)); } catch (_) { _supportsExposurePoint = false; }
      }
      AppLog.i('camera-cap focusPoint=$_supportsFocusPoint exposurePoint=$_supportsExposurePoint');
      _focusChangedAt = DateTime.now().millisecondsSinceEpoch;
      try {
        _minZoom = await c.getMinZoomLevel();
        _maxZoom = math.max(_minZoom, math.min(await c.getMaxZoomLevel(), 6.0));
      } catch (_) {
        _minZoom = 1;
        _maxZoom = 1;
      }
      _zoom = 1.0.clamp(_minZoom, _maxZoom).toDouble();
      try {
        await c.setZoomLevel(_zoom);
      } catch (_) {}
      try {
        _minExp = await c.getMinExposureOffset();
        _maxExp = await c.getMaxExposureOffset();
        _exp = 0;
      } catch (_) {
        _minExp = 0;
        _maxExp = 0;
        _exp = 0;
      }
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
      _stableHits = 0;
      _stableRef = null;
      await _detWorker.start();
      await c.startImageStream(_onFrame);
      _live = true;
    } catch (e, st) {
      AppLog.e('cam.live', e, st);
    }
  }

  Future<void> _stopLive() async {
    final c = _c;
    _live = false;
    _liveEpoch++;
    _liveQuad = null;
    _stableSince = 0;
    _stableHits = 0;
    _stableRef = null;
    if (c == null) return;
    try {
      if (c.value.isStreamingImages) await c.stopImageStream();
    } catch (_) {}
  }

  double _maxQuadDelta(List<Offset> a, List<Offset> b) {
    var mx = 0.0;
    for (var i = 0; i < 4; i++) {
      final d = (a[i] - b[i]).distance;
      if (d > mx) mx = d;
    }
    return mx;
  }

  void _onFrame(cam.CameraImage f) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!_live || _liveBusy || _shooting || now - _lastLive < _liveIntervalMs || !mounted) return;
    _liveBusy = true;
    _lastLive = now;
    final ex = _liveExtract(f, _c?.description.sensorOrientation ?? 90);
    if (ex == null) {
      _liveBusy = false;
      return;
    }
    final isLow = ex.meanY < 72 && _flash == 0;
    final hasDetail = _frameHasDetail(ex.feat, ex.w, ex.h);
    final epoch = _liveEpoch;
    final swLive = Stopwatch()..start();
    _detWorker.detect(ex.feat, ex.w, ex.h, autoCropMode).then((raw) {
      if (!mounted || !_live || epoch != _liveEpoch) return;
      List<Offset>? q;
      if (raw != null && raw.length == 8) {
        q = [for (var i = 0; i < 8; i += 2) Offset(raw[i], raw[i + 1])];
      }
      final prev = _liveQuad;
      var shouldAutoShoot = false;
      var glareNow = false;
      if (q == null) {
        _glareHits = 0;
        if (++_liveMiss >= 2) {
          _stableHits = 0;
          _stableRef = null;
        }
        _stableSince = 0;
      } else {
        _liveMiss = 0;
        // Test stability on raw corners, not a smoothed overlay that hides motion.
        final rawQ = List<Offset>.of(q);
        // لمعة: لازم تظهر في كذا فريم ورا بعض عشان التنبيه ميرعشش
        final g = _liveGlareFrac(ex.feat, ex.w, ex.h, rawQ) >= 0.015;
        _glareHits = g ? math.min(_glareHits + 1, 6) : math.max(_glareHits - 1, 0);
        glareNow = _glareHits >= 3 || (_glare && _glareHits > 0);
        _meterOnPaper(rawQ, now);
        if (_autoCap && !_shooting && hasDetail && !isLow && !glareNow &&
            now - _focusChangedAt >= 700) {
          final ts = DateTime.now().millisecondsSinceEpoch;
          if (ts - _lastAutoShot > 1100) {
            if (_stableRef != null && _maxQuadDelta(_stableRef!, rawQ) < 0.018) {
              _stableHits++;
              if (_stableHits >= 4 && ts - _stableSince >= 450) {
                _stableHits = 0;
                _stableRef = null;
                _lastAutoShot = ts;
                shouldAutoShoot = true;
              }
            } else {
              _stableRef = rawQ;
              _stableSince = ts;
              _stableHits = 1;
            }
          }
        } else {
          _stableHits = 0;
          _stableSince = 0;
          _stableRef = null;
        }
      }
      if (q != null && prev != null) {
        q = [for (var i = 0; i < 4; i++) Offset.lerp(prev[i], q[i], 0.65)!];
      }
      setState(() {
        _liveQuad = q;
        _lowLight = isLow;
        _glare = glareNow;
      });
      if (shouldAutoShoot) {
        unawaited(_shot());
      }
    }).catchError((Object e, StackTrace st) {
      AppLog.e('cam.liveFrame', e, st);
    }).whenComplete(() {
      _liveIntervalMs = nextDetectionInterval(_liveIntervalMs, swLive.elapsedMilliseconds);
      _liveBusy = false;
    });
  }

  /// قياس الإضاءة على الورقة نفسها مش نص الشاشة: الإيصال الأبيض على مكتب غامق كان بيتحرق
  /// والطباعة الحرارية الباهتة بتختفي. بنحرّك نقطة القياس لنص الورقة (مش الفوكس) بهدوء.
  void _meterOnPaper(List<Offset> q, int now) {
    final c = _c;
    if (c == null || _aeAfLocked || !_supportsExposurePoint || _shooting) return;
    if (now - _meterTs < 1500) return;
    var cx = 0.0, cy = 0.0;
    for (final o in q) {
      cx += o.dx / 4;
      cy += o.dy / 4;
    }
    final at = Offset(cx.clamp(0.05, 0.95).toDouble(), cy.clamp(0.05, 0.95).toDouble());
    final last = _meterAt ?? const Offset(0.5, 0.5);
    if ((at - last).distance < 0.08) return;
    _meterAt = at;
    _meterTs = now;
    unawaited(c.setExposurePoint(at).catchError((_) {}));
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

  Future<void> _toggleFastMode() async {
    if (!_canFast) return;
    HapticFeedback.selectionClick();
    setState(() => _fastMode = !_fastMode);
    try {
      (await SharedPreferences.getInstance()).setBool('camFastMode', _fastMode);
    } catch (_) {}
    if (mounted) {
      snack(
          context,
          _fastMode
              ? 'التصوير السريع: يقص ويحفظ الإيصالات ورا بعض بدون توقف'
              : 'التعديل الفوري: يفتح التعديل بعد كل صورة');
    }
  }

  Future<void> _toggleAutoCap() async {
    HapticFeedback.selectionClick();
    setState(() {
      _autoCap = !_autoCap;
      _stableHits = 0;
      _stableRef = null;
    });
    try {
      (await SharedPreferences.getInstance()).setBool('camAutoCap', _autoCap);
    } catch (_) {}
    if (mounted) {
      snack(context,
          _autoCap ? 'التصوير التلقائي شغّال: ثبّت الموبايل على الورقة وهيصوّر لوحده' : 'التصوير التلقائي مقفول');
    }
  }

  Future<void> _setZoom(double z) async {
    final c = _c;
    if (c == null || !c.value.isInitialized) return;
    final clamped = z.clamp(_minZoom, _maxZoom).toDouble();
    HapticFeedback.selectionClick();
    _focusChangedAt = DateTime.now().millisecondsSinceEpoch;
    setState(() => _zoom = clamped);
    try {
      await c.setZoomLevel(clamped);
    } catch (_) {}
  }

  Future<void> _setExposure(double v) async {
    final c = _c;
    if (c == null || !c.value.isInitialized) return;
    final clamped = v.clamp(_minExp, _maxExp).toDouble();
    setState(() => _exp = clamped);
    try {
      await c.setExposureOffset(clamped);
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

  Future<void> _pickRes() async {
    HapticFeedback.selectionClick();
    if (widget.receiptQuality) {
      snack(context, 'إيصالات الدفع: تصوير بأقصى دقة وحفظ بجودة عالية. تصغير الملف من نسخة PDF أصغر فقط');
      return;
    }
    final cur = gResLevel;
    final v = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: const Color(0xFF111111),
      builder: (c) => Directionality(
        textDirection: TextDirection.rtl,
        child: SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('دقة التصوير',
                  style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
            ),
            if (_lastShot != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text('آخر صورة: $_lastShot بكسل',
                    style: const TextStyle(color: Colors.white54, fontSize: 12)),
              ),
            for (final o in _resOpts)
              ListTile(
                dense: true,
                leading: Icon(o.$1 == cur ? Icons.radio_button_checked : Icons.radio_button_off,
                    color: o.$1 == cur ? kAccent : Colors.white70),
                title: Text(o.$2, style: const TextStyle(color: Colors.white)),
                subtitle: Text(o.$3, style: const TextStyle(color: Colors.white54, fontSize: 11)),
                onTap: () => Navigator.pop(c, o.$1),
              ),
          ]),
        ),
      ),
    );
    if (v == null || v == cur) return;
    await Store.setResSetting(v);
    _detailedCapture = false; // Explicit resolution replaces the session detail mode.
    try {
      (await SharedPreferences.getInstance()).remove('camSlow');
    } catch (_) {}
    if (mounted) setState(() {});
    await _start();
  }

  Future<void> _finish() async {
    if (_shooting) return;
    if (_pendingCount > 0) {
      setState(() => _shooting = true);
      try {
        await _saveQueue;
      } finally {
        if (mounted) setState(() => _shooting = false);
      }
    }
    if (mounted) Navigator.pop(context);
  }

  Future<void> _undoLastShot() async {
    final fn = widget.onUndoLast;
    if (fn == null || _shooting || (_count <= 0 && _pendingCount <= 0)) return;
    HapticFeedback.mediumImpact();
    setState(() => _shooting = true);
    try {
      await _saveQueue;
      final st = await fn();
      if (!mounted) return;
      _warnTimer?.cancel();
      setState(() => _camWarning = null);
      _apply(st);
      snack(context, 'اتمسحت آخر صورة');
    } catch (e, st) {
      AppLog.e('cam.undoLast', e, st);
    } finally {
      if (mounted) setState(() => _shooting = false);
    }
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
    if (s.warning != null && s.warning!.isNotEmpty) {
      _showCamWarning(s.warning!);
    }
  }

  Future<void> _shot() async {
    final c = _c;
    if (c == null || !c.value.isInitialized || _shooting) return;
    setState(() {
      _shooting = true;
      _stableHits = 0;
      _stableRef = null;
    });
    try {
      HapticFeedback.mediumImpact();
      final lq = _liveQuad;
      final quadCopy = lq == null ? null : List<Offset>.of(lq);
      _shotQuad = null; // Live preview/stream and JPEG can have different sensor crops.
      final swShot = Stopwatch()..start();
      // فوكس على نص الورقة قبل اللقطة (مش في التصوير السريع عشان السرعة، ومش لو الموظف قافل الفوكس
      // أو لسه عامل فوكس بإيده). ده بيمنع إن الصورة تتاخد والفوكس على المكتب.
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      if (quadCopy != null && !(_fastMode && _canFast) && !_aeAfLocked && _supportsFocusPoint &&
          nowMs - _focusChangedAt > 2500) {
        var cx = 0.0, cy = 0.0;
        for (final o in quadCopy) {
          cx += o.dx / 4;
          cy += o.dy / 4;
        }
        try {
          _focusChangedAt = nowMs;
          await c.setFocusPoint(Offset(cx.clamp(0.05, 0.95).toDouble(), cy.clamp(0.05, 0.95).toDouble()));
          await Future<void>.delayed(const Duration(milliseconds: 550));
        } catch (_) {}
        if (!mounted || !identical(_c, c)) return;
      }
      await _stopLive();
      final x = await c.takePicture();
      if (_detailedCapture && !widget.receiptQuality) {
        _rememberCaptureProfile(x.path, ImageQualityProfile.detailedCapture);
      }
      final shotMs = swShot.elapsedMilliseconds;
      AppLog.i('t takePicture ${shotMs}ms');
      if (shotMs > 2500) {
        unawaited(SharedPreferences.getInstance()
            .then((p) => p.setBool('camSlow', true))
            .catchError((_) => false));
      }
      // وضع التصوير السريع: وميض أبيض + قص وحفظ متسلسل في الخلفية بدون توقيف المعاينة
      if (_fastMode && _canFast) {
        if (mounted) {
          setState(() {
            _shutterFlash = true;
            _pendingCount++;
          });
        }
        Future.delayed(const Duration(milliseconds: 110), () {
          if (mounted) setState(() => _shutterFlash = false);
        });
        _saveQueue = _saveQueue.then((_) async {
          try {
            final st = await widget.onFastShot!(x.path, quadCopy);
            _apply(st);
          } catch (e, st) {
            AppLog.e('cam.fastShot', e, st);
            if (mounted) snack(context, 'تعذر حفظ الصورة: ${errText(e)}');
          } finally {
            if (mounted) setState(() => _pendingCount = math.max(0, _pendingCount - 1));
          }
        });
        return;
      }
      unawaited(c.pausePreview().catchError((_) {})); // من غير ما نوقف الانتقال لشاشة التعديل
      final s = await widget.onShot(x.path);
      AppLog.i('t shot+edit total ${swShot.elapsedMilliseconds}ms');
      if (!mounted) return;
      if (s?.close != true) {
        try {
          await c.resumePreview();
        } catch (_) {}
      }
      if (widget.single && s == null) return;
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
      final x = await ImagePicker()
          .pickImage(source: ImageSource.camera); // الأصل من غير تصغير
      if (x == null || !mounted) return;
      if (_detailedCapture && !widget.receiptQuality) {
        _rememberCaptureProfile(x.path, ImageQualityProfile.detailedCapture);
      }
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

  /// قفل الفوكس والإضاءة بالضغط المطوّل (ممتاز لتصوير كذا إيصال من نفس المسافة).
  Future<void> _lockFocus(LongPressStartDetails d, Rect pvRect) async {
    final c = _c;
    if (c == null || !c.value.isInitialized) return;
    if (!pvRect.contains(d.localPosition)) return;
    final dx = ((d.localPosition.dx - pvRect.left) / pvRect.width).clamp(0.0, 1.0).toDouble();
    final dy = ((d.localPosition.dy - pvRect.top) / pvRect.height).clamp(0.0, 1.0).toDouble();
    HapticFeedback.heavyImpact();
    setState(() {
      _focusAt = d.localPosition;
      _aeAfLocked = true;
    });
    try {
      _focusChangedAt = DateTime.now().millisecondsSinceEpoch;
      final stamp = _focusChangedAt;
      await c.setFocusMode(cam.FocusMode.auto);
      if (_supportsFocusPoint) await c.setFocusPoint(Offset(dx, dy));
      if (_supportsExposurePoint) await c.setExposurePoint(Offset(dx, dy));
      await Future<void>.delayed(const Duration(milliseconds: 450));
      if (!mounted || !_aeAfLocked || _focusChangedAt != stamp || !identical(_c, c)) return;
      await c.setFocusMode(cam.FocusMode.locked);
      await c.setExposureMode(cam.ExposureMode.locked);
    } catch (_) {}
  }

  Future<void> _unlockFocus() async {
    final c = _c;
    HapticFeedback.selectionClick();
    setState(() {
      _aeAfLocked = false;
      _focusAt = null;
    });
    if (c == null || !c.value.isInitialized) return;
    try {
      await c.setFocusMode(cam.FocusMode.auto);
      await c.setExposureMode(cam.ExposureMode.auto);
    } catch (_) {}
  }

  /// إصلاح حساب نقطة التركيز نسبةً لمستطيل المعاينة الفعلي مش الشاشة كلها.
  Future<void> _tapFocus(TapDownDetails d, Rect pvRect) async {
    final c = _c;
    if (c == null || !c.value.isInitialized) return;
    if (!pvRect.contains(d.localPosition)) return;
    final dx = ((d.localPosition.dx - pvRect.left) / pvRect.width).clamp(0.0, 1.0).toDouble();
    final dy = ((d.localPosition.dy - pvRect.top) / pvRect.height).clamp(0.0, 1.0).toDouble();
    _focusChangedAt = DateTime.now().millisecondsSinceEpoch;
    _meterAt = Offset(dx, dy); // الموظف اختار نقطة بإيده: منحرّكهاش لوحدنا لفترة
    _meterTs = _focusChangedAt + 3500;
    final wasLocked = _aeAfLocked;
    setState(() {
      _focusAt = d.localPosition;
      _aeAfLocked = false;
    });
    try {
      if (wasLocked) {
        await c.setFocusMode(cam.FocusMode.auto);
        await c.setExposureMode(cam.ExposureMode.auto);
      }
      if (_supportsFocusPoint) await c.setFocusPoint(Offset(dx, dy));
      if (_supportsExposurePoint) await c.setExposurePoint(Offset(dx, dy));
    } catch (_) {}
    Future.delayed(const Duration(milliseconds: 900), () {
      if (mounted && !_aeAfLocked) setState(() => _focusAt = null);
    });
  }

  Widget _pill(IconData icon, String label, bool on, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: on ? kAccent.withValues(alpha: 0.9) : Colors.black54,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: on ? kAccent : Colors.white30),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 15, color: on ? pal.onAccent : Colors.white),
            const SizedBox(width: 4),
            Text(label,
                style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: on ? pal.onAccent : Colors.white)),
          ]),
        ),
      );

  Widget _zoomBar() {
    final presets = <double>[
      if (_minZoom <= 1.0 && _maxZoom >= 1.0) 1.0,
      if (_minZoom <= 1.5 && _maxZoom >= 1.5) 1.5,
      if (_minZoom <= 2.0 && _maxZoom >= 2.0) 2.0,
    ];
    if (presets.length < 2) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        for (final z in presets)
          GestureDetector(
            onTap: () => _setZoom(z),
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 2),
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: BoxDecoration(
                color: (_zoom - z).abs() < 0.15 ? kAccent : Colors.transparent,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Text(
                z == z.roundToDouble() ? '${z.toInt()}x' : '${z}x',
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.bold,
                  color: (_zoom - z).abs() < 0.15 ? pal.onAccent : Colors.white,
                ),
              ),
            ),
          ),
      ]),
    );
  }

  Widget _icon(IconData i, String label, VoidCallback? onTap, {bool on = false}) {
    final col = on ? kAccent : Colors.white;
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
    return Row(mainAxisSize: MainAxisSize.min, children: [
      GestureDetector(
        onTap: ((_count > 0 || _pendingCount > 0) && !_shooting) ? _finish : null,
        child: SizedBox(
          width: 60,
          height: 60,
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
                    ? Image.file(File(t),
                        fit: BoxFit.cover, cacheWidth: 160, errorBuilder: (_, __, ___) => const SizedBox())
                    : const Icon(Icons.photo_library_rounded, color: Colors.white38),
              ),
            ),
            if (_pendingCount > 0)
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.black45,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  alignment: Alignment.center,
                  child: const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  ),
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
      ),
      if (_count > 0 && widget.onUndoLast != null)
        Padding(
          padding: const EdgeInsets.only(left: 8),
          child: Tooltip(
            message: 'مسح آخر لقطة',
            child: InkResponse(
              onTap: _shooting ? null : _undoLastShot,
              radius: 22,
              child: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.red.withValues(alpha: 0.25),
                  border: Border.all(color: Colors.redAccent.withValues(alpha: 0.7)),
                ),
                child: const Icon(Icons.delete_outline_rounded, color: Colors.redAccent, size: 20),
              ),
            ),
          ),
        ),
    ]);
  }

  Widget _warningBanner() => Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: GestureDetector(
                      onTap: _warningCanUndo && widget.onUndoLast != null ? _undoLastShot : () => setState(() => _camWarning = null),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: Colors.redAccent.withValues(alpha: 0.92),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          const Icon(Icons.warning_amber_rounded, size: 15, color: Colors.white),
                          const SizedBox(width: 5),
                          Flexible(
                            child: Text(
                              _warningCanUndo && widget.onUndoLast != null ? '$_camWarning — اضغط لمسح اللقطة' : _camWarning!,
                              style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                            ),
                          ),
                        ]),
                      ),
                    ),
                  );

  Widget _preview() {
    if (_err != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.no_photography_rounded, color: Colors.white54, size: 48),
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
      final pvRect = Rect.fromLTWH(pvL, pvT, pvW, pvH);
      return GestureDetector(
        onTapDown: (d) => _tapFocus(d, pvRect),
        onLongPressStart: (d) => _lockFocus(d, pvRect),
        onScaleStart: (_) => _zoom0 = _zoom,
        onScaleUpdate: (d) async {
          if (d.pointerCount < 2) return;
          final z = (_zoom0 * d.scale).clamp(_minZoom, _maxZoom).toDouble();
          if ((z - _zoom).abs() < 0.02) return;
          _focusChangedAt = DateTime.now().millisecondsSinceEpoch;
          setState(() => _zoom = z);
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
          if (_grid)
            Positioned(
              left: pvL,
              top: pvT,
              width: pvW,
              height: pvH,
              child: const IgnorePointer(child: CustomPaint(painter: _GridPainter())),
            ),
          if (_a4Frame)
            Positioned(
              left: pvL,
              top: pvT,
              width: pvW,
              height: pvH,
              child: const IgnorePointer(child: CustomPaint(painter: _A4GuidePainter())),
            ),
          if (_showLevel && _tiltFlat)
            Positioned(
              left: pvL,
              top: pvT,
              width: pvW,
              height: pvH,
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _TiltLevelPainter(
                    _tiltX,
                    _tiltY,
                    math.sqrt(_tiltX * _tiltX + _tiltY * _tiltY) < 0.85,
                  ),
                ),
              ),
            ),
          if (_liveQuad != null)
            Positioned(
              left: pvL,
              top: pvT,
              width: pvW,
              height: pvH,
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _LiveQuadPainter(_liveQuad!, lockProgress: _autoCap ? (_stableHits / 4.0).clamp(0.0, 1.0) : 0),
                ),
              ),
            ),
          if (_shutterFlash)
            Positioned.fill(
              child: IgnorePointer(child: Container(color: Colors.white.withValues(alpha: 0.75))),
            ),
          if (_focusAt != null)
            Positioned(
              left: _focusAt!.dx - 30,
              top: _focusAt!.dy - 30,
              child: IgnorePointer(
                child: Container(
                  width: 60,
                  height: 60,
                  alignment: Alignment.topRight,
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    border: Border.all(color: _aeAfLocked ? Colors.amber : kAccent, width: 2),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: _aeAfLocked
                      ? const Icon(Icons.lock_rounded, size: 14, color: Colors.amber)
                      : null,
                ),
              ),
            ),
          // شريط التحكم العلوي: التصوير السريع + التلقائي + الميزان + إطار A4 + الإضاءة
          Positioned(
            top: 10,
            left: 10,
            right: 10,
            child: Directionality(
              textDirection: TextDirection.rtl,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  alignment: WrapAlignment.center,
                  children: [
                    if (!widget.receiptQuality)
                      _pill(Icons.high_quality_rounded,
                          _detailedCapture ? 'جودة أعلى ✓' : 'جودة أعلى (ممكن أبطأ)',
                          _detailedCapture, _toggleDetailedCapture),
                    if (_canFast)
                      _pill(Icons.bolt_rounded, _fastMode ? 'تصوير سريع' : 'تعديل فوري', _fastMode, _toggleFastMode),
                    _pill(Icons.hdr_auto_rounded, 'تلقائي', _autoCap, _toggleAutoCap),
                    _pill(Icons.screen_rotation_alt_rounded, 'ميزان', _showLevel, _toggleLevel),
                    _pill(Icons.crop_portrait_rounded, 'إطار A4', _a4Frame, _toggleA4Frame),
                    if (_maxExp > _minExp)
                      _pill(Icons.wb_sunny_rounded, 'إضاءة', _showExp || _exp.abs() > 0.05,
                          () => setState(() => _showExp = !_showExp)),
                  ],
                ),
                if (_aeAfLocked)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: GestureDetector(
                      onTap: _unlockFocus,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.amber.withValues(alpha: 0.9),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: const Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(Icons.lock_rounded, size: 14, color: Colors.black),
                          SizedBox(width: 4),
                          Text('الفوكس والإضاءة مقفولين — اضغط للإلغاء',
                              style: TextStyle(color: Colors.black, fontSize: 11, fontWeight: FontWeight.bold)),
                        ]),
                      ),
                    ),
                  ),
                if (_camWarning != null)
                  _warningBanner(),
                if (_glare && !_lowLight && _camWarning == null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: GestureDetector(
                      onTap: () async {
                        if (_c == null || _flash == 0) return;
                        setState(() => _flash = 0); // الكشاف/الفلاش أكتر سبب للمعة على الورق الحراري
                        await _applyFlash(_c!);
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.orange.withValues(alpha: 0.88),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          const Icon(Icons.wb_sunny_rounded, size: 14, color: Colors.black),
                          const SizedBox(width: 4),
                          Text(_flash == 0 ? 'في لمعة على الورقة — ميّل الموبايل شوية' : 'في لمعة على الورقة — اضغط لقفل الكشاف',
                              style: const TextStyle(color: Colors.black, fontSize: 11, fontWeight: FontWeight.bold)),
                        ]),
                      ),
                    ),
                  ),
                if (_lowLight && _camWarning == null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: GestureDetector(
                      onTap: () async {
                        if (_c == null) return;
                        setState(() => _flash = 3); // تشغيل الكشاف مباشرة
                        await _applyFlash(_c!);
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.orange.withValues(alpha: 0.88),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: const Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(Icons.highlight_rounded, size: 14, color: Colors.black),
                          SizedBox(width: 4),
                          Text('إضاءة ضعيفة — اضغط لتشغيل الكشاف',
                              style: TextStyle(color: Colors.black, fontSize: 11, fontWeight: FontWeight.bold)),
                        ]),
                      ),
                    ),
                  ),
              ]),
            ),
          ),
          // سلايدر الإضاءة الرأسي
          if (_showExp && _maxExp > _minExp)
            Positioned(
              right: 8,
              top: 76,
              bottom: 56,
              child: Container(
                width: 40,
                padding: const EdgeInsets.symmetric(vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Column(children: [
                  const Icon(Icons.brightness_high_rounded, color: Colors.white, size: 16),
                  Expanded(
                    child: RotatedBox(
                      quarterTurns: 3,
                      child: Slider(
                        value: _exp.clamp(_minExp, _maxExp).toDouble(),
                        min: _minExp,
                        max: _maxExp,
                        activeColor: kAccent,
                        onChanged: _setExposure,
                      ),
                    ),
                  ),
                  GestureDetector(
                    onTap: () => _setExposure(0),
                    child: const Text('0', style: TextStyle(color: Colors.white70, fontSize: 11)),
                  ),
                ]),
              ),
            ),
          // أزرار الزوم السريعة 1x / 1.5x / 2x
          Positioned(
            bottom: 10,
            child: _zoomBar(),
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
              child: Text(
                _autoCap && _stableHits > 0 ? 'ثبّت إيدك... جاري الالتقاط' : widget.title,
                style: TextStyle(
                    color: _autoCap && _stableHits > 0 ? Colors.greenAccent : kAccent,
                    fontSize: 15,
                    fontWeight: FontWeight.w600),
              ),
            ),
            // صف الأيقونات: إغلاق، فلاش، دقة، شبكة، معرض
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
              child: Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
                _icon(Icons.close_rounded, 'إغلاق', _finish),
                _icon(_flashIcons[_flash], 'فلاش', _cycleFlash, on: _flash != 0),
                _icon(Icons.high_quality_rounded, widget.receiptQuality ? 'دقة: إيصالات عالية' : (_detailedCapture ? 'دقة: أعلى' : 'دقة: ${resShort(gResLevel)}'), _pickRes, on: widget.receiptQuality || gResLevel > 0),
                _icon(Icons.grid_3x3_rounded, 'شبكة', _toggleGrid, on: _grid),
                if (widget.onGallery != null) _icon(Icons.photo_library_rounded, 'معرض', _gallery),
              ]),
            ),
            // صف التصوير: المصغّرة (+ مسح آخر لقطة)، الزر في المنتصف بالظبط، تم
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 18),
              child: Row(children: [
                Expanded(
                  child: Align(alignment: Alignment.centerLeft, child: _thumbBox()),
                ),
                GestureDetector(
                  onTap: _shot,
                  child: Container(
                    width: 78,
                    height: 78,
                    padding: const EdgeInsets.all(5),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                          color: _autoCap && _stableHits > 0 ? Colors.greenAccent : kAccent, width: 4),
                    ),
                    child: Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _shooting ? Colors.white54 : Colors.white,
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: (!widget.single && (_count > 0 || _pendingCount > 0))
                        ? InkResponse(
                            onTap: _shooting ? null : _finish,
                            radius: 36,
                            child: Container(
                              width: 64,
                              height: 48,
                              decoration: BoxDecoration(
                                  color: kAccent, borderRadius: BorderRadius.circular(10)),
                              child: Icon(Icons.check_rounded, color: pal.onAccent, size: 30),
                            ),
                          )
                        : const SizedBox(width: 64),
                  ),
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
  ScanFilter filter = ScanFilter.receipt;
  String? progress;
  final Set<String> noTags = {}; // إيصالات من غير ورقة
  final Set<String> kept = {}; // إيصالات متعلّم عليها "احتفظ بيها" (بتروح الأرشيف بعد الإرسال)
  final Map<String, String> _ocr = {}; // كاش نص الـ OCR في الجلسة (الدائم في Store)
  final _searchCtrl = TextEditingController();
  String _ocrProgress = '';
  bool _ocrRunning = false;

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

  /// تعليم إيصال "احتفظ بيها": بعد الإرسال وعدّي ١٢ ساعة يروح للأرشيف بدل ما يتمسح.
  Future<void> _toggleKeep(String path) async {
    final v = !kept.contains(path);
    await Store.setKept(path, v);
    if (!mounted) return;
    setState(() {
      if (v) {
        kept.add(path);
      } else {
        kept.remove(path);
      }
    });
    snack(context, v ? 'هتتحفظ في الأرشيف بعد الإرسال' : 'اتشالت من المحفوظات');
  }

  /// البحث في نص الإيصالات: بيقرأ OCR لأي إيصال متقريش (أول مرة بس) والنتايج بتظهر أول بأول.
  Future<void> _onSearchChanged() async {
    setState(() {});
    if (_searchCtrl.text.trim().isEmpty) {
      if (mounted) setState(() => _ocrProgress = '');
      return;
    }
    if (_ocrRunning) return;
    _ocrRunning = true;
    try {
      final all = List.of(imgs);
      var done = 0;
      for (final p in all) {
        if (!mounted || _searchCtrl.text.trim().isEmpty) return;
        if (_ocr.containsKey(p)) continue;
        final cached = await Store.ocrText(p);
        if (cached != null) {
          _ocr[p] = cached;
        } else {
          if (mounted) setState(() => _ocrProgress = 'بنقرأ نص الإيصالات… ${done + 1}/${all.length}');
          try {
            final t = (await readAllTextRows(p)).join('\n');
            _ocr[p] = t;
            await Store.setOcrText(p, t);
          } catch (e, st) {
            AppLog.e('receipts.ocr', e, st);
            _ocr[p] = '';
          }
        }
        done++;
        if (mounted) setState(() {});
      }
    } finally {
      _ocrRunning = false;
      if (mounted) setState(() => _ocrProgress = '');
    }
  }

  /// تصوير بطاقة: وش وضهر بالماسح، بيتركّبوا على ورقة واحدة وتتحفظ كإيصال عادي في القايمة.
  Future<void> _addIdCard() async {
    if (!await askYesNo(context, 'تصوير بطاقة',
        'هتصوّر وش البطاقة الأول، وبعدين ضهرها، وهيتركبوا في صفحة واحدة تتحفظ هنا.',
        yes: 'ابدأ', no: 'إلغاء')) {
      return;
    }
    final engine = await Store.scanEngineReceipts();
    final mode = engine == 2 ? ScannerMode.full : ScannerMode.base;
    if (!mounted) return;
    final front = await scanImages(context, 1, mode: mode, camFallback: true, profile: ImageQualityProfile.receipts);
    if (front.isEmpty || !mounted) return;
    if (!await askYesNo(context, 'اتصوّر الوش ✓', 'دلوقتي صوّر ضهر البطاقة.',
        yes: 'تصوير', no: 'إلغاء')) {
      return;
    }
    if (!mounted) return;
    final back = await scanImages(context, 1, mode: mode, camFallback: true, profile: ImageQualityProfile.receipts);
    if (back.isEmpty || !mounted) return;
    setState(() => busy = true);
    String? tmp;
    try {
      final bytes = await composeIdCard(front.first, back.first);
      final d = await Store.dir();
      tmp = '${d.path}/idcard_${DateTime.now().microsecondsSinceEpoch}.png';
      await File(tmp).writeAsBytes(bytes, flush: true);
      final saved = await persistImage(tmp, 'r_${DateTime.now().microsecondsSinceEpoch}.jpg',
          filter: ScanFilter.original, applyNow: false, profile: ImageQualityProfile.receipts);
      await Store.addToDraft(saved);
      // صفحة البطاقة جاهزة بخلفية بيضا: مفيش فلتر إيصال تلقائي عليها
      await Store.setEnhanced(saved, true);
      if (!mounted) return;
      setState(() {
        imgs.add(saved);
        built = null;
      });
      HapticFeedback.lightImpact();
      final idx = imgs.length - 1;
      final savedPath = imgs[idx];
      await _edit(idx, tab: 2);
      await _ensureReceiptFiltered(idx, savedPath); // هيتخطاها: البطاقة متعلّمة جاهزة
    } catch (e, st) {
      AppLog.e('receipts.idCard', e, st);
      if (mounted) snack(context, 'حصل خطأ: ${errText(e)}');
    } finally {
      if (tmp != null) await Store.del(tmp);
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final d = await Store.draft();
    final t = await receiptTag(1000, widget.session);
    final f = await Store.pdf();
    final used = await Store.pdfImgs();
    final fl = await Store.filter();
    final nts = <String>{};
    final kp = <String>{};
    for (final x in d) {
      if (await Store.noTag(x)) nts.add(x);
      if (await Store.isKept(x)) kp.add(x);
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
      kept
        ..clear()
        ..addAll(kp);
      imgs = d;
      tag = t;
      built = b;
      filter = fl;
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

  /// أول ما تفتح إيصالات الدفع وهي فاضية: اختار ماسح جوجل ولا كاميرا A2R ولا معرض.
  Future<void> _chooseSource() async {
    if (!mounted) return;
    final c = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.add_a_photo_rounded),
            title: const Text('كاميرا'),
            onTap: () => Navigator.pop(ctx, 'google'),
          ),
          ListTile(
            leading: const Icon(Icons.camera_rounded),
            title: const Text('كاميرا A2R'),
            onTap: () => Navigator.pop(ctx, 'a2r'),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_rounded),
            title: const Text('معرض'),
            onTap: () => Navigator.pop(ctx, 'gallery'),
          ),
          const SizedBox(height: 8),
        ]),
      ),
    );
    if (!mounted) return;
    switch (c) {
      case 'google':
        await Store.setScanEngineReceipts(2);
        await _addGoogle();
        // لو ماسح جوجل مش شغال على الموبايل ده، نكمل بكاميرا A2R تلقائياً
        if (_scannerFailed && mounted && imgs.isEmpty) await _addA2R();
        break;
      case 'a2r':
        await Store.setScanEngineReceipts(0);
        await _addA2R();
        break;
      case 'gallery':
        await _addGallery();
        break;
    }
  }

  A2RCamState _camState({bool close = false}) =>
      A2RCamState(count: imgs.length, thumb: imgs.isEmpty ? null : imgs.last, close: close);

  /// كاميرا التطبيق (شكل كام اسكنر): كل صورة بتتحفظ وتتفتح للتعديل، والكاميرا تفضل مفتوحة والعداد بيزيد.
  /// زرار "تصوير": بيلتزم بمحرك التصوير المختار (ماسح جوجل أو كاميرا A2R) من الإعدادات
  /// أو من اختيارك في أول مرة. ماسح جوجل بيصغّر الصورة الناتجة، فلو الأرقام الصغيرة بتضيع
  /// اختار كاميرا A2R.
  Future<void> _add() async {
    final engine = await Store.scanEngineReceipts();
    final perf = await Store.perfMode();
    if (!mounted) return;
    if (engine >= 1 && !_scannerFailed && perf != PerfMode.lite) {
      await _addGoogle(full: engine == 2);
      // لو الماسح فشل دلوقتي (مش متاح) نكمل بكاميرا A2R تلقائياً
      if (_scannerFailed && mounted) await _addA2R();
    } else {
      await _addA2R();
    }
  }

  /// لو الموظف خرج من شاشة التعديل بدون حفظ: بنطبّق الفلتر المختار على الصورة.
  Future<void> _ensureReceiptFiltered(int idx, String savedPath) async {
    if (!mounted || filter == ScanFilter.original || idx < 0 || idx >= imgs.length || imgs[idx] != savedPath) {
      return;
    }
    if (await Store.enhanced(savedPath)) return; // متحسّنة من ماسح جوجل الكامل: مفيش فلتر تاني
    try {
      final next = await renderEditedPage(savedPath, 'r_',
          await Store.editOf(savedPath) ?? EditParams(filter: filter));
      await Store.replaceInDraft(savedPath, next);
      if (mounted && idx < imgs.length && imgs[idx] == savedPath) {
        setState(() {
          imgs[idx] = next;
          built = null;
        });
      }
    } catch (e, st) {
      AppLog.e('receipts.lateFilter', e, st);
    }
  }

  /// ماسح جوجل الذكي: صورة واحدة مقصوصة جاهزة، بعدها شاشة التعديل، وبعدها نرجع لشاشة الإيصالات
  /// (لإنشاء الـ PDF أو إضافة صور تانية).
  Future<void> _addGoogle({bool full = false}) async {
    final paths = await scanImages(context, 1,
        mode: receiptScannerMode(filter,full), camFallback: true, profile: ImageQualityProfile.receipts);
    if (paths.isEmpty || !mounted) return;
    final manual = _lastScanManual;
    final enhanced = _lastScanEnhanced && !manual; // متحسّنة من جوجل: منطبّقش فلتر الإيصال عليها
    final start = imgs.length;
    await _saveAll(paths, quick: true, keepOriginal: !manual, preEnhanced: enhanced);
    _lastScanManual = manual;
    for (var i = start; i < imgs.length; i++) {
      if (!mounted) break;
      final savedPath = imgs[i];
      final retake = await _edit(i, tab: manual ? 0 : 2, fromCam: true);
      if (retake && mounted) {
        await _addGoogle(full: full); // إعادة أخذ
        break;
      }
      await _ensureReceiptFiltered(i, savedPath);
    }
  }

  /// كاميرا A2R: صورة واحدة، بعدها التعديل، ولما يخلص تقفل الكاميرا وترجع لشاشة الإيصالات
  /// (لإنشاء الـ PDF أو إضافة صور تانية).
  Future<void> _addA2R() async {
    if (!await ensureCamera(context)) return;
    if (!mounted) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => A2RCameraScreen(
          title: 'إيصالات الدفع',
          receiptQuality: true,
          single: false,
          count: imgs.length,
          thumb: imgs.isEmpty ? null : imgs.last,
          onShot: (p) async {
            _lastScanManual = true; // من غير قص: شاشة التعديل تحدد حدود الورقة تلقائياً
            final before = imgs.length;
            await _saveAll([p], quick: true); // من غير فلتر على الصورة الكاملة: شاشة التعديل بتطبّقه
            if (mounted && imgs.length > before) {
              final idx = imgs.length - 1;
              final savedPath = imgs[idx];
              final retake = await _edit(idx, tab: 2, fromCam: true);
              if (retake && mounted) return _camState(); // إعادة أخذ: الصفحة اتمسحت والكاميرا مفتوحة
              await _ensureReceiptFiltered(idx, savedPath);
            }
            return _camState(close: imgs.length > before);
          },
          // التصوير السريع المتتالي: قص تلقائي بالإطار المكتشف + فلتر الإيصال في الخلفية من غير فتح المحرر
          onFastShot: (p, quad) => _fastSave(p, quad),
          onUndoLast: _undoLastShot,
          onGallery: () async {
            final before = imgs.length;
            await _addGallery();
            return _camState(close: imgs.length > before);
          },
        ),
      ),
    );
  }

  /// لقطة سريعة: بتحفظ الصورة مقصوصة ومفلترة جاهزة على طول. الموظف يقدر يفتحها في المحرر بعدين لو عايز يظبطها.
  Future<A2RCamState?> _fastSave(String src, List<Offset>? quad) async {
    String? saved;
    try {
      saved = await persistImage(src, 'r_${DateTime.now().microsecondsSinceEpoch}.jpg',
          filter: ScanFilter.original, applyNow: false, profile: ImageQualityProfile.receipts);
      var path = saved;
      final stillQuad = await detectDocQuad(saved);
      if (stillQuad != null || filter != ScanFilter.original) {
        path = await renderEditedPage(saved, 'r_', EditParams(quad: stillQuad, filter: filter));
        await Store.del(saved);
        saved = null;
      }
      await Store.addToDraft(path);
      if (mounted) {
        setState(() {
          imgs.add(path);
          built = null;
        });
      }
      final warn = stillQuad == null
          ? 'حدود الإيصال مش واضحة. الصورة كاملة محفوظة، افتح القص وحدد الأركان بإيدك'
          : await qualityWarning(path);
      return A2RCamState(count: imgs.length, thumb: path, warning: warn);
    } catch (e, st) {
      AppLog.e('receipts.fastSave', e, st);
      if (saved != null) await Store.del(saved);
      if (mounted) snack(context, 'حصل خطأ: ${errText(e)}');
      return null;
    }
  }

  /// مسح آخر لقطة من جوه الكاميرا (في وضع التصوير السريع).
  Future<A2RCamState?> _undoLastShot() async {
    if (imgs.isEmpty) return _camState();
    final p = imgs.last;
    if (mounted) {
      setState(() {
        imgs.removeLast();
        built = null;
      });
    }
    await Store.unlistFromDraft(p);
    await Store.del(p);
    return _camState();
  }

  /// من المعرض: منتقي الصور بتاع النظام مباشرة وتقدر تحدد أكتر من صورة.
  /// كل صورة بتتحفظ الأول، وبعدين شاشة التعديل بتفتح لكل واحدة (ارجع لتتخطاها وتفضل محفوظة).
  Future<void> _addGallery() async {
    await markPickTarget('receipts');
    List<XFile> xs;
    try {
      xs = await ImagePicker().pickMultiImage(); // الأصل من غير تصغير أو إعادة ضغط
    } catch (e, st) {
      AppLog.e('_addGallery', e, st);
      if (mounted) snack(context, 'تعذر فتح المعرض');
      return;
    }
    if (xs.isEmpty || !mounted) return;
    _lastScanManual = true; // صور من غير قص: شاشة التعديل تحدد حدود الورقة تلقائياً
    final start = imgs.length;
    await _saveAll(xs.map((e) => e.path).toList(), quick: true);
    for (var i = start; i < imgs.length; i++) {
      if (!mounted) break;
      final savedPath = imgs[i];
      await _edit(i, tab: 2);
      await _ensureReceiptFiltered(i, savedPath);
    }
  }

  Future<void> _saveAll(List<String> r,
      {bool quick = false, bool keepOriginal = false, bool preEnhanced = false}) async {
    setState(() => busy = true);
    var added = 0;
    try {
      for (final p in r) {
        final saved = await persistImage(
            p, 'r_${DateTime.now().microsecondsSinceEpoch}.jpg',
            filter: preEnhanced ? ScanFilter.original : filter,
            applyNow: !quick,
            keepOriginal: keepOriginal, profile: ImageQualityProfile.receipts);
        await Store.addToDraft(saved);
        if (preEnhanced) await Store.setEnhanced(saved, true);
        imgs.add(saved);
        added++;
      }
      built = null;
      HapticFeedback.lightImpact();
      if (!quick && imgs.isNotEmpty) {
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
    if (!await preSendCheckReceipts(context, widget.session, imgs)) return;
    if (!mounted) return;
    await _create();
    if (!mounted || built == null) return;
    await _send(check: false);
  }

  Future<void> _send({bool check = true}) async {
    final f = built;
    if (f == null) return;
    if (check && !await preSendCheckReceipts(context, widget.session, imgs)) return;
    if (!mounted) return;
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
        if (out == kRetake) {
          await Store.archivePath(old); // cam: إعادة أخذ مبتمسحش الصورة، بتروح للأرشيف
        } else {
          await Store.del(old);
        }
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

  Widget _item(int i) => _card(imgs[i], i, false);

  Widget _card(String path, int i, bool searching) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      shape: kCardShape,
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
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
          child: Column(children: [
            Row(children: [
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
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('اضغط للمعاينة', style: TextStyle(color: Colors.grey)),
                ]),
              ),
              if (!searching)
                ReorderableDragStartListener(
                    index: i,
                    child: const Padding(
                        padding: EdgeInsets.all(8), child: Icon(Icons.drag_handle_rounded))),
            ]),
            Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
              IconButton(
                  tooltip: 'استخراج النص',
                  icon: const Icon(Icons.text_snippet_outlined),
                  onPressed: busy ? null : () => showOcrTextSheet(context, path)),
              IconButton(
                  tooltip: noTags.contains(path) ? 'إظهار الورقة' : 'إخفاء الورقة',
                  icon: Icon(noTags.contains(path)
                      ? Icons.label_off_rounded
                      : Icons.label_outline_rounded),
                  onPressed: busy ? null : () => _toggleTag(path)),
              IconButton(
                  tooltip: 'تعديل',
                  icon: const Icon(Icons.tune_rounded),
                  onPressed: busy ? null : () => _edit(i)),
              IconButton(
                  tooltip: 'مسح',
                  icon: const Icon(Icons.delete_outline_rounded, color: Colors.red),
                  onPressed: (busy && progress != null) ? null : () => _remove(i)), // cam: المسح مش بيتعطل بسبب حفظ صورة جديدة
            ]),
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
                  : Column(children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                        child: TextField(
                          controller: _searchCtrl,
                          decoration: InputDecoration(
                            isDense: true,
                            prefixIcon: const Icon(Icons.search_rounded),
                            hintText: 'ابحث في نص الإيصالات (رقم، اسم، مبلغ)',
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                            suffixIcon: _searchCtrl.text.isEmpty
                                ? null
                                : IconButton(
                                    icon: const Icon(Icons.close_rounded),
                                    onPressed: () {
                                      _searchCtrl.clear();
                                      setState(() => _ocrProgress = '');
                                    }),
                          ),
                          onChanged: (_) => _onSearchChanged(),
                        ),
                      ),
                      if (_ocrProgress.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                          child: Row(children: [
                            const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2)),
                            const SizedBox(width: 8),
                            Expanded(
                                child:
                                    Text(_ocrProgress, style: const TextStyle(fontSize: 12))),
                          ]),
                        ),
                      Expanded(
                        child: _searchCtrl.text.trim().isEmpty
                            ? ReorderableListView.builder(
                                padding: const EdgeInsets.all(12),
                                buildDefaultDragHandles: false,
                                itemCount: imgs.length,
                                onReorder: _reorder,
                                itemBuilder: (_, i) => _item(i),
                              )
                            : Builder(builder: (_) {
                                final q = _searchCtrl.text.trim().toLowerCase();
                                final shown = [
                                  for (final p in imgs)
                                    if ((_ocr[p] ?? '').toLowerCase().contains(q)) p
                                ];
                                if (shown.isEmpty) {
                                  return const Center(
                                      child: Text('مفيش إيصال فيه النص ده',
                                          style:
                                              TextStyle(fontSize: 15, color: Colors.grey)));
                                }
                                return ListView.builder(
                                  padding: const EdgeInsets.all(12),
                                  itemCount: shown.length,
                                  itemBuilder: (_, i) =>
                                      _card(shown[i], imgs.indexOf(shown[i]), true),
                                );
                              }),
                      ),
                    ]),
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
              if (imgs.isNotEmpty) ...[
                const SizedBox(height: 6),
                SizedBox(
                  width: double.infinity,
                  height: 42,
                  child: OutlinedButton.icon(
                    onPressed: busy
                        ? null
                        : () => _applyToAll(EditParams(filter: filter), ''),
                    icon: const Icon(Icons.auto_fix_high_rounded, size: 18),
                    label: Text(
                        'تطبيق فلتر "${kFilterLabels[filter] ?? filter.name}" على كل الصور (${imgs.length})'),
                  ),
                ),
              ],
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: busy ? null : _add,
                    icon: const Icon(Icons.add_a_photo_rounded),
                    label: const Text('تصوير'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: busy ? null : _addGallery,
                    icon: const Icon(Icons.photo_library_rounded),
                    label: const Text('من المعرض'),
                  ),
                ),
              ]),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                height: 42,
                child: OutlinedButton.icon(
                  onPressed: busy ? null : _addIdCard,
                  icon: const Icon(Icons.badge_outlined, size: 18),
                  label: const Text('تصوير بطاقة (وش وضهر في صفحة واحدة)'),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: FilledButton.icon(
                  onPressed: (busy || imgs.isEmpty) ? null : (built == null ? _createAndSend : _send),
                  icon: busy
                      ? const SizedBox(
                          width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : Icon(built == null ? Icons.picture_as_pdf_rounded : Icons.visibility_rounded),
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


// =====================================================================
//  سجل الإرسال
// =====================================================================

// =====================================================================
//  الأرشيف (الصور المحفوظة من المسح التلقائي)
// =====================================================================

class ArchiveScreen extends StatefulWidget {
  const ArchiveScreen({super.key});
  @override
  State<ArchiveScreen> createState() => _ArchiveScreenState();
}

class _ArchiveScreenState extends State<ArchiveScreen> {
  List<String> imgs = [];
  bool loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final l = await Store.archive();
    // الأحدث الأول (بتاريخ تعديل الملف)
    l.sort((a, b) {
      try {
        return File(b).lastModifiedSync().compareTo(File(a).lastModifiedSync());
      } catch (_) {
        return 0;
      }
    });
    if (!mounted) return;
    setState(() {
      imgs = l;
      loaded = true;
    });
  }

  Future<void> _remove(String path) async {
    if (!await askYesNo(context, 'مسح من الأرشيف؟', 'الصورة هتتمسح نهائياً من التطبيق.',
        yes: 'امسح', no: 'إلغاء')) {
      return;
    }
    await Store.unarchive(path);
    if (!mounted) return;
    setState(() => imgs.remove(path));
  }

  String _dateOf(String path) {
    try {
      final t = File(path).lastModifiedSync();
      final m = t.month.toString().padLeft(2, '0'), d = t.day.toString().padLeft(2, '0');
      return '${t.year}-$m-$d';
    } catch (_) {
      return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('الأرشيف (${imgs.length})')),
      body: !loaded
          ? const Center(child: CircularProgressIndicator())
          : imgs.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                        'مفيش حاجة محفوظة لسه.\nالصور والملفات اللي بتتبدّل أو بتتبعت بتتحفظ هنا، وبتتمسح بإيدك بس.',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 15)),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: imgs.length,
                  itemBuilder: (_, i) {
                    final path = imgs[i];
                    return Card(
                      shape: kCardShape,
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      child: ListTile(
                        leading: path.toLowerCase().endsWith('.pdf')
                            ? const SizedBox(
                                width: 48, height: 64, child: Icon(Icons.picture_as_pdf_rounded, size: 34))
                            : ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Image.file(File(path),
                                    width: 48, height: 64, fit: BoxFit.cover, cacheWidth: 150),
                              ),
                        title: Text(path.toLowerCase().endsWith('.pdf')
                            ? (path.split('/').last.startsWith('sent_')
                                ? 'ملف PDF متبعت\n${_dateOf(path)}'
                                : 'ملف PDF\n${_dateOf(path)}')
                            : 'محفوظ\n${_dateOf(path)}'),
                        subtitle: const Text('اضغط للمعاينة'),
                        onTap: () => path.toLowerCase().endsWith('.pdf')
                            ? OpenFilex.open(path)
                            : Navigator.push(
                                context,
                                MaterialPageRoute(
                                    builder: (_) => ZoomPage(child: Image.file(File(path))))),
                        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                          if (!path.toLowerCase().endsWith('.pdf'))
                            IconButton(
                                tooltip: 'استخراج النص',
                                icon: const Icon(Icons.text_snippet_outlined),
                                onPressed: () => showOcrTextSheet(context, path)),
                          IconButton(
                              tooltip: 'مشاركة',
                              icon: const Icon(Icons.share_rounded),
                              onPressed: () => shareFiles(context, [path])),
                          IconButton(
                              tooltip: 'مسح',
                              icon: const Icon(Icons.delete_outline_rounded, color: Colors.red),
                              onPressed: () => _remove(path)),
                        ]),
                      ),
                    );
                  },
                ),
    );
  }
}

class SendLogEntry {
  final DateTime time;
  final String kind; // batch | receipts
  final String name, unit, detail;
  final String? building;
  const SendLogEntry({
    required this.time,
    required this.kind,
    required this.name,
    required this.unit,
    required this.detail,
    this.building,
  });

  Map<String, dynamic> toJson() => {
        't': time.millisecondsSinceEpoch,
        'k': kind,
        'n': name,
        'u': unit,
        'b': building,
        'd': detail,
      };

  factory SendLogEntry.fromJson(Map<String, dynamic> j) => SendLogEntry(
        time: DateTime.fromMillisecondsSinceEpoch((j['t'] as num).toInt()),
        kind: j['k'] as String,
        name: j['n'] as String,
        unit: j['u'] as String,
        building: j['b'] as String?,
        detail: (j['d'] as String?) ?? '',
      );
}

class SendLogScreen extends StatefulWidget {
  const SendLogScreen({super.key});
  @override
  State<SendLogScreen> createState() => _SendLogScreenState();
}

class _SendLogScreenState extends State<SendLogScreen> {
  List<SendLogEntry>? log;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final l = await Store.readLog();
    if (!mounted) return;
    setState(() => log = l);
  }

  Future<void> _clear() async {
    if (!await askYesNo(context, 'مسح السجل؟',
        'سجل الإرسال كله هيتمسح (الملفات نفسها مش هتتأثر).',
        yes: 'امسح', no: 'إلغاء')) {
      return;
    }
    await Store.clearLog();
    await _load();
  }

  String _time(DateTime t) {
    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    return '$h:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'ص' : 'م'}';
  }

  String _day(DateTime t) {
    final n = DateTime.now();
    final diff = DateTime(n.year, n.month, n.day).difference(DateTime(t.year, t.month, t.day)).inDays;
    if (diff == 0) return 'النهارده';
    if (diff == 1) return 'امبارح';
    return '${t.day.toString().padLeft(2, '0')}/${t.month.toString().padLeft(2, '0')}/${t.year}';
  }

  @override
  Widget build(BuildContext context) {
    final l = log;
    final cs = Theme.of(context).colorScheme;
    Widget body;
    if (l == null) {
      body = const Center(child: CircularProgressIndicator());
    } else if (l.isEmpty) {
      body = const Center(child: Text('لسه مفيش حاجة اتبعتت', style: TextStyle(fontSize: 16)));
    } else {
      final counts = <String, List<int>>{};
      for (final e in l) {
        counts.putIfAbsent(_day(e.time), () => [0, 0])[e.kind == 'batch' ? 0 : 1]++;
      }
      final rows = <Object>[];
      String? last;
      for (final e in l) {
        final d = _day(e.time);
        if (d != last) {
          last = d;
          rows.add(d);
        }
        rows.add(e);
      }
      body = ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: rows.length,
        itemBuilder: (_, i) {
          final r = rows[i];
          if (r is String) {
            final c = counts[r]!;
            return Padding(
              padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
              child: Text('$r  -  ${c[0]} باتش  -  ${c[1]} إرسال إيصالات',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
            );
          }
          final e = r as SendLogEntry;
          final isBatch = e.kind == 'batch';
          return Card(
            shape: kCardShape,
            margin: const EdgeInsets.symmetric(vertical: 4),
            child: ListTile(
              isThreeLine: true,
              leading: CircleAvatar(
                backgroundColor: cs.primary.withAlpha(40),
                child: Icon(isBatch ? Icons.receipt_long_rounded : Icons.payments_rounded,
                    color: cs.primary),
              ),
              title: Text(isBatch ? 'الباتش' : 'إيصالات الدفع',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text(
                  '${e.unit}${e.building == null ? '' : ' - ${e.building}'}\n${e.name}${e.detail.isEmpty ? '' : '\n${e.detail}'}'),
              trailing: Text(_time(e.time), style: const TextStyle(fontSize: 12, color: Colors.grey)),
            ),
          );
        },
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('سجل الإرسال'),
        actions: [
          if (l != null && l.isNotEmpty)
            IconButton(
                tooltip: 'مسح السجل',
                icon: const Icon(Icons.delete_sweep_rounded),
                onPressed: _clear),
        ],
      ),
      body: body,
    );
  }
}

// ===================== سكانر مستقل (فرع cam) =====================
/// أوضاع السكانر: مستند (صفحة)، متتابع (صفحات)، بطاقة (وش وضهر على A4 واحدة).
class ScannerScreen extends StatefulWidget {
  /// autoStart: الضغط على كارت «سكانر» يفتح الكاميرا على طول (لو مفيش صفحات محفوظة).
  final bool autoStart;
  const ScannerScreen({super.key, this.autoStart = false});
  @override
  State<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<ScannerScreen> {
  static const _prefKey = 'scanDefaultFilter';
  int mode = 0; // 0 مستند، 2 بطاقة (وش وضهر في صورة واحدة)
  final List<String> pages = [];
  ScanFilter sel = ScanFilter.original;
  ScanFilter? saved; // الفلتر الافتراضي المحفوظ (النجمة)
  bool busy = false;

  @override
  void initState() {
    super.initState();
    _loadDefault();
    _restorePages().then((_) {
      if (widget.autoStart && mounted) _scan(append: pages.isNotEmpty);
    });
  }

  static const _pagesKey = 'scanPages';

  /// صفحات السكانر بتتحفظ تلقائياً وترجع لما تفتح الشاشة تاني (المسح يدوي بس).
  Future<void> _restorePages() async {
    try {
      final p = await SharedPreferences.getInstance();
      final l = (p.getStringList(_pagesKey) ?? []).where((e) => File(e).existsSync()).toList();
      if (l.isNotEmpty && pages.isEmpty && mounted) setState(() => pages.addAll(l));
    } catch (e, st) {
      AppLog.e('scanner.restore', e, st);
    }
  }

  Future<void> _persistPages() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setStringList(_pagesKey, List.of(pages));
    } catch (e, st) {
      AppLog.e('scanner.persist', e, st);
    }
  }

  /// أي مستند قديم بيتبدّل بمستند جديد بيتنقل للأرشيف (مبيتمسحش).
  Future<void> _archiveCurrent() async {
    if (pages.isEmpty) return;
    final p = await SharedPreferences.getInstance();
    final a = p.getStringList('archive') ?? []; // نفس أرشيف التطبيق (قايمة الأرشيف الموجودة)
    for (final x in pages) {
      if (!a.contains(x)) a.add(x);
    }
    await p.setStringList('archive', a);
  }

  /// بينقل صورة الماسح من الكاش (أندرويد ممكن يمسحه) لمجلد التطبيق الدائم.
  Future<String> _keep(String src) async {
    final dir = (await Store.dir()).path;
    if (src.startsWith(dir)) {
      await Store.setQualityProfile(src, ImageQualityProfile.receipts);
      return src;
    }
    final dst = '$dir/scan_${DateTime.now().microsecondsSinceEpoch}.jpg';
    await File(src).copy(dst);
    await Store.setQualityProfile(dst, ImageQualityProfile.receipts); // تعديل السكانر بدقة الأصل وجودة 100
    return dst;
  }

  Future<void> _loadDefault() async {
    try {
      final p = await SharedPreferences.getInstance();
      final i = p.getInt(_prefKey);
      if (i != null && i >= 0 && i < ScanFilter.values.length) {
        saved = ScanFilter.values[i];
        sel = saved!;
      }
    } catch (e, st) {
      AppLog.e('scanner.loadDefault', e, st);
    }
    if (mounted) setState(() {});
  }

  Future<void> _toggleDefault() async {
    final p = await SharedPreferences.getInstance();
    if (saved == sel) {
      await p.remove(_prefKey);
      saved = null;
    } else {
      await p.setInt(_prefKey, sel.index);
      saved = sel;
    }
    if (mounted) setState(() {});
  }

  String get _hint => mode == 0
      ? 'مستند، صفحة أو أكتر'
      : 'وش وضهر البطاقة في صورة واحدة';

  /// بيجمع وش وضهر البطاقة في صورة JPEG واحدة بدقتهم الأصلية من غير تصغير (الوش فوق والضهر تحت على خلفية بيضا).
  /// مفيش حد أقصى للأبعاد: الصورة بتاخد عرض أكبر وش + هوامش وطول الاتنين.
  Future<String> _composeCard(String front, String back) async {
    final a = await decodeImage(await File(front).readAsBytes());
    final b = await decodeImage(await File(back).readAsBytes());
    try {
      final inner = math.max(a.width, b.width).toDouble();
      final m = (inner * 0.03).roundToDouble(), gap = (inner * 0.012).roundToDouble();
      final w = inner + 2 * m;
      final h = a.height + b.height + 2 * m + gap;
      final rec = ui.PictureRecorder();
      final c = ui.Canvas(rec);
      c.drawRect(ui.Rect.fromLTWH(0, 0, w, h), ui.Paint()..color = const ui.Color(0xFFFFFFFF));
      double y = m;
      for (final im in [a, b]) {
        c.drawImage(im, ui.Offset((w - im.width) / 2, y), ui.Paint());
        y += im.height + gap;
      }
      final out = await rec.endRecording().toImage(w.toInt(), h.toInt());
      final bd = await out.toByteData(format: ui.ImageByteFormat.png);
      out.dispose();
      if (bd == null) throw Exception('تعذر دمج الوش والضهر');
      final q = await Store.jpegQuality(profile: ImageQualityProfile.receipts);
      final jpg = await FlutterImageCompress.compressWithList(
          bd.buffer.asUint8List(bd.offsetInBytes, bd.lengthInBytes),
          minWidth: w.toInt(), minHeight: h.toInt(), quality: q, format: CompressFormat.jpeg);
      final dir = (await Store.dir()).path;
      final dst = '$dir/scan_${DateTime.now().microsecondsSinceEpoch}.jpg';
      await File(dst).writeAsBytes(jpg, flush: true);
      await Store.setQualityProfile(dst, ImageQualityProfile.receipts);
      return dst;
    } finally {
      a.dispose();
      b.dispose();
    }
  }

  Future<String> _filtered(String p) async {
    if (sel == ScanFilter.original || _lastScanEnhanced) return p;
    return renderEditedPage(p, 'scan_', EditParams(filter: sel));
  }

  /// وش أو ضهر بطاقة اتصوّر: بيتحفظ فوراً في «ملفاتي» (مسح يدوي بس)، حتى لو العملية اتلغت بعده.
  Future<void> _saveCardFace(String path) async {
    final ap = await SharedPreferences.getInstance();
    final al = ap.getStringList('archive') ?? [];
    if (!al.contains(path)) al.add(path);
    await ap.setStringList('archive', al);
  }

  /// append: لو فيه صفحات محفوظة، التصوير بيضيف عليها من غير ما يبدّلها أو يمسحها.
  Future<void> _scan({bool append = false}) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final List<String> got = [];
      if (append) {
        got.addAll(await scanImages(context, 24, camFallback: true));
      } else if (mode == 2) {
        final f = await scanImages(context, 1, camFallback: true);
        if (f.isEmpty || !mounted) return;
        // الوش بيتحفظ فوراً (حتى لو الضهر اتلغى) تحت «ملفاتي»
        final fa = await _keep(await _filtered(await _keep(f.first)));
        await _saveCardFace(fa);
        if (!mounted) return;
        snack(context, 'دلوقتي صوّر ضهر البطاقة');
        final b = await scanImages(context, 1, camFallback: true);
        if (b.isEmpty || !mounted) return;
        got..add(f.first)..add(b.first);
        final fb = await _keep(await _filtered(await _keep(b.first)));
        await _saveCardFace(fb);
        final one = await _composeCard(fa, fb);
        await _archiveCurrent();
        pages.clear();
        pages.add(one);
        await _persistPages();
        return;
      } else {
        got.addAll(await scanImages(context, mode == 0 ? 1 : 24, camFallback: true));
        if (mode == 0) {
          await _archiveCurrent();
          pages.clear();
        }
      }
      if (got.isEmpty || !mounted) return;
      for (final g in got) {
        pages.add(await _keep(await _filtered(await _keep(g))));
      }
      await _persistPages();
    } catch (e, st) {
      AppLog.e('scanner.scan', e, st);
      if (mounted) snack(context, errText(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _applyAll() async {
    if (busy || pages.isEmpty) return;
    setState(() => busy = true);
    try {
      for (var i = 0; i < pages.length; i++) {
        // بنحافظ على القص والدوران والتباين المحفوظين للصفحة ونغيّر الفلتر بس
        final prev = await Store.editOf(pages[i]);
        pages[i] = await renderEditedPage(
            pages[i],
            'scan_',
            EditParams(
              quad: prev?.quad,
              turns: prev?.turns ?? 0,
              angle: prev?.angle ?? 0,
              filter: sel,
              contrast: prev?.contrast ?? 0,
              brightness: prev?.brightness ?? 0,
              sharp: prev?.sharp ?? 0,
            ));
      }
      await _persistPages();
    } catch (e, st) {
      AppLog.e('scanner.applyAll', e, st);
      if (mounted) snack(context, errText(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _edit(int i) async {
    final out = await Navigator.push<String>(
      context,
      MaterialPageRoute(
          builder: (_) => EditorPage(
              path: pages[i], prefix: 'scan_', pageIndex: i, pageCount: pages.length)),
    );
    if (out == null || out == kRetake || !mounted) return;
    setState(() => pages[i] = out);
    await _persistPages();
  }

  Future<File> _buildPdf() async {
    final doc = pw.Document();
    if (mode == 2 && pages.length == 2) {
      final a = pw.MemoryImage(await File(pages[0]).readAsBytes());
      final b = pw.MemoryImage(await File(pages[1]).readAsBytes());
      doc.addPage(pw.Page(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(36),
        build: (_) => pw.Column(
          mainAxisAlignment: pw.MainAxisAlignment.spaceEvenly,
          children: [
            pw.Expanded(child: pw.Center(child: pw.Image(a, fit: pw.BoxFit.contain))),
            pw.SizedBox(height: 24),
            pw.Expanded(child: pw.Center(child: pw.Image(b, fit: pw.BoxFit.contain))),
          ],
        ),
      ));
    } else {
      for (final p in pages) {
        final img = pw.MemoryImage(await File(p).readAsBytes());
        doc.addPage(pw.Page(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(18),
          build: (_) => pw.Center(child: pw.Image(img, fit: pw.BoxFit.contain)),
        ));
      }
    }
    final d = await getTemporaryDirectory();
    final f = File('${d.path}/scan_${DateTime.now().millisecondsSinceEpoch}.pdf');
    await f.writeAsBytes(await doc.save(), flush: true);
    return f;
  }

  /// بنسأل في كل مرة: PDF ولا صور.
  Future<void> _export() async {
    if (busy || pages.isEmpty) return;
    final pick = await showModalBottomSheet<String>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
              leading: const Icon(Icons.picture_as_pdf_rounded),
              title: const Text('PDF'),
              onTap: () => Navigator.pop(c, 'pdf')),
          ListTile(
              leading: const Icon(Icons.image_rounded),
              title: Text(pages.length > 1 ? 'صور (JPG)' : 'صورة (JPG)'),
              onTap: () => Navigator.pop(c, 'jpg')),
        ]),
      ),
    );
    if (pick == null || !mounted) return;
    setState(() => busy = true);
    try {
      if (pick == 'pdf') {
        final f = await _buildPdf();
        await Share.shareXFiles([XFile(f.path)]);
      } else {
        await Share.shareXFiles([for (final p in pages) XFile(p)]);
      }
    } catch (e, st) {
      AppLog.e('scanner.export', e, st);
      if (mounted) snack(context, errText(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('سكانر')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Wrap(spacing: 8, children: [
              for (final e in const [0, 2])
                ChoiceChip(
                  label: Text(e == 0 ? 'مستند' : 'بطاقة'),
                  selected: mode == e,
                  onSelected: busy
                      ? null
                      : (_) async {
                          await _archiveCurrent();
                          if (!mounted) return;
                          setState(() {
                            mode = e;
                            pages.clear();
                          });
                          await _persistPages();
                        },
                ),
            ]),
            const SizedBox(height: 6),
            Text(_hint, style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: FilterBar(selected: sel, onChanged: busy ? null : (f) => setState(() => sel = f))),
              IconButton(
                tooltip: 'فلتر افتراضي',
                icon: Icon(saved == sel ? Icons.star_rounded : Icons.star_border_rounded, color: kAccent),
                onPressed: busy ? null : _toggleDefault,
              ),
            ]),
            const SizedBox(height: 8),
            Expanded(
              child: pages.isEmpty
                  ? Center(
                      child: Text('اضغط تصوير للبدء', style: TextStyle(color: cs.onSurfaceVariant)))
                  : GridView.builder(
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3, mainAxisSpacing: 8, crossAxisSpacing: 8, childAspectRatio: 0.72),
                      itemCount: pages.length,
                      itemBuilder: (_, i) => Stack(fit: StackFit.expand, children: [
                        InkWell(
                          onTap: busy ? null : () => _edit(i),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: Image.file(File(pages[i]), fit: BoxFit.cover, cacheWidth: 360),
                          ),
                        ),
                        PositionedDirectional(
                          top: 2,
                          end: 2,
                          child: IconButton.filledTonal(
                            iconSize: 16,
                            visualDensity: VisualDensity.compact,
                            tooltip: 'حذف',
                            icon: const Icon(Icons.close_rounded),
                            onPressed: busy
                                ? null
                                : () async {
                                    final gone = pages[i];
                                    setState(() => pages.removeAt(i));
                                    await _persistPages();
                                    await Store.del(gone); // مسح يدوي بس
                                  },
                          ),
                        ),
                      ]),
                    ),
            ),
            if (busy) const LinearProgressIndicator(),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                flex: 3,
                child: FilledButton.icon(
                  onPressed: busy ? null : _scan,
                  icon: const Icon(Icons.document_scanner_rounded),
                  label: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(pages.isEmpty ? 'تصوير' : 'إضافة صفحة')),
                ),
              ),
              if (pages.isNotEmpty) ...[
                const SizedBox(width: 6),
                Expanded(
                  flex: 3,
                  child: OutlinedButton(
                      onPressed: busy ? null : _applyAll,
                      child: const FittedBox(fit: BoxFit.scaleDown, child: Text('طبّق على الكل'))),
                ),
                const SizedBox(width: 6),
                Expanded(
                  flex: 2,
                  child: OutlinedButton(
                      onPressed: busy ? null : _export,
                      child: const FittedBox(fit: BoxFit.scaleDown, child: Text('تصدير'))),
                ),
              ],
            ]),
          ]),
        ),
      ),
    );
  }
}
