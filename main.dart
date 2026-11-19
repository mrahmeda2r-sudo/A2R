import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart' show ZipDecoder;
import 'package:excel/excel.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:image_picker/image_picker.dart' show ImagePicker, ImageSource;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

// ======================= الإعدادات =======================
const String kRoot = '/storage/emulated/0';
const String kDir = '$kRoot/A2R_Sender';
const String kFile = '$kDir/groups.xlsx';
const MethodChannel _ch = MethodChannel('a2r/share');

const Map<String, String> kKinds = {
  'text': 'نص فقط',
  'image': 'صورة فقط',
  'imageText': 'صورة مع نص',
  'stickers': 'استيكر أو أكثر',
};
// أقصى عدد ملفات في الرسالة (واتساب يقبل حتى 30). الاستيكرات: واحد أو أكثر بدون عدد محدد.
const Map<String, int> kLimit = {
  'text': 0,
  'image': 1,
  'imageText': 1,
  'stickers': 30,
};

/// اسم نوع الرسالة (يدعم المهام القديمة sticker1/sticker2).
String kindName(String k) =>
    kKinds[k] ?? (k.startsWith('sticker') ? 'استيكر' : k);

// ======================= الجروبات وملف Excel =======================
// لا توجد بيانات مدمجة في التطبيق: المصدر الوحيد هو ملف Excel (يُستورد من التطبيق أو يوضع في المجلد).

class G {
  final String name, numbers, teacher;
  final List<String> cats; // التصنيفات/الأيام (عمود E في Excel)
  const G(this.name, this.numbers, this.teacher, [this.cats = const []]);
  String get key => '$name|$numbers';
  String get title => numbers.isEmpty ? name : '$name  $numbers';

  /// كلمة البحث في واتساب: أول رقم، وإلا الاسم.
  String get searchKey {
    for (final n in numbers.split('/')) {
      if (n.trim().isNotEmpty) return n.trim();
    }
    return name;
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'numbers': numbers,
        'teacher': teacher,
        'cats': cats,
      };
  factory G.fromJson(Map<String, dynamic> j) => G(
      j['name'] as String,
      j['numbers'] as String,
      j['teacher'] as String,
      ((j['cats'] as List?) ?? const []).map((e) => e.toString()).toList());
}

String normDigits(String s) {
  const ar = '٠١٢٣٤٥٦٧٨٩', fa = '۰۱۲۳۴۵۶۷۸۹';
  final b = StringBuffer();
  for (final r in s.runes) {
    final ch = String.fromCharCode(r);
    var i = ar.indexOf(ch);
    if (i < 0) i = fa.indexOf(ch);
    b.write(i >= 0 ? '$i' : ch);
  }
  return b.toString();
}

String _clean(String s) => normDigits(s)
    .replaceAll(RegExp(r'[\u200e\u200f\u202a-\u202e]'), '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

final RegExp _tail = RegExp(r'^(.*?)\s*(\d[\d\s/]*)$');

const List<String> kDays = [
  'السبت',
  'الأحد',
  'الاثنين',
  'الثلاثاء',
  'الأربعاء',
  'الخميس',
  'الجمعة',
];
const String kNoCat = '__none';

/// يقسم خانة التصنيف: السبت/الثلاثاء أو السبت، الثلاثاء أو سطر لكل يوم.
List<String> parseCats(String s) => normDigits(s)
    .split(RegExp(r'[,،;؛/|\n]'))
    .map(_clean)
    .where((e) => e.isNotEmpty)
    .toList();

bool inCat(G g, String? cat) {
  if (cat == null) return true;
  if (cat == kNoCat) return g.cats.isEmpty && !Wa.inAnyWaCat(g);
  final n = _nz(cat);
  if (g.cats.any((c) => _nz(c) == n)) return true;
  return Wa.inWaCat(g, cat);
}

/// الأيام أولاً بترتيب الأسبوع ثم باقي التصنيفات أبجدياً.
List<String> allCats(List<G> gs) {
  final seen = <String, String>{};
  for (final g in gs) {
    for (final c in g.cats) {
      seen.putIfAbsent(_nz(c), () => c);
    }
  }
  for (final k in Wa.cats.keys) {
    seen.putIfAbsent(_nz(k), () => k);
  }
  final out = <String>[];
  for (final d in kDays) {
    final v = seen.remove(_nz(d));
    if (v != null) out.add(v);
  }
  final rest = seen.values.toList()..sort();
  out.addAll(rest);
  return out;
}

/// الأعمدة: A = الاسم مع الأرقام (محمد524/554)، B أو C = المعلمة، D = "إيقاف" (أي كلمة تعطّل الصف)، E = التصنيف/الأيام (السبت/الثلاثاء).
G? parseRow(List<String> c) {
  if (c.isEmpty) return null;
  final raw = _clean(c[0]);
  if (raw.isEmpty) return null;
  if (c.length > 3 && _clean(c[3]).isNotEmpty) return null; // موقوف
  var name = raw, nums = '';
  // كود بصيغة PTN-001325: الرقم للبحث = 1325 (بدون PTN وبدون الأصفار)، والباقي هو الاسم.
  final ptn = RegExp(r'PTN\s*[-_]?\s*0*(\d+)', caseSensitive: false);
  final pm = ptn.allMatches(raw).toList();
  final m = pm.isEmpty ? _tail.firstMatch(raw) : null;
  if (pm.isNotEmpty) {
    nums = pm.map((e) => e.group(1)!).join('/');
    final rest = _clean(raw.replaceAll(ptn, ' '))
        .replaceAll(RegExp(r'^[\s/\-_,،]+|[\s/\-_,،]+$'), '');
    if (rest.isNotEmpty) name = rest;
  } else if (m != null && m.group(1)!.trim().isNotEmpty) {
    name = m.group(1)!.trim();
    nums = m
        .group(2)!
        .split('/')
        .map((e) => e.replaceAll(RegExp(r'[^0-9]'), ''))
        .where((e) => e.isNotEmpty)
        .join('/');
  }
  var teacher = '';
  for (final x in c.skip(1).take(2)) {
    if (_clean(x).isNotEmpty) {
      teacher = _clean(x);
      break;
    }
  }
  final cats = c.length > 4 ? parseCats(c[4]) : <String>[];
  return G(name, nums, teacher, cats);
}

({List<G> groups, int dups, int off}) parseSheet(List<List<String>> rows) {
  final seen = <String>{};
  final out = <G>[];
  var dups = 0, off = 0;
  // تصدير المواعيد (صف عناوين فيه "الكود" و"مدرس"): الاسم والكود في الأول، والمعلم من عمود "مدرس".
  var start = 0, tcol = -1;
  for (var i = 0; i < rows.length && i < 5; i++) {
    if (rows[i].isNotEmpty && _clean(rows[i][0]) == 'الكود') {
      start = i + 1;
      tcol = rows[i].indexWhere((e) => _clean(e) == 'مدرس');
      break;
    }
  }
  for (var i = start; i < rows.length; i++) {
    var r = rows[i];
    if (start > 0) {
      r = [r.isEmpty ? '' : r[0], (tcol >= 0 && tcol < r.length) ? r[tcol] : ''];
    }
    if (i == 0 && r.isNotEmpty && r[0].contains('العميل')) continue;
    final g = parseRow(r);
    if (g == null) {
      if (r.isNotEmpty && _clean(r[0]).isNotEmpty) off++;
      continue;
    }
    if (!seen.add(g.key)) {
      dups++;
      continue;
    }
    out.add(g);
  }
  return (groups: out, dups: dups, off: off);
}

String _xmlUnesc(String s) => s
    .replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'),
        (m) => String.fromCharCode(int.parse(m[1]!, radix: 16)))
    .replaceAllMapped(
        RegExp(r'&#(\d+);'), (m) => String.fromCharCode(int.parse(m[1]!)))
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&amp;', '&');

String _tText(String x) => RegExp(r'<t(?:\s[^>]*)?>([\s\S]*?)</t>')
    .allMatches(x)
    .map((m) => _xmlUnesc(m.group(1)!))
    .join();

int _colIdx(String ref) {
  var n = 0;
  for (final c in ref.toUpperCase().codeUnits) {
    if (c < 65 || c > 90) break;
    n = n * 26 + (c - 64);
  }
  return n - 1;
}

/// قارئ xlsx بسيط وسريع (يدعم inlineStr وsharedStrings) لملفات التصدير التي تفشل مع مكتبة excel.
List<List<String>> readXlsxRaw(List<int> bytes) {
  final arc = ZipDecoder().decodeBytes(bytes);
  String? read(String name) {
    for (final f in arc.files) {
      if (f.isFile && f.name == name) {
        return utf8.decode(f.content as List<int>, allowMalformed: true);
      }
    }
    return null;
  }

  final ss = <String>[];
  final sx = read('xl/sharedStrings.xml');
  if (sx != null) {
    for (final m in RegExp(r'<si\b[^>]*>([\s\S]*?)</si>').allMatches(sx)) {
      ss.add(_tText(m.group(1)!));
    }
  }
  final sheets = <int, String>{};
  for (final f in arc.files) {
    final m = RegExp(r'^xl/worksheets/sheet(\d+)\.xml$').firstMatch(f.name);
    if (f.isFile && m != null) sheets[int.parse(m.group(1)!)] = f.name;
  }
  if (sheets.isEmpty) return [];
  final first = (sheets.keys.toList()..sort()).first;
  final sheet = read(sheets[first]!);
  if (sheet == null) return [];

  final rows = <List<String>>[];
  for (final rm
      in RegExp(r'<row\b[^>]*?(?:/>|>([\s\S]*?)</row>)').allMatches(sheet)) {
    final content = rm.group(1) ?? '';
    final cells = <int, String>{};
    var maxC = -1, auto = 0;
    for (final cm
        in RegExp(r'<c\b([^>]*?)(?:/>|>([\s\S]*?)</c>)').allMatches(content)) {
      final attrs = cm.group(1)!;
      final body = cm.group(2) ?? '';
      final ref = RegExp(r'\br="([A-Za-z]+)\d*"').firstMatch(attrs)?.group(1);
      final idx = ref != null ? _colIdx(ref) : auto;
      auto = idx + 1;
      final t = RegExp(r'\bt="(\w+)"').firstMatch(attrs)?.group(1);
      String v;
      if (t == 'inlineStr') {
        v = _tText(body);
      } else {
        final vm = RegExp(r'<v[^>]*>([\s\S]*?)</v>').firstMatch(body);
        final raw = vm == null ? '' : _xmlUnesc(vm.group(1)!);
        if (t == 's') {
          final k = int.tryParse(raw);
          v = (k != null && k >= 0 && k < ss.length) ? ss[k] : '';
        } else {
          v = raw;
        }
      }
      cells[idx] = v;
      if (idx > maxC) maxC = idx;
    }
    rows.add(List<String>.generate(maxC + 1, (i) => cells[i] ?? ''));
  }
  return rows;
}

