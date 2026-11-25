import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';
import 'package:llamadart/llamadart.dart';
import 'package:pdfrx/pdfrx.dart';
import 'data.dart';

const ink = Color(0xFF243746);
const muted = Color(0xFF667784);
const bg = Color(0xFFE9EEF1);
const accent = Color(0xFF41677C);
const panel = Color(0xFFF9FBFC);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final db = LocalStore();
  await db.init();
  runApp(WlApp(db: db));
}

class WlApp extends StatelessWidget {
  const WlApp({super.key, required this.db});
  final LocalStore db;
  @override Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'WL-1 Smart Instructor',
    locale: const Locale('ar'),
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: accent, brightness: Brightness.light),
      scaffoldBackgroundColor: bg,
      appBarTheme: const AppBarTheme(backgroundColor: bg, foregroundColor: ink, centerTitle: false, elevation: 0),
      cardTheme: CardThemeData(color: panel, elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(17),side: const BorderSide(color: Color(0xFFDCE4E9)))),
      inputDecorationTheme: InputDecorationTheme(
        filled: true, fillColor: Colors.white,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
        enabledBorder: OutlineInputBorder(borderSide: const BorderSide(color: Color(0xFFCFD9E0)),borderRadius: BorderRadius.circular(14)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14,vertical: 12),
      ),
    ),
    home: MainScreen(db: db),
  );
}

