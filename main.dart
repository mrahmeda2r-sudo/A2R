import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
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

/// رابط ملف البيانات على GitHub (data.json). غيّر YOUR_USER و YOUR_REPO.
/// لازم الريبو يكون Public عشان الرابط يشتغل من غير تسجيل دخول.
/// تقدر كمان تمرره وقت البناء: --dart-define=DATA_URL=...
const kDataUrl = String.fromEnvironment('DATA_URL',
    defaultValue: 'https://raw.githubusercontent.com/YOUR_USER/YOUR_REPO/main/data.json');
const kVersion = String.fromEnvironment('APP_VERSION', defaultValue: 'dev');

const kTagFont = 0.05; // حجم خط الورقة (نسبة من عرض الصورة)
const kTagTop = 0.03; // بُعد ورقة الباتش عن أعلى الصورة
const kBandPad = 0.02; // المسافة البيضاء حوالين الورقة في إيصالات الدفع
const kReceiptScanMode = ScannerMode.base; // قص فقط، والتحسين بيتعمل من التطبيق
const kMaxSide = 1400; // أقصى عرض للصورة المحفوظة (يخلي التطبيق خفيف على التليفونات الضعيفة)

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
        (j['num'] as num).toInt(),
        (j['name'] as String).trim(),
        j['tid'].toString().trim(),
        ((j['buildings'] as List?) ?? const []).map((e) => e.toString()).toList(),
      );

  /// اسم الوحدة للملفات: بدون همزات/أقواس، والمسافات نقط
  String get slug => name
      .replaceAll(RegExp('[أإآ]'), 'ا')
      .replaceAll(RegExp(r'[()]'), ' ')
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

/// البيانات الحالية: بتبدأ بالمدمجة، وبعدين المحفوظة من آخر تحديث، وبعدين بتتحدث من GitHub.
/// لو الإنترنت مش موجود أو الملف فيه غلط، التطبيق يكمل بآخر بيانات سليمة.
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
    } catch (_) {
      return false;
    }
  }

  static Future<void> loadCached() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString('dataJson');
      if (raw != null && _apply(raw)) status.value = 'بيانات محفوظة';
    } catch (_) {}
  }

  /// بترجع true لو اتحدثت بنجاح.
  static Future<bool> refresh() async {
    if (kDataUrl.contains('YOUR_USER')) return false;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      final req = await client.getUrl(Uri.parse(kDataUrl)).timeout(const Duration(seconds: 8));
      final res = await req.close().timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return false;
      final raw = await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 10));
      if (!_apply(raw)) {
        status.value = 'ملف البيانات فيه خطأ - مستخدم آخر نسخة سليمة';
        return false;
      }
      final p = await SharedPreferences.getInstance();
      await p.setString('dataJson', raw);
      status.value = 'تم تحديث البيانات';
      return true;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }
}

// =====================================================================
//  أدوات الصور (خفيفة على الذاكرة)
// =====================================================================

enum ScanFilter { original, enhance, bw }

