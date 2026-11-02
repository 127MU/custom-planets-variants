import collections,json,pathlib,unittest
class Catalog(unittest.TestCase):
 def test_complete_distinct_categorized(self):
  rows=json.loads((pathlib.Path(__file__).parents[1]/'assets/war_catalog.json').read_text('utf8'))['effects']
  self.assertEqual(len(rows),312);self.assertEqual(len({r['id'] for r in rows}),312)
  self.assertGreaterEqual(len({r['groupKey'] for r in rows}),10)
  self.assertTrue(all(r['name'] and r['groupLabel'] and isinstance(r['experimental'],bool) for r in rows))
  for r in rows:
   if r['effectType']==94:self.assertEqual(r['groupKey'],'variants')
   if r['effectType']==32:self.assertEqual(r['groupKey'],'stratagems')
  self.assertEqual(next(r for r in rows if r['id']==1431)['groupKey'],'enemies')
