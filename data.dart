import 'dart:convert';
import 'dart:io';
import 'package:cryptography/cryptography.dart';
import 'package:file_selector/file_selector.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';

class PageText {
  PageText(this.number, this.text);
  final int number;
  final String text;
  Map<String, dynamic> toJson() => {'page': number, 'text': text};
  factory PageText.fromJson(Map<String, dynamic> j) =>
      PageText((j['page'] as num?)?.toInt() ?? 1, j['text']?.toString() ?? '');
}

class Reference {
  Reference({required this.id, required this.name, required this.category,
    required this.pages, required this.active, this.pdfFile});
  final String id;
  final String name;
  final String category;
  final List<PageText> pages;
  bool active;
  final String? pdfFile;
  Map<String, dynamic> toJson() => {
    'id': id, 'name': name, 'category': category, 'active': active,
    'pdfFile': pdfFile, 'pages': pages.map((p) => p.toJson()).toList()
  };
  factory Reference.fromJson(Map<String, dynamic> j) => Reference(
    id: j['id']?.toString() ?? '', name: j['name']?.toString() ?? '',
    category: j['category']?.toString() ?? 'عام',
    active: j['active'] != false, pdfFile: j['pdfFile']?.toString(),
    pages: (j['pages'] as List? ?? []).whereType<Map>().map((v) =>
      PageText.fromJson(Map<String,dynamic>.from(v))).toList());
}

class Hit {
  Hit(this.reference, this.page, this.score, this.quote);
  final Reference reference;
  final PageText page;
  final int score;
  final String quote;
  String get citation => '${reference.name} — صفحة ${page.number}';
}

