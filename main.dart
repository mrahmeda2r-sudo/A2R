import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
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

  /// تاريخ مختصر للورقة: يوم/شهر بس (من غير سنة)
  String get shortDate {
    final n = DateTime.now();
    return '${n.day.toString().padLeft(2, '0')}/${n.month.toString().padLeft(2, '0')}';
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

/// أول صف فيه كتابة من فوق + لون الورقة، عشان الورقة تتحط في المساحة البيضا اللي فوق الشعار.
Future<({int ink, Color paper})> topMargin(ui.Image img) async {
  final w = img.width;
  final h = img.height;
  final bd = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (bd == null) return (ink: 0, paper: Colors.white);
  final px = bd.buffer.asUint8List();
  final limit = (h * 0.45).floor();
  final x0 = (w * 0.05).floor();
  final x1 = (w * 0.95).floor();
  const step = 3;
  var ink = limit;
  for (var y = 0; y < limit; y++) {
    var dark = 0;
    var n = 0;
    for (var x = x0; x < x1; x += step) {
      final i = (y * w + x) * 4;
      final lum = (px[i] * 299 + px[i + 1] * 587 + px[i + 2] * 114) ~/ 1000;
      n++;
      if (lum < 150) dark++;
    }
    if (dark > n * 0.01) {
      ink = y;
      break;
    }
  }
  var paper = Colors.white;
  if (ink > 8) {
    final y = ink ~/ 2;
    var r = 0, g = 0, b = 0, n = 0;
    for (var x = x0; x < x1; x += step) {
      final i = (y * w + x) * 4;
      r += px[i];
      g += px[i + 1];
      b += px[i + 2];
      n++;
    }
    if (n > 0) paper = Color.fromARGB(255, r ~/ n, g ~/ n, b ~/ n);
  }
  return (ink: ink, paper: paper);
}

/// دمج الورقة (الاسم/الوحدة+المبنى/التاريخ) في المساحة البيضا فوق الباتش بخط كبير.
/// لو المساحة البيضا أكبر من اللازم بتتقص، ولو أصغر بتتزود من فوق. مفيش حاجة من الكتابة بتتغطى.
Future<Uint8List> composeBatch(String path, Session s) async {
  final bytes = await _shrink(path, width: 1400, quality: 80);
  final img = await decodeImage(bytes);
  final w = img.width.toDouble();
  final h = img.height.toDouble();
  final tag = await batchTag(w, s);
  final tImg = await decodeImage(tag.png);
  final m = await topMargin(img);
  final gap = w * 0.015; // مسافة بين الورقة وأول سطر في الباتش
  final padTop = w * 0.012; // مسافة فوق الورقة
  final cropTop = (m.ink - gap).clamp(0.0, h * 0.45).toDouble(); // الزيادة البيضا اللي بتتقص
  final band = padTop + tag.h + gap;
  final total = band + (h - cropTop);
  final rec = ui.PictureRecorder();
  final c = Canvas(rec, Rect.fromLTWH(0, 0, w, total));
  c.drawRect(Rect.fromLTWH(0, 0, w, total), Paint()..color = m.paper);
  c.drawImageRect(
      img, Rect.fromLTWH(0, cropTop, w, h - cropTop), Rect.fromLTWH(0, band, w, h - cropTop), Paint());
  c.drawImage(tImg, Offset((w - tag.w) / 2, padTop), Paint());
  final out = await rec.endRecording().toImage(w.toInt(), total.ceil());
  final bd = await out.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  tImg.dispose();
  out.dispose();
  final jpg = await FlutterImageCompress.compressWithList(
    bd!.buffer.asUint8List(),
    minWidth: 4000,
    minHeight: 6000,
    quality: 80,
    format: CompressFormat.jpeg,
  );
  return jpg;
}

// ===== ورقة الإيصال (فوق الصورة) =====
const kTagFont = 0.042; // حجم خط الورقة (نسبة من عرض الصورة) - زوّد/قلّل الرقم لو عايز
const kTagTop = 0.03; // بُعد الورقة عن أعلى الصورة (نسبة من عرض الصورة)

class Tag {
  final Uint8List png;
  final double w, h;
  Tag(this.png, this.w, this.h);
}

// ===== ورقة الباتش (في المساحة البيضا فوق الشعار) =====
const kBatchFont = 0.05; // حجم خط ورقة الباتش (نسبة من عرض الصورة) - صغّر/كبّر الرقم لو عايز

/// ورقة من سطرين. الخط بيصغر لوحده لو السطر عريض.
Future<Tag> _makeTag(double w, List<String> texts, double fontFrac, double strokeFrac) async {
  final maxTextW = w * 0.9;
  var fs = w * fontFrac;
  late List<TextPainter> lines;
  for (var i = 0; i < 6; i++) {
    lines = [for (final t in texts) _tp(t, fs, TextDirection.rtl)];
    final widest = lines.map((l) => l.width).reduce((a, b) => a > b ? a : b);
    if (widest <= maxTextW) break;
    fs *= maxTextW / widest * 0.98;
  }
  final pad = fs * 0.4;
  final gap = fs * 0.12;
  final textW = lines.map((l) => l.width).reduce((a, b) => a > b ? a : b);
  final cw = (textW + pad * 2).clamp(0.0, w * 0.96).toDouble();
  final ch = lines.fold<double>(0, (a, l) => a + l.height) + gap * (lines.length - 1) + pad * 2;
  final rec = ui.PictureRecorder();
  final c = Canvas(rec, Rect.fromLTWH(0, 0, cw, ch));
  final rr = RRect.fromRectAndRadius(Rect.fromLTWH(0, 0, cw, ch), Radius.circular(fs * 0.4));
  c.drawRRect(rr, Paint()..color = Colors.white);
  c.drawRRect(
      rr,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = w * strokeFrac
        ..color = Colors.black);
  var y = pad;
  for (final l in lines) {
    l.paint(c, Offset((cw - l.width) / 2, y));
    y += l.height + gap;
  }
  final img = await rec.endRecording().toImage(cw.ceil(), ch.ceil());
  final bd = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  return Tag(bd!.buffer.asUint8List(), cw, ch);
}

/// ورقة الباتش:  الاسم - الوحدة  /  المبنى - التاريخ (يوم/شهر)
Future<Tag> batchTag(double w, Session s) {
  final d = _isoLtr(s.shortDate);
  return _makeTag(
      w,
      [
        '${s.name} - ${s.unit.name}',
        s.building == null ? d : '${s.building} - $d',
      ],
      kBatchFont,
      0.004);
}

/// ورقة الإيصال: نفس الشكل + رقم TID في آخر السطر التاني.
Future<Tag> receiptTag(double w, Session s) {
  final d = _isoLtr(s.shortDate);
  final tid = _isoLtr('TID: ${s.unit.tid}');
  return _makeTag(
      w,
      [
        '${s.name} - ${s.unit.name}',
        s.building == null ? '$d - $tid' : '${s.building} - $d - $tid',
      ],
      kTagFont,
      0.004);
}

/// صورة الإيصال + الورقة مرسومة فوقها (في النص من فوق).
Future<({Uint8List bytes, double ratio})> composeReceipt(String path, Session s) async {
  final bytes = await _shrink(path, width: 1280, quality: 70);
  final img = await decodeImage(bytes);
  final w = img.width.toDouble();
  final h = img.height.toDouble();
  final tag = await receiptTag(w, s);
  final tImg = await decodeImage(tag.png);
  final rec = ui.PictureRecorder();
  final c = Canvas(rec, Rect.fromLTWH(0, 0, w, h));
  c.drawImage(img, Offset.zero, Paint());
  c.drawImage(tImg, Offset((w - tag.w) / 2, w * kTagTop), Paint());
  final out = await rec.endRecording().toImage(w.toInt(), h.toInt());
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
  return (bytes: jpg, ratio: h / w);
}

/// PDF إيصالات فقط: كل صفحة = صورة الإيصال وعليها الورقة من فوق.
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

class SendEntry {
  final DateTime time;
  final String kind; // batch | receipts
  final String file;
  final int pages;
  SendEntry(this.time, this.kind, this.file, this.pages);
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
    } catch (_) {}
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
    final cp = p.getString('batchCompPath');
    if (cp != null) await del(cp);
    await p.remove('batchCompPath');
    await p.remove('batchCompSig');
  }

  static Future<void> afterBatchSent(String fileName) async {
    await clearBatchImg();
    await setFlag('batch');
    await addLog('batch', fileName, 1);
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

  /// استبدال صورة في المسودة بصورة تانية في نفس المكان.
  static Future<void> replaceInDraft(String old, String neu) async {
    final l = await draft();
    final i = l.indexOf(old);
    if (i >= 0) {
      l[i] = neu;
    } else {
      l.add(neu);
    }
    if (old != neu) await del(old);
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
    final pdfPath = p.getString('pdfPath');
    await addLog('receipts', pdfPath == null ? 'PDF' : pdfPath.split('/').last, used.length);
    final left = await draft();
    for (final u in used) {
      await del(u);
      left.remove(u);
    }
    await p.setStringList('draft', left);
    await p.remove('pdfImgs');
    await setFlag('receipts');
  }

  // --- سجل الإرسال (آخر 7 أيام) ---
  static const logDays = 7;

  static Future<void> addLog(String kind, String file, int pages) async {
    final p = await _p;
    final l = p.getStringList('sendLog') ?? [];
    l.add(jsonEncode({
      't': DateTime.now().millisecondsSinceEpoch,
      'k': kind,
      'f': file,
      'n': pages,
    }));
    await p.setStringList('sendLog', l);
  }

  /// بيرجّع السجل (الأحدث الأول) وبيمسح اللي أقدم من 7 أيام.
  static Future<List<SendEntry>> log() async {
    final p = await _p;
    final cutoff = DateTime.now().subtract(const Duration(days: logDays)).millisecondsSinceEpoch;
    final keep = <String>[];
    final out = <SendEntry>[];
    for (final raw in p.getStringList('sendLog') ?? const <String>[]) {
      try {
        final m = jsonDecode(raw) as Map<String, dynamic>;
        final t = m['t'] as int;
        if (t < cutoff) continue;
        keep.add(raw);
        out.add(SendEntry(DateTime.fromMillisecondsSinceEpoch(t), m['k'] as String,
            m['f'] as String, (m['n'] as int?) ?? 1));
      } catch (_) {}
    }
    await p.setStringList('sendLog', keep);
    out.sort((a, b) => b.time.compareTo(a.time));
    return out;
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
    final cp = (await _p).getString('batchCompPath');
    if (cp != null) keep.add(cp);
    final pdfPath = (await pdf())?.file.path;
    if (pdfPath != null) keep.add(pdfPath);
    await for (final e in (await dir()).list()) {
      if (e is File && !keep.contains(e.path)) await del(e.path);
    }
  }
}

