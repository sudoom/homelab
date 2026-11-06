"""Offline tests for bin/paperless-costs; fixtures follow the paperless-ngx v3.4.2 API shapes.

Shapes (src/documents/serialisers.py, v3.4.2): tag `parent` (id or null); document
`tags` = list of ids (ancestors included), `custom_fields` = [{"field": id, "value": ...}],
`created` = "YYYY-MM-DD"; Monetary value = "PLN123.45" (legacy bare "123.45");
default currency in /api/custom_fields/ `extra_data.default_currency`; paging `next` = full URL or null.
"""
import io
import json
import os
import unittest
import urllib.error
import urllib.request
from decimal import Decimal
from importlib import machinery, util

HERE = os.path.dirname(os.path.abspath(__file__))
_loader = machinery.SourceFileLoader("paperless_costs", os.path.join(HERE, "paperless-costs"))
_spec = util.spec_from_loader("paperless_costs", _loader)
pc = util.module_from_spec(_spec)
_loader.exec_module(pc)

AMOUNT = 7
PERIOD = 8
CATS = {10, 11}  # 10 electricity, 11 water; 9 is the parent "Category"
SCOPES = {20, 21}  # 20 JDG, 21 Home; 19 is the parent "Scope"
JDG, HOME = 20, 21


ISSUED = 5  # document type "Invoice (issued)"


def doc(i, created, tags, value, title="d", doc_type=None, period=None):
    cfs = [{"field": AMOUNT, "value": value}, {"field": 99, "value": "x"}]
    if period is not None:
        cfs.append({"field": PERIOD, "value": period})
    return {"id": i, "title": f"{title}{i}", "created": created, "tags": tags, "document_type": doc_type,
            "custom_fields": cfs}


