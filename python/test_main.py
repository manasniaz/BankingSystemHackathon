import os
import unittest
from unittest.mock import MagicMock, patch
from fastapi.testclient import TestClient

# Set dummy env vars before importing main
os.environ["SUPABASE_URL"] = "https://mock.supabase.co"
os.environ["SUPABASE_SERVICE_ROLE_KEY"] = "mock-key"

from main import app

class TestFraudService(unittest.TestCase):
    def setUp(self):
        self.client = TestClient(app)

    @patch("main.create_client")
    @patch("main.SUPABASE_SERVICE_ROLE_KEY", "test-key")
    @patch("main.SUPABASE_URL", "https://example.supabase.co")
    def test_health_reports_ok_when_database_reachable(self, mock_create):
        mock_create.return_value = MagicMock()
        response = self.client.get("/health")
        self.assertEqual(response.status_code, 200)
        body = response.json()
        self.assertEqual(body["status"], "ok")
        self.assertTrue(body["supabase_configured"])
        self.assertEqual(body["database"], "reachable")

    @patch("main.SUPABASE_SERVICE_ROLE_KEY", None)
    @patch("main.SUPABASE_URL", "https://example.supabase.co")
    def test_health_names_the_missing_variable(self):
        # The whole point of the endpoint: an unconfigured deployment must not
        # be able to report itself healthy, and must say which variable is gone.
        response = self.client.get("/health")
        self.assertEqual(response.status_code, 200)
        body = response.json()
        self.assertEqual(body["status"], "degraded")
        self.assertFalse(body["supabase_configured"])
        self.assertEqual(body["database"], "not_configured")
        self.assertIn("SUPABASE_SERVICE_ROLE_KEY", body["detail"])
        self.assertNotIn("SUPABASE_URL", body["detail"])

    @patch("main.create_client")
    @patch("main.SUPABASE_SERVICE_ROLE_KEY", "test-key")
    @patch("main.SUPABASE_URL", "https://example.supabase.co")
    def test_health_reports_unreachable_database(self, mock_create):
        mock_create.side_effect = RuntimeError("connection refused")
        response = self.client.get("/health")
        self.assertEqual(response.status_code, 200)
        body = response.json()
        self.assertEqual(body["status"], "degraded")
        self.assertTrue(body["supabase_configured"])
        self.assertEqual(body["database"], "unreachable")
        self.assertIn("connection refused", body["detail"])

    @patch("main.get_supabase_client")
    def test_assess_fraud_frozen_account(self, mock_get_client):
        mock_supabase = MagicMock()
        mock_get_client.return_value = mock_supabase

        # Mock accounts response: status = frozen
        mock_accounts = MagicMock()
        mock_accounts.execute.return_value.data = [{"id": "acc-123", "status": "frozen", "balance": 100000}]
        mock_supabase.table.return_value.select.return_value.eq.return_value = mock_accounts

        # Mock insert response for fraud_assessments
        mock_insert = MagicMock()
        mock_insert.execute.return_value.data = [{"id": "assessment-uuid-123"}]
        mock_supabase.table.return_value.insert.return_value = mock_insert

        payload = {
            "account_id": "00000000-0000-0000-0000-000000000001",
            "amount": 1000,
            "currency": "PKR",
            "profile_id": None,
            "transaction_context": {}
        }
        response = self.client.post("/assess-fraud", json=payload)
        self.assertEqual(response.status_code, 200)
        res_json = response.json()
        self.assertFalse(res_json["approved"])
        self.assertEqual(res_json["risk_score"], 100.0)
        self.assertIn("frozen", res_json["reason"])
        self.assertEqual(res_json["fraud_assessment_id"], "assessment-uuid-123")

    @patch("main.get_supabase_client")
    def test_assess_fraud_approved_low_risk(self, mock_get_client):
        mock_supabase = MagicMock()
        mock_get_client.return_value = mock_supabase

        # Mock active account
        mock_acc_exec = MagicMock()
        mock_acc_exec.data = [{"id": "acc-123", "status": "active", "balance": 100000}]
        
        # Mock active holds check (none)
        mock_holds_exec = MagicMock()
        mock_holds_exec.data = []

        # Mock transactions velocity (2 tx < 5)
        mock_tx_exec = MagicMock()
        mock_tx_exec.data = [{"id": "tx1"}, {"id": "tx2"}]

        # Setup table calls chaining
        def table_side_effect(name):
            t_mock = MagicMock()
            if name == "accounts":
                t_mock.select.return_value.eq.return_value.execute.return_value = mock_acc_exec
            elif name == "account_holds":
                t_mock.select.return_value.eq.return_value.eq.return_value.eq.return_value.execute.return_value = mock_holds_exec
            elif name == "transactions":
                t_mock.select.return_value.eq.return_value.gte.return_value.execute.return_value = mock_tx_exec
            elif name == "fraud_assessments":
                insert_mock = MagicMock()
                insert_mock.execute.return_value.data = [{"id": "assessment-uuid-456"}]
                t_mock.insert.return_value = insert_mock
            return t_mock

        mock_supabase.table.side_effect = table_side_effect

        payload = {
            "account_id": "00000000-0000-0000-0000-000000000001",
            "amount": 10000, # Rs 100.00
            "currency": "PKR",
            "profile_id": None,
            "transaction_context": {}
        }
        response = self.client.post("/assess-fraud", json=payload)
        self.assertEqual(response.status_code, 200)
        res_json = response.json()
        self.assertTrue(res_json["approved"])
        self.assertEqual(res_json["risk_score"], 0.0)
        self.assertEqual(res_json["reason"], "Low risk")
        self.assertEqual(res_json["fraud_assessment_id"], "assessment-uuid-456")

    @patch("main.get_supabase_client")
    def test_assess_fraud_high_risk_rejection(self, mock_get_client):
        mock_supabase = MagicMock()
        mock_get_client.return_value = mock_supabase

        mock_acc_exec = MagicMock()
        mock_acc_exec.data = [{"id": "acc-123", "status": "active", "balance": 10000000}]

        mock_holds_exec = MagicMock()
        mock_holds_exec.data = []

        # Mock velocity > 5 tx (6 tx)
        mock_tx_exec = MagicMock()
        mock_tx_exec.data = [{"id": f"tx{i}"} for i in range(6)]

        # Mock prior transfers to new recipient (0 tx)
        mock_prior_exec = MagicMock()
        mock_prior_exec.data = []

        def table_side_effect(name):
            t_mock = MagicMock()
            if name == "accounts":
                t_mock.select.return_value.eq.return_value.execute.return_value = mock_acc_exec
            elif name == "account_holds":
                t_mock.select.return_value.eq.return_value.eq.return_value.eq.return_value.execute.return_value = mock_holds_exec
            elif name == "transactions":
                # Returns mock_tx_exec or mock_prior_exec
                select_mock = MagicMock()
                eq1 = MagicMock()
                select_mock.eq.return_value = eq1
                eq1.gte.return_value.execute.return_value = mock_tx_exec
                eq1.eq.return_value.eq.return_value.limit.return_value.execute.return_value = mock_prior_exec
                t_mock.select.return_value = select_mock
            elif name == "fraud_assessments":
                insert_mock = MagicMock()
                insert_mock.execute.return_value.data = [{"id": "assessment-uuid-789"}]
                t_mock.insert.return_value = insert_mock
            return t_mock

        mock_supabase.table.side_effect = table_side_effect

        payload = {
            "account_id": "00000000-0000-0000-0000-000000000001",
            "amount": 60000000, # Rs 600,000 > Rs 500,000 threshold (+30 pts). Velocity > 5 (+50 pts) -> score 80 >= 75
            "currency": "PKR",
            "profile_id": None,
            "transaction_context": {"destination_account_id": "00000000-0000-0000-0000-000000000002"}
        }
        response = self.client.post("/assess-fraud", json=payload)
        self.assertEqual(response.status_code, 200)
        res_json = response.json()
        self.assertFalse(res_json["approved"])
        self.assertGreaterEqual(res_json["risk_score"], 75.0)
        self.assertIn("High risk", res_json["reason"])
        self.assertEqual(res_json["fraud_assessment_id"], "assessment-uuid-789")

    # =========================================================================
    # Failing closed on a rule that could not be evaluated.
    #
    # These are regression tests for a real fail-open defect: the velocity,
    # recipient-history and account-holds queries each sat in a try/except that
    # logged and continued, so a database error silently removed that rule's
    # points and the service returned 200 with a LOWER score and approved=true.
    # Velocity 50 + large amount 30 = 80 and is blocked; with the velocity query
    # erroring, the identical transfer scored 30 and was approved.
    #
    # The expected behaviour is 503, not a score of 100: WF-03 freezes an account
    # at 75 or above and only a human can lift that, so scoring 100 would turn a
    # momentary database error into a lockout for a customer who did nothing.
    # =========================================================================

    def _client_with_failing(self, failing_table, tx_count=9, amount_large=True):
        """A Supabase mock where exactly one table's query raises."""
        mock_supabase = MagicMock()

        def table_side_effect(name):
            t_mock = MagicMock()
            if name == "accounts":
                exec_mock = MagicMock()
                exec_mock.data = [{"id": "acc-123", "status": "active", "balance": 10 ** 9}]
                t_mock.select.return_value.eq.return_value.execute.return_value = exec_mock
            elif name == "account_holds":
                if failing_table == "account_holds":
                    t_mock.select.return_value.eq.return_value.eq.return_value.eq.return_value.execute.side_effect = RuntimeError("connection reset")
                else:
                    exec_mock = MagicMock()
                    exec_mock.data = []
                    t_mock.select.return_value.eq.return_value.eq.return_value.eq.return_value.execute.return_value = exec_mock
            elif name == "transactions":
                if failing_table == "transactions_velocity":
                    t_mock.select.return_value.eq.return_value.gte.return_value.execute.side_effect = RuntimeError("statement timeout")
                else:
                    exec_mock = MagicMock()
                    exec_mock.data = [{"id": f"tx{i}"} for i in range(tx_count)]
                    t_mock.select.return_value.eq.return_value.gte.return_value.execute.return_value = exec_mock
                if failing_table == "transactions_recipient":
                    t_mock.select.return_value.eq.return_value.eq.return_value.eq.return_value.limit.return_value.execute.side_effect = RuntimeError("deadlock detected")
                else:
                    rec_mock = MagicMock()
                    rec_mock.data = []
                    t_mock.select.return_value.eq.return_value.eq.return_value.eq.return_value.limit.return_value.execute.return_value = rec_mock
            elif name == "fraud_assessments":
                insert_mock = MagicMock()
                insert_mock.execute.return_value.data = [{"id": "assessment-should-not-exist"}]
                t_mock.insert.return_value = insert_mock
            return t_mock

        mock_supabase.table.side_effect = table_side_effect
        return mock_supabase

    def _payload(self):
        return {
            "account_id": "00000000-0000-0000-0000-000000000001",
            "amount": 60_000_000,  # Rs 600,000: over the large-amount threshold
            "currency": "PKR",
            "profile_id": None,
            "transaction_context": {"destination_account_id": "00000000-0000-0000-0000-000000000002"},
        }

    @patch("main.get_supabase_client")
    def test_velocity_query_failure_fails_closed(self, mock_get_client):
        mock_get_client.return_value = self._client_with_failing("transactions_velocity")
        response = self.client.post("/assess-fraud", json=self._payload())
        # Before the fix this was 200 / approved=true / score 30.
        self.assertEqual(response.status_code, 503)
        self.assertIn("transaction velocity", response.json()["detail"])
        self.assertNotIn("approved", response.json())

    @patch("main.get_supabase_client")
    def test_recipient_history_failure_fails_closed(self, mock_get_client):
        mock_get_client.return_value = self._client_with_failing("transactions_recipient")
        response = self.client.post("/assess-fraud", json=self._payload())
        self.assertEqual(response.status_code, 503)
        self.assertIn("recipient history", response.json()["detail"])

    @patch("main.get_supabase_client")
    def test_account_holds_failure_fails_closed(self, mock_get_client):
        # A missed full freeze is the most serious miss this service can make,
        # so it is fatal even though the status check above is redundant with it.
        mock_get_client.return_value = self._client_with_failing("account_holds")
        response = self.client.post("/assess-fraud", json=self._payload())
        self.assertEqual(response.status_code, 503)
        self.assertIn("account freeze holds", response.json()["detail"])

    @patch("main.get_supabase_client")
    def test_failure_response_carries_no_assessment_id(self, mock_get_client):
        # n8n's fraud gate requires approved == true AND fraud_assessment_id to
        # exist. A failure must supply neither, or the gate would let it through.
        mock_get_client.return_value = self._client_with_failing("transactions_velocity")
        body = self.client.post("/assess-fraud", json=self._payload()).json()
        self.assertNotIn("fraud_assessment_id", body)
        self.assertNotIn("risk_score", body)

    @patch("main.get_supabase_client")
    def test_all_rules_evaluable_still_scores_normally(self, mock_get_client):
        # The guard must not have made the happy path unavailable: 9 transactions
        # in the window (50) plus Rs 600,000 (30) is 80, which is blocked on merit.
        mock_get_client.return_value = self._client_with_failing(None, tx_count=9)
        response = self.client.post("/assess-fraud", json=self._payload())
        self.assertEqual(response.status_code, 200)
        body = response.json()
        self.assertFalse(body["approved"])
        self.assertEqual(body["risk_score"], 95.0)