String errText(Object e) {
  if (e is FileSystemException && (e.osError?.errorCode == 28)) {
    return 'مساحة التليفون ممتلئة، امسح ملفات وجرب تاني';
  }
  final s = e.toString();
  return s.startsWith('Exception: ') ? s.substring(11) : s;
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

List<double> _matrix(ScanFilter f) {
  if (f == ScanFilter.enhance) {
    const c = 1.3;
    const t = 255 * (0.5 - 0.5 * c) + 10;
    return [c, 0, 0, 0, t, 0, c, 0, 0, t, 0, 0, c, 0, t, 0, 0, 0, 1, 0];
  }
  // أبيض وأسود عالي التباين (مناسب للإيصالات الحرارية الباهتة)
  const c = 1.7;
  const t = 255 * (0.5 - 0.5 * c) + 40;
  const r = 0.2126 * c, g = 0.7152 * c, b = 0.0722 * c;
  return [r, g, b, 0, t, r, g, b, 0, t, r, g, b, 0, t, 0, 0, 0, 1, 0];
}

Future<Uint8List> applyFilter(Uint8List bytes, ScanFilter f) async {
  if (f == ScanFilter.original) return bytes;
  try {
    final img = await decodeImage(bytes);
    final w = img.width, h = img.height;
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    c.drawImage(img, Offset.zero, Paint()..colorFilter = ColorFilter.matrix(_matrix(f)));
    final out = await rec.endRecording().toImage(w, h);
    final bd = await out.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    out.dispose();
    return await FlutterImageCompress.compressWithList(
      bd!.buffer.asUint8List(),
      minWidth: w,
      minHeight: h,
      quality: 82,
      format: CompressFormat.jpeg,
    );
  } catch (_) {
    return bytes; // لو الفلتر فشل (ذاكرة) نكمل بالصورة الأصلية
  }
}

Future<bool> _decodesOk(Uint8List b) async {
  try {
    final s = await imageSize(b);
    return s.w > 0 && s.h > 0;
  } catch (_) {
    return false;
  }
}

/// نسخ الصورة من مكان الماسح المؤقت لمكان ثابت كـ JPEG واحد مضغوط (مرة واحدة بس).
/// وبعدها بيتطبق الفلتر لو الموظف اختاره.
Future<String> persistImage(String src, String name,
    {ScanFilter filter = ScanFilter.original}) async {
  Uint8List? bytes;
  try {
    bytes = await FlutterImageCompress.compressWithFile(
      src,
      minWidth: kMaxSide,
      minHeight: kMaxSide,
      quality: 82,
      format: CompressFormat.jpeg,
      keepExif: false,
    );
  } catch (_) {}
  if (bytes != null && !await _decodesOk(bytes)) bytes = null;
  if (bytes == null) {
    try {
      final raw = await File(src).readAsBytes();
      final img = await decodeImage(raw, maxWidth: kMaxSide);
      final bd = await img.toByteData(format: ui.ImageByteFormat.png);
      final w = img.width, h = img.height;
      img.dispose();
      bytes = await FlutterImageCompress.compressWithList(
        bd!.buffer.asUint8List(),
        minWidth: w,
        minHeight: h,
        quality: 82,
        format: CompressFormat.jpeg,
      );
    } catch (_) {}
  }
  if (bytes == null || !await _decodesOk(bytes)) {
    throw Exception('الصورة دي مش مدعومة، صوّرها تاني');
  }
  bytes = await applyFilter(bytes, filter);
  final f = File('${(await Store.dir()).path}/$name');
  await f.writeAsBytes(bytes, flush: true);
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
    return TagPos(a, b, c);
  }
}

Future<Tag> receiptTag(double w, Session s, {bool batch = false}) async {
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
  final rr = RRect.fromRectAndRadius(Rect.fromLTWH(0, 0, cw, ch), Radius.circular(fs * 0.5));
  c.drawRRect(rr, Paint()..color = Colors.white);
  c.drawRRect(
      rr,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = w * 0.004
        ..color = Colors.black);
  l1.paint(c, Offset((cw - l1.width) / 2, pad));
  l2.paint(c, Offset((cw - l2.width) / 2, pad + l1.height + gap));
  final img = await rec.endRecording().toImage(cw.ceil(), ch.ceil());
  final bd = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  return Tag(bd!.buffer.asUint8List(), cw, ch);
}