List<List<String>> readRows(String path) {
  final bytes = File(path).readAsBytesSync();
  try {
    final r = readXlsxRaw(bytes);
    if (r.isNotEmpty) return r;
  } catch (_) {}
  final book = Excel.decodeBytes(bytes);
  if (book.tables.isEmpty) return [];
  final sheet = book.tables[book.tables.keys.first]!;
  return sheet.rows
      .map((r) => r.map((c) => c?.value?.toString() ?? '').toList())
      .toList();
}

Future<bool> _tryPrepare() async {
  try {
    final d = Directory(kDir);
    if (!d.existsSync()) d.createSync(recursive: true);
    return true;
  } catch (_) {
    return false;
  }
}

/// أحدث ملف .xlsx في المجلد (groups.xlsx أو أي ملف يُنسخ يدوياً)، أو null لو لا يوجد.
String? findExcel() {
  try {
    final fs = Directory(kDir)
        .listSync()
        .whereType<File>()
        .where((f) {
          final n = p.basename(f.path).toLowerCase();
          return n.endsWith('.xlsx') && !n.startsWith('~\$') && !n.startsWith('.');
        })
        .toList();
    if (fs.isEmpty) return null;
    fs.sort((x, y) => y.lastModifiedSync().compareTo(x.lastModifiedSync()));
    return fs.first.path;
  } catch (_) {
    return null;
  }
}

/// يتأكد من صلاحية الملفات وينشئ المجلد. يرجع نص الخطأ أو null.
Future<String?> prepareFolder() async {
  final s = await Perm.status();
  if (s.isNotEmpty && s['storage'] != true) {
    return 'صلاحية الملفات غير ممنوحة.\nاسمحي للتطبيق بالوصول إلى كل الملفات ثم اضغطي تحديث.';
  }
  if (await _tryPrepare()) return null;
  return 'لا أستطيع الوصول إلى المجلد $kDir\nاسمحي للتطبيق بالوصول إلى الملفات من إعدادات الهاتف ثم اضغطي تحديث.';
}

// ======================= الحفظ المحلي (المسودة + تقدم المهمة) =======================
class Store {
  static Map<String, dynamic> data = {};

  static Future<File> _file() async =>
      File(p.join((await getApplicationSupportDirectory()).path, 'state.json'));

  static Future<void>? _once;

  /// تحميل مرة واحدة فقط (التابان يستدعيانه معاً).
  static Future<void> load() => _once ??= _load();

  static Future<void> _load() async {
    try {
      final f = await _file();
      if (f.existsSync()) {
        data = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      }
    } catch (_) {
      data = {};
    }
  }

  static Future<void> save() async {
    final f = await _file();
    await f.writeAsString(jsonEncode(data));
  }

  static Map<String, dynamic>? get job {
    final j = data['job'];
    if (j is Map<String, dynamic> && j['finished'] != true) return j;
    return null;
  }

  /// مهمة تاب "رسالة لمصنف".
  static Map<String, dynamic>? get ujob {
    final j = data['ujob'];
    if (j is Map<String, dynamic> && j['finished'] != true) return j;
    return null;
  }
}

Future<String> persistMedia(String src) async {
  final dir = Directory(
      p.join((await getApplicationSupportDirectory()).path, 'media'));
  await dir.create(recursive: true);
  final dest = p.join(dir.path,
      '${DateTime.now().microsecondsSinceEpoch}${p.extension(src).toLowerCase()}');
  await File(src).copy(dest);
  return dest;
}

void snack(BuildContext c, String m) => ScaffoldMessenger.of(c)
  ..hideCurrentSnackBar()
  ..showSnackBar(SnackBar(content: Text(m)));

Future<bool> ask(BuildContext c, String title, String body,
    {String ok = 'متابعة'}) async {
  final r = await showDialog<bool>(
    context: c,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('إلغاء')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(ok)),
      ],
    ),
  );
  return r ?? false;
}

// ======================= أسماء الجروبات من واتساب =======================
class Wa {
  static final Map<String, String?> _matchC = {};
  static Map<String, Set<String>>? _setsC;
  static List<String>? _namesC;
  static List<Set<String>>? _tokC;

  /// يُستدعى كلما تغيّرت الأسماء المسحوبة أو التصنيفات.
  static void invalidate() {
    _matchC.clear();
    _setsC = null;
    _namesC = null;
    _tokC = null;
  }

  static List<String> get names =>
      ((Store.data['wa'] as List?) ?? const []).map((e) => e.toString()).toList();

  static Map<String, String> get map {
    final m = Store.data['wamap'];
    if (m is Map) {
      return m.map((k, v) => MapEntry(k.toString(), v.toString()));
    }
    return <String, String>{};
  }

  /// تصنيفات واتساب المسحوبة: اسم التصنيف ← أسماء الجروبات.
  static Map<String, List<String>> get cats {
    final m = Store.data['wacats'];
    if (m is Map) {
      return m.map((k, v) => MapEntry(k.toString(),
          ((v as List?) ?? const []).map((e) => e.toString()).toList()));
    }
    return <String, List<String>>{};
  }

  static Map<String, Set<String>> get _sets {
    var c = _setsC;
    if (c == null) {
      c = <String, Set<String>>{};
      for (final e in cats.entries) {
        c[_nz(e.key)] = e.value.map(_nz).toSet();
      }
      _setsC = c;
    }
    return c;
  }

  /// اسم الجروب في واتساب المقابل لصف الشيت (يدوي ثم تلقائي).
  static String? matchOf(G g) {
    final m = Store.data['wamap'];
    if (m is Map && m[g.key] is String && (m[g.key] as String).isNotEmpty) {
      return m[g.key] as String;
    }
    return _matchC.putIfAbsent(g.key, () {
      final n = _namesC ??= names;
      final t = _tokC ??= n.map((w) => _toks(w).toSet()).toList();
      return autoMatch(g, n, t);
    });
  }

  static bool inWaCat(G g, String cat) {
    final set = _sets[_nz(cat)];
    if (set == null) return false;
    final m = matchOf(g);
    return m != null && set.contains(_nz(m));
  }

  static bool inAnyWaCat(G g) => _sets.keys.any((k) => inWaCat(g, k));
}

String _nz(String s) {
  var t = _clean(s).toLowerCase();
  t = t.replaceAll(RegExp(r'[\u064b-\u065f\u0670\u0640]'), '');
  t = t
      .replaceAll(RegExp(r'[أإآ]'), 'ا')
      .replaceAll('ى', 'ي')
      .replaceAll('ة', 'ه');
  return t;
}

List<String> _toks(String s) => RegExp(r'\p{L}+|\p{N}+', unicode: true)
    .allMatches(_nz(s))
    .map((m) => m.group(0)!)
    .toList();

/// يطابق صف الشيت مع أقرب اسم جروب في واتساب. يرجع null لو لا يوجد تطابق واضح.
String? autoMatch(G g, List<String> wa, [List<Set<String>>? pre]) {
  if (wa.isEmpty) return null;
  final st = <String>[
    ..._toks(g.name),
    ...g.numbers.split('/').where((e) => e.isNotEmpty),
  ];
  if (st.isEmpty) return null;
  String? best;
  var b1 = 0.0, b2 = 0.0;
  for (var wi = 0; wi < wa.length; wi++) {
    final w = wa[wi];
    final wt = pre != null ? pre[wi] : _toks(w).toSet();
    if (wt.isEmpty) continue;
    final hits = st.where((x) => wt.contains(x)).length;
    final extra = wt.length - hits;
    final sc = hits / st.length - 0.02 * (extra < 0 ? 0 : extra);
    if (sc > b1) {
      b2 = b1;
      b1 = sc;
      best = w;
    } else if (sc > b2) {
      b2 = sc;
    }
  }
  if (best == null || b1 < 0.6) return null;
  if (b2 > b1 - 0.15) return null; // أكثر من احتمال: يُترك للاختيار اليدوي
  return best;
}

/// الكلمة التي تُنسخ وتُلصق في بحث واتساب: الاختيار اليدوي ثم المطابقة التلقائية ثم الرقم/الاسم القديم.
String waKey(G g) {
  final m = Store.data['wamap'];
  if (m is Map && m[g.key] is String && (m[g.key] as String).isNotEmpty) {
    return m[g.key] as String;
  }
  return Wa.matchOf(g) ?? g.searchKey;
}

class WaGroupsScreen extends StatefulWidget {
  final List<G> groups;
  const WaGroupsScreen({super.key, required this.groups});
  @override
  State<WaGroupsScreen> createState() => _WaGroupsScreenState();
}

