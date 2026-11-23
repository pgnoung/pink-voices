import json
from pathlib import Path
import tempfile
import unittest

import plaud_vocabulary
from plaud_vocabulary import SCHEMA, build_evidence, canonical_terms, load_vocabulary, make_index, write_index


class PlaudVocabularyTests(unittest.TestCase):
    def test_canonical_terms_exclude_personal_and_unsafe_values(self):
        original = plaud_vocabulary.PERSONAL_MARKERS
        plaud_vocabulary.PERSONAL_MARKERS = ("ownername",)
        self.addCleanup(setattr, plaud_vocabulary, "PERSONAL_MARKERS", original)
        dictionary = "| Heard | Correct Form | Notes |\n| --- | --- | --- |\n| x | Codex | safe |\n| x | คุณOwnerName | private |\n| x | 1 แผนก | no |\n| x | https://example.test | no |\n\n| Use This | Avoid | Notes |\n| --- | --- | --- |\n| Pink voices | pink voice | safe |\n"
        self.assertEqual(canonical_terms(dictionary), {"Codex", "Pink voices"})

    def test_evidence_requires_two_distinct_documents(self):
        evidence = build_evidence({"Codex", "LINE OA"}, ["Codex Codex", "Codex and LINE OA", "no terms"], 2)
        self.assertEqual(evidence, [type(evidence[0])("Codex", 2, 3)])

    def test_local_index_never_contains_transcript_text_or_source_paths(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            dictionary = root / "terms.md"
            dictionary.write_text("| Heard | Correct Form | Notes |\n| x | Codex | safe |\n", encoding="utf-8")
            for name, body, recording_id in (("first", "secret sentence Codex", "same"), ("second", "Codex again", "same"), ("third", "Codex again", "unique")):
                transcript = root / "source" / name / "raw-transcript.md"
                transcript.parent.mkdir(parents=True)
                transcript.write_text(body, encoding="utf-8")
                transcript.with_name("source-storage-receipt.json").write_text(json.dumps({"recording": {"id": recording_id}}), encoding="utf-8")
            data = make_index(root / "source", dictionary, 2)
            serialized = json.dumps(data, ensure_ascii=False)
            self.assertNotIn("secret sentence", serialized)
            self.assertNotIn("raw-transcript", serialized)
            self.assertEqual(data["terms"], [{"term": "Codex", "document_count": 2, "occurrence_count": 2}])
            self.assertEqual(data["source"]["documents_duplicates"], 1)
            output = root / "output" / "terms.json"
            write_index(data, output)
            self.assertEqual(load_vocabulary(output)["codex"].document_count, 2)
            self.assertEqual(json.loads(output.read_text())["schema"], SCHEMA)