class LocalStore {
  late final Directory root;
  List<Reference> refs = [];
  String? modelFile;
  bool get hasPassword => _salt != null && _hash != null;
  String? _salt;
  String? _hash;
  final _kdf = Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: 120000, bits: 256);

  Future<void> init() async {
    root = Directory(p.join((await getApplicationSupportDirectory()).path, 'wl1'));
    await root.create(recursive: true);
    final f = File(p.join(root.path, 'library.json'));
    if (await f.exists()) {
      final data = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      refs = (data['refs'] as List? ?? [])
          .whereType<Map>().map((v) => Reference.fromJson(Map<String, dynamic>.from(v))).toList();
      _salt = data['salt']?.toString();
      _hash = data['hash']?.toString();
      modelFile = data['model']?.toString();
    }
    if (refs.isEmpty) {
      refs.add(Reference(id: 'demo', name: 'General Electricity — Demo Notes', category: 'General principles',
        pages: [PageText(1, 'Electrical voltage is measured in volts (V). Electric current is measured in amperes (A). Resistance is measured in ohms.'),
                PageText(2, 'Batteries and generators are sources of electrical power. An electrical bus distributes electrical power to loads.'),
                PageText(3, 'A backup source may supply selected loads if the main source fails. The available duration depends on capacity, condition and connected loads.')],
        active: true));
      await save();
    }
  }

  Future<void> save() async {
    final f = File(p.join(root.path, 'library.json'));
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode({'refs': refs.map((e) => e.toJson()).toList(),
      'salt': _salt, 'hash': _hash, 'model': modelFile}), flush: true);
    if (await f.exists()) await f.delete();
    await tmp.rename(f.path);
  }

  Future<void> setPassword(String value) async {
    if (value.length < 8) throw Exception('الباسورد لازم يكون ٨ حروف أو أكثر');
    final nonce = SecretKeyData.random(length: 16);
    final saltBytes = await nonce.extractBytes();
    final key = await _kdf.deriveKey(secretKey: SecretKey(utf8.encode(value)), nonce: saltBytes);
    _salt = base64Encode(saltBytes);
    _hash = base64Encode(await key.extractBytes());
    await save();
  }

  Future<bool> checkPassword(String value) async {
    if (!hasPassword) return false;
    final key = await _kdf.deriveKey(secretKey: SecretKey(utf8.encode(value)), nonce: base64Decode(_salt!));
    final a = await key.extractBytes(), b = base64Decode(_hash!);
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) { diff |= a[i] ^ b[i]; }
    return diff == 0;
  }

  Future<void> importDocument(XFile source, String category) async {
    final ext = p.extension(source.name).toLowerCase();
    if (!['.pdf', '.txt', '.json'].contains(ext)) throw Exception('الملف غير مدعوم');
    if (await source.length() > 40 * 1024 * 1024) throw Exception('الحد الحالي للملف 40MB');
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final stored = File(p.join(root.path, 'ref_$id$ext'));
    await source.saveTo(stored.path);
    final pages = <PageText>[];
    if (ext == '.pdf') {
      await pdfrxFlutterInitialize();
      final doc = await PdfDocument.openFile(stored.path);
      try {
        for (var i = 0; i < doc.pages.length; i++) {
          final raw = await doc.pages[i].loadText();
          final text = raw?.fullText.trim() ?? '';
          if (text.isNotEmpty) pages.add(PageText(i + 1, text));
        }
      } finally { await doc.dispose(); }
    } else if (ext == '.txt') {
      final text = await stored.readAsString();
      for (var i = 0; i < text.length; i += 1800) {
        pages.add(PageText(i ~/ 1800 + 1, text.substring(i, (i + 1800).clamp(0, text.length).toInt())));
      }
    } else {
      final json = jsonDecode(await stored.readAsString());
      if (json is! Map || json['schema'] != 'wl1-reference-v1' || json['sections'] is! List) {
        await stored.delete();
        throw Exception('صيغة JSON غير معتمدة');
      }
      for (final entry in json['sections'] as List) {
        if (entry is Map) pages.add(PageText(int.tryParse('${entry['page']}') ?? pages.length + 1,
            '${entry['text'] ?? ''}'));
      }
    }
    if (pages.isEmpty && ext != '.pdf') {
      await stored.delete();
      throw Exception('الملف مفيهوش نص قابل للبحث.');
    }
    // Keep scanned PDFs even without extractable text: original pages remain
    // viewable. Search and AI answers require OCR/indexing later.

    refs.add(Reference(id: id, name: source.name, category: category, pages: pages, active: true,
        pdfFile: ext == '.pdf' ? stored.path : null));
    await save();
  }

  Future<void> importModel(XFile source) async {
    if (p.extension(source.name).toLowerCase() != '.gguf') throw Exception('اختر ملف GGUF');
    final dst = File(p.join(root.path, 'teacher_model.gguf'));
    await source.saveTo(dst.path);
    modelFile = dst.path;
    await save();
  }

  Future<void> deleteRef(Reference ref) async {
    if (ref.pdfFile != null) {
      final f = File(ref.pdfFile!);
      if (await f.exists()) await f.delete();
    }
    refs.removeWhere((e) => e.id == ref.id);
    await save();
  }

  // Keyword ranker for first prototype. Not semantic vector retrieval.
  // Minimal bilingual glossary for Egyptian Arabic questions over English PDFs.
  List<Hit> search(String question, {int top = 3}) {
    final q = _tokens(question).toSet();
    const glossary = <String, List<String>>{
      'كهربا': ['electrical','power'],
      'الكهربا': ['electrical','power'],
      'كهرباء': ['electrical','power'],
      'بطاريه': ['battery'],
      'بطارية': ['battery'],
      'البطاريه': ['battery'],
      'البطارية': ['battery'],
      'مولد': ['generator'],
      'المولد': ['generator'],
      'طلمبه': ['pump'],
      'طلمبة': ['pump'],
      'الطلمبه': ['pump'],
      'الطلمبة': ['pump'],
      'وقود': ['fuel'],
      'الوقود': ['fuel'],
      'بنزين': ['fuel'],
      'الضغط': ['pressure'],
      'ضغط': ['pressure'],
      'فرعي': ['secondary'],
      'رئيسي': ['main','master'],
      'الطوارئ': ['emergency'],
      'طوارئ': ['emergency'],
      'بيغذي': ['supply'],
      'تغذية': ['supply'],
      'التغذية': ['supply'],
      'بيشحن': ['charge'],
      'الشحن': ['charge'],
    };
    for(final word in q.toList()) {
      q.addAll(glossary[word] ?? const <String>[]);
    }

    if (q.isEmpty) return [];
    final scored = <Hit>[];
    for (final ref in refs.where((r) => r.active)) {
      for (final page in ref.pages) {
        final text = _normalize(page.text);
        var score = 0;
        for (final word in q) {
          if (text.contains(word)) score += 1;
          if (_normalize(ref.name).contains(word)) score += 1;
        }
        if (score > 0) {
          final pos = q.map(text.indexOf).where((n) => n >= 0).fold<int>(text.length,
             (a, b) => a < b ? a : b);
          final start = (pos - 220).clamp(0, page.text.length).toInt();
          final end = (start + 1050).clamp(0, page.text.length).toInt();
          scored.add(Hit(ref, page, score, page.text.substring(start, end)));
        }
      }
    }
    scored.sort((a,b) => b.score.compareTo(a.score));
    return scored.take(top).toList();
  }

  String _normalize(String s) => s.toLowerCase()
      .replaceAll(RegExp(r'[\u064B-\u065F\u0670]'), '')
      .replaceAll(RegExp('[أإآ]'), 'ا').replaceAll('ى', 'ي').replaceAll('ة','ه');
  List<String> _tokens(String input) => _normalize(input).split(RegExp(r'[^\u0621-\u064Aa-z0-9]+'))
      .where((t) => t.length >= 3 && !{'ايه','ازاي','يعني','شرح','اشرح','what','the','how','does','about','this'}.contains(t))
      .toSet().toList();
}