class _WaGroupsScreenState extends State<WaGroupsScreen> {
  /// لصق أسماء الجروبات (سطر لكل اسم) بدل السحب التلقائي.
  Future<void> _addNames() async {
    final namesC = TextEditingController();
    final catC = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('إضافة أسماء الجروبات'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text(
                'انسخي أسماء الجروبات من واتساب والصقيها هنا، كل اسم في سطر.'),
            const SizedBox(height: 8),
            TextField(
              controller: namesC,
              minLines: 6,
              maxLines: 12,
              decoration: const InputDecoration(
                  border: OutlineInputBorder(), hintText: 'اسم الجروب\nاسم الجروب'),
            ),
            const SizedBox(height: 12),
            const Text('اختياري: اسم التصنيف (مثل اليوم) لحفظ الأسماء تحته'),
            const SizedBox(height: 6),
            TextField(
                controller: catC,
                decoration: const InputDecoration(hintText: 'مثال: السبت')),
            const SizedBox(height: 8),
            Wrap(spacing: 6, children: [
              for (final d in kDays)
                ActionChip(label: Text(d), onPressed: () => catC.text = d),
            ]),
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('حفظ')),
        ],
      ),
    );
    if (ok != true) return;
    final got = namesC.text
        .split(RegExp(r'[\r\n]+'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList();
    if (got.isEmpty) return;
    final cat = catC.text.trim();
    if (cat.isNotEmpty) {
      final cm = Wa.cats;
      cm[cat] = got;
      Store.data['wacats'] = cm;
    }
    Store.data['wa'] = <String>{...Wa.names, ...got}.toList();
    Wa.invalidate();
    await Store.save();
    if (mounted) {
      setState(() {});
      snack(context, 'تمت إضافة ${got.length} اسم');
    }
  }

  Future<void> _clearAll() async {
    Store.data['wa'] = <String>[];
    Store.data['wacats'] = <String, dynamic>{};
    Wa.invalidate();
    await Store.save();
    if (mounted) setState(() {});
  }

  Future<void> _pick(G g) async {
    final r = await showDialog<String>(
        context: context,
        builder: (_) => _PickDialog(title: g.title, names: Wa.names));
    if (r == null) return;
    final m = Wa.map;
    if (r.isEmpty) {
      m.remove(g.key);
    } else {
      m[g.key] = r;
    }
    Store.data['wamap'] = m;
    await Store.save();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final names = Wa.names;
    final map = Wa.map;
    var ok = 0;
    final rows = <Widget>[];
    for (final g in widget.groups) {
      final manual = map[g.key];
      final auto = manual == null ? Wa.matchOf(g) : null;
      final shown = manual ?? auto;
      if (shown != null) ok++;
      rows.add(ListTile(
        title: Text(g.title),
        subtitle: Text(
          shown ??
              (names.isEmpty
                  ? 'لم تتم إضافة أسماء بعد'
                  : 'لا يوجد تطابق واضح — اضغطي للاختيار'),
          style: shown == null ? const TextStyle(color: Colors.red) : null,
        ),
        trailing: Icon(
          manual != null
              ? Icons.edit
              : auto != null
                  ? Icons.check_circle
                  : Icons.help_outline,
          color: shown == null ? Colors.red : Colors.green,
        ),
        onTap: () => _pick(g),
      ));
    }
    return Scaffold(
      appBar: AppBar(title: const Text('أسماء الجروبات من واتساب')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Text('الأسماء المحفوظة من واتساب: ${names.length}'),
          ),
        ),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: _addNames,
          icon: const Icon(Icons.paste),
          label: const Text('لصق / إضافة أسماء الجروبات'),
        ),
        if (names.isNotEmpty) ...[
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _clearAll,
            icon: const Icon(Icons.delete_sweep),
            label: const Text('مسح كل الأسماء المحفوظة'),
          ),
        ],
        if (Wa.cats.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text('التصنيفات المسحوبة', style: Theme.of(context).textTheme.titleMedium),
          for (final e in Wa.cats.entries)
            ListTile(
              dense: true,
              title: Text('${e.key} (${e.value.length} جروب)'),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () async {
                  final m = Wa.cats..remove(e.key);
                  Store.data['wacats'] = m;
                  Wa.invalidate();
                  await Store.save();
                  if (mounted) setState(() {});
                },
              ),
            ),
        ],
        const SizedBox(height: 8),
        if (names.isNotEmpty)
          Text('تمت مطابقة $ok من ${widget.groups.length} جروب',
              style: Theme.of(context).textTheme.titleMedium),
        ...rows,
      ]),
    );
  }
}

class _PickDialog extends StatefulWidget {
  final String title;
  final List<String> names;
  const _PickDialog({required this.title, required this.names});
  @override
  State<_PickDialog> createState() => _PickDialogState();
}

class _PickDialogState extends State<_PickDialog> {
  String q = '';
  @override
  Widget build(BuildContext context) {
    final nq = _nz(q);
    final list = widget.names
        .where((n) => nq.isEmpty || _nz(n).contains(nq))
        .toList();
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: double.maxFinite,
        height: 420,
        child: Column(children: [
          TextField(
              decoration: const InputDecoration(
                  hintText: 'بحث', prefixIcon: Icon(Icons.search)),
              onChanged: (v) => setState(() => q = v)),
          Expanded(
              child: ListView.builder(
                  itemCount: list.length,
                  itemBuilder: (_, i) => ListTile(
                      dense: true,
                      title: Text(list[i]),
                      onTap: () => Navigator.pop(context, list[i])))),
        ]),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context, ''),
            child: const Text('إلغاء الربط')),
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('إغلاق')),
      ],
    );
  }
}

// ======================= الفقاعة العائمة (خدمة إمكانية الوصول) =======================
/// جسر للجزء الأصلي (Kotlin): الفقاعة تكتب كلمة البحث في واتساب بيزنس وتنقل للجروب التالي.
class Bubble {
  static const List<String> _codes = ['pending', 'done', 'skipped'];
  static int code(String s) => s == 'done' ? 1 : (s == 'skipped' ? 2 : 0);

  static Future<Map<String, dynamic>> status() async {
    try {
      final r = await _ch.invokeMethod<Map>('svcStatus');
      return (r ?? {}).map((k, v) => MapEntry(k.toString(), v));
    } catch (_) {
      return {};
    }
  }

  /// يشغّل الجلسة ويفتح العنصر [at]. يرجع نص الخطأ أو null عند النجاح.
  static Future<String?> start(Map<String, dynamic> session, int at) async {
    try {
      await _ch.invokeMethod<bool>(
          'start', {'session': jsonEncode(session), 'at': at});
      return null;
    } on PlatformException catch (e) {
      return e.code == 'NO_A11Y'
          ? 'فعّلي خدمة A2R Sender من إعدادات إمكانية الوصول أولاً'
          : (e.message ?? 'تعذر تشغيل الفقاعة');
    } catch (e) {
      return '$e';
    }
  }

  static Future<Map<String, dynamic>?> state() async {
    try {
      final s = await _ch.invokeMethod<String>('state');
      if (s == null || s.isEmpty) return null;
      return jsonDecode(s) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  static Future<void> stop() async {
    try {
      await _ch.invokeMethod<bool>('stop');
    } catch (_) {}
  }

  static Future<void> clear() async {
    try {
      await _ch.invokeMethod<bool>('clear');
    } catch (_) {}
  }

  static Future<void> setStatus(int i, String st) async {
    try {
      await _ch.invokeMethod<bool>('setStatus', {'i': i, 's': code(st)});
    } catch (_) {}
  }

  static Future<void> open(String what) async {
    try {
      await _ch.invokeMethod<bool>(what);
    } catch (_) {}
  }

  /// يدمج حالات الفقاعة (تم/تخطي) في المهمة المحفوظة [key] = job أو ujob.
  static Future<({bool active, bool changed})> sync(String key) async {
    final j = Store.data[key];
    if (j is! Map) return (active: false, changed: false);
    final s = await state();
    if (s == null || s['id'] != key) return (active: false, changed: false);
    var changed = false;
    final st = j['st'];
    final ns = s['st'];
    if (st is List && ns is List && st.length == ns.length) {
      for (var i = 0; i < st.length; i++) {
        final n = ns[i];
        final v = _codes[(n is int ? n : 0).clamp(0, 2).toInt()];
        if (st[i] != v) {
          st[i] = v;
          changed = true;
        }
      }
      if (changed) await Store.save();
    }
    final active = s['active'] == true;
    if (!active) await clear();
    return (active: active, changed: changed);
  }

  static Future<void> syncAll() async {
    await sync('job');
    await sync('ujob');
  }

  /// قبل إنشاء مهمة جديدة: إنهاء أي جلسة قديمة حتى لا تختلط حالاتها.
  static Future<void> reset() async {
    await stop();
    await clear();
  }
}

/// جلسة الإرسال الفردي: كل جروب يفتح واتساب بالرسالة ثم يكتب كلمة بحثه.
Map<String, dynamic> jobSession(Map<String, dynamic> job) {
  final gs = job['groups'] as List;
  final st = job['st'] as List;
  return {
    'id': 'job',
    'text': job['text'] as String,
    'media': (job['media'] as List).map((e) => e.toString()).toList(),
    'items': List.generate(gs.length, (i) {
      final g = G.fromJson(gs[i] as Map<String, dynamic>);
      return {
        't': g.title,
        'k': waKey(g),
        'l': true,
        's': Bubble.code(st[i] as String),
      };
    }),
  };
}

/// جلسة المصنف: واتساب يُفتح مرة لكل دفعة، وكل ضغطة تكتب اسم الجروب التالي في الدفعة.
Map<String, dynamic> labelSession(Map<String, dynamic> job) {
  final names = (job['items'] as List).map((e) => e.toString()).toList();
  final st = job['st'] as List;
  final bs = ((job['batch'] as int?) ?? 5).clamp(1, 30).toInt();
  return {
    'id': 'ujob',
    'text': job['text'] as String,
    'media': (job['media'] as List).map((e) => e.toString()).toList(),
    'items': List.generate(names.length, (i) => {
          't': names[i],
          'k': names[i],
          'l': i % bs == 0,
          's': Bubble.code(st[i] as String),
        }),
  };
}

/// بطاقة تفعيل الفقاعة وتشغيلها.
class BubbleCard extends StatefulWidget {
  final String startLabel;
  final Future<void> Function() onStart;
  const BubbleCard({super.key, required this.startLabel, required this.onStart});
  @override
  State<BubbleCard> createState() => _BubbleCardState();
}

class _BubbleCardState extends State<BubbleCard> with WidgetsBindingObserver {
  Map<String, dynamic> st = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    final r = await Bubble.status();
    if (mounted) setState(() => st = r);
  }

  @override
  Widget build(BuildContext context) {
    final on = st['a11y'] == true;
    final t = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.bubble_chart,
                color: on ? Colors.green : t.colorScheme.outline),
            const SizedBox(width: 8),
            Expanded(
                child: Text(
                    on
                        ? 'الفقاعة العائمة جاهزة'
                        : 'الفقاعة العائمة (تفعيل لمرة واحدة)',
                    style: t.textTheme.titleSmall)),
          ]),
          const SizedBox(height: 8),
          if (!on) ...[
            const Text(
                'تكتب الفقاعة كلمة البحث في واتساب بيزنس بدل اللصق اليدوي، وتنقلك للجروب التالي بدون الرجوع للتطبيق. '
                'فعّلي \"A2R Sender\" من إعدادات إمكانية الوصول (الخدمات المثبتة). الخدمة مقصورة على واتساب بيزنس '
                'ولا تضغط على الجروب ولا على إرسال.'),
            const SizedBox(height: 8),
            FilledButton.tonalIcon(
                onPressed: () => Bubble.open('openA11y'),
                icon: const Icon(Icons.accessibility_new),
                label: const Text('فتح إعدادات إمكانية الوصول')),
            TextButton(
                onPressed: () => Bubble.open('openAppInfo'),
                child: const Text(
                    'التفعيل مقفول أو ظهرت رسالة \"إعداد مقيّد\"؟ افتحي معلومات التطبيق')),
          ] else ...[
            FilledButton.icon(
                onPressed: widget.onStart,
                icon: const Icon(Icons.play_circle_outline),
                label: Text(widget.startLabel)),
            if (st['overlay'] != true)
              TextButton(
                  onPressed: () => Bubble.open('openOverlay'),
                  child: const Text(
                      'لو الفقاعة لا تفتح واتساب: اسمحي بالعرض فوق التطبيقات')),
          ],
        ]),
      ),
    );
  }
}