class TestInterestStatementsReconciliation(unittest.TestCase):
    """Covers the interest / statements / reconciliation half of the Python
    service, which the capstone brief lists alongside fraud scoring."""

    def setUp(self):
        self.client = TestClient(app)

    # ---------------------------------------------------------------- money
    def test_rs_formatting_is_exact_at_paisa_precision(self):
        from main import _rs
        self.assertEqual(_rs(0), "Rs 0.00")
        self.assertEqual(_rs(1), "Rs 0.01")
        self.assertEqual(_rs(99), "Rs 0.99")
        self.assertEqual(_rs(100), "Rs 1.00")
        self.assertEqual(_rs(123456789), "Rs 1,234,567.89")
        self.assertEqual(_rs(-12345), "-Rs 123.45")
        self.assertEqual(_rs(None), "Rs 0.00")

    # ------------------------------------------------------------- interest
    def test_interest_projection_reconciles(self):
        r = self.client.post("/project-interest",
                             json={"balance": 10000000, "annual_rate_pct": 5.0, "months": 12})
        self.assertEqual(r.status_code, 200)
        d = r.json()
        # The schedule must account for every paisa: opening + interest == closing.
        self.assertEqual(d["closing_balance"] - d["opening_balance"], d["total_interest"])
        self.assertEqual(len(d["schedule"]), 12)
        self.assertEqual(d["schedule"][-1]["closing_balance"], d["closing_balance"])

    def test_interest_projection_zero_rate_pays_nothing(self):
        r = self.client.post("/project-interest",
                             json={"balance": 5000000, "annual_rate_pct": 0.0, "months": 6})
        d = r.json()
        self.assertEqual(d["total_interest"], 0)
        self.assertEqual(d["closing_balance"], d["opening_balance"])

    def test_interest_projection_rounds_down_never_up(self):
        # A balance small enough that one month of interest is a fraction of a
        # paisa must pay nothing, not round up into money that does not exist.
        r = self.client.post("/project-interest",
                             json={"balance": 100, "annual_rate_pct": 5.0, "months": 1})
        self.assertEqual(r.json()["total_interest"], 0)

    def test_interest_projection_rejects_bad_input(self):
        self.assertEqual(self.client.post("/project-interest",
                         json={"balance": -1, "annual_rate_pct": 5.0}).status_code, 422)
        self.assertEqual(self.client.post("/project-interest",
                         json={"balance": 100, "annual_rate_pct": 5.0, "months": 0}).status_code, 422)

    @patch("main.get_supabase_client")
    def test_accrue_interest_delegates_to_rpc(self, mock_get_client):
        mock_supabase = MagicMock()
        mock_get_client.return_value = mock_supabase
        mock_supabase.rpc.return_value.execute.return_value.data = {
            "success": True, "accounts_paid": 2, "total_interest": 4321,
            "period_start": "2026-08-01", "period_end": "2026-08-31"
        }
        r = self.client.post("/accrue-interest", json={})
        self.assertEqual(r.status_code, 200)
        d = r.json()
        self.assertTrue(d["success"])
        self.assertEqual(d["total_interest_formatted"], "Rs 43.21")
        mock_supabase.rpc.assert_called_once()
        self.assertEqual(mock_supabase.rpc.call_args[0][0], "accrue_monthly_interest")

    # ------------------------------------------------------------ statement
    @patch("main.get_supabase_client")
    def test_statement_renders_and_balances(self, mock_get_client):
        mock_supabase = MagicMock()
        mock_get_client.return_value = mock_supabase
        mock_supabase.rpc.return_value.execute.return_value.data = {
            "success": True, "account_number": "ACC-TEST01", "account_type": "savings",
            "currency": "PKR", "period_start": "2026-08-01", "period_end": "2026-08-31",
            "opening_balance": 100000, "total_credits": 50000, "total_debits": 20000,
            "closing_balance": 130000, "entry_count": 2, "current_balance": 130000,
            "outstanding_debt": 0, "holder_emails": ["a@b.c"],
            "entries": [
                {"posted_at": "2026-08-02T10:00:00+00:00", "entry_type": "CREDIT",
                 "amount": 50000, "balance_after": 150000, "description": "Deposit",
                 "counterparty": "TREASURY-MAIN", "status": "completed"},
                {"posted_at": "2026-08-09T10:00:00+00:00", "entry_type": "DEBIT",
                 "amount": 20000, "balance_after": 130000, "description": "Transfer out",
                 "counterparty": "ACC-OTHER", "status": "completed"},
            ],
        }
        r = self.client.post("/generate-statement", json={"account_id": "acc-1"})
        self.assertEqual(r.status_code, 200)
        d = r.json()
        self.assertTrue(d["balanced"], "opening + credits - debits must equal closing")
        self.assertIn("ACC-TEST01", d["statement_text"])
        self.assertIn("Rs 1,300.00", d["statement_text"])
        self.assertIn("OUT", d["statement_text"])

    @patch("main.get_supabase_client")
    def test_statement_flags_when_it_does_not_balance(self, mock_get_client):
        mock_supabase = MagicMock()
        mock_get_client.return_value = mock_supabase
        # Closing deliberately inconsistent with opening + credits - debits.
        mock_supabase.rpc.return_value.execute.return_value.data = {
            "success": True, "account_number": "ACC-BAD", "account_type": "checking",
            "currency": "PKR", "period_start": "2026-08-01", "period_end": "2026-08-31",
            "opening_balance": 100000, "total_credits": 50000, "total_debits": 20000,
            "closing_balance": 999999, "entry_count": 0, "current_balance": 999999,
            "outstanding_debt": 0, "holder_emails": [], "entries": [],
        }
        d = self.client.post("/generate-statement", json={"account_id": "acc-1"}).json()
        self.assertFalse(d["balanced"], "a statement that does not add up must be flagged")

    @patch("main.get_supabase_client")
    def test_statement_rejects_unknown_account(self, mock_get_client):
        mock_supabase = MagicMock()
        mock_get_client.return_value = mock_supabase
        mock_supabase.rpc.return_value.execute.return_value.data = {
            "success": False, "error": "Account not found."
        }
        r = self.client.post("/generate-statement", json={"account_id": "nope"})
        self.assertEqual(r.status_code, 400)

    # -------------------------------------------------------- reconciliation
    @patch("main.get_supabase_client")
    def test_reconcile_passes_when_balanced(self, mock_get_client):
        mock_supabase = MagicMock()
        mock_get_client.return_value = mock_supabase
        mock_supabase.rpc.return_value.execute.return_value.data = {
            "passed": True, "total_debits": 500, "total_credits": 500, "discrepancies": []
        }
        d = self.client.post("/reconcile", json={"sweep_debts": False}).json()
        self.assertTrue(d["passed"])
        self.assertFalse(d["requires_human_attention"])
        self.assertEqual(d["system_drift"], 0)

    @patch("main.get_supabase_client")
    def test_reconcile_flags_drift_for_a_human(self, mock_get_client):
        mock_supabase = MagicMock()
        mock_get_client.return_value = mock_supabase
        # Debits and credits disagree: this must never be reported as a pass,
        # even though the RPC itself said passed=true.
        mock_supabase.rpc.return_value.execute.return_value.data = {
            "passed": True, "total_debits": 500, "total_credits": 400,
            "discrepancies": [{"account": "ACC-X"}]
        }
        d = self.client.post("/reconcile", json={"sweep_debts": False}).json()
        self.assertFalse(d["passed"])
        self.assertTrue(d["requires_human_attention"])
        self.assertEqual(d["system_drift"], 100)
        self.assertEqual(d["discrepancy_count"], 1)



if __name__ == "__main__":
    unittest.main()
