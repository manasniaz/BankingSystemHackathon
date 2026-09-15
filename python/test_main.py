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

    def test_health_endpoint(self):
        response = self.client.get("/health")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json(), {"status": "ok"})

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

if __name__ == "__main__":
    unittest.main()