// ======================= الصلاحيات عند بداية التشغيل =======================
class Perm {
  static Future<Map<String, dynamic>> status() async {
    try {
      final r = await _ch.invokeMethod<Map>('permStatus');
      return (r ?? {}).map((k, v) => MapEntry(k.toString(), v));
    } catch (_) {
      return {};
    }
  }

  static Future<void> reqStorage() async {
    try {
      await _ch.invokeMethod<bool>('reqStorage');
    } catch (_) {}
  }
}

/// شاشة البداية: تطلب الصلاحيات واحدة واحدة (الملفات ← العرض فوق التطبيقات ← خدمة إمكانية الوصول)
/// ثم تفتح التطبيق. تعمل على أندرويد 10 حتى 16.
class Gate extends StatefulWidget {
  const Gate({super.key});
  @override
  State<Gate> createState() => _GateState();
}

class _GateState extends State<Gate> with WidgetsBindingObserver {
  Map<String, dynamic> st = {};
  bool checked = false, skipped = false, entered = false, busy = false;
  final Set<String> asked = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) _refresh();
  }

  bool _ok(String k) => st[k] == true;
  bool get _all => _ok('storage') && _ok('overlay') && _ok('a11y');

  Future<void> _refresh() async {
    if (busy) return;
    busy = true;
    try {
      final r = await Perm.status();
      if (!mounted) return;
      setState(() {
        st = r;
        checked = true;
      });
      if (r.isEmpty || _all || skipped || entered) return;
      // يطلب تلقائياً أول صلاحية ناقصة (مرة واحدة لكل صلاحية)، والباقي بالأزرار.
      for (final k in const ['storage', 'overlay', 'a11y']) {
        if (!_ok(k) && asked.add(k)) {
          await Future<void>.delayed(const Duration(milliseconds: 400));
          if (mounted) await _request(k);
          break;
        }
      }
    } finally {
      busy = false;
    }
  }

  Future<void> _request(String k) async {
    if (k == 'storage') {
      await Perm.reqStorage();
    } else if (k == 'overlay') {
      await Bubble.open('openOverlay');
    } else {
      await Bubble.open('openA11y');
    }
  }

  Widget _item(ThemeData t, String k, String title, String why, String btn) {
    final ok = _ok(k);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(ok ? Icons.check_circle : Icons.error_outline,
                color: ok ? Colors.green : t.colorScheme.error),
            const SizedBox(width: 8),
            Expanded(child: Text(title, style: t.textTheme.titleMedium)),
          ]),
          const SizedBox(height: 6),
          Text(why),
          if (!ok) ...[
            const SizedBox(height: 8),
            FilledButton.tonal(
                onPressed: () => _request(k), child: Text(btn)),
          ],
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!checked) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_all || st.isEmpty || skipped || entered) {
      entered = true;
      return const Shell();
    }
    final t = Theme.of(context);
    final sdk = st['sdk'];
    return Scaffold(
      appBar: AppBar(title: const Text('تجهيز التطبيق')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text('محتاجين تفعيل 3 صلاحيات عشان التطبيق يشتغل كامل:',
            style: t.textTheme.titleMedium),
        const SizedBox(height: 12),
        _item(
            t,
            'storage',
            '1) الوصول إلى الملفات',
            'لقراءة ملف Excel من مجلد A2R_Sender واختيار الصور والاستيكرات.',
            'السماح بالوصول للملفات'),
        _item(
            t,
            'overlay',
            '2) العرض فوق التطبيقات',
            'عشان الفقاعة تقدر تفتح واتساب بيزنس من الخلفية.',
            'السماح بالعرض فوق التطبيقات'),
        _item(
            t,
            'a11y',
            '3) خدمة إمكانية الوصول',
            'تكتب كلمة البحث في واتساب بيزنس فقط. لا تقرأ محادثاتك ولا تضغط إرسال. '
                'فعّلي "A2R Sender" من الخدمات المثبتة.',
            'فتح إعدادات إمكانية الوصول'),
        if (sdk is int && sdk >= 33 && !_ok('a11y'))
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                      'لو خيار التفعيل رمادي (أندرويد 13+): افتحي معلومات التطبيق ← القائمة ⋮ ← "السماح بالإعدادات المقيّدة"، ثم ارجعي وفعّلي الخدمة.'),
                  TextButton(
                      onPressed: () => Bubble.open('openAppInfo'),
                      child: const Text('فتح معلومات التطبيق')),
                ]),
          ),
        const SizedBox(height: 16),
        OutlinedButton(
            onPressed: () => setState(() => skipped = true),
            child: const Text('متابعة بدون تفعيل (بعض الميزات لن تعمل)')),
      ]),
    );
  }
}

// ======================= الهيكل: تابان =======================
class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int tab = 0;
  @override
  Widget build(BuildContext context) {
    final kb = MediaQuery.of(context).viewInsets.bottom > 0;
    return Scaffold(
      body: IndexedStack(index: tab, children: const [Home(), LabelTab()]),
      bottomNavigationBar: kb
          ? null
          : NavigationBar(
              selectedIndex: tab,
              onDestinationSelected: (v) => setState(() => tab = v),
              destinations: const [
                NavigationDestination(
                    icon: Icon(Icons.send), label: 'إرسال لكل جروب'),
                NavigationDestination(
                    icon: Icon(Icons.label_outline), label: 'رسالة لمصنف'),
              ],
            ),
    );
  }
}

// ======================= التطبيق =======================
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext context) {
    const big = Size.fromHeight(56);
    return MaterialApp(
      title: 'A2R Sender',
      debugShowCheckedModeBanner: false,
      locale: const Locale('ar'),
      supportedLocales: const [Locale('ar')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF1B7F5C),
        filledButtonTheme:
            FilledButtonThemeData(style: FilledButton.styleFrom(minimumSize: big)),
        outlinedButtonTheme: OutlinedButtonThemeData(
            style: OutlinedButton.styleFrom(minimumSize: big)),
      ),
      home: const Gate(),
    );
  }
}

// ======================= شاشة الرسالة =======================
class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> with WidgetsBindingObserver {
  final TextEditingController text = TextEditingController();
  String kind = 'text';
  List<String> media = [];
  List<G> groups = [];
  int dups = 0, off = 0;
  String? err;
  String? srcPath;
  String? cat; // التصنيف المحدد للإرسال (null = الكل)
  bool loading = true;

  List<String> get _cats => allCats(groups);
  String? get _cat {
    final c = cat;
    if (c == null || c == kNoCat) return c;
    return _cats.any((x) => _nz(x) == _nz(c)) ? c : null;
  }

  List<G> get shown => groups.where((g) => inCat(g, _cat)).toList();

  Future<void> _setCat(String? c) async {
    setState(() => cat = c);
    if (c == null) {
      Store.data.remove('cat');
    } else {
      Store.data['cat'] = c;
    }
    await Store.save();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    text.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    // بعد تعديل Excel في تطبيق آخر والرجوع هنا، يُعاد قراءة الملف تلقائياً.
    if (s == AppLifecycleState.resumed && !loading) {
      Bubble.syncAll().then((_) {
        if (mounted) setState(() {});
      });
      _reload();
    }
  }

  Future<void> _init() async {
    await Store.load();
    Wa.invalidate();
    final sc = Store.data['cat'];
    if (sc is String) cat = sc;
    final d = Store.data['draft'];
    if (d is Map<String, dynamic>) {
      kind = (d['kind'] as String?) ?? 'text';
      if (kind == 'sticker1' || kind == 'sticker2') kind = 'stickers';
      if (!kKinds.containsKey(kind)) kind = 'text';
      text.text = (d['text'] as String?) ?? '';
      media = ((d['media'] as List?) ?? const [])
          .map((e) => e.toString())
          .where((x) => File(x).existsSync())
          .toList();
    }
    await _reload();
  }

  Future<void> _reload() async {
    var e = await prepareFolder();
    var g = <G>[];
    var dp = 0, of = 0;
    String? src;
    if (e == null) {
      src = findExcel();
      if (src == null) {
        e = 'لا يوجد ملف جروبات بعد.\nاضغطي "استيراد ملف Excel"، أو ضعي ملف .xlsx داخل مجلد A2R_Sender في الذاكرة الداخلية.';
      } else {
        try {
          final r = parseSheet(readRows(src));
          g = r.groups;
          dp = r.dups;
          of = r.off;
        } catch (x) {
          e = 'تعذر قراءة ${p.basename(src)}: $x';
        }
      }
    }
    if (!mounted) return;
    setState(() {
      srcPath = src;
      groups = g;
      dups = dp;
      off = of;
      err = e;
      loading = false;
    });
  }

  /// استيراد ملف Excel من أي مكان في الهاتف ونسخه مكان groups.xlsx.
  Future<void> _importExcel() async {
    try {
      final res = await FilePicker.platform.pickFiles(
          type: FileType.custom, allowedExtensions: ['xlsx']);
      if (res == null || res.files.isEmpty || res.files.first.path == null) {
        return;
      }
      final src = File(res.files.first.path!);
      final r = parseSheet(readRows(src.path)); // تحقق إن الملف سليم
      if (r.groups.isEmpty) {
        if (mounted) snack(context, 'لا توجد جروبات في هذا الملف');
        return;
      }
      final e = await prepareFolder();
      if (e != null) {
        if (mounted) snack(context, e);
        return;
      }
      final dst = File(kFile);
      if (dst.existsSync()) dst.deleteSync();
      await src.copy(kFile);
      await _reload();
      if (mounted) snack(context, 'تم استيراد ${r.groups.length} جروب');
    } catch (x) {
      if (mounted) snack(context, 'تعذر استيراد الملف: $x');
    }
  }