/// صورة الباتش + الورقة فوقها في المكان اللي الموظف اختاره (ضغط واحد بس في الآخر).
Future<Uint8List> composeBatch(String path, Session s) async {
  final src = await File(path).readAsBytes();
  final sz = await imageSize(src);
  final img = await decodeImage(src, maxWidth: sz.w > kMaxSide ? kMaxSide : null);
  final w = img.width.toDouble();
  final h = img.height.toDouble();
  final ref = await receiptTag(1000, s, batch: true);
  final pos = await Store.pos(path) ?? TagPos.initial(ref);
  final tag = await receiptTag(1000 * (w * pos.s) / ref.w, s, batch: true);
  final tImg = await decodeImage(tag.png);
  final rec = ui.PictureRecorder();
  final c = Canvas(rec, Rect.fromLTWH(0, 0, w, h));
  c.drawImage(img, Offset.zero, Paint());
  c.drawImage(tImg, Offset(pos.cx * w - tag.w / 2, pos.cy * w - tag.h / 2), Paint());
  final out = await rec.endRecording().toImage(img.width, img.height);
  final bd = await out.toByteData(format: ui.ImageByteFormat.png);
  final iw = img.width, ih = img.height;
  img.dispose();
  tImg.dispose();
  out.dispose();
  return FlutterImageCompress.compressWithList(
    bd!.buffer.asUint8List(),
    minWidth: iw,
    minHeight: ih,
    quality: 82,
    format: CompressFormat.jpeg,
  );
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
    for (var i = 0; i < receipts.length; i++) {
      onProgress?.call(i, receipts.length);
      final bytes = await File(receipts[i]).readAsBytes();
      final sz = await imageSize(bytes);
      final imgH = pageW * sz.h / sz.w;
      final pageH = bandH + imgH + 1;
      final image = pw.MemoryImage(bytes);
      doc.addPage(pw.Page(
        pageFormat: PdfPageFormat(pageW, pageH),
        margin: pw.EdgeInsets.zero,
        build: (_) => pw.Column(children: [
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
      await (await _p).remove('pos:$path');
    } catch (_) {}
  }

  // --- إعدادات الموظف ---
  static Future<ScanFilter> filter() async {
    final i = (await _p).getInt('filter') ?? 0;
    return ScanFilter.values[i.clamp(0, ScanFilter.values.length - 1)];
  }

  static Future<void> setFilter(ScanFilter f) async => (await _p).setInt('filter', f.index);

  static Future<bool> continuous() async => (await _p).getBool('continuous') ?? true;
  static Future<void> setContinuous(bool v) async => (await _p).setBool('continuous', v);

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
    await for (final e in (await dir()).list()) {
      if (working > 0) return;
      if (e is File && !keep.contains(e.path)) await del(e.path);
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
  } catch (_) {
    if (context.mounted) snack(context, 'تعذر فتح الكاميرا أو المعرض');
    return [];
  }
}

/// كل التصوير (كاميرا أو معرض) بيعدي على ماسح المستندات (قص).
/// لو الماسح مش شغال على الموبايل بيتحول للكاميرا العادية تلقائياً.
Future<List<String>> scanImages(BuildContext context, int limit,
    {ScannerMode mode = ScannerMode.full}) async {
  if (!await ensureCamera(context)) return [];
  if (!context.mounted) return [];
  final scanner = DocumentScanner(
    options: DocumentScannerOptions(mode: mode, pageLimit: limit, isGalleryImport: true),
  );
  try {
    final r = await scanner.scanDocument();
    return List<String>.from(r.images ?? const []);
  } catch (e) {
    if (e.toString().toLowerCase().contains('cancel')) return [];
    if (!context.mounted) return [];
    snack(context, 'الماسح مش شغال على الموبايل ده، هنفتح الكاميرا العادية');
    return simplePick(context, multi: limit > 1);
  } finally {
    scanner.close();
  }
}

/// قايمة المشاركة العادية: الموظف يختار واتساب أو أي تطبيق.
Future<bool> shareFiles(BuildContext context, List<String> paths) async {
  final r = await Share.shareXFiles(paths.map((p) => XFile(p)).toList());
  if (r.status == ShareResultStatus.success) return true;
  if (r.status == ShareResultStatus.dismissed) return false;
  if (!context.mounted) return false;
  return askYesNo(context, 'تم الإرسال؟', 'لو بعت الملف فعلاً اضغط "تم".',
      yes: 'تم', no: 'لا');
}

Future<bool> sendBatchFile(BuildContext context, Session s, String img) async {
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
  final ok = await shareFiles(context, [out.path]);
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
  const TaggedImage(
      {super.key,
      required this.path,
      required this.tag,
      required this.pos,
      this.aspect,
      this.onChanged});

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
                width: cw, height: ch, fit: BoxFit.fill, cacheWidth: kMaxSide, errorBuilder: err)
            : Image.file(File(path),
                width: cw, fit: BoxFit.fitWidth, cacheWidth: kMaxSide, errorBuilder: err);
        final stack = Stack(clipBehavior: Clip.hardEdge, children: [
          img,
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

class ZoomPage extends StatelessWidget {
  final Widget child;
  const ZoomPage({super.key, required this.child});
  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white),
      body: InteractiveViewer(
        constrained: false,
        minScale: 0.5,
        maxScale: 6,
        child: SizedBox(width: w, child: child),
      ),
    );
  }
}

class ReceiptPreview extends StatelessWidget {
  final String path;
  final Tag tag;
  const ReceiptPreview({super.key, required this.path, required this.tag});
  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (ctx, cons) {
        final cw = cons.maxWidth;
        return Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: cw,
            color: Colors.white,
            padding: EdgeInsets.symmetric(vertical: cw * kBandPad),
            alignment: Alignment.center,
            child: Image.memory(tag.png,
                width: cw * tag.w / 1000, height: cw * tag.h / 1000, fit: BoxFit.fill),
          ),
          Image.file(File(path),
              width: cw,
              fit: BoxFit.fitWidth,
              cacheWidth: kMaxSide,
              errorBuilder: (_, __, ___) =>
                  const SizedBox(height: 120, child: Center(child: Text('تعذر عرض الصورة')))),
        ]);
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
  await AppData.loadCached();
  runApp(const A2RApp());
  unawaited(AppData.refresh());
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
  const A2RApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'A2R',
        debugShowCheckedModeBanner: false,
        theme: _theme(Brightness.light),
        darkTheme: _theme(Brightness.dark),
        themeMode: ThemeMode.system,
        builder: (c, w) => Directionality(textDirection: TextDirection.rtl, child: w!),
        home: const LoginScreen(),
      );
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  String? name;
  String? unitName;
  String? building;
  bool refreshing = false;

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

  void _start() {
    final u = _unit!;
    final b = _needsBuilding ? _building : (u.buildings.length == 1 ? u.buildings.first : null);
    name = _name;
    building = _building;
    _save();
    Navigator.push(
        context, MaterialPageRoute(builder: (_) => MainScreen(session: Session(name!, u, b))));
  }

  Future<void> _refresh() async {
    setState(() => refreshing = true);
    final ok = await AppData.refresh();
    if (!mounted) return;
    setState(() => refreshing = false);
    snack(context, ok ? 'تم تحديث البيانات' : 'مقدرتش أحدّث، هكمل بآخر بيانات محفوظة');
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
                        const SizedBox(width: 4),
                        refreshing
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2))
                            : IconButton(
                                tooltip: 'تحديث البيانات',
                                visualDensity: VisualDensity.compact,
                                icon: const Icon(Icons.refresh, size: 20),
                                onPressed: _refresh),
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
    try {
      await Store.cleanup();
    } catch (_) {}
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

  Future<void> _open(Widget screen) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => screen));
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
    final r = await OpenFilex.open(f.file.path);
    if (r.type != ResultType.done && mounted) {
      snack(context, 'مفيش تطبيق يفتح ملفات PDF على التليفون');
    }
  }

  Future<void> _sendPdf() async {
    final f = pdf;
    if (f == null) return;
    final ok = await shareFiles(context, [f.file.path]);
    if (ok) {
      HapticFeedback.mediumImpact();
      await Store.afterPdfSent();
      await _reload();
    }
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
            style: TextStyle(color: Colors.white, fontSize: 16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(Icons.person, color: Colors.white),
                const SizedBox(width: 8),
                Expanded(
                    child: Text(s.name,
                        style: const TextStyle(fontSize: 19, fontWeight: FontWeight.bold))),
              ]),
              const SizedBox(height: 8),
              Row(children: [
                Icon(Icons.location_on_outlined, color: Colors.white),
                const SizedBox(width: 8),
                Expanded(child: Text(unitLine)),
              ]),
              const SizedBox(height: 8),
              Row(children: [
                Icon(Icons.calendar_today, color: Colors.white, size: 20),
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
              child: _big(Icons.receipt_long, 'الباتش', () => _open(BatchScreen(session: s)))),
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
  const BatchScreen({super.key, required this.session});
  @override
  State<BatchScreen> createState() => _BatchScreenState();
}

