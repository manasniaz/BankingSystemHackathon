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
    amount: int = Field(..., gt=0, description="Transaction amount in paisa (1 PKR = 100 paisa)")
    currency: str = Field(default="PKR", description="ISO currency code")
    profile_id: Optional[str] = Field(default=None, description="UUID of initiating profile or null")
    transaction_context: Dict[str, Any] = Field(default_factory=dict, description="Additional context dictionary")


class AssessFraudResponse(BaseModel):
    approved: bool = Field(..., description="True if transaction is approved, False otherwise")
    risk_score: float = Field(..., ge=0.0, le=100.0, description="Risk score from 0 to 100")
    reason: str = Field(..., description="Explanation of the fraud assessment result")
    fraud_assessment_id: str = Field(..., description="UUID of the inserted fraud_assessments record")


class HealthResponse(BaseModel):
    status: str = Field(..., description="ok when the service can actually score, degraded otherwise")
    supabase_configured: bool = Field(..., description="Both Supabase environment variables are set")
    database: str = Field(..., description="reachable | unreachable | not_configured")
    detail: Optional[str] = Field(default=None, description="What is wrong, when something is")


@app.get("/health", response_model=HealthResponse)
def health_check():
    """Readiness, not just liveness.

    A bare {"status": "ok"} was actively misleading. The process answers it
    perfectly well while missing the credentials it needs to score anything, so
    a misconfigured deployment looked healthy and the only symptom was every
    transfer being stopped by the fail-safe -- which looks like fraud detection
    working, not like a broken deployment.

    Deliberately still HTTP 200 when degraded: Railway restarts a container
    whose health check fails, and restarting does not supply a missing
    environment variable. It would turn a diagnosable problem into a crash loop.
    Read the body, not the status code.
    """
    missing = [name for name, value in (
        ("SUPABASE_URL", SUPABASE_URL),
        ("SUPABASE_SERVICE_ROLE_KEY", SUPABASE_SERVICE_ROLE_KEY),
    ) if not value]

    if missing:
        return HealthResponse(
            status="degraded",
            supabase_configured=False,
            database="not_configured",
            detail=("Missing environment variable(s): " + ", ".join(missing) +
                    ". Fraud scoring cannot run: every assessment fails safe, "
                    "scores 100, and blocks the transfer."),
        )

    try:
        create_client(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY) \
            .table("interest_rates").select("account_type").limit(1).execute()
    except Exception as exc:
        return HealthResponse(
            status="degraded",
            supabase_configured=True,
            database="unreachable",
            detail=str(exc)[:300],
        )

    return HealthResponse(status="ok", supabase_configured=True, database="reachable")