  void _saveDraft() {
    Store.data['draft'] = {'kind': kind, 'text': text.text, 'media': media};
    Store.save();
  }

  void _setKind(String k) {
    setState(() {
      // الاستيكرات والصور لا تُخلط: عند التبديل بينهما تُفرّغ القائمة.
      if ((k == 'stickers') != (kind == 'stickers')) media = [];
      kind = k;
      final lim = kLimit[k]!;
      if (media.length > lim) media = media.sublist(0, lim);
    });
    _saveDraft();
  }

  String _firstDir(List<String> c) {
    for (final d in c) {
      if (Directory(d).existsSync()) return d;
    }
    return kRoot;
  }

  Future<void> _addMedia(List<String> paths) async {
    for (final f in paths) {
      media.add(await persistMedia(f));
    }
    if (!mounted) return;
    setState(() {});
    _saveDraft();
  }

  /// صورة من معرض الصور في الهاتف.
  Future<void> _gallery() async {
    if (kLimit[kind]! - media.length <= 0) return;
    try {
      final x = await ImagePicker().pickImage(source: ImageSource.gallery);
      if (x == null) return;
      await _addMedia([x.path]);
    } catch (e) {
      if (mounted) snack(context, 'تعذر فتح معرض الصور: $e');
    }
  }

  /// تصفح مجلدات الهاتف مع تذكر آخر مجلد (للاستيكرات أو الصور).
  Future<void> _browse() async {
    final room = kLimit[kind]! - media.length;
    if (room <= 0) return;
    if (await prepareFolder() != null) {
      await Perm.reqStorage();
      return;
    }
    if (!mounted) return;
    final st = kind == 'stickers';
    final res = await Navigator.push<List<String>>(
      context,
      MaterialPageRoute(
        builder: (_) => MediaBrowser(
          title: st ? 'اختيار استيكرات' : 'اختيار صورة',
          storeKey: st ? 'dirSticker' : 'dirImage',
          fallbackDir: st
              ? _firstDir([
                  '$kRoot/Android/media/com.whatsapp.w4b/WhatsApp Business/Media/WhatsApp Business Stickers',
                  '$kRoot/WhatsApp Business/Media/WhatsApp Business Stickers',
                  '$kRoot/Download',
                ])
              : _firstDir(['$kRoot/DCIM/Camera', '$kRoot/Pictures', '$kRoot/Download']),
          exts: st ? ['webp'] : ['jpg', 'jpeg', 'png', 'webp'],
          max: room,
        ),
      ),
    );
    if (res == null || res.isEmpty) return;
    await _addMedia(res);
  }

  String? _validate() {
    if (kind == 'text' && text.text.trim().isEmpty) return 'اكتبي نص الرسالة';
    if (kind != 'text' && media.isEmpty) {
      return kind == 'stickers' ? 'اختاري استيكراً واحداً على الأقل' : 'اختاري صورة';
    }
    return null;
  }

  Future<void> _start() async {
    final v = _validate();
    if (v != null) {
      snack(context, v);
      return;
    }
    final sel = shown;
    if (sel.isEmpty) {
      snack(context, groups.isEmpty ? 'لا توجد جروبات في ملف Excel' : 'لا توجد جروبات في هذا التصنيف');
      return;
    }
    final catLabel = _cat == null ? '' : ' (${_cat == kNoCat ? 'بدون تصنيف' : _cat})';
    final old = Store.job != null;
    final ok = await ask(context, 'بدء الإرسال',
        '${kindName(kind)}${kind == 'stickers' ? ' (${media.length})' : ''} إلى ${sel.length} جروب$catLabel.${old ? '\nسيتم إغلاق المهمة غير المنتهية السابقة.' : ''}',
        ok: 'ابدأ');
    if (!ok || !mounted) return;
    await Bubble.reset();
    Store.data['job'] = {
      'kind': kind,
      'text': (kind == 'text' || kind == 'imageText') ? text.text.trim() : '',
      'media': kind == 'text' ? <String>[] : media,
      'groups': sel.map((g) => g.toJson()).toList(),
      'st': List<String>.filled(sel.length, 'pending'),
      'finished': false,
    };
    _saveDraft();
    await Store.save();
    if (!mounted) return;
    await Navigator.push(
        context, MaterialPageRoute(builder: (_) => const SendScreen()));
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final job = Store.job;
    final lim = kLimit[kind]!;
    return Scaffold(
      appBar: AppBar(title: const Text('A2R Sender'), actions: [
        IconButton(
            tooltip: 'أسماء الجروبات من واتساب',
            onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => WaGroupsScreen(groups: groups))),
            icon: const Icon(Icons.groups)),
        IconButton(
            tooltip: 'استيراد ملف Excel',
            onPressed: _importExcel,
            icon: const Icon(Icons.upload_file)),
        IconButton(
            tooltip: 'تحديث من ملف Excel',
            onPressed: _reload,
            icon: const Icon(Icons.refresh)),
      ]),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        if (loading) const LinearProgressIndicator(),
        OutlinedButton.icon(
          onPressed: _importExcel,
          icon: const Icon(Icons.upload_file),
          label: const Text('استيراد ملف Excel'),
        ),
        const SizedBox(height: 8),
        if (err != null)
          Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(err!),
                        if (err!.contains('اسمحي')) ...[
                          const SizedBox(height: 8),
                          FilledButton.tonal(
                              onPressed: () => Perm.reqStorage(),
                              child: const Text('منح صلاحية الملفات')),
                        ],
                      ])))
        else
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text('${groups.length} جروب جاهز'
                  '${dups > 0 ? ' • مكرر تم تجاهله: $dups' : ''}'
                  '${off > 0 ? ' • موقوف: $off' : ''}\n'
                  'الملف: ${srcPath ?? kFile}'
                  '${_cat != null ? '\nالمحدد للإرسال: ${shown.length} جروب' : ''}'),
            ),
          ),
        if (err == null && _cats.isNotEmpty) ...[
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('الإرسال إلى:',
                        style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 8),
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      ChoiceChip(
                          label: Text('الكل (${groups.length})'),
                          selected: _cat == null,
                          onSelected: (_) => _setCat(null)),
                      for (final c in _cats)
                        ChoiceChip(
                            label: Text(
                                '$c (${groups.where((g) => inCat(g, c)).length})'),
                            selected: _cat != null &&
                                _cat != kNoCat &&
                                _nz(_cat!) == _nz(c),
                            onSelected: (_) => _setCat(c)),
                      if (groups.any((g) => g.cats.isEmpty && !Wa.inAnyWaCat(g)))
                        ChoiceChip(
                            label: Text(
                                'بدون تصنيف (${groups.where((g) => inCat(g, kNoCat)).length})'),
                            selected: _cat == kNoCat,
                            onSelected: (_) => _setCat(kNoCat)),
                    ]),
                  ]),
            ),
          ),
        ],
        if (job != null) ...[
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(children: [
                Text(
                    'مهمة غير منتهية: ${(job['st'] as List).where((s) => s != 'pending').length} من ${(job['st'] as List).length}'),
                const SizedBox(height: 8),
                FilledButton(
                    onPressed: () async {
                      await Navigator.push(context,
                          MaterialPageRoute(builder: (_) => const SendScreen()));
                      if (mounted) setState(() {});
                    },
                    child: const Text('استكمال الإرسال')),
              ]),
            ),
          ),
        ],
        const SizedBox(height: 8),
        for (final k in kKinds.keys)
          ListTile(
            selected: kind == k,
            leading: Icon(kind == k
                ? Icons.radio_button_checked
                : Icons.radio_button_off),
            title: Text(kKinds[k]!,
                style: Theme.of(context).textTheme.titleMedium),
            onTap: () => _setKind(k),
          ),
        const Divider(),
        if (kind == 'text' || kind == 'imageText') ...[
          const SizedBox(height: 8),
          TextField(
            controller: text,
            minLines: 4,
            maxLines: 10,
            onChanged: (_) => _saveDraft(),
            decoration: const InputDecoration(
                labelText: 'نص الرسالة', border: OutlineInputBorder()),
          ),
        ],
        if (lim > 0) ...[
          const SizedBox(height: 16),
          Wrap(spacing: 12, runSpacing: 12, children: [
            for (var i = 0; i < media.length; i++)
              Stack(children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    width: 120,
                    height: 120,
                    color: Colors.black12,
                    child: Image.file(File(media[i]),
                        width: 120,
                        height: 120,
                        fit: kind == 'stickers' ? BoxFit.contain : BoxFit.cover,
                        cacheWidth: 300,
                        errorBuilder: (_, __, ___) => const Center(
                            child: Icon(Icons.broken_image))),
                  ),
                ),
                PositionedDirectional(
                  top: 0,
                  end: 0,
                  child: IconButton.filled(
                    iconSize: 18,
                    onPressed: () {
                      setState(() => media.removeAt(i));
                      _saveDraft();
                    },
                    icon: const Icon(Icons.close),
                  ),
                ),
              ]),
          ]),
          const SizedBox(height: 12),
          if (media.length < lim) ...[
            if (kind != 'stickers') ...[
              OutlinedButton.icon(
                onPressed: _gallery,
                icon: const Icon(Icons.photo_library),
                label: const Text('اختيار من معرض الصور'),
              ),
              const SizedBox(height: 8),
            ],
            OutlinedButton.icon(
              onPressed: _browse,
              icon: Icon(kind == 'stickers'
                  ? Icons.emoji_emotions
                  : Icons.folder_open),
              label: Text(kind == 'stickers'
                  ? 'إضافة استيكرات (${media.length}) — آخر مجلد محفوظ'
                  : 'اختيار من مجلد — آخر مجلد محفوظ'),
            ),
          ],
        ],
        const SizedBox(height: 24),
        FilledButton.icon(
            onPressed: loading ? null : _start,
            icon: const Icon(Icons.play_arrow),
            label: const Text('بدء الإرسال للجروبات')),
      ]),
    );
  }
}

// ======================= شاشة الإرسال =======================
class SendScreen extends StatefulWidget {
  const SendScreen({super.key});
  @override
  State<SendScreen> createState() => _SendScreenState();
}

class _SendScreenState extends State<SendScreen> with WidgetsBindingObserver {
  late Map<String, dynamic> job;
  int? forced;
  bool opened = false;