class FakeResp(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


class Tests(unittest.TestCase):
    def test_parse_monetary(self):
        self.assertEqual(pc.parse_monetary("PLN245.30", "PLN"), ("PLN", Decimal("245.30")))
        self.assertEqual(pc.parse_monetary("245.30", "PLN"), ("PLN", Decimal("245.30")))
        self.assertEqual(pc.parse_monetary("EUR12.00", "PLN"), ("EUR", Decimal("12.00")))
        self.assertEqual(pc.parse_monetary("PLN-12.50", "PLN"), ("PLN", Decimal("-12.50")))
        self.assertIsNone(pc.parse_monetary(None, "PLN"))
        self.assertIsNone(pc.parse_monetary("", "PLN"))
        with self.assertRaises(ValueError):
            pc.parse_monetary("abc", "PLN")

    def test_category_one_zero_two(self):
        self.assertEqual(pc.category_of([9, 10, 3], CATS), 10)  # parent 9 is not a category
        self.assertIsNone(pc.category_of([9, 3], CATS))
        self.assertIsNone(pc.category_of([9, 10, 11], CATS))

    def test_aggregate_month_from_created(self):
        docs = [doc(1, "2024-11-30", [9, 10], "PLN10.00"), doc(2, "2024-12-01", [9, 10], "PLN5.00")]
        totals, excluded = pc.aggregate(docs, AMOUNT, CATS, "PLN")
        self.assertEqual(totals[("PLN", None)]["2024-11"][10], Decimal("10.00"))
        self.assertEqual(totals[("PLN", None)]["2024-12"][10], Decimal("5.00"))
        self.assertEqual(excluded, [])

    def test_aggregate_excludes_and_lists(self):
        docs = [doc(1, "2024-11-05", [9, 10], "PLN10.00"),
                doc(2, "2024-11-05", [3], "PLN99.00"),
                doc(3, "2024-11-05", [9, 10, 11], "PLN77.00"),
                doc(4, "2024-11-05", [9, 10], "")]
        totals, excluded = pc.aggregate(docs, AMOUNT, CATS, "PLN")
        self.assertEqual(totals, {("PLN", None): {"2024-11": {10: Decimal("10.00")}}})
        self.assertEqual([e["id"] for e in excluded], [2, 3, 4])
        self.assertIn("category", excluded[0]["reason"])

    def test_aggregate_skips_issued_invoices(self):
        # Issued invoices carry an Amount (gross, any currency) and no category; they are income,
        # so they are neither counted nor listed as excluded, even if a category tag slips on.
        docs = [doc(1, "2024-11-05", [9, 10], "PLN10.00"),
                doc(2, "2024-11-05", [], "EUR500.00", doc_type=ISSUED),
                doc(3, "2024-11-05", [9, 10], "PLN900.00", doc_type=ISSUED),
                doc(4, "2024-11-05", [3], "PLN99.00", doc_type=2)]
        totals, excluded = pc.aggregate(docs, AMOUNT, CATS, "PLN", skip_type_ids={ISSUED})
        self.assertEqual(totals, {("PLN", None): {"2024-11": {10: Decimal("10.00")}}})
        self.assertEqual([e["id"] for e in excluded], [4])

    def test_type_ids_named(self):
        types = [{"id": 2, "name": "Invoice (received)"}, {"id": ISSUED, "name": "Invoice (issued)"},
                 {"id": 8, "name": "invoice (ISSUED) "}]
        self.assertEqual(pc.type_ids_named(types, pc.ISSUED_TYPE), {ISSUED, 8})
        self.assertEqual(pc.type_ids_named([], pc.ISSUED_TYPE), set())

    def test_currencies_not_mixed(self):
        docs = [doc(1, "2024-11-05", [9, 10], "PLN10.00"), doc(2, "2024-11-06", [9, 10], "EUR3.00"),
                doc(3, "2024-11-07", [9, 10], "4.00")]
        totals, _ = pc.aggregate(docs, AMOUNT, CATS, "PLN")
        self.assertEqual(totals[("PLN", None)]["2024-11"][10], Decimal("14.00"))
        self.assertEqual(totals[("EUR", None)]["2024-11"][10], Decimal("3.00"))
        out = pc.render(totals, {10: "electricity"})
        self.assertLess(out.index("== PLN =="), out.index("== EUR =="))

    def test_month_from_period_else_created(self):
        # Period (the month a document belongs to) wins over created; without it, created.
        docs = [doc(1, "2024-11-03", [9, 10], "PLN10.00", period="2024-10-01"),
                doc(2, "2024-11-04", [9, 10], "PLN5.00", period=None),
                doc(3, "2024-11-05", [9, 10], "PLN7.00", period="")]
        totals, excluded = pc.aggregate(docs, AMOUNT, CATS, "PLN", period_field_id=PERIOD)
        self.assertEqual(totals[("PLN", None)]["2024-10"][10], Decimal("10.00"))
        self.assertEqual(totals[("PLN", None)]["2024-11"][10], Decimal("12.00"))
        self.assertEqual(excluded, [])

    def test_bad_period_excluded(self):
        docs = [doc(1, "2024-11-03", [9, 10], "PLN10.00", period="Oct 2024")]
        totals, excluded = pc.aggregate(docs, AMOUNT, CATS, "PLN", period_field_id=PERIOD)
        self.assertEqual(totals, {})
        self.assertEqual([e["id"] for e in excluded], [1])
        self.assertIn("Period", excluded[0]["reason"])

    def test_range_uses_the_effective_month(self):
        # In range by created but Period outside: skipped silently; the reverse: counted.
        docs = [doc(1, "2024-11-03", [9, 10], "PLN10.00", period="2024-09-01"),
                doc(2, "2024-12-02", [9, 10], "PLN5.00", period="2024-11-01"),
                doc(3, "2024-12-02", [3], "PLN99.00")]  # out of range: not even listed as excluded
        totals, excluded = pc.aggregate(docs, AMOUNT, CATS, "PLN", period_field_id=PERIOD,
                                        start="2024-10", end="2024-11")
        self.assertEqual(totals, {("PLN", None): {"2024-11": {10: Decimal("5.00")}}})
        self.assertEqual(excluded, [])

    def test_scope_split_and_exclusions(self):
        docs = [doc(1, "2024-11-03", [9, 10, 19, JDG], "PLN10.00"),
                doc(2, "2024-11-03", [9, 10, 19, HOME], "PLN20.00"),
                doc(3, "2024-11-03", [9, 10], "PLN30.00"),
                doc(4, "2024-11-03", [9, 10, 19, JDG, HOME], "PLN40.00")]
        totals, excluded = pc.aggregate(docs, AMOUNT, CATS, "PLN", scope_ids=SCOPES)
        self.assertEqual(totals, {("PLN", JDG): {"2024-11": {10: Decimal("10.00")}},
                                  ("PLN", HOME): {"2024-11": {10: Decimal("20.00")}}})
        self.assertEqual([e["id"] for e in excluded], [3, 4])
        self.assertIn("scope", excluded[0]["reason"])
        out = pc.render(totals, {10: "electricity", JDG: "JDG", HOME: "Home"})
        self.assertLess(out.index("== PLN · Home =="), out.index("== PLN · JDG =="))

    def test_paging_follows_next(self):
        base = "http://pl.test"
        pages = {
            f"{base}/api/documents/?page=1": {"next": f"{base}/api/documents/?page=2", "results": [{"id": 1}, {"id": 2}]},
            f"{base}/api/documents/?page=2": {"next": f"{base}/api/documents/?page=3", "results": [{"id": 3}, {"id": 4}]},
            f"{base}/api/documents/?page=3": {"next": None, "results": [{"id": 5}]},
        }
        seen = []

        def opener(req, timeout=None):
            seen.append(req.full_url)
            self.assertEqual(req.get_header("Authorization"), "Token T")
            return FakeResp(json.dumps(pages[req.full_url]).encode())

        res = pc.fetch_all(f"{base}/api/documents/?page=1", "T", opener)
        self.assertEqual([d["id"] for d in res], [1, 2, 3, 4, 5])
        self.assertEqual(len(seen), 3)

    def test_http_error_exits_without_token(self):
        def opener(req, timeout=None):
            raise urllib.error.HTTPError(req.full_url, 403, "no", {}, None)
        with self.assertRaises(SystemExit) as cm:
            pc.fetch_all("http://pl.test/api/x/", "SECRET", opener)
        self.assertIn("403", str(cm.exception))
        self.assertNotIn("SECRET", str(cm.exception))

    def test_next_to_other_host_refused(self):
        def opener(req, timeout=None):
            return FakeResp(json.dumps({"next": "http://evil.test/x", "results": []}).encode())
        with self.assertRaises(SystemExit):
            pc.fetch_all("http://pl.test/a", "T", opener)

    def test_redirect_refused_without_second_request(self):
        calls = []

        def opener(req, timeout=None):
            calls.append(req.full_url)
            raise urllib.error.HTTPError(req.full_url, 302, "Found",
                                         {"Location": "http://evil.test/x"}, None)
        with self.assertRaises(SystemExit) as cm:
            pc.fetch_all("http://pl.test/api/x/", "SECRET", opener)
        self.assertEqual(len(calls), 1)
        msg = str(cm.exception)
        self.assertIn("302", msg)
        self.assertIn("http://evil.test/x", msg)
        self.assertNotIn("SECRET", msg)

    def test_redirect_handler_refuses(self):
        import urllib.request
        req = urllib.request.Request("http://pl.test/a", headers={"Authorization": "Token SECRET"})
        with self.assertRaises(SystemExit) as cm:
            pc.NoRedirect().redirect_request(req, None, 302, "Found", {}, "http://evil.test/x")
        self.assertIn("evil.test", str(cm.exception))
        self.assertNotIn("SECRET", str(cm.exception))

    def test_default_opener_installs_noredirect(self):
        # The opener main() and fetch_all() use by default must carry NoRedirect
        # in place of urllib's stock HTTPRedirectHandler, or the test above proves nothing.
        handlers = pc._default_opener.__self__.handlers
        self.assertTrue(any(isinstance(h, pc.NoRedirect) for h in handlers))
        self.assertFalse(any(type(h) is urllib.request.HTTPRedirectHandler for h in handlers))
        self.assertIs(pc.main.__defaults__[-1], pc._default_opener)
        self.assertIs(pc.fetch_all.__defaults__[-1], pc._default_opener)

    def test_timeout_exits_cleanly(self):
        def opener(req, timeout=None):
            raise TimeoutError("timed out")
        with self.assertRaises(SystemExit) as cm:
            pc.fetch_all("http://pl.test/api/x/", "SECRET", opener)
        self.assertIn("timeout", str(cm.exception))
        self.assertIn("http://pl.test/api/x/", str(cm.exception))

    def test_non_json_body_exits_cleanly(self):
        def opener(req, timeout=None):
            return FakeResp(b"<html>login</html>")
        with self.assertRaises(SystemExit) as cm:
            pc.fetch_all("http://pl.test/api/x/", "SECRET", opener)
        self.assertIn("not valid JSON", str(cm.exception))
        self.assertIn("http://pl.test/api/x/", str(cm.exception))


if __name__ == "__main__":
    unittest.main()