/// بيتأكد إن الصورة مش سودا بالكامل (حصل مرة بعد الخروج والرجوع).
Future<bool> _looksBlack(Uint8List jpg) async {
  try {
    final img = await decodeImage(jpg);
    final w = img.width;
    final h = img.height;
    final bd = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    img.dispose();
    if (bd == null) return false;
    final px = bd.buffer.asUint8List();
    var sum = 0;
    var n = 0;
    for (var y = 0; y < h; y += 40) {
      for (var x = 0; x < w; x += 40) {
        final i = (y * w + x) * 4;
        sum += px[i] + px[i + 1] + px[i + 2];
        n += 3;
      }
    }
    return n > 0 && sum / n < 10;
  } catch (_) {
    return false;
  }
}

/// صورة الباتش النهائية (بالورقة). بتتحفظ ومبتتعملش تاني لو مفيش حاجة اتغيرت،
/// وبتتفحص عشان متطلعش سودا؛ لو طلعت سودا بتتعاد لحد 3 مرات.
Future<Uint8List> batchComposed(String img, Session s) async {
  final p = await SharedPreferences.getInstance();
  final sig = '$img|${s.name}|${s.unit.name}|${s.building}|${s.shortDate}';
  final cp = p.getString('batchCompPath');
  if (cp != null && p.getString('batchCompSig') == sig && File(cp).existsSync()) {
    return File(cp).readAsBytes();
  }
  Uint8List? out;
  for (var i = 0; i < 3 && out == null; i++) {
    final b = await composeBatch(img, s);
    if (!await _looksBlack(b)) out = b;
  }
  if (out == null) throw 'تعذر تجهيز صورة الباتش، جرّب تصوّرها تاني';
  final f = File('${(await Store.dir()).path}/bc_${DateTime.now().microsecondsSinceEpoch}.jpg');
  await f.writeAsBytes(out);
  if (cp != null && cp != f.path) await Store.del(cp);
  await p.setString('batchCompPath', f.path);
  await p.setString('batchCompSig', sig);
  return out;
}