  @override
  void initState() {
    super.initState();
    job = Store.job!;
    WidgetsBinding.instance.addObserver(this);
    _sync();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) _sync();
  }

  /// يأخذ ما أنجزته الفقاعة (تم/تخطي) أثناء وجودك في واتساب.
  Future<void> _sync() async {
    final r = await Bubble.sync('job');
    if (r.changed) forced = null;
    if (mounted) setState(() {});
  }

  Future<void> _startBubble(int i) async {
    final media = (job['media'] as List).map((e) => e.toString()).toList();
    for (final m in media) {
      if (!File(m).existsSync()) {
        snack(context, 'ملف الصورة غير موجود، جهزي الرسالة من جديد');
        return;
      }
    }
    final err = await Bubble.start(jobSession(job), i);
    if (!mounted) return;
    if (err != null) {
      snack(context, err);
      return;
    }
    setState(() => opened = true);
  }

  List get _st => job['st'] as List;
  List get _groups => job['groups'] as List;
  G _g(int i) => G.fromJson(_groups[i] as Map<String, dynamic>);
  int _count(String s) => _st.where((x) => x == s).length;

  int? get cur {
    if (forced != null) return forced;
    final i = _st.indexOf('pending');
    return i < 0 ? null : i;
  }

  Future<void> _open(int i) async {
    final media = (job['media'] as List).map((e) => e.toString()).toList();
    for (final m in media) {
      if (!File(m).existsSync()) {
        snack(context, 'ملف الصورة غير موجود، جهزي الرسالة من جديد');
        return;
      }
    }
    await Clipboard.setData(ClipboardData(text: waKey(_g(i))));
    try {
      await _ch.invokeMethod<bool>(
          'share', {'text': job['text'] as String, 'paths': media});
      if (mounted) setState(() => opened = true);
    } on PlatformException catch (e) {
      if (!mounted) return;
      snack(
          context,
          e.code == 'NO_WA_BUSINESS'
              ? 'WhatsApp Business غير مثبت على هذا الهاتف'
              : 'تعذر فتح واتساب: ${e.message}');
    }
  }

  Future<void> _mark(int i, String s) async {
    _st[i] = s;
    await Store.save();
    unawaited(Bubble.setStatus(i, s));
    setState(() {
      forced = null;
      opened = false;
    });
  }

  Future<void> _jump(int i) async {
    if (_st[i] == 'done') {
      final ok = await ask(context, 'إعادة الإرسال',
          'تم تأكيد الإرسال لهذا الجروب سابقاً. إرسال مرة أخرى؟',
          ok: 'إعادة');
      if (!ok) return;
      _st[i] = 'pending';
      await Store.save();
      unawaited(Bubble.setStatus(i, 'pending'));
    }
    if (mounted) setState(() => forced = i);
  }

  Future<void> _finish() async {
    final ok = await ask(context, 'إنهاء المهمة',
        'المتبقي: ${_count('pending')} جروب. سيتم إغلاق المهمة.',
        ok: 'إنهاء');
    if (!ok) return;
    await Bubble.reset();
    job['finished'] = true;
    await Store.save();
    if (mounted) Navigator.pop(context);
  }

  Icon _icon(String s) => s == 'done'
      ? const Icon(Icons.check_circle, color: Colors.green)
      : s == 'skipped'
          ? const Icon(Icons.skip_next, color: Colors.orange)
          : const Icon(Icons.radio_button_unchecked);

  void _list() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.8,
        builder: (_, sc) => ListView.builder(
          controller: sc,
          itemCount: _groups.length,
          itemBuilder: (_, i) {
            final g = _g(i);
            return ListTile(
              leading: _icon(_st[i] as String),
              title: Text(g.title),
              subtitle: g.teacher.isEmpty ? null : Text(g.teacher),
              onTap: () {
                Navigator.pop(ctx);
                _jump(i);
              },
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final total = _groups.length;
    final done = _count('done'), skipped = _count('skipped');
    final i = cur;
    final t = Theme.of(context);
    final media = (job['media'] as List).map((e) => e.toString()).toList();
    final kind = job['kind'] as String;
    final body = (job['text'] as String).trim();

    return Scaffold(
      appBar: AppBar(title: const Text('الإرسال'), actions: [
        IconButton(
            tooltip: 'قائمة الجروبات',
            onPressed: _list,
            icon: const Icon(Icons.list)),
        IconButton(
            tooltip: 'إنهاء المهمة',
            onPressed: _finish,
            icon: const Icon(Icons.stop_circle_outlined)),
      ]),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        LinearProgressIndicator(
            value: total == 0 ? 0 : (done + skipped) / total, minHeight: 8),
        const SizedBox(height: 8),
        Text(
            'تم $done  •  تخطي $skipped  •  متبقي ${_count('pending')}  (من $total)'),
        const SizedBox(height: 12),
        if (i == null) ...[
          const SizedBox(height: 24),
          const Icon(Icons.check_circle, size: 72, color: Colors.green),
          const SizedBox(height: 12),
          Text('اكتمل المرور على كل الجروبات',
              textAlign: TextAlign.center, style: t.textTheme.titleLarge),
          if (skipped > 0)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('يمكنك العودة للجروبات المتخطاة من أيقونة القائمة.',
                  textAlign: TextAlign.center),
            ),
          const SizedBox(height: 24),
          FilledButton(onPressed: _finish, child: const Text('إنهاء المهمة')),
        ] else ...[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('الجروب الحالي', style: t.textTheme.labelMedium),
                    const SizedBox(height: 4),
                    Text(_g(i).name, style: t.textTheme.headlineSmall),
                    if (_g(i).numbers.isNotEmpty)
                      Text(_g(i).numbers, style: t.textTheme.titleMedium),
                    if (_g(i).teacher.isNotEmpty)
                      Text('المعلمة/المعلم: ${_g(i).teacher}'),
                    const Divider(height: 24),
                    Row(children: [
                      Expanded(
                          child: Text('ابحثي في واتساب عن:  ${waKey(_g(i))}',
                              style: t.textTheme.titleMedium)),
                      IconButton(
                        tooltip: 'نسخ',
                        icon: const Icon(Icons.copy),
                        onPressed: () async {
                          await Clipboard.setData(
                              ClipboardData(text: waKey(_g(i))));
                          if (context.mounted) snack(context, 'تم النسخ');
                        },
                      ),
                    ]),
                  ]),
            ),
          ),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(children: [
                for (final m in media.take(2))
                  Padding(
                    padding: const EdgeInsetsDirectional.only(end: 8),
                    child: Image.file(File(m),
                        width: 48,
                        height: 48,
                        cacheWidth: 100,
                        errorBuilder: (_, __, ___) =>
                            const Icon(Icons.broken_image)),
                  ),
                Expanded(
                    child: Text(
                        body.isEmpty ? kindName(kind) : '${kindName(kind)}: $body',
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis)),
              ]),
            ),
          ),
          const SizedBox(height: 8),
          BubbleCard(
              startLabel: 'تشغيل الفقاعة من هذا الجروب',
              onStart: () => _startBubble(i)),
          const SizedBox(height: 8),
          OutlinedButton.icon(
              onPressed: () => _open(i),
              icon: const Icon(Icons.chat),
              label: const Text('فتح واتساب بيزنس (يدوي)')),
          if (opened)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                  'اختاري الجروب في واتساب (تم نسخ كلمة البحث) وأرسلي، ثم ارجعي هنا واضغطي "تم الإرسال".',
                  style: t.textTheme.bodyMedium
                      ?.copyWith(color: t.colorScheme.primary)),
            ),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
                child: FilledButton.tonalIcon(
                    onPressed: () => _mark(i, 'done'),
                    icon: const Icon(Icons.check),
                    label: const Text('تم الإرسال'))),
            const SizedBox(width: 12),
            Expanded(
                child: OutlinedButton.icon(
                    onPressed: () => _mark(i, 'skipped'),
                    icon: const Icon(Icons.skip_next),
                    label: const Text('تخطي'))),
          ]),
        ],
      ]),
    );
  }
}


// ======================= متصفح الملفات (استيكرات / صور) مع حفظ آخر مجلد =======================
class MediaBrowser extends StatefulWidget {
  final String title, storeKey, fallbackDir;
  final List<String> exts;
  final int max;
  const MediaBrowser({
    super.key,
    required this.title,
    required this.storeKey,
    required this.fallbackDir,
    required this.exts,
    required this.max,
  });
  @override
  State<MediaBrowser> createState() => _MediaBrowserState();
}

class _MediaBrowserState extends State<MediaBrowser> {
  late String dir;
  List<Directory> dirs = [];
  List<File> files = [];
  final List<String> sel = [];
  String? error;

  bool get atRoot => dir == kRoot || dir == '/' || p.dirname(dir) == dir;

  @override
  void initState() {
    super.initState();
    final saved = Store.data[widget.storeKey];
    dir = (saved is String && Directory(saved).existsSync())
        ? saved
        : widget.fallbackDir;
    _scan();
  }

  void _scan() {
    try {
      final d = <Directory>[];
      final f = <File>[];
      for (final e in Directory(dir).listSync(followLinks: false)) {
        final n = p.basename(e.path);
        if (n.startsWith('.')) continue;
        if (e is Directory) {
          d.add(e);
        } else if (e is File &&
            widget.exts
                .contains(p.extension(n).toLowerCase().replaceFirst('.', ''))) {
          f.add(e);
        }
      }
      d.sort((a, b) => p
          .basename(a.path)
          .toLowerCase()
          .compareTo(p.basename(b.path).toLowerCase()));
      f.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
      dirs = d;
      files = f;
      error = null;
      Store.data[widget.storeKey] = dir; // آخر مسار
      Store.save();
    } catch (_) {
      dirs = [];
      files = [];
      error =
          'لا أستطيع فتح هذا المجلد. اسمحي للتطبيق بالوصول إلى الملفات من إعدادات الهاتف.';
    }
  }

  void _go(String d) {
    setState(() {
      dir = d;
      _scan();
    });
  }

