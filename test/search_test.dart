import 'package:flutter_test/flutter_test.dart';
import 'package:wl1_smart_instructor/data.dart';

void main() {
  test('matches an indexed reference and preserves the source page', () {
    final store = LocalStore();
    store.refs = [Reference(id:'1',name:'Electrical Basics',category:'General',active:true,
      pages:[PageText(7,'voltage is measured in volts'),PageText(8,'temperature is measured in degrees')])];
    final hits = store.search('voltage');
    expect(hits, isNotEmpty);
    expect(hits.first.page.number, 7);
    expect(hits.first.citation, contains('صفحة 7'));
  });
  test('Arabic question can retrieve English power-source terms', () {
    final store = LocalStore();
    store.refs = [Reference(id:'3',name:'Electrical',category:'General',active:true,
      pages:[PageText(17,'The battery supplies the electrical bus while the generator is off.')])];
    expect(store.search('البطارية'), isNotEmpty);
  });
  test('inactive references are excluded', () {
    final store = LocalStore();
    store.refs = [Reference(id:'1',name:'Voltage',category:'General',active:false,
      pages:[PageText(1,'voltage source')])];
    expect(store.search('voltage'), isEmpty);
  });
  test('no references means no fabricated answer evidence', () {
    final store = LocalStore();
    expect(store.search('missing'), isEmpty);
  });
}