/// نسخ الصورة من مكان الماسح المؤقت لمكان ثابت (مضغوطة).
Future<String> persistImage(String src, String name) async {
  final bytes = await _shrink(src, width: 1600, quality: 80);
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

// ===== مصادر الصور =====
enum CaptureSource { smart, camera, gallery }

/// الماسح الذكي (ماسح جوجل): قص تلقائي + فلاتر. لو مش شغال بيتحول للكاميرا العادية + المحرر.
Future<List<String>> scanImages(BuildContext context, int limit) async {
  if (!await ensureCamera(context)) return [];
  if (!context.mounted) return [];
  final scanner = DocumentScanner(
    options: DocumentScannerOptions(
      mode: ScannerMode.full,
      pageLimit: limit,
      isGalleryImport: false,
    ),
  );
  try {
    final r = await scanner.scanDocument();
    return List<String>.from(r.images ?? const []);
  } catch (e) {
    if (e.toString().toLowerCase().contains('cancel')) return [];
    if (!context.mounted) return [];
    snack(context, 'الماسح الذكي مش شغال على الموبايل ده، هنفتح الكاميرا العادية');
    return cameraFlow(context);
  } finally {
    scanner.close();
  }
}

/// كاميرا عادية ثم المحرر (قص حر + فلاتر).
Future<List<String>> cameraFlow(BuildContext context) async {
  if (!await ensureCamera(context)) return [];
  if (!context.mounted) return [];
  try {
    final x = await ImagePicker().pickImage(source: ImageSource.camera, maxWidth: 2400, imageQuality: 90);
    if (x == null || !context.mounted) return [];
    final e = await editImage(context, x.path);
    return e == null ? [] : [e];
  } catch (_) {
    if (context.mounted) snack(context, 'تعذر فتح الكاميرا');
    return [];
  }
}

/// صور من المعرض: كل صورة بتفتح في المحرر (قص حر + فلاتر + تدوير).
Future<List<String>> galleryFlow(BuildContext context, {bool multi = true}) async {
  try {
    final picker = ImagePicker();
    List<String> paths;
    if (multi) {
      final xs = await picker.pickMultiImage(maxWidth: 2400, imageQuality: 90);
      paths = xs.map((e) => e.path).toList();
    } else {
      final x = await picker.pickImage(source: ImageSource.gallery, maxWidth: 2400, imageQuality: 90);
      paths = x == null ? <String>[] : [x.path];
    }
    final out = <String>[];
    for (var i = 0; i < paths.length; i++) {
      if (!context.mounted) break;
      final e = await editImage(context, paths[i],
          title: paths.length > 1 ? 'صورة ${i + 1} من ${paths.length}' : null);
      if (e != null) out.add(e);
    }
    return out;
  } catch (_) {
    if (context.mounted) snack(context, 'تعذر فتح المعرض');
    return [];
  }
}

/// بيسأل: ماسح ذكي / كاميرا عادية / معرض، وبيكمل على الاختيار.
Future<List<String>> captureFlow(BuildContext context,
    {required bool multi, bool allowGallery = true}) async {
  final src = await showModalBottomSheet<CaptureSource>(
    context: context,
    builder: (c) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text('اختار طريقة التصوير', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        ),
        ListTile(
          leading: const Icon(Icons.document_scanner, color: kBrand),
          title: const Text('الماسح الذكي (كاميرا)', style: TextStyle(fontWeight: FontWeight.bold)),
          subtitle: const Text('بيقص الورقة تلقائي وفيه فلاتر وتنظيف'),
          onTap: () => Navigator.pop(c, CaptureSource.smart),
        ),
        ListTile(
          leading: const Icon(Icons.photo_camera, color: kBrand),
          title: const Text('كاميرا عادية', style: TextStyle(fontWeight: FontWeight.bold)),
          subtitle: const Text('صوّر وبعدين اقص وظبط الصورة بنفسك'),
          onTap: () => Navigator.pop(c, CaptureSource.camera),
        ),
        if (allowGallery)
          ListTile(
            leading: const Icon(Icons.photo_library, color: kBrand),
            title: const Text('المعرض', style: TextStyle(fontWeight: FontWeight.bold)),
            subtitle: const Text('اختار صورة واقص وظبط الصورة بنفسك'),
            onTap: () => Navigator.pop(c, CaptureSource.gallery),
          ),
        const SizedBox(height: 8),
      ]),
    ),
  );
  if (src == null || !context.mounted) return [];
  switch (src) {
    case CaptureSource.smart:
      return scanImages(context, multi ? 10 : 1);
    case CaptureSource.camera:
      return cameraFlow(context);
    case CaptureSource.gallery:
      return galleryFlow(context, multi: multi);
  }
}

// ===== محرر الصورة: قص حر من كل الاتجاهات + فلاتر + تدوير =====
enum EditFilter { original, auto, bw, gray, vivid }

String filterName(EditFilter f) => switch (f) {
      EditFilter.original => 'الأصل',
      EditFilter.auto => 'تحسين تلقائي',
      EditFilter.bw => 'أبيض وأسود',
      EditFilter.gray => 'رمادي',
      EditFilter.vivid => 'ألوان زاهية',
    };

List<double> filterMatrix(EditFilter f, int black, int white) {
  final sc = 255 / (white - black);
  final off = -black * sc;
  const r = 0.299, g = 0.587, b = 0.114;
  switch (f) {
    case EditFilter.original:
      return <double>[1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0];
    case EditFilter.auto:
      return <double>[sc, 0, 0, 0, off, 0, sc, 0, 0, off, 0, 0, sc, 0, off, 0, 0, 0, 1, 0];
    case EditFilter.gray:
      {
        final row = <double>[r * sc, g * sc, b * sc, 0, off];
        return <double>[...row, ...row, ...row, 0, 0, 0, 1, 0];
      }
    case EditFilter.bw:
      {
        const k = 2.6, pivot = 165.0;
        final row = <double>[r * sc * k, g * sc * k, b * sc * k, 0, (off - pivot) * k + pivot];
        return <double>[...row, ...row, ...row, 0, 0, 0, 1, 0];
      }
    case EditFilter.vivid:
      {
        const sat = 1.6;
        final a = r * (1 - sat), bb = g * (1 - sat), c = b * (1 - sat);
        return <double>[
          (a + sat) * sc, bb * sc, c * sc, 0, off, //
          a * sc, (bb + sat) * sc, c * sc, 0, off, //
          a * sc, bb * sc, (c + sat) * sc, 0, off, //
          0, 0, 0, 1, 0,
        ];
      }
  }
}