  void _toggle(String path) {
    setState(() {
      if (sel.contains(path)) {
        sel.remove(path);
      } else if (widget.max == 1) {
        sel
          ..clear()
          ..add(path);
      } else if (sel.length >= widget.max) {
        snack(context, 'الحد الأقصى ${widget.max}');
      } else {
        sel.add(path);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'المجلد الأعلى',
          icon: const Icon(Icons.arrow_upward),
          onPressed: atRoot ? null : () => _go(p.dirname(dir)),
        ),
        title: Text(widget.title),
        actions: [
          TextButton(
            onPressed:
                sel.isEmpty ? null : () => Navigator.pop(context, List<String>.from(sel)),
            child: Text('تم (${sel.length})'),
          ),
        ],
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(dir,
                textDirection: TextDirection.ltr,
                style: Theme.of(context).textTheme.bodySmall),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: error != null
              ? Center(
                  child: Padding(
                      padding: const EdgeInsets.all(16), child: Text(error!)))
              : CustomScrollView(slivers: [
                  SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (c, i) => ListTile(
                        dense: true,
                        leading: const Icon(Icons.folder),
                        title: Text(p.basename(dirs[i].path)),
                        onTap: () => _go(dirs[i].path),
                      ),
                      childCount: dirs.length,
                    ),
                  ),
                  if (files.isEmpty)
                    const SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.all(16),
                        child: Text('لا توجد ملفات مناسبة في هذا المجلد'),
                      ),
                    ),
                  SliverPadding(
                    padding: const EdgeInsets.all(8),
                    sliver: SliverGrid(
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 3,
                              mainAxisSpacing: 8,
                              crossAxisSpacing: 8),
                      delegate: SliverChildBuilderDelegate(
                        (c, i) {
                          final f = files[i];
                          final on = sel.contains(f.path);
                          return GestureDetector(
                            onTap: () => _toggle(f.path),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: Stack(fit: StackFit.expand, children: [
                                Container(
                                  color: Colors.black12,
                                  child: Image.file(f,
                                      fit: BoxFit.contain,
                                      cacheWidth: 300,
                                      errorBuilder: (_, __, ___) =>
                                          const Center(
                                              child:
                                                  Icon(Icons.broken_image))),
                                ),
                                if (on)
                                  Container(
                                    color: Colors.black45,
                                    child: const Center(
                                        child: Icon(Icons.check_circle,
                                            color: Colors.white, size: 40)),
                                  ),
                              ]),
                            ),
                          );
                        },
                        childCount: files.length,
                      ),
                    ),
                  ),
                ]),
        ),
      ]),
    );
  }
}

// ======================= تاب: رسالة موحدة لمصنف واتساب =======================
class LabelTab extends StatefulWidget {
  const LabelTab({super.key});
  @override
  State<LabelTab> createState() => _LabelTabState();
}

class _LabelTabState extends State<LabelTab> with WidgetsBindingObserver {
  final TextEditingController text = TextEditingController();
  String kind = 'text';
  List<String> media = [];
  String? label;
  final Set<String> off = {};
  int batch = 5;
  bool ready = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    text.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed && ready) {
      Bubble.syncAll().then((_) {
        if (mounted) setState(() {});
      });
    }
  }

  Future<void> _init() async {
    await Store.load();
    Wa.invalidate();
    final d = Store.data['draft2'];
    if (d is Map<String, dynamic>) {
      kind = (d['kind'] as String?) ?? 'text';
      if (!kKinds.containsKey(kind)) kind = 'text';
      text.text = (d['text'] as String?) ?? '';
      media = ((d['media'] as List?) ?? const [])
          .map((e) => e.toString())
          .where((x) => File(x).existsSync())
          .toList();
      label = d['label'] as String?;
      batch = ((d['batch'] as int?) ?? 5).clamp(1, 30).toInt();
      off
        ..clear()
        ..addAll(((d['off'] as List?) ?? const []).map((e) => e.toString()));
    }
    if (!mounted) return;
    setState(() => ready = true);
  }

  void _save() {
    Store.data['draft2'] = {
      'kind': kind,
      'text': text.text,
      'media': media,
      'label': label,
      'batch': batch,
      'off': off.toList(),
    };
    Store.save();
  }

  /// المصنف المحدد لو ما زال موجوداً في المصنفات المحفوظة.
  String? get _label {
    final l = label;
    if (l == null) return null;
    return Wa.cats.containsKey(l) ? l : null;
  }

  List<String> get _names {
    final l = _label;
    if (l == null) return [];
    return Wa.cats[l] ?? [];
  }

  List<String> get _chosen => _names.where((n) => !off.contains(n)).toList();

  void _setKind(String k) {
    setState(() {
      if ((k == 'stickers') != (kind == 'stickers')) media = [];
      kind = k;
      final lim = kLimit[k]!;
      if (media.length > lim) media = media.sublist(0, lim);
    });
    _save();
  }

  String _firstDir(List<String> c) {
    for (final d in c) {
      if (Directory(d).existsSync()) return d;
    }
    return kRoot;
  }

  Future<void> _addMedia(List<String> paths) async {
    for (final f in paths) {
      media.add(await persistMedia(f));
    }
    if (!mounted) return;
    setState(() {});
    _save();
  }

  Future<void> _gallery() async {
    if (kLimit[kind]! - media.length <= 0) return;
    try {
      final x = await ImagePicker().pickImage(source: ImageSource.gallery);
      if (x == null) return;
      await _addMedia([x.path]);
    } catch (e) {
      if (mounted) snack(context, 'تعذر فتح معرض الصور: $e');
    }
  }

  Future<void> _browse() async {
    final room = kLimit[kind]! - media.length;
    if (room <= 0) return;
    if (await prepareFolder() != null) {
      await Perm.reqStorage();
      return;
    }
    if (!mounted) return;
    final st = kind == 'stickers';
    final res = await Navigator.push<List<String>>(
      context,
      MaterialPageRoute(
        builder: (_) => MediaBrowser(
          title: st ? 'اختيار استيكرات' : 'اختيار صورة',
          storeKey: st ? 'dirSticker' : 'dirImage',
          fallbackDir: st
              ? _firstDir([
                  '$kRoot/Android/media/com.whatsapp.w4b/WhatsApp Business/Media/WhatsApp Business Stickers',
                  '$kRoot/WhatsApp Business/Media/WhatsApp Business Stickers',
                  '$kRoot/Download',
                ])
              : _firstDir(['$kRoot/DCIM/Camera', '$kRoot/Pictures', '$kRoot/Download']),
          exts: st ? ['webp'] : ['jpg', 'jpeg', 'png', 'webp'],
          max: room,
        ),
      ),
    );
    if (res == null || res.isEmpty) return;
    await _addMedia(res);
  }

  String? _validate() {
    if (kind == 'text' && text.text.trim().isEmpty) return 'اكتبي نص الرسالة';
    if (kind != 'text' && media.isEmpty) {
      return kind == 'stickers' ? 'اختاري استيكراً واحداً على الأقل' : 'اختاري صورة';
    }
    return null;
  }

  Future<void> _start() async {
    final v = _validate();
    if (v != null) {
      snack(context, v);
      return;
    }
    final lab = _label;
    if (lab == null) {
      snack(context, 'اختاري المصنف أولاً');
      return;
    }
    final sel = _chosen;
    if (sel.isEmpty) {
      snack(context, 'لا توجد جروبات محددة في هذا المصنف');
      return;
    }
    final batches = (sel.length / batch).ceil();
    final old = Store.ujob != null;
    final ok = await ask(
        context,
        'تجهيز الإرسال',
        '${kindName(kind)}${kind == 'stickers' ? ' (${media.length})' : ''} إلى ${sel.length} جروب من \"$lab\" على $batches دفعة (حتى $batch جروب في الدفعة).'
        '${old ? '\nسيتم إغلاق المهمة غير المنتهية السابقة.' : ''}',
        ok: 'ابدأ');
    if (!ok || !mounted) return;
    await Bubble.reset();
    Store.data['ujob'] = {
      'label': lab,
      'kind': kind,
      'text': (kind == 'text' || kind == 'imageText') ? text.text.trim() : '',
      'media': kind == 'text' ? <String>[] : media,
      'items': sel,
      'st': List<String>.filled(sel.length, 'pending'),
      'batch': batch,
      'finished': false,
    };
    _save();
    await Store.save();
    if (!mounted) return;
    await Navigator.push(
        context, MaterialPageRoute(builder: (_) => const LabelSendScreen()));
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cats = Wa.cats;
    final lab = _label;
    final names = _names;
    final lim = kLimit[kind]!;
    final job = Store.ujob;
    return Scaffold(
      appBar: AppBar(title: const Text('رسالة موحدة لمصنف')),
      body: !ready
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.all(16), children: [
              if (job != null) ...[
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(children: [
                      Text(
                          'مهمة مصنف غير منتهية (${job['label']}): ${(job['st'] as List).where((s) => s != 'pending').length} من ${(job['st'] as List).length}'),
                      const SizedBox(height: 8),
                      FilledButton(
                          onPressed: () async {
                            await Navigator.push(
                                context,
                                MaterialPageRoute(
                                    builder: (_) => const LabelSendScreen()));
                            if (mounted) setState(() {});
                          },
                          child: const Text('استكمال الإرسال')),
                    ]),
                  ),
                ),
                const SizedBox(height: 8),
              ],
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(12),
                  child: Text(
                      'اكتبي الرسالة مرة واحدة واختاري المصنف. التطبيق يرتب جروباته على دفعات، والفقاعة تكتب اسم كل جروب في بحث واتساب، وأنتِ تعلّمين عليه وتضغطين إرسال لكل دفعة.'),
                ),
              ),
              const SizedBox(height: 8),
              if (cats.isEmpty)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(children: [
                      const Text(
                          'لا توجد مصنفات محفوظة. من شاشة أسماء الجروبات الصقي أسماء جروبات المصنف مع اسم التصنيف.'),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: () async {
                          await Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) =>
                                      const WaGroupsScreen(groups: [])));
                          if (mounted) setState(() {});
                        },
                        icon: const Icon(Icons.groups),
                        label: const Text('إضافة مصنف'),
                      ),
                    ]),
                  ),
                )
              else ...[
                Text('المصنف', style: t.textTheme.titleMedium),
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final e in cats.entries)
                    ChoiceChip(
                      label: Text('${e.key} (${e.value.length})'),
                      selected: lab == e.key,
                      onSelected: (_) {
                        setState(() {
                          label = e.key;
                          off.clear();
                        });
                        _save();
                      },
                    ),
                ]),
              ],
              if (lab != null) ...[
                const SizedBox(height: 8),
                Card(
                  child: ExpansionTile(
                    title: Text('الجروبات: ${_chosen.length} من ${names.length}'),
                    subtitle: const Text('اضغطي لاستبعاد جروبات من هذه الرسالة'),
                    children: [
                      Row(children: [
                        TextButton(
                            onPressed: () {
                              setState(off.clear);
                              _save();
                            },
                            child: const Text('تحديد الكل')),
                        TextButton(
                            onPressed: () {
                              setState(() => off.addAll(names));
                              _save();
                            },
                            child: const Text('إلغاء الكل')),
                      ]),
                      for (final n in names)
                        CheckboxListTile(
                          dense: true,
                          controlAffinity: ListTileControlAffinity.leading,
                          value: !off.contains(n),
                          title: Text(n),
                          onChanged: (v) {
                            setState(() {
                              if (v == true) {
                                off.remove(n);
                              } else {
                                off.add(n);
                              }
                            });
                            _save();
                          },
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(children: [
                      const Expanded(
                          child: Text(
                              'عدد الجروبات في كل دفعة (واتساب يسمح غالباً بـ 5 في المشاركة الواحدة)')),
                      IconButton(
                          onPressed: batch > 1
                              ? () {
                                  setState(() => batch--);
                                  _save();
                                }
                              : null,
                          icon: const Icon(Icons.remove_circle_outline)),
                      Text('$batch', style: t.textTheme.titleLarge),
                      IconButton(
                          onPressed: batch < 30
                              ? () {
                                  setState(() => batch++);
                                  _save();
                                }
                              : null,
                          icon: const Icon(Icons.add_circle_outline)),
                    ]),
                  ),
                ),
              ],
              const Divider(height: 32),
              for (final k in kKinds.keys)
                ListTile(
                  selected: kind == k,
                  leading: Icon(kind == k
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off),
                  title: Text(kKinds[k]!, style: t.textTheme.titleMedium),
                  onTap: () => _setKind(k),
                ),
              const Divider(),
              if (kind == 'text' || kind == 'imageText') ...[
                const SizedBox(height: 8),
                TextField(
                  controller: text,
                  minLines: 4,
                  maxLines: 10,
                  onChanged: (_) => _save(),
                  decoration: const InputDecoration(
                      labelText: 'نص الرسالة', border: OutlineInputBorder()),
                ),
              ],
              if (lim > 0) ...[
                const SizedBox(height: 16),
                Wrap(spacing: 12, runSpacing: 12, children: [
                  for (var i = 0; i < media.length; i++)
                    Stack(children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Container(
                          width: 120,
                          height: 120,
                          color: Colors.black12,
                          child: Image.file(File(media[i]),
                              width: 120,
                              height: 120,
                              fit: kind == 'stickers'
                                  ? BoxFit.contain
                                  : BoxFit.cover,
                              cacheWidth: 300,
                              errorBuilder: (_, __, ___) =>
                                  const Center(child: Icon(Icons.broken_image))),
                        ),
                      ),
                      PositionedDirectional(
                        top: 0,
                        end: 0,
                        child: IconButton.filled(
                          iconSize: 18,
                          onPressed: () {
                            setState(() => media.removeAt(i));
                            _save();
                          },
                          icon: const Icon(Icons.close),
                        ),
                      ),
                    ]),
                ]),
                const SizedBox(height: 12),
                if (media.length < lim) ...[
                  if (kind != 'stickers') ...[
                    OutlinedButton.icon(
                      onPressed: _gallery,
                      icon: const Icon(Icons.photo_library),
                      label: const Text('اختيار من معرض الصور'),
                    ),
                    const SizedBox(height: 8),
                  ],
                  OutlinedButton.icon(
                    onPressed: _browse,
                    icon: Icon(kind == 'stickers'
                        ? Icons.emoji_emotions
                        : Icons.folder_open),
                    label: Text(kind == 'stickers'
                        ? 'إضافة استيكرات (${media.length}) — آخر مجلد محفوظ'
                        : 'اختيار من مجلد — آخر مجلد محفوظ'),
                  ),
                ],
              ],
              const SizedBox(height: 24),
              FilledButton.icon(
                  onPressed: _start,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('تجهيز الإرسال للمصنف')),
              const SizedBox(height: 24),
            ]),
    );
  }
}

