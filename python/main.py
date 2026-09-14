import os
import sys
import logging
from datetime import datetime, timezone, timedelta
from typing import Optional, Dict, Any

import uvicorn
from fastapi import FastAPI, HTTPException, status
from pydantic import BaseModel, Field
from dotenv import load_dotenv
from supabase import create_client, Client

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s"
)
logger = logging.getLogger("fraud-service")

# Load environment variables from .env if present
load_dotenv()

SUPABASE_URL = os.getenv("SUPABASE_URL")
SUPABASE_SERVICE_ROLE_KEY = os.getenv("SUPABASE_SERVICE_ROLE_KEY")

def get_supabase_client() -> Client:
    """Returns an initialized Supabase client using service role key."""
    if not SUPABASE_URL or not SUPABASE_SERVICE_ROLE_KEY:
        logger.error("SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY environment variables are missing.")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Supabase credentials missing from environment configuration"
        )
    return create_client(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY)


app = FastAPI(
    title="Banking Fraud Scoring Microservice",
    description="Deterministic Python microservice for banking transaction risk scoring",
    version="1.0.0"
)


class AssessFraudRequest(BaseModel):
    account_id: str = Field(..., description="UUID of the source account")
    amount: int = Field(..., gt=0, description="Transaction amount in cents")
    currency: str = Field(default="USD", description="ISO currency code")
    profile_id: Optional[str] = Field(default=None, description="UUID of initiating profile or null")
    transaction_context: Dict[str, Any] = Field(default_factory=dict, description="Additional context dictionary")


class AssessFraudResponse(BaseModel):
    approved: bool = Field(..., description="True if transaction is approved, False otherwise")
    risk_score: float = Field(..., ge=0.0, le=100.0, description="Risk score from 0 to 100")
    reason: str = Field(..., description="Explanation of the fraud assessment result")
    fraud_assessment_id: str = Field(..., description="UUID of the inserted fraud_assessments record")


class HealthResponse(BaseModel):
    status: str = "ok"


@app.get("/health", response_model=HealthResponse)
def health_check():
    """Health check endpoint required for service readiness probes."""
    return {"status": "ok"}