class ChatMessage {
  ChatMessage(this.text, this.mine, {this.hits = const []});
  String text;
  final bool mine;
  final List<Hit> hits;
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key, required this.db});
  final LocalStore db;
  @override State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with WidgetsBindingObserver {
  int page = 0; // Open the instructor first. 0 = instructor, 1 = references.
  bool admin = false;
  LlamaEngine? engine;
  bool loadingModel = false;
  bool answering = false;
  String engineStatus = 'الموديل غير مُشغّل';
  final chatInput = TextEditingController();
  final searchInput = TextEditingController();
  final messages = <ChatMessage>[];

  LocalStore get db => widget.db;

  @override void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    messages.add(ChatMessage('اسألني بالراحة، وهنفهمها سوا. الكتاب هيفضل بالإنجليزي، وأنا هشرحهولك بالعربي من المرجع.',false));
  }
  @override void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      if (admin && mounted) setState(() => admin = false);
    }
  }
  @override void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    chatInput.dispose(); searchInput.dispose();
    engine?.dispose();
    super.dispose();
  }
  void notice(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text),behavior: SnackBarBehavior.floating));
  }
  void goto(int index) { setState(() => page=index); }

  Future<String?> inputDialog(String title, {bool secret=false, String hint=''}) async {
    final c = TextEditingController();
    final result = await showDialog<String>(context: context, builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(controller:c, autofocus:true, obscureText: secret, decoration: InputDecoration(hintText:hint)),
      actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('إلغاء')),
        FilledButton(onPressed:()=>Navigator.pop(ctx,c.text),child:const Text('متابعة'))],
    ));
    c.dispose();
    return result;
  }
  Future<bool> unlock() async {
    if (admin) return true;
    if (!db.hasPassword) {
      final pass = await inputDialog('تعيين باسورد المسؤول', secret:true, hint:'٨ أحرف على الأقل');
      if (pass == null) return false;
      try { await db.setPassword(pass); setState(()=>admin=true); notice('تم إعداد باسورد المسؤول على هذا الجهاز');return true; }
      catch(e) {notice('$e');return false;}
    }
    final pass = await inputDialog('باسورد المسؤول',secret:true);
    if (pass == null) return false;
    if (!await db.checkPassword(pass)) {notice('الباسورد غير صحيح');return false;}
    setState(()=>admin=true);return true;
  }
  Future<void> changePassword() async {
    if (!await unlock()) return;
    final value = await inputDialog('الباسورد الجديد', secret:true,hint:'٨ أحرف على الأقل');
    if (value == null) return;
    try {await db.setPassword(value);notice('تم تغيير باسورد الجهاز');}
    catch(e) {notice('$e');}
  }
  Future<void> addReference() async {
    if (!await unlock()) return;
    final source=await openFile(acceptedTypeGroups: [const XTypeGroup(label:'مراجع',extensions:['pdf','txt','json'])]);
    if(source==null)return;
    final category = await inputDialog('تصنيف المرجع', hint:'مثال: مبادئ الكهرباء') ?? 'عام';
    if (!mounted) return;
    try {
      await db.importDocument(source, category.isEmpty?'عام':category);
      if (!mounted)return;
      setState((){});notice('اتضاف المرجع واتعمل له فهرس محلي');
    }catch(e){notice('تعذر إضافة المرجع: $e');}
  }
  Future<void> addModel() async {
    if (!await unlock()) return;
    final source = await openFile(acceptedTypeGroups:[const XTypeGroup(label:'GGUF model',extensions:['gguf'])]);
    if(source==null)return;
    try {
      setState(()=>engineStatus='جار نسخ النموذج إلى الجهاز...');
      if(engine != null){ await engine!.dispose(); engine=null; }
      await db.importModel(source);
      if (!mounted)return;
      setState(()=>engineStatus='النموذج اتضاف. شغّله من صفحة المدرس.');
      notice('تم استيراد النموذج محليًا');
    }catch(e){notice('تعذر استيراد النموذج: $e');}
  }
  Future<void> startModel() async {
    if(engine != null || loadingModel)return;
    if (db.modelFile == null || !await File(db.modelFile!).exists()) {
      notice('أضف نموذج GGUF من مكتبة المراجع باستخدام باسورد المسؤول');return;
    }
    setState(() {loadingModel=true;engineStatus='جار تشغيل النموذج على الجهاز...';});
    final temp=LlamaEngine(LlamaBackend());
    try {
      // CPU-first setting is deliberately conservative for older iPhones.
      await temp.loadModel(db.modelFile!, modelParams: const ModelParams(contextSize:2048,gpuLayers:0));
      if (!mounted) {await temp.dispose();return;}
      setState((){engine=temp;engineStatus='المدرس المحلي جاهز';});
    } catch(e) {
      await temp.dispose();
      if(mounted){setState(()=>engineStatus='فشل تشغيل النموذج');notice('تعذر تشغيل النموذج: $e');}
    } finally {if(mounted)setState(()=>loadingModel=false);}
  }
  Future<void> sendQuestion() async {
    final question=chatInput.text.trim();
    if(question.isEmpty || answering)return;
    chatInput.clear();
    var hits=db.search(question);
    // A short follow-up like 'ليه؟' keeps the last referenced passage in context.
    // Never borrow an unrelated previous passage for a new substantive question.
    if(hits.isEmpty && question.length <= 65) {
      final previous = messages.where((m) => !m.mine && m.hits.isNotEmpty);
      if(previous.isNotEmpty) hits = previous.last.hits;
    }
    setState(() {messages.add(ChatMessage(question,true)); answering=true;});
    if(hits.isEmpty){
      setState((){messages.add(ChatMessage('مش لاقي نص في المراجع النشطة يدعم الإجابة. جرّب سؤالًا أدق أو أضف مرجعًا.',false)); answering=false;});
      return;
    }
    final reply = ChatMessage('',false,hits:hits);
    setState(()=>messages.add(reply));
    if(engine==null){await startModel();}
    if(engine==null){
      if(mounted)setState((){
        reply.text='لقيت النصوص دي في المراجع. علشان أحولها لشرح ذكي، لازم تجهّز نموذج GGUF من إدارة المراجع.\n\n${hits.map((h)=>'${h.citation}\n${h.quote.substring(0,h.quote.length.clamp(0,320).toInt())}').join('\n\n')}';
        answering=false;});
      return;
    }
    final evidence = hits.asMap().entries.map((e)=>
      '[${e.key+1}] ${e.value.citation}\n${e.value.quote}').join('\n\n');
    final priorConversation = messages
        .where((m) => m.text.trim().isNotEmpty)
        .toList()
        .reversed
        .take(7)
        .toList()
        .reversed
        .map((m) => '${m.mine ? 'الطالب' : 'المدرس'}: ${m.text.length > 500 ? m.text.substring(0, 500) : m.text}')
        .join('\n');
    final prompt = '''أنت مدرس بيشرح بالعربي المصري، كأنك قاعد بتذاكر مع صاحبك.
جاوب السؤال الحالي أولًا، وبعده وضّح الفكرة بالراحة وبكلام طبيعي.
افهم الأسئلة المكملة من سياق الحوار، مثل «ليه؟» و«مش فاهم».
ممنوع ترجمة الكتاب الأصلي أو تغيير نصه. اقتبس النص الإنجليزي كما ورد عند الحاجة.
اعتمد فقط على المقاطع المسترجعة من الكتب ولا تضف وقائع خارجها.
عند عدم كفاية الدليل قل «المعلومة دي مش واضحة في الجزء اللي عندي من الكتاب».
افصل بين حقيقة من المصدر وبين التفسير، واذكر [1] أو [2] أو [3] مع كل معلومة أساسية.
لا تقدم إرشادات تسليح أو استهداف أو تنفيذ عمليات عسكرية.

الحوار السابق:
$priorConversation

سؤال الطالب الآن:
$question

المقاطع المرجعية الأصلية باللغة الإنجليزية:
$evidence

جواب عربي مصري طبيعي:''';
    try {
      await for(final part in engine!.create([
        LlamaChatMessage.fromText(role:LlamaChatRole.user,text:prompt),
      ],params:const GenerationParams(maxTokens:320,))) {
        final chunk=part.choices.first.delta.content;
        if(chunk!=null && mounted){setState(()=>reply.text+=chunk);}
      }
      if (reply.text.trim().isEmpty && mounted) setState(()=>reply.text='النموذج ما أنتجش إجابة.');
    }catch(e){if(mounted)setState(()=>reply.text='فشل توليد الإجابة: $e');}
    finally {if(mounted)setState(()=>answering=false);}
  }

  @override Widget build(BuildContext context) {
    return Directionality(textDirection:TextDirection.rtl,child:Scaffold(
      appBar:AppBar(title:const Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
        Text('WL-1',style:TextStyle(fontWeight:FontWeight.w800,fontSize:20)),
        Text('SMART INSTRUCTOR',style:TextStyle(fontSize:9,letterSpacing:1.8,color:muted)),
      ])),
      body:SafeArea(child:AnimatedSwitcher(duration:const Duration(milliseconds:140),child:KeyedSubtree(
        key:ValueKey(page),child:[_ask(),_refs()].elementAtOrNull(page) ?? _ask(),
      ))),
      bottomNavigationBar:NavigationBar(
        height:73, selectedIndex:page,
        backgroundColor:const Color(0xFFF5F8F9),
        indicatorColor:const Color(0xFFDDE9EF),
        onDestinationSelected:goto,
        labelBehavior:NavigationDestinationLabelBehavior.alwaysShow,
        destinations:const [
          NavigationDestination(icon:Icon(Icons.chat_bubble_outline),selectedIcon:Icon(Icons.chat_bubble),label:'المدرس'),
          NavigationDestination(icon:Icon(Icons.folder_outlined),selectedIcon:Icon(Icons.folder),label:'المراجع'),
        ],
      ),
    ));
  }
  Widget wrapPage(Widget child) => Center(child:ConstrainedBox(constraints:const BoxConstraints(maxWidth:790),
    child:Padding(padding:const EdgeInsets.all(16),child:child)));
  Widget title(String name,{String? sub}) => Padding(padding:const EdgeInsets.only(top:6,bottom:18),child:
    Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(name,style:const TextStyle(color:ink,fontSize:23,fontWeight:FontWeight.w700)),
      if(sub!=null)Padding(padding:const EdgeInsets.only(top:5),child:Text(sub,style:const TextStyle(color:muted,fontSize:13)))]));
  Widget _ask()=>Column(children:[
    Padding(padding:const EdgeInsets.symmetric(horizontal:16,vertical:6),child:Row(children:[
      Expanded(child:Text(engineStatus,style:const TextStyle(color:muted,fontSize:12))),
      if(engine==null)TextButton(onPressed:loadingModel?null:startModel,child:Text(loadingModel?'بيشتغل...':'تشغيل AI')),
    ])),
    Expanded(child:ListView.builder(padding:const EdgeInsets.symmetric(horizontal:12,vertical:8),itemCount:messages.length,itemBuilder:(c,i){
      final m=messages[i];return Align(alignment:m.mine?Alignment.centerRight:Alignment.centerLeft,
        child:Container(margin:const EdgeInsets.only(bottom:10),constraints:BoxConstraints(maxWidth:MediaQuery.sizeOf(context).width*.91),
          decoration:BoxDecoration(color:m.mine?const Color(0xFFD6E7EF):panel,borderRadius:BorderRadius.circular(14)),
          padding:const EdgeInsets.all(13),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
            SelectableText(m.text,style:const TextStyle(color:ink,fontSize:14,height:1.65)),
            if(m.hits.isNotEmpty) ...[
              const Divider(),const Text('المراجع',style:TextStyle(color:muted,fontSize:11)),
              for(final h in m.hits)TextButton.icon(onPressed:()=>showRef(h.reference,h.page.number),
                icon:const Icon(Icons.book_outlined,size:14),label:Text(h.citation,maxLines:2,overflow:TextOverflow.ellipsis,
                  style:const TextStyle(fontSize:11)))
            ]
          ])));
    })),
    Padding(padding:const EdgeInsets.fromLTRB(12,5,12,10),child:Row(children:[
      Expanded(child:TextField(controller:chatInput,enabled:!answering,
        decoration:const InputDecoration(hintText:'اسأل المدرس...',isDense:true),onSubmitted:(_)=>sendQuestion())),
      const SizedBox(width:8),IconButton.filled(onPressed:answering?null:sendQuestion,icon:answering?
        const SizedBox(height:18,width:18,child:CircularProgressIndicator(strokeWidth:2,color:Colors.white)):
        const Icon(Icons.send_rounded)),
    ])),
  ]);
  Widget _refs() => SingleChildScrollView(child:wrapPage(Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
    title('مكتبة المراجع',sub:'مراجع الجهاز فقط'),
    Row(children:[Expanded(child:OutlinedButton.icon(onPressed:addReference,icon:const Icon(Icons.add),label:const Text('إضافة مرجع'))),
      const SizedBox(width:8),IconButton.outlined(onPressed:()=>unlock(),icon:Icon(admin?Icons.lock_open:Icons.lock_outline),tooltip:'وضع المسؤول')]),
    const SizedBox(height:12),TextField(controller:searchInput,onChanged:(_)=>setState((){}),
      decoration:const InputDecoration(prefixIcon:Icon(Icons.search),hintText:'بحث باسم المرجع...')),
    const SizedBox(height:10),
    for(final r in db.refs.where((r)=>r.name.toLowerCase().contains(searchInput.text.toLowerCase())))
      Card(child:Padding(padding:const EdgeInsets.all(12),child:Column(children:[
        ListTile(contentPadding:EdgeInsets.zero,title:Text(r.name),subtitle:Text('${r.category} · ${r.pages.length} صفحة · ${r.active?'نشط':'موقوف'}'),
          leading:const Icon(Icons.picture_as_pdf_outlined,color:accent),onTap:()=>showRef(r,1)),
        if(admin)Row(mainAxisAlignment:MainAxisAlignment.end,children:[
          TextButton(onPressed:() async{r.active=!r.active;await db.save();if(mounted)setState((){});},
            child:Text(r.active?'إيقاف':'تفعيل')),
          TextButton(onPressed:() async{
            final allow=await showDialog<bool>(context:context,builder:(c)=>AlertDialog(title:const Text('حذف المرجع؟'),
              content:Text(r.name),actions:[TextButton(onPressed:()=>Navigator.pop(c,false),child:const Text('إلغاء')),
                FilledButton(onPressed:()=>Navigator.pop(c,true),child:const Text('حذف'))]));
            if(allow==true){await db.deleteRef(r);if(mounted)setState((){});}
          },child:const Text('حذف',style:TextStyle(color:Colors.red))),
        ])
      ]))),
    const SizedBox(height:14),
    Card(child:Padding(padding:const EdgeInsets.all(14),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      const Text('المسؤول والنموذج المحلي',style:TextStyle(fontWeight:FontWeight.w700,color:ink)),
      const SizedBox(height:6),Text(db.modelFile==null?'لم تتم إضافة نموذج GGUF':'تم حفظ نموذج GGUF على الجهاز',style:const TextStyle(color:muted)),
      Wrap(spacing:7,children:[
        OutlinedButton.icon(onPressed:addModel,icon:const Icon(Icons.memory),label:const Text('إضافة نموذج AI')),
        OutlinedButton.icon(onPressed:changePassword,icon:const Icon(Icons.key),label:const Text('تغيير الباسورد')),
        if(admin)TextButton(onPressed:()=>setState(()=>admin=false),child:const Text('قفل المسؤول')),
      ])
    ]))),
    const SizedBox(height:8),const Text('ملفات PDF المصوّرة تحتاج OCR قبل إضافتها إلى البحث.',
      style:TextStyle(color:muted,fontSize:11)),
  ])));

  void showRef(Reference ref, int pageNumber) {
    showModalBottomSheet(context:context,isScrollControlled:true,backgroundColor:bg,builder:(ctx)=>
      SizedBox(height:MediaQuery.sizeOf(ctx).height*.91,child:Column(children:[
        ListTile(title:Text(ref.name,maxLines:1,overflow:TextOverflow.ellipsis),
          subtitle:Text('الصفحة $pageNumber'),trailing:IconButton(onPressed:()=>Navigator.pop(ctx),icon:const Icon(Icons.close))),
        Expanded(child:ref.pdfFile!=null?
          PdfViewer.file(ref.pdfFile!, initialPageNumber:pageNumber):SingleChildScrollView(padding:const EdgeInsets.all(16),child:
           Directionality(textDirection:TextDirection.ltr,child:SelectableText(ref.pages.map((p)=>p.text).join('\n\n'))))),
      ])));
  }
}