class DocInfo {
  final Rect crop; // نسب 0..1
  final int black, white;
  DocInfo(this.crop, this.black, this.white);
}

/// بيحلل الصورة: حدود الورقة الفاتحة (اقتراح للقص) + نقطتي الأسود والأبيض للتحسين التلقائي.
Future<DocInfo> analyzeDoc(ui.Image img) async {
  const full = Rect.fromLTRB(0, 0, 1, 1);
  try {
    final w = img.width;
    final h = img.height;
    final bd = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (bd == null) return DocInfo(full, 0, 255);
    final px = bd.buffer.asUint8List();
    const step = 4;
    final gw = w ~/ step;
    final gh = h ~/ step;
    final lum = Uint8List(gw * gh);
    final hist = List<int>.filled(256, 0);
    for (var gy = 0; gy < gh; gy++) {
      for (var gx = 0; gx < gw; gx++) {
        final i = ((gy * step) * w + gx * step) * 4;
        final l = (px[i] * 299 + px[i + 1] * 587 + px[i + 2] * 114) ~/ 1000;
        lum[gy * gw + gx] = l;
        hist[l]++;
      }
    }
    int pct(double f) {
      final target = (gw * gh * f).round();
      var acc = 0;
      for (var v = 0; v < 256; v++) {
        acc += hist[v];
        if (acc >= target) return v;
      }
      return 255;
    }

    final black = pct(0.02);
    final white = pct(0.90);
    if (white - black < 60) return DocInfo(full, 0, 255);
    final t = black + ((white - black) * 0.6).round();
    final rowB = List<int>.filled(gh, 0);
    final colB = List<int>.filled(gw, 0);
    for (var gy = 0; gy < gh; gy++) {
      for (var gx = 0; gx < gw; gx++) {
        if (lum[gy * gw + gx] > t) {
          rowB[gy]++;
          colB[gx]++;
        }
      }
    }
    int firstOver(List<int> a, double lim) {
      for (var i = 0; i < a.length; i++) {
        if (a[i] > lim) return i;
      }
      return -1;
    }

    int lastOver(List<int> a, double lim) {
      for (var i = a.length - 1; i >= 0; i--) {
        if (a[i] > lim) return i;
      }
      return -1;
    }

    final top = firstOver(rowB, gw * 0.3);
    final bottom = lastOver(rowB, gw * 0.3);
    final left = firstOver(colB, gh * 0.3);
    final right = lastOver(colB, gh * 0.3);
    var crop = full;
    if (top >= 0 && bottom > top && left >= 0 && right > left) {
      final frac = ((right - left + 1) * (bottom - top + 1)) / (gw * gh);
      if (frac >= 0.35 && frac <= 0.97) {
        const pad = 0.015;
        crop = Rect.fromLTRB(
          (left * step / w - pad).clamp(0.0, 1.0).toDouble(),
          (top * step / h - pad).clamp(0.0, 1.0).toDouble(),
          (((right + 1) * step) / w + pad).clamp(0.0, 1.0).toDouble(),
          (((bottom + 1) * step) / h + pad).clamp(0.0, 1.0).toDouble(),
        );
      }
    }
    return DocInfo(crop, black, white);
  } catch (_) {
    return DocInfo(full, 0, 255);
  }
}

/// بيفتح المحرر ويرجّع مسار الصورة بعد التعديل (أو null لو اتلغى/اتخطى).
Future<String?> editImage(BuildContext context, String src, {String? title}) =>
    Navigator.push<String>(
      context,
      MaterialPageRoute(fullscreenDialog: true, builder: (_) => ScanEditorPage(path: src, title: title)),
    );

class _CropPainter extends CustomPainter {
  final ui.Image img;
  final Rect disp; // مكان الصورة على الشاشة
  final Rect crop; // نسب 0..1
  final List<double> matrix;
  _CropPainter(this.img, this.disp, this.crop, this.matrix);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawImageRect(
      img,
      Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
      disp,
      Paint()
        ..filterQuality = FilterQuality.medium
        ..colorFilter = ColorFilter.matrix(matrix),
    );
    final r = Rect.fromLTRB(disp.left + crop.left * disp.width, disp.top + crop.top * disp.height,
        disp.left + crop.right * disp.width, disp.top + crop.bottom * disp.height);
    final dim = Path()
      ..addRect(disp)
      ..addRect(r)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(dim, Paint()..color = Colors.black54);
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = Colors.white;
    canvas.drawRect(r, line);
    final grid = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8
      ..color = Colors.white38;
    for (var i = 1; i < 3; i++) {
      canvas.drawLine(Offset(r.left + r.width * i / 3, r.top), Offset(r.left + r.width * i / 3, r.bottom), grid);
      canvas.drawLine(Offset(r.left, r.top + r.height * i / 3), Offset(r.right, r.top + r.height * i / 3), grid);
    }
    final fill = Paint()..color = kBrand;
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = Colors.white;
    final pts = <Offset>[
      r.topLeft, r.topRight, r.bottomLeft, r.bottomRight,
      Offset(r.center.dx, r.top), Offset(r.center.dx, r.bottom),
      Offset(r.left, r.center.dy), Offset(r.right, r.center.dy),
    ];
    for (var i = 0; i < pts.length; i++) {
      canvas.drawCircle(pts[i], i < 4 ? 11 : 8, fill);
      canvas.drawCircle(pts[i], i < 4 ? 11 : 8, ring);
    }
  }

  @override
  bool shouldRepaint(covariant _CropPainter old) => true;
}

class ScanEditorPage extends StatefulWidget {
  final String path;
  final String? title;
  const ScanEditorPage({super.key, required this.path, this.title});
  @override
  State<ScanEditorPage> createState() => _ScanEditorPageState();
}