@app.post("/assess-fraud", response_model=AssessFraudResponse)
def assess_fraud(payload: AssessFraudRequest):
    """
    Evaluates deterministic Python fraud rules against Supabase transaction & account state.
    
    Rules evaluated:
    1. Account status rule: Reject immediately if account is frozen or closed.
    2. Velocity rule: > 5 transactions from this account in the last 60 minutes -> High risk (+50 points).
    3. Large amount rule: amount > 50,000,000 paisa (Rs 500,000) -> Elevated risk (+30 points).
    4. New recipient rule: destination account has never received money from this account before -> Minor risk (+15 points).
    
    Score >= 75.0 -> Not approved.
    Writes result to Supabase fraud_assessments table before returning.

    Fails closed. If any rule's query fails, no score is produced and the
    response is 503: an unevaluated rule is not a passed rule. Only rule 1's
    account lookup is fatal on its own, because without it there is nothing to
    assess at all.
    """
    supabase = get_supabase_client()
    
    account_id = payload.account_id
    amount = payload.amount
    context = payload.transaction_context or {}

    flags = []

    # A rule that could not be evaluated is not a rule that passed. Each rule
    # below records its own name here if its query fails; nothing is scored or
    # approved while this list is non-empty. See the failure note before the
    # score calculation for why this raises rather than scoring 100.
    unevaluated = []

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
        # Redundant with the status check above today, because place_account_hold()
        # also sets accounts.status = 'frozen'. Treated as fatal anyway: a missed
        # full freeze is the most serious thing this service can get wrong, and
        # "redundant today" is precisely the assumption that breaks quietly later.
        logger.error(f"Error checking account_holds for account_id {account_id}: {e}")
        unevaluated.append("account freeze holds")

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
        unevaluated.append("transaction velocity")

    # -------------------------------------------------------------------------
    # RULE 3: Large Amount Rule (amount > 50,000,000 paisa / Rs 500,000)
    # -------------------------------------------------------------------------
    large_amount_risk = False
    if amount > 50_000_000:
        large_amount_risk = True
        flags.append(f"Large amount (Rs {amount / 100:,.2f} exceeds Rs 500,000.00 threshold)")

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
            unevaluated.append("recipient history")

    # -------------------------------------------------------------------------
    # FAIL CLOSED: refuse to score at all if any rule could not be evaluated.
    #
    # Every rule is attempted first, so the error names all of them rather than
    # only the first to fail -- which is the difference between a diagnosable
    # incident and a guess.
    #
    # 503 rather than a score of 100. A 100 would block this transfer AND, via
    # WF-03's freeze-at-75, lock the customer out of their account until a human
    # intervened -- turning a momentary database error into a support incident
    # for someone who did nothing wrong. A 503 has no `approved` field and no
    # `fraud_assessment_id`, which is exactly what n8n's fraud gate requires, so
    # the transfer is held, nothing is frozen, and a retry can succeed.
    # -------------------------------------------------------------------------
    if unevaluated:
        detail = ("Fraud assessment incomplete: could not evaluate " +
                  ", ".join(unevaluated) +
                  ". No score was produced and the transfer must not proceed.")
        logger.error(f"Failing closed for account {account_id}: {detail}")
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=detail,
        )

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


# =============================================================================
# Interest, statements and reconciliation
#
# Division of labour, consistent with the zero-trust rule the rest of the system
# follows: Postgres owns every movement of money, because that is where the
# ledger and its constraints live and where atomicity is real. Python owns the
# computation and presentation around it -- projecting interest that has not been
# paid yet, rendering a statement a human can read, and analysing reconciliation
# output for drift. Python never writes a balance directly.
# =============================================================================

PAISA_PER_RUPEE = 100


def _rs(paisa: Optional[int]) -> str:
    """Format integer paisa as a PKR amount. Money is never floated around."""
    value = int(paisa or 0)
    sign = "-" if value < 0 else ""
    value = abs(value)
    return f"{sign}Rs {value // PAISA_PER_RUPEE:,}.{value % PAISA_PER_RUPEE:02d}"


def _call_rpc(supabase: Client, name: str, params: Dict[str, Any]) -> Any:
    try:
        return supabase.rpc(name, params).execute().data
    except Exception as e:
        logger.error(f"RPC {name} failed: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Database call {name} failed: {str(e)}"
        )


class AccrueInterestRequest(BaseModel):
    as_of: Optional[str] = Field(default=None, description="YYYY-MM-DD; defaults to today")
    dry_run: bool = Field(default=False, description="Project the interest without paying it")


class ProjectInterestRequest(BaseModel):
    balance: int = Field(..., ge=0, description="Balance in paisa")
    annual_rate_pct: float = Field(default=5.0, ge=0, description="Annual rate, percent")
    months: int = Field(default=12, gt=0, le=600, description="Months to project")


