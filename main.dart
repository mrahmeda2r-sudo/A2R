import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
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

// ===== البيانات =====
// بيانات A2R - من ملف A2R2_Settings_v2.xlsx
// لتعديل أي اسم / وحدة / TID / مبنى عدّل هنا فقط.

class Unit {
  final int num; // رقم الوحدة (بيستخدم في اسم الملف والصورة)
  final String name;
  final String tid;
  final List<String> buildings;
  const Unit(this.num, this.name, this.tid, [this.buildings = const []]);

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

  /// مثال: 8.المنتزه.1.يوم.14.11  (اليوم.الشهر من تاريخ الموبايل بدون أصفار)
  String get pdfName {
    final n = DateTime.now();
    return '${unit.num}.${unit.slug}.يوم.${n.day}.${n.month}';
  }

  /// اسم صورة الباتش = رقم الوحدة فقط
  String get batchName => '${unit.num}';
}

const kNames = <String>[
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
const _qabbari = ['النقل']; // مبنى واحد -> مفيش قايمة

const kUnits = <Unit>[
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

// ===== رسم الورقة الصغيرة =====
class Rendered {
  final Uint8List png;
  final double ratio; // height / width
  Rendered(this.png, this.ratio);
}

Future<ui.Image> decodeImage(Uint8List b) async {
  final c = await ui.instantiateImageCodec(b);
  return (await c.getNextFrame()).image;
}

TextPainter _tp(String t, double fs, TextDirection d) => TextPainter(
      text: TextSpan(
          text: t,
          style: TextStyle(
              color: Colors.black, fontSize: fs, fontWeight: FontWeight.bold)),
      textDirection: d,
    )..layout();

Future<Rendered> _render(double w, double h, void Function(Canvas) draw) async {
  final rec = ui.PictureRecorder();
  final canvas = Canvas(rec, Rect.fromLTWH(0, 0, w, h));
  canvas.drawRect(Rect.fromLTWH(0, 0, w, h), Paint()..color = Colors.white);
  draw(canvas);
  final img = await rec.endRecording().toImage(w.ceil(), h.ceil());
  final bd = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  return Rendered(bd!.buffer.asUint8List(), h / w);
}

String _isoLtr(String s) => '\u2066$s\u2069';

/// الورقة الصغيرة فوق كل صورة إيصالات: الاسم / الوحدة (+المبنى) / TID / التاريخ
Future<Rendered> receiptLabel(double w, Session s) async {
  final fs = w * 0.034;
  final unitLine = s.building == null ? s.unit.name : '${s.unit.name} - ${s.building}';
  final lines = <TextPainter>[
    _tp(s.name, fs, TextDirection.rtl),
    _tp(unitLine, fs, TextDirection.rtl),
    _tp('TID: ${s.unit.tid}', fs, TextDirection.ltr),
    _tp(s.date, fs, TextDirection.ltr),
  ];
  final gap = fs * 0.35;
  final pad = fs * 0.9;
  final textW = lines.map((l) => l.width).reduce((a, b) => a > b ? a : b);
  final textH = lines.fold<double>(0, (a, l) => a + l.height) + gap * (lines.length - 1);
  final cardW = (textW + pad * 2).clamp(w * 0.4, w * 0.95);
  final cardH = textH + pad * 2;
  final margin = fs * 0.6;
  final h = cardH + margin * 2;
  return _render(w, h, (c) {
    final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH((w - cardW) / 2, margin, cardW, cardH), Radius.circular(fs * 0.5));
    c.drawRRect(
        rect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = w * 0.004
          ..color = Colors.black);
    var y = margin + pad;
    for (final l in lines) {
      l.paint(c, Offset((w - l.width) / 2, y));
      y += l.height + gap;
    }
  });
}

/// الشريط الرفيع فوق صورة الباتش (بدون TID):
/// سطر 1: الاسم | الوحدة     سطر 2: المبنى | التاريخ
Future<Rendered> batchStrip(double w, Session s) async {
  final fs = w * 0.026;
  final l1 = '${s.name}  |  ${s.unit.name}';
  final l2 = s.building == null
      ? _isoLtr(s.date)
      : '${s.building}  |  ${_isoLtr(s.date)}';
  final lines = [_tp(l1, fs, TextDirection.rtl), _tp(l2, fs, TextDirection.rtl)];
  final gap = fs * 0.25;
  final pad = fs * 0.5;
  final h = lines[0].height + lines[1].height + gap + pad * 2;
  return _render(w, h, (c) {
    var y = pad;
    for (final l in lines) {
      l.paint(c, Offset((w - l.width) / 2, y));
      y += l.height + gap;
    }
    c.drawLine(Offset(0, h - 1), Offset(w, h - 1),
        Paint()..color = Colors.black..strokeWidth = w * 0.002);
  });
}

// ===== بناء الـ PDF =====
/// تصغير وضغط الصورة (JPEG) عشان الـ PDF يطلع خفيف وميتقلش على التليفون.
Future<Uint8List> _shrink(String path, {int width = 1280, int quality = 60}) async {
  try {
    final out = await FlutterImageCompress.compressWithFile(
      path,
      minWidth: width,
      minHeight: width,
      quality: quality,
      format: CompressFormat.jpeg,
      keepExif: false,
    );
    if (out != null) return out;
  } catch (_) {}
  return File(path).readAsBytes();
}

// ===== ورقة البيانات (حرّة فوق الصورة: تتحرك وتكبر وتصغر) =====
const kTagFont = 0.05; // حجم خط الورقة الافتراضي (نسبة من عرض الصورة)
/// وضع ماسح الإيصالات: قص فقط (بدون فلاتر) ثم تأكيد. غيّره لـ ScannerMode.full لو عايز تحسين تلقائي.
const kReceiptScanMode = ScannerMode.base;
const kTagTop = 0.03; // بُعد ورقة الباتش عن أعلى الصورة في الوضع الافتراضي
const kBandPad = 0.02; // المسافة البيضاء فوق وتحت الورقة في إيصالات الدفع (نسبة من عرض الصورة)

class Tag {
  final Uint8List png;
  final double w, h;
  Tag(this.png, this.w, this.h);
}

/// مكان وحجم الورقة على الصورة. كل الأرقام نسب من عرض الصورة:
/// cx = مركز الورقة أفقياً، cy = مركزها رأسياً، s = عرض الورقة.
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

Future<double> imageAspect(String path) async {
  final i = await decodeImage(await File(path).readAsBytes());
  final r = i.height / i.width;
  i.dispose();
  return r;
}

/// الورقة: سطر (الاسم | الوحدة - المبنى) وسطر ثاني (TID | التاريخ) للإيصالات، أو (التاريخ) للباتش.
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

/// صورة + الورقة مرسومة فوقها في المكان والحجم اللي الموظف اختاره.
Future<({Uint8List bytes, double ratio})> composeTagged(String path, Session s,
    {required bool batch, required int width, required int quality}) async {
  final bytes = await _shrink(path, width: width, quality: quality);
  final img = await decodeImage(bytes);
  final w = img.width.toDouble();
  final h = img.height.toDouble();
  final ref = await receiptTag(1000, s, batch: batch);
  final pos = await Store.pos(path) ?? TagPos.initial(ref);
  final tag = await receiptTag(1000 * (w * pos.s) / ref.w, s, batch: batch);
  final tImg = await decodeImage(tag.png);
  final rec = ui.PictureRecorder();
  final c = Canvas(rec, Rect.fromLTWH(0, 0, w, h));
  c.drawImage(img, Offset.zero, Paint());
  c.drawImage(tImg, Offset(pos.cx * w - tag.w / 2, pos.cy * w - tag.h / 2), Paint());
  final out = await rec.endRecording().toImage(w.toInt(), h.toInt());
  final bd = await out.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  tImg.dispose();
  out.dispose();
  final jpg = await FlutterImageCompress.compressWithList(
    bd!.buffer.asUint8List(),
    minWidth: 4000,
    minHeight: 6000,
    quality: quality,
    format: CompressFormat.jpeg,
  );
  return (bytes: jpg, ratio: h / w);
}

Future<Uint8List> composeBatch(String path, Session s) async =>
    (await composeTagged(path, s, batch: true, width: 1400, quality: 80)).bytes;

/// الإيصال بعد القص + جزء علوي أبيض بعرض الصورة والورقة في منتصفه (من غير ما تغطي حاجة من الإيصال).
Future<({Uint8List bytes, double ratio})> composeReceipt(String path, Session s) async {
  final bytes = await _shrink(path, width: 1280, quality: 65);
  final img = await decodeImage(bytes);
  final w = img.width.toDouble();
  final h = img.height.toDouble();
  final tag = await receiptTag(w, s);
  final tImg = await decodeImage(tag.png);
  final pad = w * kBandPad;
  final bandH = tag.h + pad * 2;
  final total = bandH + h;
  final rec = ui.PictureRecorder();
  final c = Canvas(rec, Rect.fromLTWH(0, 0, w, total));
  c.drawRect(Rect.fromLTWH(0, 0, w, total), Paint()..color = Colors.white);
  c.drawImage(tImg, Offset((w - tag.w) / 2, pad), Paint());
  c.drawImage(img, Offset(0, bandH), Paint());
  final out = await rec.endRecording().toImage(w.toInt(), total.ceil());
  final bd = await out.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  tImg.dispose();
  out.dispose();
  final jpg = await FlutterImageCompress.compressWithList(
    bd!.buffer.asUint8List(),
    minWidth: 4000,
    minHeight: 6000,
    quality: 65,
    format: CompressFormat.jpeg,
  );
  return (bytes: jpg, ratio: total / w);
}

/// PDF إيصالات فقط: كل صفحة = جزء أبيض فيه الورقة + صورة الإيصال المقصوصة.
Future<File> buildReceiptsPdf(Session s, List<String> receipts) async {
  final doc = pw.Document();
  const pageW = 595.0;
  // صفحة واحدة في كل مرة عشان الذاكرة (تليفونات ضعيفة)
  for (final path in receipts) {
    final r = await composeReceipt(path, s);
    final pageH = pageW * r.ratio;
    doc.addPage(pw.Page(
      pageFormat: PdfPageFormat(pageW, pageH),
      margin: pw.EdgeInsets.zero,
      build: (_) => pw.Image(pw.MemoryImage(r.bytes), width: pageW, height: pageH),
    ));
  }
  final dir = await Store.dir();
  final file = File('${dir.path}/${s.pdfName}.pdf');
  await file.writeAsBytes(await doc.save());
  return file;
}

// ===== التخزين =====
String _dayKey() {
  final n = DateTime.now();
  return '${n.year}-${n.month}-${n.day}';
}

class Store {
  static const pdfLife = Duration(hours: 24);
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

  // --- مكان وحجم الورقة لكل صورة ---
  static Future<TagPos?> pos(String path) async =>
      TagPos.decode((await _p).getString('pos:$path'));

  /// لو الصورة ملهاش مكان محفوظ: بتاخد آخر مكان استخدمه الموظف (أو الافتراضي) وتتحفظ.
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

  // --- صورة الباتش اللي لسه متبعتتش ---
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

  // --- صور الإيصالات اللي لسه متبعتتش ---
  static Future<void> setDraft(List<String> l) async =>
      (await _p).setStringList('draft', l);

  static Future<List<String>> pdfImgs() async =>
      (await _p).getStringList('pdfImgs') ?? [];

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

  /// بعد إرسال الـ PDF: تتمسح الصور اللي دخلت فيه، والـ PDF نفسه يفضل لحد 24 ساعة.
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

  /// مسح أي ملفات مؤقتة مش تابعة لصور مسودة أو PDF شغّال.
  static Future<void> cleanup() async {
    final keep = <String>{...await draft()};
    final bi = await batchImg();
    if (bi != null) keep.add(bi);
    final pdfPath = (await pdf())?.file.path;
    if (pdfPath != null) keep.add(pdfPath);
    await for (final e in (await dir()).list()) {
      if (e is File && !keep.contains(e.path)) await del(e.path);
    }
  }
}

Future<bool> _decodesOk(Uint8List b) async {
  try {
    final i = await decodeImage(b);
    final ok = i.width > 0 && i.height > 0;
    i.dispose();
    return ok;
  } catch (_) {
    return false;
  }
}

/// نسخ الصورة من مكان الماسح المؤقت لمكان ثابت كـ JPEG عادي (مضغوط) بغض النظر عن نوع التليفون.
/// بيتأكد إن الصورة بتتفتح فعلاً، ولو الطريقة الأولى فشلت بيجرب فتحها بمحرك Flutter وإعادة حفظها.
Future<String> persistImage(String src, String name) async {
  Uint8List? bytes;
  try {
    bytes = await FlutterImageCompress.compressWithFile(
      src,
      minWidth: 1600,
      minHeight: 1600,
      quality: 80,
      format: CompressFormat.jpeg,
      keepExif: false,
    );
  } catch (_) {}
  if (bytes != null && !await _decodesOk(bytes)) bytes = null;
  if (bytes == null) {
    try {
      final raw = await File(src).readAsBytes();
      final codec = await ui.instantiateImageCodec(raw, targetWidth: 1600);
      final img = (await codec.getNextFrame()).image;
      final bd = await img.toByteData(format: ui.ImageByteFormat.png);
      img.dispose();
      bytes = await FlutterImageCompress.compressWithList(
        bd!.buffer.asUint8List(),
        minWidth: 4000,
        minHeight: 6000,
        quality: 80,
        format: CompressFormat.jpeg,
      );
    } catch (_) {}
  }
  if (bytes == null || !await _decodesOk(bytes)) {
    throw Exception('الصورة دي مش مدعومة، صوّرها تاني');
  }
  final f = File('${(await Store.dir()).path}/$name');
  await f.writeAsBytes(bytes);
  return f.path;
}

// ===== الأذونات والكاميرا والمشاركة =====
/// بيتطلب أول ما التطبيق يفتح عشان الموظف يشوف طلب الإذن.
Future<void> requestAllPermissions() async {
  await Permission.camera.request();
  final ph = await Permission.photos.request();
  if (!ph.isGranted && !ph.isLimited) {
    await Permission.storage.request();
  }
}

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

/// كل التصوير (كاميرا أو معرض) بيعدي على ماسح المستندات (قص وتحسين).
/// لو الماسح مش شغال على الموبايل بيتحول للكاميرا العادية تلقائياً.
/// داخل الماسح فيه أيقونة المعرض لاستيراد صور (لحد [limit] صورة).
Future<List<String>> scanImages(BuildContext context, int limit,
    {ScannerMode mode = ScannerMode.full}) async {
  if (!await ensureCamera(context)) return [];
  if (!context.mounted) return [];
  final scanner = DocumentScanner(
    options: DocumentScannerOptions(
      mode: mode,
      pageLimit: limit,
      isGalleryImport: true,
    ),
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

/// بيفتح قايمة المشاركة. لو النظام مرجعش النتيجة بنسأل الموظف.
Future<bool> shareFiles(BuildContext context, List<String> paths) async {
  final r = await Share.shareXFiles(paths.map((p) => XFile(p)).toList());
  if (r.status == ShareResultStatus.success) return true;
  if (r.status == ShareResultStatus.dismissed) return false;
  if (!context.mounted) return false;
  return askYesNo(context, 'تم الإرسال؟', 'لو بعت الملف فعلاً اضغط "تم".',
      yes: 'تم', no: 'لا');
}

/// تجهيز صورة الباتش (والورقة عليها) باسم رقم الوحدة وإرسالها.
Future<bool> sendBatchFile(BuildContext context, Session s, String img) async {
  final bytes = await composeBatch(img, s);
  final out = File('${(await Store.dir()).path}/${s.batchName}.jpg');
  await out.writeAsBytes(bytes);
  if (!context.mounted) return false;
  final ok = await shareFiles(context, [out.path]);
  if (ok) await Store.afterBatchSent();
  return ok;
}

/// صورة + الورقة فوقها. لو [onChanged] موجودة الورقة بتتحرك بالسحب وبتكبر/تصغر بإصبعين.
/// لو [aspect] موجودة الصورة بتتحط كلها جوه المساحة المتاحة، وإلا بتاخد العرض كله.
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
        Widget t = Image.memory(tag.png, width: dw, height: dh, fit: BoxFit.fill, gaplessPlayback: true);
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
            ? Image.file(File(path), width: cw, height: ch, fit: BoxFit.fill, errorBuilder: err)
            : Image.file(File(path), width: cw, fit: BoxFit.fitWidth, errorBuilder: err);
        final stack = Stack(clipBehavior: Clip.hardEdge, children: [
          img,
          Positioned(left: pos.cx * cw - dw / 2, top: pos.cy * cw - dh / 2, width: dw, height: dh, child: t),
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
          final cy = (p.cy + d.focalPointDelta.dy / widget.cw).clamp(0.0, widget.maxCy).toDouble();
          widget.onChanged(TagPos(cx, cy, s));
        },
        child: widget.child,
      );
}

/// عرض ملء الشاشة بتكبير بالأصابع.
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

/// الإيصال بعد القص وفوقه جزء أبيض بعرض الصورة والورقة في المنتصف (نفس شكل الـ PDF).
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
              errorBuilder: (_, __, ___) => const SizedBox(
                  height: 120, child: Center(child: Text('تعذر عرض الصورة')))),
        ]);
      });
}