class _ScanEditorPageState extends State<ScanEditorPage> {
  ui.Image? img;
  Rect crop = const Rect.fromLTRB(0, 0, 1, 1);
  int black = 0, white = 255;
  EditFilter filter = EditFilter.auto;
  bool saving = false;
  String? error;
  int _grab = 0; // 1 يسار، 2 فوق، 4 يمين، 8 تحت، 16 تحريك الإطار كله
  Rect _disp = Rect.zero;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    img?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final bytes = await _shrink(widget.path, width: 1600, quality: 90);
      final im = await decodeImage(bytes);
      final info = await analyzeDoc(im);
      final p = await SharedPreferences.getInstance();
      final fi = (p.getInt('editFilter') ?? EditFilter.auto.index)
          .clamp(0, EditFilter.values.length - 1)
          .toInt();
      if (!mounted) {
        im.dispose();
        return;
      }
      setState(() {
        img = im;
        crop = info.crop;
        black = info.black;
        white = info.white;
        filter = EditFilter.values[fi];
      });
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  Future<void> _rotate(bool cw) async {
    final im = img;
    if (im == null) return;
    final w = im.width.toDouble();
    final h = im.height.toDouble();
    final rec = ui.PictureRecorder();
    final c = Canvas(rec, Rect.fromLTWH(0, 0, h, w));
    if (cw) {
      c.translate(h, 0);
      c.rotate(math.pi / 2);
    } else {
      c.translate(0, w);
      c.rotate(-math.pi / 2);
    }
    c.drawImage(im, Offset.zero, Paint());
    final out = await rec.endRecording().toImage(h.toInt(), w.toInt());
    if (!mounted) {
      out.dispose();
      return;
    }
    final k = crop;
    setState(() {
      img = out;
      crop = cw
          ? Rect.fromLTRB(1 - k.bottom, k.left, 1 - k.top, k.right)
          : Rect.fromLTRB(k.top, 1 - k.right, k.bottom, 1 - k.left);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => im.dispose());
  }

  void _panStart(Offset pos) {
    final d = _disp;
    final r = Rect.fromLTRB(d.left + crop.left * d.width, d.top + crop.top * d.height,
        d.left + crop.right * d.width, d.top + crop.bottom * d.height);
    const hit = 36.0;
    final inY = pos.dy > r.top - hit && pos.dy < r.bottom + hit;
    final inX = pos.dx > r.left - hit && pos.dx < r.right + hit;
    var g = 0;
    final dl = (pos.dx - r.left).abs(), dr = (pos.dx - r.right).abs();
    final dt = (pos.dy - r.top).abs(), db = (pos.dy - r.bottom).abs();
    if (inY && dl < hit && dl <= dr) g |= 1;
    if (inY && dr < hit && dr < dl) g |= 4;
    if (inX && dt < hit && dt <= db) g |= 2;
    if (inX && db < hit && db < dt) g |= 8;
    if (g == 0 && r.contains(pos)) g = 16;
    _grab = g;
  }

  void _panUpdate(Offset delta) {
    if (_grab == 0 || _disp.width == 0) return;
    final dx = delta.dx / _disp.width;
    final dy = delta.dy / _disp.height;
    var l = crop.left, t = crop.top, r = crop.right, b = crop.bottom;
    const minS = 0.08;
    if (_grab == 16) {
      final w = r - l, h = b - t;
      l = (l + dx).clamp(0.0, 1.0 - w).toDouble();
      t = (t + dy).clamp(0.0, 1.0 - h).toDouble();
      r = l + w;
      b = t + h;
    } else {
      if (_grab & 1 != 0) l = (l + dx).clamp(0.0, r - minS).toDouble();
      if (_grab & 4 != 0) r = (r + dx).clamp(l + minS, 1.0).toDouble();
      if (_grab & 2 != 0) t = (t + dy).clamp(0.0, b - minS).toDouble();
      if (_grab & 8 != 0) b = (b + dy).clamp(t + minS, 1.0).toDouble();
    }
    setState(() => crop = Rect.fromLTRB(l, t, r, b));
  }

  Future<void> _done() async {
    final im = img;
    if (im == null) return;
    setState(() => saving = true);
    try {
      final sx = crop.left * im.width;
      final sy = crop.top * im.height;
      final sw = crop.width * im.width;
      final sh = crop.height * im.height;
      final rec = ui.PictureRecorder();
      final c = Canvas(rec, Rect.fromLTWH(0, 0, sw, sh));
      c.drawImageRect(
        im,
        Rect.fromLTWH(sx, sy, sw, sh),
        Rect.fromLTWH(0, 0, sw, sh),
        Paint()
          ..filterQuality = FilterQuality.medium
          ..colorFilter = ColorFilter.matrix(filterMatrix(filter, black, white)),
      );
      final out = await rec.endRecording().toImage(math.max(1, sw.ceil()), math.max(1, sh.ceil()));
      final png = await out.toByteData(format: ui.ImageByteFormat.png);
      out.dispose();
      if (png == null) throw 'تعذر حفظ الصورة';
      final jpg = await FlutterImageCompress.compressWithList(
        png.buffer.asUint8List(),
        minWidth: 4000,
        minHeight: 6000,
        quality: 85,
        format: CompressFormat.jpeg,
      );
      final f = File('${(await Store.dir()).path}/e_${DateTime.now().microsecondsSinceEpoch}.jpg');
      await f.writeAsBytes(jpg);
      await (await SharedPreferences.getInstance()).setInt('editFilter', filter.index);
      if (mounted) Navigator.pop(context, f.path);
    } catch (e) {
      if (mounted) {
        setState(() => saving = false);
        snack(context, 'حصل خطأ: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final im = img;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        leading: IconButton(
            tooltip: 'تخطي',
            icon: const Icon(Icons.close),
            onPressed: saving ? null : () => Navigator.pop(context)),
        title: Text(widget.title ?? 'تعديل الصورة', style: const TextStyle(fontSize: 16)),
        actions: [
          TextButton(
            onPressed: (saving || im == null) ? null : _done,
            child: saving
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('تم', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
      body: error != null
          ? Center(child: Text('حصل خطأ: $error', style: const TextStyle(color: Colors.white)))
          : im == null
              ? const Center(child: CircularProgressIndicator())
              : Column(children: [
                  Expanded(
                    child: LayoutBuilder(builder: (ctx, cons) {
                      const m = 20.0;
                      final sc = math.min((cons.maxWidth - 2 * m) / im.width, (cons.maxHeight - 2 * m) / im.height);
                      final dw = im.width * sc, dh = im.height * sc;
                      _disp = Rect.fromLTWH((cons.maxWidth - dw) / 2, (cons.maxHeight - dh) / 2, dw, dh);
                      return GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onPanStart: (d) => _panStart(d.localPosition),
                        onPanUpdate: (d) => _panUpdate(d.delta),
                        onPanEnd: (_) => _grab = 0,
                        child: CustomPaint(
                          size: Size.infinite,
                          painter: _CropPainter(im, _disp, crop, filterMatrix(filter, black, white)),
                        ),
                      );
                    }),
                  ),
                  const Padding(
                    padding: EdgeInsets.only(bottom: 4),
                    child: Text('اسحب الدواير أو الجوانب للقص من أي اتجاه',
                        style: TextStyle(color: Colors.white54, fontSize: 12)),
                  ),
                  SizedBox(
                    height: 50,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      children: [
                        for (final f in EditFilter.values)
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                            child: ChoiceChip(
                              label: Text(filterName(f)),
                              selected: filter == f,
                              onSelected: saving ? null : (_) => setState(() => filter = f),
                            ),
                          ),
                      ],
                    ),
                  ),
                  SafeArea(
                    top: false,
                    child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                      IconButton(
                          tooltip: 'تدوير لليسار',
                          color: Colors.white,
                          iconSize: 30,
                          onPressed: saving ? null : () => _rotate(false),
                          icon: const Icon(Icons.rotate_left)),
                      TextButton.icon(
                        style: TextButton.styleFrom(foregroundColor: Colors.white),
                        onPressed: saving ? null : () => setState(() => crop = const Rect.fromLTRB(0, 0, 1, 1)),
                        icon: const Icon(Icons.crop_free),
                        label: const Text('الصورة كلها'),
                      ),
                      IconButton(
                          tooltip: 'تدوير لليمين',
                          color: Colors.white,
                          iconSize: 30,
                          onPressed: saving ? null : () => _rotate(true),
                          icon: const Icon(Icons.rotate_right)),
                    ]),
                  ),
                ]),
    );
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

/// تجهيز صورة الباتش (مع الشريط) باسم رقم الوحدة وإرسالها.
Future<bool> sendBatchFile(BuildContext context, Session s, String img) async {
  final bytes = await batchComposed(img, s);
  final out = File('${(await Store.dir()).path}/${s.batchName}.jpg');
  await out.writeAsBytes(bytes);
  if (!context.mounted) return false;
  final ok = await shareFiles(context, [out.path]);
  if (ok) await Store.afterBatchSent('${s.batchName}.jpg');
  return ok;
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

/// صورة إيصال والورقة فوقها (نفس شكل الـ PDF).
class ReceiptPreview extends StatelessWidget {
  final String path;
  final Tag? tag;
  final int? cacheWidth;
  final double top; // بُعد الورقة عن أعلى الصورة (نسبة من العرض)
  const ReceiptPreview(
      {super.key, required this.path, this.tag, this.cacheWidth, this.top = kTagTop});
  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (ctx, cons) {
        final cw = cons.maxWidth;
        return Stack(children: [
          Image.file(File(path), width: double.infinity, fit: BoxFit.fitWidth, cacheWidth: cacheWidth),
          if (tag != null)
            Positioned(
              top: cw * top,
              left: 0,
              right: 0,
              child: Center(child: Image.memory(tag!.png, width: cw * tag!.w / 1000)),
            ),
        ]);
      });
}

void snack(BuildContext context, String m) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

// ===== التطبيق =====
void main() => runApp(const A2RApp());

// ===== الشكل =====
const kBrand = Color(0xFF0B5FA5);
const kBrandDark = Color(0xFF083E70);
const kInk = Color(0xFF1B2733);

/// رقم الإصدار (بيتحط أوتوماتيك من GitHub وقت البناء، مثال: 1.12)
const kVersion = String.fromEnvironment('APP_VERSION', defaultValue: 'تجريبي');
String get kVersionLabel => 'الإصدار $kVersion';

InputDecoration fieldDec(String label, IconData icon) => InputDecoration(
      labelText: label,
      prefixIcon: Icon(icon, color: kBrand),
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
      enabledBorder:
          OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: Colors.blueGrey.shade100)),
      focusedBorder:
          OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: kBrand, width: 2)),
    );