@app.post("/assess-fraud", response_model=AssessFraudResponse)
def assess_fraud(payload: AssessFraudRequest):
    """
    Evaluates deterministic Python fraud rules against Supabase transaction & account state.
    
    Rules evaluated:
    1. Account status rule: Reject immediately if account is frozen or closed.
    2. Velocity rule: > 5 transactions from this account in the last 60 minutes -> High risk (+50 points).
    3. Large amount rule: amount > 500,000 cents ($5,000) -> Elevated risk (+30 points).
    4. New recipient rule: destination account has never received money from this account before -> Minor risk (+15 points).
    
    Score >= 75.0 -> Not approved.
    Writes result to Supabase fraud_assessments table before returning.
    """
    supabase = get_supabase_client()
    
    account_id = payload.account_id
    amount = payload.amount
    context = payload.transaction_context or {}

    flags = []

    # -------------------------------------------------------------------------
    # RULE 1: Account Status Rule
    # -------------------------------------------------------------------------
    try:
        acc_res = supabase.table("accounts").select("id, status, balance").eq("id", account_id).execute()
    except Exception as e:
        logger.error(f"Error querying accounts table for account_id {account_id}: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Database error checking account status: {str(e)}"
        )

    if not acc_res.data:
        # Account not found -> Immediately reject
        return _persist_and_respond(
            supabase=supabase,
            account_id=account_id,
            amount=amount,
            approved=False,
            risk_score=100.0,
            reason="Account not found"
        )

    account_status = acc_res.data[0].get("status", "").lower()
    if account_status in ("frozen", "closed"):
        # Account is frozen or closed -> Immediately reject
        return _persist_and_respond(
            supabase=supabase,
            account_id=account_id,
            amount=amount,
            approved=False,
            risk_score=100.0,
            reason=f"Account status is {account_status}"
        )

    # Check for active full freeze holds in account_holds
    try:
        holds_res = supabase.table("account_holds") \
            .select("id") \
            .eq("account_id", account_id) \
            .eq("status", "active") \
            .eq("is_full_freeze", True) \
            .execute()
        if holds_res.data and len(holds_res.data) > 0:
            return _persist_and_respond(
                supabase=supabase,
                account_id=account_id,
                amount=amount,
                approved=False,
                risk_score=100.0,
                reason="Account has active full freeze hold"
            )
    except Exception as e:
        logger.warning(f"Error checking account_holds for account_id {account_id}: {e}")

    # -------------------------------------------------------------------------
    # RULE 2: Velocity Rule (> 5 transactions in last 60 minutes)
    # -------------------------------------------------------------------------
    now_utc = datetime.now(timezone.utc)
    sixty_mins_ago = (now_utc - timedelta(minutes=60)).isoformat()
    
    velocity_high_risk = False
    try:
        tx_res = supabase.table("transactions") \
            .select("id") \
            .eq("source_account_id", account_id) \
            .gte("created_at", sixty_mins_ago) \
            .execute()
        
        tx_count = len(tx_res.data) if tx_res.data else 0
        if tx_count > 5:
            velocity_high_risk = True
            flags.append(f"High velocity ({tx_count} transactions in last 60m)")
    except Exception as e:
        logger.error(f"Error checking transaction velocity for account_id {account_id}: {e}")

    # -------------------------------------------------------------------------
    # RULE 3: Large Amount Rule (amount > 500,000 cents / $5,000)
    # -------------------------------------------------------------------------
    large_amount_risk = False
    if amount > 500_000:
        large_amount_risk = True
        flags.append(f"Large amount (${amount / 100:,.2f} exceeds $5,000.00 threshold)")

    # -------------------------------------------------------------------------
    # RULE 4: New Recipient Rule
    # -------------------------------------------------------------------------
    destination_account_id = (
        context.get("destination_account_id") or
        context.get("recipient_account_id") or
        context.get("destination_id") or
        context.get("target_account_id")
    )
    
    new_recipient_risk = False
    if destination_account_id:
        try:
            prior_tx_res = supabase.table("transactions") \
                .select("id") \
                .eq("source_account_id", account_id) \
                .eq("destination_account_id", destination_account_id) \
                .eq("status", "completed") \
                .limit(1) \
                .execute()
            
            if not prior_tx_res.data or len(prior_tx_res.data) == 0:
                new_recipient_risk = True
                flags.append("New recipient (no prior completed transfers from this account)")
        except Exception as e:
            logger.error(f"Error checking recipient history for destination {destination_account_id}: {e}")

    # -------------------------------------------------------------------------
    # RISK SCORE CALCULATION (0 - 100)
    # -------------------------------------------------------------------------
    risk_score = 0.0
    if velocity_high_risk:
        risk_score += 50.0
    if large_amount_risk:
        risk_score += 30.0
    if new_recipient_risk:
        risk_score += 15.0

    risk_score = min(100.0, risk_score)
    approved = (risk_score < 75.0)

    if not approved:
        reason = f"High risk (score {risk_score:.1f}): " + "; ".join(flags)
    elif flags:
        reason = f"Elevated risk flags noted (score {risk_score:.1f}): " + "; ".join(flags)
    else:
        reason = "Low risk"

    return _persist_and_respond(
        supabase=supabase,
        account_id=account_id,
        amount=amount,
        approved=approved,
        risk_score=risk_score,
        reason=reason
    )


def _persist_and_respond(
    supabase: Client,
    account_id: str,
    amount: int,
    approved: bool,
    risk_score: float,
    reason: str
) -> AssessFraudResponse:
    """Helper function to insert fraud assessment into Supabase and return response model."""
    expires_at = datetime.now(timezone.utc) + timedelta(minutes=10)
    
    assessment_data = {
        "account_id": account_id,
        "amount": amount,
        "risk_score": round(risk_score, 2),
        "approved": approved,
        "reason": reason,
        "consumed": False,
        "expires_at": expires_at.isoformat()
    }
    
    try:
        insert_res = supabase.table("fraud_assessments").insert(assessment_data).execute()
        if not insert_res.data or len(insert_res.data) == 0:
            raise Exception("No record returned after inserting into fraud_assessments")
        
        fraud_assessment_id = insert_res.data[0]["id"]
        logger.info(
            f"Saved fraud assessment {fraud_assessment_id} for account {account_id}: "
            f"approved={approved}, score={risk_score}, reason='{reason}'"
        )
    except Exception as e:
        logger.error(f"Failed to insert fraud assessment into Supabase: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to persist fraud assessment to database: {str(e)}"
        )

    return AssessFraudResponse(
        approved=approved,
        risk_score=round(risk_score, 2),
        reason=reason,
        fraud_assessment_id=fraud_assessment_id
    )


if __name__ == "__main__":
    port = int(os.getenv("PORT", 8080))
    uvicorn.run("main:app", host="0.0.0.0", port=port, reload=False)