class _BatchScreenState extends State<BatchScreen> {
  String? img;
  Tag? tag;
  TagPos? pos;
  double? aspect;
  bool busy = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final cur = await Store.batchImg();
    if (!mounted) return;
    if (cur != null) {
      await _show(cur);
    } else {
      _capture();
    }
  }

  Future<void> _show(String path) async {
    try {
      final t = tag ?? await receiptTag(1000, widget.session, batch: true);
      final a = await imageAspect(path);
      final p = await Store.assignPos(path, t, true);
      if (!mounted) return;
      setState(() {
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

  Future<void> _capture() async {
    final r = await scanImages(context, 1);
    if (!mounted) return;
    if (r.isEmpty) {
      if (img == null) Navigator.pop(context);
      return;
    }
    setState(() => busy = true);
    try {
      final path =
          await persistImage(r.first, 'batch_${DateTime.now().microsecondsSinceEpoch}.jpg');
      await Store.setBatchImg(path);
      await _show(path);
    } catch (e) {
      if (mounted) snack(context, 'حصل خطأ: ${errText(e)}');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void _set(TagPos p) {
    setState(() => pos = p);
    Store.savePos(img!, p, true);
  }

  Future<void> _send() async {
    setState(() => busy = true);
    try {
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
    final ready = img != null && tag != null && pos != null && aspect != null;
    return Scaffold(
      appBar: AppBar(title: const Text('الباتش')),
      body: !ready
          ? const Center(child: CircularProgressIndicator())
          : Column(children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: TaggedImage(
                      path: img!, tag: tag!, pos: pos!, aspect: aspect, onChanged: _set),
                ),
              ),
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
                      onChanged: (v) => _set(pos!.copyWith(s: v)),
                    ),
                  ),
                  IconButton(
                    tooltip: 'المكان الأصلي',
                    icon: const Icon(Icons.restart_alt),
                    onPressed: () => _set(TagPos.initial(tag!)),
                  ),
                ]),
              ),
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  child: Row(children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: busy ? null : _capture,
                        icon: const Icon(Icons.add_a_photo),
                        label: const Text('تصوير / معرض'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
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
//  شاشة إيصالات الدفع
// =====================================================================

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
  ScanFilter filter = ScanFilter.original;
  String? progress;

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
      imgs = d;
      tag = t;
      built = b;
      filter = fl;
      continuous = co;
      loaded = true;
    });
    if (d.isEmpty) _add();
  }

  /// تصوير متتالي: صوّر → قص → يرجع يفتح الكاميرا تاني لحد ما الموظف يقفل الماسح.
  Future<void> _add() async {
    do {
      final r = await scanImages(context, 1, mode: kReceiptScanMode);
      if (r.isEmpty || !mounted) break;
      await _saveAll(r);
      if (!mounted) break;
    } while (continuous);
  }

  Future<void> _addGallery() async {
    final r = await scanImages(context, 100, mode: kReceiptScanMode);
    if (r.isEmpty || !mounted) return;
    await _saveAll(r);
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
    } catch (e) {
      if (mounted) snack(context, 'حصل خطأ: ${errText(e)}');
    } finally {
      if (mounted) setState(() => busy = false);
    }
    if (added > 0 && mounted && r.length > 1) snack(context, 'اتضاف $added إيصال');
  }

  Future<void> _remove(int i) async {
    if (!await askYesNo(context, 'مسح الصورة؟', 'الصورة دي هتتمسح.', yes: 'امسح', no: 'إلغاء')) {
      return;
    }
    await Store.removeFromDraft(imgs[i]);
    if (!mounted) return;
    setState(() {
      imgs.removeAt(i);
      built = null;
    });
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

  Future<void> _send() async {
    final ok = await shareFiles(context, [built!.path]);
    if (ok) {
      HapticFeedback.mediumImpact();
      await Store.afterPdfSent();
      if (mounted) Navigator.pop(context);
    }
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
                builder: (_) => ZoomPage(child: ReceiptPreview(path: path, tag: tag!)))),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Row(children: [
            CircleAvatar(
                radius: 14,
                backgroundColor: cs.primary,
                child: Text('${i + 1}',
                    style: TextStyle(color: cs.onPrimary, fontSize: 13))),
            const SizedBox(width: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.file(File(path),
                  width: 72,
                  height: 72,
                  fit: BoxFit.cover,
                  cacheWidth: 220,
                  errorBuilder: (_, __, ___) =>
                      const SizedBox(width: 72, height: 72, child: Icon(Icons.broken_image))),
            ),
            const SizedBox(width: 12),
            const Expanded(child: Text('اضغط للمعاينة', style: TextStyle(color: Colors.grey))),
            IconButton(
                tooltip: 'مسح',
                icon: const Icon(Icons.delete_outline, color: Colors.red),
                onPressed: busy ? null : () => _remove(i)),
            ReorderableDragStartListener(
                index: i,
                child: const Padding(
                    padding: EdgeInsets.all(8), child: Icon(Icons.drag_handle))),
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
                child: SegmentedButton<ScanFilter>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: ScanFilter.original, label: Text('أصلي')),
                    ButtonSegment(value: ScanFilter.enhance, label: Text('تحسين')),
                    ButtonSegment(value: ScanFilter.bw, label: Text('أبيض وأسود')),
                  ],
                  selected: {filter},
                  onSelectionChanged: busy
                      ? null
                      : (v) {
                          setState(() => filter = v.first);
                          Store.setFilter(v.first);
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
                  onPressed: (busy || imgs.isEmpty) ? null : (built == null ? _create : _send),
                  icon: busy
                      ? const SizedBox(
                          width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : Icon(built == null ? Icons.picture_as_pdf : Icons.send),
                  label: Text(progress != null
                      ? 'جارى التجهيز $progress'
                      : (built == null ? 'إنشاء PDF' : 'إرسال')),
                ),
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}