class LabelSendScreen extends StatefulWidget {
  const LabelSendScreen({super.key});
  @override
  State<LabelSendScreen> createState() => _LabelSendScreenState();
}

class _LabelSendScreenState extends State<LabelSendScreen>
    with WidgetsBindingObserver {
  late Map<String, dynamic> job;
  bool started = false;

  @override
  void initState() {
    super.initState();
    job = Store.ujob!;
    WidgetsBinding.instance.addObserver(this);
    _sync();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) _sync();
  }

  List get _items => job['items'] as List;
  List get _st => job['st'] as List;
  int get _bs => ((job['batch'] as int?) ?? 5).clamp(1, 30).toInt();
  int _count(String s) => _st.where((x) => x == s).length;
  List<String> get _media =>
      (job['media'] as List).map((e) => e.toString()).toList();

  Future<void> _sync() async {
    await Bubble.sync('ujob');
    if (mounted) setState(() {});
  }

  bool _mediaOk() {
    for (final m in _media) {
      if (!File(m).existsSync()) {
        snack(context, 'ملف الصورة غير موجود، جهزي الرسالة من جديد');
        return false;
      }
    }
    return true;
  }

  Future<void> _startBubble(int at) async {
    if (!_mediaOk()) return;
    final err = await Bubble.start(labelSession(job), at);
    if (!mounted) return;
    if (err != null) {
      snack(context, err);
      return;
    }
    setState(() => started = true);
  }

  Future<void> _manualShare() async {
    if (!_mediaOk()) return;
    try {
      await _ch.invokeMethod<bool>(
          'share', {'text': job['text'] as String, 'paths': _media});
    } on PlatformException catch (e) {
      if (!mounted) return;
      snack(
          context,
          e.code == 'NO_WA_BUSINESS'
              ? 'WhatsApp Business غير مثبت على هذا الهاتف'
              : 'تعذر فتح واتساب: ${e.message}');
    }
  }

  Future<void> _setSt(int i, String s) async {
    _st[i] = s;
    await Store.save();
    unawaited(Bubble.setStatus(i, s));
    if (mounted) setState(() {});
  }

  Future<void> _finish() async {
    final ok = await ask(context, 'إنهاء المهمة',
        'المتبقي: ${_count('pending')} جروب. سيتم إغلاق المهمة والفقاعة.',
        ok: 'إنهاء');
    if (!ok) return;
    await Bubble.reset();
    job['finished'] = true;
    await Store.save();
    if (mounted) Navigator.pop(context);
  }

  Icon _icon(String s) => s == 'done'
      ? const Icon(Icons.check_circle, color: Colors.green)
      : s == 'skipped'
          ? const Icon(Icons.skip_next, color: Colors.orange)
          : const Icon(Icons.radio_button_unchecked);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final total = _items.length;
    final done = _count('done'), skipped = _count('skipped');
    final cur = _st.indexOf('pending');
    final bs = _bs;
    final media = _media;
    final body = (job['text'] as String).trim();
    final batches = (total / bs).ceil();

    return Scaffold(
      appBar: AppBar(title: Text('مصنف: ${job['label']}'), actions: [
        IconButton(
            tooltip: 'إنهاء المهمة',
            onPressed: _finish,
            icon: const Icon(Icons.stop_circle_outlined)),
      ]),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        LinearProgressIndicator(
            value: total == 0 ? 0 : (done + skipped) / total, minHeight: 8),
        const SizedBox(height: 8),
        Text(
            'تم $done  •  تخطي $skipped  •  متبقي ${_count('pending')}  (من $total في $batches دفعة)'),
        const SizedBox(height: 12),
        if (cur < 0) ...[
          const SizedBox(height: 12),
          const Icon(Icons.check_circle, size: 72, color: Colors.green),
          const SizedBox(height: 12),
          Text('اكتمل المرور على كل الجروبات',
              textAlign: TextAlign.center, style: t.textTheme.titleLarge),
          const SizedBox(height: 16),
          FilledButton(onPressed: _finish, child: const Text('إنهاء المهمة')),
        ] else ...[
          BubbleCard(
              startLabel:
                  started ? 'استكمال بالفقاعة' : 'تشغيل الفقاعة من الجروب ${cur + 1}',
              onStart: () => _startBubble(cur)),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                  'في واتساب: اضغطي الفقاعة فيُكتب اسم الجروب في البحث، علّمي عليه، ثم اضغطي الفقاعة للجروب التالي. '
                  'بعد آخر جروب في الدفعة اضغطي إرسال في واتساب، ثم الفقاعة لتبدأ الدفعة التالية. '
                  'اضغطي الفقاعة مطولاً للتخطي أو إعادة الكتابة أو الإغلاق.',
                  style: t.textTheme.bodyMedium),
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
              onPressed: _manualShare,
              icon: const Icon(Icons.chat),
              label: const Text('فتح واتساب بالرسالة (يدوي)')),
        ],
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              for (final m in media.take(2))
                Padding(
                  padding: const EdgeInsetsDirectional.only(end: 8),
                  child: Image.file(File(m),
                      width: 48,
                      height: 48,
                      cacheWidth: 100,
                      errorBuilder: (_, __, ___) =>
                          const Icon(Icons.broken_image)),
                ),
              Expanded(
                  child: Text(
                      body.isEmpty
                          ? kindName(job['kind'] as String)
                          : '${kindName(job['kind'] as String)}: $body',
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis)),
            ]),
          ),
        ),
        const SizedBox(height: 8),
        for (var b = 0; b < batches; b++) ...[
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 4),
            child: Text('الدفعة ${b + 1}', style: t.textTheme.titleSmall),
          ),
          for (var i = b * bs;
              i < ((b + 1) * bs < total ? (b + 1) * bs : total);
              i++)
            ListTile(
              dense: true,
              leading: _icon(_st[i] as String),
              title: Text(_items[i].toString()),
              onTap: () async {
                await Clipboard.setData(ClipboardData(text: _items[i].toString()));
                if (context.mounted) snack(context, 'تم نسخ الاسم');
              },
              trailing: PopupMenuButton<String>(
                onSelected: (v) {
                  if (v == 'start') {
                    _startBubble(i);
                  } else {
                    _setSt(i, v);
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'start', child: Text('ابدأ الفقاعة من هنا')),
                  PopupMenuItem(value: 'done', child: Text('تعليم: تم')),
                  PopupMenuItem(value: 'skipped', child: Text('تعليم: تخطي')),
                  PopupMenuItem(value: 'pending', child: Text('إعادته للمعلّق')),
                ],
              ),
            ),
        ],
        const SizedBox(height: 24),
      ]),
    );
  }
}