@app.post("/accrue-interest")
def accrue_interest(payload: AccrueInterestRequest):
    """
    Runs the monthly interest accrual for the last fully elapsed month.

    Safe to call repeatedly: the accrual is keyed on (account_id, period_start)
    with a unique constraint, so a second run for the same month pays nothing
    and reports the accounts it skipped.
    """
    supabase = get_supabase_client()

    if payload.dry_run:
        # Project what WOULD be paid, touching nothing. Same floor-rounding rule
        # as the database so the projection matches the eventual payment exactly.
        try:
            rates = {r["account_type"]: float(r["annual_rate_pct"])
                     for r in supabase.table("interest_rates").select("*").execute().data or []}
            accounts = supabase.table("accounts") \
                .select("id, account_number, account_type, balance, status") \
                .eq("status", "active").gt("balance", 0).execute().data or []
        except Exception as e:
            raise HTTPException(status_code=500, detail=f"Database error: {e}")

        projected = []
        total = 0
        for acc in accounts:
            if acc.get("account_number") == "TREASURY-MAIN":
                continue
            rate = rates.get(acc.get("account_type"), 0.0)
            if rate <= 0:
                continue
            interest = int((acc["balance"] * (rate / 100.0)) // 12)
            if interest <= 0:
                continue
            total += interest
            projected.append({
                "account_number": acc["account_number"],
                "balance": acc["balance"],
                "annual_rate_pct": rate,
                "interest_amount": interest,
                "interest_formatted": _rs(interest),
            })

        return {
            "success": True, "dry_run": True,
            "accounts_would_be_paid": len(projected),
            "total_interest": total, "total_interest_formatted": _rs(total),
            "details": projected,
        }

    result = _call_rpc(supabase, "accrue_monthly_interest", {"p_as_of": payload.as_of})
    if isinstance(result, dict):
        result["total_interest_formatted"] = _rs(result.get("total_interest"))
    logger.info(f"Interest accrual completed: {result}")
    return result


@app.post("/project-interest")
def project_interest(payload: ProjectInterestRequest):
    """
    Month-by-month interest projection on a balance. Pure computation -- touches
    no account and moves no money. Used to answer "what would I earn?" without
    creating a financial record to answer a hypothetical.
    """
    monthly_rate = payload.annual_rate_pct / 100.0 / 12.0
    balance = payload.balance
    schedule = []
    total_interest = 0

    for month in range(1, payload.months + 1):
        # Floor to whole paisa each month, matching the accrual rule exactly:
        # projecting with floats and rounding at the end would drift from what
        # the customer is actually paid.
        interest = int(balance * monthly_rate)
        if interest < 0:
            interest = 0
        balance += interest
        total_interest += interest
        schedule.append({
            "month": month,
            "interest": interest,
            "interest_formatted": _rs(interest),
            "closing_balance": balance,
            "closing_balance_formatted": _rs(balance),
        })

    return {
        "success": True,
        "opening_balance": payload.balance,
        "opening_balance_formatted": _rs(payload.balance),
        "annual_rate_pct": payload.annual_rate_pct,
        "months": payload.months,
        "total_interest": total_interest,
        "total_interest_formatted": _rs(total_interest),
        "closing_balance": balance,
        "closing_balance_formatted": _rs(balance),
        "schedule": schedule,
    }


class StatementRequest(BaseModel):
    account_id: str = Field(..., description="UUID of the account")
    period_start: Optional[str] = Field(default=None, description="YYYY-MM-DD")
    period_end: Optional[str] = Field(default=None, description="YYYY-MM-DD")


@app.post("/generate-statement")
def generate_statement(payload: StatementRequest):
    """
    Produces a rendered, human-readable account statement.

    The figures come from the ledger via generate_account_statement(); this
    endpoint's job is turning them into something a customer can actually read
    in an email, and checking that the statement internally balances before
    sending it out.
    """
    supabase = get_supabase_client()
    data = _call_rpc(supabase, "generate_account_statement", {
        "p_account_id": payload.account_id,
        "p_from": payload.period_start,
        "p_to": payload.period_end,
    })

    if not isinstance(data, dict) or not data.get("success"):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=(data or {}).get("error", "Could not generate statement")
        )

    opening = int(data.get("opening_balance") or 0)
    credits = int(data.get("total_credits") or 0)
    debits = int(data.get("total_debits") or 0)
    closing = int(data.get("closing_balance") or 0)

    # A statement whose own arithmetic does not close is a statement we must not
    # send. Opening + credits - debits must equal closing, or the ledger and the
    # rendering disagree and a human needs to look.
    expected_closing = opening + credits - debits
    balanced = expected_closing == closing

    lines = [
        "DIGITAL BANK - ACCOUNT STATEMENT",
        "=" * 60,
        f"Account:        {data.get('account_number')} ({data.get('account_type')})",
        f"Period:         {data.get('period_start')} to {data.get('period_end')}",
        f"Currency:       {data.get('currency')}",
        "",
        f"Opening balance:  {_rs(opening):>20}",
        f"Money in:         {_rs(credits):>20}",
        f"Money out:        {_rs(debits):>20}",
        f"Closing balance:  {_rs(closing):>20}",
        "",
    ]

    entries = data.get("entries") or []
    if entries:
        lines.append(f"{'DATE':<12} {'DESCRIPTION':<32} {'IN/OUT':<8} {'AMOUNT':>14} {'BALANCE':>14}")
        lines.append("-" * 84)
        for e in entries:
            posted = str(e.get("posted_at") or "")[:10]
            desc = str(e.get("description") or "")[:32]
            direction = "OUT" if str(e.get("entry_type", "")).upper() == "DEBIT" else "IN"
            lines.append(
                f"{posted:<12} {desc:<32} {direction:<8} "
                f"{_rs(e.get('amount')):>14} {_rs(e.get('balance_after')):>14}"
            )
    else:
        lines.append("No transactions in this period.")

    debt = int(data.get("outstanding_debt") or 0)
    if debt > 0:
        lines += ["", f"OUTSTANDING DEBT ON THIS ACCOUNT: {_rs(debt)}",
                  "This is collected automatically from funds received into the account."]

    lines += ["", f"Current balance: {_rs(data.get('current_balance'))}",
              "=" * 60]

    if not balanced:
        logger.error(
            f"Statement for {data.get('account_number')} does not balance: "
            f"opening {opening} + credits {credits} - debits {debits} = {expected_closing}, "
            f"but closing is {closing}"
        )

    return {
        "success": True,
        "balanced": balanced,
        "account_number": data.get("account_number"),
        "period_start": data.get("period_start"),
        "period_end": data.get("period_end"),
        "opening_balance": opening,
        "total_credits": credits,
        "total_debits": debits,
        "closing_balance": closing,
        "entry_count": data.get("entry_count"),
        "outstanding_debt": debt,
        "holder_emails": data.get("holder_emails") or [],
        "statement_text": "\n".join(lines),
    }