void snack(BuildContext context, String m) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

// ===== التطبيق =====
void main() => runApp(const A2RApp());

class A2RApp extends StatelessWidget {
  const A2RApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'A2R',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorSchemeSeed: const Color(0xFF0B5FA5), useMaterial3: true),
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
  Unit? unit;
  String? building;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    final n = p.getString('name');
    final u = p.getString('unit');
    final b = p.getString('building');
    setState(() {
      if (kNames.contains(n)) name = n;
      final found = kUnits.where((x) => x.name == u);
      if (found.isNotEmpty) {
        unit = found.first;
        if (unit!.buildings.length > 1 && unit!.buildings.contains(b)) building = b;
      }
    });
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('name', name ?? '');
    await p.setString('unit', unit?.name ?? '');
    await p.setString('building', building ?? '');
  }

  bool get _needsBuilding => unit != null && unit!.buildings.length > 1;
  bool get _ready => name != null && unit != null && (!_needsBuilding || building != null);

  void _start() {
    // مبنى واحد -> يتاخد أوتوماتيك. مفيش مباني -> null
    final b = _needsBuilding
        ? building
        : (unit!.buildings.length == 1 ? unit!.buildings.first : null);
    _save();
    Navigator.push(context,
        MaterialPageRoute(builder: (_) => MainScreen(session: Session(name!, unit!, b))));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(children: [
            const SizedBox(height: 16),
            const Text('A2R',
                style: TextStyle(fontSize: 56, fontWeight: FontWeight.w900, letterSpacing: 4)),
            const SizedBox(height: 48),
            DropdownButtonFormField<String>(
              value: name,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'الاسم', border: OutlineInputBorder()),
              items: kNames.map((n) => DropdownMenuItem(value: n, child: Text(n))).toList(),
              onChanged: (v) => setState(() => name = v),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<Unit>(
              value: unit,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'الوحدة', border: OutlineInputBorder()),
              items: kUnits.map((u) => DropdownMenuItem(value: u, child: Text(u.name))).toList(),
              onChanged: (v) => setState(() {
                unit = v;
                building = null;
              }),
            ),
            if (_needsBuilding) ...[
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                key: ValueKey(unit!.name),
                value: building,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'المبنى', border: OutlineInputBorder()),
                items: unit!.buildings
                    .map((b) => DropdownMenuItem(value: b, child: Text(b)))
                    .toList(),
                onChanged: (v) => setState(() => building = v),
              ),
            ],
            const Spacer(),
            SizedBox(
              width: double.infinity,
              height: 56,
              child: FilledButton(
                onPressed: _ready ? _start : null,
                child: const Text('ابدأ', style: TextStyle(fontSize: 20)),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

// ===== الشاشة الرئيسية =====
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
    await Store.cleanup();
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
      if (ok) await _reload();
    } catch (e) {
      if (mounted) snack(context, 'حصل خطأ: $e');
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

  Widget _big(IconData icon, String label, bool done, VoidCallback onTap) => SizedBox(
        height: 150,
        child: FilledButton(
          style: FilledButton.styleFrom(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              padding: const EdgeInsets.all(8)),
          onPressed: onTap,
          child: SizedBox.expand(
            child: Stack(children: [
              Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(icon, size: 46),
                  const SizedBox(height: 8),
                  Text(label,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                ]),
              ),
              if (done)
                const Positioned(
                  top: 2,
                  left: 2,
                  child: CircleAvatar(
                      radius: 14,
                      backgroundColor: Colors.green,
                      child: Icon(Icons.check, color: Colors.white, size: 20)),
                ),
            ]),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final s = widget.session;
    final unitLine = s.building == null ? s.unit.name : '${s.unit.name} - ${s.building}';
    final pf = pdf;
    final bi = batchImg;
    return Scaffold(
      appBar: AppBar(
        title: const Text('A2R', style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 2)),
      ),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        if (busy) const LinearProgressIndicator(),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Icon(Icons.person),
                const SizedBox(width: 8),
                Expanded(
                    child: Text(s.name,
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
              ]),
              const SizedBox(height: 6),
              Row(children: [
                const Icon(Icons.location_on_outlined),
                const SizedBox(width: 8),
                Expanded(child: Text(unitLine, style: const TextStyle(fontSize: 16))),
              ]),
              const SizedBox(height: 6),
              Row(children: [
                const Icon(Icons.calendar_today),
                const SizedBox(width: 8),
                Text(s.date,
                    textDirection: TextDirection.ltr,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                const SizedBox(width: 8),
                const Expanded(
                    child: Text('(تاريخ التليفون - اتأكد إنه صح)',
                        style: TextStyle(fontSize: 12, color: Colors.grey))),
              ]),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: TextButton.icon(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.switch_account),
                  label: const Text('تغيير الحساب'),
                ),
              ),
            ]),
          ),
        ),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(
              child: _big(Icons.receipt_long, 'الباتش', batchSent,
                  () => _open(BatchScreen(session: s)))),
          const SizedBox(width: 12),
          Expanded(
              child: _big(Icons.payments, 'إيصالات الدفع', receiptsSent,
                  () => _open(ReceiptsScreen(session: s)))),
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
                  borderRadius: BorderRadius.circular(6),
                  child: Image.file(File(bi), width: 48, height: 48, fit: BoxFit.cover),
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
                  borderRadius: BorderRadius.circular(6),
                  child: Image.file(File(draft.first), width: 48, height: 48, fit: BoxFit.cover),
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
                title: Text(pf.file.path.split('/').last, maxLines: 2, overflow: TextOverflow.ellipsis),
                subtitle: Text(
                    'اضغط لفتحه - يتمسح بعد ${(24 - DateTime.now().difference(pf.time).inHours).clamp(1, 24)} ساعة'),
                onTap: _openPdf,
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(
                      tooltip: 'إرسال',
                      icon: const Icon(Icons.send),
                      onPressed: _sendPdf),
                  IconButton(
                      tooltip: 'مسح',
                      icon: const Icon(Icons.delete, color: Colors.red),
                      onPressed: _trashPdf),
                ]),
              ),
            ),
        ],
      ]),
    );
  }
}