/// شعار A2R بخلفية متدرجة فوق شاشة الدخول.
class BrandHeader extends StatelessWidget {
  const BrandHeader({super.key});
  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 26),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
              begin: Alignment.topRight, end: Alignment.bottomLeft, colors: [kBrand, kBrandDark]),
          borderRadius: BorderRadius.circular(26),
          boxShadow: [BoxShadow(color: kBrand.withAlpha(70), blurRadius: 18, offset: const Offset(0, 8))],
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Image.asset(
            'assets/logo.png',
            width: 200,
            errorBuilder: (_, __, ___) => const Text('A2R',
                style: TextStyle(
                    fontSize: 46, fontWeight: FontWeight.w900, letterSpacing: 6, color: Colors.white, height: 1.1)),
          ),
          const SizedBox(height: 10),
          Container(width: 48, height: 3, decoration: BoxDecoration(color: Colors.white38, borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 10),
          Text('تجميع إيصالات الدفع', style: TextStyle(fontSize: 14, color: Colors.white.withAlpha(210))),
        ]),
      );
}

class A2RApp extends StatelessWidget {
  const A2RApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'A2R',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(seedColor: kBrand),
          scaffoldBackgroundColor: const Color(0xFFF2F6FB),
          filledButtonTheme: FilledButtonThemeData(
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 52),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ),
          outlinedButtonTheme: OutlinedButtonThemeData(
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(0, 52),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ),
        ),
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
            const SizedBox(height: 8),
            const BrandHeader(),
            Expanded(
              child: Center(
                child: SingleChildScrollView(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
            DropdownButtonFormField<String>(
              value: name,
              isExpanded: true,
              decoration: fieldDec('الاسم', Icons.person_outline),
              items: kNames.map((n) => DropdownMenuItem(value: n, child: Text(n))).toList(),
              onChanged: (v) => setState(() => name = v),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<Unit>(
              value: unit,
              isExpanded: true,
              decoration: fieldDec('الوحدة', Icons.store_mall_directory_outlined),
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
                decoration: fieldDec('المبنى', Icons.apartment),
                items: unit!.buildings
                    .map((b) => DropdownMenuItem(value: b, child: Text(b)))
                    .toList(),
                onChanged: (v) => setState(() => building = v),
              ),
            ],
                  ]),
                ),
              ),
            ),
            SizedBox(
              width: double.infinity,
              height: 56,
              child: FilledButton(
                onPressed: _ready ? _start : null,
                child: const Text('ابدأ', style: TextStyle(fontSize: 20)),
              ),
            ),
            const SizedBox(height: 10),
            Text(kVersionLabel,
                style: TextStyle(fontSize: 12, color: Colors.blueGrey.shade400)),
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

  Widget _big(IconData icon, String label, bool done, VoidCallback onTap,
          {Color color = kBrand}) =>
      SizedBox(
        height: 150,
        child: Material(
          color: Colors.white,
          elevation: 3,
          shadowColor: color.withAlpha(90),
          borderRadius: BorderRadius.circular(24),
          child: InkWell(
            borderRadius: BorderRadius.circular(24),
            onTap: onTap,
            child: Stack(children: [
              Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Container(
                    width: 70,
                    height: 70,
                    decoration: BoxDecoration(color: color.withAlpha(30), shape: BoxShape.circle),
                    child: Icon(icon, size: 36, color: color),
                  ),
                  const SizedBox(height: 12),
                  Text(label,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: kInk)),
                ]),
              ),
              if (done)
                const Positioned(
                  top: 10,
                  left: 10,
                  child: CircleAvatar(
                      radius: 13,
                      backgroundColor: Colors.green,
                      child: Icon(Icons.check, color: Colors.white, size: 18)),
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
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: const Text('A2R',
            style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 4, color: kBrandDark)),
        actions: [
          IconButton(
            tooltip: 'سجل الإرسال',
            icon: const Icon(Icons.history, color: kBrandDark),
            onPressed: () => _open(const SendLogScreen()),
          ),
        ],
      ),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        if (busy) const LinearProgressIndicator(),
        Container(
          decoration: BoxDecoration(
            gradient: const LinearGradient(
                begin: Alignment.topRight, end: Alignment.bottomLeft, colors: [kBrand, kBrandDark]),
            borderRadius: BorderRadius.circular(22),
            boxShadow: [BoxShadow(color: kBrand.withAlpha(70), blurRadius: 16, offset: const Offset(0, 6))],
          ),
          child: DefaultTextStyle.merge(
            style: const TextStyle(color: Colors.white),
            child: IconTheme(
            data: const IconThemeData(color: Colors.white),
            child: Padding(
            padding: const EdgeInsets.all(16),
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
                        style: TextStyle(fontSize: 12, color: Colors.white70))),
              ]),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: TextButton.icon(
                  style: TextButton.styleFrom(foregroundColor: Colors.white),
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.switch_account),
                  label: const Text('تغيير الحساب'),
                ),
              ),
            ]),
          ),
          ),
          ),
        ),
        const SizedBox(height: 18),
        Row(children: [
          Expanded(
              child: _big(Icons.receipt_long, 'الباتش', batchSent,
                  () => _open(BatchScreen(session: s)))),
          const SizedBox(width: 12),
          Expanded(
              child: _big(Icons.payments, 'إيصالات الدفع', receiptsSent,
                  () => _open(ReceiptsScreen(session: s)),
                  color: const Color(0xFF00897B))),
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
                  child: Image.file(File(bi), width: 48, height: 48, fit: BoxFit.cover, cacheWidth: 150),
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
                  child: Image.file(File(draft.first), width: 48, height: 48, fit: BoxFit.cover, cacheWidth: 150),
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
        const SizedBox(height: 28),
        Center(
          child: Text('A2R - $kVersionLabel',
              style: TextStyle(fontSize: 12, color: Colors.blueGrey.shade400)),
        ),
        const SizedBox(height: 8),
      ]),
    );
  }
}