class ReconcileRequest(BaseModel):
    run_date: Optional[str] = Field(default=None, description="YYYY-MM-DD; defaults to today")
    sweep_debts: bool = Field(default=True, description="Also collect outstanding debts")


@app.post("/reconcile")
def reconcile(payload: ReconcileRequest):
    """
    Nightly integrity run: reconcile the ledger, then collect any outstanding
    debt from accounts that can now cover it.

    The arithmetic lives in Postgres (it reads the ledger under the same
    transactional guarantees that wrote it). This endpoint orchestrates the two
    steps, classifies the outcome, and decides whether a human needs waking.
    """
    supabase = get_supabase_client()

    run_date = payload.run_date or datetime.now(timezone.utc).date().isoformat()
    recon = _call_rpc(supabase, "run_reconciliation", {"p_run_date": run_date})

    if not isinstance(recon, dict):
        raise HTTPException(status_code=500, detail="Unexpected reconciliation response")

    debits = int(recon.get("total_debits") or 0)
    credits = int(recon.get("total_credits") or 0)
    drift = debits - credits
    discrepancies = recon.get("discrepancies") or []
    passed = bool(recon.get("passed")) and drift == 0 and len(discrepancies) == 0

    sweep = None
    if payload.sweep_debts:
        sweep = _call_rpc(supabase, "sweep_outstanding_debts", {})

    if not passed:
        logger.error(
            f"RECONCILIATION FAILED for {run_date}: drift={drift} paisa, "
            f"{len(discrepancies)} account discrepancies"
        )
    else:
        logger.info(f"Reconciliation passed for {run_date}: {_rs(debits)} on both sides")

    return {
        "success": True,
        "run_date": run_date,
        "passed": passed,
        "requires_human_attention": not passed,
        "total_debits": debits,
        "total_credits": credits,
        "total_debits_formatted": _rs(debits),
        "system_drift": drift,
        "system_drift_formatted": _rs(drift),
        "discrepancy_count": len(discrepancies),
        "discrepancies": discrepancies,
        "debt_sweep": sweep,
    }


if __name__ == "__main__":
    port = int(os.getenv("PORT", 8080))
    uvicorn.run("main:app", host="0.0.0.0", port=port, reload=False)
