import json,pathlib,re,unittest
ROOT=pathlib.Path(__file__).parents[1]
class Translation(unittest.TestCase):
 def test_effects_keep_both_search_names(self):
  rows=json.loads((ROOT/'assets/war_catalog.json').read_text('utf8'))['effects']
  for row in rows:
   self.assertTrue(row['englishName'])
   self.assertFalse(re.search('[\u3400-\u9fff]',row['englishName']))