// ===== شاشة الباتش =====
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

  /// لو فيه صورة باتش محفوظة بنعرضها للمعاينة، وإلا بنفتح الماسح.
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
      final path = await persistImage(r.first, 'batch_${DateTime.now().microsecondsSinceEpoch}.jpg');
      await Store.setBatchImg(path); // بتمسح القديمة
      await _show(path);
    } catch (e) {
      if (mounted) snack(context, 'حصل خطأ: $e');
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
      if (ok && mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) snack(context, 'حصل خطأ: $e');
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

// ===== شاشة إيصالات الدفع =====
class ReceiptsScreen extends StatefulWidget {
  final Session session;
  const ReceiptsScreen({super.key, required this.session});
  @override
  State<ReceiptsScreen> createState() => _ReceiptsScreenState();
}

class _ReceiptsScreenState extends State<ReceiptsScreen> {
  List<String> imgs = [];
  Tag? tag;
  File? built; // PDF اتعمل من نفس الصور الحالية
  bool busy = false;
  bool loaded = false;

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
      loaded = true;
    });
    if (d.isEmpty) _add();
  }

  /// تصوير إيصال: قص على الإيصال بس، وبعدين تأكيد.
  Future<void> _add() async {
    final r = await scanImages(context, 1, mode: kReceiptScanMode);
    if (r.isEmpty || !mounted) return;
    await _saveAll(r);
  }

  /// إيصالات من المعرض (بنفس القص، لحد 100 صورة).
  Future<void> _addGallery() async {
    final r = await scanImages(context, 100, mode: kReceiptScanMode);
    if (r.isEmpty || !mounted) return;
    await _saveAll(r);
  }

  Future<void> _saveAll(List<String> r) async {
    setState(() => busy = true);
    try {
      for (final p in r) {
        final saved = await persistImage(p, 'r_${DateTime.now().microsecondsSinceEpoch}.jpg');
        await Store.addToDraft(saved);
        imgs.add(saved);
      }
      built = null;
    } catch (e) {
      if (mounted) snack(context, 'حصل خطأ: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
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

  Future<void> _move(int i, int delta) async {
    final j = i + delta;
    if (j < 0 || j >= imgs.length) return;
    setState(() {
      final x = imgs.removeAt(i);
      imgs.insert(j, x);
      built = null;
    });
    await Store.setDraft(imgs);
  }

  Future<void> _create() async {
    setState(() => busy = true);
    try {
      final f = await buildReceiptsPdf(widget.session, imgs);
      await Store.setPdf(f, List.of(imgs));
      if (mounted) setState(() => built = f);
    } catch (e) {
      if (mounted) snack(context, 'حصل خطأ: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _send() async {
    final ok = await shareFiles(context, [built!.path]);
    if (ok) {
      await Store.afterPdfSent();
      if (mounted) Navigator.pop(context);
    }
  }

  Widget _mini(IconData icon, VoidCallback? onTap, {Color color = Colors.black54}) => GestureDetector(
        onTap: onTap,
        child: CircleAvatar(
            radius: 16, backgroundColor: color, child: Icon(icon, size: 20, color: Colors.white)),
      );

  Widget _item(int i) {
    final path = imgs[i];
    return Container(
      decoration: BoxDecoration(border: Border.all(color: Colors.grey.shade400)),
      child: Stack(children: [
        GestureDetector(
          onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => ZoomPage(child: ReceiptPreview(path: path, tag: tag!)))),
          child: ReceiptPreview(path: path, tag: tag!),
        ),
        Positioned(
            top: 6,
            left: 6,
            child: _mini(Icons.close, busy ? null : () => _remove(i), color: Colors.red)),
        Positioned(
          top: 6,
          right: 6,
          child: Row(children: [
            if (i > 0) _mini(Icons.arrow_upward, busy ? null : () => _move(i, -1)),
            const SizedBox(width: 4),
            if (i < imgs.length - 1) _mini(Icons.arrow_downward, busy ? null : () => _move(i, 1)),
          ]),
        ),
        Positioned(
          bottom: 6,
          left: 6,
          child: CircleAvatar(
              radius: 14,
              backgroundColor: Colors.black54,
              child: Text('${i + 1}', style: const TextStyle(color: Colors.white, fontSize: 13))),
        ),
      ]),
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
                  : ListView.separated(
                      padding: const EdgeInsets.all(12),
                      itemCount: imgs.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 12),
                      itemBuilder: (_, i) => _item(i),
                    ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Row(children: [
                Expanded(
                  child: OutlinedButton.icon(
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
                height: 48,
                child: FilledButton.icon(
                  onPressed: (busy || imgs.isEmpty) ? null : (built == null ? _create : _send),
                  icon: busy
                      ? const SizedBox(
                          width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : Icon(built == null ? Icons.picture_as_pdf : Icons.send),
                  label: Text(built == null ? 'إنشاء PDF' : 'إرسال'),
                ),
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}