// ===== سجل الإرسال =====
String _hm(DateTime t) {
  final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
  return '$h:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'ص' : 'م'}';
}

String _dayTitle(DateTime t) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final d = DateTime(t.year, t.month, t.day);
  final diff = today.difference(d).inDays;
  final date = '${t.day}/${t.month}/${t.year}';
  if (diff == 0) return 'النهاردة - $date';
  if (diff == 1) return 'امبارح - $date';
  return date;
}

class SendLogScreen extends StatefulWidget {
  const SendLogScreen({super.key});
  @override
  State<SendLogScreen> createState() => _SendLogScreenState();
}

class _SendLogScreenState extends State<SendLogScreen> {
  List<SendEntry>? items;

  @override
  void initState() {
    super.initState();
    Store.log().then((l) {
      if (mounted) setState(() => items = l);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = items;
    final children = <Widget>[];
    String? lastDay;
    for (final e in l ?? const <SendEntry>[]) {
      final day = _dayTitle(e.time);
      if (day != lastDay) {
        lastDay = day;
        children.add(Padding(
          padding: const EdgeInsets.fromLTRB(4, 16, 4, 6),
          child: Text(day, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: kBrandDark)),
        ));
      }
      final isBatch = e.kind == 'batch';
      children.add(Card(
        child: ListTile(
          leading: CircleAvatar(
            backgroundColor: (isBatch ? kBrand : const Color(0xFF00897B)).withAlpha(30),
            child: Icon(isBatch ? Icons.receipt_long : Icons.payments,
                color: isBatch ? kBrand : const Color(0xFF00897B)),
          ),
          title: Text(isBatch ? 'الباتش' : 'إيصالات الدفع (${e.pages} صفحة)',
              style: const TextStyle(fontWeight: FontWeight.bold)),
          subtitle: Text(e.file, maxLines: 2, overflow: TextOverflow.ellipsis),
          trailing: Text(_hm(e.time), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
        ),
      ));
    }
    return Scaffold(
      appBar: AppBar(title: const Text('سجل الإرسال')),
      body: l == null
          ? const Center(child: CircularProgressIndicator())
          : l.isEmpty
              ? const Center(child: Text('مفيش حاجة اتبعتت في آخر 7 أيام', style: TextStyle(fontSize: 16)))
              : ListView(padding: const EdgeInsets.all(12), children: [
                  ...children,
                  const SizedBox(height: 16),
                  Center(
                    child: Text('السجل بيحتفظ بآخر 7 أيام بس',
                        style: TextStyle(fontSize: 12, color: Colors.blueGrey.shade400)),
                  ),
                  const SizedBox(height: 8),
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
  Uint8List? composed; // الصورة النهائية زي ما هتتبعت
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
      try {
        final st = await batchComposed(cur, widget.session);
        if (!mounted) return;
        setState(() {
          img = cur;
          composed = st;
        });
      } catch (e) {
        if (!mounted) return;
        snack(context, 'حصل خطأ: $e');
        Navigator.pop(context);
      }
    } else {
      _capture(all: true);
    }
  }

  /// all=true: ماسح ذكي / كاميرا / معرض (أول ما تفتح الشاشة). غير كده: الكاميرا بس.
  Future<void> _capture({bool all = false}) async {
    final r = await captureFlow(context, multi: false, allowGallery: all);
    if (!mounted) return;
    if (r.isEmpty) {
      if (img == null) Navigator.pop(context);
      return;
    }
    await _useImage(r.first);
  }

  Future<void> _gallery() async {
    final r = await galleryFlow(context, multi: false);
    if (r.isEmpty || !mounted) return;
    await _useImage(r.first);
  }

  /// قص/فلاتر/تدوير لصورة الباتش الحالية.
  Future<void> _edit() async {
    final cur = img;
    if (cur == null) return;
    final e = await editImage(context, cur, title: 'تعديل صورة الباتش');
    if (e == null || !mounted) return;
    await _useImage(e);
  }

  Future<void> _useImage(String src) async {
    setState(() => busy = true);
    try {
      final path = await persistImage(src, 'batch_${DateTime.now().microsecondsSinceEpoch}.jpg');
      await Store.setBatchImg(path); // بتمسح القديمة
      final st = await batchComposed(path, widget.session);
      if (!mounted) return;
      setState(() {
        img = path;
        composed = st;
      });
    } catch (e) {
      if (mounted) snack(context, 'حصل خطأ: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
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

  Widget _content({int? cacheWidth}) =>
      Image.memory(composed!, width: double.infinity, fit: BoxFit.fitWidth);

  @override
  Widget build(BuildContext context) {
    final ready = img != null && composed != null;
    return Scaffold(
      appBar: AppBar(title: const Text('الباتش')),
      body: !ready
          ? const Center(child: CircularProgressIndicator())
          : Column(children: [
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(12),
                  child: GestureDetector(
                    onTap: () => Navigator.push(
                        context, MaterialPageRoute(builder: (_) => ZoomPage(child: _content()))),
                    child: Container(
                      decoration: BoxDecoration(border: Border.all(color: Colors.grey)),
                      child: _content(cacheWidth: 1000),
                    ),
                  ),
                ),
              ),
              const Padding(
                padding: EdgeInsets.only(bottom: 4),
                child: Text('اضغط على الصورة لتكبيرها',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
              ),
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
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
                      height: 48,
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
    if (d.isEmpty) _add(all: true);
  }

  /// تصوير: ماسح ذكي أو كاميرا (all=true بتضيف المعرض كمان).
  Future<void> _add({bool all = false}) async {
    final r = await captureFlow(context, multi: true, allowGallery: all);
    if (r.isEmpty || !mounted) return;
    await _saveAll(r);
  }

  /// صور من المعرض: كل صورة بتفتح في المحرر.
  Future<void> _addGallery() async {
    final r = await galleryFlow(context);
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

  /// تدوير الصفحة 90 درجة (في اتجاه عقارب الساعة).
  Future<void> _rotate(int i) async {
    final old = imgs[i];
    setState(() => busy = true);
    try {
      final out = await FlutterImageCompress.compressWithFile(
        old,
        minWidth: 4000,
        minHeight: 4000,
        quality: 80,
        rotate: 90,
        format: CompressFormat.jpeg,
        keepExif: false,
      );
      if (out == null) throw 'تعذر تدوير الصورة';
      // اسم جديد عشان الصورة القديمة متفضلش في الكاش
      final f = File('${(await Store.dir()).path}/r_${DateTime.now().microsecondsSinceEpoch}.jpg');
      await f.writeAsBytes(out);
      await Store.replaceInDraft(old, f.path);
      if (!mounted) return;
      setState(() {
        final k = imgs.indexOf(old);
        if (k >= 0) imgs[k] = f.path;
        built = null;
      });
    } catch (e) {
      if (mounted) snack(context, 'حصل خطأ: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  /// استبدال صفحة واحدة بصورة جديدة (من غير ما تتمسح وتتصور من الأول).
  Future<void> _replace(int i) async {
    final old = imgs[i];
    final r = await captureFlow(context, multi: false);
    if (r.isEmpty || !mounted) return;
    setState(() => busy = true);
    try {
      final saved = await persistImage(r.first, 'r_${DateTime.now().microsecondsSinceEpoch}.jpg');
      await Store.replaceInDraft(old, saved);
      if (!mounted) return;
      setState(() {
        final k = imgs.indexOf(old);
        if (k >= 0) imgs[k] = saved;
        built = null;
      });
    } catch (e) {
      if (mounted) snack(context, 'حصل خطأ: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  /// قص حر + فلاتر + تدوير لصفحة موجودة.
  Future<void> _edit(int i) async {
    final old = imgs[i];
    final e = await editImage(context, old, title: 'تعديل صفحة ${i + 1}');
    if (e == null || !mounted) return;
    setState(() => busy = true);
    try {
      await Store.replaceInDraft(old, e);
      if (!mounted) return;
      setState(() {
        final k = imgs.indexOf(old);
        if (k >= 0) imgs[k] = e;
        built = null;
      });
    } catch (err) {
      if (mounted) snack(context, 'حصل خطأ: $err');
    } finally {
      if (mounted) setState(() => busy = false);
    }
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

  Widget _pill(IconData icon, String label, VoidCallback? onTap) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
              color: onTap == null ? Colors.black26 : Colors.black54,
              borderRadius: BorderRadius.circular(20)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 18, color: Colors.white),
            const SizedBox(width: 4),
            Text(label, style: const TextStyle(color: Colors.white, fontSize: 13)),
          ]),
        ),
      );

  Widget _item(int i) => Container(
        decoration: BoxDecoration(border: Border.all(color: Colors.grey)),
        child: Stack(children: [
          GestureDetector(
            onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => ZoomPage(child: ReceiptPreview(path: imgs[i], tag: tag)))),
            child: ReceiptPreview(path: imgs[i], tag: tag, cacheWidth: 900),
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
            right: 6,
            child: Row(children: [
              _pill(Icons.crop, 'تعديل', busy ? null : () => _edit(i)),
              const SizedBox(width: 6),
              _pill(Icons.rotate_right, 'تدوير', busy ? null : () => _rotate(i)),
              const SizedBox(width: 6),
              _pill(Icons.camera_alt, 'استبدال', busy ? null : () => _replace(i)),
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
